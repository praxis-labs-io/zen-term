import ControlProtocol
import Foundation
import TerminalKit

// One held `pane.wait` on one pane, answered once, or until it exits when it keeps watching. Main-thread only.
final class PaneWait {
    // libghostty reports no output, and without OSC 133 the foreground group is the only sign a job exited.
    static let checkInterval: TimeInterval = 0.25
    static let exitLines = 40

    struct Watched {
        let surfaceID: SurfaceID
        weak var surface: TerminalSurface?
        let readsForeground: Bool
        let pane: () -> ListResult.Pane?
        let exit: () -> LaunchedPaneExit?
        let awaitsQueuedTask: () -> Bool
    }

    struct Answer {
        let reason: WaitReason
        let exitCode: Int?
        let text: String?
        let pane: ListResult.Pane
    }

    let watched: Watched
    let caller: SurfaceID?
    private let keepsWatching: Bool
    private var reply: ((Answer) -> Void)?
    private var lastPane: ListResult.Pane
    private var output: OutputWatch?
    private var ranJob = false
    private var backAtShell = false
    private var ticker: Timer?
    var onAnswered: (() -> Void)?

    init?(
        _ watched: Watched, caller: SurfaceID?, output needle: String?, keepsWatching: Bool = false,
        reply: @escaping (Answer) -> Void
    ) {
        guard let pane = watched.pane() else { return nil }
        self.watched = watched
        self.caller = caller
        self.keepsWatching = keepsWatching
        self.reply = reply
        lastPane = pane
        if let needle {
            output = OutputWatch(needle: needle, baseline: Self.screen(of: watched.surface) ?? "")
        }
        ranJob = Self.foregroundIsJob(watched)
    }

    var pane: ListResult.Pane { watched.pane() ?? lastPane }

    var isWatching: Bool { reply != nil }

    // A wait without a timeout answers only on the pane's news, for a wait that holds the deadline itself.
    func start(timeout: TimeInterval?) {
        let ticker = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
        guard let timeout else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.answer(.timeout) }
    }

    // A pane with `output` waits for that text, and one with a task queued for it waits for that task's turn.
    func agentStopped() {
        guard answers(.stopped) else { return }
        answer(.stopped)
    }

    func commandFinished(exitCode: Int?) {
        if sawOutput() { return answer(.output) }
        answer(.exited, exitCode: exitCode, text: Self.lastLines(of: watched.surface))
    }

    func closed() {
        let exit = watched.exit()
        answer(.exited, exitCode: exit?.exitCode, text: exit?.lastLines)
    }

    func answers(_ reason: WaitReason) -> Bool {
        reason != .stopped || (output == nil && !watched.awaitsQueuedTask())
    }

    func messageArrived() { answer(.message) }

    func cancel() { finish() }

    private func check() {
        if let pane = watched.pane() { lastPane = pane }
        if sawOutput() { return answer(.output) }
        guard watched.readsForeground, let group = watched.surface?.foregroundProcessGroupID else { return }
        if backAtShell, ForegroundGroup.isShell(group) {
            return answer(.exited, text: Self.lastLines(of: watched.surface))
        }
        backAtShell = ranJob && ForegroundGroup.isShell(group)
        if !ForegroundGroup.isShell(group) { ranJob = true }
    }

    // A program that prints the text and exits before the next check still answers with the text.
    private func sawOutput() -> Bool {
        guard output != nil, let screen = Self.screen(of: watched.surface) else { return false }
        return output?.sawNeedle(in: screen) == true
    }

    private func answer(_ reason: WaitReason, exitCode: Int? = nil, text: String? = nil) {
        guard let reply else { return }
        let pane = pane
        if !keepsWatching || reason == .exited { finish() }
        reply(Answer(reason: reason, exitCode: exitCode, text: text, pane: pane))
    }

    private func finish() {
        guard reply != nil else { return }
        reply = nil
        ticker?.invalidate()
        ticker = nil
        onAnswered?()
    }

    private static func foregroundIsJob(_ watched: Watched) -> Bool {
        guard watched.readsForeground, let group = watched.surface?.foregroundProcessGroupID else { return false }
        return !ForegroundGroup.isShell(group)
    }

    private static func screen(of surface: TerminalSurface?) -> String? {
        guard let surface, surface.isStarted else { return nil }
        return surface.activeScreenText
    }

    private static func lastLines(of surface: TerminalSurface?) -> String? {
        guard let surface, surface.isStarted else { return nil }
        return surface.text(lastLines: exitLines)
    }
}
