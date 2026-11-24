import AppKit
import AppLog
import TerminalKit

/// A tab's float panes: panes it owns that the window shows in its float slot instead of the split tree.
final class PaneFloats: NSObject {
    private struct Entry {
        let token: Int
        let surfaceID: SurfaceID
        let surface: TerminalSurface
        let launch: TerminalSurfaceConfig
        let cwd: URL?
        var record = PaneRecord()
    }

    private var entries: [Entry] = []
    private var exitHold = LaunchedExitHold<Int>()
    private let workspaceEnv: [String: String]
    private let backingScale: CGFloat?
    private let makeSurface: () -> TerminalSurface
    private let startSurface: SurfaceStart

    // Whatever shows a float pane takes its presentation events; its guard on the shown surface drops a hidden one's.
    weak var presenter: TerminalSurfaceDelegate?

    var onSurfacesRegistered: (([SurfaceID]) -> Void)?
    var onSurfacesReleased: (([SurfaceID]) -> Void)?
    var onPaneTokensReleased: (([Int]) -> Void)?
    var onLaunchedPaneExited: ((LaunchedPaneExit) -> Void)?
    var onProgramLaunched: ((SurfaceID, String) -> Void)?
    var onNotification: ((SurfaceID, TerminalNotification) -> Void)?
    var onCommandFinished: ((SurfaceID, TerminalCommandResult) -> Void)?
    var onProgress: ((SurfaceID, TerminalProgress?) -> Void)?
    var onProgramStatus: ((SurfaceID, TerminalProgramStatus?) -> Void)?
    var onTitle: ((SurfaceID, String) -> Void)?
    var onSurfaceStartFailed: ((@escaping () -> Void, @escaping () -> Void) -> Void)?

    init(
        env: [String: String], backingScale: CGFloat?, makeSurface: @escaping () -> TerminalSurface,
        startSurface: @escaping SurfaceStart
    ) {
        workspaceEnv = env
        self.backingScale = backingScale
        self.makeSurface = makeSurface
        self.startSurface = startSurface
        super.init()
    }

    var handles: [PaneHandle] {
        entries.map {
            PaneHandle(
                token: $0.token, surfaceID: $0.surfaceID, surface: $0.surface, location: .float,
                cwd: $0.surface.currentDirectory ?? $0.cwd, record: $0.record)
        }
    }

    var surfaces: [TerminalSurface] { entries.map(\.surface) }

    var surfaceIDs: [SurfaceID] { entries.map(\.surfaceID) }

    func contains(token: Int) -> Bool { entries.contains { $0.token == token } }

    func contains(surface id: SurfaceID) -> Bool { entries.contains { $0.surfaceID == id } }

    func surface(_ id: SurfaceID) -> TerminalSurface? { entries.first { $0.surfaceID == id }?.surface }

    // Sized before it starts, because a view never attached to a window has no frame to push to its grid.
    func open(running program: PaneProgram?, cwd: URL?, size: NSSize?) -> Int {
        let surface = makeSurface()
        surface.delegate = self
        let token = NavRegistry.shared.mintToken()
        NavRegistry.shared.register(token: token) { _ in }
        let surfaceID = SurfaceIDs.mint()
        let env = PaneEnvironment.variables(base: workspaceEnv, token: token)
        var launch =
            if let program {
                ShellLaunch.program(
                    program.command, cwd: cwd, env: env, exitClosesPane: program.exitClosesPane,
                    marksExit: program.marksExit)
            } else {
                ShellLaunch.shell(cwd: cwd, env: env)
            }
        launch.backingScale = backingScale
        if program?.exitClosesPane == true { exitHold.watch(token) }
        entries.append(Entry(token: token, surfaceID: surfaceID, surface: surface, launch: launch, cwd: cwd))
        if let size { surface.view.setFrameSize(size) }
        onSurfacesRegistered?([surfaceID])
        startSurface(surface, surfaceID, launch)
        if let program { onProgramLaunched?(surfaceID, program.command) }
        Log.info("surface started (float pane)", category: .surface)
        return token
    }

    func updateRecord(token: Int, _ change: (inout PaneRecord) -> Void) {
        guard let index = entries.firstIndex(where: { $0.token == token }) else { return }
        change(&entries[index].record)
    }

