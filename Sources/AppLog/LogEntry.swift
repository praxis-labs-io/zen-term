import Foundation
import os

public enum LogLevel: String, Sendable {
    case debug, info, warning, error

    var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .warning: return "WARN"
        case .error: return "ERROR"
        }
    }

    // `OSLogType` has no warning level, so `warning` maps to `.default`.
    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        }
    }
}

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

    /// Formats as `2026-07-21T06:53:05Z  WARN  [nav]  message`, in UTC.
    public func fileLine() -> String {
        "\(Self.iso.string(from: timestamp))  \(level.label)  [\(category)]  \(message)"
    }

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}
