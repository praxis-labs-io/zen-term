import Foundation

// Blocking by design: callers own the hop off the main thread.
enum GitCommand {
    struct Failure: Error, LocalizedError, Equatable {
        let status: Int32
        let stderr: String

        var errorDescription: String? {
            let reason = Self.reason(in: stderr)
            return reason.isEmpty ? "git exited with \(status)." : reason
        }

        // Git writes progress to stderr beside the failure; only the `fatal:` or `error:` line is for a person.
        private static func reason(in stderr: String) -> String {
            let lines = stderr.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard
                let named = lines.last(where: { $0.hasPrefix("fatal: ") || $0.hasPrefix("error: ") }),
                let body = named.range(of: ": ").map({ String(named[$0.upperBound...]) })
            else { return lines.last ?? "" }
            return body.prefix(1).uppercased() + body.dropFirst()
                + (body.hasSuffix(".") ? "" : ".")
        }
    }

    // `/usr/bin/git` is an xcrun shim that opens the install-tools prompt without CLT; `xcode-select -p` opens nothing.
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

    // Drains both pipes before waiting, or a child filling the 64K stderr buffer deadlocks.
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
