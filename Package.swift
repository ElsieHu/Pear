// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Pear",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LyricEngine", targets: ["LyricEngine"]),
        .library(name: "AppleMusicBridge", targets: ["AppleMusicBridge"]),
        .executable(name: "PearApp", targets: ["PearApp"]),
    ],
    targets: [
        .target(name: "LyricEngine"),
        .target(name: "AppleMusicBridge", dependencies: ["LyricEngine"]),
        .executableTarget(name: "PearApp", dependencies: ["LyricEngine", "AppleMusicBridge"]),
        .testTarget(name: "LyricEngineTests", dependencies: ["LyricEngine"]),
        .testTarget(name: "AppleMusicBridgeTests", dependencies: ["AppleMusicBridge"]),
    ]
)
