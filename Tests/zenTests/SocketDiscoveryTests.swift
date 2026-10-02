import ControlProtocol
import XCTest

@testable import zen

final class SocketDiscoveryTests: XCTestCase {
    private var directory: URL!
    private var listeners: [Int32] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: "/tmp/zt-discovery-\(getpid())-\(name.hashValue & 0xFFFF)")
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        listeners.forEach { close($0) }
        listeners = []
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func listen(_ name: String) throws -> String {
        let path = directory.appendingPathComponent(name).path
        var addr = try XCTUnwrap(UnixSocket.address(for: path))
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(fd, 4), 0)
        listeners.append(fd)
        return path
    }

    private func deadSocketFile(_ name: String) -> String {
        let path = directory.appendingPathComponent(name).path
        FileManager.default.createFile(atPath: path, contents: nil)
        return path
    }

    private func resolve(explicit: String? = nil, environment: [String: String] = [:]) -> Result<String, ZenFailure> {
        Result { () throws(ZenFailure) in
            try SocketDiscovery.resolve(explicit: explicit, environment: environment, directory: directory)
        }
    }

    func test_usesTheOneLiveSocket_skippingDeadOnesAndOtherSockets() throws {
        let live = try listen("control.101.sock")
        _ = deadSocketFile("control.102.sock")
        _ = try listen("nav.101.sock")

        XCTAssertEqual(try resolve().get(), live)
    }

    func test_severalLiveSockets_exitThreeListingEach() throws {
        let first = try listen("control.101.sock")
        let second = try listen("control.202.sock")

        guard case .failure(let failure) = resolve() else { return XCTFail("two instances must not pick one") }
        XCTAssertEqual(failure.exitCode, 3)
        XCTAssertTrue(failure.message.contains(first), failure.message)
        XCTAssertTrue(failure.message.contains(second), failure.message)
        XCTAssertTrue(failure.message.contains("--socket"), failure.message)
    }

    func test_noLiveSocket_exitsThree() {
        _ = deadSocketFile("control.102.sock")

        guard case .failure(let failure) = resolve() else { return XCTFail("a dead socket is not an instance") }
        XCTAssertEqual(failure, .noInstance("ZenTerm isn't running."))
    }

    func test_aLiveInheritedSocketWinsOverTheSearchAndKeepsTheCallerPane() throws {
        let inherited = try listen("control.101.sock")
        _ = try listen("control.202.sock")
        let environment = ["ZEN_CONTROL_SOCK": inherited, "ZEN_PANE": "31"]

        let path = try resolve(environment: environment).get()

        XCTAssertEqual(path, inherited)
        XCTAssertEqual(ConnectionOptions.caller(for: path, environment: environment), ControlCaller(pane: 31))
    }

    func test_aDeadInheritedSocketFallsBackToTheLiveOne_withNoCallerPane() throws {
        let stale = deadSocketFile("control.102.sock")
        let live = try listen("control.202.sock")
        let environment = ["ZEN_CONTROL_SOCK": stale, "ZEN_PANE": "31"]

        let path = try resolve(environment: environment).get()

        XCTAssertEqual(path, live)
        XCTAssertNil(
            ConnectionOptions.caller(for: path, environment: environment),
            "the dead instance's pane token means nothing to the live one")
    }

    func test_aDeadInheritedSocketWithSeveralLiveOnes_exitsThreeListingThem() throws {
        let first = try listen("control.101.sock")
        let second = try listen("control.202.sock")

        guard case .failure(let failure) = resolve(environment: ["ZEN_CONTROL_SOCK": "/x/control.9.sock"]) else {
            return XCTFail("a dead inherited socket must not pick between two instances")
        }
        XCTAssertEqual(failure.exitCode, 3)
        XCTAssertTrue(failure.message.contains(first) && failure.message.contains(second), failure.message)
    }

    func test_aDeadInheritedSocketWithNoInstance_exitsThree() {
        XCTAssertEqual(
            resolve(environment: ["ZEN_CONTROL_SOCK": "/x/control.9.sock"]),
            .failure(.noInstance("ZenTerm isn't running.")))
    }

    func test_theFlagIsTakenAsGiven_evenWhenDeadAndAnInstanceIsLive() throws {
        let live = try listen("control.202.sock")

        XCTAssertEqual(
            try resolve(explicit: "/dead/flag.sock", environment: ["ZEN_CONTROL_SOCK": live]).get(), "/dead/flag.sock")
    }

    func test_theFlagNamingAnotherInstance_sendsNoCallerPane() {
        let environment = ["ZEN_CONTROL_SOCK": "/a/control.1.sock", "ZEN_PANE": "31"]
        XCTAssertNil(ConnectionOptions.caller(for: "/b/control.2.sock", environment: environment))
        XCTAssertEqual(
            ConnectionOptions.caller(for: "/a/control.1.sock", environment: environment), ControlCaller(pane: 31))
    }
}
