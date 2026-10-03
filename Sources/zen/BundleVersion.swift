import Foundation

// Installed as a symlink into the app, so the bundle is found from the resolved path.
enum BundleVersion {
    static let unbundled = "0.0.0+src"

    static var current: String { of(executable: Bundle.main.executableURL) }

    static func of(executable: URL?) -> String {
        guard
            let contents = executable?.resolvingSymlinksInPath().deletingLastPathComponent()
                .deletingLastPathComponent(),
            contents.lastPathComponent == "Contents",
            let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")),
            let version = info["CFBundleShortVersionString"] as? String
        else { return unbundled }
        return version
    }
}
