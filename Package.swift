// swift-tools-version: 6.2
import PackageDescription

// Swift 5 language mode, pinned per target. The 6.2 tools-version is here only for
// `.treatWarning` below; left unpinned it would default every target to Swift 6 language
// mode, which is a migration this package hasn't done — no target compiles under it today.
// Pin stays until that migration is a ticket of its own.
let swift5 = SwiftSetting.swiftLanguageMode(.v5)

/// What every first-party target compiles with. The escalation is here rather than on one
/// target because it is half of a safety invariant, and a per-target copy is a per-target
/// chance to forget: a new chrome-side target, or config/keymap code moved into one, would
/// silently start with the off-main shape back to a warning nobody reads.
///
/// `@MainActor` alone does not hold. Swift 5 language mode hard-errors an isolation violation
/// in a synchronous function body but downgrades it to a warning inside a closure, which is
/// exactly the shape (`DispatchQueue.async { … }`) that killed the app in ZEN-17. Escalating
/// the diagnostic group is what makes both of those fail the build; removing it re-opens the
/// hole with everything still green. A `DispatchWorkItem` is type-erased at construction and
/// stays invisible even to this, which is why the TIS call carries a runtime precondition too
/// (ZEN-31; see docs/swift-conventions.md, "Carbon and the main thread").
let mainThreadEnforced: [SwiftSetting] = [
    swift5,
    .treatWarning("ActorIsolatedCall", as: .error),
]

let package = Package(
    name: "ZenTerm",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Auto-updates (ZEN-118). The project's first remote dependency; chrome-only, so it
        // rides on the ZenTerm target and never crosses the TerminalKit seam. Pinned by the
        // committed Package.resolved.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
        // Tree-sitter grammars + highlight queries for the diff viewer's syntax highlighting
        // (ZEN-239). A prebuilt xcframework bundling all v1 languages incl. Swift, so no generated
        // parser.c lives in this repo; pulls in SwiftTreeSitter. Chrome-only, rides on ZenTerm, never
        // crosses the TerminalKit seam. Pinned by Package.resolved.
        .package(url: "https://github.com/CodeEditApp/CodeEditLanguages", from: "0.1.21"),
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
            swiftSettings: mainThreadEnforced,
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
            name: "AppLog",                  // pure leaf — Foundation + os only, no backend, no chrome
            swiftSettings: mainThreadEnforced
        ),
        .target(
            name: "PaneKit",
            dependencies: ["TerminalKit"],  // seam types only — never the backend
            swiftSettings: mainThreadEnforced
        ),
        .target(
            name: "TabKit",                  // pure — no AppKit, no backend
            swiftSettings: mainThreadEnforced
        ),
        .executableTarget(
            name: "ZenTerm",
            dependencies: [
                "TerminalKit", "PaneKit", "TabKit", "AppLog",  // chrome — no backend
                .product(name: "Sparkle", package: "Sparkle"),  // auto-updates (ZEN-118), chrome-side
                // Syntax highlighting for the diff viewer (ZEN-239), chrome-side.
                .product(name: "CodeEditLanguages", package: "CodeEditLanguages"),
            ],
            resources: [
                .copy("Resources"),  // brand marks (GitHub, git, Linear, origami) SVGs for the dock + Settings
                .copy("Themes"),  // bundled ghostty theme catalog for the Settings theme picker
                .copy("Shaders"),  // bundled, vetted GLSL custom shaders selected by `custom-shader`
                // Tree-sitter highlight queries per language (ZEN-239). Loaded via the app's own safe
                // resource bundle rather than CodeEditLanguages' loader, whose Bundle.module path
                // resolves wrong in terminal-native SwiftPM. Grammars still come from CodeEditLanguages.
                .copy("SyntaxQueries"),
            ],
            swiftSettings: mainThreadEnforced,
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
            dependencies: ["TerminalKit"],
            swiftSettings: mainThreadEnforced
        ),
        .testTarget(
            name: "PaneKitTests",
            dependencies: ["PaneKit", "TerminalKit"],
            swiftSettings: mainThreadEnforced
        ),
        .testTarget(
            name: "TabKitTests",
            dependencies: ["TabKit"],
            swiftSettings: mainThreadEnforced
        ),
        .testTarget(
            name: "AppLogTests",
            dependencies: ["AppLog"],
            swiftSettings: mainThreadEnforced
        ),
        .testTarget(
            name: "ZenTermTests",
            dependencies: ["ZenTerm", "TabKit"],
            // XCTest runs these on the main thread and they drive AppKit views in real windows, so
            // main-actor is what this target already is. Declaring it here rather than annotating
            // every test class keeps the isolation the chrome now carries from costing ~180
            // `@MainActor`s across 22 files (ZEN-31).
            swiftSettings: mainThreadEnforced + [.defaultIsolation(MainActor.self)]
        ),
    ]
)
