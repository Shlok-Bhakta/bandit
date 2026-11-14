// Neural Playground BCI bridge: a BLE HID device implementing Apple's Brain-Computer Interface HID
// descriptor, plus a small authenticated GATT service that Neural Playground writes finished BCI
// reports to. The bridge never sees the Neural Band's owner key.
//
// Test inputs before involving the band:
//   - BOOT button: Select (button 0) click
//   - Serial monitor: s=Select n=Next p=Previous m=Menu a=Activate h=Home u=VolUp d=VolDown
//                     e=Escape c=AppSwitcher x=release all  ?=help
//
// The Neural Band measures surface EMG (muscle activity). This bridge only relays user intent
// through Apple's BCI HID interface; it does not measure brain activity.

#include <stdio.h>
#include <string.h>

#include "driver/gpio.h"
#include "esp_hidd.h"
#include "esp_log.h"
#include "esp_random.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "nvs_flash.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include "bci_descriptor.h"

static const char *TAG = "bci-bridge";

#define DEVICE_NAME "NP BCI Bridge"
#define APPEARANCE_GENERIC_HID 0x03C0
#define BRIDGE_PROTOCOL_VERSION 1

// iOS button indices (Apple's documented action order).
enum {
    BTN_SELECT = 0, BTN_NEXT = 1, BTN_PREVIOUS = 2, BTN_MENU = 3, BTN_ACTIVATE = 4,
    BTN_APP_SWITCHER = 8, BTN_HOME = 9, BTN_VOLUME_DOWN = 12, BTN_VOLUME_UP = 13, BTN_ESCAPE = 17,
};

static esp_hidd_dev_t *s_hid_dev;
static bool s_hid_connected;
static uint16_t s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static uint16_t s_status_handle;
static bool s_status_subscribed;
static uint8_t s_own_addr_type;
static uint32_t s_buttons;            // absolute state of all 32 buttons (report 2)
static uint8_t s_last_sequence;
static uint32_t s_bridge_reports;

// ---------------------------------------------------------------------------------------------
// HID reports
// ---------------------------------------------------------------------------------------------

static void send_report(uint8_t report_id, const uint8_t *payload, size_t length) {
    if (!s_hid_dev || !s_hid_connected) {
        ESP_LOGW(TAG, "report %u not sent: no HID host connected", report_id);
        return;
    }
    esp_err_t err = esp_hidd_dev_input_set(s_hid_dev, 0, report_id, (uint8_t *)payload, length);
    if (err != ESP_OK) ESP_LOGE(TAG, "report %u failed: %s", report_id, esp_err_to_name(err));
}

static void send_buttons(void) {
    uint8_t payload[4] = {s_buttons & 0xff, (s_buttons >> 8) & 0xff, (s_buttons >> 16) & 0xff, s_buttons >> 24};
    ESP_LOGI(TAG, "buttons -> %02X %02X %02X %02X", payload[0], payload[1], payload[2], payload[3]);
    send_report(BCI_REPORT_BUTTONS, payload, sizeof(payload));
}

static void release_all(const char *why) {
    if (s_buttons == 0) return;
    ESP_LOGW(TAG, "releasing all buttons (%s)", why);
    s_buttons = 0;
    send_buttons();
}

// Press then release one button, preserving the others (Apple's send_bci_button_click).
static void click(int index) {
    if (index < 0 || index > 31) return;
    s_buttons |= (1u << index);
    send_buttons();
    vTaskDelay(pdMS_TO_TICKS(40));
    s_buttons &= ~(1u << index);
    send_buttons();
}

// ---------------------------------------------------------------------------------------------
// Bridge GATT service: [version, sequence, reportID, payload...] from Neural Playground.
// Writes require an encrypted, authenticated (passkey) bond, so only the paired phone can drive it.
// ---------------------------------------------------------------------------------------------

