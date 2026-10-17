// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FolderChatExample",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "FolderChat",
            dependencies: [
                .product(name: "DSHKit", package: "dsh-swift"),
                .product(name: "DSHProtocol", package: "dsh-swift"),
                .product(name: "DSHSession", package: "dsh-swift"),
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
