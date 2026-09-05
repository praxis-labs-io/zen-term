import Foundation

/// Runs `git` and hands back its stdout. Blocking on purpose: the caller owns the queue hop, the
/// way `GitRepoStatus` wraps `GitRepo`. Never call this on the main thread.
enum GitCommand {
    struct Failure: Error, LocalizedError, Equatable {
        let status: Int32
        let stderr: String

        var errorDescription: String? { stderr.isEmpty ? "git exited with \(status)." : stderr }
    }

    /// Whether a real `git` exists to run. Resolved once, off any hot path.
    ///
    /// `/usr/bin/git` is always present as an `xcrun` shim, so its existence proves nothing: on a
    /// Mac without the Command Line Tools, running it opens the system "install developer tools"
    /// modal. A picker probing one repo per row would stack a prompt per workspace, from work the
    /// user never asked for. `xcode-select -p` answers the same question and opens nothing.
    static let isAvailable: Bool = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }()

    /// Trimmed stdout on success. `dir` must exist; git resolves the repo from it.
    static func run(_ args: [String], in dir: URL) -> Result<String, Error> {
        guard isAvailable else {
            return .failure(Failure(status: -1, stderr: "git is not available."))
        }
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
