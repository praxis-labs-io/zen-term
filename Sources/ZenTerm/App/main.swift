import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate

app.run()
