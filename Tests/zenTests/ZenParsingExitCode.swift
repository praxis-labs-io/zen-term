import ArgumentParser
import Foundation

@testable import zen

extension Zen {
    // A test that runs a command could reach the user's running ZenTerm, so usage checks stop at parsing.
    static func exitCode(parsing arguments: [String]) -> Int32 {
        do {
            _ = try parseAsRoot(arguments)
            return 0
        } catch {
            return finish(error, usage: true)
        }
    }

    // `--socket` wins over $ZEN_CONTROL_SOCK and discovery, so a test that runs a command can only reach this.
    static let unreachableSocket = FileManager.default.temporaryDirectory
        .appendingPathComponent("zt-nothing-\(getpid()).sock").path
}
