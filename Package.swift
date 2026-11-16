// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "tatami",
    targets: [
        .target(name: "TatamiCore"),
        .executableTarget(
            name: "tatami", dependencies: ["TatamiCore"],
            // Private SkyLight calls, all in Sources/tatami/Private.swift.
            linkerSettings: [.unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"])]),
        // End-to-end tests against a real tatami and real windows: `swift run tatami-e2e`.
        .executableTarget(name: "tatami-e2e"),
        .testTarget(name: "TatamiCoreTests", dependencies: ["TatamiCore"]),
    ]
)
