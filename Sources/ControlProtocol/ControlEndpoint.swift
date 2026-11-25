import Foundation

/// Where a ZenTerm instance listens for control connections, and how a pane learns it.
public enum ControlEndpoint {
    public static let environmentKey = "ZEN_CONTROL_SOCK"

    /// Set only for a host login's ssh: the token `ssh.askpass` must carry, and the sign that `zen` runs as its askpass.
    public static let askpassTokenKey = "ZEN_ASKPASS_TOKEN"

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
