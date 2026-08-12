// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Maccheroni",
    defaultLocalization: "en",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MaccheroniCore", targets: ["MaccheroniCore"]),
        .library(name: "MaccheroniPreprocess", targets: ["MaccheroniPreprocess"]),
        .library(name: "MaccheroniDiarize", targets: ["MaccheroniDiarize"]),
        .library(name: "MaccheroniASR", targets: ["MaccheroniASR"]),
        .library(name: "MaccheroniMerge", targets: ["MaccheroniMerge"]),
        .library(name: "MaccheroniPostprocess", targets: ["MaccheroniPostprocess"]),
        .library(name: "MaccheroniStorage", targets: ["MaccheroniStorage"]),
        .executable(name: "maccheroni", targets: ["MaccheroniCLI"]),
        .executable(name: "MaccheroniApp", targets: ["MaccheroniApp"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            exact: "1.8.2"
        ),
    ],
    targets: [
        .target(name: "MaccheroniCore"),
        .target(name: "MaccheroniPreprocess", dependencies: ["MaccheroniCore"]),
        .target(name: "MaccheroniDiarize", dependencies: ["MaccheroniCore"]),
        .target(
            name: "MaccheroniASR",
            dependencies: ["MaccheroniCore"],
            exclude: ["Python/.venv", "Python/__pycache__", "Python/tests"],
            resources: [
                .copy("Python/maccheroni_asr_runner.py"),
                .copy("Python/pyproject.toml"),
                .copy("Python/uv.lock"),
            ]
        ),
        .target(name: "MaccheroniMerge", dependencies: ["MaccheroniCore"]),
        .target(
            name: "MaccheroniPostprocess",
            dependencies: ["MaccheroniCore"],
            resources: [
                .process("Resources"),
                .copy("Python/maccheroni_postprocess_runner.py"),
                .copy("Python/pyproject.toml"),
                .copy("Python/uv.lock"),
            ],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .target(
            name: "MaccheroniStorage",
            dependencies: [
                "MaccheroniCore",
                "MaccheroniPreprocess",
                "MaccheroniDiarize",
                "MaccheroniASR",
                "MaccheroniPostprocess",
            ]
        ),
        .executableTarget(
            name: "MaccheroniCLI",
            dependencies: [
                "MaccheroniCore",
                "MaccheroniPreprocess",
                "MaccheroniDiarize",
                "MaccheroniASR",
                "MaccheroniMerge",
                "MaccheroniPostprocess",
                "MaccheroniStorage",
                .product(
                    name: "ArgumentParser",
                    package: "swift-argument-parser"
                ),
            ],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "MaccheroniApp",
            dependencies: [
                "MaccheroniCore",
                "MaccheroniPreprocess",
                "MaccheroniMerge",
                "MaccheroniPostprocess",
                "MaccheroniStorage",
            ],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "MaccheroniCoreTests", dependencies: ["MaccheroniCore"]),
        .testTarget(
            name: "MaccheroniPreprocessTests",
            dependencies: ["MaccheroniPreprocess"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "MaccheroniDiarizeTests",
            dependencies: ["MaccheroniDiarize"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "MaccheroniASRTests", dependencies: ["MaccheroniASR"]),
        .testTarget(name: "MaccheroniMergeTests", dependencies: ["MaccheroniMerge"]),
        .testTarget(
            name: "MaccheroniPostprocessTests",
            dependencies: ["MaccheroniPostprocess", "MaccheroniCore"]
        ),
        .testTarget(name: "MaccheroniStorageTests", dependencies: ["MaccheroniStorage"]),
        .testTarget(
            name: "MaccheroniCLITests",
            dependencies: [
                "MaccheroniCLI",
                "MaccheroniCore",
                "MaccheroniPreprocess",
                "MaccheroniDiarize",
                "MaccheroniASR",
                "MaccheroniMerge",
                "MaccheroniPostprocess",
                "MaccheroniStorage",
            ]
        ),
        .testTarget(
            name: "MaccheroniAppTests",
            dependencies: [
                "MaccheroniApp",
                "MaccheroniCore",
                "MaccheroniPreprocess",
                "MaccheroniMerge",
                "MaccheroniPostprocess",
                "MaccheroniStorage",
            ]
        ),
    ]
)
