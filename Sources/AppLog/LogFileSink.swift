import Foundation

/// Appends log lines to a size-capped, rotated file set, written on a serial background queue so a
/// write never touches the main thread. The active file is `fileName`; when a write would
/// push it past `maxBytes` it rotates (`fileName` → `fileName.1` → …), keeping at most `maxFiles`
/// files total and dropping the oldest.
public final class LogFileSink {
    private let directory: URL
    private let fileName: String
    private let maxBytes: Int
    private let maxFiles: Int
    private let queue = DispatchQueue(label: "com.drucial.ZenTerm.LogFileSink")

    public init(directory: URL, fileName: String, maxBytes: Int, maxFiles: Int) {
        self.directory = directory
        self.fileName = fileName
        self.maxBytes = max(1, maxBytes)
        self.maxFiles = max(1, maxFiles)
    }

    /// The shipping sink: `~/Library/Logs/ZenTerm/zen-term.log`, ~5 MB × 2 files. The directory is
    /// created lazily on the first write, so constructing this touches no disk.
    public static func standard() -> LogFileSink {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/ZenTerm", isDirectory: true)
        return LogFileSink(directory: logs, fileName: "zen-term.log", maxBytes: 5 * 1024 * 1024, maxFiles: 2)
    }

    /// Append one line (a trailing newline is added). Returns immediately; the line is *formatted*
    /// and written on the serial queue (the `@autoclosure` defers it), so the caller thread never
    /// touches the shared date formatter or the disk.
    public func writeLine(_ line: @autoclosure @escaping () -> String) {
        queue.async { [weak self] in self?.append(Data((line() + "\n").utf8)) }
    }

    /// Block until every queued write has landed. For tests and for a clean shutdown.
    public func flush() {
        queue.sync {}
    }

    /// The log files that currently exist, active file first then each present rotation — the set
    /// Export Diagnostics bundles. Keeps the naming scheme here rather than leaking
    /// `fileName`/`.1` to callers. Runs on the write queue, so lines still queued when an export
    /// starts are on disk before this returns (the newest line is the one a bug report most needs)
    /// and a concurrent `rotate()` can't tear the listing. Blocks until the queue drains, so call it
    /// off the main thread.
    public var fileURLs: [URL] {
        queue.sync {
            let fileManager = FileManager.default
            var urls: [URL] = []
            if fileManager.fileExists(atPath: activeURL.path) { urls.append(activeURL) }
            for index in 1..<maxFiles {
                let url = rotatedURL(index)
                if fileManager.fileExists(atPath: url.path) { urls.append(url) }
            }
            return urls
        }
    }

    private var activeURL: URL { directory.appendingPathComponent(fileName) }
    private func rotatedURL(_ index: Int) -> URL {
        directory.appendingPathComponent("\(fileName).\(index)")
    }

    private func append(_ data: Data) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: activeURL.path) {
            fm.createFile(atPath: activeURL.path, contents: nil)
        }
        let size = (try? activeURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 0, size + data.count > maxBytes {
            rotate()
            fm.createFile(atPath: activeURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: activeURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// Shift the active file down the rotated chain, dropping anything past `maxFiles`.
    private func rotate() {
        let fm = FileManager.default
        let lastIndex = maxFiles - 1
        guard lastIndex >= 1 else {
            // Keep only the active file: drop it so a fresh one takes its place.
            try? fm.removeItem(at: activeURL)
            return
        }
        try? fm.removeItem(at: rotatedURL(lastIndex))  // drop the oldest
        var index = lastIndex - 1
        while index >= 1 {
            let from = rotatedURL(index)
            if fm.fileExists(atPath: from.path) {
                try? fm.moveItem(at: from, to: rotatedURL(index + 1))
            }
            index -= 1
        }
        try? fm.moveItem(at: activeURL, to: rotatedURL(1))
    }
}
