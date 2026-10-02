import Foundation

/// The framing both ends share: one JSON object per `\n`-terminated UTF-8 line.
public enum ControlWire {
    /// The protocol version this build speaks, sent as `v` on every request and response.
    public static let version = 1

    /// The longest line either end accepts, newline excluded.
    public static let maxLineLength = 64 * 1024

    /// One encoded line with its trailing newline.
    public static func line(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
}
