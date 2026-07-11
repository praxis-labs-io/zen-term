import AppKit

/// Restart the app to apply a change that the running process can't hot-swap (a theme, today).
enum Relauncher {
    /// Set when the user asks to restart-to-apply; consumed in applicationWillTerminate so the fresh
    /// instance spawns ONLY once termination actually proceeds. Spawning before terminate could leave
    /// two instances if the quit-confirm is cancelled.
    private(set) static var isRelaunchPending = false

    /// Ask to restart. Requests termination (which may show a quit-confirm); the replacement is
    /// spawned from applicationWillTerminate if and only if the app actually quits.
    static func relaunch() {
        isRelaunchPending = true
        NSApp.terminate(nil)
    }

    /// Called from AppDelegate.applicationWillTerminate — the point of no return. Spawns a fresh
    /// instance detached, so it starts as this one exits. Packaged `.app` uses `/usr/bin/open -n`
    /// (forces a new instance); a bare dev executable relaunches itself. No shell, so a bundle path
    /// with shell metacharacters can't be interpreted.
    static func performPendingRelaunchIfNeeded() {
        guard isRelaunchPending else { return }
        isRelaunchPending = false
        let bundleURL = Bundle.main.bundleURL
        let task = Process()
        if bundleURL.pathExtension == "app" {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-n", bundleURL.path]
        } else if let exe = Bundle.main.executablePath {
            task.executableURL = URL(fileURLWithPath: exe)
        } else {
            NSLog("Relauncher: no bundle or executable path to relaunch; restart manually to apply.")
            return
        }
        do {
            try task.run()
        } catch {
            NSLog("Relauncher: failed to spawn restart helper: \(error); restart manually.")
        }
    }
}
