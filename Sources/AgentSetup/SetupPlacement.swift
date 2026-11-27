import Foundation

/// One file an `AgentInstaller` writes, named in its change lines by `noun` ("the zen skill").
public struct SetupPlacement: Sendable {
    public let url: URL
    public let contents: Data
    public let noun: String
    /// Removing the file also removes its folder when that folder is left empty.
    public let ownsFolder: Bool

    public init(url: URL, contents: Data, noun: String, ownsFolder: Bool = false) {
        self.url = url
        self.contents = contents
        self.noun = noun
        self.ownsFolder = ownsFolder
    }
}
