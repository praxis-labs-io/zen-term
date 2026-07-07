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
        case selectTab(Int)   // 1...9
        case toggleBottomDrawer
        case toggleRightDrawer
    }

    var onReservedChord: ((ReservedChord) -> Void)?
    private var monitor: Any?

    func start() {
        stop() // idempotent: never stack a second monitor on repeat calls
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased()

            // The one reserved ⌘⇧ chord: ⌘⇧\ ( "⌘|" ) → right drawer. With shift held,
            // charactersIgnoringModifiers is "|"; also accept "\\" defensively.
            if flags == [.command, .shift], key == "|" || key == "\\" {
                self.onReservedChord?(.toggleRightDrawer)
                return nil
            }

            guard flags == .command else { return event }   // all other reserved chords are bare-⌘

            let chord: ReservedChord?
            switch key {
            case "\\": chord = .splitVertical
            case "-":  chord = .splitHorizontal
            case "h":  chord = .navLeft
            case "l":  chord = .navRight
            case "k":  chord = .navUp
            case "j":  chord = .navDown
            case "w":  chord = .closePane
            case "t": chord = .newTab
            case "n": chord = .newWindow
            case "b": chord = .toggleBottomDrawer
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                chord = key.flatMap { Int($0) }.map { .selectTab($0) }
            default:   chord = nil
            }
            if let chord {
                self.onReservedChord?(chord)
                return nil                                   // consumed — never reaches the PTY
            }
            return event                                     // everything else passes through
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { stop() }
}
