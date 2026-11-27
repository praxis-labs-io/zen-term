import Foundation

/// Installs, refreshes and removes the zen skill and SessionStart hook in one Codex config folder.
public struct CodexSetup: AgentInstaller {
    static let hookFileName = SessionStartHooks.hookFileName
    static let stampFileName = "zenterm-context.build"
    static let trustNote = "Codex asks you to trust it when it next starts."

    public let configRoot: URL
    public let files: CodexSetupFiles

    public init(configRoot: URL, files: CodexSetupFiles) {
        self.configRoot = configRoot
        self.files = files
    }

    /// The folder Codex reads: `$CODEX_HOME` when set, else `.codex` in `$HOME`.
    public static func configRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let folder = environment["CODEX_HOME"], !folder.isEmpty {
            return URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent(".codex")
    }

    public var skillURL: URL { configRoot.appendingPathComponent("skills/zen/SKILL.md") }
    public var hookURL: URL { configRoot.appendingPathComponent("hooks/\(Self.hookFileName)") }
    public var hooksURL: URL { configRoot.appendingPathComponent("hooks.json") }
    public var stampURL: URL { configRoot.appendingPathComponent("hooks/\(Self.stampFileName)") }

    var hookCommand: String { "bash '\(hookURL.path.replacingOccurrences(of: "'", with: "'\\''"))'" }

    public var placements: [SetupPlacement] {
        [
            SetupPlacement(url: skillURL, contents: files.skill, noun: "the zen skill", ownsFolder: true),
            SetupPlacement(url: hookURL, contents: files.hook, noun: "the session hook"),
        ]
    }

    public func readRegistration() throws(SetupError) -> (any SetupRegistration)? {
        try SessionStartEntry.read(at: hooksURL, command: hookCommand, trustNote: Self.trustNote)
    }
}
