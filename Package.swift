// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StickIt",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "StickIt",
            path: "Sources/StickIt",
            resources: [.copy("Resources")]
        )
    ]
)
