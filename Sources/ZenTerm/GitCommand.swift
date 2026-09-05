import Foundation

/// Runs `git` and hands back its stdout. Blocking on purpose: the caller owns the queue hop, the
/// way `GitRepoStatus` wraps `GitRepo`. Never call this on the main thread.
enum GitCommand {
    struct Failure: Error, LocalizedError, Equatable {
        let status: Int32
        let stderr: String

        var errorDescription: String? { stderr.isEmpty ? "git exited with \(status)." : stderr }
    }

    /// Trimmed stdout on success. `dir` must exist; git resolves the repo from it.
    static func run(_ args: [String], in dir: URL) -> Result<String, Error> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = dir

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            return .failure(error)
        }

        // Both pipes drain at once, and both before waiting: a child that fills the 64K stderr
        // buffer blocks on write while this thread blocks reading stdout, and neither ever moves.
        var errData = Data()
        let errDrain = DispatchQueue(label: "GitCommand.stderr")
        let drained = DispatchGroup()
        errDrain.async(group: drained) { errData = err.fileHandleForReading.readDataToEndOfFile() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()

        let stdout = String(decoding: outData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            let stderr = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(Failure(status: process.terminationStatus, stderr: stderr))
        }
        return .success(stdout)
    }
}
