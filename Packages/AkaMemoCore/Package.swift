// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AkaMemoCore",
    platforms: [
        .iOS(.v18),
        .watchOS(.v11),
        .macOS(.v14),
    ],
    products: [
        .library(name: "AkaMemoCore", targets: ["AkaMemoCore"])
    ],
    targets: [
        .target(
            name: "AkaMemoCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "AkaMemoCoreTests",
            dependencies: ["AkaMemoCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
    ]
)
