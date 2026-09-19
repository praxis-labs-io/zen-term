import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

@MainActor
final class ConfigFanOutDifferentialTests: WindowTestCase {
    private var originalConfig: GeneralConfig!
    private var originalTheme: AppTheme!
    private var originalOverride: (() -> TerminalSurface)?
    private var tempRoots: [URL] = []

    override func setUp() {
        super.setUp()
        originalConfig = GeneralConfig.current
        originalTheme = Theme.current
        originalOverride = TerminalSurfaceFactory.makeOverride
        Motion.isReduceMotionEnabled = { true }
    }

    override func tearDownWithError() throws {
        TerminalSurfaceFactory.makeOverride = originalOverride
        GeneralConfig.setCurrentForTesting(originalConfig)
        Theme.setCurrentForTesting(originalTheme)
        for dir in tempRoots { try? FileManager.default.removeItem(at: dir) }
        tempRoots = []
        try super.tearDownWithError()
    }

    private struct SurfaceAppearance: Equatable {
        var theme: TerminalTheme
        var behavior: TerminalBehavior
    }

    private struct ChromeFingerprint: Equatable {
        var tracer: String?
        var headerKeycaps: [String]
        var keycaps: [String]
        var panelFrames: [String]
        var toastFrames: [String]
        var trafficLightsHidden: Bool?
        var backdropTint: String?
        var colors: [String]
        var text: [String]
        var dockFloatIDs: [String]
        var dockLayout: [String]
        var surfaces: [SurfaceAppearance?]

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
            note("toolbar layout", dockLayout, other.dockLayout)
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
            dockLayout: views.compactMap { ($0 as? ToggleDock)?.visibleLayoutForTesting }
                .flatMap { $0 },
            surfaces: surfaces.map { surface in
                surface.lastAppearance.map { SurfaceAppearance(theme: $0.theme, behavior: $0.behavior) }
            })
    }

    private struct Scenario {
        var name: String
        var mutate: (inout GeneralConfig) -> Void
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

    private func appTheme(font config: GeneralConfig, palette: TerminalTheme) -> AppTheme {
        var terminal = palette
        terminal.fontName = config.fontName
        terminal.fontSize = config.fontSize
        return AppTheme(terminal: terminal, chrome: ChromeThemeDeriver.derive(from: terminal))
    }

    private final class SurfaceLog {
        var surfaces: [RecordingSurface] = []
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        OperationQueue.main.addOperation { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

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
        controller.mountAndStart()
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

    func test_hideToolbarButtons() throws {
        try assertGateSkipsNothing(
            Scenario(name: "hide-toolbar-buttons") {
                $0.hiddenToolbarButtons = [.splitHorizontal, .focusMode]
            })
    }

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

    func test_severalKindsAtOnce() throws {
        try assertGateSkipsNothing(
            Scenario(name: "gap + cursor + rebind") {
                $0.panelGap += 16
                $0.cursorStyle = .underline
                $0.keymap[Chord(command: true, shift: true, option: true, control: true, key: "y")] =
                    .toggleZoom
            })
    }

    func test_theFingerprintIsDeterministic() throws {
        let resolved = try resolve(Scenario(name: "control") { $0.panelGap += 32 })
        XCTAssertEqual(
            run(resolved, applying: .all), run(resolved, applying: .all),
            "two identical runs fingerprinted differently — the probes aren't stable")
    }

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
        # The accent slot, named from the constant rather than pinned: this fixture used to
        # move palette 5 because that was the accent, and went blind when the default moved.
        palette = \(AccentSlot.themeDefault.ansiIndex)=#00ffff
        """.write(to: dir.appendingPathComponent("theme"), atomically: true, encoding: .utf8)
        return ConfigLoader.loadAppTheme(configRoot: dir, general: .builtIn)
    }
}
