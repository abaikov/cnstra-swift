// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CNStra",
    platforms: [
        .iOS(.v14), .macOS(.v11), .tvOS(.v14), .watchOS(.v7)
    ],
    products: [
        .library(name: "CNStra", targets: ["CNStra"])
    ],
    targets: [
        .target(name: "CNStra", path: "Sources/CoreSwift"),
        .testTarget(name: "CoreSwiftTests", dependencies: ["CNStra"], path: "Tests/CoreSwiftTests")
    ]
)


