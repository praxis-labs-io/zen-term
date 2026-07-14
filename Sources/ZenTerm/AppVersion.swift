import Foundation

/// The app's marketing version for display. Source of truth is the release git tag, baked into
/// the bundle at package time as `CFBundleShortVersionString` (see `bin/package-app`); an
/// unpackaged `swift run` build has no such key, so it falls back to a dev string.
enum AppVersion {
    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }
}
