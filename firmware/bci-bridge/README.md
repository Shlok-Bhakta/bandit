# BCI bridge (ESP32)

A Bluetooth LE HID device that implements **Apple's Brain-Computer Interface HID descriptor**
(byte for byte, generated from `NeuralBandKit/Sources/BandAccessibility/BCIHID.swift`). It also
exposes a small authenticated GATT service. Neural Playground writes finished BCI reports to that
service, and the ESP32 forwards them to the iPhone as HID input for Switch Control.

```
Neural Band ──L2CAP──▶ Neural Playground (iPhone) ──bridge GATT──▶ ESP32 ──BLE HID (BCI)──▶ iOS Switch Control
```

The bridge never sees the band's owner key; that stays on the phone. The band measures surface EMG
(muscle activity), and this only uses Apple's BCI *interface* to deliver that intent.

## Which boards work

| Chip | BLE HID | Notes |
|---|---|---|
| ESP32 (classic) | ✅ | Compile-checked. BOOT = GPIO0 |
| ESP32-C3 | ✅ | BOOT = GPIO9 |
| ESP32-S3 | ✅ | BOOT = GPIO0 |
| ESP32-C6 | ✅ | BOOT = GPIO9 |
| ESP32-S2 | ❌ | No Bluetooth radio |

Not sure which one you have? Plug it in and run `esptool.py chip_id` (see below).

## Build and flash

ESP-IDF v5.4.2 is installed at `/Volumes/BlenderBuild/esp` (delete that folder to remove it).

```sh
export IDF_TOOLS_PATH=/Volumes/BlenderBuild/esp/tools
. /Volumes/BlenderBuild/esp/esp-idf/export.sh
cd firmware/bci-bridge
esptool.py chip_id                     # tells you the chip; plug the board in first
idf.py set-target esp32                # or esp32c3 / esp32s3 / esp32c6
idf.py build
idf.py -p /dev/cu.usbserial-XXXX flash monitor   # ls /dev/cu.* to find the port; Ctrl-] quits the monitor
```

## First test: no band, no app

1. Flash, and keep `idf.py monitor` open.
2. On the iPhone, go to **Settings › Bluetooth** and tap **NP BCI Bridge**. iOS asks for a passkey: type the six digits shown in the monitor.
3. Go to **Settings › Accessibility › Switch Control › Switches › Add New Switch › External**, then press the BOOT button (or type `s` in the monitor). Assign it to **Select Item**, and add more switches the same way (`n`, `p` …).
4. Turn on **Switch Control** (set up the Accessibility Shortcut first: triple-click the side button toggles it off again).
5. Press BOOT or type `n` / `s` to move through items and select them in any app. If iOS lists the BCI device under Switch Control's own BCI settings, try those too.

Serial commands: `s` Select, `n` Next, `p` Previous, `m` Menu, `a` Activate, `h` Home, `c` App
Switcher, `u`/`d` Volume, `e` Escape, `x` release all, `?` help.

## With the band

In Neural Playground, go to **Playground › System Control**:
1. Tap **Find ESP32 bridge**.
2. Turn on **Forward band gestures**.
3. Index tap → Select, thumb swipes → Next/Previous (the mapping is editable per wrist).

## Bridge protocol (v1)

- Service `7A1F0001-5E6B-4C5D-9E3A-4B1D2C3E4F50`
- Report characteristic `…0002`: write, encrypted + authenticated (passkey bond) only. The packet is `[version=1, sequence, reportID, payload…]`, where the payload sizes are report 1 = 2, report 2 = 4, report 3 = 3, report 4 = 1. A pointer report with an absent x-axis is rejected.
- Status characteristic `…0003`: notify. Kind `1` is a text status; kind `4` carries the 6-byte Switch Control scan info (BCI output report 4).
- All buttons are released when the link drops or the app unsubscribes.

## Status

Compiled with ESP-IDF v5.4.2. **Not yet run on hardware.** Things to verify on a real board:
- iOS recognizes the BCI descriptor over BLE HID, and Switch Control accepts its buttons.
- Button indices beyond 0–3, which come from Apple's list order.
- iOS lets the app reach the bridge's GATT service while the HID connection belongs to the system.
- How `esp_hid` builds report characteristics for the BCI usage page.
