import Foundation

/// Assembles the diagnostics `.zip` a user attaches to a bug report: the rotated log files plus a
/// `metadata.txt` holding the `SystemReport` block. It carries only the logs it's handed and the
/// report it's given, so the shell environment and the config file can never leak in.
///
/// Pure Foundation: the archive is produced with `NSFileCoordinator`'s `.forUploading` reading
/// intent (the system's own directory-to-zip), so there's no third-party archiver.
struct DiagnosticsBundleBuilder {
    let report: SystemReport
    let logFiles: [URL]

    /// Copy `metadata.txt` and each existing log into `directory` (created if needed). Split out from
    /// `build` so the bundle's contents are assertable without unzipping.
    func stage(into directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(report.plainText.utf8)
            .write(to: directory.appendingPathComponent("metadata.txt"))
        for log in logFiles where fileManager.fileExists(atPath: log.path) {
            try fileManager.copyItem(at: log, to: directory.appendingPathComponent(log.lastPathComponent))
        }
    }

    /// Stage into a throwaway temp folder and zip it to `destination` (overwriting). The archive
    /// expands to a single "ZenTerm Diagnostics/" folder.
    func build(to destination: URL) throws {
        let fileManager = FileManager.default
        let parent = fileManager.temporaryDirectory
            .appendingPathComponent("zenterm-diag-\(UUID().uuidString)", isDirectory: true)
        let bundle = parent.appendingPathComponent("ZenTerm Diagnostics", isDirectory: true)
        defer { try? fileManager.removeItem(at: parent) }
        try stage(into: bundle)

        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: bundle, options: .forUploading, error: &coordinationError
        ) { zipped in
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.copyItem(at: zipped, to: destination)
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }
}
