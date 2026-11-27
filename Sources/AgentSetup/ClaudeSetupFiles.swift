import Foundation

/// The zen skill and the SessionStart hook script, as `ClaudeSetup` writes them.
public struct ClaudeSetupFiles: SetupFiles {
    public let skill: Data
    public let hook: Data
    public let shippedDigests: Set<String>
    public let build: Int?

    public init(skill: Data, hook: Data, shippedDigests: Set<String> = [], build: Int? = nil) {
        self.skill = skill
        self.hook = hook
        self.shippedDigests = shippedDigests
        self.build = build
    }

    public var contents: [Data] { [skill, hook] }

    public static func bundled(beside executable: URL? = Bundle.main.executableURL) -> ClaudeSetupFiles? {
        guard
            let bundle = readBundle(
                folder: "Claude", names: ["SKILL.md", ClaudeSetup.hookFileName], beside: executable)
        else { return nil }
        return ClaudeSetupFiles(
            skill: bundle.contents[0], hook: bundle.contents[1], shippedDigests: bundle.shippedDigests,
            build: bundle.build)
    }
}
