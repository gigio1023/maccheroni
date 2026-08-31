// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MaccheroniOfflineSpeechRuntime",
    platforms: [
        .macOS("15.0"),
    ],
    products: [
        .executable(
            name: "maccheroni-offline-speech-runtime",
            targets: ["MaccheroniOfflineSpeechRuntime"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/soniqo/speech-swift.git",
            revision: "c1aa219bc2284239ff6917d675a3e1978c840260"
        ),
    ],
    targets: [
        .executableTarget(
            name: "MaccheroniOfflineSpeechRuntime",
            dependencies: [
                .product(name: "AudioCommon", package: "speech-swift"),
                .product(name: "SpeechVAD", package: "speech-swift"),
            ]
        ),
    ]
)
