import Foundation

extension Notification.Name {
    /// Posted after `AppConfig` re-resolves the config statics, so living consumers (the keymap,
    /// chrome layout, terminal surfaces) re-apply. `persist` and `reload` post it on the main
    /// thread, which is every path a shipping build has.
    static let configDidChange = Notification.Name("ZenTerm.configDidChange")
}

/// The save→reload→apply seam. A Settings edit writes `config` via `ConfigWriter`, the launch
/// statics are re-resolved from disk, and `configDidChange` broadcasts. The invariant: after any
/// write + reload, `GeneralConfig.current` / `Theme.current` mirror the file.
///
/// **The write runs off the main thread; re-resolving stays on it** (ZEN-17). The write is the
/// expensive half — a whole-file read-modify-rewrite plus an atomic replace, fired every ~180ms
/// while a Settings control settles — and on a network-backed or cloud-synced home that is the
/// ZEN-90 stall this removes.
///
/// **Re-resolving cannot move off main, and the reason is not obvious.** Parsing the config
/// assembles the keymap, and that consults the keyboard layout through Carbon
/// (`KeyboardLayout.canType` -> `TISCopyCurrentKeyboardLayoutInputSource`). TIS is main-thread-only
/// in a GUI app: called from a background queue it takes the whole process down, cleanly, with no
/// crash report. It does NOT do that under `swift test`, where TIS answers happily off-main, so a
/// green suite is not evidence here — this cost a day and was only ever caught by the running app.
/// Anything moved off this queue has to be checked in `swift run ZenTerm`, not in a test.
enum AppConfig {
    /// Serial, and shared by writes and reloads. Every config edit is a whole-file
    /// read-modify-rewrite, so two overlapping writes would both read the pre-edit file and the
    /// second would erase the first. One queue keeps the ordering the main thread used to provide,
    /// and keeps a re-resolve from reading the file between a write's read and its rewrite.
    private static let queue = DispatchQueue(label: "com.zenterm.config-write", qos: .userInitiated)

    /// Run `write` on the queue, then re-resolve and apply on main. `completion` lands on main
    /// either way, carrying the write's error or nil when it landed.
    ///
    /// A failed write skips the re-resolve — nothing changed on disk, and re-applying would post a
    /// `configDidChange` that says otherwise.
    ///
    /// **`write` runs on the queue, so it must close over values, not chrome state.** Snapshot what
    /// it needs on main first: reading a view model's array in there is a read of main-thread state
    /// from another thread, and it can see an edit the user made after the write was enqueued.
    static func persist(_ write: @escaping () throws -> Void, completion: @escaping (Error?) -> Void) {
        beginResolve()
        queue.async {
            do {
                try write()
            } catch {
                afterPendingResolves {
                    endResolve()
                    completion(error)
                }
                return
            }
            resolveAndApply { completion(nil) }
        }
    }

    /// Re-resolve from disk with no write of our own — the Reload Config command (⌘⌥R), which is
    /// how a hand-edit made outside the app is picked up. Runs on the same queue as `persist`, so
    /// it can't read a config mid-rewrite.
    static func reload(completion: (() -> Void)? = nil) {
        beginResolve()
        queue.async { resolveAndApply { completion?() } }
    }

    #if DEBUG
        /// Test hook: resolve and apply on the calling thread, blocking on both file reads.
        ///
        /// Tests use it to pin the statics to a known config in `setUp`, where the async form would
        /// return before the swap landed. **Call it on the main thread**, like every caller does: it
        /// applies wherever it's called, so calling it off-main would swap the statics and post
        /// `configDidChange` from another thread. Compiled out of release builds, so app code can't
        /// reach for it: there, `persist` / `reload` are the only way in, and a blocking read on the
        /// main queue is the stall they exist to remove.
        static func reloadBlocking() {
            let general = ConfigLoader.loadGeneralConfig()
            apply((general, ConfigLoader.loadAppTheme(general: general)))
        }

