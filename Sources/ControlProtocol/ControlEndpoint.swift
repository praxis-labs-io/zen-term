import Foundation

/// Where a ZenTerm instance listens for control connections, and how a pane learns it.
public enum ControlEndpoint {
    public static let environmentKey = "ZEN_CONTROL_SOCK"

    public static let fileNamePrefix = "control."
    public static let fileNameSuffix = ".sock"

    /// `~/Library/Application Support/ZenTerm`.
    public static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZenTerm", isDirectory: true)
    }

    /// True for `control.<anything>.sock`.
    public static func isSocketFileName(_ name: String) -> Bool {
        name.hasPrefix(fileNamePrefix) && name.hasSuffix(fileNameSuffix)
            && name.count > fileNamePrefix.count + fileNameSuffix.count
    }
}
