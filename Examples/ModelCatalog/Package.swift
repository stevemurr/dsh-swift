// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DSHModelCatalogExample",
    platforms: [.macOS(.v15)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "ModelCatalog",
            dependencies: [
                .product(name: "DSHKit", package: "dsh-swift"),
                .product(name: "DSHProtocol", package: "dsh-swift"),
                .product(name: "DSHSession", package: "dsh-swift"),
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
