// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AlbumerCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "AlbumerCore", targets: ["AlbumerCore"])],
    targets: [
        .target(name: "AlbumerCore", path: "Sources/Albumer",
                exclude: ["AlbumerApp.swift", "UI", "Resources"],
                sources: ["Core", "AppModel.swift", "ImageStore.swift", "FixtureSpotifyService.swift"]),
        .testTarget(name: "AlbumerCoreTests", dependencies: ["AlbumerCore"], path: "Tests/AlbumerTests")
    ]
)

