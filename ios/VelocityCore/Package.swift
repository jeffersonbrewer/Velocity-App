// swift-tools-version:5.9
// The measurement engine shared by the iPhone app and a command-line tool used to check it
// against the Python prototype. It has no Apple-only dependencies, so it also builds and tests
// on Linux.
import PackageDescription

let package = Package(
    name: "VelocityCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "VelocityCore", targets: ["VelocityCore"]),
    ],
    targets: [
        .target(
            name: "VelocityCore",
            // Image processing is far too slow unoptimized, so optimize even in Debug builds.
            swiftSettings: [.unsafeFlags(["-O"])]
        ),
        .executableTarget(name: "vbt-cli", dependencies: ["VelocityCore"]),
        .testTarget(name: "VelocityCoreTests", dependencies: ["VelocityCore"]),
    ]
)
