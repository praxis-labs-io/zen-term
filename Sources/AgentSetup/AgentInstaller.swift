import Foundation

/// Installs, refreshes and removes zen's files for one agent in one config folder.
public protocol AgentInstaller: Sendable {
    associatedtype Files: SetupFiles
    typealias State = SetupState

    var configRoot: URL { get }
    var files: Files { get }
    /// The files written, in `files.contents` order.
    var placements: [SetupPlacement] { get }
    /// Where the installing build records its number and `files.version`.
    var stampURL: URL { get }

    init(configRoot: URL, files: Files)

    /// The folder the agent reads, from `environment`.
    static func configRoot(environment: [String: String]) -> URL

    /// Reads the agent's registration; nil for an agent that only needs the files. Throws when it is unreadable.
    func readRegistration() throws(SetupError) -> (any SetupRegistration)?
}

extension AgentInstaller {
    /// Reads what is installed; throws when the registration cannot be read or is not the shape the agent reads.
    public func state() throws(SetupError) -> SetupState {
        let registration = try readRegistration()
        var installed: [Data] = []
        var missing = false
        for placement in placements {
            if let data = try contents(of: placement.url) { installed.append(data) } else { missing = true }
        }
        if installed.isEmpty, registration?.hasEntry != true { return .notInstalled }
        guard !missing, registration?.isCurrent ?? true else { return .edited }
        let pairs = zip(installed, placements.map(\.contents))
        if pairs.allSatisfy({ $0 == $1 }) { return .current }
        if try isFromNewerBuild(installed: installed) { return .newer }
        return pairs.allSatisfy { $0 == $1 || files.isShipped($0) } ? .outdated : .edited
    }

    /// Writes what is missing or out of date and returns one line per change, none when it was already current.
    /// Refuses before writing anything when the registration is malformed.
    public func install() throws(SetupError) -> [String] {
        var registration = try readRegistration()
        var changes: [String] = []
        for placement in placements {
            if let verb = try place(placement.contents, at: placement.url) {
                changes.append("\(verb) \(placement.noun) at \(placement.url.path)")
            }
        }
        if let line = try registration?.register() { changes.append(line) }
        if let build = files.build {
            _ = try place(Data("\(build) \(files.version)\n".utf8), at: stampURL)
        }
        return changes
    }

    /// Deletes what setup installed, keeping every other entry, and returns one line per change.
    /// Refuses before deleting anything when the registration is malformed.
    public func remove() throws(SetupError) -> [String] {
        var registration = try readRegistration()
        var changes: [String] = []
        if let line = try registration?.unregister() { changes.append(line) }
        for placement in placements {
            guard try delete(placement.url) else { continue }
            if placement.ownsFolder { _ = rmdir(placement.url.deletingLastPathComponent().path) }
            changes.append("Removed \(placement.noun) from \(placement.url.path)")
        }
        _ = try delete(stampURL)
        return changes
    }

    private func isFromNewerBuild(installed: [Data]) throws(SetupError) -> Bool {
        guard let running = files.build, let stamp = try contents(of: stampURL) else { return false }
        let fields = String(decoding: stamp, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, let installer = Int(fields[0]) else { return false }
        return installer > running && fields[1] == Files.version(of: installed)
    }

    private func contents(of url: URL) throws(SetupError) -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            throw .unreadable(url, error)
        }
    }

    private func place(_ data: Data, at url: URL) throws(SetupError) -> String? {
        let existing = try contents(of: url)
        guard existing != data else { return nil }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw .unwritable(url, error)
        }
        return existing == nil ? "Installed" : "Updated"
    }

    private func delete(_ url: URL) throws(SetupError) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw .unwritable(url, error)
        }
        return true
    }
}
