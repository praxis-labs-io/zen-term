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
        let server = ControlServer(path: path) { [unowned self] request, reply in
            appliedOnMain.append(Thread.isMainThread)
            guard request.cmd == .list else { return reply(.success(HelloResult(app: "test-\(request.id)"))) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                reply(.success(HelloResult(app: "later-\(request.id)")))
                reply(.success(HelloResult(app: "twice-\(request.id)")))
            }
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

    func test_aReplyThatArrivesLaterIsWrittenOnceAndInOrder() throws {
        let replies = try exchange(
            [#"{"v":1,"id":1,"cmd":"list"}"#, #"{"v":1,"id":2,"cmd":"hello"}"#, #"{"v":1,"id":3,"cmd":"hello"}"#],
            expecting: 3)
        let answered = try replies.map { try decode($0, as: HelloResult.self).result?.app }
        XCTAssertEqual(answered, ["later-1", "test-2", "test-3"])
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

    private func paddedHello(length: Int) -> String {
        let head = #"{"v":1,"id":5,"cmd":"hello","pad":""#
        let tail = #""}"#
        return head + String(repeating: "x", count: length - head.count - tail.count) + tail
    }

    func test_anOverlongLineIsRefusedAndTheConnectionClosed() throws {
        let line = try XCTUnwrap(firstReply(toRaw: String(repeating: "x", count: ControlWire.maxLineLength + 10)))
        XCTAssertEqual(try decode(line, as: NoPayload.self).error?.code, .badRequest)
    }

    func test_anOverlongLineWhoseNewlineArrivesWithItIsRefused() throws {
        let request = paddedHello(length: ControlWire.maxLineLength + 10)
        XCTAssertEqual(request.utf8.count, ControlWire.maxLineLength + 10)

        let line = try XCTUnwrap(firstReply(toRaw: request + "\n"))

        let response = try decode(line, as: NoPayload.self)
        XCTAssertEqual(response.error?.code, .badRequest, line)
        XCTAssertNil(response.id)
        XCTAssertEqual(appliedOnMain, [])
    }

    func test_aLineAtTheLimitIsAnswered() throws {
        let line = try XCTUnwrap(firstReply(toRaw: paddedHello(length: ControlWire.maxLineLength) + "\n"))
        XCTAssertEqual(try decode(line, as: HelloResult.self).id, 5)
    }

    private func firstReply(toRaw payload: String) throws -> String? {
        let fd = try UnixSocket.connect(to: path)
        defer { close(fd) }
        let done = expectation(description: "first reply")
        var reply = Data()
        DispatchQueue.global().async {
            defer { done.fulfill() }
            _ = UnixSocket.writeAll(Data(payload.utf8), to: fd)
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var chunk = [UInt8](repeating: 0, count: 1024)
            while !reply.contains(0x0A) {
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 { break }
                reply.append(contentsOf: chunk[0..<n])
            }
        }
        wait(for: [done], timeout: 5)
        return String(decoding: reply, as: UTF8.self).split(separator: "\n").first.map(String.init)
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
