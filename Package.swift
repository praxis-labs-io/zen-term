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
                "AppLog",  // diagnostic logging facade (ZEN-11); leaf, no backend
            ],
            // libghostty's runtime resources (shell-integration, themes, terminfo),
            // staged from the pinned vendor/ghostty build by bin/build-ghosttykit.
            // Gitignored like the xcframework — both come from the same script run.
            resources: [
                .copy("Resources/ghostty-resources"),
                // Stands in for the real cursor shader on an unfocused surface (ZEN-237);
                // below the seam because it exists only to work around a libghostty behavior.
                .copy("Resources/passthrough.glsl"),
            ],
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
            name: "AppLog"                   // pure leaf — Foundation + os only, no backend, no chrome
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
                "TerminalKit", "PaneKit", "TabKit", "AppLog",  // chrome — no backend
                .product(name: "Sparkle", package: "Sparkle"),  // auto-updates (ZEN-118), chrome-side
            ],
            resources: [
                .copy("Resources"),  // brand marks (GitHub, git, origami) SVGs for the dock + Settings
                .copy("Themes"),  // bundled ghostty theme catalog for the Settings theme picker
                .copy("Shaders"),  // bundled, vetted GLSL custom shaders selected by `custom-shader`
            ],
            // swift build links Sparkle.framework but doesn't embed it; the shipped bundle carries
            // it under Contents/Frameworks (bin/package-app), so the binary must resolve it there.
            // A `swift run`/`swift test` build has no ../Frameworks, but SwiftPM copies the framework
            // beside the built binary and @loader_path (also on the rpath) resolves it, so dev builds
            // need no extra setup.
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
            name: "AppLogTests",
            dependencies: ["AppLog"]
        ),
        .testTarget(
            name: "ZenTermTests",
            dependencies: ["ZenTerm", "TabKit"]
        ),
    ]
)
