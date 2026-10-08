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
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
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
        .target(
            name: "ControlProtocol",
            swiftSettings: mainThreadEnforced
        ),
        .executableTarget(
            name: "ZenTerm",
            dependencies: [
                "TerminalKit", "PaneKit", "TabKit", "AppLog", "ControlProtocol",
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
        .executableTarget(
            name: "zen",
            dependencies: [
                "ControlProtocol",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: mainThreadEnforced
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
            name: "ControlProtocolTests",
            dependencies: ["ControlProtocol"],
            swiftSettings: mainThreadEnforced
        ),
        .testTarget(
            name: "zenTests",
            dependencies: ["zen", "ControlProtocol"],
            swiftSettings: mainThreadEnforced
        ),
        .testTarget(
            name: "AppLogTests",
            dependencies: ["AppLog"],
            swiftSettings: mainThreadEnforced
        ),
        .testTarget(
            name: "ZenTermTests",
            dependencies: ["ZenTerm", "TabKit", "ControlProtocol"],
            swiftSettings: mainThreadEnforced + [.defaultIsolation(MainActor.self)]
        ),
    ]
)
