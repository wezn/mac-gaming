// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "mg",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MGCore", targets: ["MGCore"]),
        .executable(name: "mg", targets: ["mg"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Everything a GUI front end needs: no dependencies beyond Foundation.
        .target(name: "MGCore"),
        // Thin CLI over MGCore.
        .executableTarget(
            name: "mg",
            dependencies: [
                "MGCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "MGCoreTests",
            dependencies: ["MGCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
