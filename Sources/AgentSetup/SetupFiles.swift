import CryptoKit
import Foundation

/// The files one build ships for an agent, and the digests of every copy a build has shipped.
public protocol SetupFiles: Equatable, Sendable {
    /// In the order the installer places them.
    var contents: [Data] { get }
    /// The SHA-256 hex digest of every file a build has shipped.
    var shippedDigests: Set<String> { get }
    /// The `CFBundleVersion` of the app that ships these copies; nil for a build from source.
    var build: Int? { get }

    /// Reads the copies shipped beside `executable`, following a symlink to it; nil when none are there.
    static func bundled(beside executable: URL?) -> Self?
}

extension SetupFiles {
    // Hand-kept because asking `Bundle.module` for it can `fatalError` in a packaged app.
    static var bundleName: String { "ZenTerm_AgentSetup" }
    static var shippedDigestsFileName: String { "shipped-digests.txt" }

    /// Names this set of files: equal only for builds that ship the same files.
    public var version: String { Self.version(of: contents) }

    static func version(of contents: [Data]) -> String {
        digest(of: Data(contents.map(digest(of:)).joined().utf8))
    }

    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func isShipped(_ data: Data) -> Bool {
        shippedDigests.contains(Self.digest(of: data))
    }

    static func readBundle(folder: String, names: [String], beside executable: URL?) -> (
        contents: [Data], shippedDigests: Set<String>, build: Int?
    )? {
        guard let binFolder = executable?.resolvingSymlinksInPath().deletingLastPathComponent() else { return nil }
        let app = binFolder.deletingLastPathComponent()
        let candidates = [
            app.appendingPathComponent("Resources/\(bundleName).bundle"),
            binFolder.appendingPathComponent("\(bundleName).bundle"),
        ]
        for candidate in candidates {
            guard let resources = Bundle(url: candidate)?.resourceURL?.appendingPathComponent(folder),
                let digests = try? String(
                    contentsOf: resources.appendingPathComponent(shippedDigestsFileName), encoding: .utf8)
            else { continue }
            let contents = names.compactMap { try? Data(contentsOf: resources.appendingPathComponent($0)) }
            guard contents.count == names.count else { continue }
            let shipped = Set(
                digests.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
            return (contents, shipped, build(of: app))
        }
        return nil
    }

    private static func build(of app: URL) -> Int? {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Info.plist"))
        return (info?["CFBundleVersion"] as? String).flatMap { Int($0) }
    }
}
