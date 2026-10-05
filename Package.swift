// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NotchApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NotchApp", targets: ["NotchApp"])
    ],
    targets: [
        .executableTarget(
            name: "NotchApp",
            path: "Sources/NotchApp"
        )
    ]
)
