// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZenTerm",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.13.0"),
    ],
    targets: [
        .target(
            name: "TerminalKit",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .target(
            name: "PaneKit",
            dependencies: ["TerminalKit"]   // seam type only — NOT SwiftTerm
        ),
        .executableTarget(
            name: "ZenTerm",
            dependencies: ["TerminalKit", "PaneKit"]  // still no SwiftTerm
        ),
        .testTarget(
            name: "TerminalKitTests",
            dependencies: ["TerminalKit"]
        ),
        .testTarget(
            name: "PaneKitTests",
            dependencies: ["PaneKit", "TerminalKit"]
        ),
    ]
)
