// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "LyricFeverDirect",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LyricEngine", targets: ["LyricEngine"]),
        .library(name: "AppleMusicBridge", targets: ["AppleMusicBridge"]),
        .executable(name: "LyricFeverDirectApp", targets: ["LyricFeverDirectApp"]),
    ],
    targets: [
        .target(name: "LyricEngine"),
        .target(name: "AppleMusicBridge", dependencies: ["LyricEngine"]),
        .executableTarget(name: "LyricFeverDirectApp", dependencies: ["LyricEngine", "AppleMusicBridge"]),
        .testTarget(name: "LyricEngineTests", dependencies: ["LyricEngine"]),
        .testTarget(name: "AppleMusicBridgeTests", dependencies: ["AppleMusicBridge"]),
    ]
)
