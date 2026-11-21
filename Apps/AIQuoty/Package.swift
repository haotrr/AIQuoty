// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIQuotyApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AIQuoty", targets: ["AIQuoty"]),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "AIQuoty",
            dependencies: [
                .product(name: "AIQuotyCore", package: "AIQuoty"),
            ],
            path: "Sources"
        ),
    ]
)
