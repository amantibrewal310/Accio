// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Accio",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Accio", targets: ["Accio"])
    ],
    targets: [
        .executableTarget(
            name: "Accio",
            path: "Sources/Accio",
            // Optimise for size; the app does little heavy computation.
            swiftSettings: [.unsafeFlags(["-Osize"])]
        )
    ]
)