        /// Test hook: call back on main once everything already enqueued has been applied.
        ///
        /// A barrier rather than a `reload`, because a reload would post its own `configDidChange`,
        /// and a card that re-renders on that clears the per-edit messages a test is about to assert
        /// (the displaced-shortcut notice, for one). Enqueueing an empty block is enough: the queue is
        /// serial, and the completions ahead of it were handed to main ahead of this one.
        static func drainForTesting(_ completion: @escaping () -> Void) {
            queue.async {
                DispatchQueue.main.async {
                    // Re-arm rather than count hops: a resolve is queue -> main -> queue -> main, and
                    // a barrier that assumed a fixed depth would return between the parse and the
                    // apply. `inFlight` hits zero only once every resolve has applied.
                    guard inFlight == 0 else { return drainForTesting(completion) }
                    completion()
                }
            }
        }
    #endif

    /// Re-resolve and apply, **starting on the queue**: each file read runs there and each parse
    /// runs on main, so the main thread never waits on the filesystem and never reaches Carbon from
    /// the wrong thread.
    ///
    ///     queue: read `config`  ->  main: parse it  ->  queue: read the theme  ->  main: build + adopt
    ///
    /// The theme read needs the parsed config (the `theme` key names the file), which is why it is
    /// two hops rather than one. `done` runs on main after the apply, and runs even when a newer
    /// resolve superseded this one.
    private static func resolveAndApply(then done: @escaping () -> Void) {
        let configText = ConfigLoader.readGeneralConfigText()
        DispatchQueue.main.async {
            resolveGeneration += 1
            let generation = resolveGeneration
            let general = ConfigLoader.parseGeneralConfig(configText)
            queue.async {
                let themeText = ConfigLoader.readThemeText(general: general)
                DispatchQueue.main.async {
                    defer {
                        endResolve()
                        done()
                    }
                    // A newer resolve read a newer file and owns the statics. Applying underneath it
                    // would put this pass's general config next to that pass's theme, and the two
                    // disagree about the font.
                    guard generation == resolveGeneration else { return }
                    apply((general, ConfigLoader.makeAppTheme(themeText: themeText, general: general)))
                }
            }
        }
    }

    /// Bumped per resolve on main, so a superseded pass can tell. Main-thread only, like the
    /// statics it guards.
    private static var resolveGeneration = 0

    /// Resolves started and not yet applied. Main-thread only, and the reason `drainForTesting`
    /// doesn't have to know how many queue hops a resolve takes.
    private static var inFlight = 0

    /// Called on main by `persist` / `reload` before the queue work starts, so a drain enqueued
    /// straight after the call already sees the resolve as outstanding.
    private static func beginResolve() {
        dispatchPrecondition(condition: .onQueue(.main))
        inFlight += 1
    }

    private static func endResolve() { inFlight -= 1 }

    /// Deliver on main once every resolve that was already in flight has applied.
    ///
    /// A failed write resolves nothing, so its completion would otherwise take a single hop home and
    /// overtake an earlier write's apply, handing the caller statics that still predate it. The
    /// keybinds card rebases `desired` on `GeneralConfig.current` there, so overtaking would roll an
    /// already-saved rebind back out and the next write would persist the loss. Yields through the
    /// queue between checks rather than re-arming on main, so a slow read can't be spun on.
    private static func afterPendingResolves(_ body: @escaping () -> Void) {
        queue.async {
            DispatchQueue.main.async {
                guard inFlight <= 1 else { return afterPendingResolves(body) }  // 1 is our own
                body()
            }
        }
    }

    /// Swap both statics and broadcast. General first, then theme, matching the order they resolve
    /// in — a consumer reading both from the notification sees a matched pair either way, but
    /// adopting them apart would leave a window where the theme's font disagrees with the config's.
    private static func apply(_ resolved: (general: GeneralConfig, theme: AppTheme)) {
        GeneralConfig.adopt(resolved.general)
        Theme.adopt(resolved.theme)
        NotificationCenter.default.post(name: .configDidChange, object: nil)
    }
}
