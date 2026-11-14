// band-link stage 1: ESP32 connects to the Meta Neural Band directly.
// Finds the band (name "Meta Band…" or identity address), pairs/bonds (Just Works, saved in NVS),
// reads the PSM characteristic, opens the L2CAP channel, and logs everything over USB serial.
// No owner key is used yet; the encrypted session comes in stage 2.

#include <stdio.h>
#include <string.h>

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "host/ble_hs.h"
#include "host/ble_l2cap.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "nvs_flash.h"
#include "os/os_mbuf.h"
#include "services/gap/ble_svc_gap.h"

static const char *TAG = "band-link";

// Your band's Bluetooth identity address, most significant byte first (macOS: System
// Information › Bluetooth; Linux: bluetoothctl devices). In pairing mode it advertises with a
// resolvable private address, so the name is matched too. Set it before building.
#ifndef BAND_IDENTITY_ADDR
#define BAND_IDENTITY_ADDR {0x00, 0x00, 0x00, 0x00, 0x00, 0x00}
#endif
static const uint8_t BAND_IDENTITY[6] = BAND_IDENTITY_ADDR;

static uint8_t s_own_addr_type;
static uint16_t s_conn = BLE_HS_CONN_HANDLE_NONE;
static uint16_t s_psm_handle;
static struct ble_l2cap_chan *s_chan;

#define COC_MTU 512
#define COC_BUFS 6
static os_membuf_t s_coc_mem[OS_MEMPOOL_SIZE(COC_BUFS, COC_MTU + 64)];
static struct os_mempool s_coc_pool;
static struct os_mbuf_pool s_coc_mbuf_pool;

static void start_scan(void);

static void log_hex(const char *label, const uint8_t *data, size_t length, size_t max) {
    char line[3 * 64 + 1];
    size_t shown = length < max ? length : max;
    if (shown > 64) shown = 64;
    for (size_t i = 0; i < shown; i++) sprintf(line + i * 3, "%02x ", data[i]);
    line[shown * 3] = 0;
    ESP_LOGI(TAG, "%s (%u B): %s%s", label, (unsigned)length, line, length > shown ? "…" : "");
}

static bool is_identity(const ble_addr_t *addr) {
    // NimBLE stores addresses little-endian.
    for (int i = 0; i < 6; i++) if (addr->val[i] != BAND_IDENTITY[5 - i]) return false;
    return true;
}

// ---------------------------------------------------------------------------------------------
// L2CAP channel
// ---------------------------------------------------------------------------------------------

static struct os_mbuf *coc_rx_buffer(void) { return os_mbuf_get_pkthdr(&s_coc_mbuf_pool, 0); }

static int l2cap_event(struct ble_l2cap_event *event, void *arg) {
    switch (event->type) {
    case BLE_L2CAP_EVENT_COC_CONNECTED:
        if (event->connect.status) {
            ESP_LOGE(TAG, "L2CAP connect failed: %d", event->connect.status);
            return 0;
        }
        s_chan = event->connect.chan;
        struct ble_l2cap_chan_info info;
        ble_l2cap_get_chan_info(s_chan, &info);
        ESP_LOGW(TAG, "RESULT: L2CAP channel open on PSM 0x%04x (our MTU %u, peer MTU %u, peer CoC MTU %u)",
                 info.psm, info.our_l2cap_mtu, info.peer_l2cap_mtu, info.peer_coc_mtu);
        ESP_LOGI(TAG, "Stage 1 complete: link works. Stage 2 adds encryption + owner trust.");
        return 0;
    case BLE_L2CAP_EVENT_COC_DISCONNECTED:
        ESP_LOGW(TAG, "L2CAP channel closed");
        s_chan = NULL;
        return 0;
    case BLE_L2CAP_EVENT_COC_DATA_RECEIVED: {
        struct os_mbuf *om = event->receive.sdu_rx;
        uint16_t length = OS_MBUF_PKTLEN(om);
        uint8_t buffer[96];
        os_mbuf_copydata(om, 0, length < sizeof(buffer) ? length : sizeof(buffer), buffer);
        log_hex("L2CAP rx", buffer, length, sizeof(buffer));
        os_mbuf_free_chain(om);
        ble_l2cap_recv_ready(event->receive.chan, coc_rx_buffer());
        return 0;
    }
    case BLE_L2CAP_EVENT_COC_TX_UNSTALLED:
        return 0;
    default:
        return 0;
    }
}

// ---------------------------------------------------------------------------------------------
// GATT: find the PSM characteristic (FEB8 / 2D41DA7C-…), read it, open L2CAP
// ---------------------------------------------------------------------------------------------

