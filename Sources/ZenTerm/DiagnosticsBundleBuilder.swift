import Foundation

struct DiagnosticsBundleBuilder {
    let report: SystemReport
    let logFiles: [URL]

    /// Skips a log that fails to copy: a rotation can remove one mid-export.
    func stage(into directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(report.plainText.utf8)
            .write(to: directory.appendingPathComponent("metadata.txt"))
        for log in logFiles {
            try? fileManager.copyItem(at: log, to: directory.appendingPathComponent(log.lastPathComponent))
        }
    }

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
