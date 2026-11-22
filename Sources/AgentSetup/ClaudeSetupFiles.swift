import Foundation

/// The zen skill and the SessionStart hook script, as `ClaudeSetup` writes them.
public struct ClaudeSetupFiles: Equatable, Sendable {
    // Hand-kept because asking `Bundle.module` for it can `fatalError` in a packaged app.
    static let bundleName = "ZenTerm_AgentSetup"

    public let skill: Data
    public let hook: Data

    public init(skill: Data, hook: Data) {
        self.skill = skill
        self.hook = hook
    }

    /// Reads the copies shipped beside `executable`, following a symlink to it; nil when none are there.
    public static func bundled(beside executable: URL? = Bundle.main.executableURL) -> ClaudeSetupFiles? {
        guard let folder = executable?.resolvingSymlinksInPath().deletingLastPathComponent() else { return nil }
        let candidates = [
            folder.deletingLastPathComponent().appendingPathComponent("Resources/\(bundleName).bundle"),
            folder.appendingPathComponent("\(bundleName).bundle"),
        ]
        for candidate in candidates {
            guard let resources = Bundle(url: candidate)?.resourceURL?.appendingPathComponent("Claude"),
                let skill = try? Data(contentsOf: resources.appendingPathComponent("SKILL.md")),
                let hook = try? Data(contentsOf: resources.appendingPathComponent(ClaudeSetup.hookFileName))
            else { continue }
            return ClaudeSetupFiles(skill: skill, hook: hook)
        }
        return nil
    }
}
