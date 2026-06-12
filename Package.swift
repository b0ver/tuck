// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tuck",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Tuck",
            path: "Sources/Tuck",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
