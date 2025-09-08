// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CNStraSwift",
    platforms: [
        .iOS(.v14), .macOS(.v11), .tvOS(.v14), .watchOS(.v7)
    ],
    products: [
        .library(name: "CNStraSwift", targets: ["CNStraSwift"])
    ],
    targets: [
        .target(name: "CNStraSwift", path: "Sources/CoreSwift"),
        .testTarget(name: "CoreSwiftTests", dependencies: ["CNStraSwift"], path: "Tests/CoreSwiftTests")
    ]
)


