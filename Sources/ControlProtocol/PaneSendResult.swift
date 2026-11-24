/// A `pane.send` that did not deliver at once: `queued` until the person sends or clears their draft.
public struct PaneSendResult: ControlPayload, Equatable {
    public let queued: Bool?

    public init(queued: Bool? = nil) { self.queued = queued }
}
