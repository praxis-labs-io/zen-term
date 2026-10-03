import XCTest

@testable import ZenTerm

final class SSHSocketSweepTests: XCTestCase {
    private let ownPID: pid_t = 100
    private let livePID: pid_t = 200
    private let deadPID: pid_t = 300
    private var folder: URL!
    private var resolved: [String] = []
    private var ended: [pid_t] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("zt-sweep-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        try super.tearDownWithError()
    }

    private func file(_ name: String) {
        FileManager.default.createFile(atPath: folder.appendingPathComponent(name).path, contents: nil)
    }

    private func recording(master: pid_t?) -> SSHSocketSweep.Effects {
        SSHSocketSweep.Effects(
            isZenTermRunning: { [livePID] in $0 == livePID },
            resolveMaster: { [unowned self] path in
                resolved.append(path.lastPathComponent)
                return master
            },
            endMaster: { [unowned self] pid, _ in ended.append(pid) })
    }

    func test_aSocketNamesTheZenTermThatMadeIt() {
        XCTAssertEqual(SSHSocketSweep.owner(ofSocketNamed: "74123-ac68150d"), 74123)
        XCTAssertNil(SSHSocketSweep.owner(ofSocketNamed: "nav.74123.sock"))
        XCTAssertNil(SSHSocketSweep.owner(ofSocketNamed: "74123-ac68150d.Xy3k9QpL2aBcDeFg"), "ssh's temporary bind")
        XCTAssertNil(SSHSocketSweep.owner(ofSocketNamed: "74123-ac6815"))
        XCTAssertNil(SSHSocketSweep.owner(ofSocketNamed: "devbox-ac68150d"))
        XCTAssertNil(SSHSocketSweep.owner(ofSocketNamed: "0-ac68150d"))
    }

    func test_onlyADeadInstancesSocket_isChecked_andItsMasterEnded() {
        file("\(ownPID)-aaaaaaaa")
        file("\(livePID)-bbbbbbbb")
        file("\(deadPID)-cccccccc")
        file("notes.txt")

        SSHSocketSweep.sweep([folder], effects: recording(master: 4242), ownPID: ownPID)

        XCTAssertEqual(
            resolved, ["\(deadPID)-cccccccc"], "a running instance's sockets, dev or release, are never touched")
        XCTAssertEqual(ended, [4242])
    }

    func test_aDeadInstancesSocketWithNoMaster_endsNothing() {
        file("\(deadPID)-cccccccc")

        SSHSocketSweep.sweep([folder], effects: recording(master: nil), ownPID: ownPID)

        XCTAssertEqual(resolved, ["\(deadPID)-cccccccc"])
        XCTAssertEqual(ended, [])
    }

    func test_everyFolderIsSwept_andAMissingOneIsSkipped() throws {
        let other = folder.appendingPathComponent("fallback", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: other.appendingPathComponent("\(deadPID)-dddddddd").path, contents: nil)
        file("\(deadPID)-cccccccc")

        SSHSocketSweep.sweep(
            [folder.appendingPathComponent("missing"), folder, other], effects: recording(master: nil), ownPID: ownPID)

        XCTAssertEqual(Set(resolved), ["\(deadPID)-cccccccc", "\(deadPID)-dddddddd"])
    }

    private func refusingSocket(named name: String) throws {
        let path = folder.appendingPathComponent(name).path
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try XCTSkipIf(bound != 0, "couldn't bind a test socket")
        Darwin.close(fd)
    }

    private var liveChecks: SSHSocketSweep.Effects {
        var effects = SSHSocketSweep.Effects.live
        effects.endMaster = { [unowned self] pid, _ in ended.append(pid) }
        return effects
    }

    func test_theLiveSweep_removesADeadInstancesSocketThatRefuses() throws {
        let name = "\(pid_t.max)-cccccccc"
        try refusingSocket(named: name)

        SSHSocketSweep.sweep([folder], effects: liveChecks)

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path))
        XCTAssertEqual(ended, [])
    }

    private func runningZenTerm() throws -> Process {
        let binary = folder.appendingPathComponent("ZenTerm")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: binary)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["30"]
        try process.run()
        return process
    }

    func test_theLiveSweep_leavesARunningZenTermsSocket() throws {
        let zenTerm = try runningZenTerm()
        defer { zenTerm.terminate() }
        let name = "\(zenTerm.processIdentifier)-bbbbbbbb"
        try refusingSocket(named: name)

        SSHSocketSweep.sweep([folder], effects: liveChecks)

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path))
    }

    func test_theLiveSweep_checksASocketWhosePidNowBelongsToSomethingElse() throws {
        let name = "\(getppid())-bbbbbbbb"
        try refusingSocket(named: name)

        SSHSocketSweep.sweep([folder], effects: liveChecks)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path),
            "a dead ZenTerm's pid reused by another process must not hide its masters forever")
    }
}
