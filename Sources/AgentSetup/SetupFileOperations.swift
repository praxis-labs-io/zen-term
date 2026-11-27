import Foundation

enum SetupFileError: Error {
    case unreadable(URL, Error)
    case unwritable(URL, Error)
}

enum SetupFileOperations {
    static func contents(of url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            throw SetupFileError.unreadable(url, error)
        }
    }

    static func place(_ data: Data, at url: URL) throws -> String? {
        let existing = try contents(of: url)
        guard existing != data else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw SetupFileError.unwritable(url, error)
        }
        return existing == nil ? "Installed" : "Updated"
    }

    static func delete(_ url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw SetupFileError.unwritable(url, error)
        }
        return true
    }
}
