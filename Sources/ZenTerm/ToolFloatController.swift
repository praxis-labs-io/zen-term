import AppKit
import TerminalKit

/// The tool-float engine: declarative command floats whose process lifetime is set by `persist:`.
///
/// Floats are **window-level**, not per-tab (ZEN-141). A float card is a modal surface over the
/// whole window, hosted on the window's `container` so it survives a tab switch instead of
/// unmounting with its host tab, and one live instance per float id is shared by every tab in the
/// window — two tabs on one repo get one lazygit, not two. `persist:` therefore says only whether
/// a float's process survives dismissal; it no longer implies anything about where the card lives.
///
/// Per-window and not per-app: a surface is one `NSView` and can live in one view hierarchy, so an
/// app-global instance would physically yank the float out of window A when opened in window B.
///
/// The engine reaches the active tab only through the closures it's built with — `focusedCWD`,
/// `yieldFocus`, `restoreFocus` — so it holds no reference to any `TabController` and doesn't care
/// which tab is up.
final class ToolFloatController: NSObject, TerminalSurfaceDelegate {
    /// Host the card in the window's float region (`WindowController` owns the geometry — it
    /// knows the tab bar the region stops at).
    private let presentOverlay: (SurfaceFloatOverlay) -> Void
    /// The active tab's focused pane cwd — where an unpinned float's command runs.
    private let focusedCWD: () -> URL?
    /// The active tab drops its unified focus (halo + first responder) to the modal float.
    private let yieldFocus: () -> Void
    /// The active tab takes its unified focus back when the card goes away.
    private let restoreFocus: () -> Void
    private let makeSurface: () -> TerminalSurface

    /// The tool float currently SHOWN. Floats are modal and mutually exclusive, so one slot
    /// suffices. Whether its surface dies on dismiss depends on `spec.persist`.
    private var activeFloat: (spec: ToolFloat, surface: TerminalSurface, overlay: SurfaceFloatOverlay)?

    /// Tool floats whose process is ALIVE, keyed by float id — the persistent ones, kept across
    /// dismissal. Liveness and visibility are independent: a float can be in here while hidden.
    /// `anchor` is the directory identity a `.directory` float was launched against (`.ephemeral`
    /// floats are never in here at all; a `.window` float's anchor is nil, which is exactly what
    /// makes it never re-anchor). `spec` is the one the instance was SPAWNED with — a Settings
    /// edit to its `command`/`dir` is caught on the next open and respawns, instead of silently
    /// reusing a process still running the old command; its `title` names a hidden float in the
    /// notifications and warnings it can still raise.
    private var liveFloats: [String: (surface: TerminalSurface, anchor: URL?, spec: ToolFloat)] = [:]

    /// A float overlay still springing out. It keeps Auto Layout constraints on a persistent
    /// float's shared `surface.view`, so a fast re-show must snap it away before re-hosting that
    /// view in a new card — otherwise the old constraints fight the new ones.
    private var dismissingOverlay: SurfaceFloatOverlay?

    /// Fired whenever a card opens or closes, so the dock's float pips re-render.
    var onStateChanged: (() -> Void)?
    /// Request a transient top-right toast (e.g. a `git:true` float opened outside a repo).
    var onRequestToast: ((ToastContent) -> Void)?
    /// A float's tool posted a desktop notification (an agent asking for input), with the float it
    /// came from so the banner can name it. Relayed for hidden floats too — that's the case that
    /// needs it most: a dismissed `persist:` agent has no on-screen trace at all.
    var onNotification: ((TerminalNotification, ToolFloat) -> Void)?

    init(
        presentOverlay: @escaping (SurfaceFloatOverlay) -> Void,
        focusedCWD: @escaping () -> URL?,
        yieldFocus: @escaping () -> Void,
        restoreFocus: @escaping () -> Void,
        makeSurface: @escaping () -> TerminalSurface = TerminalSurfaceFactory.make
    ) {
        self.presentOverlay = presentOverlay
        self.focusedCWD = focusedCWD
        self.yieldFocus = yieldFocus
        self.restoreFocus = restoreFocus
        self.makeSurface = makeSurface
        super.init()
    }

