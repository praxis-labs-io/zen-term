import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// Differential tests for the window half of the `.configDidChange` fan-out (ZEN-281). The
/// app-global half is `ConfigApplierDifferentialTests`; the invariant is the same one:
///
/// > For any config change, the **gated** fan-out must leave the chrome identical to the
/// > **ungated** one.
///
/// `WindowControllerConfigFanOutTests` asserts specific gates hold for specific probes, which is
/// worth keeping: those give a named failure ("the rebind never reached the drawer header keycap")
/// where this one only says two fingerprints differ. But they only cover the dependencies someone
/// already thought of, and the ZEN-48 regressions were exactly the ones nobody thought of. This is
/// the net under them: it needs no dependency list to be right.
///
/// **Honest limit:** it only covers what the fingerprint samples. Every probe added protects every
/// change kind at once, so widening the fingerprint is the way to shrink the blind spot — but it
/// does not close it.
@MainActor
final class ConfigFanOutDifferentialTests: XCTestCase {
    private var originalConfig: GeneralConfig!
    private var originalTheme: AppTheme!
    private var originalOverride: (() -> TerminalSurface)?
    private var tempRoots: [URL] = []

    override func setUp() {
        super.setUp()
        originalConfig = GeneralConfig.current
        originalTheme = Theme.current
        originalOverride = TerminalSurfaceFactory.makeOverride
        // Instant everything. `animateSplitIn` detaches the very constraints the frames are read
        // from, so an animated run would fingerprint a frame mid-slide — and two runs would catch
        // different frames, which reads as a gate bug (see `PaneGapLiveApplyTests`).
        Motion.isReduceMotionEnabled = { true }
    }

    override func tearDownWithError() throws {
        TerminalSurfaceFactory.makeOverride = originalOverride
        MotionConfig.apply(.system)
        GeneralConfig.setCurrentForTesting(originalConfig)
        Theme.setCurrentForTesting(originalTheme)
        for dir in tempRoots { try? FileManager.default.removeItem(at: dir) }
        tempRoots = []
        try super.tearDownWithError()
    }

    // MARK: - the fingerprint

    /// The appearance a live surface was last handed across the seam.
    private struct SurfaceAppearance: Equatable {
        var theme: TerminalTheme
        var behavior: TerminalBehavior
    }

    /// What the chrome looks like after a reload. Equatable so gated and ungated compare whole:
    /// adding a probe protects every change kind at once, with no per-kind assertion to remember.
    private struct ChromeFingerprint: Equatable {
        /// The tab bar's tracer underline, baked to `chrome.accent` at init and reset only by
        /// `TabBarView.reapplyTheme()`.
        var tracer: String?
        /// The glyphs the mounted panel headers were **built** with. `builtHeaderKeycapForTesting`
        /// reads the built value; `contentForTesting` re-resolves live and so goes green whether or
        /// not the rebuild happened. That distinction is what makes this able to fail.
        var headerKeycaps: [String]
        /// Every mounted keycap's glyph, in tree order — palette rows, toasts, drawer headers. One
        /// probe covering every surface that resolves a chord from the live keymap.
        var keycaps: [String]
        /// Every mounted panel host's frame in window coordinates. Subsumes the pane gap, the
        /// window gutter, the drawer split, and the top inset the traffic lights clear.
        var panelFrames: [String]
        /// Where the toast stack sits — its insets are frozen at construction (ZEN-48).
        var toastFrames: [String]
        var trafficLightsHidden: Bool?
        /// Theme color plus `backdrop-alpha`, the one probe covering both halves of that gate.
        var backdropTint: String?
        /// Every mounted view's resolved fill and text ink, in tree order, **except the tab bar's
        /// subtree** (see `fingerprint` for why: it is the one part of the chrome the real mouse
        /// position changes). The broad colour probe: `.theme` recolors the dock, both drawers, the
        /// confirm and waiting toasts, float chrome, and every pane border, and sampling only the
        /// two named colours above left all of that invisible to a theme gate that was too narrow.
        /// Positional, so an added or removed view shows up as well as a recolored one.
        var colors: [String]
        /// Text the chrome rendered, so a re-render that drops or restates content is caught too.
        /// Same tab-bar exclusion, so a tooltip appearing under the cursor can't shift it.
        var text: [String]
        var dockFloatIDs: [String]
        /// What each live surface was last handed. Nil means it was never told anything.
        var surfaces: [SurfaceAppearance?]

