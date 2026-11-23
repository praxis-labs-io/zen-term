import ControlProtocol
import Foundation

// The person's last key into each pane, so a send waits out a draft they are typing. App-wide, main-thread only.
final class PaneDrafts {
    static let quiet: TimeInterval = 2
    static let longestHold = TimeInterval(ControlWire.longestDraftHold)

    var now: () -> Date = Date.init
    var after: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private var lastKeys: [SurfaceID: Date] = [:]

    func typed(into surface: SurfaceID) { lastKeys[surface] = now() }

    func lastKey(into surface: SurfaceID) -> Date? { lastKeys[surface] }

    func panesClosed(_ surfaces: [SurfaceID]) { surfaces.forEach { lastKeys[$0] = nil } }

    func hold(_ surface: SurfaceID, hangup: ControlHangup, then deliver: @escaping () -> Void) {
        release(surface, by: now().addingTimeInterval(Self.longestHold), hangup: hangup, deliver)
    }

    private func release(
        _ surface: SurfaceID, by cap: Date, hangup: ControlHangup, _ deliver: @escaping () -> Void
    ) {
        guard !hangup.hasHungUp else { return }
        let now = now()
        guard let lastKey = lastKeys[surface], now < cap else { return deliver() }
        let quietAt = lastKey.addingTimeInterval(Self.quiet)
        guard now < quietAt else { return deliver() }
        after(min(quietAt, cap).timeIntervalSince(now)) { [weak self] in
            self?.release(surface, by: cap, hangup: hangup, deliver)
        }
    }
}
