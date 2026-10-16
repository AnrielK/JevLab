// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JevLabCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "JevLabCore", targets: ["JevLabCore"]),
    ],
    targets: [
        .target(name: "JevLabCore"),
        .testTarget(
            name: "JevLabCoreTests",
            dependencies: ["JevLabCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
