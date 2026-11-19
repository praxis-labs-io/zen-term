import Foundation

// Blocking by design: callers own the hop off the main thread.
enum Subprocess {
    struct Output: Equatable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    struct TimedOut: Error {}

    private static let killGrace: TimeInterval = 1

    // Drains both pipes before waiting, or a child filling the 64K stderr buffer deadlocks.
    static func run(
        _ executable: URL, _ args: [String], in dir: URL? = nil, timeout: TimeInterval? = nil
    ) -> Result<Output, Error> {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        if let dir { process.currentDirectoryURL = dir }

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return .failure(error)
        }

        let drained = DispatchGroup()
        let outDrain = Drain(out, group: drained)
        let errDrain = Drain(err, group: drained)
        let deadline: DispatchTime = timeout.map { .now() + $0 } ?? .distantFuture
        guard drained.wait(timeout: deadline) == .success, exited.wait(timeout: deadline) == .success else {
            stop(process, exited: exited)
            return .failure(TimedOut())
        }

        return .success(
            Output(
                status: process.terminationStatus,
                stdout: String(decoding: outDrain.data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                stderr: String(decoding: errDrain.data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private static func stop(_ process: Process, exited: DispatchSemaphore) {
        process.terminate()
        guard exited.wait(timeout: .now() + killGrace) == .timedOut else { return }
        kill(process.processIdentifier, SIGKILL)
        exited.wait()
    }

    // Its own thread, not the global pool: a saturated pool never runs the read and the wait never returns.
    private final class Drain: @unchecked Sendable {
        private(set) var data = Data()

        init(_ pipe: Pipe, group: DispatchGroup) {
            group.enter()
            Thread { [self] in
                data = pipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }.start()
        }
    }
}
