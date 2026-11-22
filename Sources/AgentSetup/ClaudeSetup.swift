import Foundation

/// Installs, refreshes and removes the zen skill and SessionStart hook in one Claude Code config folder.
public struct ClaudeSetup: Sendable {
    public enum State: Equatable, Sendable {
        case notInstalled
        case outdated
        case current
    }

    static let hookFileName = "zenterm-context.sh"

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

    var hookCommand: String { "bash '\(hookURL.path.replacingOccurrences(of: "'", with: "'\\''"))'" }

    /// Reads what is installed; throws when settings.json cannot be read or is not the shape Claude Code reads.
    public func state() throws(ClaudeSetupError) -> State {
        let settings = try ClaudeSettings.read(at: settingsURL)
        let skill = try contents(of: skillURL)
        let hook = try contents(of: hookURL)
        if skill == nil, hook == nil, !settings.hasOwnEntry() { return .notInstalled }
        let isCurrent = skill == files.skill && hook == files.hook && settings.isRegistered(command: hookCommand)
        return isCurrent ? .current : .outdated
    }

    /// Writes what is missing or out of date and returns one line per change, none when it was already current.
    /// Refuses before writing anything when settings.json is malformed.
    public func install() throws(ClaudeSetupError) -> [String] {
        var settings = try ClaudeSettings.read(at: settingsURL)
        var changes: [String] = []
        if let verb = try place(files.skill, at: skillURL) {
            changes.append("\(verb) the zen skill at \(skillURL.path)")
        }
        if let verb = try place(files.hook, at: hookURL) {
            changes.append("\(verb) the session hook at \(hookURL.path)")
        }
        let wasRegistered = settings.hasOwnEntry()
        if settings.register(command: hookCommand) {
            try settings.write(to: settingsURL)
            let verb = wasRegistered ? "Updated" : "Added"
            changes.append("\(verb) the SessionStart entry in \(settingsURL.path)")
        }
        return changes
    }

    /// Deletes what setup installed, keeping every other entry, and returns one line per change.
    /// Refuses before deleting anything when settings.json is malformed.
    public func remove() throws(ClaudeSetupError) -> [String] {
        var settings = try ClaudeSettings.read(at: settingsURL)
        var changes: [String] = []
        if settings.unregister() {
            try settings.write(to: settingsURL)
            changes.append("Removed the SessionStart entry from \(settingsURL.path)")
        }
        if try delete(skillURL) {
            _ = rmdir(skillURL.deletingLastPathComponent().path)
            changes.append("Removed the zen skill from \(skillURL.path)")
        }
        if try delete(hookURL) {
            changes.append("Removed the session hook from \(hookURL.path)")
        }
        return changes
    }

    private func contents(of url: URL) throws(ClaudeSetupError) -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            throw .unreadable(url, error)
        }
    }

    private func place(_ data: Data, at url: URL) throws(ClaudeSetupError) -> String? {
        let existing = try contents(of: url)
        guard existing != data else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw .unwritable(url, error)
        }
        return existing == nil ? "Installed" : "Updated"
    }

    private func delete(_ url: URL) throws(ClaudeSetupError) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw .unwritable(url, error)
        }
        return true
    }
}
