import Foundation

/// Installs, refreshes and removes the zen skill and session extension in one Pi config folder.
public struct PiSetup: AgentInstaller {
    static let extensionFileName = "zenterm-context.ts"
    // Pi loads only `.ts` and `.js` from `extensions`, so the stamp beside the extension is never loaded.
    static let stampFileName = "zenterm-context.build"

    public let configRoot: URL
    public let files: PiSetupFiles

    public init(configRoot: URL, files: PiSetupFiles) {
        self.configRoot = configRoot
        self.files = files
    }

    /// The folder Pi reads: `$PI_CODING_AGENT_DIR` when set, else `.pi/agent` in `$HOME`.
    public static func configRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let folder = environment["PI_CODING_AGENT_DIR"], !folder.isEmpty {
            return URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent(".pi/agent")
    }

    public var skillURL: URL { configRoot.appendingPathComponent("skills/zen/SKILL.md") }
    public var extensionURL: URL { configRoot.appendingPathComponent("extensions/\(Self.extensionFileName)") }
    public var stampURL: URL { configRoot.appendingPathComponent("extensions/\(Self.stampFileName)") }

    public var placements: [SetupPlacement] {
        [
            SetupPlacement(url: skillURL, contents: files.skill, noun: "the zen skill", ownsFolder: true),
            SetupPlacement(url: extensionURL, contents: files.extension, noun: "the session extension"),
        ]
    }

    // Pi loads every extension in `extensions` on its own, so there is nothing to register.
    public func readRegistration() throws(SetupError) -> (any SetupRegistration)? { nil }
}
