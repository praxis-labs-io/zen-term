import XCTest

@testable import ZenTerm

final class SSHConfigHostsTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = try makeTempDir()
    }

    @discardableResult
    private func write(_ text: String, to name: String = "config") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_collectsEveryAliasOfAHostLine_inFileOrder() throws {
        let config = try write(
            """
            Host devbox dev
                HostName 10.0.0.2
            Host prod
                User deploy
            """)

        XCTAssertEqual(SSHConfigHosts.aliases(in: config), ["devbox", "dev", "prod"])
    }

    func test_skipsWildcardsAndNegations() throws {
        let config = try write(
            """
            Host *
                ServerAliveInterval 30
            Host *.example.com web? !bastion jump
            """)

        XCTAssertEqual(SSHConfigHosts.aliases(in: config), ["jump"])
    }

    func test_readsTheKeywordInAnyCase_withAnEqualsSeparator() throws {
        let config = try write(
            """
            host=alpha
            HOST = beta
            \tHost\tgamma
            """)

        XCTAssertEqual(SSHConfigHosts.aliases(in: config), ["alpha", "beta", "gamma"])
    }

    func test_ignoresComments() throws {
        let config = try write(
            """
            # Host commented
              # Host indented
            Host real # trailing note
            """)

        XCTAssertEqual(SSHConfigHosts.aliases(in: config), ["real"])
    }

    func test_skipsMatchBlocks_untilTheNextHost() throws {
        try write("Host hidden\n", to: "conditional")
        let config = try write(
            """
            Host before
            Match host foo exec "true"
                Include conditional
                User someone
            Host after
            """)

        XCTAssertEqual(SSHConfigHosts.aliases(in: config), ["before", "after"])
    }

    func test_followsARelativeInclude_againstTheConfigsFolder() throws {
        try write("Host included\n", to: "config.d/work")
        let config = try write(
            """
            Include config.d/work
            Host local
            """)

        XCTAssertEqual(SSHConfigHosts.aliases(in: config), ["included", "local"])
    }

    func test_followsAnAbsoluteInclude() throws {
        let other = try write("Host elsewhere\n", to: "other/hosts")
        let config = try write("Include \(other.path)\nHost local\n")

        XCTAssertEqual(SSHConfigHosts.aliases(in: config), ["elsewhere", "local"])
    }

    func test_expandsAGlobbedInclude_inNameOrder() throws {
        try write("Host bravo\n", to: "config.d/20-bravo")
        try write("Host alpha\n", to: "config.d/10-alpha")
        try write("Host skipped\n", to: "config.d/notes.txt")
        let config = try write("Include config.d/[0-9]*\n")

        XCTAssertEqual(SSHConfigHosts.aliases(in: config), ["alpha", "bravo"])
    }

    func test_anIncludeCycle_endsWithoutRepeating() throws {
        try write("Host loop\nInclude config\n", to: "loop")
        let config = try write("Host start\nInclude loop\n")

        XCTAssertEqual(SSHConfigHosts.aliases(in: config), ["start", "loop"])
    }

    func test_deduplicatesAcrossFiles() throws {
        try write("Host shared\nHost extra\n", to: "more")
        let config = try write("Host shared\nInclude more\n")

        XCTAssertEqual(SSHConfigHosts.aliases(in: config), ["shared", "extra"])
    }

    func test_aMissingFileOrInclude_yieldsWhatCanBeRead() throws {
        XCTAssertEqual(SSHConfigHosts.aliases(in: dir.appendingPathComponent("absent")), [])
        let config = try write("Include nowhere\nHost kept\n")

        XCTAssertEqual(SSHConfigHosts.aliases(in: config), ["kept"])
    }

    func test_destination_readsUserAndHostnameFromTheDump() {
        let dump = """
            host devbox
            user drew
            hostname 10.0.0.2
            port 22
            """

        XCTAssertEqual(SSHHostResolver.destination(inDump: dump), "drew@10.0.0.2")
        XCTAssertNil(SSHHostResolver.destination(inDump: "host devbox\nport 22\n"))
    }
}
