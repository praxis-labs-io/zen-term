import AppKit

/// Selective global interception: consume a small reserved allowlist of chrome
/// chords, pass everything else through to the PTY. This is the mechanism behind
/// the "don't steal Ctrl+hjkl from nvim" rule — un-reserved chords are returned
/// untouched so the terminal (and the program inside it) receives them.
final class KeyInterceptor {
    enum ReservedChord {
        case splitVertical, splitHorizontal
        case navLeft, navRight, navUp, navDown
        case closePane
        case newTab, newWindow
        case selectTab(Int)  // 1...9
        case prevTab, nextTab
        case resizeLeft, resizeRight, resizeUp, resizeDown
        case toggleBottomDrawer
        case toggleRightDrawer
        case toggleZoom
        case toggleLazygit
        case toggleToolFloat(String)  // associated value = ToolFloat.id
        case toggleRepoPicker
        case toggleCommandPalette
        case newWebPane
    }

    var onReservedChord: ((ReservedChord) -> Void)?
    private var monitor: Any?

    func start() {
        stop()  // idempotent: never stack a second monitor on repeat calls
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased()

            // ⌘⇧ family: vertical split (⌘⇧\ → "|"; also "\\" defensively), pane/drawer
            // resize on ⌘⇧HJKL — the same HJKL directions as ⌘-nav, Shift meaning "push the
            // divider" instead of "hop to the neighbor" — and ⌘⇧P for the repo picker (bare
            // ⌘P now opens the command palette instead). With Shift held,
            // charactersIgnoringModifiers is the shifted glyph, so `.lowercased()` normalizes
            // "H" → "h". Unmatched ⌘⇧ chords fall through to the terminal.
            if flags == [.command, .shift] {
                let chord: ReservedChord?
                switch key {
                case "|", "\\": chord = .splitVertical
                case "h": chord = .resizeLeft
                case "l": chord = .resizeRight
                case "k": chord = .resizeUp
                case "j": chord = .resizeDown
                case "p": chord = .toggleRepoPicker
                case "b": chord = .newWebPane  // ⌘⇧B — split a web pane in (spike)
                case "g": chord = .toggleToolFloat("gitdash")  // ⌘⇧G — per-float keybinding
                default: chord = nil
                }
                if let chord { self.onReservedChord?(chord); return nil }
                return event
            }

            guard flags == .command else { return event }  // all other reserved chords are bare-⌘

            let chord: ReservedChord?
            switch key {
            case "\\": chord = .toggleRightDrawer
            case "[": chord = .prevTab
            case "]": chord = .nextTab
            case "-": chord = .splitHorizontal
            case "h": chord = .navLeft
            case "l": chord = .navRight
            case "k": chord = .navUp
            case "j": chord = .navDown
            case "w": chord = .closePane
            case "t": chord = .newTab
            case "n": chord = .newWindow
            case "b": chord = .toggleBottomDrawer
            case "f": chord = .toggleZoom
            case "g": chord = .toggleLazygit
            case "p": chord = .toggleCommandPalette
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                chord = key.flatMap { Int($0) }.map { .selectTab($0) }
            default: chord = nil
            }
            if let chord {
                self.onReservedChord?(chord)
                return nil  // consumed — never reaches the PTY
            }
            return event  // everything else passes through
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { stop() }
}
