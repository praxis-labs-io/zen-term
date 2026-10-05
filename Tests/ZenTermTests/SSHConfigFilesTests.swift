import XCTest

@testable import ZenTerm

final class SSHConfigFilesTests: XCTestCase {
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

    private func resolved(_ urls: URL...) -> [String] {
        urls.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }.sorted()
    }

    func test_aConfigWithoutIncludes_listsOnlyItself() throws {
        let config = try write("Host devbox\n    HostName 10.0.0.2\n")

        XCTAssertEqual(SSHConfigFiles.paths(of: config), resolved(config))
    }

    func test_followsARelativeInclude_againstTheConfigsFolder() throws {
        let included = try write("Host included\n", to: "config.d/work")
        let config = try write("Include config.d/work\nHost local\n")

        XCTAssertEqual(SSHConfigFiles.paths(of: config), resolved(config, included))
    }

    func test_followsAnAbsoluteInclude() throws {
        let other = try write("Host elsewhere\n", to: "other/hosts")
        let config = try write("Include \(other.path)\nHost local\n")

        XCTAssertEqual(SSHConfigFiles.paths(of: config), resolved(config, other))
    }

    func test_readsIncludeInAnyCase_withAnEqualsSeparator() throws {
        let one = try write("", to: "one")
        let two = try write("", to: "two")
        let config = try write("include=one\nINCLUDE = two\n")

        XCTAssertEqual(SSHConfigFiles.paths(of: config), resolved(config, one, two))
    }

    func test_ignoresACommentedInclude() throws {
        try write("", to: "hidden")
        let config = try write("# Include hidden\n  # Include hidden\n")

        XCTAssertEqual(SSHConfigFiles.paths(of: config), resolved(config))
    }

    func test_expandsAGlobbedInclude() throws {
        let alpha = try write("", to: "config.d/10-alpha")
        let bravo = try write("", to: "config.d/20-bravo")
        try write("", to: "config.d/notes.txt")
        let config = try write("Include config.d/[0-9]*\n")

        XCTAssertEqual(SSHConfigFiles.paths(of: config), resolved(config, alpha, bravo))
    }

    func test_aQuotedInclude_isOnePath_evenWithASpaceAndAGlob() throws {
        let spaced = try write("", to: "config files/work.conf")
        try write("", to: "config files/notes.txt")
        let config = try write("Include \"config files/*.conf\"\n")

        XCTAssertEqual(SSHConfigFiles.paths(of: config), resolved(config, spaced))
    }

    func test_mixesQuotedAndUnquotedIncludeArguments() throws {
        let first = try write("", to: "a dir/one")
        let second = try write("", to: "two")
        let config = try write("Include \"a dir/one\" two # \"not a path\"\n")

        XCTAssertEqual(SSHConfigFiles.paths(of: config), resolved(config, first, second))
    }

    func test_skipsAnIncludeInAMatchBlock_untilTheNextHost() throws {
        let hidden = try write("", to: "conditional")
        let shown = try write("", to: "after")
        let config = try write(
            """
            Match host foo exec "true"
                Include conditional
            Host after
                Include after
            """)

        XCTAssertEqual(SSHConfigFiles.paths(of: config), resolved(config, shown))
        XCTAssertFalse(SSHConfigFiles.paths(of: config).contains(resolved(hidden)[0]))
    }

    func test_anIncludeCycle_endsWithoutRepeating() throws {
        let loop = try write("Include config\n", to: "loop")
        let config = try write("Include loop\n")

        XCTAssertEqual(SSHConfigFiles.paths(of: config), resolved(config, loop))
    }

    func test_aMissingConfig_stillListsItsOwnPath() {
        let absent = dir.appendingPathComponent("absent")

        XCTAssertEqual(SSHConfigFiles.paths(of: absent), resolved(absent))
    }

    func test_aMissingInclude_isListedAndTheRestIsStillRead() throws {
        let kept = try write("", to: "kept")
        let config = try write("Include nowhere\nInclude kept\n")

        XCTAssertEqual(
            SSHConfigFiles.paths(of: config), resolved(config, dir.appendingPathComponent("nowhere"), kept))
    }

    func test_anUnreadableInclude_isStillListed() throws {
        let included = try write("", to: "more")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: included.path)
        let config = try write("Include more\n")

        XCTAssertEqual(SSHConfigFiles.paths(of: config), resolved(config, included))
    }

    func test_aConfigWithAnInvalidUTF8Byte_stillFollowsItsIncludes() throws {
        let included = try write("", to: "more")
        var bytes = Data("# note ".utf8)
        bytes.append(0xFF)
        bytes.append(contentsOf: "\nInclude more\n".utf8)
        let config = dir.appendingPathComponent("config")
        try bytes.write(to: config)

        XCTAssertEqual(SSHConfigFiles.paths(of: config), resolved(config, included))
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