        /// Which fields moved, for the failure message. Equality is what makes the assertion
        /// correct; this only makes it readable, so a field missing here degrades to a vaguer
        /// message rather than a missed regression.
        func differences(from other: ChromeFingerprint) -> [String] {
            var diffs: [String] = []
            func note<Value: Equatable>(_ label: String, _ lhs: Value, _ rhs: Value) {
                guard lhs != rhs else { return }
                diffs.append("\(label) (gated: \(lhs), ungated: \(rhs))")
            }
            note("tab bar tracer", tracer, other.tracer)
            note("panel header keycaps", headerKeycaps, other.headerKeycaps)
            note("mounted keycaps", keycaps, other.keycaps)
            note("panel frames", panelFrames, other.panelFrames)
            note("toast frames", toastFrames, other.toastFrames)
            note("traffic lights hidden", trafficLightsHidden, other.trafficLightsHidden)
            note("backdrop tint", backdropTint, other.backdropTint)
            note("dock float buttons", dockFloatIDs, other.dockFloatIDs)
            // Listed rather than dumped: these run to hundreds of entries, and printing both whole
            // arrays produces a wall that hides the handful of views that actually moved.
            if colors != other.colors {
                diffs.append("colors at \(Self.firstFew(differing: colors, from: other.colors))")
            }
            if text != other.text {
                diffs.append("text at \(Self.firstFew(differing: text, from: other.text))")
            }
            if surfaces != other.surfaces {
                let moved = zip(surfaces, other.surfaces).enumerated()
                    .filter { $0.element.0 != $0.element.1 }.map(\.offset)
                diffs.append("surface appearance at \(moved) of \(surfaces.count)")
            }
            return diffs
        }

        /// The first few positions where two lists disagree, with both values. A length change
        /// shifts every later index, so this reports the leading edge rather than the whole tail.
        private static func firstFew(differing lhs: [String], from rhs: [String]) -> String {
            func at(_ list: [String], _ index: Int) -> String {
                list.indices.contains(index) ? list[index] : "absent"
            }
            let shown = (0..<max(lhs.count, rhs.count))
                .filter { at(lhs, $0) != at(rhs, $0) }
                .prefix(4)
                .map { "[\($0)] \(at(lhs, $0)) vs \(at(rhs, $0))" }
            let total = lhs.count == rhs.count ? "" : " (\(lhs.count) vs \(rhs.count) views)"
            return shown.joined(separator: ", ") + total
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// Rounded so float noise can't read as a divergence. A gate that skipped a relayout moves a
    /// frame by points, not by hundredths.
    private func describe(_ rect: NSRect) -> String {
        let round = { (value: CGFloat) in (value * 100).rounded() / 100 }
        return "(\(round(rect.minX)), \(round(rect.minY)), \(round(rect.width)), \(round(rect.height)))"
    }

    private func fingerprint(
        _ controller: WindowController, surfaces: [RecordingSurface]
    ) -> ChromeFingerprint {
        let root = controller.window.contentView!
        root.layoutSubtreeIfNeeded()
        let views = descendants(of: root)
        // The tab bar's own subtree is excluded from the broad colour and text sweep below, because
        // it is the one part of the chrome whose appearance is driven by the **real** mouse:
        // `TabBarView.refreshHover()` recomputes hover from `mouseLocationOutsideOfEventStream` on
        // every relayout while the window is key, and hover tints a chip. Worse than a wrong value,
        // it changes whether a chip is sampled *at all* — an un-hovered chip has no layer colour
        // until `updateBackground()` first assigns one, so a chip that has ever been hovered adds an
        // entry and shifts every index after it. Sampling it would make the suite pass in CI and on
        // any machine whose pointer is elsewhere, then read as a gate regression on the one whose
        // pointer happens to rest over the test window.
        //
        // Nothing is lost: `tracer` above is a deterministic probe of the same view's re-theme, and
        // `reapplyTheme()` rebuilds the chips from it.
        let hoverDriven = Set(
            views.compactMap { $0 as? TabBarView }
                .flatMap { [$0] + descendants(of: $0) }
                .map(ObjectIdentifier.init))
        let stable = views.filter { !hoverDriven.contains(ObjectIdentifier($0)) }
        let hosts = views.compactMap { $0 as? PanelHostView }
        return ChromeFingerprint(
            tracer: views.compactMap { ($0 as? TabBarView)?.tracerColorForTesting }.first?.description,
            headerKeycaps: hosts.compactMap(\.builtHeaderKeycapForTesting),
            keycaps: views.compactMap { ($0 as? KeycapView)?.shortcut },
            panelFrames: hosts.map { describe($0.convert($0.bounds, to: root)) }.sorted(),
            toastFrames: views.compactMap { $0 as? ToastView }
                .map { describe($0.convert($0.bounds, to: root)) }.sorted(),
            trafficLightsHidden: controller.window.standardWindowButton(.closeButton)?.isHidden,
            backdropTint: controller.backdropTintColorForTesting?.description,
            colors: stable.enumerated().compactMap { index, view in
                let fill = view.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.description }
                let ink = (view as? NSTextField)?.textColor?.description
                guard fill != nil || ink != nil else { return nil }
                return "\(index) \(type(of: view)) \(fill ?? "-")/\(ink ?? "-")"
            },
            text: stable.compactMap { ($0 as? NSTextField)?.stringValue },
            dockFloatIDs: views.compactMap { ($0 as? ToggleDock)?.toolFloatButtonIDsForTesting }
                .flatMap { $0 },
            surfaces: surfaces.map { surface in
                surface.lastAppearance.map { SurfaceAppearance(theme: $0.theme, behavior: $0.behavior) }
            })
    }

