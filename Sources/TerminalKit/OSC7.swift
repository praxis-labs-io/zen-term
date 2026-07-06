import Foundation

/// Parses OSC 7 ("current working directory") payloads into file URLs.
public enum OSC7 {
    public static func fileURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("file://") {
            // Decode host + percent-encoding via URL, then rebuild a clean file URL.
            guard let parsed = URL(string: trimmed), parsed.isFileURL else { return nil }
            return URL(fileURLWithPath: parsed.path)
        }
        // A bare path — never URL(string:), which drops paths containing spaces.
        return URL(fileURLWithPath: trimmed)
    }
}
