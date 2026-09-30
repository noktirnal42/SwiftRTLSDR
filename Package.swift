// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftRTLSDR",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RTLSDRKit", targets: ["RTLSDRKit"]),
        .library(name: "RTLSDRScan", targets: ["RTLSDRScan"]),
        .library(name: "RTLSDRServer", targets: ["RTLSDRServer"]),
        .library(name: "RTLSDRDecoders", targets: ["RTLSDRDecoders"]),
        .executable(name: "rtlsdr-tool", targets: ["rtlsdr-tool"]),
    ],
    targets: [
        .target(name: "RTLSDRKit", swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "RTLSDRScan", dependencies: ["RTLSDRKit"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "RTLSDRServer", dependencies: ["RTLSDRKit"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(name: "RTLSDRDecoders", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(
            name: "rtlsdr-tool",
            dependencies: ["RTLSDRKit", "RTLSDRScan", "RTLSDRServer", "RTLSDRDecoders"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RTLSDRKitTests",
            dependencies: ["RTLSDRKit"],
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "RTLSDRScanTests", dependencies: ["RTLSDRScan"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "RTLSDRServerTests", dependencies: ["RTLSDRServer"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(
            name: "RTLSDRDecodersTests",
            dependencies: ["RTLSDRDecoders"],
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
