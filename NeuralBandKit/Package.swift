// swift-tools-version: 6.0
import PackageDescription

// The band SDK, layered so it can later be extracted on its own:
//   BandLogging     – shared, redaction-disciplined log (copy/paste friendly)
//   BandProtocol    – sans-IO protocol core (crypto, framing, session state machine, events)
//   BandCredentials – owner key storage (Keychain) and portable credential formats
//   BandTransport   – CoreBluetooth discovery, bonding and the L2CAP stream
//   BandAccessibility – Apple BCI HID descriptor/reports and gesture→intent mapping
//   BandKit         – the façade apps use: connection lifecycle, Meta ownership flow, event streams
//   DongleProtocol  – sans-IO control protocol of the ESP32 dongle (status, commands, update stream)
let package = Package(
    name: "NeuralBandKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "BandLogging", targets: ["BandLogging"]),
        .library(name: "BandProtocol", targets: ["BandProtocol"]),
        .library(name: "BandCredentials", targets: ["BandCredentials"]),
        .library(name: "BandTransport", targets: ["BandTransport"]),
        .library(name: "BandKit", targets: ["BandKit"]),
        .library(name: "BandAccessibility", targets: ["BandAccessibility"]),
        .library(name: "DongleProtocol", targets: ["DongleProtocol"]),
    ],
    targets: [
        .target(name: "BandLogging"),
        .target(name: "BandProtocol"),
        .target(name: "BandCredentials", dependencies: ["BandProtocol", "BandLogging"]),
        .target(name: "BandTransport", dependencies: ["BandLogging"]),
        .target(name: "BandKit", dependencies: ["BandProtocol", "BandCredentials", "BandTransport", "BandLogging"]),
        // Apple's BCI HID reports + gesture→intent mapping. Depends on gesture types only, not the band protocol.
        .target(name: "BandAccessibility", dependencies: ["BandProtocol"]),
        .testTarget(name: "BandAccessibilityTests", dependencies: ["BandAccessibility"]),
        // macOS hardware probe (see Sources/band-probe/main.swift); wrapped in an .app by Scripts/run-probe.sh.
        .executableTarget(name: "band-probe", dependencies: ["BandProtocol", "BandTransport", "BandLogging", "BandCredentials"]),
        .testTarget(name: "BandProtocolTests", dependencies: ["BandProtocol", "BandCredentials", "BandLogging"]),
        .testTarget(name: "BandKitTests", dependencies: ["BandKit", "BandProtocol"]),
        // The ESP32 dongle's control service (firmware/band-dongle/CONTROL.md). No band code involved.
        .target(name: "DongleProtocol"),
        .testTarget(name: "DongleProtocolTests", dependencies: ["DongleProtocol"]),
    ]
)
