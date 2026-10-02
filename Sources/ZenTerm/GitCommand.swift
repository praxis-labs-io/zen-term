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

    static func run(_ args: [String], in dir: URL) -> Result<String, Error> {
        guard isAvailable else {
            return .failure(Failure(status: -1, stderr: "git is not available."))
        }
        return Subprocess.run(URL(fileURLWithPath: "/usr/bin/env"), ["git"] + args, in: dir)
            .flatMap { output in
                guard output.status == 0 else {
                    return .failure(Failure(status: output.status, stderr: output.stderr))
                }
                return .success(output.stdout)
            }
    }
}