static const ble_uuid128_t BRIDGE_SERVICE = BLE_UUID128_INIT(0x50, 0x4F, 0x3E, 0x2C, 0x1D, 0x4B, 0x3A, 0x9E,
                                                              0x5D, 0x4C, 0x6B, 0x5E, 0x01, 0x00, 0x1F, 0x7A);
static const ble_uuid128_t BRIDGE_REPORT = BLE_UUID128_INIT(0x50, 0x4F, 0x3E, 0x2C, 0x1D, 0x4B, 0x3A, 0x9E,
                                                             0x5D, 0x4C, 0x6B, 0x5E, 0x02, 0x00, 0x1F, 0x7A);
static const ble_uuid128_t BRIDGE_STATUS = BLE_UUID128_INIT(0x50, 0x4F, 0x3E, 0x2C, 0x1D, 0x4B, 0x3A, 0x9E,
                                                             0x5D, 0x4C, 0x6B, 0x5E, 0x03, 0x00, 0x1F, 0x7A);

static void notify_status(uint8_t kind, const uint8_t *data, size_t length) {
    if (!s_status_subscribed || s_conn_handle == BLE_HS_CONN_HANDLE_NONE) return;
    uint8_t packet[32];
    if (length > sizeof(packet) - 1) length = sizeof(packet) - 1;
    packet[0] = kind;
    memcpy(packet + 1, data, length);
    struct os_mbuf *om = ble_hs_mbuf_from_flat(packet, length + 1);
    if (om) ble_gatts_notify_custom(s_conn_handle, s_status_handle, om);
}

static void notify_text(const char *text) { notify_status(1, (const uint8_t *)text, strlen(text)); }

static size_t expected_payload(uint8_t report_id) {
    switch (report_id) {
    case BCI_REPORT_SIGNAL_QUALITY: return 2;
    case BCI_REPORT_BUTTONS: return 4;
    case BCI_REPORT_POINTER: return 3;
    case BCI_REPORT_ITEM: return 1;
    default: return 0;
    }
}

static int bridge_access(uint16_t conn_handle, uint16_t attr_handle, struct ble_gatt_access_ctxt *ctxt, void *arg) {
    if (ble_uuid_cmp(ctxt->chr->uuid, &BRIDGE_STATUS.u) == 0 && ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
        const char *state = s_hid_connected ? "hid connected" : "hid waiting";
        uint8_t packet[24] = {1};
        size_t length = strlen(state);
        memcpy(packet + 1, state, length);
        return os_mbuf_append(ctxt->om, packet, length + 1) == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) return BLE_ATT_ERR_REQ_NOT_SUPPORTED;
    uint8_t packet[16];
    uint16_t length = 0;
    if (ble_hs_mbuf_to_flat(ctxt->om, packet, sizeof(packet), &length) != 0 || length < 3) {
        ESP_LOGW(TAG, "bridge: malformed packet (%u bytes)", length);
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }
    uint8_t version = packet[0], sequence = packet[1], report_id = packet[2];
    size_t payload_length = length - 3;
    if (version != BRIDGE_PROTOCOL_VERSION) {
        ESP_LOGW(TAG, "bridge: unsupported protocol version %u", version);
        return BLE_ATT_ERR_UNLIKELY;
    }
    if (expected_payload(report_id) == 0 || expected_payload(report_id) != payload_length) {
        ESP_LOGW(TAG, "bridge: report %u with %u payload bytes rejected", report_id, (unsigned)payload_length);
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }
    if (report_id == BCI_REPORT_POINTER && (int8_t)packet[3] == BCI_POINTER_AXIS_ABSENT) {
        ESP_LOGW(TAG, "bridge: pointer report with absent x-axis rejected (host would ignore it)");
        return BLE_ATT_ERR_UNLIKELY;
    }
    if (sequence != (uint8_t)(s_last_sequence + 1) && s_bridge_reports > 0) {
        ESP_LOGW(TAG, "bridge: sequence %u after %u (a packet was lost or repeated)", sequence, s_last_sequence);
    }
    s_last_sequence = sequence;
    s_bridge_reports++;
    if (report_id == BCI_REPORT_BUTTONS) {
        s_buttons = packet[3] | (packet[4] << 8) | (packet[5] << 16) | ((uint32_t)packet[6] << 24);
    }
    ESP_LOGI(TAG, "bridge: seq %u report %u (%u bytes)", sequence, report_id, (unsigned)payload_length);
    send_report(report_id, packet + 3, payload_length);
    return 0;
}

