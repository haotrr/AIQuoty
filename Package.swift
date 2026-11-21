// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = [
    .library(name: "AIQuotyCore", targets: ["AIQuotyCore"]),
    .executable(name: "aiquoty-cli", targets: ["AIQuotyCLI"]),
]

var targets: [Target] = [
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

#if os(macOS)
products.append(
    .executable(name: "AIQuoty", targets: ["AIQuoty"])
)
targets.append(
    .executableTarget(
        name: "AIQuoty",
        dependencies: ["AIQuotyCore"],
        path: "Apps/AIQuoty/Sources"
    )
)
#endif

let package = Package(
    name: "AIQuoty",
    platforms: [
        .macOS(.v14),
    ],
    products: products,
    targets: targets
)
