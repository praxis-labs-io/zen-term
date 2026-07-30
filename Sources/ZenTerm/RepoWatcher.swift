import CoreServices
import Foundation

/// A recursive FSEvents watch for one repository. Events stay on a private queue, where a trailing
/// debounce collapses each filesystem burst; only the settled callback crosses to the main queue.
final class RepoWatcher {
    private final class EventSink {
        weak var watcher: RepoWatcher?

        init(watcher: RepoWatcher) {
            self.watcher = watcher
        }
    }

    /// A main-queue callback can already be enqueued when `stop` reaches the watcher. Keeping its
    /// action behind a gate lets teardown make that last callback a no-op too.
    private final class CallbackGate {
        private var action: (() -> Void)?

        init(action: @escaping () -> Void) {
            self.action = action
        }

        func fire() {
            action?()
        }

        func cancel() {
            action = nil
        }
    }

    private let queue: DispatchQueue
    private let debouncer: TrailingDebouncer
    private var stream: FSEventStreamRef?
    private var sink: EventSink?
    private var callbackGate: CallbackGate?

    init(debounceDelay: TimeInterval = 0.275) {
        let queue = DispatchQueue(label: "dev.zenterm.repo-watcher", qos: .utility)
        self.queue = queue
        debouncer = TrailingDebouncer(
            delay: debounceDelay,
            schedule: { delay, work in queue.asyncAfter(deadline: .now() + delay, execute: work) })
    }

    deinit {
        stop()
    }

    /// Start watching the whole repository, including `.git`, so working-tree writes and index/ref
    /// changes take the same refresh path.
    func start(repoRoot: URL, onChange: @escaping () -> Void) {
        stop()
        let watchPaths = Self.watchPaths(repoRoot: repoRoot)

        let sink = EventSink(watcher: self)
        self.sink = sink
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(sink).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                return UnsafeRawPointer(Unmanaged<EventSink>.fromOpaque(info).retain().toOpaque())
            },
            release: { info in
                guard let info else { return }
                Unmanaged<EventSink>.fromOpaque(info).release()
            },
            copyDescription: nil)

        guard
            let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                { _, info, _, _, _, _ in
                    guard let info else { return }
                    Unmanaged<EventSink>.fromOpaque(info).takeUnretainedValue().watcher?.receiveEvent()
                },
                &context,
                watchPaths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.1,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot))
        else {
            self.sink = nil
            return
        }

        self.stream = stream
        let callbackGate = CallbackGate(action: onChange)
        self.callbackGate = callbackGate
        debouncer.setAction {
            DispatchQueue.main.async {
                callbackGate.fire()
            }
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        if !FSEventStreamStart(stream) {
            stop()
        }
    }

    /// Tear down the stream synchronously and invalidate any callback already waiting in the debounce.
    func stop() {
        callbackGate?.cancel()
        callbackGate = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        queue.sync {
            debouncer.cancel()
            debouncer.setAction(nil)
        }
        sink = nil
    }

    private func receiveEvent() {
        debouncer.signal()
    }

    /// A linked worktree's `.git` is a pointer file. Its index and HEAD live in the referenced Git
    /// directory, and refs may live one level farther away in the directory named by `commondir`.
    /// FSEvents does not follow either pointer, so add those external roots explicitly.
    static func watchPaths(
        repoRoot: URL,
        readFile: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }
    ) -> [String] {
        let root = repoRoot.standardizedFileURL
        let dotGit = root.appendingPathComponent(".git")
        guard
            let pointer = readFile(dotGit),
            let gitDirectory = referencedDirectory(
                prefix: "gitdir:", contents: pointer, relativeTo: root)
        else {
            return [root.path]
        }

        var directories = [root, gitDirectory]
        if let commonPointer = readFile(gitDirectory.appendingPathComponent("commondir")),
            let commonDirectory = referencedDirectory(
                contents: commonPointer, relativeTo: gitDirectory)
        {
            directories.append(commonDirectory)
        }

        return directories.reduce(into: [String]()) { paths, directory in
            let path = directory.standardizedFileURL.path
            let isAlreadyCovered = paths.contains { existing in
                path == existing || path.hasPrefix(existing + "/")
            }
            if !isAlreadyCovered {
                paths.append(path)
            }
        }
    }

    private static func referencedDirectory(
        prefix: String? = nil,
        contents: String,
        relativeTo base: URL
    ) -> URL? {
        var path = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if let prefix {
            guard path.hasPrefix(prefix) else { return nil }
            path = String(path.dropFirst(prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !path.isEmpty else { return nil }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return base.appendingPathComponent(path)
    }
}

/// Generation-based trailing debounce. Injecting the scheduler makes burst coalescing and
/// cancellation deterministic in tests without making FSEvents itself pretend to be deterministic.
final class TrailingDebouncer {
    typealias Schedule = (_ delay: TimeInterval, _ work: @escaping () -> Void) -> Void

    private let delay: TimeInterval
    private let schedule: Schedule
    private var generation = 0
    private var action: (() -> Void)?

    init(
        delay: TimeInterval,
        schedule: @escaping Schedule
    ) {
        self.delay = delay
        self.schedule = schedule
    }

    func setAction(_ action: (() -> Void)?) {
        self.action = action
    }

    func signal() {
        generation += 1
        let scheduledGeneration = generation
        schedule(delay) { [weak self] in
            guard let self, self.generation == scheduledGeneration else { return }
            self.action?()
        }
    }

    func cancel() {
        generation += 1
    }
}
