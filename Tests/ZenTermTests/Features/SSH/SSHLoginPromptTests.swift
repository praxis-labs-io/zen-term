import XCTest

@testable import ZenTerm

final class SSHLoginPromptTests: XCTestCase {
    func test_aKeysPassphrase_namesTheKeyFile() {
        XCTAssertEqual(
            SSHLoginPrompt.parse("Enter passphrase for key '/Users/me/.ssh/id_ed25519_zenlab': "),
            .secret(headline: "Enter the passphrase for id_ed25519_zenlab"))
    }

    func test_aPassword_isAskedPlainly() {
        XCTAssertEqual(
            SSHLoginPrompt.parse("me@[127.0.0.1]:22622's password: "), .secret(headline: "Enter your password"))
        XCTAssertEqual(SSHLoginPrompt.parse("devbox's password: "), .secret(headline: "Enter your password"))
        XCTAssertEqual(SSHLoginPrompt.parse("(me@devbox) Password:"), .secret(headline: "Enter your password"))
        XCTAssertEqual(SSHLoginPrompt.parse("Password: "), .secret(headline: "Enter your password"))
    }

    func test_aServersOwnPrompt_dropsOnlyTheUserAtHostPrefix() {
        XCTAssertEqual(
            SSHLoginPrompt.parse("(me@devbox) Verification code: "), .secret(headline: "Verification code:"))
    }

    func test_anUnrecognizedPrompt_keepsSSHsText() {
        XCTAssertEqual(
            SSHLoginPrompt.parse("Enter PIN for ECDSA-SK key /Users/me/.ssh/id_ecdsa_sk: "),
            .secret(headline: "Enter PIN for ECDSA-SK key /Users/me/.ssh/id_ecdsa_sk:"))
    }

    func test_anUnknownHostIsAHostKey_withItsTypeInTheHeadline_andItsFingerprintApart() {
        let prompt = """
            The authenticity of host '[127.0.0.1]:22622 ([127.0.0.1]:22622)' can't be established.
            ED25519 key fingerprint is: SHA256:Ddh6AiyxUdOZKfIK9rti77ebCzauHfX8qDY3SrKKNkw
            This key is not known by any other names.
            Are you sure you want to continue connecting (yes/no/[fingerprint])? 
            """
        let parsed = SSHLoginPrompt.parse(prompt)

        XCTAssertEqual(
            parsed, .hostKey(type: "ED25519", fingerprint: "SHA256:Ddh6AiyxUdOZKfIK9rti77ebCzauHfX8qDY3SrKKNkw"))
        XCTAssertEqual(parsed.headline, "New ED25519 host key")
    }

    func test_olderSSHsTrailingPeriodIsNotPartOfTheFingerprint() {
        XCTAssertEqual(
            SSHLoginPrompt.parse(
                "ECDSA key fingerprint is SHA256:Ddh6AiyxUdOZ.\nAre you sure you want to continue connecting "
                    + "(yes/no/[fingerprint])? "),
            .hostKey(type: "ECDSA", fingerprint: "SHA256:Ddh6AiyxUdOZ"))
    }

    func test_theHostKeyAgainPromptsAndTheIPMismatchAreHostKeys_withNoTypeToName() {
        let again = SSHLoginPrompt.parse("Please type 'yes', 'no' or the fingerprint: ")
        XCTAssertEqual(again, .hostKey(type: nil, fingerprint: nil))
        XCTAssertEqual(again.headline, "New host key")
        XCTAssertEqual(
            SSHLoginPrompt.parse(
                "Warning: the ED25519 host key for 'devbox' differs from the key for the IP address '10.0.0.2'\n"
                    + "Are you sure you want to continue connecting (yes/no)? "),
            .hostKey(type: nil, fingerprint: nil))
    }

    func test_aFingerprint_splitsIntoTwoHalvesOfEqualLength() {
        let fingerprint = "SHA256:Ddh6AiyxUdOZKfIK9rti77ebCzauHfX8qDY3SrKKNkw"
        let lines = SSHLoginPrompt.fingerprintLines(fingerprint).split(separator: "\n")

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].count, lines[1].count)
        XCTAssertEqual(lines.joined(), fingerprint)
    }

    func test_anOddFingerprint_putsTheExtraCharacterOnTheFirstLine() {
        XCTAssertEqual(SSHLoginPrompt.fingerprintLines("SHA256:abcde"), "SHA256\n:abcde")
        XCTAssertEqual(SSHLoginPrompt.fingerprintLines("abc"), "ab\nc")
        XCTAssertEqual(SSHLoginPrompt.fingerprintLines("a"), "a")
    }
}
