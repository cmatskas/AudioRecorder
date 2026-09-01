// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AudioRecorder",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        // AWS SDK is used only by AudioRecorderInsights; the recording core
        // (AudioRecorderCore) must stay dependency-free. Transcribe streaming
        // deliberately does NOT use the SDK: its HTTP/2 event stream buffers
        // results until end of input, so the app speaks the WebSocket API
        // directly (see TranscribeStreamer).
        .package(url: "https://github.com/awslabs/aws-sdk-swift.git", exact: "1.7.72")
    ],
    targets: [
        .target(
            name: "AudioRecorderCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "AudioRecorderInsights",
            dependencies: [
                "AudioRecorderCore",
                .product(name: "AWSBedrockRuntime", package: "aws-sdk-swift"),
                .product(name: "AWSSTS", package: "aws-sdk-swift"),
                .product(name: "AWSSDKIdentity", package: "aws-sdk-swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AudioRecorder",
            dependencies: ["AudioRecorderCore", "AudioRecorderInsights"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AudioRecorderCoreTests",
            dependencies: ["AudioRecorderCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AudioRecorderInsightsTests",
            dependencies: ["AudioRecorderInsights"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
