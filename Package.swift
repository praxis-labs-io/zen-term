// swift-tools-version: 6.2
import PackageDescription

// Tools 6.2 is only for `.treatWarning`; no target compiles in Swift 6 language mode yet.
let swift5 = SwiftSetting.swiftLanguageMode(.v5)

// Swift 5 mode only warns on an isolation violation inside a closure; this makes it a build error.
let mainThreadEnforced: [SwiftSetting] = [
    swift5,
    .treatWarning("ActorIsolatedCall", as: .error),
]

let package = Package(
    name: "ZenTerm",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "Frameworks/GhosttyKit.xcframework"
        ),
        .target(
            name: "TerminalKit",
            dependencies: [
                "GhosttyKit",
                "AppLog",
            ],
            resources: [
                .copy("Resources/ghostty-resources"),
                .copy("Resources/passthrough.glsl"),
            ],
            swiftSettings: mainThreadEnforced,
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
            name: "AppLog",
            swiftSettings: mainThreadEnforced
        ),
        .target(
            name: "PaneKit",
            dependencies: ["TerminalKit"],
            swiftSettings: mainThreadEnforced
        ),
        .target(
            name: "TabKit",
            swiftSettings: mainThreadEnforced
        ),
        .executableTarget(
            name: "ZenTerm",
            dependencies: [
                "TerminalKit", "PaneKit", "TabKit", "AppLog",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [
                .copy("Resources"),
                .copy("Themes"),
                .copy("Shaders"),
            ],
            swiftSettings: mainThreadEnforced,
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
            swiftSettings: mainThreadEnforced + [.defaultIsolation(MainActor.self)]
        ),
    ]
)
