// swift-tools-version: 6.0
import PackageDescription

// Joseon — real-time system audio analyzer for macOS (Apple silicon, Metal).
// DLMA layout: each layer is its own module and talks through JoseonCore contracts.
let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Joseon",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "Joseon", targets: ["JoseonApp"]),
        .executable(name: "joseon-probe", targets: ["JoseonProbe"]),
    ],
    targets: [
        // L0: contracts + DSP. No AppKit, no Core Audio, no Metal.
        .target(name: "JoseonCore", swiftSettings: swift5),
        // L1: system audio capture (Core Audio process tap).
        .target(name: "JoseonCapture", dependencies: ["JoseonCore"], swiftSettings: swift5),
        // L1: headphone frequency response model (AutoEQ data).
        // Curves are embedded as Swift source (no resource bundle: keeps the .app simple to sign).
        .target(name: "JoseonHeadphones", dependencies: ["JoseonCore"], swiftSettings: swift5),
        // L2: Metal renderers. Input is AnalysisFrame only.
        .target(name: "JoseonRender", dependencies: ["JoseonCore"], swiftSettings: swift5),
        // L3: app shell (windows, menu bar mini graph, settings).
        .executableTarget(
            name: "JoseonApp",
            dependencies: ["JoseonCore", "JoseonCapture", "JoseonHeadphones", "JoseonRender"],
            swiftSettings: swift5
        ),
        // Headless probe: capture N seconds, print analysis as JSON. Used by checks.
        .executableTarget(
            name: "JoseonProbe",
            dependencies: ["JoseonCore", "JoseonCapture", "JoseonHeadphones", "JoseonRender"],
            swiftSettings: swift5
        ),
        .testTarget(name: "JoseonCoreTests", dependencies: ["JoseonCore"], swiftSettings: swift5),
        .testTarget(name: "JoseonHeadphonesTests", dependencies: ["JoseonHeadphones"], swiftSettings: swift5),
        .testTarget(name: "JoseonRenderTests", dependencies: ["JoseonRender"], swiftSettings: swift5),
    ]
)
