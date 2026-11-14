import BandLogging
@preconcurrency import CoreBluetooth
import Foundation

/// A discovered GATT characteristic, for diagnostics.
public struct GATTCharacteristicInfo: Sendable, Identifiable, Equatable {
    public var id: String { uuid }
    public let uuid: String
    public let properties: [String]
    /// Readable values from standard services (Device Information, Battery) only.
    public var value: String?
}

public struct GATTServiceInfo: Sendable, Identifiable, Equatable {
    public var id: String { uuid }
    public let uuid: String
    public let isPrimary: Bool
    public var characteristics: [GATTCharacteristicInfo]
}

public enum TransportEvent: Sendable {
    case stage(String)
    /// The PSM read is slow: iOS is very likely showing its "Bluetooth Pairing Request" alert.
    case systemPairingPrompt
    case gatt([GATTServiceInfo])
    /// Strings from the standard Device Information service (manufacturer, firmware revision, …).
    case deviceInformation([String: String])
    case batteryLevel(Int)
    case rssi(Int)
    case l2capOpened(psm: UInt16, maxWrite: Int)
    case bytes([UInt8])
    /// The link is gone. `nil` error: closed on request.
    case closed(Error?)
}

/// One connection to one band: GATT discovery, the bonding-triggering PSM read, and the L2CAP stream.
@MainActor
public final class BandLink: NSObject, @preconcurrency CBPeripheralDelegate, @preconcurrency StreamDelegate {
    public let id: UUID
    private weak var central: BandCentral?
    private var handler: (@MainActor (TransportEvent) -> Void)?
    private var peripheral: CBPeripheral?
    private var channel: CBL2CAPChannel?
    private var outgoing: [UInt8] = []
    private var services: [GATTServiceInfo] = []
    private var deviceInformation: [String: String] = [:]
    private var psmReadStartedAt: Date?
    private var pairingNoted = false
    private var timer: Timer?
    private var closed = false
    var waitingForDiscovery = false

    public private(set) var bytesRead = 0
    public private(set) var bytesWritten = 0
    public private(set) var psm: UInt16?
    public var peripheralName: String? { peripheral?.name }

    init(id: UUID, central: BandCentral, handler: @escaping @MainActor (TransportEvent) -> Void) {
        self.id = id
        self.central = central
        self.handler = handler
        super.init()
    }

    func attach(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        emit(.stage("Connecting over Bluetooth"))
    }

    private func emit(_ event: TransportEvent) { handler?(event) }

