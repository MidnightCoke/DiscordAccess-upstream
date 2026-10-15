// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiscordAccess",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DiscordAccessKit", targets: ["DiscordAccessKit"]),
        .executable(name: "DiscordAccess", targets: ["DiscordAccess"]),
    ],
    targets: [
        .target(name: "DiscordAccessKit"),
        .executableTarget(name: "DiscordAccess", dependencies: ["DiscordAccessKit"]),
        .testTarget(name: "DiscordAccessKitTests", dependencies: ["DiscordAccessKit"], resources: [.copy("Fixtures")]),
    ],
    // Swift 5 language mode until the networking layers (Aşama 1c-1e) settle their concurrency model.
    swiftLanguageModes: [.v5]
)
