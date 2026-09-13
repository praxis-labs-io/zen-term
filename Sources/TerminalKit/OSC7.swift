import Foundation

public enum OSC7 {
    public static func fileURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("file://") {
            guard let parsed = URL(string: trimmed), parsed.isFileURL else { return nil }
            return URL(fileURLWithPath: parsed.path)
        }
        return URL(fileURLWithPath: trimmed)
    }
}
