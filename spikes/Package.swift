// swift-tools-version: 6.0
import PackageDescription

// Phase 0 feasibility spikes: throwaway probes for the low-level
// primitives Accio depends on. See docs/spikes.md for results.
let package = Package(
    name: "AccioSpikes",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "spike",
            path: "Sources/Spike"
        )
    ]
)
