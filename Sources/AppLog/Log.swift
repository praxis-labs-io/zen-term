import Foundation
import os

/// The `os.Logger` category and the `[name]` tag in the file line.
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

/// Writes each line to `os.Logger` (subsystem `com.drucial.ZenTerm`) and to `fileSink`.
public enum Log {
    /// Seeded from `ZENTERM_LOG_VERBOSE=1`; the app overrides it from config at launch.
    public static var isVerbose: Bool = ProcessInfo.processInfo.environment["ZENTERM_LOG_VERBOSE"] == "1"

    /// Nil disables file logging. The app installs `LogFileSink.standard()` at launch.
    public static var fileSink: LogFileSink?

    /// Builds and writes `message` only when `isVerbose` is on.
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
        let entry = LogEntry(level: level, category: category.name, message: text, timestamp: Date())
        fileSink?.writeLine(entry.fileLine())
    }

    private static let subsystem = "com.drucial.ZenTerm"
    private static let loggersLock = NSLock()
    private static var loggers: [String: Logger] = [:]

    private static func logger(for category: LogCategory) -> Logger {
        loggersLock.lock()
        defer { loggersLock.unlock() }
        if let existing = loggers[category.name] { return existing }
        let logger = Logger(subsystem: subsystem, category: category.name)
        loggers[category.name] = logger
        return logger
    }
}
