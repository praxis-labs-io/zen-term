import CryptoKit
import Foundation

/// The zen skill and Pi extension script shipped for `PiSetup`.
public struct PiSetupFiles: Equatable, Sendable {
    static let bundleName = "ZenTerm_AgentSetup"
    static let shippedDigestsFileName = "pi-shipped-digests.txt"

    public let skill: Data
    public let extensionScript: Data
    public let shippedDigests: Set<String>
    public let build: Int?

    public init(skill: Data, extensionScript: Data, shippedDigests: Set<String> = [], build: Int? = nil) {
        self.skill = skill
        self.extensionScript = extensionScript
        self.shippedDigests = shippedDigests
        self.build = build
    }

    /// Names this pair of files so an installed copy can be compared with a build.
    public var version: String {
        Self.digest(of: Data((Self.digest(of: skill) + Self.digest(of: extensionScript)).utf8))
    }

    static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func isShipped(_ data: Data) -> Bool { shippedDigests.contains(Self.digest(of: data)) }

    /// Reads the Pi resources beside `executable`, or returns nil when they are unavailable.
    public static func bundled(beside executable: URL? = Bundle.main.executableURL) -> PiSetupFiles? {
        guard let folder = executable?.resolvingSymlinksInPath().deletingLastPathComponent() else { return nil }
        let contents = folder.deletingLastPathComponent()
        let candidates = [
            contents.appendingPathComponent("Resources/\(bundleName).bundle"),
            folder.appendingPathComponent("\(bundleName).bundle"),
        ]
        for candidate in candidates {
            guard let resources = Bundle(url: candidate)?.resourceURL?.appendingPathComponent("Pi"),
                let skill = try? Data(contentsOf: resources.appendingPathComponent("SKILL.md")),
                let extensionScript = try? Data(contentsOf: resources.appendingPathComponent("zenterm-context.ts")),
                let digests = try? String(
                    contentsOf: resources.appendingPathComponent(shippedDigestsFileName), encoding: .utf8)
            else { continue }
            let shipped = Set(
                digests.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
            return PiSetupFiles(
                skill: skill, extensionScript: extensionScript, shippedDigests: shipped, build: build(of: contents))
        }
        return nil
    }

    private static func build(of contents: URL) -> Int? {
        let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist"))
        return (info?["CFBundleVersion"] as? String).flatMap { Int($0) }
    }
}