static const struct ble_gatt_svc_def bridge_services[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &BRIDGE_SERVICE.u,
        .characteristics = (struct ble_gatt_chr_def[]){
            {
                .uuid = &BRIDGE_REPORT.u,
                .access_cb = bridge_access,
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP | BLE_GATT_CHR_F_WRITE_ENC | BLE_GATT_CHR_F_WRITE_AUTHEN,
            },
            {
                .uuid = &BRIDGE_STATUS.u,
                .access_cb = bridge_access,
                .val_handle = &s_status_handle,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY | BLE_GATT_CHR_F_READ_ENC,
            },
            {0},
        },
    },
    {0},
};

// ---------------------------------------------------------------------------------------------
// GAP: advertising and passkey pairing
// ---------------------------------------------------------------------------------------------

static void advertise(void);

static int gap_event(struct ble_gap_event *event, void *arg) {
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        ESP_LOGI(TAG, "connect %s (handle %d)", event->connect.status == 0 ? "ok" : "failed", event->connect.conn_handle);
        if (event->connect.status == 0) {
            s_conn_handle = event->connect.conn_handle;
            // HID hosts expect an encrypted link; ask for it right away.
            ble_gap_security_initiate(s_conn_handle);
        } else {
            advertise();
        }
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGW(TAG, "disconnect (reason 0x%x)", event->disconnect.reason);
        s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        s_status_subscribed = false;
        s_buttons = 0;  // nothing can stay pressed across a lost link
        advertise();
        break;
    case BLE_GAP_EVENT_ENC_CHANGE:
        ESP_LOGI(TAG, "encryption %s (status %d)", event->enc_change.status == 0 ? "on" : "failed", event->enc_change.status);
        break;
    case BLE_GAP_EVENT_PASSKEY_ACTION:
        if (event->passkey.params.action == BLE_SM_IOACT_DISP) {
            struct ble_sm_io pk = {.action = BLE_SM_IOACT_DISP, .passkey = esp_random() % 1000000};
            printf("\n================================================\n");
            printf("  Pairing passkey: %06" PRIu32 "\n  Type it on the iPhone when asked.\n", pk.passkey);
            printf("================================================\n\n");
            ble_sm_inject_io(event->passkey.conn_handle, &pk);
        }
        break;
    case BLE_GAP_EVENT_REPEAT_PAIRING: {
        // The phone forgot the bond: drop ours and pair again.
        struct ble_gap_conn_desc desc;
        if (ble_gap_conn_find(event->repeat_pairing.conn_handle, &desc) == 0) ble_store_util_delete_peer(&desc.peer_id_addr);
        return BLE_GAP_REPEAT_PAIRING_RETRY;
    }
    case BLE_GAP_EVENT_SUBSCRIBE:
        if (event->subscribe.attr_handle == s_status_handle) {
            s_status_subscribed = event->subscribe.cur_notify;
            ESP_LOGI(TAG, "bridge status notifications %s", s_status_subscribed ? "on" : "off");
            if (!s_status_subscribed) release_all("bridge client unsubscribed");
            else notify_text(s_hid_connected ? "hid connected" : "hid waiting");
        }
        break;
    case BLE_GAP_EVENT_ADV_COMPLETE:
        advertise();
        break;
    default:
        break;
    }
    return 0;
}

