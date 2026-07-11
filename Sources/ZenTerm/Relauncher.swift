import AppKit

/// Restart the app to apply a change that the running process can't hot-swap (a theme, today).
/// Spawns a fresh instance, then terminates this one. Packaged `.app` relaunches via `/usr/bin/open
/// -n` (which forces a new instance, so there's no dedup race to work around); a bare dev executable
/// relaunches itself directly. Runs the process straight — no shell — so a bundle path containing
/// shell metacharacters can't be interpreted. If neither resolves, it logs and no-ops (the config
/// write already persisted).
enum Relauncher {
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let task = Process()
        if bundleURL.pathExtension == "app" {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-n", bundleURL.path]
        } else if let exe = Bundle.main.executablePath {
            task.executableURL = URL(fileURLWithPath: exe)
        } else {
            NSLog("Relauncher: no bundle or executable path to relaunch — restart manually to apply.")
            return
        }
        do {
            try task.run()
        } catch {
            NSLog("Relauncher: failed to spawn restart helper: \(error) — restart manually.")
            return
        }
        NSApp.terminate(nil)
    }
}
