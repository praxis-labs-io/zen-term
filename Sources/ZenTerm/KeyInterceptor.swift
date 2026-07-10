import AppKit

/// Selective global interception: consume a small reserved allowlist of chrome
/// chords, pass everything else through to the PTY. This is the mechanism behind
/// the "don't steal Ctrl+hjkl from nvim" rule — un-reserved chords are returned
/// untouched so the terminal (and the program inside it) receives them.
final class KeyInterceptor {
    enum ReservedChord: Equatable {
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
        case addProject
    }

    var onReservedChord: ((ReservedChord) -> Void)?
    private var monitor: Any?

    /// The chord → action lookup. Defaults to the built-in map; `AppDelegate` overlays the
    /// user's config via `setKeymap` before `start()`. The interceptor stays a pure mechanism
    /// — it never reads `GeneralConfig` itself, so it's trivially unit-testable.
    private var keymap: [Chord: ReservedChord] = KeymapDefaults.map

    func setKeymap(_ map: [Chord: ReservedChord]) { keymap = map }

    func start() {
        stop()  // idempotent: never stack a second monitor on repeat calls
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Build the chord this event represents and look it up. A hit is consumed (never
            // reaches the PTY); a miss — including every un-reserved chord like Ctrl+hjkl —
            // passes straight through to the terminal. The ⌘⇧\ → "|" shifted-symbol quirk is
            // covered by the map holding both "|" and "\\" entries, so this stays pure lookup.
            guard let chord = Chord(event: event), let action = self.keymap[chord] else { return event }
            self.onReservedChord?(action)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { stop() }
}