    var isOpen: Bool { activeFloat != nil }
    var activeID: String? { activeFloat?.spec.id }

    /// Whether any persistent float's process has live work — hidden ones included, which is the
    /// point: a dismissed persistent float is invisible, and the ⌘W confirm would otherwise let
    /// the window close over it silently.
    var hasBusy: Bool { liveFloats.values.contains { $0.surface.isBusy } }

    /// Every live float surface, for the config-change re-theming fan-out.
    var allSurfaces: [TerminalSurface] {
        var result = liveFloats.values.map(\.surface)
        // An ephemeral float is shown but never in the registry, so the slot is its only home.
        if let active = activeFloat, !result.contains(where: { $0 === active.surface }) {
            result.append(active.surface)
        }
        return result
    }

    /// Re-focus the shown card — the window calls this when mounting a tab, so a tab switch
    /// beneath an open float doesn't steal first responder to the pane hidden behind it.
    func refocus() { activeFloat?.surface.focus() }

    func reapplyTheme() { activeFloat?.overlay.reapplyTheme() }

    /// Where a float's command runs: its pinned `dir:` when it has one, else the focused pane's cwd.
    private func floatCWD(_ spec: ToolFloat) -> URL? { spec.dir ?? focusedCWD() }

    /// Toggle a tool float: same id open → close; otherwise run the git guard and open.
    func toggle(_ spec: ToolFloat) {
        if activeFloat?.spec.id == spec.id { close(); return }
        if activeFloat != nil { close() }  // switch floats
        // One ancestor walk per press: the git guard and the `.directory` anchor share the same
        // repo-root lookup, and each `isGitRepo` probe is main-thread filesystem I/O.
        let repoRoot = GitRepo.repoRoot(for: floatCWD(spec))
        if spec.requiresGitRepo, repoRoot == nil {
            onRequestToast?(gitGuardToast(for: spec))
            return
        }
        // Only `.directory` takes an anchor. `.window` deliberately gets nil: a nil anchor makes
        // the reuse check unconditional, which IS "one instance per window that never re-anchors".
        let anchor = spec.persist == .directory ? (repoRoot ?? floatCWD(spec)?.standardizedFileURL) : nil
        show(spec, anchor: anchor)
    }

    /// The `git:true` block toast. A pinned `dir:` float is gated on the PINNED directory, so the
    /// copy must name it — "run `git init` here" would point at the focused pane, which the guard
    /// never looked at, leaving the user un-followable advice.
    private func gitGuardToast(for spec: ToolFloat) -> ToastContent {
        let message: String
        if let dir = spec.dir {
            message =
                "This float is pinned to \(PathDisplay.abbreviatingHome(dir.path)), "
                + "which isn't a Git repository."
        } else {
            message = "This needs a Git repository. Run `git init` here, or open a folder that has one."
        }
        return ToastContent(variant: .info, title: spec.title, message: message)
    }

    /// Present `spec` in a float card: resolve its surface (retained or fresh), host it, and take
    /// the active tab's unified focus. When the tool exits, `surfaceDidExit` tears the float down.
    private func show(_ spec: ToolFloat, anchor: URL?) {
        let surface = surfaceForFloat(spec, anchor: anchor)
        // Snap away a still-springing-out card ONLY when it holds constraints on the view we're
        // about to re-host — otherwise let it finish its own exit. A card that isn't sharing this
        // surface's view (a different float, or a fresh spawn) springs out normally while the new
        // one springs in; only a shared-view re-host needs the snap.
        if let dismissing = dismissingOverlay, surface.view.isDescendant(of: dismissing) {
            dismissing.removeFromSuperview()
            dismissingOverlay = nil
        }
        let overlay = SurfaceFloatOverlay(
            content: surface.view,
            background: Theme.current.chrome.background.nsColor,
            widthFraction: spec.widthFraction,
            heightFraction: spec.heightFraction,
            contentInset: 10,
            cornerRadius: 14,
            onDismiss: { [weak self] in self?.close() })
        presentOverlay(overlay)
        activeFloat = (spec, surface, overlay)
        yieldFocus()
        surface.focus()
        overlay.animateIn()
        onStateChanged?()
    }

