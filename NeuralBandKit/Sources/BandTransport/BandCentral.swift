import BandLogging
@preconcurrency import CoreBluetooth
import Foundation

/// GATT identifiers of the Meta Neural Band (from kinesis `BandConnection.swift`, verified on hardware).
public enum BandGATT {
    /// Meta's 16-bit service; its PSM characteristic reads `FF 00` (L2CAP PSM 255, little-endian).
    public static let service = CBUUID(string: "FEB8")
    public static let psmCharacteristic = CBUUID(string: "2D41DA7C-82B6-42AA-B34E-E2E01DF8CC1A")
    public static let batteryService = CBUUID(string: "180F")
    public static let batteryLevel = CBUUID(string: "2A19")
    public static let deviceInformation = CBUUID(string: "180A")

    public static func looksLikeBand(name: String?, services: [CBUUID]) -> Bool {
        (name?.lowercased().hasPrefix("meta band") ?? false) || services.contains(service)
    }
}

/// A device seen while scanning. Only public identifiers: iOS hides Bluetooth addresses.
public struct DiscoveredDevice: Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var rssi: Int?
    public var isConnectable: Bool?
    public var advertisedServices: [String]
    public var manufacturerData: String?
    public var lastSeen: Date
    public var isBand: Bool
    /// Already connected at the system level (bonded and in use by iOS or another app).
    public var systemConnected: Bool
}

/// The app-wide CoreBluetooth central. Everything runs on the main queue / main actor.
@MainActor
public final class BandCentral: NSObject, @preconcurrency CBCentralManagerDelegate {
    public private(set) var state: CBManagerState = .unknown
    public private(set) var authorization: CBManagerAuthorization = CBCentralManager.authorization
    public private(set) var discovered: [UUID: DiscoveredDevice] = [:]
    public private(set) var isScanning = false
    public var onChange: (() -> Void)?

    private var manager: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var links: [UUID: BandLink] = [:]
    private var whenPoweredOn: [() -> Void] = []

