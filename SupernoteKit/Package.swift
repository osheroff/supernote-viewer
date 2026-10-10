// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SupernoteKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "SupernoteKit", targets: ["SupernoteKit"]),
        .executable(name: "snrender", targets: ["snrender"]),
    ],
    targets: [
        .target(name: "SupernoteKit"),
        .executableTarget(name: "snrender", dependencies: ["SupernoteKit"]),
        .testTarget(name: "SupernoteKitTests", dependencies: ["SupernoteKit"]),
    ]
)
