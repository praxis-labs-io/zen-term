import Foundation

public struct ControlRequest: Encodable, Equatable, Sendable {
    public let v: Int
    public let id: Int
    public let cmd: ControlCommand
    public let args: ControlArgs
    public let caller: ControlCaller?

    public init(
        id: Int, cmd: ControlCommand, args: ControlArgs = ControlArgs(), caller: ControlCaller? = nil,
        v: Int = ControlWire.version
    ) {
        self.v = v
        self.id = id
        self.cmd = cmd
        self.args = args
        self.caller = caller
    }

    /// Why a line is not a request, with the `id` it carried when one could be read.
    public struct Rejection: Error, Equatable, Sendable {
        public let id: Int?
        public let error: ControlError
    }

    /// Decodes one line, with or without its newline.
    public static func decode(_ line: Data) -> Result<ControlRequest, Rejection> {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line) else {
            return .failure(Rejection(id: nil, error: ControlError(.badRequest, "The request is not a JSON object.")))
        }
        let id = envelope.id
        func reject(_ code: ControlErrorCode, _ message: String) -> Result<ControlRequest, Rejection> {
            .failure(Rejection(id: id, error: ControlError(code, message)))
        }
        guard let v = envelope.v, v >= 1 else { return reject(.badRequest, "The request has no valid v.") }
        guard v <= ControlWire.version else {
            return reject(
                .unsupportedVersion, "This ZenTerm speaks protocol version \(ControlWire.version), not \(v).")
        }
        guard let id else { return reject(.badRequest, "The request has no integer id.") }
        guard let name = envelope.cmd else { return reject(.badRequest, "The request has no cmd.") }
        guard let cmd = ControlCommand(rawValue: name) else {
            return reject(.unknownCommand, "There is no command named \(name).")
        }
        guard let args = envelope.args else {
            return reject(.badRequest, "The request's args are not an object of the fields \(name) takes.")
        }
        return .success(ControlRequest(id: id, cmd: cmd, args: args, caller: envelope.caller, v: v))
    }

    private struct Envelope: Decodable {
        let v: Int?
        let id: Int?
        let cmd: String?
        // Nil when `args` is present but malformed, which is a bad request rather than no args.
        let args: ControlArgs?
        let caller: ControlCaller?

        private enum CodingKeys: String, CodingKey { case v, id, cmd, args, caller }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            v = try? c.decodeIfPresent(Int.self, forKey: .v)
            id = try? c.decodeIfPresent(Int.self, forKey: .id)
            cmd = try? c.decodeIfPresent(String.self, forKey: .cmd)
            let hasNoArgs = !c.contains(.args) || (try? c.decodeNil(forKey: .args)) == true
            args = hasNoArgs ? ControlArgs() : try? c.decode(ControlArgs.self, forKey: .args)
            caller = try? c.decodeIfPresent(ControlCaller.self, forKey: .caller)
        }
    }
}
