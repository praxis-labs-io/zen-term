import Foundation

/// Installs, refreshes and removes ZenTerm's Pi skill and extension.
public struct PiSetup: Sendable {
    public enum State: Equatable, Sendable {
        case notInstalled
        case outdated
        case edited
        case newer
        case current
    }

    static let stampFileName = "zenterm-context.build"

    public let configRoot: URL
    public let files: PiSetupFiles

    public init(configRoot: URL, files: PiSetupFiles) {
        self.configRoot = configRoot
        self.files = files
    }

    /// The folder Pi reads: `$PI_CODING_AGENT_DIR` when set, else `.pi/agent` in `$HOME`.
    public static func configRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let folder = environment["PI_CODING_AGENT_DIR"], !folder.isEmpty {
            return URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
        }
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent(".pi/agent")
    }

    public var skillURL: URL { configRoot.appendingPathComponent("skills/zen/SKILL.md") }
    public var extensionURL: URL { configRoot.appendingPathComponent("extensions/zenterm-context.ts") }
    var stampURL: URL { configRoot.appendingPathComponent("extensions/\(Self.stampFileName)") }

    public func state() throws(PiSetupError) -> State {
        let skill = try contents(of: skillURL)
        let extensionScript = try contents(of: extensionURL)
        if skill == nil, extensionScript == nil { return .notInstalled }
        guard let skill, let extensionScript else { return .edited }
        if skill == files.skill, extensionScript == files.extensionScript { return .current }
        if try isFromNewerBuild(skill: skill, extensionScript: extensionScript) { return .newer }
        let isShipped = [(skill, files.skill), (extensionScript, files.extensionScript)]
            .allSatisfy { $0 == $1 || files.isShipped($0) }
        return isShipped ? .outdated : .edited
    }

    public func install() throws(PiSetupError) -> [String] {
        var changes: [String] = []
        if let verb = try place(files.skill, at: skillURL) {
            changes.append("\(verb) the zen skill at \(skillURL.path)")
        }
        if let verb = try place(files.extensionScript, at: extensionURL) {
            changes.append("\(verb) the ZenTerm extension at \(extensionURL.path)")
        }
        if let build = files.build {
            _ = try place(Data("\(build) \(files.version)\n".utf8), at: stampURL)
        }
        return changes
    }

    public func remove() throws(PiSetupError) -> [String] {
        var changes: [String] = []
        if try delete(skillURL) {
            _ = try? FileManager.default.removeItem(at: skillURL.deletingLastPathComponent())
            changes.append("Removed the zen skill from \(skillURL.path)")
        }
        if try delete(extensionURL) {
            changes.append("Removed the ZenTerm extension from \(extensionURL.path)")
        }
        _ = try delete(stampURL)
        return changes
    }

    private func isFromNewerBuild(skill: Data, extensionScript: Data) throws(PiSetupError) -> Bool {
        guard let running = files.build, let stamp = try contents(of: stampURL) else { return false }
        let fields = String(decoding: stamp, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        guard fields.count == 2, let installer = Int(fields[0]) else { return false }
        return installer > running && fields[1] == PiSetupFiles(skill: skill, extensionScript: extensionScript).version
    }

    private func contents(of url: URL) throws(PiSetupError) -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            throw .unreadable(url, error)
        }
    }

    private func place(_ data: Data, at url: URL) throws(PiSetupError) -> String? {
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

    private func delete(_ url: URL) throws(PiSetupError) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw .unwritable(url, error)
        }
        return true
    }
}
