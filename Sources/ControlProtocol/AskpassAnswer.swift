/// What a person typed for ssh. Encodes as a bare JSON string; every description and mirror of it is redacted.
public struct AskpassAnswer: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
    CustomReflectable
{
    public static let redacted = "<redacted>"

    public let text: String

    public init(_ text: String) { self.text = text }

    public init(from decoder: Decoder) throws { text = try decoder.singleValueContainer().decode(String.self) }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }

    public var description: String { Self.redacted }
    public var debugDescription: String { Self.redacted }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
