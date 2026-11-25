import XCTest

@testable import ZenTerm

final class SSHFailureReasonTests: XCTestCase {
    func test_theLastLineIsTheReason_verbatim_withoutSSHsPrefix() {
        XCTAssertEqual(
            SSHFailureReason.parse("ssh: connect to host 127.0.0.1 port 1: Connection refused\r\r\n"),
            "connect to host 127.0.0.1 port 1: Connection refused")
        XCTAssertEqual(
            SSHFailureReason.parse(
                "ssh: Could not resolve hostname no-such-host.invalid: nodename nor servname provided, or not known"),
            "Could not resolve hostname no-such-host.invalid: nodename nor servname provided, or not known")
        XCTAssertEqual(
            SSHFailureReason.parse("ssh: connect to host 10.255.255.1 port 22622: Operation timed out"),
            "connect to host 10.255.255.1 port 22622: Operation timed out")
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

    func test_loginsOwnBanner_isNoReason() {
        XCTAssertNil(SSHFailureReason.parse("Last login: Tue Nov 24 10:01:02 on ttys003\r\n"))
        XCTAssertEqual(
            SSHFailureReason.parse(
                "devbox: Permission denied (publickey).\nLast login: Tue Nov 24 10:01:02 on ttys003"),
            "devbox: Permission denied (publickey).")
    }

    func test_eachKnownFailure_getsAPlainHeadline() {
        let headlines = [
            "Could not resolve hostname zenlab-nowhere.invalid: nodename nor servname provided, or not known":
                "This host can't be found",
            "connect to host 127.0.0.1 port 1: Connection refused": "The host refused the connection",
            "connect to host 10.255.255.1 port 22: Operation timed out": "The host didn't answer",
            "connect to host 10.255.255.1 port 22: Connection timed out": "The host didn't answer",
            "drucial@127.0.0.1: Permission denied (publickey,password).": "Couldn't sign in",
            "Host key verification failed.": "Couldn't verify the host's key",
            "kex_exchange_identification: read: Connection reset by peer": "Couldn't connect",
        ]
        for (reason, headline) in headlines {
            XCTAssertEqual(SSHFailureReason.headline(for: reason), headline, reason)
        }
        XCTAssertEqual(SSHFailureReason.headline(for: nil), "Couldn't connect")
    }

    func test_throughAJumpHost_theHeadlineReadsTheRealReason() {
        let tail = """
            ssh: Could not resolve hostname inner.invalid: nodename nor servname provided, or not known
            Connection closed by UNKNOWN port 65535
            """
        let reason = SSHFailureReason.parse(tail)

        XCTAssertEqual(reason, "Could not resolve hostname inner.invalid: nodename nor servname provided, or not known")
        XCTAssertEqual(SSHFailureReason.headline(for: reason), "This host can't be found")
    }
}
