import ControlProtocol
import XCTest

@testable import zen

final class ControlClientTests: XCTestCase {
    private var path = ""
    private var listener: Int32 = -1
    private var received: [ControlRequest] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        path = "/tmp/zt-client-\(getpid())-\(name.hashValue & 0xFFFF).sock"
        unlink(path)
        var addr = try XCTUnwrap(UnixSocket.address(for: path))
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(listener, 4), 0)
    }

    override func tearDownWithError() throws {
        close(listener)
        unlink(path)
        try super.tearDownWithError()
    }

    private func answerOnce(_ reply: @escaping (ControlRequest) throws -> Data) {
        let fd = listener
        DispatchQueue.global().async { [weak self] in
            let conn = accept(fd, nil, nil)
            guard conn >= 0 else { return }
            defer { close(conn) }
            var line = Data()
            var byte: UInt8 = 0
            while read(conn, &byte, 1) == 1, byte != 0x0A { line.append(byte) }
            guard let request = try? ControlRequest.decode(line).get(), let data = try? reply(request) else { return }
            DispatchQueue.main.async { self?.received.append(request) }
            _ = UnixSocket.writeAll(data, to: conn)
        }
    }

    func test_decodesTheResultAndSendsTheCaller() throws {
        answerOnce { try HelloResult(app: "9.9.9").responseLine(id: $0.id) }

        let hello = try ControlClient(path: path, caller: ControlCaller(pane: 31))
            .send(.hello, expecting: HelloResult.self)

        XCTAssertEqual(hello, HelloResult(app: "9.9.9"))
        let drained = expectation(description: "main")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        XCTAssertEqual(received, [ControlRequest(id: 1, cmd: .hello, caller: ControlCaller(pane: 31))])
    }

    func test_anErrorReplyIsAnAppError() {
        answerOnce { try ControlError(.notFound, "No pane 4.").responseLine(id: $0.id) }

        XCTAssertThrowsError(try ControlClient(path: path, caller: nil).send(.list, expecting: ListResult.self)) {
            XCTAssertEqual($0 as? ZenFailure, .app("No pane 4. (not_found)"))
        }
    }

    func test_aHangUpWithoutAnswerIsAConnectionFailure() {
        answerOnce { _ in Data() }

        XCTAssertThrowsError(try ControlClient(path: path, caller: nil).send(.list, expecting: ListResult.self)) {
            XCTAssertEqual(($0 as? ZenFailure)?.exitCode, 3)
        }
    }
}