    // MARK: - harness

    /// A config move. The theme is *derived* from the config rather than set alongside it, because
    /// that's the real resolution order: `AppConfig.reload()` re-resolves the general config first,
    /// then the theme, which reads the general font.
    private struct Scenario {
        var name: String
        var mutate: (inout GeneralConfig) -> Void
        /// Also point the theme at a different file, on top of any font change.
        var swapsTheme = false
    }

    private struct Resolved {
        var old: GeneralConfig
        var new: GeneralConfig
        var oldTheme: AppTheme
        var newTheme: AppTheme
    }

    private func resolve(_ scenario: Scenario) throws -> Resolved {
        let old = GeneralConfig.builtIn
        var new = old
        scenario.mutate(&new)
        let baseTerminal = originalTheme.terminal
        let newBase = scenario.swapsTheme ? try makeAlternateTheme().terminal : baseTerminal
        return Resolved(
            old: old, new: new,
            oldTheme: appTheme(font: old, palette: baseTerminal),
            newTheme: appTheme(font: new, palette: newBase))
    }

    /// The config's font over a palette, with the chrome roles derived from the result — the shape
    /// `ConfigLoader` produces.
    private func appTheme(font config: GeneralConfig, palette: TerminalTheme) -> AppTheme {
        var terminal = palette
        terminal.fontName = config.fontName
        terminal.fontSize = config.fontSize
        return AppTheme(terminal: terminal, chrome: ChromeThemeDeriver.derive(from: terminal))
    }

    /// Collects the stub surfaces this run created, so the fingerprint can see what the fan-out
    /// pushed across the seam.
    private final class SurfaceLog {
        var surfaces: [RecordingSurface] = []
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        OperationQueue.main.addOperation { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    /// Build a dressed window in the scenario's *old* state, move the statics to the *new* state,
    /// post `change`, and fingerprint what's on screen. Torn down before returning, so the next run
    /// starts from nothing and the global notification only ever reaches one window.
    private func run(_ resolved: Resolved, applying change: ConfigChange) -> ChromeFingerprint {
        GeneralConfig.setCurrentForTesting(resolved.old)
        Theme.setCurrentForTesting(resolved.oldTheme)

        let log = SurfaceLog()
        TerminalSurfaceFactory.makeOverride = {
            let surface = RecordingSurface()
            log.surfaces.append(surface)
            return surface
        }

        let controller = WindowController(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), initialCWD: nil)
        controller.showAndStart()
        // Dress it: two panes (a split gutter to measure), a drawer (a panel header keycap), a
        // toast (which is what freezes the stack's insets), and an open palette (rows whose
        // shortcut column resolves from the live keymap).
        controller.handle(.splitHorizontal)
        controller.handle(.toggleBottomDrawer)
        controller.showToast(ToastContent(variant: .info, title: "notice", message: "body"))
        controller.handle(.toggleCommandPalette)
        drainMainQueue()

        GeneralConfig.setCurrentForTesting(resolved.new)
        Theme.setCurrentForTesting(resolved.newTheme)
        NotificationCenter.default.post(
            name: .configDidChange, object: nil, userInfo: [ConfigChange.userInfoKey: change])
        drainMainQueue()

        let result = fingerprint(controller, surfaces: log.surfaces)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        return result
    }

    private func assertGateSkipsNothing(
        _ scenario: Scenario, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let resolved = try resolve(scenario)
        let diffed = ConfigChange.between(
            old: resolved.old, new: resolved.new, oldTheme: resolved.oldTheme,
            newTheme: resolved.newTheme)
        let gated = run(resolved, applying: diffed)
        let ungated = run(resolved, applying: .all)
        guard gated != ungated else { return }
        XCTFail(
            """
            "\(scenario.name)" diverged in \(gated.differences(from: ungated).joined(separator: "; ")).
            The gate skipped work the ungated fan-out does. The diff said \(diffed.rawValue) — \
            trace what the skipped call chain resolves, not what it's named after.
            """, file: file, line: line)
    }

    // MARK: - scenarios

    /// The ticket's motivating write, and the one both ZEN-48 regressions rode in on: a rebind
    /// reaches every surface that renders a keycap, none of which sounds like a keymap consumer.
    func test_keymapRebind() throws {
        try assertGateSkipsNothing(
            Scenario(name: "rebind Focus Mode") {
                let rebound = Chord(command: true, shift: true, option: true, control: true, key: "j")
                $0.keymap = $0.keymap.filter { $0.value != .toggleZoom }
                $0.keymap[rebound] = .toggleZoom
            })
    }

