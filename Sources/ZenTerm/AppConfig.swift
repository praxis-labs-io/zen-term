import Foundation

extension Notification.Name {
    /// Posted after `AppConfig` re-resolves the config statics, so living consumers (the keymap,
    /// chrome layout, terminal surfaces) re-apply. Always posted on the main thread.
    static let configDidChange = Notification.Name("ZenTerm.configDidChange")
}

/// The save→reload→apply seam. A Settings edit writes `config` via `ConfigWriter`, the launch
/// statics are re-resolved from disk, and `configDidChange` broadcasts. The invariant: after any
/// write + reload, `GeneralConfig.current` / `Theme.current` mirror the file.
///
/// **The file I/O runs off the main thread and only the apply runs on it** (ZEN-17). A write is a
/// whole-file read-modify-rewrite plus two reads to re-resolve, and Settings live-apply fires one
/// every ~180ms while a control settles; on a network-backed or cloud-synced home that is the
/// ZEN-90 stall. The statics stay main-thread-only regardless: every reader of them is chrome, so
/// the values are resolved off-main and assigned on it, which is why `GeneralConfig.adopt` and
/// `Theme.adopt` take a value rather than reading the file themselves.
enum AppConfig {
    /// Serial, and shared by writes and reloads. Every config edit is a whole-file
    /// read-modify-rewrite, so two overlapping writes would both read the pre-edit file and the
    /// second would erase the first. One queue keeps the ordering the main thread used to provide,
    /// and keeps a re-resolve from reading the file between a write's read and its rewrite.
    private static let queue = DispatchQueue(label: "com.zenterm.config-write", qos: .userInitiated)

    /// Run `write`, re-resolve, and apply: the write and both reads on the queue, the apply on main.
    /// `completion` lands on main either way, carrying the write's error or nil when it landed.
    ///
    /// A failed write skips the re-resolve — nothing changed on disk, and re-applying would post a
    /// `configDidChange` that says otherwise.
    static func persist(_ write: @escaping () throws -> Void, completion: @escaping (Error?) -> Void) {
        queue.async {
            do {
                try write()
            } catch {
                DispatchQueue.main.async { completion(error) }
                return
            }
            let resolved = resolve()
            DispatchQueue.main.async {
                apply(resolved)
                completion(nil)
            }
        }
    }

    /// Re-resolve from disk with no write of our own — the Reload Config command (⌘⌥R), which is
    /// how a hand-edit made outside the app is picked up. Runs on the same queue as `persist`, so
    /// it can't read a config mid-rewrite.
    static func reload(completion: (() -> Void)? = nil) {
        queue.async {
            let resolved = resolve()
            DispatchQueue.main.async {
                apply(resolved)
                completion?()
            }
        }
    }

    /// Resolve and apply on the calling thread, blocking on both file reads.
    ///
    /// This is what tests use to pin the statics to a known config in `setUp`, where the async form
    /// would return before the swap landed. App code uses `persist` / `reload`: calling this from
    /// the main thread is the stall they exist to remove.
    static func reloadBlocking() {
        apply(resolve())
    }

    #if DEBUG
        /// Test hook: call back on main once everything already enqueued has been applied.
        ///
        /// A barrier rather than a `reload`, because a reload would post its own `configDidChange`,
        /// and a card that re-renders on that clears the per-edit messages a test is about to assert
        /// (the displaced-shortcut notice, for one). Enqueueing an empty block is enough: the queue is
        /// serial, and the completions ahead of it were handed to main ahead of this one.
        static func drainForTesting(_ completion: @escaping () -> Void) {
            queue.async { DispatchQueue.main.async(execute: completion) }
        }
    #endif

    /// Read `config` and the theme file. Runs off-main in both async paths, so it must not touch
    /// `GeneralConfig.current` / `Theme.current`. It doesn't need to: `loadAppTheme` takes the
    /// general config it reads the font from, so the pair resolves from the files alone.
    private static func resolve() -> (general: GeneralConfig, theme: AppTheme) {
        let general = ConfigLoader.loadGeneralConfig()
        return (general, ConfigLoader.loadAppTheme(general: general))
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
