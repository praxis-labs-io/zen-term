import AppKit
import TerminalKit
import XCTest

@testable import ZenTerm

/// Differential tests for the app-global half of the `.configDidChange` fan-out.
///
/// The fan-out was gated by change kind on the premise "no behavior change intended", and
/// nothing checked it. Two regressions shipped past a green suite, both in this observer, both
/// caught by reading the diff rather than by a failing test — and the second was the *same shape*
/// as the first, made twenty minutes later. Re-deriving four-deep call chains by hand does not
/// scale, so this checks the invariant directly instead of enumerating dependencies:
///
/// > For any config change, the **gated** fan-out must leave the app identical to the **ungated**
/// > one.
///
/// A gate that is too narrow makes the two diverge, whether or not anyone knew the dependency was
/// there. **Honest limit:** it only covers what the fingerprint samples.
///
/// The doubles model *resulting state*, not calls made, and each is seeded with the **old** value
/// exactly as the real collaborator would hold it. "Was it called" is the wrong question: under
/// `.all` every sink fires, and re-applying an unchanged value is a no-op, so a call-count
/// comparison would report a difference on every scenario.
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

    // MARK: - doubles

    /// Stand-ins for the app-global collaborators, each holding the state its real counterpart
    /// would. The update card is the exception and deliberately so: it's a **real**
    /// `UpdateCardView`, driven through its real `reapplyTheme()`. That call chain
    /// (`reapplyTheme` → `refreshKeycap` → the live keymap) is regression #2, and a modelled fake
    /// would only ever prove the model right.
    private final class SinkDoubles {
        var keymap: [Chord: KeyInterceptor.ReservedChord]
        /// The keymap the shadow report last read. That sink returns nothing (it logs), so the state
        /// it lands on is *which* keymap it was asked about.
        var shadowKeymap: [Chord: KeyInterceptor.ReservedChord]
        var motion: GeneralConfig.ReduceMotion
        var autoChecks: Bool
        var announced: [ToastContent] = []
        /// The notice **currently on screen**, as opposed to the log of every one ever raised. The
        /// config notice is sticky, so this is the thing a user is actually looking at.
        var showing: ToastContent?
        /// The chord conflicts carded, one per card.
        var conflicts: [KeybindConflict] = []
        /// Whether a window is there to take a notice. The real sink returns false when the key
        /// window isn't one of ours (an open panel).
        var canDeliver = true
        /// The payload `theme.json` holds. Seeded with the *old* theme, because that is what the
        /// file on disk already carries — nil would model "was it called", and re-publishing an
        /// unchanged theme is a no-op that would then read as a divergence.
        var published: ThemePublisher.Payload
        let card: UpdateCardView

        /// Built while `GeneralConfig.current` is still the *old* config, so the card bakes in the
        /// old keycap and every field starts where the running app would have it.
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
                // The real sink takes no value either; it reads the live keymap when it runs.
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
                // The real sink re-reads the live config rather than taking a value.
                applyAutoCheckSetting: { [unowned self] in
                    self.autoChecks = GeneralConfig.current.automaticUpdateChecks
                },
                // The real sink resolves the payload from the live statics, so this does too. The
                // `nvimColorscheme` half needs the filesystem and is asserted in `ThemePublisherTests`.
                publishTheme: { [unowned self] in
                    self.published = ThemePublisher.payload(
                        for: Theme.current, themeName: GeneralConfig.current.themeName)
                })
        }
    }

    /// Everything the fan-out is allowed to have moved. Equatable so gated and ungated compare
    /// whole, rather than one assertion per field going stale as fields are added.
    private struct AppFingerprint: Equatable {
        /// The keymap the sink holds, flattened to sorted `chord = action` lines. Flattened rather
        /// than held as the dictionary because a failure prints the whole thing, and two raw
        /// 33-entry maps is a wall nobody reads.
        var keymap: [String]
        /// The keymap the shadow report ran against, same flattening as above.
        var shadowKeymap: [String]
        var motion: GeneralConfig.ReduceMotion
        var autoChecks: Bool
        /// The glyph the card's keycap was **built** with — empty when the chord is unbound.
        var cardKeycap: String
        /// Every label the card rendered, so a re-render that drops content shows up too.
        var cardText: [String]
        var announced: [ToastContent]
        /// The notice left on screen. Distinct from `announced`: a gate that raised the right
        /// warning but failed to retract it lands here, not there.
        var showing: ToastContent?
        /// What `theme.json` holds after the fan-out.
        var published: ThemePublisher.Payload

        /// Which fields moved, for the failure message. Equality above is what makes the assertion
        /// correct; this only makes it readable, so a field missing here degrades to a vaguer
        /// message rather than a missed regression.
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

    // MARK: - harness

    /// A config move: where the app starts, and where the reload leaves it.
    private struct Scenario {
        var name: String
        var old: GeneralConfig = .builtIn
        var new: GeneralConfig
        var oldTheme: AppTheme?
        var newTheme: AppTheme?
    }

    /// Put the statics in the scenario's *old* state, build a fresh applier against fresh doubles,
    /// move the statics to the *new* state, and apply `change` — the exact sequence
    /// `AppConfig.reload()` drives.
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

    /// The invariant. The gated run gets the real diff `AppConfig.reload()` would compute; the
    /// ungated run gets `.all`, which is the earlier behavior.
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

    // MARK: - scenarios

    /// Regression #2's shape. `.checkForUpdates` is unbound by default, so binding it moves the
    /// card's keycap — and the card is re-themed only when the gate lets a `.keymap` change reach
    /// it. Gate it on `.theme` alone and the gated run keeps an empty keycap while the ungated run
    /// shows the new glyph.
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

    /// A write that resolved to no change at all still has to leave the app where `.all` would —
    /// this is the empty-change-set case, which is exactly what strands an undelivered diagnostic
    /// when `surfaceConfigDiagnostics` is wrongly gated.
    func test_noChangeAtAll_leavesTheAppWhereTheUngatedFanOutWould() {
        assertGateSkipsNothing(Scenario(name: "nothing moved", new: .builtIn))
    }

    /// Several kinds in one write (a Settings save touches more than one row).
    func test_severalKindsAtOnce_leaveTheAppWhereTheUngatedFanOutWould() {
        var new = GeneralConfig.builtIn
        new.keymap[Chord(command: true, shift: true, option: true, key: "u")] = .checkForUpdates
        new.reduceMotion = .off
        new.automaticUpdateChecks = !GeneralConfig.builtIn.automaticUpdateChecks
        assertGateSkipsNothing(Scenario(name: "rebind + motion + updates", new: new))
    }

    /// The harness's own control. If a fingerprint isn't stable across two identical runs, every
    /// assertion above is meaningless — a flaky probe would read as a gate bug.
    func test_theFingerprintIsDeterministic() {
        var new = GeneralConfig.builtIn
        new.keymap[Chord(command: true, shift: true, option: true, key: "u")] = .checkForUpdates
        let scenario = Scenario(name: "control", new: new)
        XCTAssertEqual(run(scenario, applying: .all), run(scenario, applying: .all))
    }

    // MARK: - sequences the differential shape can't reach

    /// Regression #1. `surfaceConfigDiagnostics` is ungated because it already has a finer gate:
    /// it records a notice as announced only once a window has actually shown it. Gate it on
    /// `.diagnostics` and an undelivered notice is stranded forever — the diagnostics haven't
    /// changed, so the retry never comes.
    ///
    /// A single-apply differential can't see this: it's about the *second* reload, whose change set
    /// is empty precisely because nothing about the config moved.
    func test_anUndeliveredDiagnosticIsRetriedOnTheNextReload() {
        var config = GeneralConfig.builtIn
        config.configDiagnostics = [
            ConfigDiagnostic(scope: .keybindLine, problem: .unparseableLine("keybind = nonsense"))
        ]
        GeneralConfig.setCurrentForTesting(config)

        let doubles = SinkDoubles(old: config)
        doubles.canDeliver = false  // no window of ours is key — an open panel has focus
        let applier = ConfigApplier(sinks: doubles.sinks)

        applier.apply(.diagnostics)
        XCTAssertTrue(doubles.announced.isEmpty, "nothing could have shown it")

        // A window is back. The next reload changed nothing, so its change set is empty — the
        // retry has to happen anyway.
        doubles.canDeliver = true
        applier.apply([])
        XCTAssertEqual(
            doubles.announced.count, 1,
            "an undelivered config notice was never retried — it's stranded for the session")
    }

    /// The notice is sticky and describes what's wrong *now*, so fixing the config has to take it
    /// down. Nothing else does: `ConfigDiagnostic.announcement` returns nil for an empty set, which
    /// is indistinguishable from "nothing changed", so the warning outlived the fix that made it
    /// false and sat there contradicting a config that was already clean.
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

        GeneralConfig.setCurrentForTesting(.builtIn)  // the user fixed the file
        applier.apply(.diagnostics)
        XCTAssertNil(
            doubles.showing,
            "the config is clean but its problem notice is still on screen saying otherwise")
        XCTAssertEqual(doubles.announced.count, 1, "retracting must not itself announce anything")
    }

    /// A changed set replaces the notice rather than stacking a second card beside one that
    /// describes a different set of problems.
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

    /// Replacing the notice is "all or nothing": if no window can take the new one, keep the
    /// existing notice up and retry the replacement on the next reload.
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

    /// The same problems plus one more, so the set is genuinely different.
    private static func worsened(_ config: GeneralConfig) -> GeneralConfig {
        var worse = config
        worse.configDiagnostics.append(
            ConfigDiagnostic(
                scope: .setting(key: "font-size"),
                problem: .invalidValue(got: "x", expected: "a number")))
        return worse
    }

    /// The other half of that gate: once delivered, an unchanged set stays quiet. Every in-app
    /// write reloads (a Settings rebind, a float save), and re-announcing a conflict the user
    /// already read on each of those is noise.
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

    // MARK: - helpers

    /// A theme whose accent (ANSI slot 5) is a clearly distinct `#00ff00`, built through the same
    /// `ConfigLoader.loadAppTheme` path the other re-apply tests use.
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
        """.write(to: dir.appendingPathComponent("theme"), atomically: true, encoding: .utf8)
        return ConfigLoader.loadAppTheme(configRoot: dir, general: .builtIn)
    }
}
