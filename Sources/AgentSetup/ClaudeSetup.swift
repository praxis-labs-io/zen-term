import Foundation

/// Installs, refreshes and removes the zen skill and SessionStart hook in one Claude Code config folder.
public struct ClaudeSetup: AgentInstaller {
    static let hookFileName = "zenterm-context.sh"
    static let stampFileName = "zenterm-context.build"

    public let configRoot: URL
    public let files: ClaudeSetupFiles

    public init(configRoot: URL, files: ClaudeSetupFiles) {
        self.configRoot = configRoot
        self.files = files
    }

    /// The folder Claude Code reads: `$CLAUDE_CONFIG_DIR` when set, else `.claude` in `$HOME`.
    public static func configRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let folder = environment["CLAUDE_CONFIG_DIR"], !folder.isEmpty {
            return URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent(".claude")
    }

    public var skillURL: URL { configRoot.appendingPathComponent("skills/zen/SKILL.md") }
    public var hookURL: URL { configRoot.appendingPathComponent("hooks/\(Self.hookFileName)") }
    public var settingsURL: URL { configRoot.appendingPathComponent("settings.json") }
    public var stampURL: URL { configRoot.appendingPathComponent("hooks/\(Self.stampFileName)") }

    var hookCommand: String { "bash '\(hookURL.path.replacingOccurrences(of: "'", with: "'\\''"))'" }

    public var placements: [SetupPlacement] {
        [
            SetupPlacement(url: skillURL, contents: files.skill, noun: "the zen skill", ownsFolder: true),
            SetupPlacement(url: hookURL, contents: files.hook, noun: "the session hook"),
        ]
    }

    public func readRegistration() throws(SetupError) -> (any SetupRegistration)? {
        try ClaudeSessionStartEntry.read(at: settingsURL, command: hookCommand)
    }
}
