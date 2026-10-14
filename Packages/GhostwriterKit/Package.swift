// swift-tools-version: 6.2
import PackageDescription

let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "GhostwriterKit",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "GWCore", targets: ["GWCore"]),
        .library(name: "Inference", targets: ["Inference"]),
        .library(name: "Prompting", targets: ["Prompting"]),
        .library(name: "Memory", targets: ["Memory"]),
        .library(name: "Capture", targets: ["Capture"]),
        .library(name: "Input", targets: ["Input"]),
        .library(name: "Overlay", targets: ["Overlay"]),
        .library(name: "ScreenContext", targets: ["ScreenContext"]),
        .library(name: "Actions", targets: ["Actions"]),
        .library(name: "Proofing", targets: ["Proofing"]),
        .executable(name: "gw-eval", targets: ["gw-eval"]),
        .executable(name: "gw-axprobe", targets: ["gw-axprobe"]),
        .executable(name: "gw-inputprobe", targets: ["gw-inputprobe"]),
        .executable(name: "gw-ctxprobe", targets: ["gw-ctxprobe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.0"),
    ],
    targets: [
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11559/llama-b11559-xcframework.zip",
            checksum: "433c3326bf21c6e98cbf075c624aba5c42b9432291d758722bb29b29fe33a700"
        ),
        .target(name: "GWCore", swiftSettings: swift6),
        .target(
            name: "Inference",
            dependencies: ["GWCore", "llama"],
            // Beam search runs in Swift over the full vocabulary each step: unoptimized it is several times slower,
            // which makes Debug builds of the app unusable for judging latency.
            swiftSettings: swift6 + [.unsafeFlags(["-O"], .when(configuration: .debug))]
        ),
        .target(name: "Prompting", dependencies: ["GWCore"], swiftSettings: swift6),
        .target(
            name: "Memory",
            dependencies: ["GWCore", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: swift6
        ),
        .target(name: "Capture", dependencies: ["GWCore"], swiftSettings: swift6),
        .target(name: "Input", dependencies: ["GWCore"], swiftSettings: swift6),
        .target(name: "Overlay", dependencies: ["GWCore"], swiftSettings: swift6),
        .target(name: "ScreenContext", dependencies: ["GWCore"], swiftSettings: swift6),
        .target(name: "Actions", dependencies: ["GWCore"], swiftSettings: swift6),
        .target(name: "Proofing", dependencies: ["GWCore"], swiftSettings: swift6),
        .executableTarget(
            name: "gw-eval",
            dependencies: ["GWCore", "Inference", "Input", "Prompting", "Proofing", "Actions"],
            swiftSettings: swift6
        ),
        .executableTarget(name: "gw-axprobe", dependencies: ["GWCore", "Capture"], swiftSettings: swift6),
        .executableTarget(name: "gw-inputprobe", dependencies: ["GWCore", "Input", "Overlay"], swiftSettings: swift6),
        .executableTarget(name: "gw-ctxprobe", dependencies: ["GWCore", "ScreenContext", "Actions"], swiftSettings: swift6),
        .testTarget(name: "InferenceTests", dependencies: ["Inference"], swiftSettings: swift6),
        .testTarget(name: "PromptingTests", dependencies: ["Prompting"], swiftSettings: swift6),
        .testTarget(name: "MemoryTests", dependencies: ["Memory"], swiftSettings: swift6),
        .testTarget(name: "InputTests", dependencies: ["Input"], swiftSettings: swift6),
        .testTarget(name: "CaptureTests", dependencies: ["Capture"], swiftSettings: swift6),
        .testTarget(name: "OverlayTests", dependencies: ["Overlay"], swiftSettings: swift6),
        .testTarget(name: "ActionsTests", dependencies: ["Actions"], swiftSettings: swift6),
        .testTarget(name: "ProofingTests", dependencies: ["Proofing"], swiftSettings: swift6),
        .testTarget(name: "ScreenContextTests", dependencies: ["ScreenContext"], swiftSettings: swift6),
    ]
)
