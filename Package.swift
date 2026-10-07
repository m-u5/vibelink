// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VibeLink",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "vibelink", targets: ["vibelink"]),
        .executable(name: "VibeLinkApp", targets: ["VibeLinkApp"]),
    ],
    targets: [
        .target(name: "VibeLinkCore"),
        .executableTarget(name: "vibelink", dependencies: ["VibeLinkCore"]),
        .executableTarget(name: "VibeLinkApp", dependencies: ["VibeLinkCore"]),
        .testTarget(name: "VibeLinkCoreTests", dependencies: ["VibeLinkCore"]),
    ]
)
