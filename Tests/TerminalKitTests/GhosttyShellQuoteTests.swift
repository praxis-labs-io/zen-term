import XCTest

@testable import TerminalKit

final class GhosttyShellQuoteTests: XCTestCase {
    func test_plainWordRoundTrips() {
        XCTAssertEqual(GhosttySurface.shellWordQuote("lazygit"), "\"lazygit\"")
    }

    func test_spacesAndMetacharactersStayOneWord() {
        XCTAssertEqual(
            GhosttySurface.shellWordQuote("lazygit; exec /bin/zsh -l -i"),
            "\"lazygit; exec /bin/zsh -l -i\"")
    }

    func test_doubleQuoteSpecialsAreEscaped() {
        XCTAssertEqual(
            GhosttySurface.shellWordQuote(#"say "$USER" `id` \n"#),
            #""say \"\$USER\" \`id\` \\n""#)
    }

    func test_quotedArg0StripsToBareShellName() {
        XCTAssertEqual(GhosttySurface.shellWordQuote("zsh"), "\"zsh\"")
        XCTAssertFalse(GhosttySurface.shellWordQuote("zsh").contains("'"))
    }

    func test_quotedJoinSurvivesRealShellParse() throws {
        let args = ["-l", "-i", "-c", "lazygit; exec /bin/zsh -l -i", "it's"]
        let joined = args.map(GhosttySurface.shellWordQuote).joined(separator: " ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
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
