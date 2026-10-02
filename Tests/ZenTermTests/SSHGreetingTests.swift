import Network
import XCTest

@testable import ZenTerm

final class SSHGreetingTests: XCTestCase {
    private var listener: NWListener?
    private let serverQueue = DispatchQueue(label: "SSHGreetingTests.server")

    override func tearDown() {
        listener?.cancel()
        listener = nil
        super.tearDown()
    }

    private func greeting(_ text: String) -> Bool? { SSHHostProbe.greeting(in: Data(text.utf8)) }

    func test_aVersionLine_isSSH() {
        XCTAssertEqual(greeting("SSH-2.0-OpenSSH_9.8\r\n"), true)
    }

    func test_linesBeforeTheVersion_areSkipped() {
        XCTAssertEqual(greeting("Welcome to devbox\r\nAuthorized use only\r\nSSH-2.0-OpenSSH_9.8\r\n"), true)
    }

    func test_aPartialLine_waitsForMore() {
        XCTAssertNil(greeting("SS"))
        XCTAssertNil(greeting("Welcome\r\nSSH"))
        XCTAssertNil(greeting(""))
    }

    func test_aLineLongerThanTheRFCAllows_isNotSSH() {
        XCTAssertEqual(greeting(String(repeating: "x", count: 300)), false)
        XCTAssertEqual(greeting(String(repeating: "x", count: 300) + "\r\nSSH-2.0-x\r\n"), false)
    }

    func test_manyLinesWithoutAVersion_isNotSSH() {
        XCTAssertEqual(greeting(String(repeating: "HTTP/1.1 400 Bad Request\r\n", count: 8)), false)
    }

    private func serve(_ payload: String?, after delay: TimeInterval = 0) throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = serverQueue
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            guard let payload else { return }
            queue.asyncAfter(deadline: .now() + delay) {
                connection.send(content: Data(payload.utf8), completion: .contentProcessed { _ in })
            }
        }
        let ready = expectation(description: "the listener is up")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 2)
        self.listener = listener
        return try XCTUnwrap(listener.port?.rawValue)
    }

    func test_aServerWithAPreamble_answersSSH() throws {
        let port = try serve("Welcome to devbox\r\nSSH-2.0-test\r\n")

        XCTAssertTrue(SSHHostProbe.answersSSH("127.0.0.1", port: port, connectTimeout: 2, bannerTimeout: 2))
    }

    func test_aSlowGreeting_getsItsOwnTimeoutPastTheConnect() throws {
        let port = try serve("SSH-2.0-test\r\n", after: 1.5)

        XCTAssertTrue(SSHHostProbe.answersSSH("127.0.0.1", port: port, connectTimeout: 1, bannerTimeout: 3))
    }

    func test_aSilentServer_isNotSSH_onceTheGreetingTimesOut() throws {
        let port = try serve(nil)
        let start = Date()

        XCTAssertFalse(SSHHostProbe.answersSSH("127.0.0.1", port: port, connectTimeout: 2, bannerTimeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }
}
