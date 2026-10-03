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

        XCTAssertEqual(SSHConfigHosts.listing(of: config).aliases, ["devbox", "dev", "prod"])
    }

    func test_skipsWildcardsAndNegations() throws {
        let config = try write(
            """
            Host *
                ServerAliveInterval 30
            Host *.example.com web? !bastion jump
            """)

        XCTAssertEqual(SSHConfigHosts.listing(of: config).aliases, ["jump"])
    }

    func test_readsTheKeywordInAnyCase_withAnEqualsSeparator() throws {
        let config = try write(
            """
            host=alpha
            HOST = beta
            \tHost\tgamma
            """)

        XCTAssertEqual(SSHConfigHosts.listing(of: config).aliases, ["alpha", "beta", "gamma"])
    }

    func test_ignoresComments() throws {
        let config = try write(
            """
            # Host commented
              # Host indented
            Host real # trailing note
            """)

        XCTAssertEqual(SSHConfigHosts.listing(of: config).aliases, ["real"])
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

        XCTAssertEqual(SSHConfigHosts.listing(of: config).aliases, ["before", "after"])
    }

    func test_followsARelativeInclude_againstTheConfigsFolder() throws {
        try write("Host included\n", to: "config.d/work")
        let config = try write(
            """
            Include config.d/work
            Host local
            """)

        XCTAssertEqual(SSHConfigHosts.listing(of: config).aliases, ["included", "local"])
    }

    func test_followsAnAbsoluteInclude() throws {
        let other = try write("Host elsewhere\n", to: "other/hosts")
        let config = try write("Include \(other.path)\nHost local\n")

        XCTAssertEqual(SSHConfigHosts.listing(of: config).aliases, ["elsewhere", "local"])
    }

    func test_expandsAGlobbedInclude_inNameOrder() throws {
        try write("Host bravo\n", to: "config.d/20-bravo")
        try write("Host alpha\n", to: "config.d/10-alpha")
        try write("Host skipped\n", to: "config.d/notes.txt")
        let config = try write("Include config.d/[0-9]*\n")

        XCTAssertEqual(SSHConfigHosts.listing(of: config).aliases, ["alpha", "bravo"])
    }

    func test_aQuotedInclude_isOnePath_evenWithASpaceAndAGlob() throws {
        try write("Host spaced\n", to: "config files/work.conf")
        try write("Host skipped\n", to: "config files/notes.txt")
        let config = try write("Include \"config files/*.conf\"\n")

        XCTAssertEqual(SSHConfigHosts.listing(of: config).aliases, ["spaced"])
    }

    func test_aQuotedHostAlias_isOneAlias_withoutItsQuotes() throws {
        let config = try write("Host \"devbox\" \"two words\"\n")

        XCTAssertEqual(SSHConfigHosts.listing(of: config).aliases, ["devbox", "two words"])
    }

    func test_mixesQuotedAndUnquotedArguments() throws {
        try write("Host first\n", to: "a dir/one")
        try write("Host second\n", to: "two")
        let config = try write(
            """
            Include "a dir/one" two
            Host plain "quoted alias" tail # "not an alias"
            """)

        XCTAssertEqual(
            SSHConfigHosts.listing(of: config).aliases, ["first", "second", "plain", "quoted alias", "tail"])
    }

    func test_anIncludeCycle_endsWithoutRepeating() throws {
        try write("Host loop\nInclude config\n", to: "loop")
        let config = try write("Host start\nInclude loop\n")

        XCTAssertEqual(SSHConfigHosts.listing(of: config).aliases, ["start", "loop"])
    }

    func test_deduplicatesAcrossFiles() throws {
        try write("Host shared\nHost extra\n", to: "more")
        let config = try write("Host shared\nInclude more\n")

        XCTAssertEqual(SSHConfigHosts.listing(of: config).aliases, ["shared", "extra"])
    }

    func test_aMissingFileOrInclude_yieldsWhatCanBeRead() throws {
        XCTAssertEqual(
            SSHConfigHosts.listing(of: dir.appendingPathComponent("absent")),
            SSHConfigHosts.Listing(aliases: [], isUnreadable: false), "a missing config is not a failure")
        let config = try write("Include nowhere\nHost kept\n")

        XCTAssertEqual(
            SSHConfigHosts.listing(of: config), SSHConfigHosts.Listing(aliases: ["kept"], isUnreadable: false))
    }

    func test_aConfigThatExistsButCannotBeRead_isReportedUnreadable() throws {
        let config = try write("Host hidden\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: config.path)

        XCTAssertEqual(SSHConfigHosts.listing(of: config), SSHConfigHosts.Listing(aliases: [], isUnreadable: true))
    }

    func test_aConfigWithAnInvalidUTF8Byte_stillYieldsItsHosts() throws {
        try XCTUnwrap("# caf\u{E9}\nHost included\n".data(using: .isoLatin1))
            .write(to: dir.appendingPathComponent("latin1"))
        var bytes = Data("# note ".utf8)
        bytes.append(0xFF)
        bytes.append(contentsOf: "\nHost kept\nInclude latin1\n".utf8)
        let config = dir.appendingPathComponent("config")
        try bytes.write(to: config)

        XCTAssertEqual(
            SSHConfigHosts.listing(of: config),
            SSHConfigHosts.Listing(aliases: ["kept", "included"], isUnreadable: false))
    }

    func test_anUnreadableInclude_doesNotMarkTheConfigUnreadable() throws {
        let included = try write("Host hidden\n", to: "more")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: included.path)
        let config = try write("Include more\nHost kept\n")

        XCTAssertEqual(
            SSHConfigHosts.listing(of: config), SSHConfigHosts.Listing(aliases: ["kept"], isUnreadable: false))
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

    func test_aHostWithItsOwnRemoteCommand_launchesPlain_andAnyOtherRunsTheLoginShell() {
        XCTAssertEqual(SSHHostResolver.launchForm(inDump: "host devbox\nremotecommand tmux new -A\n"), .plain)
        XCTAssertEqual(SSHHostResolver.launchForm(inDump: "host devbox\nrequesttty auto\n"), .loginShell)
    }

    func test_aHostWhoseConfigCannotBeRead_launchesPlain() {
        XCTAssertEqual(SSHHostResolver.launchForm(inDump: nil), .plain)
    }

    func test_endpoint_readsHostnameAndPortFromTheDump() {
        let dump = """
            host devbox
            user drew
            hostname 10.0.0.2
            port 2222
            """

        XCTAssertEqual(SSHHostResolver.endpoint(inDump: dump), .direct(hostname: "10.0.0.2", port: 2222))
    }

    func test_endpoint_withoutAPort_isTwentyTwo() {
        XCTAssertEqual(
            SSHHostResolver.endpoint(inDump: "host devbox\nhostname devbox.lan\n"),
            .direct(hostname: "devbox.lan", port: 22))
    }

    func test_endpoint_behindAJumpHost_isProxied() {
        let dump = "host inner\nhostname 10.0.0.9\nport 22\nproxyjump bastion\n"

        XCTAssertEqual(SSHHostResolver.endpoint(inDump: dump), .proxied)
    }

    func test_endpoint_behindAProxyCommand_isProxied() {
        let dump = "host inner\nhostname 10.0.0.9\nport 22\nproxycommand nc %h %p\n"

        XCTAssertEqual(SSHHostResolver.endpoint(inDump: dump), .proxied)
    }

    func test_endpoint_withNoHostname_isNil() {
        XCTAssertNil(SSHHostResolver.endpoint(inDump: "host devbox\nport 22\n"))
    }
}
