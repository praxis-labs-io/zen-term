import Foundation
import os

/// Severity of a log line. `debug` is the verbose-only tier: it reaches the file solely when
/// verbose logging is enabled (config `debug = true` or `ZENTERM_LOG_VERBOSE=1`).
public enum LogLevel: String, Sendable {
    case debug, info, warning, error

    /// The fixed-width-ish tag written into the file line.
    var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }

    /// The matching `os.Logger` level. `warning` maps to `.default` (there is no distinct warning
    /// `OSLogType`); `error` to `.error`.
    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        }
    }
}

/// One log line: its level, category, message, and when it happened. A pure value so the file
/// formatting and the verbose gate are unit-testable without touching `os.Logger` or the disk.
public struct LogEntry: Equatable, Sendable {
    public let level: LogLevel
    public let category: String
    public let message: String
    public let timestamp: Date

    public init(level: LogLevel, category: String, message: String, timestamp: Date) {
        self.level = level
        self.category = category
        self.message = message
        self.timestamp = timestamp
    }

    /// The line written to the log file: `2026-07-21T06:53:05Z  WARN  [nav]  message`.
    public func fileLine() -> String {
        "\(Self.iso.string(from: timestamp))  \(level.label)  [\(category)]  \(message)"
    }

    /// UTC ISO-8601 to the second, so log lines sort and read the same on any machine.
    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}