    func didConnect() {
        guard let peripheral, !closed else { return }
        emit(.stage("Discovering services"))
        logInfo(.bluetooth, "Discovering all GATT services (max write without response: \(peripheral.maximumWriteValueLength(for: .withoutResponse))B)")
        peripheral.discoverServices(nil)
        timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private var lastRSSIRead = Date.distantPast
    private var unknownValueCounts: [String: Int] = [:]

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            logDebug(.bluetooth, "Notify on \(characteristic.uuid.uuidString) failed: \(BandLog.describe(error))")
        } else {
            logInfo(.bluetooth, "Notifications \(characteristic.isNotifying ? "on" : "off") for \(characteristic.uuid.uuidString)")
        }
    }

    private func tick() {
        guard !closed else { return }
        if !pairingNoted, let started = psmReadStartedAt, Date().timeIntervalSince(started) > 1.5 {
            pairingNoted = true
            logNotice(.bluetooth, "PSM read is waiting >1.5 s: iOS is likely showing the Bluetooth pairing request")
            emit(.systemPairingPrompt)
        }
        if peripheral?.state == .connected, Date().timeIntervalSince(lastRSSIRead) >= 2 {
            lastRSSIRead = Date()
            peripheral?.readRSSI()
        }
    }

    /// Write bytes to the L2CAP stream (buffered until space is available).
    public func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty, !closed else { return }
        outgoing += bytes
        flush()
    }

    public func close(reason: String) {
        guard !closed else { return }
        logInfo(.bluetooth, "Closing link: \(reason)")
        teardown(error: nil)
    }

    func fail(_ error: Error) {
        guard !closed else { return }
        logError(.bluetooth, "Link failed: \(BandLog.describe(error))")
        teardown(error: Self.explain(error))
    }

    func didDisconnect(_ error: Error?) {
        guard !closed else { return }
        teardown(error: error.map(Self.explain) ?? TransportError("The band disconnected"), cancel: false)
    }

    private func teardown(error: Error?, cancel: Bool = true) {
        closed = true
        timer?.invalidate()
        timer = nil
        closeStreams()
        if cancel, let peripheral { central?.cancel(peripheral) }
        peripheral?.delegate = nil
        central?.forget(self)
        let handler = handler
        self.handler = nil
        handler?(.closed(error))
    }

    private func closeStreams() {
        guard let channel else { return }
        for stream in [channel.inputStream as Stream?, channel.outputStream as Stream?].compactMap({ $0 }) {
            stream.delegate = nil
            stream.close()
            stream.remove(from: .main, forMode: .common)
        }
        self.channel = nil
        logInfo(.l2cap, "L2CAP streams closed (\(bytesRead)B read, \(bytesWritten)B written)")
    }

    /// iOS reports a failed system pairing as an ATT security error. Translate it into advice.
    static func explain(_ error: Error) -> Error {
        let native = error as NSError
        if native.domain == CBATTErrorDomain {
            switch native.code {
            case CBATTError.insufficientEncryption.rawValue:
                return TransportError("iOS couldn't finish pairing with the band (ATT \(native.code)). If the band was reset or claimed elsewhere, open Settings › Bluetooth, tap ⓘ next to the band, choose Forget This Device, then pair again.")
            case CBATTError.insufficientAuthentication.rawValue, CBATTError.insufficientAuthorization.rawValue:
                return TransportError("iOS didn't finish pairing (ATT \(native.code)). Try again and tap Pair when the Bluetooth request appears.")
            default: break
            }
        }
        if native.domain == CBErrorDomain {
            switch native.code {
            case CBError.peerRemovedPairingInformation.rawValue:
                return TransportError("The band forgot its pairing with this iPhone. Open Settings › Bluetooth, Forget This Device on the band, put the band in pairing mode (hold ~3 s), and connect again.")
            case CBError.connectionTimeout.rawValue:
                return TransportError("The Bluetooth connection timed out. Keep the band close and awake, then retry.")
            case CBError.encryptionTimedOut.rawValue:
                return TransportError("Bluetooth encryption timed out. Accept the pairing request on the iPhone, or Forget the band in Settings › Bluetooth and retry.")
            default: break
            }
        }
        return error
    }

    // MARK: CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard !closed else { return }
        if let error { fail(error); return }
        let list = peripheral.services ?? []
        logInfo(.bluetooth, "Services: \(list.map { $0.uuid.uuidString })")
        services = list.map { GATTServiceInfo(uuid: $0.uuid.uuidString, isPrimary: $0.isPrimary, characteristics: []) }
        emit(.gatt(services))
        guard list.contains(where: { $0.uuid == BandGATT.service }) else {
            fail(TransportError("This device doesn't expose the band's FEB8 service. Is it a Meta Neural Band?"))
            return
        }
        emit(.stage("Discovering characteristics"))
        for service in list { peripheral.discoverCharacteristics(nil, for: service) }
    }

    private static func properties(_ value: CBCharacteristicProperties) -> [String] {
        var names: [String] = []
        if value.contains(.read) { names.append("read") }
        if value.contains(.write) { names.append("write") }
        if value.contains(.writeWithoutResponse) { names.append("writeNoResponse") }
        if value.contains(.notify) { names.append("notify") }
        if value.contains(.indicate) { names.append("indicate") }
        if value.contains(.authenticatedSignedWrites) { names.append("signedWrite") }
        if value.contains(.notifyEncryptionRequired) { names.append("notifyEncrypted") }
        if value.contains(.indicateEncryptionRequired) { names.append("indicateEncrypted") }
        return names
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard !closed else { return }
        if let error {
            logWarning(.bluetooth, "Characteristic discovery failed for \(service.uuid.uuidString): \(BandLog.describe(error))")
            if service.uuid == BandGATT.service { fail(error) }
            return
        }
        let characteristics = service.characteristics ?? []
        if let index = services.firstIndex(where: { $0.uuid == service.uuid.uuidString }) {
            services[index].characteristics = characteristics.map {
                GATTCharacteristicInfo(uuid: $0.uuid.uuidString, properties: Self.properties($0.properties), value: nil)
            }
        }
        logInfo(.bluetooth, "Service \(service.uuid.uuidString): \(characteristics.map { "\($0.uuid.uuidString)[\(Self.properties($0.properties).joined(separator: ","))]" })")
        emit(.gatt(services))
        for characteristic in characteristics {
            switch (service.uuid, characteristic.uuid) {
            case (BandGATT.service, BandGATT.psmCharacteristic):
                emit(.stage("Reading the input channel (iOS may ask to pair)"))
                psmReadStartedAt = Date()
                logInfo(.bluetooth, "Reading the PSM characteristic; this triggers bonding on a fresh band")
                peripheral.readValue(for: characteristic)
            case (BandGATT.batteryService, BandGATT.batteryLevel):
                if characteristic.properties.contains(.notify) { peripheral.setNotifyValue(true, for: characteristic) }
                peripheral.readValue(for: characteristic)
            case (BandGATT.deviceInformation, _) where characteristic.properties.contains(.read):
                peripheral.readValue(for: characteristic)
            default:
                // Undocumented characteristics (FEB8's 2D41DA7A, FD5F, …): read and subscribe for diagnostics.
                // Writes are never attempted.
                if characteristic.properties.contains(.read) { peripheral.readValue(for: characteristic) }
                // Subscribing writes a CCCD on the band, so it's opt-in (Diagnostics › verbose logging).
                if BandLog.shared.logsFrames, characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                    logInfo(.bluetooth, "Verbose mode: subscribing to \(characteristic.uuid.uuidString) notifications")
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            }
        }
        if service.uuid == BandGATT.service, !characteristics.contains(where: { $0.uuid == BandGATT.psmCharacteristic }) {
            fail(TransportError("The band's input channel characteristic is missing"))
        }
    }

    private static let deviceInformationNames: [String: String] = [
        "2A29": "Manufacturer", "2A24": "Model", "2A25": "Serial", "2A27": "Hardware revision",
        "2A26": "Firmware revision", "2A28": "Software revision", "2A23": "System ID", "2A50": "PnP ID",
    ]

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard !closed else { return }
        let uuid = characteristic.uuid
        if uuid == BandGATT.psmCharacteristic {
            psmReadStartedAt = nil
            if let error {
                logError(.bluetooth, "PSM read failed: \(BandLog.describe(error))")
                fail(error)
                return
            }
            guard let value = characteristic.value, value.count == 2 else {
                fail(TransportError("Unexpected input channel value (\(characteristic.value?.count ?? 0) bytes)"))
                return
            }
            let psm = UInt16(value[value.startIndex]) | UInt16(value[value.startIndex + 1]) << 8
            self.psm = psm
            logNotice(.l2cap, "PSM characteristic read: \(psm) (bytes \([UInt8](value).map { String(format: "%02x", $0) }.joined(separator: " "))); bonded. Opening L2CAP channel")
            emit(.stage("Opening the L2CAP channel"))
            peripheral.openL2CAPChannel(CBL2CAPPSM(psm))
            return
        }
        if let error {
            logDebug(.bluetooth, "Read of \(uuid.uuidString) failed: \(BandLog.describe(error))")
            return
        }
        guard let value = characteristic.value else { return }
        if uuid == BandGATT.batteryLevel, let level = value.first, level <= 100 {
            logDebug(.bluetooth, "GATT battery level \(level)%")
            emit(.batteryLevel(Int(level)))
            setValue(String(level) + "%", for: characteristic)
            return
        }
        if characteristic.service?.uuid != BandGATT.deviceInformation {
            let bytes = [UInt8](value)
            let hex = bytes.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
            let text = String(bytes: bytes, encoding: .utf8).flatMap { $0.allSatisfy { $0.isASCII && !$0.isNewline } && !$0.isEmpty ? " \"\($0)\"" : nil } ?? ""
            let count = (unknownValueCounts[uuid.uuidString] ?? 0) + 1
            unknownValueCounts[uuid.uuidString] = count
            if count <= 20 || count % 100 == 0 {
                logInfo(.bluetooth, "Characteristic \(characteristic.service?.uuid.uuidString ?? "?")/\(uuid.uuidString) value #\(count) (\(bytes.count)B): \(hex)\(bytes.count > 64 ? " …" : "")\(text)")
            }
            setValue("\(bytes.count)B \(bytes.prefix(16).map { String(format: "%02x", $0) }.joined())", for: characteristic)
            return
        }
        if characteristic.service?.uuid == BandGATT.deviceInformation {
            let name = Self.deviceInformationNames[uuid.uuidString] ?? uuid.uuidString
            // The serial string is masked; everything else is product/version text.
            let text = String(data: value, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters.union(.whitespaces))
            let shown = name == "Serial" ? text.map { BandLog.mask($0) } : (text?.isEmpty == false ? text : [UInt8](value).map { String(format: "%02x", $0) }.joined())
            deviceInformation[name] = shown
            setValue(shown, for: characteristic)
            logInfo(.bluetooth, "Device Information \(name): \(shown ?? "?")")
            emit(.deviceInformation(deviceInformation))
        }
    }

    private func setValue(_ text: String?, for characteristic: CBCharacteristic) {
        for service in services.indices {
            if let index = services[service].characteristics.firstIndex(where: { $0.uuid == characteristic.uuid.uuidString }) {
                services[service].characteristics[index].value = text
            }
        }
        emit(.gatt(services))
    }

    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil, !closed else { return }
        emit(.rssi(RSSI.intValue))
    }

    public func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard !closed else { return }
        if let error {
            logError(.l2cap, "L2CAP open failed: \(BandLog.describe(error))")
            fail(error)
            return
        }
        guard let channel else { fail(TransportError("Could not open the band's L2CAP channel")); return }
        self.channel = channel
        let maxWrite = peripheral.maximumWriteValueLength(for: .withoutResponse)
        logNotice(.l2cap, "L2CAP channel open on PSM \(channel.psm); scheduling streams on the main run loop")
        for stream in [channel.inputStream as Stream?, channel.outputStream as Stream?].compactMap({ $0 }) {
            stream.delegate = self
            stream.schedule(in: .main, forMode: .common)
            stream.open()
        }
        emit(.l2capOpened(psm: UInt16(channel.psm), maxWrite: maxWrite))
        flush()
    }

    // MARK: StreamDelegate

    // Streams are scheduled on the main run loop, so this always arrives on the main actor.
    public func stream(_ stream: Stream, handle eventCode: Stream.Event) {
        guard let channel, !closed, stream === channel.inputStream || stream === channel.outputStream else { return }
        if eventCode.contains(.errorOccurred) {
            fail(stream.streamError ?? TransportError("The band's L2CAP stream failed"))
            return
        }
        if eventCode.contains(.endEncountered) {
            logWarning(.l2cap, "L2CAP stream ended by the band")
            fail(TransportError("The band closed the connection"))
            return
        }
        if eventCode.contains(.openCompleted) {
            logDebug(.l2cap, "\(stream === channel.inputStream ? "Input" : "Output") stream open")
        }
        if eventCode.contains(.hasBytesAvailable) { readAvailable() }
        if eventCode.contains(.hasSpaceAvailable) { flush() }
    }

    private func readAvailable() {
        guard let input = channel?.inputStream else { return }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = input.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else {
            fail(input.streamError ?? TransportError("Could not read from the band"))
            return
        }
        guard count > 0 else { return }
        bytesRead += count
        emit(.bytes(Array(buffer.prefix(count))))
    }

    private func flush() {
        guard let output = channel?.outputStream, !closed else { return }
        while !outgoing.isEmpty, output.hasSpaceAvailable {
            let count = outgoing.withUnsafeBufferPointer { output.write($0.baseAddress!, maxLength: $0.count) }
            guard count >= 0 else {
                fail(output.streamError ?? TransportError("Could not write to the band"))
                return
            }
            guard count > 0 else { return }
            bytesWritten += count
            outgoing.removeFirst(count)
        }
    }
}
