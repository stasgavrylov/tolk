// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Tolk",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Tolk", targets: ["Tolk"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .target(name: "TolkCore"),
        .executableTarget(
            name: "Tolk",
            dependencies: ["TolkCore", "KeyboardShortcuts"]
        ),
        .executableTarget(name: "TolkSmoke", dependencies: ["TolkCore"]),
        .target(name: "TolkTestSupport", dependencies: ["TolkCore"], path: "Tests/TolkTestSupport"),
        .testTarget(name: "TolkCoreTests", dependencies: ["TolkCore", "TolkTestSupport"]),
        .testTarget(name: "TolkTests", dependencies: ["Tolk", "TolkTestSupport"]),
    ]
)
