import Foundation

/// Installs, refreshes and removes the zen skill and SessionStart hook in one Claude Code config folder.
public struct ClaudeSetup: Sendable {
    public enum State: Equatable, Sendable {
        case notInstalled
        /// Every part is installed, and each file differs from this build's only as an earlier build shipped it.
        case outdated
        /// A file holds edits no build shipped, a part is missing, or the SessionStart entry is not the one setup
        /// writes, so updating would undo the user's change.
        case edited
        /// A later build installed these files and they are untouched, so this build must not replace them.
        case newer
        case current
    }

    static let hookFileName = "zenterm-context.sh"
    static let stampFileName = "zenterm-context.build"

    public enum Client: String, Sendable {
        case claude, codex

        public var displayName: String { self == .claude ? "Claude Code" : "Codex" }

        public func configRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
            if self == .claude { return ClaudeSetup.configRoot(environment: environment) }
            if let folder = environment["CODEX_HOME"], !folder.isEmpty {
                return URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
            }
            return Self.home(environment).appendingPathComponent(".codex")
        }

        fileprivate static func home(_ environment: [String: String]) -> URL {
            let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
            return URL(fileURLWithPath: home)
        }

        public func setup(files: ClaudeSetupFiles, environment: [String: String] = ProcessInfo.processInfo.environment)
            -> ClaudeSetup
        {
            let skillRoot = self == .codex ? Self.home(environment).appendingPathComponent(".agents") : nil
            return ClaudeSetup(
                configRoot: configRoot(environment: environment), files: files,
                skillRoot: skillRoot, client: self)
        }
    }

    public let configRoot: URL
    public let files: ClaudeSetupFiles

    private let skillRoot: URL
    private let client: Client

    public init(configRoot: URL, files: ClaudeSetupFiles, skillRoot: URL? = nil, client: Client = .claude) {
        self.configRoot = configRoot
        self.files = files
        self.skillRoot = skillRoot ?? configRoot
        self.client = client
    }

    /// The folder Claude Code reads: `$CLAUDE_CONFIG_DIR` when set, else `.claude` in `$HOME`.
    public static func configRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let folder = environment["CLAUDE_CONFIG_DIR"], !folder.isEmpty {
            return URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
        }
        return Client.home(environment).appendingPathComponent(".claude")
    }

    public var skillURL: URL { skillRoot.appendingPathComponent("skills/zen/SKILL.md") }
    private var hookFileName: String { client == .codex ? "zenterm-codex-context.sh" : Self.hookFileName }
    public var hookURL: URL { configRoot.appendingPathComponent("hooks/\(hookFileName)") }
    public var settingsURL: URL { configRoot.appendingPathComponent(client == .codex ? "hooks.json" : "settings.json") }
    var stampURL: URL {
        let name = client == .codex ? "zenterm-codex-context.build" : Self.stampFileName
        return configRoot.appendingPathComponent("hooks/\(name)")
    }

    var hookCommand: String { "bash '\(hookURL.path.replacingOccurrences(of: "'", with: "'\\''"))'" }

    private var registeredCommand: String { client == .codex ? hookCommand + " codex" : hookCommand }

    private var hookCommands: Set<String> {
        let suffix = client == .codex ? " codex" : ""
        var commands: Set<String> = [registeredCommand]
        let shellSpecial = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "'\"\\$`;&|<>()*?[]{}!"))
        if hookURL.path.rangeOfCharacter(from: shellSpecial) == nil {
            commands.insert("bash \(hookURL.path)\(suffix)")
            commands.insert("bash \"\(hookURL.path)\"\(suffix)")
        }
        let defaultClaudeHook = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/hooks/\(Self.hookFileName)")
        if client == .claude, hookURL.standardizedFileURL == defaultClaudeHook.standardizedFileURL {
            commands.insert("bash $HOME/.claude/hooks/\(Self.hookFileName)")
            commands.insert("bash \"$HOME/.claude/hooks/\(Self.hookFileName)\"")
        }
        return commands
    }

    /// Reads what is installed; throws when settings.json cannot be read or is not the shape Claude Code reads.
    public func state() throws(ClaudeSetupError) -> State {
        let settings = try ClaudeSettings.read(at: settingsURL, hookCommands: hookCommands)
        let skill = try contents(of: skillURL)
        let hook = try contents(of: hookURL)
        if (client == .codex || skill == nil), hook == nil, !settings.hasOwnEntry() { return .notInstalled }
        guard let skill, let hook, settings.isRegistered(command: registeredCommand) else { return .edited }
        if skill == files.skill, hook == files.hook { return .current }
        if try isFromNewerBuild(skill: skill, hook: hook) { return .newer }
        let isShipped = [(skill, files.skill), (hook, files.hook)].allSatisfy { $0 == $1 || files.isShipped($0) }
        return isShipped ? .outdated : .edited
    }

    /// Writes what is missing or out of date and returns one line per change, none when it was already current.
    /// Refuses before writing anything when settings.json is malformed.
    public func install() throws(ClaudeSetupError) -> [String] {
        var settings = try ClaudeSettings.read(at: settingsURL, hookCommands: hookCommands)
        var changes: [String] = []
        if let verb = try place(files.skill, at: skillURL) {
            changes.append("\(verb) the zen skill at \(skillURL.path)")
        }
        if let verb = try place(files.hook, at: hookURL) {
            changes.append("\(verb) the session hook at \(hookURL.path)")
        }
        let wasRegistered = settings.hasOwnEntry()
        if settings.register(command: registeredCommand) {
            try settings.write(to: settingsURL)
            let verb = wasRegistered ? "Updated" : "Added"
            changes.append("\(verb) the SessionStart entry in \(settingsURL.path)")
        }
        if let build = files.build ?? (client == .codex ? 0 : nil) {
            _ = try place(Data("\(build) \(files.version)\n".utf8), at: stampURL)
        }
        return changes
    }

    /// Deletes what setup installed, keeping every other entry, and returns one line per change.
    /// Refuses before deleting anything when settings.json is malformed.
    public func remove() throws(ClaudeSetupError) -> [String] {
        var settings = try ClaudeSettings.read(at: settingsURL, hookCommands: hookCommands)
        var changes: [String] = []
        if settings.unregister() {
            try settings.write(to: settingsURL)
            changes.append("Removed the SessionStart entry from \(settingsURL.path)")
        }
        if client == .claude, try delete(skillURL) {
            _ = rmdir(skillURL.deletingLastPathComponent().path)
            changes.append("Removed the zen skill from \(skillURL.path)")
        }
        if try delete(hookURL) {
            changes.append("Removed the session hook from \(hookURL.path)")
        }
        _ = try delete(stampURL)
        return changes
    }

    private func isFromNewerBuild(skill: Data, hook: Data) throws(ClaudeSetupError) -> Bool {
        guard let running = files.build, let stamp = try contents(of: stampURL) else { return false }
        let fields = String(decoding: stamp, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, let installer = Int(fields[0]) else { return false }
        return installer > running && fields[1] == ClaudeSetupFiles(skill: skill, hook: hook).version
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