    /// The surface to show for `spec`: a retained one when the float persists, still matches its
    /// anchor, AND was spawned with the same `command`/`dir` — else discard and spawn fresh. The
    /// discard covers a `persist:` flipped to `none` in a live config reload (which must not reuse
    /// and then terminate a surface the registry still holds), the focused dir moving, and a
    /// Settings edit to the command or pinned dir (reusing would silently keep the OLD command's
    /// process running, making the edit look like a no-op).
    private func surfaceForFloat(_ spec: ToolFloat, anchor: URL?) -> TerminalSurface {
        if let live = liveFloats[spec.id] {
            let anchorHolds = spec.persist != .directory || live.anchor?.path == anchor?.path
            let spawnHolds = live.spec.command == spec.command && live.spec.dir == spec.dir
            if spec.persist != .ephemeral, anchorHolds, spawnHolds { return live.surface }
            discard(spec.id)
        }
        let surface = spawn(spec)
        if spec.persist != .ephemeral {
            liveFloats[spec.id] = (surface, anchor, spec)
        }
        return surface
    }

    /// Reconcile the registry against the catalog after a config reload. An entry whose id no
    /// longer exists (float deleted — or renamed, which is a delete plus an add) would otherwise
    /// keep a hidden process running with no dock button, chord, or palette entry ever able to
    /// reach it again. A present-but-edited id is NOT discarded here: command/dir edits reconcile
    /// lazily on the next open, so a config save never kills a hidden tool that is still reachable.
    /// If the float currently SHOWN was deleted, close its card too — it has no toggle left.
    func prune(against catalog: [ToolFloat]) {
        let ids = Set(catalog.map(\.id))
        if let active = activeFloat, !ids.contains(active.spec.id) { close() }
        // Snapshot the keys — the discard mutates the dictionary mid-loop (same rule as `shutdown()`).
        for id in Array(liveFloats.keys) where !ids.contains(id) { discard(id) }
    }

    /// Spawn `spec.command` in a fresh login+interactive shell at the float's cwd, so the user's
    /// PATH and pager match a pane's.
    private func spawn(_ spec: ToolFloat) -> TerminalSurface {
        let surface = makeSurface()
        surface.delegate = self
        surface.start(
            TerminalSurfaceConfig(
                command: ShellLaunch.userShell, args: ["-l", "-i", "-c", spec.command],
                workingDirectory: floatCWD(spec), theme: Theme.current.terminal,
                behavior: GeneralConfig.current.terminalBehavior))
        return surface
    }

    /// Drop a persistent float's surface. Clears the ref BEFORE terminate so a synchronous
    /// `surfaceDidExit` re-entry can't resurrect the entry this is removing.
    private func discard(_ id: String) {
        guard let live = liveFloats.removeValue(forKey: id) else { return }
        live.surface.terminate()
    }

    /// Close the float. An ephemeral float's surface dies with the card; a persistent one keeps
    /// running and only loses its card. Clears the slot before terminate so a synchronous
    /// `surfaceDidExit` re-entry no-ops.
    func close() {
        guard let active = activeFloat else { return }
        activeFloat = nil
        let overlay = active.overlay
        // Park BEFORE animateOut: `Motion.springScaleFade` fires its completion synchronously under
        // Reduce Motion, and that completion clears the slot by identity — assigning afterwards
        // would strand an overlay no completion will ever clear.
        // Snap any PREVIOUSLY parked card first: the slot holds one overlay,
        // and silently dropping a parked reference would skip the shared-view snap-away on a fast
        // X→Y→X switch — X's old card would keep its constraints on the view being re-hosted.
        if active.spec.persist != .ephemeral {
            dismissingOverlay?.removeFromSuperview()
            dismissingOverlay = overlay
        }
        overlay.animateOut { [weak self] in
            overlay.removeFromSuperview()
            if self?.dismissingOverlay === overlay { self?.dismissingOverlay = nil }
        }
        if active.spec.persist == .ephemeral { active.surface.terminate() }
        restoreFocus()
        onStateChanged?()
    }

