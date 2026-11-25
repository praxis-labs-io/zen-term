import XCTest

@testable import ZenTerm

final class HostEmblemMotionTests: XCTestCase {
    private let signature = HostSignature.cells(of: SSHHostID(alias: "devbox"))
    private let cells = 0..<HostEmblemMotion.cellCount

    private func levels(_ motion: HostEmblemMotion, at time: TimeInterval) -> [Double] {
        cells.map { motion.cell($0, at: time).level }
    }

    func test_theRainStartsFromTheSignature() {
        let motion = HostEmblemMotion(signature: signature, seed: 7)

        XCTAssertEqual(cells.map { motion.cell($0, at: 0).level == 1 }, signature)
    }

    func test_theSameSeedRainsTheSameWay_andAnotherSeedDoesNot() {
        let times = stride(from: 0.0, through: 6, by: 0.1)
        let first = HostEmblemMotion(signature: signature, seed: 7)
        let again = HostEmblemMotion(signature: signature, seed: 7)
        let other = HostEmblemMotion(signature: signature, seed: 8)

        XCTAssertEqual(times.map { levels(first, at: $0) }, times.map { levels(again, at: $0) })
        XCTAssertNotEqual(times.map { levels(first, at: $0) }, times.map { levels(other, at: $0) })
    }

    func test_theRainKeepsFalling_longAfterTheSignatureLetsGo() {
        let motion = HostEmblemMotion(signature: signature, seed: 7)
        let late = stride(from: 30.0, through: 32, by: 0.05)

        XCTAssertTrue(late.contains { levels(motion, at: $0).contains { $0 > 0.5 } })
    }

    func test_everySpiralVisitsEachCellOnce() {
        for seed in UInt64(0)..<20 {
            let order = HostEmblemMotion(signature: signature, seed: seed).orderForTesting
            XCTAssertEqual(order.sorted(), Array(cells), "seed \(seed)")
        }
    }

    func test_aResolveSettlesExactlyIntoItsGlyph_inItsOwnColor() throws {
        for glyph in [HostEmblemGlyph.check, .cross] {
            let motion = HostEmblemMotion(signature: signature, seed: 3)
            motion.resolve(to: glyph, at: 1.3)
            let settled = try XCTUnwrap(motion.settledAt)

            XCTAssertGreaterThan(settled, 1.3)
            XCTAssertLessThanOrEqual(settled, 1.3 + Motion.HostConnect.claimSpan + Motion.HostConnect.settleDownLongest)
            XCTAssertEqual(levels(motion, at: settled), glyph.cells.map { $0 ? 1 : 0 }, "\(glyph)")
            XCTAssertEqual(cells.map { motion.cell($0, at: settled).glyphMix }, Array(repeating: 1, count: cells.count))
        }
    }

    func test_beforeItsAnswer_aResolveChangesNothing() {
        let rain = HostEmblemMotion(signature: signature, seed: 3)
        let resolving = HostEmblemMotion(signature: signature, seed: 3)
        resolving.resolve(to: .check, at: 2)

        XCTAssertEqual(levels(resolving, at: 1.9), levels(rain, at: 1.9))
    }
}
