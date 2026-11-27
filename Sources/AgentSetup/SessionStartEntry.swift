import Foundation

struct SessionStartEntry: SetupRegistration {
    let url: URL
    let command: String
    let trustNote: String?
    private var settings: SessionStartHooks

    static func read(at url: URL, command: String, trustNote: String? = nil) throws(SetupError) -> SessionStartEntry {
        SessionStartEntry(
            url: url, command: command, trustNote: trustNote, settings: try SessionStartHooks.read(at: url))
    }

    private init(url: URL, command: String, trustNote: String?, settings: SessionStartHooks) {
        self.url = url
        self.command = command
        self.trustNote = trustNote
        self.settings = settings
    }

    var hasEntry: Bool { settings.hasOwnEntry() }
    var isCurrent: Bool { settings.isRegistered(command: command) }

    mutating func register() throws(SetupError) -> String? {
        let wasRegistered = settings.hasOwnEntry()
        guard settings.register(command: command) else { return nil }
        try settings.write(to: url)
        let line = "\(wasRegistered ? "Updated" : "Added") the SessionStart entry in \(url.path)"
        return trustNote.map { "\(line). \($0)" } ?? line
    }

    mutating func unregister() throws(SetupError) -> String? {
        guard settings.unregister() else { return nil }
        try settings.write(to: url)
        return "Removed the SessionStart entry from \(url.path)"
    }
}