static void advertise(void) {
    struct ble_hs_adv_fields fields = {0};
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.appearance = APPEARANCE_GENERIC_HID;
    fields.appearance_is_present = 1;
    ble_uuid16_t hid = BLE_UUID16_INIT(0x1812);
    fields.uuids16 = &hid;
    fields.num_uuids16 = 1;
    fields.uuids16_is_complete = 0;
    fields.name = (uint8_t *)DEVICE_NAME;
    fields.name_len = strlen(DEVICE_NAME);
    fields.name_is_complete = 1;
    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) { ESP_LOGE(TAG, "adv fields: %d", rc); return; }

    struct ble_hs_adv_fields response = {0};
    response.uuids128 = (ble_uuid128_t *)&BRIDGE_SERVICE;
    response.num_uuids128 = 1;
    response.uuids128_is_complete = 0;
    rc = ble_gap_adv_rsp_set_fields(&response);
    if (rc != 0) ESP_LOGW(TAG, "scan response: %d", rc);

    struct ble_gap_adv_params params = {.conn_mode = BLE_GAP_CONN_MODE_UND, .disc_mode = BLE_GAP_DISC_MODE_GEN};
    rc = ble_gap_adv_start(s_own_addr_type, NULL, BLE_HS_FOREVER, &params, gap_event, NULL);
    if (rc != 0 && rc != BLE_HS_EALREADY) ESP_LOGE(TAG, "adv start: %d", rc);
    else ESP_LOGI(TAG, "advertising as \"%s\"", DEVICE_NAME);
}

static void on_sync(void) {
    ble_hs_util_ensure_addr(0);
    ble_hs_id_infer_auto(0, &s_own_addr_type);
    advertise();
}

static void on_reset(int reason) { ESP_LOGE(TAG, "NimBLE reset, reason %d", reason); }

static void host_task(void *param) {
    nimble_port_run();
    nimble_port_freertos_deinit();
}

// ---------------------------------------------------------------------------------------------
// HID device events
// ---------------------------------------------------------------------------------------------

static void hidd_event(void *handler_args, esp_event_base_t base, int32_t id, void *event_data) {
    esp_hidd_event_data_t *param = (esp_hidd_event_data_t *)event_data;
    switch ((esp_hidd_event_t)id) {
    case ESP_HIDD_START_EVENT: ESP_LOGI(TAG, "HID started"); break;
    case ESP_HIDD_CONNECT_EVENT:
        s_hid_connected = true;
        ESP_LOGI(TAG, "HID host connected");
        notify_text("hid connected");
        break;
    case ESP_HIDD_PROTOCOL_MODE_EVENT:
        ESP_LOGI(TAG, "protocol mode %s", param->protocol_mode.protocol_mode ? "report" : "boot");
        break;
    case ESP_HIDD_CONTROL_EVENT:
        ESP_LOGI(TAG, "control %s", param->control.control ? "exit suspend" : "suspend");
        break;
    case ESP_HIDD_OUTPUT_EVENT:
        // Report 4 output: Switch Control's scan information (6 bytes).
        ESP_LOGI(TAG, "output report %u (%u bytes)", param->output.report_id, param->output.length);
        if (param->output.report_id == BCI_REPORT_ITEM && param->output.length == 6) {
            const uint8_t *d = param->output.data;
            ESP_LOGI(TAG, "scan: item %u/%u seed %u type %u latency %u+%u/255", d[0], d[1], d[2], d[3], d[4], d[5]);
            notify_status(4, d, 6);
        }
        break;
    case ESP_HIDD_FEATURE_EVENT:
        ESP_LOGI(TAG, "feature report %u", param->feature.report_id);
        break;
    case ESP_HIDD_DISCONNECT_EVENT:
        s_hid_connected = false;
        s_buttons = 0;
        ESP_LOGW(TAG, "HID host disconnected");
        break;
    case ESP_HIDD_STOP_EVENT: ESP_LOGI(TAG, "HID stopped"); break;
    default: break;
    }
}

// ---------------------------------------------------------------------------------------------
// Test inputs: serial commands and the BOOT button
// ---------------------------------------------------------------------------------------------

