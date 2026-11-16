import BandLogging
import BandTransport
@preconcurrency import CoreBluetooth
import DongleProtocol
import Foundation
import Observation
import UIKit

/// The ESP32 dongle's control service ("NP Band Remote"). iOS already holds the dongle's link for
/// the HID remote; the app attaches to it (or scans for the control service) while it's in the
/// foreground, and keeps it in the background only while something needs it (an update, a profile
/// upload, the status Live Activity). Nothing is remembered between launches.
@MainActor
@Observable
final class DongleLink: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    enum State: Equatable {
        case idle
        case bluetooth(String)
        case searching
        case connecting
        case discovering
        case ready
        case failed(String)

        var title: String {
            switch self {
            case .idle: "Not connected"
            case .bluetooth(let state): "Bluetooth \(state)"
            case .searching: "Looking for the dongle…"
            case .connecting: "Connecting…"
            case .discovering: "Opening the control service…"
            case .ready: "Connected"
            case .failed: "Problem"
            }
        }
    }

    static let service = CBUUID(string: DongleGATT.service)
    static let statusUUID = CBUUID(string: DongleGATT.status)
    static let statusNudge = Data("?".utf8)
    static let commandUUID = CBUUID(string: DongleGATT.command)
    static let logUUID = CBUUID(string: DongleGATT.log)
    static let updateUUID = CBUUID(string: DongleGATT.update)
    static let changedUUID = CBUUID(string: DongleGATT.changed)
    static let pairingAdvice = "iOS couldn't pair with the dongle. Open Settings › Bluetooth and connect “\(DongleGATT.advertisedName)”, then come back. (The dongle only accepts a new device while its pairing window is open: open one with Add a device on a phone that's already paired, or plug the dongle in again: for 2 minutes after it starts, the next new device may pair.)"
    static let logCapacity = 2000

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?() } }
    }
    private(set) var status: DongleStatus?
    private(set) var statusDate: Date?
    private(set) var peripheralName: String?
    /// Pairing failed: the control characteristics need an encrypted (bonded) link.
    private(set) var needsPairing = false
    private(set) var commandError: String?
    private(set) var logLines: [String] = []
    private(set) var logPending = ""

    @ObservationIgnored weak var updater: DongleUpdater?
    /// Every status read or notification (after the updater has seen it).
    @ObservationIgnored var onStatus: ((DongleStatus) -> Void)?
    /// The connection state changed.
    @ObservationIgnored var onStateChange: (() -> Void)?
    /// Completed log lines as they arrive.
    @ObservationIgnored var onLogLines: (([String]) -> Void)?
    /// Something besides the screen needs the link (checked when deciding to reconnect).
    @ObservationIgnored var keepConnected: () -> Bool = { false }
    @ObservationIgnored private var manager: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var characteristics: [CBUUID: CBCharacteristic] = [:]
    @ObservationIgnored private var pendingCommands: [(text: String, done: ((Error?) -> Void)?)] = []
    @ObservationIgnored private var assembler = DongleLogAssembler()
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var readingStatus = false
    @ObservationIgnored private var helloSent = false

    var isReady: Bool { state == .ready }

    // MARK: lifecycle

    /// The app is in the foreground: connect and poll Status every 1.5 s.
    func setActive(_ on: Bool) {
        #if DEBUG
        if simulated { return }
        #endif
        guard on != visible else { return }
        visible = on
        if on {
            if manager == nil {
                manager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: true])
                logInfo(.dongle, "Dongle central manager created")
            } else {
                connectIfNeeded()
            }
            let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
            readStatus()
        } else {
            pollTimer?.invalidate()
            pollTimer = nil
            if state == .searching, !keepConnected() {
                manager?.stopScan()
                state = .idle
            }
        }
    }

    /// Wants the dongle even while the app isn't polling (an update waiting for the reboot).
    private var wantsConnection: Bool { visible || updater?.needsLink == true || keepConnected() }

    func reconnect() {
        if let peripheral, peripheral.state != .disconnected { manager?.cancelPeripheralConnection(peripheral) }
        reset()
        peripheral = nil
        connectIfNeeded()
    }

    private func connectIfNeeded() {
        guard let manager, wantsConnection else { return }
        guard manager.state == .poweredOn else {
            state = .bluetooth(BandCentral.describe(manager.state))
            return
        }
        if let peripheral, peripheral.state == .connected || peripheral.state == .connecting { return }
        let known = peripheral ?? manager.retrieveConnectedPeripherals(withServices: [Self.service]).first
        if let known {
            if state == .searching { manager.stopScan() }
            attach(known)
            logNotice(.dongle, "Connecting to \(known.name ?? "dongle") (\(known.identifier)), iOS state \(known.state.rawValue)")
            manager.connect(known, options: nil)
        } else if state != .searching {
            state = .searching
            logInfo(.dongle, "No system-connected dongle; scanning for the control service")
            manager.scanForPeripherals(withServices: [Self.service], options: nil)
        }
    }

    private func attach(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        peripheralName = peripheral.name
        state = .connecting
    }

    private func reset() {
        characteristics.removeAll()
        let dropped = pendingCommands
        pendingCommands.removeAll()
        for command in dropped { command.done?(TransportError("The dongle disconnected.")) }
        readingStatus = false
        helloSent = false
    }

    private func poll() {
        guard visible, updater?.isStreaming != true else { return }
        if state == .ready { readStatus() } else if case .failed = state {} else { connectIfNeeded() }
    }

    // MARK: commands

    /// Writes a command (with response). `done` runs when the dongle acknowledged the write, or
    /// with the error (not connected included).
    func send(_ command: DongleCommand, done: ((Error?) -> Void)? = nil) {
        guard let peripheral, let characteristic = characteristics[Self.commandUUID], state == .ready else {
            commandError = "Not connected to the dongle."
            done?(TransportError("Not connected to the dongle."))
            return
        }
        commandError = nil
        pendingCommands.append((command.text, done))
        // Profile data is long and says nothing a person reads.
        if case .profilesData(let offset, let bytes) = command {
            logDebug(.dongle, "Command: profiles data \(offset) (\(bytes.count) B)")
        } else {
            logInfo(.dongle, "Command: \(command.text)")
        }
        peripheral.writeValue(command.data, for: characteristic, type: .withResponse)
    }

    #if DEBUG
    /// Simulator layout checks (`-NPDemo YES`): a connected dongle with this status, no radio.
    @ObservationIgnored private var simulated = false

    func simulate(_ status: DongleStatus) {
        simulated = true
        peripheralName = DongleGATT.advertisedName
        self.status = status
        statusDate = Date()
        state = .ready
        onStatus?(status)
    }
    #endif

    func readStatus() {
        guard let peripheral, let characteristic = characteristics[Self.statusUUID], !readingStatus else { return }
        readingStatus = true
        peripheral.readValue(for: characteristic)
    }

    func clearLog() {
        logLines.removeAll()
        logPending = ""
    }

    /// The dongle's log, for Copy and Share.
    var logText: String {
        var header = "NP Band Remote log, copied \(ISO8601DateFormatter().string(from: Date()))"
        if let status { header += "\nFirmware \(status.firmware) id \(status.buildID) slot \(status.slot) up \(status.uptime)s" }
        return ([header, ""] + logLines + (logPending.isEmpty ? [] : [logPending])).joined(separator: "\n") + "\n"
    }

    // MARK: update characteristic (for DongleUpdater)

    var maximumUpdateWrite: Int { peripheral?.maximumWriteValueLength(for: .withoutResponse) ?? 20 }
    var canSendUpdateData: Bool { peripheral?.canSendWriteWithoutResponse ?? false }

    @discardableResult
    func writeUpdate(_ data: Data, withResponse: Bool) -> Bool {
        guard let peripheral, let characteristic = characteristics[Self.updateUUID], state == .ready else { return false }
        peripheral.writeValue(data, for: characteristic, type: withResponse ? .withResponse : .withoutResponse)
        return true
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        logNotice(.dongle, "Bluetooth is \(BandCentral.describe(central.state)) (dongle central)")
        if central.state == .poweredOn {
            if case .bluetooth = state { state = .idle }
            connectIfNeeded()
        } else {
            peripheral = nil
            reset()
            state = .bluetooth(BandCentral.describe(central.state))
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.peripheral == nil || self.peripheral?.identifier == peripheral.identifier else { return }
        central.stopScan()
        attach(peripheral)
        peripheralName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        logNotice(.dongle, "Found \(peripheralName ?? "dongle") (\(peripheral.identifier)) rssi \(RSSI); connecting")
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral == self.peripheral else { return }
        logNotice(.dongle, "Connected to \(peripheral.name ?? "dongle"); discovering the control service")
        needsPairing = false
        state = .discovering
        reset()
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral == self.peripheral else { return }
        logError(.dongle, "Couldn't connect: \(error.map(BandLog.describe) ?? "no error given")")
        fail(error, fallback: "Couldn't connect to the dongle.")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral == self.peripheral else { return }
        logNotice(.dongle, "Dongle disconnected: \(error.map(BandLog.describe) ?? "requested")")
        reset()
        updater?.linkLost()
        if case .failed = state { return }
        state = .connecting
        // A pending connect has no timeout: it completes when the dongle is back (after a reboot, say).
        if wantsConnection { central.connect(peripheral, options: nil) } else { state = .idle }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { return fail(error, fallback: "Service discovery failed.") }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            return fail(nil, fallback: "This dongle has no control service. Its firmware is too old for this screen: update it once with the Chrome flasher.")
        }
        peripheral.discoverCharacteristics([Self.statusUUID, Self.commandUUID, Self.logUUID, Self.updateUUID, Self.changedUUID], for: service)
    }

    /// A firmware update that changed the GATT layout: iOS dropped its copy, so find the service again.
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard invalidatedServices.contains(where: { $0.uuid == Self.service }) else { return }
        logNotice(.dongle, "The dongle's services changed; discovering them again")
        characteristics.removeAll()
        state = .discovering
        peripheral.discoverServices([Self.service])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { return fail(error, fallback: "Characteristic discovery failed.") }
        for characteristic in service.characteristics ?? [] { characteristics[characteristic.uuid] = characteristic }
        let missing = [Self.statusUUID, Self.commandUUID, Self.logUUID, Self.updateUUID].filter { characteristics[$0] == nil }
        guard missing.isEmpty else {
            return fail(nil, fallback: "The control service is incomplete (missing \(missing.map(\.uuidString).joined(separator: ", "))). Update the dongle's firmware.")
        }
        logInfo(.dongle, "Control service ready (max write without response \(peripheral.maximumWriteValueLength(for: .withoutResponse)) B)")
        state = .ready
        // Touching an encrypted characteristic makes iOS pair (or reuse the HID bond) on its own.
        peripheral.setNotifyValue(true, for: characteristics[Self.logUUID]!)
        peripheral.setNotifyValue(true, for: characteristics[Self.updateUUID]!)
        // Firmware that notifies status changes keeps the Live Activity current in the background.
        if let changed = characteristics[Self.changedUUID] {
            peripheral.setNotifyValue(true, for: changed)
        } else if let status = characteristics[Self.statusUUID], status.properties.contains(.notify) {
            peripheral.setNotifyValue(true, for: status)
        }
        if !helloSent {
            helloSent = true
            send(.hello(name: UIDevice.current.name))
        }
        readStatus()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            logWarning(.dongle, "Notify on \(characteristic.uuid.uuidString) failed: \(BandLog.describe(error))")
            if Self.isPairingError(error) { fail(error, fallback: "") }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        switch characteristic.uuid {
        case Self.changedUUID:
            if error == nil { readStatus() }
        case Self.statusUUID:
            // A notification is only a nudge ("?", from 0.11): the whole status doesn't fit in one, so read it.
            if error == nil, characteristic.value == Self.statusNudge {
                readStatus()
                return
            }
            readingStatus = false
            if let error {
                logWarning(.dongle, "Status read failed: \(BandLog.describe(error))")
                if Self.isPairingError(error) { fail(error, fallback: "") }
                return
            }
            guard let value = characteristic.value else { return }
            do {
                let decoded = try DongleStatus.decode(value)
                status = decoded
                statusDate = Date()
                updater?.statusChanged(decoded)
                onStatus?(decoded)
            } catch {
                logWarning(.dongle, "Status isn't valid JSON (\(value.count) B): \(BandLog.describe(error))")
            }
        case Self.logUUID:
            guard error == nil, let value = characteristic.value else { return }
            let lines = assembler.feed(value)
            logLines += lines
            if logLines.count > Self.logCapacity { logLines.removeFirst(logLines.count - Self.logCapacity) }
            logPending = assembler.pending
            if !lines.isEmpty { onLogLines?(lines) }
        case Self.updateUUID:
            guard error == nil, let value = characteristic.value else { return }
            if let message = DongleUpdateMessage(value) {
                updater?.received(message)
            } else {
                logWarning(.dongle, "Unknown update notification \(value.prefix(8).map { String(format: "%02x", $0) }.joined())")
            }
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        switch characteristic.uuid {
        case Self.commandUUID:
            let command: (text: String, done: ((Error?) -> Void)?) = pendingCommands.isEmpty ? ("command", nil) : pendingCommands.removeFirst()
            let text = command.text.hasPrefix("profiles data") ? "profiles data" : command.text
            command.done?(error)
            if let error {
                logWarning(.dongle, "“\(text)” failed: \(BandLog.describe(error))")
                if Self.isPairingError(error) { return fail(error, fallback: "") }
                commandError = Self.isStaleLayout(error)
                    ? "iOS is using an old copy of the dongle's services, so commands land in the wrong place. Firmware 0.11.0 does this: update the dongle over USB (the Chrome flasher, or make flash)."
                    : "“\(text)” failed: \(error.localizedDescription)"
            } else if pendingCommands.isEmpty {
                readStatus()
            }
        case Self.updateUUID:
            updater?.updateWriteFinished(error)
        default:
            break
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        updater?.readyToSend()
    }

    // MARK: errors

    /// A write to a handle that's no longer the characteristic iOS thinks it is.
    static func isStaleLayout(_ error: Error) -> Bool {
        let native = error as NSError
        return native.domain == CBATTErrorDomain && [CBATTError.writeNotPermitted.rawValue, CBATTError.invalidHandle.rawValue].contains(native.code)
    }

    static func isPairingError(_ error: Error) -> Bool {
        let native = error as NSError
        if native.domain == CBATTErrorDomain {
            return [CBATTError.insufficientEncryption.rawValue, CBATTError.insufficientAuthentication.rawValue,
                    CBATTError.insufficientAuthorization.rawValue, CBATTError.insufficientEncryptionKeySize.rawValue].contains(native.code)
        }
        if native.domain == CBErrorDomain {
            return [CBError.peerRemovedPairingInformation.rawValue, CBError.encryptionTimedOut.rawValue].contains(native.code)
        }
        return false
    }

    private func fail(_ error: Error?, fallback: String) {
        if let error, Self.isPairingError(error) {
            needsPairing = true
            state = .failed(Self.pairingAdvice)
        } else {
            state = .failed(error.map { "\(fallback) \($0.localizedDescription)".trimmingCharacters(in: .whitespaces) } ?? fallback)
        }
        logError(.dongle, "Dongle link failed: \(error.map(BandLog.describe) ?? fallback)")
        updater?.linkLost()
        if let peripheral, peripheral.state != .disconnected { manager?.cancelPeripheralConnection(peripheral) }
        reset()
    }
}
