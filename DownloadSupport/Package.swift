// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DownloadSupport",
    platforms: [.iOS("18.0"), .macOS("13.0")],
    products: [
        .library(name: "DownloadSupport", targets: ["DownloadSupport"]),
    ],
    targets: [
        .target(name: "DownloadSupport"),
        .testTarget(name: "DownloadSupportTests", dependencies: ["DownloadSupport"]),
    ]
)