    func test_themeSwap() throws {
        try assertGateSkipsNothing(Scenario(name: "theme swap", mutate: { _ in }, swapsTheme: true))
    }

    /// A font edit resolves into the `AppTheme` rather than being read on its own, so it has to
    /// reach observers as `.theme`.
    func test_fontSize() throws {
        try assertGateSkipsNothing(Scenario(name: "font-size") { $0.fontSize += 4 })
    }

    func test_paneGap() throws {
        try assertGateSkipsNothing(Scenario(name: "pane-gap") { $0.panelGap += 32 })
    }

    func test_windowGutter() throws {
        try assertGateSkipsNothing(Scenario(name: "window-gutter") { $0.windowGutter += 40 })
    }

    func test_windowChrome() throws {
        try assertGateSkipsNothing(Scenario(name: "window-chrome") { $0.windowChrome.toggle() })
    }

    func test_backdropAlpha() throws {
        try assertGateSkipsNothing(Scenario(name: "backdrop-alpha") { $0.backdropAlpha = 0.3 })
    }

    /// Reaches further than the other `TerminalBehavior` keys: it also has to recolor the panel,
    /// which fills its padding ring to match the surface (ZEN-282).
    func test_backgroundAlpha() throws {
        try assertGateSkipsNothing(Scenario(name: "background-alpha") { $0.backgroundAlpha = 0.6 })
    }

    func test_cursorStyle() throws {
        try assertGateSkipsNothing(Scenario(name: "cursor-style") { $0.cursorStyle = .bar })
    }

    func test_scrollMultiplier() throws {
        try assertGateSkipsNothing(Scenario(name: "scroll-multiplier") { $0.scrollMultiplier += 1.5 })
    }

    func test_toolFloatAdded() throws {
        try assertGateSkipsNothing(
            Scenario(name: "a tool float added") {
                $0.floats = [
                    ToolFloat(
                        id: "notes", order: 0, title: "Notes", icon: ToolFloatParser.defaultIcon,
                        command: "ls", dir: nil, widthFraction: 0.85, heightFraction: 0.85,
                        requiresGitRepo: false, persist: .ephemeral,
                        toggle: Chord(command: true, shift: true, key: "n"))
                ]
            })
    }

    /// App-global kinds the window observer reads nothing from. Cheap, and they're the assertion
    /// that it genuinely reads nothing — a window that quietly grew a dependency on one would show
    /// up here rather than as stale chrome.
    func test_reduceMotion() throws {
        try assertGateSkipsNothing(Scenario(name: "reduce-motion") { $0.reduceMotion = .on })
    }

    func test_automaticUpdateChecks() throws {
        try assertGateSkipsNothing(
            Scenario(name: "automatic-update-checks") { $0.automaticUpdateChecks.toggle() })
    }

    func test_aDiagnosticAppearing() throws {
        try assertGateSkipsNothing(
            Scenario(name: "a config problem appears") {
                $0.configDiagnostics = [
                    ConfigDiagnostic(scope: .keybindLine, problem: .unparseableLine("keybind = x"))
                ]
            })
    }

    /// Several kinds at once — a Settings save touches more than one row.
    func test_severalKindsAtOnce() throws {
        try assertGateSkipsNothing(
            Scenario(name: "gap + cursor + rebind") {
                $0.panelGap += 16
                $0.cursorStyle = .underline
                $0.keymap[Chord(command: true, shift: true, option: true, control: true, key: "y")] =
                    .toggleZoom
            })
    }

    /// The harness's own control. If a fingerprint isn't stable across two identical runs, every
    /// assertion above is meaningless — a flaky probe reads as a gate bug.
    func test_theFingerprintIsDeterministic() throws {
        let resolved = try resolve(Scenario(name: "control") { $0.panelGap += 32 })
        XCTAssertEqual(
            run(resolved, applying: .all), run(resolved, applying: .all),
            "two identical runs fingerprinted differently — the probes aren't stable")
    }

    // MARK: - helpers

    /// A theme whose accent (ANSI slot 5) is a clearly distinct `#00ff00`, built through the same
    /// `ConfigLoader.loadAppTheme` path the other re-apply tests use, so every derived chrome role
    /// is populated exactly like a real theme swap.
    private func makeAlternateTheme() throws -> AppTheme {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-differential-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempRoots.append(dir)
        try """
        background = #010101
        foreground = #fefefe
        palette = 1=#ff0000
        palette = 5=#00ff00
        """.write(to: dir.appendingPathComponent("theme"), atomically: true, encoding: .utf8)
        return ConfigLoader.loadAppTheme(configRoot: dir, general: .builtIn)
    }
}
