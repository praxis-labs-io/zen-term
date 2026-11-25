import XCTest

@testable import ZenTerm

final class SSHLoginOutputTests: XCTestCase {
    func test_theDetailIsSSHsLatestLine_pastWhatTheScreenAlreadySays() {
        let lines = [
            "Confirm user presence for key ED25519 SHA256:x", "Permission denied, please try again.",
            "Warning: Permanently added 'devbox' (ED25519) to the list of known hosts.",
        ]

        XCTAssertEqual(SSHLoginOutput.detail(of: lines), "Confirm user presence for key ED25519 SHA256:x")
        XCTAssertNil(SSHLoginOutput.detail(of: ["Permission denied, please try again."]))
        XCTAssertNil(SSHLoginOutput.detail(of: []))
    }

    func test_sshsDenial_isFoundAmongItsLines() {
        XCTAssertTrue(SSHLoginOutput.saysDenied(["x", "Permission denied, please try again."]))
        XCTAssertFalse(SSHLoginOutput.saysDenied(["Permission denied (publickey)."]))
    }
}
