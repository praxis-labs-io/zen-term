import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

final class ConfigApplierDifferentialTests: XCTestCase {
    private var originalConfig: GeneralConfig!
    private var originalTheme: AppTheme!
    private var tempRoots: [URL] = []

    override func setUp() {
        super.setUp()
        originalConfig = GeneralConfig.current
        originalTheme = Theme.current
    }

    override func tearDownWithError() throws {
        GeneralConfig.setCurrentForTesting(originalConfig)
        Theme.setCurrentForTesting(originalTheme)
        for dir in tempRoots { try? FileManager.default.removeItem(at: dir) }
        tempRoots = []
        try super.tearDownWithError()
    }

    private final class SinkDoubles {
        var keymap: [Chord: KeyInterceptor.ReservedChord]
        var shadowKeymap: [Chord: KeyInterceptor.ReservedChord]
        var motion: GeneralConfig.ReduceMotion
        var autoChecks: Bool
        var announced: [ToastContent] = []
        var showing: ToastContent?
        var conflicts: [KeybindConflict] = []
        var canDeliver = true
        var published: ThemePublisher.Payload
        let card: UpdateCardView

        init(old: GeneralConfig) {
            published = ThemePublisher.payload(for: Theme.current, themeName: old.themeName)
            keymap = old.keymap
            shadowKeymap = old.keymap
            motion = old.reduceMotion
            autoChecks = old.automaticUpdateChecks
            card = UpdateCardView(
                state: .available(version: "9.9.9", current: "1.0.0", notes: ["a note"], notesURL: nil),
                actions: UpdateCardView.Actions())
        }

        var sinks: ConfigApplier.Sinks {
            ConfigApplier.Sinks(
                setKeymap: { [unowned self] in self.keymap = $0 },
                reportBackendShadow: { [unowned self] in self.shadowKeymap = GeneralConfig.current.keymap },
                applyMotion: { [unowned self] in self.motion = $0 },
                announceDiagnostics: { [unowned self] content, _ in
                    guard self.canDeliver else { return false }
                    self.showing = content
                    self.announced.append(content)
                    return true
                },
                retractDiagnostics: { [unowned self] in self.showing = nil },
                announceConflicts: { [unowned self] in
                    self.conflicts = $0
                    return true
                },
                retractConflicts: { [unowned self] in self.conflicts = [] },
                reapplyUpdateCardTheme: { [unowned self] in self.card.reapplyTheme() },
                applyAutoCheckSetting: { [unowned self] in
                    self.autoChecks = GeneralConfig.current.automaticUpdateChecks
                },
                publishTheme: { [unowned self] in
                    self.published = ThemePublisher.payload(
                        for: Theme.current, themeName: GeneralConfig.current.themeName)
                })
        }
    }

    private struct AppFingerprint: Equatable {
        var keymap: [String]
        var shadowKeymap: [String]
        var motion: GeneralConfig.ReduceMotion
        var autoChecks: Bool
        var cardKeycap: String
        var cardText: [String]
        var announced: [ToastContent]
        var showing: ToastContent?
        var published: ThemePublisher.Payload

