import BandAccessibility
import BandKit
import BandLogging
import BandProtocol
import BandTransport
@preconcurrency import CoreBluetooth
import Foundation
import Observation
import UIKit

/// The bridge protocol between Neural Playground and the ESP32 BCI HID firmware (firmware/bci-bridge).
/// The ESP32 never sees the band's owner key: it only receives finished BCI reports.
enum BridgeProtocol {
    static let service = CBUUID(string: "7A1F0001-5E6B-4C5D-9E3A-4B1D2C3E4F50")
    /// Write without response, encrypted + authenticated link only (LE Secure Connections bond).
    static let report = CBUUID(string: "7A1F0002-5E6B-4C5D-9E3A-4B1D2C3E4F50")
    /// Notify: bridge status and Switch Control's scan information (BCI output report 4).
    static let status = CBUUID(string: "7A1F0003-5E6B-4C5D-9E3A-4B1D2C3E4F50")
    static let version: UInt8 = 1

    /// `[version, sequence, reportID, payload...]`.
    static func packet(_ report: BCIReport, sequence: UInt8) -> Data {
        Data([version, sequence, report.id.rawValue] + report.payload)
    }
}

/// Connects to the ESP32 bridge's custom GATT service (alongside the HID service iOS manages).
@MainActor
@Observable
final class BCIBridgeClient: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    enum State: Equatable { case off, searching, connecting, ready(String), failed(String) }

    private(set) var state: State = .off
    private(set) var lastStatus: String?
    private(set) var scanInfo: BCIScanInfo?
    @ObservationIgnored private var manager: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var reportCharacteristic: CBCharacteristic?
    @ObservationIgnored private var sequence: UInt8 = 0

    var isReady: Bool { if case .ready = state { true } else { false } }

    func start() {
        guard manager == nil else { return }
        state = .searching
        manager = CBCentralManager(delegate: self, queue: .main)
        logInfo(.app, "BCI bridge: looking for the ESP32 bridge service")
    }

    func stop() {
        if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
        manager?.stopScan()
        manager = nil
        peripheral = nil
        reportCharacteristic = nil
        state = .off
    }

    @discardableResult
    func send(_ report: BCIReport) -> Bool {
        guard let peripheral, let reportCharacteristic else { return false }
        sequence &+= 1
        peripheral.writeValue(BridgeProtocol.packet(report, sequence: sequence), for: reportCharacteristic, type: .withoutResponse)
        return true
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            if central.state != .unknown, central.state != .resetting { state = .failed("Bluetooth \(BandCentral.describe(central.state))") }
            return
        }
        // Once iOS has paired the bridge as a HID device, it's connected at the system level and may not advertise.
        if let connected = central.retrieveConnectedPeripherals(withServices: [BridgeProtocol.service]).first {
            logInfo(.app, "BCI bridge: found system-connected bridge \(connected.name ?? "?")")
            connect(connected)
        } else {
            central.scanForPeripherals(withServices: [BridgeProtocol.service])
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        logInfo(.app, "BCI bridge: discovered \(peripheral.name ?? "bridge") rssi \(RSSI)")
        connect(peripheral)
    }

    private func connect(_ peripheral: CBPeripheral) {
        manager?.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        state = .connecting
        manager?.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([BridgeProtocol.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = .failed(error?.localizedDescription ?? "Couldn't connect to the bridge")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logWarning(.app, "BCI bridge disconnected: \(error.map(BandLog.describe) ?? "requested")")
        reportCharacteristic = nil
        self.peripheral = nil
        if manager != nil {
            state = .searching
            central.scanForPeripherals(withServices: [BridgeProtocol.service])
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == BridgeProtocol.service }) else {
            state = .failed("The bridge service isn't visible to apps on this connection.")
            logWarning(.app, "BCI bridge: service not found (services: \(peripheral.services?.map(\.uuid.uuidString) ?? []))")
            return
        }
        peripheral.discoverCharacteristics([BridgeProtocol.report, BridgeProtocol.status], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == BridgeProtocol.report { reportCharacteristic = characteristic }
            if characteristic.uuid == BridgeProtocol.status { peripheral.setNotifyValue(true, for: characteristic) }
        }
        if reportCharacteristic != nil {
            state = .ready(peripheral.name ?? "ESP32 bridge")
            logNotice(.app, "BCI bridge ready: \(peripheral.name ?? "?")")
        } else {
            state = .failed("The bridge's report characteristic is missing")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let value = characteristic.value, !value.isEmpty else { return }
        let bytes = [UInt8](value)
        // Status packet: [kind, ...]; kind 1 = text, kind 4 = scan info (BCI output report 4 payload).
        if bytes[0] == 4, let info = try? BCIScanInfo(Array(bytes.dropFirst())) {
            scanInfo = info
            logDebug(.app, "Switch Control scan: item \(info.selectedItem)/\(info.numberOfItems), type \(info.itemControlType)")
        } else if bytes[0] == 1 {
            lastStatus = String(bytes: bytes.dropFirst(), encoding: .utf8)
            logInfo(.app, "BCI bridge status: \(lastStatus ?? "?")")
        }
    }
}

/// Neural Band gesture → wrist normalization (BandClient) → intent → BCI report → transport.
@MainActor
@Observable
final class SystemControl {
    struct Sent: Identifiable {
        let id = UUID()
        let date = Date()
        let gesture: RecognizedGesture
        let action: BCIAction
        let reports: [BCIReport]
        let source: EventSource
        let delivered: Bool
    }

    var forwarding = false {
        didSet {
            logNotice(.app, "System control forwarding \(forwarding ? "ON" : "OFF")")
            if !forwarding { emergencyStop(reason: "forwarding turned off") }
        }
    }
    /// Accept simulated gestures too (labeled). Off by default: system control should follow the real band.
    var acceptSimulated = false
    private(set) var history: [Sent] = []
    private(set) var switchControlRunning = UIAccessibility.isSwitchControlRunning
    let bridge = BCIBridgeClient()
    @ObservationIgnored private var encoder = IntentEncoder()
    @ObservationIgnored private var mappings: [Wrist: IntentMapping]
    private(set) var mappingRevision = 0
    private let band: BandClient

    init(band: BandClient) {
        self.band = band
        mappings = Self.loadMappings()
        let stream = band.events.subscribe()
        Task { @MainActor [weak self] in
            for await event in stream {
                if case .gesture(let gesture) = event { self?.handle(gesture) }
            }
        }
        NotificationCenter.default.addObserver(forName: UIAccessibility.switchControlStatusDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.switchControlRunning = UIAccessibility.isSwitchControlRunning }
        }
    }

    func mapping(for wrist: Wrist) -> IntentMapping { mappings[wrist] ?? .default }

    func setAction(_ action: BCIAction?, for gesture: RecognizedGesture, wrist: Wrist) {
        var mapping = self.mapping(for: wrist)
        mapping.actions[gesture] = action
        mappings[wrist] = mapping
        mappingRevision += 1
        saveMappings()
        logInfo(.app, "Mapping (\(wrist.rawValue)): \(gesture.title) → \(action?.title ?? "nothing")")
    }

    func restoreDefaultMapping(for wrist: Wrist) {
        mappings[wrist] = .default
        mappingRevision += 1
        saveMappings()
    }

    private func handle(_ event: GestureEvent) {
        guard forwarding else { return }
        guard event.source == .band || (event.source == .simulated && acceptSimulated) else { return }
        guard let (action, reports) = encoder.reports(for: event.gesture, mapping: mapping(for: band.wrist.wrist)) else { return }
        var delivered = false
        for report in reports { delivered = bridge.send(report) || delivered }
        history.insert(Sent(gesture: event.gesture, action: action, reports: reports, source: event.source, delivered: delivered), at: 0)
        if history.count > 50 { history.removeLast() }
        logNotice(.app, "System control: \(event.gesture.title) → \(action.title) [button \(action.buttonIndex)] \(reports.map(\.description).joined(separator: ", ")) → \(delivered ? "sent to bridge" : "preview only (no bridge)")\(event.source == .simulated ? " SIMULATED" : "")")
    }

    /// Releases every HID button and stops forwarding.
    func emergencyStop(reason: String = "emergency stop") {
        let report = encoder.releaseAll()
        let sent = bridge.send(report)
        if forwarding { forwarding = false }
        logWarning(.app, "System control stopped (\(reason)): all buttons released \(report) \(sent ? "on the bridge" : "(no bridge)")")
    }

    private static let key = "systemcontrol.mappings.v1"

    private static func loadMappings() -> [Wrist: IntentMapping] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: IntentMapping].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in Wrist(rawValue: key).map { ($0, value) } })
    }

    private func saveMappings() {
        let encoded = Dictionary(uniqueKeysWithValues: mappings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encoded) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
