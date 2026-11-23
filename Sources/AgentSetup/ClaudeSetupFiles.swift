import CryptoKit
import Foundation

/// The zen skill and the SessionStart hook script, as `ClaudeSetup` writes them.
public struct ClaudeSetupFiles: Equatable, Sendable {
    // Hand-kept because asking `Bundle.module` for it can `fatalError` in a packaged app.
    static let bundleName = "ZenTerm_AgentSetup"
    static let shippedDigestsFileName = "shipped-digests.txt"

    public let skill: Data
    public let hook: Data
    /// The SHA-256 hex digest of every skill and hook a build has shipped.
    public let shippedDigests: Set<String>

    public init(skill: Data, hook: Data, shippedDigests: Set<String> = []) {
        self.skill = skill
        self.hook = hook
        self.shippedDigests = shippedDigests
    }

    /// Names this pair of files: equal only for builds that ship the same skill and hook.
    public var version: String {
        Self.digest(of: Data((Self.digest(of: skill) + Self.digest(of: hook)).utf8))
    }

    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func isShipped(_ data: Data) -> Bool {
        shippedDigests.contains(Self.digest(of: data))
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
                let hook = try? Data(contentsOf: resources.appendingPathComponent(ClaudeSetup.hookFileName)),
                let digests = try? String(
                    contentsOf: resources.appendingPathComponent(shippedDigestsFileName), encoding: .utf8)
            else { continue }
            let shipped = Set(
                digests.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
            return ClaudeSetupFiles(skill: skill, hook: hook, shippedDigests: shipped)
        }
        return nil
    }
}
