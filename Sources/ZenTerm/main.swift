import AppKit
import TerminalKit

// Backend swap point. libghostty is the default (ZEN-45);
// `ZENTERM_BACKEND=swiftterm` is the escape hatch back to the SwiftTerm backend.
if ProcessInfo.processInfo.environment["ZENTERM_BACKEND"] == "swiftterm" {
    TerminalSurfaceFactory.backend = .swiftTerm
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
