import AppKit

/// The narrow capability the Settings Keybinds section needs from the key interceptor: divert
/// the next keystrokes to a capture handler instead of routing them, so recording a new chord
/// isn't pre-empted by the chord's current binding.
protocol KeybindCapturing: AnyObject {
    func beginCapture(_ handler: @escaping (NSEvent) -> Void)
    func endCapture()
}

/// The narrow capability a window needs to run a sticky keyboard mode: install a handler for the
/// keys the keymap didn't claim, and take it back down. Separate from `KeybindCapturing` because
/// the two differ in strength, not just in caller (see `modeHandler`).
protocol KeyModeHosting: AnyObject {
    var modeHandler: ((NSEvent) -> Bool)? { get set }
}

/// Selective global interception: consume a small reserved allowlist of chrome
/// chords, pass everything else through to the PTY. This is the mechanism behind
/// the "don't steal Ctrl+hjkl from nvim" rule — un-reserved chords are returned
/// untouched so the terminal (and the program inside it) receives them.
final class KeyInterceptor {
    enum ReservedChord: Hashable {
        case splitVertical, splitHorizontal
        case navLeft, navRight, navUp, navDown
        case closePane
        case newTab, newWindow
        case selectTab(Int)  // 1...9
        case prevTab, nextTab
        case resizeLeft, resizeRight, resizeUp, resizeDown
        case toggleBottomDrawer
        case toggleRightDrawer
        case toggleZoom  // the "Focus Mode" command (internal name stays `zoom`, distinct from pane focus)
        case fillScreen  // toggle the window to fill the desktop's visible frame (not native fullscreen)
        case toggleToolFloat(String)  // associated value = ToolFloat.id
        case toggleRepoPicker
        case toggleCommandPalette
        case openSettings
        case reloadConfig
        case checkForUpdates  // run a manual Sparkle update check (unbound by default; ZEN-20)
        case reportIssue  // open the Report an Issue composer (unbound by default; ZEN-212)
        case openDiffViewer  // open the diff viewer overlay (ZEN-226)
        // Terminal font size, app-wide (ZEN-224). Taken over from libghostty, which binds the same
        // chords itself but applies each to the one focused surface.
        case increaseFontSize, decreaseFontSize, resetFontSize
        case toggleScrollMode  // enter/leave scroll mode over the focused pane (ZEN-330)
        case toggleSearch  // open the find bar over the focused pane's scrollback (ZEN-324)
    }

    var onReservedChord: ((ReservedChord) -> Void)?

    /// Escape hatch for a terminal that owns a chord more than the chrome does: when this returns
    /// `true` for a chord that *did* hit the keymap, the real `NSEvent` is passed through to the
    /// terminal instead of being consumed — so the program inside receives a genuine `Ctrl-h`
    /// rather than the chord firing pane nav. `AppDelegate` returns `true` only for `Ctrl`-nav,
    /// and only over an nvim pane or an open tool float (`NavGuard` holds the truth table), so
    /// default `⌘`-nav is never affected.
    var passThroughGuard: ((Chord, ReservedChord) -> Bool)?
    private var monitor: Any?

    /// The chord → action lookup. Defaults to the built-in map; `AppDelegate` overlays the
    /// user's config via `setKeymap` before `start()`. The interceptor stays a pure mechanism
    /// — it never reads `GeneralConfig` itself, so it's trivially unit-testable.
    private var keymap: [Chord: ReservedChord] = KeymapDefaults.map

    func setKeymap(_ map: [Chord: ReservedChord]) { keymap = map }

    /// When set (the Settings card is recording), every keyDown — and flagsChanged, for the live
    /// modifier preview — is diverted here and consumed, bypassing keymap routing, so even a bound
    /// chord (⌘P) is captured, not fired.
    private var captureHandler: ((NSEvent) -> Void)?

    func beginCapture(_ handler: @escaping (NSEvent) -> Void) { captureHandler = handler }
    func endCapture() { captureHandler = nil }

