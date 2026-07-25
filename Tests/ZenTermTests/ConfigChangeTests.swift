import TerminalKit
import XCTest

@testable import ZenTerm

/// Unit tests for the change-kind diff (ZEN-48). The gate in the `.configDidChange` observers is
/// only as good as this diff: a kind that fails to light up when its field moves is stale chrome.
final class ConfigChangeTests: XCTestCase {
    private static func terminalTheme(fontName: String = "Menlo", fontSize: CGFloat = 14)
        -> TerminalTheme
    {
        let color = TerminalColor(red: 20, green: 30, blue: 40)
        return TerminalTheme(
            fontName: fontName, fontSize: fontSize, background: color, foreground: color,
            cursor: color, selectionBackground: color, ansi: Array(repeating: color, count: 16))
    }

    /// The real resolution shape: the terminal theme carries the general config's font, and the
    /// chrome roles derive from that theme — so a font edit moves the `AppTheme`.
    private func theme(_ config: GeneralConfig) -> AppTheme {
        let terminal = Self.terminalTheme(fontName: config.fontName, fontSize: config.fontSize)
        return AppTheme(terminal: terminal, chrome: ChromeThemeDeriver.derive(from: terminal))
    }

    private func change(
        from mutate: (inout GeneralConfig) -> Void, oldTheme: AppTheme? = nil, newTheme: AppTheme? = nil
    ) -> ConfigChange {
        let old = GeneralConfig.builtIn
        var new = old
        mutate(&new)
        let base = theme(old)
        return ConfigChange.between(
            old: old, new: new, oldTheme: oldTheme ?? base, newTheme: newTheme ?? base)
    }

    func test_identicalConfigAndTheme_yieldsNoChange() {
        XCTAssertEqual(change(from: { _ in }), [])
    }

    func test_keybindRebind_yieldsKeymapOnly() {
        let result = change(from: {
            $0.keymap[Chord(command: true, shift: true, option: true, control: true, key: "q")] =
                .splitHorizontal
        })
        XCTAssertEqual(result, .keymap)
    }

    /// The load-bearing one: a rebind must NOT light up the chrome-layout kind, or the gate saves
    /// nothing on the very write the ticket is about.
    func test_keybindRebind_doesNotYieldChromeLayout() {
        let result = change(from: {
            $0.keymap[Chord(command: true, shift: true, option: true, control: true, key: "q")] =
                .splitHorizontal
        })
        XCTAssertFalse(result.contains(.chromeLayout))
        XCTAssertFalse(result.contains(.theme))
        XCTAssertFalse(result.contains(.terminalBehavior))
        XCTAssertFalse(result.contains(.floats))
    }

    func test_eachChromeLayoutField_yieldsChromeLayout() {
        XCTAssertEqual(change(from: { $0.windowChrome.toggle() }), .chromeLayout)
        XCTAssertEqual(change(from: { $0.backdropAlpha += 0.1 }), .chromeLayout)
        XCTAssertEqual(change(from: { $0.windowGutter += 4 }), .chromeLayout)
        XCTAssertEqual(change(from: { $0.panelGap += 4 }), .chromeLayout)
    }

    func test_eachTerminalBehaviorField_yieldsTerminalBehavior() {
        XCTAssertEqual(change(from: { $0.cursorStyle = .bar }), .terminalBehavior)
        XCTAssertEqual(change(from: { $0.cursorBlink.toggle() }), .terminalBehavior)
        XCTAssertEqual(change(from: { $0.cursorThickness += 1 }), .terminalBehavior)
        XCTAssertEqual(change(from: { $0.optionAsAlt.toggle() }), .terminalBehavior)
        XCTAssertEqual(change(from: { $0.scrollMultiplier += 0.5 }), .terminalBehavior)
        XCTAssertEqual(change(from: { $0.cursorShader = "cursor_blaze" }), .terminalBehavior)
    }

    func test_remainingKinds_eachYieldTheirOwn() {
        let float = ToolFloat(
            id: "notes", order: 0, title: "Notes", icon: ToolFloatParser.defaultIcon, command: "ls",
            dir: nil, widthFraction: 0.85, heightFraction: 0.85, requiresGitRepo: false,
            persist: .ephemeral, toggle: Chord(command: true, shift: true, key: "n"))
        XCTAssertEqual(change(from: { $0.floats = [float] }), .floats)
        XCTAssertEqual(change(from: { $0.reduceMotion = .on }), .motion)
        XCTAssertEqual(change(from: { $0.automaticUpdateChecks.toggle() }), .updates)
        XCTAssertEqual(
            change(from: {
                $0.configDiagnostics = [
                    ConfigDiagnostic(scope: .keybindLine, problem: .floatMissingField("key:"))
                ]
            }), .diagnostics)
    }

    func test_themeMove_yieldsTheme() {
        let terminal = Self.terminalTheme(fontSize: 22)
        let other = AppTheme(terminal: terminal, chrome: ChromeThemeDeriver.derive(from: terminal))
        XCTAssertEqual(change(from: { _ in }, newTheme: other), .theme)
    }

    /// A font edit resolves into the `AppTheme` rather than being read on its own, so it must reach
    /// observers as `.theme` — the kind the surface re-appearance and chrome recolor gate on.
    func test_fontChange_reachesObserversAsTheme() {
        let old = GeneralConfig.builtIn
        var new = old
        new.fontSize = 20
        let result = ConfigChange.between(
            old: old, new: new, oldTheme: theme(old), newTheme: theme(new))
        XCTAssertTrue(result.contains(.theme))
    }

    func test_severalFieldsAtOnce_yieldTheUnion() {
        let result = change(from: {
            $0.windowGutter += 4
            $0.reduceMotion = .off
            $0.cursorBlink.toggle()
        })
        XCTAssertEqual(result, [.chromeLayout, .motion, .terminalBehavior])
    }

    /// The fail-safe: a notification posted without a change set must read as "everything moved",
    /// so a caller that doesn't diff gets the old do-everything behavior instead of stale chrome.
    func test_notificationWithoutUserInfo_readsAsAll() {
        let note = Notification(name: .configDidChange)
        XCTAssertEqual(ConfigChange.from(note), .all)
    }

    func test_notificationWithWrongTypeUnderTheKey_readsAsAll() {
        let note = Notification(
            name: .configDidChange, object: nil, userInfo: [ConfigChange.userInfoKey: "nonsense"])
        XCTAssertEqual(ConfigChange.from(note), .all)
    }

    func test_notificationWithAChangeSet_readsItBack() {
        let note = Notification(
            name: .configDidChange, object: nil,
            userInfo: [ConfigChange.userInfoKey: ConfigChange.keymap])
        XCTAssertEqual(ConfigChange.from(note), .keymap)
    }

    /// `.all` must actually contain every kind — a kind added to the type but left out of `.all`
    /// would make the fail-safe silently partial.
    func test_allContainsEveryKind() {
        for kind: ConfigChange in [
            .theme, .chromeLayout, .terminalBehavior, .floats, .keymap, .motion, .diagnostics, .updates,
        ] {
            XCTAssertTrue(ConfigChange.all.contains(kind), "\(kind.rawValue) missing from .all")
        }
    }
}