    public override init() {
        super.init()
        manager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: true])
        logInfo(.bluetooth, "Central manager created (authorization: \(Self.describe(authorization)))")
    }

    public var stateDescription: String { Self.describe(state) }

    public static func describe(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: "on"
        case .poweredOff: "off"
        case .unauthorized: "not allowed (Settings › Privacy › Bluetooth)"
        case .unsupported: "unsupported on this device"
        case .resetting: "resetting"
        case .unknown: "starting"
        @unknown default: "state \(state.rawValue)"
        }
    }

    public static func describe(_ authorization: CBManagerAuthorization) -> String {
        switch authorization {
        case .allowedAlways: "allowed"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not asked yet"
        @unknown default: "\(authorization.rawValue)"
        }
    }

    // MARK: scanning

    public func startScan() {
        guard state == .poweredOn else {
            logInfo(.bluetooth, "Scan requested while Bluetooth is \(stateDescription); will start when on")
            whenPoweredOn.append { [weak self] in self?.startScan() }
            return
        }
        // A bonded band in use by iOS may not advertise: list system-connected ones too.
        for peripheral in manager.retrieveConnectedPeripherals(withServices: [BandGATT.service]) {
            peripherals[peripheral.identifier] = peripheral
            var device = discovered[peripheral.identifier] ?? DiscoveredDevice(
                id: peripheral.identifier, name: peripheral.name ?? "Meta Band", rssi: nil, isConnectable: true,
                advertisedServices: [BandGATT.service.uuidString], manufacturerData: nil, lastSeen: Date(), isBand: true, systemConnected: true)
            device.systemConnected = true
            device.lastSeen = Date()
            discovered[peripheral.identifier] = device
            logInfo(.bluetooth, "System-connected band found: \(device.name) id \(peripheral.identifier)")
        }
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        isScanning = true
        logNotice(.bluetooth, "Scanning for nearby devices")
        onChange?()
    }

    public func stopScan() {
        guard isScanning else { return }
        manager.stopScan()
        isScanning = false
        logInfo(.bluetooth, "Scan stopped (\(discovered.values.filter(\.isBand).count) bands, \(discovered.count) devices seen)")
        onChange?()
    }

    public func clearDiscovered() {
        discovered.removeAll()
        onChange?()
    }

    // MARK: links

    /// Opens a link to a band by its CoreBluetooth identifier (from a scan, or remembered).
    public func openLink(to id: UUID, handler: @escaping @MainActor (TransportEvent) -> Void) -> BandLink {
        links[id]?.close(reason: "replaced by a new connection")
        let link = BandLink(id: id, central: self, handler: handler)
        links[id] = link
        let start = { [weak self, weak link] in
            guard let self, let link else { return }
            guard let peripheral = self.peripherals[id] ?? self.manager.retrievePeripherals(withIdentifiers: [id]).first else {
                logWarning(.bluetooth, "Band \(id) isn't known to iOS yet; scanning for it")
                link.waitingForDiscovery = true
                self.startScan()
                return
            }
            self.peripherals[id] = peripheral
            link.attach(peripheral)
            logNotice(.bluetooth, "Connecting to \(peripheral.name ?? "band") (\(id)), iOS state \(peripheral.state.rawValue)")
            self.manager.connect(peripheral, options: nil)
        }
        if state == .poweredOn { start() } else {
            logInfo(.bluetooth, "Link to \(id) waits for Bluetooth to turn on")
            whenPoweredOn.append(start)
        }
        return link
    }

    func cancel(_ peripheral: CBPeripheral) {
        if peripheral.state != .disconnected { manager.cancelPeripheralConnection(peripheral) }
    }

    func forget(_ link: BandLink) {
        if links[link.id] === link { links[link.id] = nil }
    }

    // MARK: CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state = central.state
        authorization = CBCentralManager.authorization
        logNotice(.bluetooth, "Bluetooth is \(stateDescription) (authorization \(Self.describe(authorization)))")
        if state == .poweredOn {
            let pending = whenPoweredOn
            whenPoweredOn.removeAll()
            pending.forEach { $0() }
        } else {
            isScanning = false
            for link in links.values { link.fail(TransportError("Bluetooth turned \(stateDescription)")) }
        }
        onChange?()
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let isBand = BandGATT.looksLikeBand(name: name, services: services)
        // Unnamed non-band devices are noise (beacons, phones); keep named ones for the "all devices" view.
        guard isBand || name != nil else { return }
        peripherals[peripheral.identifier] = peripheral
        let isNew = discovered[peripheral.identifier] == nil
        let manufacturer = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data).map { [UInt8]($0).prefix(4).map { String(format: "%02x", $0) }.joined() }
        let rssi = RSSI.intValue == 127 ? nil : RSSI.intValue
        discovered[peripheral.identifier] = DiscoveredDevice(
            id: peripheral.identifier, name: name ?? "Unnamed", rssi: rssi,
            isConnectable: (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue,
            advertisedServices: services.map(\.uuidString), manufacturerData: manufacturer, lastSeen: Date(), isBand: isBand,
            systemConnected: discovered[peripheral.identifier]?.systemConnected ?? false)
        if isNew {
            if isBand {
                logNotice(.bluetooth, "Found band \(name ?? "?") id \(peripheral.identifier) rssi \(rssi.map(String.init) ?? "?") services \(services.map(\.uuidString)) connectable \(String(describing: advertisementData[CBAdvertisementDataIsConnectable]))")
            } else {
                logDebug(.bluetooth, "Saw device \(name ?? "?") rssi \(rssi.map(String.init) ?? "?")")
            }
        }
        if let link = links[peripheral.identifier], link.waitingForDiscovery {
            link.waitingForDiscovery = false
            stopScan()
            link.attach(peripheral)
            logNotice(.bluetooth, "Band \(peripheral.identifier) found; connecting")
            manager.connect(peripheral, options: nil)
        }
        onChange?()
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        logNotice(.bluetooth, "Connected at the Bluetooth level to \(peripheral.name ?? "band")")
        links[peripheral.identifier]?.didConnect()
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        logError(.bluetooth, "Failed to connect: \(error.map(BandLog.describe) ?? "no error given")")
        links[peripheral.identifier]?.fail(error ?? TransportError("Could not connect to the band"))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logNotice(.bluetooth, "Disconnected from \(peripheral.name ?? "band"): \(error.map(BandLog.describe) ?? "requested")")
        links[peripheral.identifier]?.didDisconnect(error)
    }
}

public struct TransportError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