static const ble_uuid128_t PSM_UUID = BLE_UUID128_INIT(0x1A, 0xCC, 0xF8, 0x1D, 0xE0, 0xE2, 0x4E, 0xB3,
                                                       0xAA, 0x42, 0xB6, 0x82, 0x7C, 0xDA, 0x41, 0x2D);

static int psm_read(uint16_t conn, const struct ble_gatt_error *error, struct ble_gatt_attr *attr, void *arg) {
    if (error->status != 0) {
        ESP_LOGE(TAG, "PSM read failed: status %d (0x%x)", error->status, error->status);
        return 0;
    }
    uint8_t value[8] = {0};
    uint16_t length = OS_MBUF_PKTLEN(attr->om);
    os_mbuf_copydata(attr->om, 0, length < sizeof(value) ? length : sizeof(value), value);
    log_hex("PSM characteristic", value, length, sizeof(value));
    if (length != 2) return 0;
    uint16_t psm = value[0] | (value[1] << 8);
    ESP_LOGW(TAG, "RESULT: PSM %u; opening L2CAP", psm);
    int rc = ble_l2cap_connect(conn, psm, COC_MTU, coc_rx_buffer(), l2cap_event, NULL);
    if (rc) ESP_LOGE(TAG, "ble_l2cap_connect: %d", rc);
    return 0;
}

static int chr_found(uint16_t conn, const struct ble_gatt_error *error, const struct ble_gatt_chr *chr, void *arg) {
    if (error->status == 0 && chr) {
        char uuid[BLE_UUID_STR_LEN];
        ESP_LOGI(TAG, "characteristic %s handle %u props 0x%02x", ble_uuid_to_str(&chr->uuid.u, uuid), chr->val_handle, chr->properties);
        if (ble_uuid_cmp(&chr->uuid.u, &PSM_UUID.u) == 0) s_psm_handle = chr->val_handle;
        return 0;
    }
    if (error->status == BLE_HS_EDONE) {
        if (!s_psm_handle) { ESP_LOGE(TAG, "PSM characteristic not found"); return 0; }
        ble_gattc_read(conn, s_psm_handle, psm_read, NULL);
    }
    return 0;
}

static int svc_found(uint16_t conn, const struct ble_gatt_error *error, const struct ble_gatt_svc *svc, void *arg) {
    if (error->status == 0 && svc) {
        ESP_LOGI(TAG, "FEB8 service handles %u–%u", svc->start_handle, svc->end_handle);
        ble_gattc_disc_all_chrs(conn, svc->start_handle, svc->end_handle, chr_found, NULL);
    } else if (error->status != BLE_HS_EDONE) {
        ESP_LOGE(TAG, "service discovery failed: %d", error->status);
    }
    return 0;
}

// ---------------------------------------------------------------------------------------------
// GAP
// ---------------------------------------------------------------------------------------------

