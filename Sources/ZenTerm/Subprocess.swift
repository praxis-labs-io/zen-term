import Foundation

// Blocking by design: callers own the hop off the main thread.
enum Subprocess {
    struct Output: Equatable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    // Drains both pipes before waiting, or a child filling the 64K stderr buffer deadlocks.
    static func run(_ executable: URL, _ args: [String], in dir: URL? = nil) -> Result<Output, Error> {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        if let dir { process.currentDirectoryURL = dir }

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
        let errDrain = DispatchQueue(label: "Subprocess.stderr")
        let drained = DispatchGroup()
        errDrain.async(group: drained) { errData = err.fileHandleForReading.readDataToEndOfFile() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        drained.wait()
        process.waitUntilExit()

        return .success(
            Output(
                status: process.terminationStatus,
                stdout: String(decoding: outData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                stderr: String(decoding: errData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}
