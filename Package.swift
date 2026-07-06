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
        .executableTarget(
            name: "ZenTerm",
            dependencies: ["TerminalKit"]   // NOTE: no SwiftTerm — the seam is enforced here.
        ),
        .testTarget(
            name: "TerminalKitTests",
            dependencies: ["TerminalKit"]
        ),
    ]
)
