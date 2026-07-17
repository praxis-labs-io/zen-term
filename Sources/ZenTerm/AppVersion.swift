import Foundation

/// The app's marketing version for display. Source of truth is the release git tag, baked into
/// the bundle at package time as `CFBundleShortVersionString` (see `bin/package-app`); an
/// unpackaged `swift run` build has no such key, so it falls back to a source string.
///
/// The fallback must never look like a shipped version. An installed app and a `swift run` build
/// are routinely open side by side, so a fallback of "0.1.0" would make a dev build indistinguishable
/// from the v0.1.0 release in the Settings footer, which is the one place that tells them apart.
enum AppVersion {
    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0+src"
    }
}
