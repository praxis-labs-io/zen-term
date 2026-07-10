// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZenTerm",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.13.0"),
    ],
    targets: [
        // libghostty as a prebuilt static-library xcframework (ZEN-40 spike). Built from
        // source via bin/build-ghosttykit; gitignored, rebuilt per machine.
        .binaryTarget(
            name: "GhosttyKit",
            path: "Frameworks/GhosttyKit.xcframework"
        ),
        .target(
            name: "TerminalKit",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                "GhosttyKit",
            ],
            // libghostty's runtime resources (shell-integration, themes, terminfo),
            // staged from the pinned vendor/ghostty build by bin/build-ghosttykit.
            // Gitignored like the xcframework — both come from the same script run.
            resources: [.copy("Resources/ghostty-resources")],
            // A static-library xcframework carries no link metadata, so the frameworks
            // libghostty's objects reference must be linked by the consumer. This set is
            // what Ghostty's own macOS app links; over-linking is harmless.
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("IOSurface"),
                .linkedFramework("IOKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "PaneKit",
            dependencies: ["TerminalKit"]   // seam type only — NOT SwiftTerm
        ),
        .target(
            name: "TabKit"                   // pure — no AppKit, no SwiftTerm
        ),
        // A second TerminalSurface backend: a WKWebView pane. Depends on TerminalKit
        // for the seam type only (like PaneKit) — NOT SwiftTerm — and links WebKit.
        .target(
            name: "WebPaneKit",
            dependencies: ["TerminalKit"],
            linkerSettings: [.linkedFramework("WebKit")]
        ),
        .executableTarget(
            name: "ZenTerm",
            dependencies: ["TerminalKit", "PaneKit", "TabKit", "WebPaneKit"],  // still no SwiftTerm
            resources: [.copy("Resources")]  // brand marks (GitHub, git) SVGs for the dock
        ),
        .testTarget(
            name: "TerminalKitTests",
            dependencies: ["TerminalKit"]
        ),
        .testTarget(
            name: "PaneKitTests",
            dependencies: ["PaneKit", "TerminalKit"]
        ),
        .testTarget(
            name: "TabKitTests",
            dependencies: ["TabKit"]
        ),
        .testTarget(
            name: "ZenTermTests",
            dependencies: ["ZenTerm"]
        ),
    ]
)
