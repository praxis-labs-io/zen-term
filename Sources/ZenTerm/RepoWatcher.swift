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
                [repoRoot.path] as CFArray,
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
