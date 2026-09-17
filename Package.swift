// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AnkiLernassistent",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AnkiLernassistent", targets: ["AnkiLernassistent"])
    ],
    targets: [
        .executableTarget(
            name: "AnkiLernassistent",
            path: "Sources"
        )
    ]
)
