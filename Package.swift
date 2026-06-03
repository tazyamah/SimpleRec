// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SimpleRec",
    platforms: [
        .macOS(.v14)            // WhisperKit requires macOS 14+
    ],
    dependencies: [
        // Argmax Open-Source SDK (WhisperKit). The legacy argmaxinc/WhisperKit
        // URL redirects to argmax-oss-swift.
        .package(url: "https://github.com/argmaxinc/WhisperKit.git",
                 .upToNextMinor(from: "1.0.0"))
    ],
    targets: [
        .executableTarget(
            name: "SimpleRec",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/SimpleRec"
        )
    ]
)
