import Foundation

/// The zen skill and the session extension, as `PiSetup` writes them.
public struct PiSetupFiles: SetupFiles {
    public let skill: Data
    public let `extension`: Data
    public let shippedDigests: Set<String>
    public let build: Int?

    public init(skill: Data, extension: Data, shippedDigests: Set<String> = [], build: Int? = nil) {
        self.skill = skill
        self.extension = `extension`
        self.shippedDigests = shippedDigests
        self.build = build
    }

    public var contents: [Data] { [skill, `extension`] }

    public static func bundled(beside executable: URL? = Bundle.main.executableURL) -> PiSetupFiles? {
        guard
            let bundle = readBundle(folder: "Pi", names: ["SKILL.md", PiSetup.extensionFileName], beside: executable)
        else { return nil }
        return PiSetupFiles(
            skill: bundle.contents[0], extension: bundle.contents[1], shippedDigests: bundle.shippedDigests,
            build: bundle.build)
    }
}
