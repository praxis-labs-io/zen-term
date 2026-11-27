import Foundation

// Claude Code's registration: ZenTerm's hook under `hooks.SessionStart` in settings.json.
struct ClaudeSessionStartEntry: SetupRegistration {
    let url: URL
    let command: String
    private var settings: ClaudeSettings

    static func read(at url: URL, command: String) throws(SetupError) -> ClaudeSessionStartEntry {
        ClaudeSessionStartEntry(url: url, command: command, settings: try ClaudeSettings.read(at: url))
    }

    private init(url: URL, command: String, settings: ClaudeSettings) {
        self.url = url
        self.command = command
        self.settings = settings
    }

    var hasEntry: Bool { settings.hasOwnEntry() }
    var isCurrent: Bool { settings.isRegistered(command: command) }

    mutating func register() throws(SetupError) -> String? {
        let wasRegistered = settings.hasOwnEntry()
        guard settings.register(command: command) else { return nil }
        try settings.write(to: url)
        return "\(wasRegistered ? "Updated" : "Added") the SessionStart entry in \(url.path)"
    }

    mutating func unregister() throws(SetupError) -> String? {
        guard settings.unregister() else { return nil }
        try settings.write(to: url)
        return "Removed the SessionStart entry from \(url.path)"
    }
}
