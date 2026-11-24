// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "HttpDownloadCore",
    platforms: [.iOS("18.0"), .macOS("13.0")],
    products: [
        .library(name: "HttpDownloadCore", targets: ["HttpDownloadCore"]),
    ],
    dependencies: [
        .package(path: "../DownloadSupport"),
    ],
    targets: [
        .target(name: "HttpDownloadCore", dependencies: ["DownloadSupport"]),
        .testTarget(name: "HttpDownloadCoreTests", dependencies: ["HttpDownloadCore"]),
    ]
)
