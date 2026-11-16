// swift-tools-version: 6.0
import PackageDescription

// What the Bandit app shares with its tests:
//   BandLogging     – shared, redaction-disciplined log (copy/paste friendly)
//   BandTransport   – CoreBluetooth helpers
//   DongleProtocol  – sans-IO control protocol of the ESP32 dongle (status, commands, update stream)
let package = Package(
    name: "NeuralBandKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "BandLogging", targets: ["BandLogging"]),
        .library(name: "BandTransport", targets: ["BandTransport"]),
        .library(name: "DongleProtocol", targets: ["DongleProtocol"]),
    ],
    targets: [
        .target(name: "BandLogging"),
        .target(name: "BandTransport", dependencies: ["BandLogging"]),
        // The ESP32 dongle's control service (firmware/bandit/CONTROL.md). No band code involved.
        .target(name: "DongleProtocol"),
        .testTarget(name: "DongleProtocolTests", dependencies: ["DongleProtocol"]),
    ]
)