    /// A sticky keyboard mode (scroll mode, ZEN-330) claiming the keys the keymap left alone.
    /// Returns whether it consumed the event; an event it declines still reaches the PTY.
    ///
    /// Weaker than `captureHandler` on purpose, and consulted after chord routing rather than
    /// before it. A mode that also swallowed ⌘T, ⌘P and pane nav would brick the app for as long
    /// as it stayed up. This way a reserved chord still wins, so the mode's own exit chord fires
    /// and a user's `ctrl+j` still navigates, while every un-reserved key routes here, including
    /// the bare `j`/`k`/`g` no chord can ever hold.
    var modeHandler: ((NSEvent) -> Bool)?

    func start() {
        stop()  // idempotent: never stack a second monitor on repeat calls
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            return self.route(event)
        }
    }

    /// The monitor's whole decision, factored out of the live closure so it's unit-testable the
    /// same way `resolve(_:)` is. Returns the event to pass on, or nil to consume it.
    ///
    /// Order is the design: capture beats everything, then reserved chords, then a sticky mode,
    /// then the PTY. A mode sits below chords so it can't brick ⌘T or pane nav for as long as it
    /// is up, and above the PTY so it can claim the bare keys no chord is allowed to hold.
    func route(_ event: NSEvent) -> NSEvent? {
        if let captureHandler {
            captureHandler(event)  // keyDown AND flagsChanged (live modifier preview) are diverted
            return nil  // consumed — never routes or reaches the PTY while capturing
        }
        // Outside capture, flagsChanged passes straight through; only keyDown routes to a chord.
        guard event.type == .keyDown else { return event }
        // A reserved chord always carries a modifier (`Chord.parse` rejects modifier-less
        // binds), so a bare keystroke can never match the keymap. Skip the Chord + its
        // lowercased string on the hot per-keystroke path rather than allocating to miss.
        let reservableModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        if !event.modifierFlags.intersection(reservableModifiers).isEmpty {
            switch resolve(Chord(event: event)) {
            case .consume(let action):
                // A repeat the action declines is still consumed, not passed on: the chord is
                // ours for as long as it is held, and handing the raw keystroke to the program
                // mid-hold would put a ⌘N into the shell after the first window opened.
                if !event.isARepeat || action.shouldRepeat { onReservedChord?(action) }
                return nil
            case .deferToTerminal:
                return event  // the guard gave this one to the program; nothing else may take it
            case .passThrough:
                break
            }
        }
        // Nothing reserved wanted it. A sticky mode gets the refusal before the PTY does.
        if modeHandler?(event) == true { return nil }
        return event
    }

    /// What to do with a resolved keyDown, factored out of the live monitor so it's
    /// unit-testable. A miss — a nil chord or an un-reserved chord like an unbound Ctrl+hjkl —
    /// passes through to the terminal. A hit is consumed, unless the pass-through guard vetoes
    /// it (Ctrl-nav over an nvim pane or an open tool float), in which case it passes through too
    /// so the program receives the real key. The ⌘⇧\ → "|" shifted-symbol quirk is absorbed by `Chord`'s canonicalizing
    /// `init` — the event and the bind fold onto the same key — so this stays a pure lookup.
    func resolve(_ chord: Chord?) -> Route {
        guard let chord, let action = keymap[chord] else { return .passThrough }
        if passThroughGuard?(chord, action) == true { return .deferToTerminal }
        return .consume(action)
    }

    /// The outcome of `resolve(_:)`.
    ///
    /// `passThrough` and `deferToTerminal` both end up at the PTY, and the distinction between
    /// them is load-bearing anyway: `passThrough` means nothing claimed the key, so a sticky mode
    /// may still take it. `deferToTerminal` means a chord *did* match and the guard handed it to
    /// the program on purpose, so nothing else may touch it. Collapsing the two let scroll mode
    /// eat the `Ctrl`-nav that was being handed to nvim.
    enum Route: Equatable {
        case passThrough
        case deferToTerminal
        case consume(ReservedChord)
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { stop() }
}

extension KeyInterceptor: KeybindCapturing {}
extension KeyInterceptor: KeyModeHosting {}
