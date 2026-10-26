// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenLift",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "OpenLift", targets: ["OpenLift"]),
        .executable(name: "OpenLiftSelfTest", targets: ["OpenLiftSelfTest"])
    ],
    targets: [
        .target(
            name: "OpenLiftCore",
            path: "Sources/OpenLiftCore"
        ),
        .target(
            name: "OpenLiftUI",
            dependencies: ["OpenLiftCore"],
            path: "Sources/OpenLiftUI"
        ),
        .target(
            name: "OpenLiftApp",
            dependencies: ["OpenLiftCore", "OpenLiftUI"],
            path: "Sources/OpenLiftApp"
        ),
        .executableTarget(
            name: "OpenLift",
            dependencies: ["OpenLiftCore", "OpenLiftUI", "OpenLiftApp"],
            path: "Sources/OpenLift"
        ),
        // Runs the same checks as Tests/OpenLiftTests without XCTest, which
        // requires a full Xcode install. Once Xcode is present the XCTest
        // target in Tests/OpenLiftTests can be re-enabled in this manifest.
        .executableTarget(
            name: "OpenLiftSelfTest",
            dependencies: ["OpenLiftCore"],
            path: "Tests/OpenLiftSelfTest"
        ),
        .executableTarget(
            name: "OpenLiftBench",
            dependencies: ["OpenLiftCore"],
            path: "Sources/OpenLiftBench"
        )
    ]
)