static void print_help(void) {
    printf("\nCommands: s=Select n=Next p=Previous m=Menu a=Activate h=Home c=AppSwitcher\n"
           "          u=VolumeUp d=VolumeDown e=Escape x=ReleaseAll ?=Help\n"
           "BOOT button (GPIO %d) = Select\n\n", CONFIG_BCI_BUTTON_GPIO);
}

static void input_task(void *param) {
    gpio_config_t io = {.pin_bit_mask = 1ULL << CONFIG_BCI_BUTTON_GPIO, .mode = GPIO_MODE_INPUT, .pull_up_en = GPIO_PULLUP_ENABLE};
    gpio_config(&io);
    int last_level = 1;
    print_help();
    for (;;) {
        int level = gpio_get_level(CONFIG_BCI_BUTTON_GPIO);
        if (last_level == 1 && level == 0) {
            ESP_LOGI(TAG, "BOOT button: Select");
            click(BTN_SELECT);
        }
        last_level = level;

        int c = fgetc(stdin);
        switch (c) {
        case 's': click(BTN_SELECT); break;
        case 'n': click(BTN_NEXT); break;
        case 'p': click(BTN_PREVIOUS); break;
        case 'm': click(BTN_MENU); break;
        case 'a': click(BTN_ACTIVATE); break;
        case 'h': click(BTN_HOME); break;
        case 'c': click(BTN_APP_SWITCHER); break;
        case 'u': click(BTN_VOLUME_UP); break;
        case 'd': click(BTN_VOLUME_DOWN); break;
        case 'e': click(BTN_ESCAPE); break;
        case 'x': release_all("serial command"); break;
        case '?': print_help(); break;
        default: break;
        }
        vTaskDelay(pdMS_TO_TICKS(20));
    }
}

void app_main(void) {
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);

    ESP_ERROR_CHECK(nimble_port_init());
    ble_hs_cfg.reset_cb = on_reset;
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.store_status_cb = ble_store_util_status_rr;
    // Passkey pairing (display only): the bond is authenticated, which the bridge characteristic requires.
    ble_hs_cfg.sm_io_cap = BLE_HS_IO_DISPLAY_ONLY;
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_mitm = 1;
    ble_hs_cfg.sm_sc = 1;
    ble_hs_cfg.sm_our_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;

    ble_svc_gap_init();
    ble_svc_gatt_init();
    ble_svc_gap_device_name_set(DEVICE_NAME);
    ble_svc_gap_device_appearance_set(APPEARANCE_GENERIC_HID);

    static esp_hid_raw_report_map_t report_maps[] = {{.data = bci_report_map, .len = sizeof(bci_report_map)}};
    static esp_hid_device_config_t config = {
        .vendor_id = 0x16C0,  // pid.codes / V-USB shared test VID; replace for anything you distribute
        .product_id = 0x27DE,
        .version = 0x0100,
        .device_name = DEVICE_NAME,
        .manufacturer_name = "Neural Playground",
        .serial_number = "0001",
        .report_maps = report_maps,
        .report_maps_len = 1,
    };
    ESP_ERROR_CHECK(esp_hidd_dev_init(&config, ESP_HID_TRANSPORT_BLE, hidd_event, &s_hid_dev));

    ESP_ERROR_CHECK(ble_gatts_count_cfg(bridge_services) == 0 ? ESP_OK : ESP_FAIL);
    ESP_ERROR_CHECK(ble_gatts_add_svcs(bridge_services) == 0 ? ESP_OK : ESP_FAIL);

    extern void ble_store_config_init(void);
    ble_store_config_init();
    nimble_port_freertos_init(host_task);

    xTaskCreate(input_task, "inputs", 4096, NULL, 5, NULL);
    ESP_LOGI(TAG, "BCI bridge ready: pair \"%s\" from iPhone Settings › Bluetooth", DEVICE_NAME);
}
