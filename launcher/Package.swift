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

#if os(macOS)
// The SwiftUI app (macOS only, so `swift build` / `swift test` keep working on Linux).
// `Scripts/make_app.sh` wraps the binary into MacGaming.app.
package.products.append(.executable(name: "MacGamingApp", targets: ["MacGamingApp"]))
package.targets.append(.executableTarget(name: "MacGamingApp", dependencies: ["MGCore"]))
#endif
