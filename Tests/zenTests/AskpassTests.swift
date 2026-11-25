import ControlProtocol
import XCTest

@testable import zen

final class AskpassTests: XCTestCase {
    private var path = ""
    private var listener: Int32 = -1
    private var received: [ControlRequest] = []
    private let token = "a1b2c3"

    override func setUpWithError() throws {
        try super.setUpWithError()
        path = "/tmp/zt-askpass-\(getpid())-\(name.hashValue & 0xFFFF).sock"
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

    private var environment: [String: String] {
        [ControlEndpoint.askpassTokenKey: token, ControlEndpoint.environmentKey: path]
    }

    private func answerOnce(_ reply: @escaping (ControlRequest) throws -> Data) {
        let fd = listener
        let lock = NSLock()
        DispatchQueue.global().async { [weak self] in
            let conn = accept(fd, nil, nil)
            guard conn >= 0 else { return }
            defer { close(conn) }
            var line = Data()
            var byte: UInt8 = 0
            while read(conn, &byte, 1) == 1, byte != 0x0A { line.append(byte) }
            guard let request = try? ControlRequest.decode(line).get(), let data = try? reply(request) else { return }
            lock.withLock { self?.received.append(request) }
            _ = UnixSocket.writeAll(data, to: conn)
        }
    }

    func test_runsOnlyForSSH_withTheTokenAndOneArgument() {
        let ssh = "/usr/bin/ssh"
        XCTAssertTrue(Askpass.runs(arguments: ["zen", "Password: "], environment: environment, parent: ssh))
        XCTAssertTrue(
            Askpass.runs(arguments: ["zen", "Password: "], environment: environment, parent: "/opt/homebrew/bin/ssh"))
        XCTAssertFalse(Askpass.runs(arguments: ["zen", "list", "--pretty"], environment: environment, parent: ssh))
        XCTAssertFalse(Askpass.runs(arguments: ["zen", "list"], environment: [:], parent: ssh))
        XCTAssertFalse(
            Askpass.runs(arguments: ["zen", "list"], environment: [ControlEndpoint.askpassTokenKey: ""], parent: ssh))
        XCTAssertFalse(
            Askpass.runs(arguments: ["zen", "list"], environment: environment, parent: "/bin/zsh"),
            "a ProxyCommand's own zen call keeps the CLI")
        XCTAssertFalse(Askpass.runs(arguments: ["zen", "list"], environment: environment, parent: nil))
    }

    func test_printsTheAnswer_andSendsThePromptVerbatimWithTheToken() {
        answerOnce { try AskpassResult(answer: AskpassAnswer("s3cret")).responseLine(id: $0.id) }
        var printed: [String] = []
        var errors: [String] = []

        let code = Askpass.exitCode(
            prompt: "-oops's password: ", environment: environment, sshPID: 4242,
            answer: { printed.append($0) }, fail: { errors.append($0) })

        XCTAssertEqual(code, 0)
        XCTAssertEqual(printed, ["s3cret"])
        XCTAssertEqual(errors, [])
        XCTAssertEqual(
            received,
            [
                ControlRequest(
                    id: 1, cmd: .sshAskpass, args: ControlArgs(token: token, prompt: "-oops's password: ", sshPID: 4242)
                )
            ])
    }

    func test_aYesNoConfirmIsRefusedWithoutAsking_andANoticeNeedsNoAnswer() {
        var printed: [String] = []
        for (hint, expected) in [("confirm", Int32(1)), ("none", Int32(0))] {
            var env = environment
            env[Askpass.hintKey] = hint
            XCTAssertEqual(
                Askpass.exitCode(prompt: "Allow?", environment: env, answer: { printed.append($0) }, fail: { _ in }),
                expected)
        }
        XCTAssertEqual(printed, [])
        XCTAssertEqual(received, [])
    }

    func test_aRefusalFails_andItsMessageHoldsNeitherPromptNorAnswer() {
        answerOnce { try ControlError(.notFound, "No ssh login is waiting for an answer.").responseLine(id: $0.id) }
        var printed: [String] = []
        var errors: [String] = []

        let code = Askpass.exitCode(
            prompt: "secret-prompt-text", environment: environment, answer: { printed.append($0) },
            fail: { errors.append($0) })

        XCTAssertEqual(code, 1)
        XCTAssertEqual(printed, [])
        XCTAssertEqual(errors, ["zen: No ssh login is waiting for an answer. (not_found)"])
    }
}
