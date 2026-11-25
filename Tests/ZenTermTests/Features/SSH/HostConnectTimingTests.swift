import AppKit
import XCTest

@testable import ZenTerm

@MainActor
final class HostConnectTimingTests: WindowTestCase {
    private var clock: CFTimeInterval = 100
    private var scheduled: [(delay: TimeInterval, work: () -> Void)] = []
    private var handOffs = 0
    private var answersShown: [HostConnectView.Outcome] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        Motion.isReduceMotionEnabled = { false }
        HostConnectView.now = { [unowned self] in self.clock }
        HostConnectView.after = { [unowned self] delay, work in self.scheduled.append((delay, work)) }
    }

    private func connecting() -> HostConnectView {
        let view = HostConnectView(
            host: SSHHostID(alias: "devbox"), name: "devbox", status: .online, destination: nil, onConnect: {},
            onFocusRequest: {})
        view.onHandOff = { [unowned self] in self.handOffs += 1 }
        view.onAnswerShown = { [unowned self] in self.answersShown.append($0) }
        view.setLogin(HostConnectView.Login(question: nil, output: []))
        return view
    }

    private func runNext() throws -> TimeInterval {
        let next = try XCTUnwrap(scheduled.first, "nothing was scheduled")
        scheduled.removeFirst()
        clock += next.delay
        next.work()
        return next.delay
    }

    func test_aFastAnswer_waitsOutTheMinimumRain_thenItsWordsFollowTheGlyph() throws {
        let view = connecting()
        clock += 0.1

        view.setLogin(nil)
        view.setOutcome(.failed(reason: nil))

        XCTAssertEqual(try runNext(), Motion.HostConnect.minimumRain - 0.1, accuracy: 1e-9)
        XCTAssertEqual(view.emblemForTesting.glyphForTesting, .cross)
        XCTAssertEqual(view.statusForTesting, "Connecting…", "the words wait for the glyph to form")
        XCTAssertEqual(try runNext(), Motion.HostConnect.answerDelay)
        XCTAssertEqual(view.statusForTesting, "Couldn't connect")
        XCTAssertEqual(answersShown, [.failed(reason: nil)])
    }

    func test_aSlowAnswer_landsAtOnce() throws {
        let view = connecting()
        clock += 3

        view.setLogin(nil)
        view.setOutcome(.connected)

        XCTAssertEqual(try runNext(), 0)
    }

    func test_aConnectedAnswer_handsOffOnceTheGlyphHasSettled() throws {
        let view = connecting()
        clock += 1

        view.setLogin(nil)
        view.setOutcome(.connected)
        _ = try runNext()
        _ = try runNext()
        XCTAssertEqual(view.statusForTesting, "Connected")
        XCTAssertEqual(handOffs, 0)
        let handOff = try XCTUnwrap(scheduled.last).delay

        XCTAssertGreaterThan(handOff, Motion.HostConnect.settledToHandOff)
        scheduled.removeLast().work()
        XCTAssertEqual(handOffs, 1)
    }

    func test_anAnswerReplacedBeforeItLands_isDropped() throws {
        let view = connecting()
        view.setLogin(nil)
        view.setOutcome(.connected)

        view.setOutcome(nil)
        for item in scheduled { item.work() }

        XCTAssertNil(view.emblemForTesting.glyphForTesting)
        XCTAssertEqual(handOffs, 0)
        XCTAssertTrue(answersShown.isEmpty)
    }

    func test_whileTheAnswerForms_returnDoesNotReconnect() throws {
        var connects = 0
        let view = HostConnectView(
            host: SSHHostID(alias: "devbox"), name: "devbox", status: .online, destination: nil,
            onConnect: { connects += 1 }, onFocusRequest: {})
        view.setLogin(HostConnectView.Login(question: nil, output: []))
        view.setLogin(nil)
        view.setOutcome(.failed(reason: nil))
        let returnKey = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))

        view.keyDown(with: returnKey)
        XCTAssertEqual(connects, 0)
        while !scheduled.isEmpty { _ = try runNext() }
        view.keyDown(with: returnKey)
        XCTAssertEqual(connects, 1, "Retry once the failure shows")
    }
}
