import XCTest

@testable import ZenTerm

final class SSHLoginPromptTests: XCTestCase {
    func test_secretsKeepSSHsWordsWithoutTheTrailingColon() {
        XCTAssertEqual(
            SSHLoginPrompt.parse("Enter passphrase for key '/Users/me/.ssh/id_ed25519': "),
            .secret(label: "Enter passphrase for key '/Users/me/.ssh/id_ed25519'"))
        XCTAssertEqual(
            SSHLoginPrompt.parse("me@[127.0.0.1]:22622's password: "), .secret(label: "me@[127.0.0.1]:22622's password")
        )
        XCTAssertEqual(
            SSHLoginPrompt.parse("(me@devbox) Verification code:"), .secret(label: "(me@devbox) Verification code"))
    }

    func test_anUnknownHostIsAHostKey_withItsTypeAndFingerprint() {
        let prompt = """
            The authenticity of host '[127.0.0.1]:22622 ([127.0.0.1]:22622)' can't be established.
            ED25519 key fingerprint is: SHA256:Ddh6AiyxUdOZKfIK9rti77ebCzauHfX8qDY3SrKKNkw
            This key is not known by any other names.
            Are you sure you want to continue connecting (yes/no/[fingerprint])? 
            """
        XCTAssertEqual(
            SSHLoginPrompt.parse(prompt),
            .hostKey(fingerprint: "ED25519 SHA256:Ddh6AiyxUdOZKfIK9rti77ebCzauHfX8qDY3SrKKNkw"))
    }

    func test_olderSSHsTrailingPeriodIsNotPartOfTheFingerprint() {
        XCTAssertEqual(
            SSHLoginPrompt.parse(
                "ECDSA key fingerprint is SHA256:Ddh6AiyxUdOZ.\nAre you sure you want to continue connecting "
                    + "(yes/no/[fingerprint])? "),
            .hostKey(fingerprint: "ECDSA SHA256:Ddh6AiyxUdOZ"))
    }

    func test_theHostKeyAgainPromptsAndTheIPMismatchAreHostKeys() {
        XCTAssertEqual(
            SSHLoginPrompt.parse("Please type 'yes', 'no' or the fingerprint: "), .hostKey(fingerprint: nil))
        XCTAssertEqual(
            SSHLoginPrompt.parse(
                "Warning: the ED25519 host key for 'devbox' differs from the key for the IP address '10.0.0.2'\n"
                    + "Are you sure you want to continue connecting (yes/no)? "),
            .hostKey(fingerprint: nil))
    }
}
