import XCTest

@testable import TerminalKit

final class GhosttyShellQuoteTests: XCTestCase {
    func test_plainWordRoundTrips() {
        XCTAssertEqual(GhosttySurface.shellWordQuote("lazygit"), "\"lazygit\"")
    }

    func test_spacesAndMetacharactersStayOneWord() {
        // The chrome's real spawn shape: zsh -l -i -c "lazygit; exec /bin/zsh -l -i"
        XCTAssertEqual(
            GhosttySurface.shellWordQuote("lazygit; exec /bin/zsh -l -i"),
            "\"lazygit; exec /bin/zsh -l -i\"")
    }

    func test_doubleQuoteSpecialsAreEscaped() {
        XCTAssertEqual(
            GhosttySurface.shellWordQuote(#"say "$USER" `id` \n"#),
            #""say \"\$USER\" \`id\` \\n""#)
    }

    /// The whole reason for double quotes over single: ghostty's shell-integration
    /// detector (Zig ArgIteratorGeneral, double-quote-only) must recover a bare `zsh`
    /// from arg0 or integration silently disables. Single quotes would leave `'zsh'`.
    func test_quotedArg0StripsToBareShellName() {
        XCTAssertEqual(GhosttySurface.shellWordQuote("zsh"), "\"zsh\"")
        XCTAssertFalse(GhosttySurface.shellWordQuote("zsh").contains("'"))
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
