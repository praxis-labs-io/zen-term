import Foundation

/// The result a command answers with.
public protocol ControlPayload: Codable, Sendable {}

/// One response line. `id` is the request's, or null when the request had none that could be read.
public struct ControlResponse<Payload: ControlPayload>: Codable, Sendable {
    public let v: Int
    public let id: Int?
    public let ok: Bool
    public let result: Payload?
    public let error: ControlError?

    public init(id: Int?, result: Payload) {
        v = ControlWire.version
        self.id = id
        ok = true
        self.result = result
        error = nil
    }

    public init(id: Int?, error: ControlError) {
        v = ControlWire.version
        self.id = id
        ok = false
        result = nil
        self.error = error
    }

    private enum CodingKeys: String, CodingKey { case v, id, ok, result, error }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(id, forKey: .id)
        try c.encode(ok, forKey: .ok)
        try c.encodeIfPresent(result, forKey: .result)
        try c.encodeIfPresent(error, forKey: .error)
    }
}

/// The payload of a response that carries none.
public struct NoPayload: ControlPayload, Equatable {
    public init() {}
}

extension ControlPayload {
    /// This payload as the encoded `ok` response line to request `id`.
    public func responseLine(id: Int?) throws -> Data {
        try ControlWire.line(ControlResponse(id: id, result: self))
    }
}

extension ControlError {
    /// This error as the encoded response line to request `id`.
    public func responseLine(id: Int?) throws -> Data {
        try ControlWire.line(ControlResponse<NoPayload>(id: id, error: self))
    }
}
