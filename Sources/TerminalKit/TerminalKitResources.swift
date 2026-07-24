import Foundation

/// TerminalKit's own SwiftPM resource bundle (staged ghostty runtime resources).
///
/// `bundleName` is `<PackageName>_<TargetName>`, matching what the generated
/// `Bundle.module` accessor hardcodes and what `bin/package-app`'s
/// `EXPECTED_BUNDLES` asserts. It is a hand-maintained literal because the accessor
/// can't be asked for the name without risking its `fatalError` in a packaged app
/// (see `Bundle+ZenResource.swift`); `TerminalKitResourcesTests` asserts it matches
/// the actually-emitted bundle so a rename or SwiftPM scheme change fails the gate
/// rather than re-shipping the ZEN-175 launch crash.
enum TerminalKitResources {
    static let bundleName = "ZenTerm_TerminalKit"

    /// Resolved once, from `Contents/Resources` in a packaged app (never the fataling
    /// `Bundle.module`, which only ever resolved on the build machine).
    static let bundle: Bundle = Bundle.zenResourceBundle(named: bundleName, fallback: .module)

    /// The do-nothing cursor shader an unfocused surface runs in place of the real one
    /// (ZEN-237). Nil if it's missing from the bundle, which leaves the surface shader-less:
    /// still tracer-free, at the cost of a smear on the next focus.
    static var passthroughShaderPath: String? {
        bundle.url(forResource: "passthrough", withExtension: "glsl")?.path
    }
}
