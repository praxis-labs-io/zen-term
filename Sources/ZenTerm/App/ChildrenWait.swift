import ControlProtocol
import Foundation

// One held `pane.wait` on the caller's children, answered once: each child is watched as a pane wait is.
final class ChildrenWait {
    struct Child {
        let token: Int
        let watched: PaneWait.Watched
        let isWorking: () -> Bool
    }

    private struct Watch {
        let token: Int
        let probe: PaneWait
        let isWorking: () -> Bool
    }

    let caller: SurfaceID
    private let mode: WaitChildren
    private var watches: [Watch] = []
    private var news: [Int: PaneWait.Answer] = [:]
    private var reply: ((ControlReply) -> Void)?
    private var ticker: Timer?
    var onAnswered: (() -> Void)?

    var probes: [PaneWait] { watches.map(\.probe) }

    init(
        _ children: [Child], mode: WaitChildren, caller: SurfaceID, output needle: String?,
        reply: @escaping (ControlReply) -> Void
    ) {
        self.mode = mode
        self.caller = caller
        self.reply = reply
        watches = children.compactMap { child in
            PaneWait(child.watched, caller: nil, output: needle, keepsWatching: mode == .all) { [weak self] in
                self?.heard($0, from: child.token)
            }
            .map { Watch(token: child.token, probe: $0, isWorking: child.isWorking) }
        }
    }

    func start(timeout: TimeInterval) {
        watches.forEach { $0.probe.start(timeout: nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.answer(.timeout) }
        guard mode == .all else { return }
        let ticker = Timer(timeInterval: PaneWait.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.answerOnceNoneWorks() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
        answerOnceNoneWorks()
    }

    func messageArrived() { answer(.message) }

    // `all` keeps each child's probe until it exits, records the latest change, and reports it when it answers.
    func answers(_ reason: WaitReason, from surface: SurfaceID) -> Bool {
        watches.contains {
            $0.probe.watched.surfaceID == surface && $0.probe.isWatching && $0.probe.answers(reason)
        }
    }

    func watches(_ surface: SurfaceID) -> Bool {
        watches.contains { $0.probe.watched.surfaceID == surface && $0.probe.isWatching }
    }

    func cancel() { finish() }

    private func heard(_ answer: PaneWait.Answer, from token: Int) {
        news[token] = answer
        switch mode {
        case .any: self.answer(answer.reason)
        case .all: answerOnceNoneWorks()
        }
    }

    // A child that exited is done, whatever its pane read as it closed.
    private func answerOnceNoneWorks() {
        let working = watches.contains { news[$0.token]?.reason != .exited && $0.isWorking() }
        if !working { answer(.stopped) }
    }

    private func answer(_ reason: WaitReason) {
        guard let reply else { return }
        let children = watches.map { watch in
            let heard = news[watch.token]
            return WaitResult.Child(
                reason: heard?.reason, exitCode: heard?.exitCode, text: heard?.text, pane: watch.probe.pane)
        }
        finish()
        reply(.success(WaitResult(reason: reason, children: children)))
    }

    private func finish() {
        guard reply != nil else { return }
        reply = nil
        ticker?.invalidate()
        ticker = nil
        watches.forEach { $0.probe.cancel() }
        onAnswered?()
    }
}