        func differences(from other: AppFingerprint) -> [String] {
            var diffs: [String] = []
            if keymap != other.keymap {
                let onlyHere = Set(keymap).subtracting(other.keymap).sorted()
                let onlyThere = Set(other.keymap).subtracting(keymap).sorted()
                diffs.append("keymap (gated-only: \(onlyHere), ungated-only: \(onlyThere))")
            }
            if shadowKeymap != other.shadowKeymap {
                diffs.append("backend shadow report ran against a different keymap")
            }
            if motion != other.motion { diffs.append("motion (\(motion) vs \(other.motion))") }
            if autoChecks != other.autoChecks {
                diffs.append("autoChecks (\(autoChecks) vs \(other.autoChecks))")
            }
            if cardKeycap != other.cardKeycap {
                diffs.append("update card keycap (\"\(cardKeycap)\" vs \"\(other.cardKeycap)\")")
            }
            if cardText != other.cardText {
                diffs.append("update card text (\(cardText) vs \(other.cardText))")
            }
            if announced != other.announced {
                diffs.append(
                    "announced (\(announced.map(\.title)) vs \(other.announced.map(\.title)))")
            }
            if showing != other.showing {
                diffs.append(
                    "notice on screen (\(showing?.title ?? "none") vs \(other.showing?.title ?? "none"))")
            }
            if published != other.published {
                diffs.append(
                    "published theme (\(published.name) \(published.background) vs "
                        + "\(other.published.name) \(other.published.background))")
            }
            return diffs
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func fingerprint(_ doubles: SinkDoubles) -> AppFingerprint {
        let views = descendants(of: doubles.card)
        return AppFingerprint(
            keymap: doubles.keymap.map { "\($0.key.configToken) = \($0.value)" }.sorted(),
            shadowKeymap: doubles.shadowKeymap.map { "\($0.key.configToken) = \($0.value)" }.sorted(),
            motion: doubles.motion, autoChecks: doubles.autoChecks,
            cardKeycap: views.compactMap { ($0 as? KeycapView)?.shortcut }.joined(separator: "+"),
            cardText: views.compactMap { ($0 as? NSTextField)?.stringValue },
            announced: doubles.announced, showing: doubles.showing, published: doubles.published)
    }

    private struct Scenario {
        var name: String
        var old: GeneralConfig = .builtIn
        var new: GeneralConfig
        var oldTheme: AppTheme?
        var newTheme: AppTheme?
    }

    private func run(_ scenario: Scenario, applying change: ConfigChange) -> AppFingerprint {
        GeneralConfig.setCurrentForTesting(scenario.old)
        if let oldTheme = scenario.oldTheme { Theme.setCurrentForTesting(oldTheme) }
        let doubles = SinkDoubles(old: scenario.old)
        let applier = ConfigApplier(sinks: doubles.sinks)

        GeneralConfig.setCurrentForTesting(scenario.new)
        if let newTheme = scenario.newTheme { Theme.setCurrentForTesting(newTheme) }
        applier.apply(change)
        return fingerprint(doubles)
    }

    private func assertGateSkipsNothing(
        _ scenario: Scenario, file: StaticString = #filePath, line: UInt = #line
    ) {
        let diffed = ConfigChange.between(
            old: scenario.old, new: scenario.new,
            oldTheme: scenario.oldTheme ?? Theme.current, newTheme: scenario.newTheme ?? Theme.current)
        let gated = run(scenario, applying: diffed)
        let ungated = run(scenario, applying: .all)
        guard gated != ungated else { return }
        XCTFail(
            """
            "\(scenario.name)" diverged in \(gated.differences(from: ungated).joined(separator: ", ")).
            The gate skipped work the ungated fan-out does. The diff said \(diffed.rawValue) — \
            trace what the skipped sink's call chain resolves, not what it's named after.
            """, file: file, line: line)
    }

    func test_keymapRebind_leavesTheAppWhereTheUngatedFanOutWould() {
        var new = GeneralConfig.builtIn
        new.keymap[Chord(command: true, shift: true, option: true, key: "u")] = .checkForUpdates
        assertGateSkipsNothing(Scenario(name: "bind Check for Updates", new: new))
    }

    func test_motionChange_leavesTheAppWhereTheUngatedFanOutWould() {
        var new = GeneralConfig.builtIn
        new.reduceMotion = .on
        assertGateSkipsNothing(Scenario(name: "reduce-motion on", new: new))
    }

    func test_autoUpdateToggle_leavesTheAppWhereTheUngatedFanOutWould() {
        var new = GeneralConfig.builtIn
        new.automaticUpdateChecks = !GeneralConfig.builtIn.automaticUpdateChecks
        assertGateSkipsNothing(Scenario(name: "auto-update toggle", new: new))
    }

    func test_diagnosticAppearing_leavesTheAppWhereTheUngatedFanOutWould() {
        var new = GeneralConfig.builtIn
        new.configDiagnostics = [
            ConfigDiagnostic(scope: .keybindLine, problem: .unparseableLine("keybind = nonsense"))
        ]
        assertGateSkipsNothing(Scenario(name: "a config problem appears", new: new))
    }

    func test_themeMove_leavesTheAppWhereTheUngatedFanOutWould() throws {
        assertGateSkipsNothing(
            Scenario(
                name: "theme swap", new: .builtIn, oldTheme: Theme.current,
                newTheme: try makeAlternateTheme()))
    }

    func test_noChangeAtAll_leavesTheAppWhereTheUngatedFanOutWould() {
        assertGateSkipsNothing(Scenario(name: "nothing moved", new: .builtIn))
    }

    func test_severalKindsAtOnce_leaveTheAppWhereTheUngatedFanOutWould() {
        var new = GeneralConfig.builtIn
        new.keymap[Chord(command: true, shift: true, option: true, key: "u")] = .checkForUpdates
        new.reduceMotion = .off
        new.automaticUpdateChecks = !GeneralConfig.builtIn.automaticUpdateChecks
        assertGateSkipsNothing(Scenario(name: "rebind + motion + updates", new: new))
    }

    func test_theFingerprintIsDeterministic() {
        var new = GeneralConfig.builtIn
        new.keymap[Chord(command: true, shift: true, option: true, key: "u")] = .checkForUpdates
        let scenario = Scenario(name: "control", new: new)
        XCTAssertEqual(run(scenario, applying: .all), run(scenario, applying: .all))
    }

    func test_anUndeliveredDiagnosticIsRetriedOnTheNextReload() {
        var config = GeneralConfig.builtIn
        config.configDiagnostics = [
            ConfigDiagnostic(scope: .keybindLine, problem: .unparseableLine("keybind = nonsense"))
        ]
        GeneralConfig.setCurrentForTesting(config)

        let doubles = SinkDoubles(old: config)
        doubles.canDeliver = false
        let applier = ConfigApplier(sinks: doubles.sinks)

        applier.apply(.diagnostics)
        XCTAssertTrue(doubles.announced.isEmpty, "nothing could have shown it")

        doubles.canDeliver = true
        applier.apply([])
        XCTAssertEqual(
            doubles.announced.count, 1,
            "an undelivered config notice was never retried — it's stranded for the session")
    }

    func test_fixingTheConfig_retractsTheNoticeAlreadyOnScreen() {
        var broken = GeneralConfig.builtIn
        broken.configDiagnostics = [
            ConfigDiagnostic(scope: .keybindLine, problem: .unparseableLine("keybind = nonsense"))
        ]
        GeneralConfig.setCurrentForTesting(broken)

        let doubles = SinkDoubles(old: broken)
        let applier = ConfigApplier(sinks: doubles.sinks)
        applier.apply(.diagnostics)
        XCTAssertNotNil(doubles.showing, "expected the problem notice up")

        GeneralConfig.setCurrentForTesting(.builtIn)
        applier.apply(.diagnostics)
        XCTAssertNil(
            doubles.showing,
            "the config is clean but its problem notice is still on screen saying otherwise")
        XCTAssertEqual(doubles.announced.count, 1, "retracting must not itself announce anything")
    }

    func test_aChangedProblemSet_replacesTheNoticeRatherThanStacking() {
        var broken = GeneralConfig.builtIn
        broken.configDiagnostics = [
            ConfigDiagnostic(scope: .keybindLine, problem: .unparseableLine("keybind = nonsense"))
        ]
        GeneralConfig.setCurrentForTesting(broken)

        let doubles = SinkDoubles(old: broken)
        let applier = ConfigApplier(sinks: doubles.sinks)
        applier.apply(.diagnostics)

        GeneralConfig.setCurrentForTesting(Self.worsened(broken))
        applier.apply(.diagnostics)

        XCTAssertEqual(doubles.announced.count, 2, "the new set should have been announced")
        XCTAssertEqual(doubles.showing, doubles.announced.last, "the notice on screen is the stale one")
    }

    func test_aReplacementThatCannotBeDelivered_keepsTheCurrentNoticeUntilRetrySucceeds() {
        var broken = GeneralConfig.builtIn
        broken.configDiagnostics = [
            ConfigDiagnostic(scope: .keybindLine, problem: .unparseableLine("keybind = nonsense"))
        ]
        GeneralConfig.setCurrentForTesting(broken)

        let doubles = SinkDoubles(old: broken)
        let applier = ConfigApplier(sinks: doubles.sinks)
        applier.apply(.diagnostics)
        let firstNotice = doubles.showing
        XCTAssertNotNil(firstNotice, "expected the first problem notice up")

        GeneralConfig.setCurrentForTesting(Self.worsened(broken))
        doubles.canDeliver = false
        applier.apply(.diagnostics)

        XCTAssertEqual(doubles.showing, firstNotice, "failed replacement wrongly retracted the current notice")
        XCTAssertEqual(doubles.announced.count, 1, "failed replacement should not log a second announcement")

        doubles.canDeliver = true
        applier.apply([])
        XCTAssertEqual(doubles.announced.count, 2, "replacement was not retried once delivery became possible")
        XCTAssertEqual(doubles.showing, doubles.announced.last, "retry did not replace the notice on screen")
    }

    private static func worsened(_ config: GeneralConfig) -> GeneralConfig {
        var worse = config
        worse.configDiagnostics.append(
            ConfigDiagnostic(
                scope: .setting(key: "font-size"),
                problem: .invalidValue(got: "x", expected: "a number")))
        return worse
    }

    func test_aDeliveredDiagnosticIsNotReannouncedOnTheNextReload() {
        var config = GeneralConfig.builtIn
        config.configDiagnostics = [
            ConfigDiagnostic(scope: .keybindLine, problem: .unparseableLine("keybind = nonsense"))
        ]
        GeneralConfig.setCurrentForTesting(config)

        let doubles = SinkDoubles(old: config)
        let applier = ConfigApplier(sinks: doubles.sinks)

        applier.apply(.diagnostics)
        applier.apply([])
        applier.apply(.all)
        XCTAssertEqual(doubles.announced.count, 1, "the same config problem announced more than once")
    }

    private func makeAlternateTheme() throws -> AppTheme {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-applier-\(UUID().uuidString)", isDirectory: true)
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
