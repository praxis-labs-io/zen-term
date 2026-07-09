import XCTest

@testable import TerminalKit

final class GhosttyShellQuoteTests: XCTestCase {
    func test_plainWordRoundTrips() {
        XCTAssertEqual(GhosttySurface.shellWordQuote("lazygit"), "'lazygit'")
    }

    func test_spacesAndMetacharactersStayOneWord() {
        // The chrome's real spawn shape: zsh -l -i -c "lazygit; exec /bin/zsh -l -i"
        XCTAssertEqual(
            GhosttySurface.shellWordQuote("lazygit; exec /bin/zsh -l -i"),
            "'lazygit; exec /bin/zsh -l -i'")
    }

    func test_embeddedSingleQuoteEscapes() {
        XCTAssertEqual(
            GhosttySurface.shellWordQuote("echo 'hi'"),
            #"'echo '\''hi'\'''"#)
    }

    /// End-to-end: sh -c on the quoted join must reproduce the original argv.
    func test_quotedJoinSurvivesRealShellParse() throws {
        let args = ["-l", "-i", "-c", "lazygit; exec /bin/zsh -l -i", "it's"]
        let joined = args.map(GhosttySurface.shellWordQuote).joined(separator: " ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Re-emit each word NUL-separated so the round-trip is observable.
        process.arguments = ["-c", "printf '%s\\0' \(joined)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let words = String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
        XCTAssertEqual(words, args)
    }
}
