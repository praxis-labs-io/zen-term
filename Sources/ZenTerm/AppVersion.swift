import Foundation

enum AppVersion {
    /// Falls back to a string no release uses, so a dev build never reads as a shipped version.
    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0+src"
    }
}
