import AppKit
import TerminalKit

// Backend swap point (ZEN-40 spike). SwiftTerm is the default shipping core;
// `ZENTERM_BACKEND=ghostty` selects the libghostty backend to try it out.
if ProcessInfo.processInfo.environment["ZENTERM_BACKEND"] == "ghostty" {
    TerminalSurfaceFactory.backend = .ghostty
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = AppDelegate()
app.delegate = delegate

app.run()
