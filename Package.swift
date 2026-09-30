// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftRTLSDR",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RTLSDRKit", targets: ["RTLSDRKit"]),
        .executable(name: "rtlsdr-tool", targets: ["rtlsdr-tool"]),
    ],
    targets: [
        .target(name: "RTLSDRKit", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "rtlsdr-tool", dependencies: ["RTLSDRKit"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(
            name: "RTLSDRKitTests",
            dependencies: ["RTLSDRKit"],
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