    /// Terminate every float this window owns — the window is closing.
    func shutdown() {
        activeFloat?.overlay.removeFromSuperview()
        // An ephemeral float lives only in the slot, so terminate the shown surface directly; a
        // persistent one is also in the registry, and `discard` no-ops on an already-dead surface.
        activeFloat?.surface.terminate()
        activeFloat = nil
        dismissingOverlay?.removeFromSuperview()
        dismissingOverlay = nil
        // Snapshot the keys: `discard` removes from `liveFloats` as it goes, and iterating `.keys`
        // directly over a dictionary being mutated mid-loop is a hazard.
        for id in Array(liveFloats.keys) { discard(id) }
    }

    /// Copy the shown float's selection. The window routes here instead of to the active tab
    /// whenever a card is up — the float is modal, so it owns the clipboard verbs.
    @objc func copyFromSurface(_ sender: Any?) {
        guard let text = activeFloat?.surface.copySelection(), !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func pasteToSurface(_ sender: Any?) {
        guard let surface = activeFloat?.surface,
            let text = NSPasteboard.general.string(forType: .string)
        else { return }
        surface.paste(text)
    }

    // MARK: TerminalSurfaceDelegate

    /// A float's tool posted a desktop notification (a `claude` float asking for input) — relay it
    /// as this window's attention signal, same as a pane or a drawer.
    ///
    /// Before ZEN-141 floats were tab-owned, so `TabController`'s blanket relay carried this for
    /// free; owning the delegate here means owning this too, or an agent float's request is
    /// silently dropped (ZEN-139).
    func surface(_ s: TerminalSurface, didPostNotification n: TerminalNotification) {
        guard let spec = spec(for: s) else { return }
        onNotification?(n, spec)
    }

    /// The spec behind a live surface — the shown card's, or a hidden persistent float's.
    private func spec(for s: TerminalSurface) -> ToolFloat? {
        if let active = activeFloat, s === active.surface { return active.spec }
        return liveFloats.values.first { $0.surface === s }?.spec
    }

    /// A float's tool ran to completion / quit (`q` in lazygit) → close the card and forget the
    /// instance, so the next open spawns fresh rather than resurrecting a dead surface.
    func surfaceDidExit(_ s: TerminalSurface, code: Int32?) {
        if let active = activeFloat, s === active.surface {
            activeFloat = nil
            liveFloats.removeValue(forKey: active.spec.id)
            active.overlay.animateOut { active.overlay.removeFromSuperview() }
            active.surface.terminate()
            restoreFocus()
            onStateChanged?()
            return
        }
        if let id = liveFloats.first(where: { $0.value.surface === s })?.key {
            liveFloats.removeValue(forKey: id)  // a hidden persistent float's tool quit
            s.terminate()
        }
    }

    /// A float's surface failed to start. Warn passively and reuse `surfaceDidExit`'s teardown so
    /// the next toggle spawns a fresh one — the natural retry for a float, unlike a pane, which
    /// gets an in-place Retry button.
    func surfaceDidFailToStart(_ s: TerminalSurface) {
        let descriptor: String
        if activeFloat?.surface === s {
            descriptor = "This tool"
        } else if liveFloats.values.contains(where: { $0.surface === s }) {
            // Hidden persistent float: evict so the next open spawns fresh, but still warn — the
            // user believes this tool is alive in the background, and a silent eviction makes the
            // next open's cold, state-less spawn look like persistence quietly failing.
            descriptor = "A background tool"
        } else {
            return  // not one of ours
        }
        onRequestToast?(
            ToastContent(
                variant: .warning, title: "Terminal Didn't Start",
                message: "\(descriptor) failed to launch. Open it again to retry."))
        surfaceDidExit(s, code: nil)
    }
}
