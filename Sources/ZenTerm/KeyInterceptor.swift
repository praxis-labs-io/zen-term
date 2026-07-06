import AppKit

/// Selective global interception: consume a small reserved allowlist of chrome
/// chords, pass everything else through to the PTY. This is the mechanism behind
/// the "don't steal Ctrl+hjkl from nvim" rule — un-reserved chords are returned
/// untouched so the terminal (and the program inside it) receives them.
final class KeyInterceptor {
    enum ReservedChord { case close, logProbe }

    var onReservedChord: ((ReservedChord) -> Void)?
    private var monitor: Any?

    func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased()

            // Reserved allowlist — consume (return nil), never reaches the terminal.
            if flags == .command, key == "w" {
                self.onReservedChord?(.close)
                return nil
            }
            if flags == .command, key == "k" {
                self.onReservedChord?(.logProbe)
                return nil
            }

            // Everything else — including Ctrl+H — passes straight through.
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
