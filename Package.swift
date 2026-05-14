// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LiveKitNative",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
    ],
    products: [
        .library(
            name: "LiveKitNative",
            targets: ["LiveKitNative"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-protobuf.git",
            from: "1.31.0"
        ),
    ],
    targets: [
        .target(
            name: "LiveKitNative",
            dependencies: [
                "LiveKitNativeProtocol",
                "LiveKitNativeWebRTC",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            resources: [
                .process("PrivacyInfo.xcprivacy"),
            ]
        ),
        .target(
            name: "LiveKitNativeProtocol",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            exclude: [
                "Generated/README.md",
                "Generated/livekit-protocol-revision.txt",
            ]
        ),
        .target(
            name: "LiveKitNativeWebRTC",
            linkerSettings: [
                .linkedFramework("AVFoundation", .when(platforms: [.iOS, .macOS])),
                .linkedFramework("AudioToolbox", .when(platforms: [.iOS, .macOS])),
                .linkedFramework("CoreMedia", .when(platforms: [.iOS, .macOS])),
                .linkedFramework("Network", .when(platforms: [.iOS, .macOS])),
                .linkedFramework("Security", .when(platforms: [.iOS, .macOS])),
                .linkedFramework("VideoToolbox", .when(platforms: [.iOS, .macOS])),
            ]
        ),
        .testTarget(
            name: "LiveKitNativeTests",
            dependencies: [
                "LiveKitNative",
                "LiveKitNativeProtocol",
                "LiveKitNativeWebRTC",
            ]
        ),
        .testTarget(
            name: "LiveKitNativeIntegrationTests",
            dependencies: [
                "LiveKitNative",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
