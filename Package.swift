// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZenTerm",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Auto-updates (ZEN-118). The project's first remote dependency; chrome-only, so it
        // rides on the ZenTerm target and never crosses the TerminalKit seam. Pinned by the
        // committed Package.resolved.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
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
            dependencies: ["TerminalKit"]   // seam types only — never the backend
        ),
        .target(
            name: "TabKit"                   // pure — no AppKit, no backend
        ),
        .executableTarget(
            name: "ZenTerm",
            dependencies: [
                "TerminalKit", "PaneKit", "TabKit",  // chrome — no backend
                .product(name: "Sparkle", package: "Sparkle"),  // auto-updates (ZEN-118), chrome-side
            ],
            resources: [
                .copy("Resources"),  // brand marks (GitHub, git, origami) SVGs for the dock + Settings
                .copy("Themes"),  // bundled ghostty theme catalog for the Settings theme picker
            ],
            // swift build links Sparkle.framework but doesn't embed it; the shipped bundle carries
            // it under Contents/Frameworks (bin/package-app), so the binary must resolve it there.
            // A `swift run` build has no ../Frameworks — bin/run supplies DYLD_FRAMEWORK_PATH instead.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
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
            dependencies: ["ZenTerm", "TabKit"]
        ),
    ]
)
