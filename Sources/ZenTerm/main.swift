import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)

// Top-level code is nonisolated, and it is also the main thread by definition — this runs before
// `app.run()` on the thread that will be the main actor's.
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate

app.run()
