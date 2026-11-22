// The server's word that a request's client closed its connection before the answer. Main-thread only.
final class ControlHangup {
    private var handlers: [() -> Void] = []
    private(set) var hasHungUp = false

    func onHangup(_ handler: @escaping () -> Void) {
        guard !hasHungUp else { return handler() }
        handlers.append(handler)
    }

    func hangUp() {
        guard !hasHungUp else { return }
        hasHungUp = true
        let pending = handlers
        handlers = []
        pending.forEach { $0() }
    }
}
