import ControlProtocol
import XCTest

@testable import ZenTerm

final class ControlServerTests: XCTestCase {
    private var server: ControlServer?
    private var path = ""
    private var appliedOnMain: [Bool] = []

    override func setUp() {
        super.setUp()
        path = "/tmp/zt-control-\(getpid())-\(name.hashValue & 0xFFFF).sock"
        appliedOnMain = []
        let server = ControlServer(path: path) { [unowned self] request in
            appliedOnMain.append(Thread.isMainThread)
            return .success(HelloResult(app: "test-\(request.id)"))
        }
        server.start()
        self.server = server
    }

    override func tearDown() {
        server?.stop()
        server = nil
        super.tearDown()
    }

    private func exchange(_ lines: [String], expecting count: Int) throws -> [String] {
        let fd = try UnixSocket.connect(to: path)
        let done = expectation(description: "replies read")
        var replies: [String] = []
        DispatchQueue.global().async {
            defer {
                close(fd)
                done.fulfill()
            }
            for line in lines { _ = UnixSocket.writeAll(Data((line + "\n").utf8), to: fd) }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var pending = Data()
            var byte: UInt8 = 0
            while replies.count < count, read(fd, &byte, 1) == 1 {
                if byte == 0x0A {
                    replies.append(String(decoding: pending, as: UTF8.self))
                    pending.removeAll()
                } else {
                    pending.append(byte)
                }
            }
        }
        wait(for: [done], timeout: 5)
        return replies
    }

    private func decode<P>(_ line: String, as: P.Type) throws -> ControlResponse<P> {
        try JSONDecoder().decode(ControlResponse<P>.self, from: Data(line.utf8))
    }

    func test_answersARequestWithItsID() throws {
        let replies = try exchange([#"{"v":1,"id":7,"cmd":"hello"}"#], expecting: 1)
        let response = try decode(XCTUnwrap(replies.first), as: HelloResult.self)
        XCTAssertEqual(response.id, 7)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result, HelloResult(app: "test-7"))
        XCTAssertEqual(appliedOnMain, [true])
    }

    func test_malformedLineIsABadRequestAndTheConnectionStaysUsable() throws {
        let replies = try exchange(["garbage not json", #"{"v":1,"id":2,"cmd":"hello"}"#], expecting: 2)
        guard replies.count == 2 else { return XCTFail("expected two replies, got \(replies)") }
        let rejected = try decode(replies[0], as: NoPayload.self)
        XCTAssertFalse(rejected.ok)
        XCTAssertNil(rejected.id)
        XCTAssertEqual(rejected.error?.code, .badRequest)
        let answered = try decode(replies[1], as: HelloResult.self)
        XCTAssertEqual(answered.id, 2)
        XCTAssertEqual(answered.result, HelloResult(app: "test-2"))
    }

    func test_unknownCommandIsUnknownCommandAndNeverReachesMain() throws {
        let replies = try exchange([#"{"v":1,"id":3,"cmd":"tab.explode"}"#], expecting: 1)
        let response = try decode(XCTUnwrap(replies.first), as: NoPayload.self)
        XCTAssertEqual(response.id, 3)
        XCTAssertEqual(response.error?.code, .unknownCommand)
        XCTAssertEqual(appliedOnMain, [])
    }

    func test_newerVersionIsUnsupported() throws {
        let replies = try exchange([#"{"v":9,"id":4,"cmd":"hello"}"#], expecting: 1)
        let response = try decode(XCTUnwrap(replies.first), as: NoPayload.self)
        XCTAssertEqual(response.error?.code, .unsupportedVersion)
        XCTAssertEqual(response.v, 1)
    }

    func test_anOverlongLineIsRefusedAndTheConnectionClosed() throws {
        let long = String(repeating: "x", count: ControlWire.maxLineLength + 10)
        let fd = try UnixSocket.connect(to: path)
        defer { close(fd) }
        let done = expectation(description: "reply and close")
        var reply = Data()
        DispatchQueue.global().async {
            _ = UnixSocket.writeAll(Data(long.utf8), to: fd)
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var chunk = [UInt8](repeating: 0, count: 1024)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 { break }
                reply.append(contentsOf: chunk[0..<n])
            }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        let line = try XCTUnwrap(String(decoding: reply, as: UTF8.self).split(separator: "\n").first)
        XCTAssertEqual(try decode(String(line), as: NoPayload.self).error?.code, .badRequest)
    }

    func test_socketFileIsOwnerOnly() throws {
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode, 0o600)
    }

    func test_defaultPathIsPerProcessBesideTheNavSocket() {
        XCTAssertTrue(ControlServer.socketPath.hasSuffix("/ZenTerm/control.\(getpid()).sock"))
        XCTAssertEqual(
            URL(fileURLWithPath: ControlServer.socketPath).deletingLastPathComponent(),
            URL(fileURLWithPath: NavSocketServer.socketPath).deletingLastPathComponent())
    }
}
