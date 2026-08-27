// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioRecorder",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .target(
            name: "AudioRecorderCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AudioRecorder",
            dependencies: ["AudioRecorderCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AudioRecorderCoreTests",
            dependencies: ["AudioRecorderCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
