// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIQuoty",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "AIQuotyCore", targets: ["AIQuotyCore"]),
        .executable(name: "aiquoty-cli", targets: ["AIQuotyCLI"]),
    ],
    targets: [
        .target(
            name: "AIQuotyCore",
            path: "Sources/AIQuotyCore"
        ),
        .executableTarget(
            name: "AIQuotyCLI",
            dependencies: ["AIQuotyCore"],
            path: "Sources/AIQuotyCLI"
        ),
        .testTarget(
            name: "AIQuotyCoreTests",
            dependencies: ["AIQuotyCore"],
            path: "Tests/AIQuotyCoreTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
