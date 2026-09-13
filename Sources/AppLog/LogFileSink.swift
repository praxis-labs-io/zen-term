import Foundation

/// Appends lines to a file that rotates to `fileName.1`, `.2`, … past `maxBytes`, keeping `maxFiles` files.
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

    /// `~/Library/Logs/ZenTerm/zen-term.log`, 5 MB x 2 files. Touches no disk until the first write.
    public static func standard() -> LogFileSink {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/ZenTerm", isDirectory: true)
        return LogFileSink(directory: logs, fileName: "zen-term.log", maxBytes: 5 * 1024 * 1024, maxFiles: 2)
    }

    /// Formats and appends `line` plus a newline on a background queue. Returns immediately.
    public func writeLine(_ line: @autoclosure @escaping () -> String) {
        queue.async { [weak self] in self?.append(Data((line() + "\n").utf8)) }
    }

    /// Blocks until every queued write has landed.
    public func flush() {
        queue.sync {}
    }

    /// The log files that exist, active first. Waits for queued writes, so call it off the main thread.
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

    private func rotate() {
        let fm = FileManager.default
        let lastIndex = maxFiles - 1
        guard lastIndex >= 1 else {
            try? fm.removeItem(at: activeURL)
            return
        }
        try? fm.removeItem(at: rotatedURL(lastIndex))
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
