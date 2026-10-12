// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SaneScan",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SaneScan",
            path: "Sources/SaneScan"
        ),
        .testTarget(
            name: "SaneScanTests",
            dependencies: ["SaneScan"],
            path: "Tests/SaneScanTests"
        ),
    ]
)
