import Foundation
import os

/// A logging category — the `os.Logger` category and the `[name]` tag in the file line. Free-form,
/// with the known surfaces as statics so call sites stay consistent.
public struct LogCategory: Hashable, Sendable {
    public let name: String
    public init(_ name: String) { self.name = name }

    public static let app = LogCategory("app")
    public static let config = LogCategory("config")
    public static let keybinds = LogCategory("keybinds")
    public static let nav = LogCategory("nav")
    public static let update = LogCategory("update")
    public static let surface = LogCategory("surface")
    public static let workspace = LogCategory("workspace")
    public static let toolFloat = LogCategory("tool-float")
    public static let panes = LogCategory("panes")
    public static let tabs = LogCategory("tabs")
    public static let drawers = LogCategory("drawers")
}

/// The app's logging facade: every line goes to `os.Logger` (subsystem `com.drucial.ZenTerm`, keyed
/// by category) and is teed to a rotating file for bug reports. `debug` is verbose-only.
public enum Log {
    /// Verbose gate. Seeded from the environment; the app overrides it from config at launch.
    public static var isVerbose: Bool = ProcessInfo.processInfo.environment["ZENTERM_LOG_VERBOSE"] == "1"

    /// The file sink; nil disables disk logging. The app installs the real sink
    /// (`LogFileSink.standard()`) at launch — it stays nil under `swift test` (which never launches
    /// the app), so a test run never writes to the user's `~/Library/Logs/ZenTerm/zen-term.log`.
    public static var fileSink: LogFileSink?

    /// Verbose-only diagnostics. The message is not even built when verbose is off, so an expensive
    /// dump (e.g. a nav-frame trace) costs nothing on a normal run.
    public static func debug(_ message: @autoclosure () -> String, category: LogCategory) {
        guard isVerbose else { return }
        write(.debug, message(), category)
    }

    public static func info(_ message: @autoclosure () -> String, category: LogCategory) {
        write(.info, message(), category)
    }

    public static func warning(_ message: @autoclosure () -> String, category: LogCategory) {
        write(.warning, message(), category)
    }

    public static func error(_ message: @autoclosure () -> String, category: LogCategory) {
        write(.error, message(), category)
    }

    private static func write(_ level: LogLevel, _ text: String, _ category: LogCategory) {
        logger(for: category).log(level: level.osLogType, "\(text, privacy: .public)")
        // Timestamp is captured now (on the caller thread) for accuracy; `fileLine()` runs on the
        // sink's serial queue via the @autoclosure, so the shared ISO formatter is touched single-threaded.
        let entry = LogEntry(level: level, category: category.name, message: text, timestamp: Date())
        fileSink?.writeLine(entry.fileLine())
    }

    private static let subsystem = "com.drucial.ZenTerm"
    private static let loggersLock = NSLock()
    private static var loggers: [String: Logger] = [:]

    /// One cached `os.Logger` per category, so repeated calls don't re-create it.
    private static func logger(for category: LogCategory) -> Logger {
        loggersLock.lock()
        defer { loggersLock.unlock() }
        if let existing = loggers[category.name] { return existing }
        let logger = Logger(subsystem: subsystem, category: category.name)
        loggers[category.name] = logger
        return logger
    }
}
