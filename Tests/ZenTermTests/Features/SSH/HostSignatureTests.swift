import XCTest

@testable import ZenTerm

final class HostSignatureTests: XCTestCase {
    private func pattern(_ alias: String) -> String {
        HostSignature.cells(of: SSHHostID(alias: alias)).map { $0 ? "1" : "0" }.joined()
    }

    func test_aSignature_isTheAliasesMD5_readRowByRow_andMirrored() {
        XCTAssertEqual(
            pattern("devbox"), "11111" + "11011" + "10001" + "10101" + "10101", "MD5 fa5bd82b…, high bit first")
    }

    func test_everyRow_mirrorsLeftToRight() {
        for alias in ["devbox", "prod", "deploy@10.0.0.5", "omakase-work"] {
            let cells = HostSignature.cells(of: SSHHostID(alias: alias))
            for row in 0..<5 {
                let line = Array(cells[row * 5..<row * 5 + 5])
                XCTAssertEqual(line, line.reversed(), "\(alias) row \(row)")
            }
        }
    }

    func test_differentAliases_drawDifferentSignatures_andOneAliasAlwaysTheSame() {
        XCTAssertNotEqual(pattern("devbox"), pattern("prod"))
        XCTAssertEqual(pattern("devbox"), pattern("devbox"))
    }
}
