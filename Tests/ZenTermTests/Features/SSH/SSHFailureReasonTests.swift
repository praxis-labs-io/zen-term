import XCTest

@testable import ZenTerm

final class SSHFailureReasonTests: XCTestCase {
    func test_theLastLineIsTheReason_withoutSSHsPrefix() {
        XCTAssertEqual(
            SSHFailureReason.parse("ssh: connect to host 127.0.0.1 port 1: Connection refused\r\r\n"),
            "Connect to host 127.0.0.1 port 1: Connection refused")
        XCTAssertEqual(
            SSHFailureReason.parse(
                "ssh: Could not resolve hostname no-such-host.invalid: nodename nor servname provided, or not known"),
            "Could not resolve hostname no-such-host.invalid: nodename nor servname provided, or not known")
        XCTAssertEqual(
            SSHFailureReason.parse("ssh: connect to host 10.255.255.1 port 22622: Operation timed out"),
            "Connect to host 10.255.255.1 port 22622: Operation timed out")
    }

    func test_anAuthFailure_keepsItsLastLine_pastEarlierRetries() {
        let tail = """
            Permission denied, please try again.
            Permission denied, please try again.
            drucial@127.0.0.1: Permission denied (password).

            """
        XCTAssertEqual(SSHFailureReason.parse(tail), "drucial@127.0.0.1: Permission denied (password).")
    }

    func test_aHostKeyFailure_afterItsBanner_readsTheLastLine() {
        let tail = """
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            Host key verification failed.
            """
        XCTAssertEqual(SSHFailureReason.parse(tail), "Host key verification failed.")
    }

    func test_throughAJumpHost_theReasonIsTheLineBeforeItsClose() {
        let tail = """
            drucial@127.0.0.1: Permission denied (publickey).
            Connection closed by UNKNOWN port 65535
            """
        XCTAssertEqual(SSHFailureReason.parse(tail), "drucial@127.0.0.1: Permission denied (publickey).")
    }

    func test_aBareCloseByTheServer_saysNothingUseful() {
        XCTAssertNil(SSHFailureReason.parse("Connection closed by 127.0.0.1 port 22622\r\r\n"))
    }

    func test_anEmptyTerminal_hasNoReason() {
        XCTAssertNil(SSHFailureReason.parse(""))
        XCTAssertNil(SSHFailureReason.parse("\n  \r\n"))
    }
}
