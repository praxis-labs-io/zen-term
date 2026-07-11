import AppKit

/// Restart the app to apply a change that the running process can't hot-swap (a theme, today).
/// Spawns a fresh instance detached from this process, then terminates — the child starts once
/// this one has exited. Packaged `.app` relaunches via `open`; a bare dev executable relaunches
/// itself; if neither resolves, it logs and no-ops (the config write already persisted).
enum Relauncher {
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let isAppBundle = bundleURL.pathExtension == "app"
        let command: String
        if isAppBundle {
            // `open` waits for nothing; the short sleep lets this process exit first so the
            // freshly-opened instance isn't deduplicated against the still-dying one.
            command = "sleep 0.3; open \"\(bundleURL.path)\""
        } else if let exe = Bundle.main.executablePath {
            command = "sleep 0.3; \"\(exe)\""
        } else {
            NSLog("Relauncher: no bundle or executable path to relaunch — restart manually to apply.")
            return
        }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", command]
        do {
            try task.run()
        } catch {
            NSLog("Relauncher: failed to spawn restart helper: \(error) — restart manually.")
            return
        }
        NSApp.terminate(nil)
    }
}