static int gap_event(struct ble_gap_event *event, void *arg) {
    switch (event->type) {
    case BLE_GAP_EVENT_DISC: {
        struct ble_hs_adv_fields fields;
        if (ble_hs_adv_parse_fields(&fields, event->disc.data, event->disc.length_data) != 0) return 0;
        bool named = fields.name && fields.name_len >= 9 && memcmp(fields.name, "Meta Band", 9) == 0;
        if (!named && !is_identity(&event->disc.addr)) return 0;
        char name[32] = {0};
        if (fields.name) memcpy(name, fields.name, fields.name_len < 31 ? fields.name_len : 31);
        ESP_LOGW(TAG, "Found band \"%s\" addr %02x:%02x:%02x:%02x:%02x:%02x type %d rssi %d",
                 name, event->disc.addr.val[5], event->disc.addr.val[4], event->disc.addr.val[3],
                 event->disc.addr.val[2], event->disc.addr.val[1], event->disc.addr.val[0],
                 event->disc.addr.type, event->disc.rssi);
        ble_gap_disc_cancel();
        int rc = ble_gap_connect(s_own_addr_type, &event->disc.addr, 30000, NULL, gap_event, NULL);
        if (rc) { ESP_LOGE(TAG, "connect: %d", rc); start_scan(); }
        return 0;
    }
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status != 0) {
            ESP_LOGE(TAG, "connection failed: %d", event->connect.status);
            start_scan();
            return 0;
        }
        s_conn = event->connect.conn_handle;
        ESP_LOGW(TAG, "Connected (handle %d); starting security (bonding)", s_conn);
        ble_gap_security_initiate(s_conn);
        return 0;
    case BLE_GAP_EVENT_ENC_CHANGE: {
        struct ble_gap_conn_desc desc;
        ble_gap_conn_find(event->enc_change.conn_handle, &desc);
        ESP_LOGW(TAG, "Encryption change: status %d, encrypted %d, authenticated %d, bonded %d, key size %d",
                 event->enc_change.status, desc.sec_state.encrypted, desc.sec_state.authenticated,
                 desc.sec_state.bonded, desc.sec_state.key_size);
        if (event->enc_change.status == 0) {
            ESP_LOGI(TAG, "peer identity %02x:%02x:%02x:%02x:%02x:%02x (type %d)",
                     desc.peer_id_addr.val[5], desc.peer_id_addr.val[4], desc.peer_id_addr.val[3],
                     desc.peer_id_addr.val[2], desc.peer_id_addr.val[1], desc.peer_id_addr.val[0], desc.peer_id_addr.type);
            ble_uuid16_t feb8 = BLE_UUID16_INIT(0xFEB8);
            ble_gattc_disc_svc_by_uuid(s_conn, &feb8.u, svc_found, NULL);
        }
        return 0;
    }
    case BLE_GAP_EVENT_REPEAT_PAIRING: {
        struct ble_gap_conn_desc desc;
        if (ble_gap_conn_find(event->repeat_pairing.conn_handle, &desc) == 0) ble_store_util_delete_peer(&desc.peer_id_addr);
        ESP_LOGW(TAG, "Band asked to pair again; dropped the old bond and retrying");
        return BLE_GAP_REPEAT_PAIRING_RETRY;
    }
    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGW(TAG, "Disconnected: reason 0x%x", event->disconnect.reason);
        s_conn = BLE_HS_CONN_HANDLE_NONE;
        s_chan = NULL;
        s_psm_handle = 0;
        vTaskDelay(pdMS_TO_TICKS(3000));
        start_scan();
        return 0;
    case BLE_GAP_EVENT_DISC_COMPLETE:
        start_scan();
        return 0;
    default:
        return 0;
    }
}

static void start_scan(void) {
    struct ble_gap_disc_params params = {.passive = 0, .filter_duplicates = 1, .itvl = 0x50, .window = 0x30};
    int rc = ble_gap_disc(s_own_addr_type, 60000, &params, gap_event, NULL);
    if (rc && rc != BLE_HS_EALREADY) ESP_LOGE(TAG, "scan: %d", rc);
    else ESP_LOGI(TAG, "Scanning for the band (put it in pairing mode the first time: hold ~3 s)");
}

static void on_sync(void) {
    ble_hs_util_ensure_addr(0);
    ble_hs_id_infer_auto(0, &s_own_addr_type);
    // If we're already bonded, try the identity address directly too (works once the band's IRK is known).
    ble_addr_t identity = {.type = BLE_ADDR_PUBLIC};
    for (int i = 0; i < 6; i++) identity.val[i] = BAND_IDENTITY[5 - i];
    union ble_store_key key = {.sec = {.peer_addr = identity}};
    union ble_store_value value;
    if (ble_store_read_peer_sec(&key.sec, &value.sec) == 0) {
        ESP_LOGW(TAG, "Bonded with the band already; connecting to its identity address");
        if (ble_gap_connect(s_own_addr_type, &identity, 15000, NULL, gap_event, NULL) == 0) return;
    }
    start_scan();
}

static void host_task(void *param) {
    nimble_port_run();
    nimble_port_freertos_deinit();
}

void app_main(void) {
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        nvs_flash_erase();
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);
    ESP_ERROR_CHECK(os_mempool_init(&s_coc_pool, COC_BUFS, COC_MTU + 64, s_coc_mem, "coc"));
    ESP_ERROR_CHECK(os_mbuf_pool_init(&s_coc_mbuf_pool, &s_coc_pool, COC_MTU + 64, COC_BUFS));

    ESP_ERROR_CHECK(nimble_port_init());
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.store_status_cb = ble_store_util_status_rr;
    ble_hs_cfg.sm_io_cap = BLE_HS_IO_NO_INPUT_OUTPUT;
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_mitm = 0;
    ble_hs_cfg.sm_sc = 1;
    ble_hs_cfg.sm_our_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_svc_gap_init();
    ble_svc_gap_device_name_set("NP Band Link");
    extern void ble_store_config_init(void);
    ble_store_config_init();
    nimble_port_freertos_init(host_task);
    ESP_LOGI(TAG, "band-link stage 1 started");
}