    func close(token: Int) {
        guard let index = entries.firstIndex(where: { $0.token == token }) else { return }
        let entry = entries.remove(at: index)
        exitHold.forget(token)
        entry.surface.terminate()
        NavRegistry.shared.unregister(token: token)
        Log.info("surface stopped (float pane)", category: .surface)
        onSurfacesReleased?([entry.surfaceID])
        onPaneTokensReleased?([token])
    }

    func shutdown() {
        for token in entries.map(\.token) { close(token: token) }
    }

    private func entry(of s: TerminalSurface) -> Entry? { entries.first { $0.surface === s } }

    private func closeExited(_ token: Int) {
        guard let entry = entries.first(where: { $0.token == token }), let exit = exitHold.take(token) else { return }
        onLaunchedPaneExited?(
            LaunchedPaneExit(token: token, record: entry.record, exitCode: exit.exitCode, lastLines: exit.lastLines))
        close(token: token)
    }

    private func retryStart(_ token: Int) {
        guard let entry = entries.first(where: { $0.token == token }) else { return }
        startSurface(entry.surface, entry.surfaceID, entry.launch)
    }
}

extension PaneFloats: TerminalSurfaceDelegate {
    func surface(_ s: TerminalSurface, titleDidChange title: String) {
        guard let entry = entry(of: s) else { return }
        onTitle?(entry.surfaceID, title)
    }
    func surface(_ s: TerminalSurface, didPostNotification n: TerminalNotification) {
        guard let entry = entry(of: s) else { return }
        onNotification?(entry.surfaceID, n)
    }
    func surface(_ s: TerminalSurface, progressDidChange p: TerminalProgress?) {
        guard let entry = entry(of: s) else { return }
        onProgress?(entry.surfaceID, p)
    }
    func surface(_ s: TerminalSurface, programStatusDidChange status: TerminalProgramStatus?) {
        guard let entry = entry(of: s) else { return }
        onProgramStatus?(entry.surfaceID, status)
    }
    func surface(_ s: TerminalSurface, commandDidFinish result: TerminalCommandResult) {
        guard let entry = entry(of: s) else { return }
        exitHold.recordMark(entry.token, exitCode: result.exitCode)
        onCommandFinished?(entry.surfaceID, result)
        if exitHold.hasExited(entry.token) { closeExited(entry.token) }
    }
    func surfaceDidExit(_ s: TerminalSurface, code: Int32?) {
        guard let token = entry(of: s)?.token else { return }
        guard exitHold.closesOnExit(token) else { return close(token: token) }
        exitHold.recordExit(token, lastLines: s.text(lastLines: LaunchedExitHold<Int>.tailLines))
        if exitHold.hasMark(token) { return closeExited(token) }
        DispatchQueue.main.asyncAfter(deadline: .now() + LaunchedExitHold<Int>.markGrace) { [weak self] in
            self?.closeExited(token)
        }
    }
    func surfaceDidFailToStart(_ s: TerminalSurface) {
        guard let token = entry(of: s)?.token else { return }
        onSurfaceStartFailed?(
            { [weak self] in self?.retryStart(token) },
            { [weak self] in self?.close(token: token) })
    }
    func surface(_ s: TerminalSurface, backgroundDidChange color: TerminalColor) {
        presenter?.surface(s, backgroundDidChange: color)
    }
    func surface(_ s: TerminalSurface, hoveredLinkDidChange url: String?) {
        presenter?.surface(s, hoveredLinkDidChange: url)
    }
    func surfaceWantsFocus(_ s: TerminalSurface) { presenter?.surfaceWantsFocus(s) }
    func surface(_ s: TerminalSurface, scrollPositionDidChange position: TerminalScrollPosition) {
        presenter?.surface(s, scrollPositionDidChange: position)
    }
    func surfaceGridDidReflow(_ s: TerminalSurface) { presenter?.surfaceGridDidReflow(s) }
    func surface(_ s: TerminalSurface, searchTotalDidChange total: Int?) {
        presenter?.surface(s, searchTotalDidChange: total)
    }
    func surface(_ s: TerminalSurface, searchSelectionDidChange index: Int?) {
        presenter?.surface(s, searchSelectionDidChange: index)
    }
    func surfaceDidEndSearch(_ s: TerminalSurface) { presenter?.surfaceDidEndSearch(s) }
    func surface(_ s: TerminalSurface, wantsSearchWithNeedle needle: String) {
        presenter?.surface(s, wantsSearchWithNeedle: needle)
    }
}
