// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TextRefiner",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "2.30.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.31.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "TextRefiner",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "Sources",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalPerformanceShaders"),
            ]
        )
    ]
)
