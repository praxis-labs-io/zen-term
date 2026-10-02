public struct HelloResult: ControlPayload, Equatable {
    public let app: String
    public let protocolVersion: Int

    public init(app: String, protocolVersion: Int = ControlWire.version) {
        self.app = app
        self.protocolVersion = protocolVersion
    }

    private enum CodingKeys: String, CodingKey {
        case app
        case protocolVersion = "protocol"
    }
}
