// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AkaMemoCore",
    platforms: [
        .iOS(.v18),
        .watchOS(.v11),
        .macOS(.v14)
    ],
    products: [
        .library(name: "AkaMemoCore", targets: ["AkaMemoCore"])
    ],
    targets: [
        .target(name: "AkaMemoCore"),
        .testTarget(
            name: "AkaMemoCoreTests",
            dependencies: ["AkaMemoCore"]
        )
    ]
)
