// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DSHClient",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DSHKit", targets: ["DSHKit"]),
        .library(name: "DSHProtocol", targets: ["DSHProtocol"]),
        .library(name: "DSHSession", targets: ["DSHSession"]),
    ],
    targets: [
        .target(name: "DSHProtocol"),
        .target(name: "DSHSession", dependencies: ["DSHProtocol"]),
        .target(name: "DSHKit", dependencies: ["DSHProtocol"]),
        .testTarget(name: "DSHKitTests", dependencies: ["DSHKit", "DSHProtocol"]),
        .testTarget(name: "DSHProtocolTests", dependencies: ["DSHProtocol"]),
        .testTarget(name: "DSHSessionTests", dependencies: ["DSHSession", "DSHProtocol"]),
    ],
    swiftLanguageModes: [.v5]
)
