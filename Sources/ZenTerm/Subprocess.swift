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

        var outData = Data()
        var errData = Data()
        let drained = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: drained) {
            outData = out.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global(qos: .utility).async(group: drained) {
            errData = err.fileHandleForReading.readDataToEndOfFile()
        }
        let deadline: DispatchTime = timeout.map { .now() + $0 } ?? .distantFuture
        guard drained.wait(timeout: deadline) == .success, exited.wait(timeout: deadline) == .success else {
            stop(process, exited: exited)
            return .failure(TimedOut())
        }

        return .success(
            Output(
                status: process.terminationStatus,
                stdout: String(decoding: outData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                stderr: String(decoding: errData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    private static func stop(_ process: Process, exited: DispatchSemaphore) {
        process.terminate()
        guard exited.wait(timeout: .now() + killGrace) == .timedOut else { return }
        kill(process.processIdentifier, SIGKILL)
        exited.wait()
    }
}
