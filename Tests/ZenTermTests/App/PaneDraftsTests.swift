import XCTest

@testable import ZenTerm

final class PaneDraftsTests: XCTestCase {
    private let drafts = PaneDrafts()
    private let surface = SurfaceID(raw: 1)
    private var now = Date(timeIntervalSince1970: 1_000_000)
    private var due: [(at: Date, work: () -> Void)] = []
    private var delivered: [(name: String, overDraft: Bool)] = []
    private var dropped: [String] = []

    override func setUp() {
        super.setUp()
        drafts.now = { [unowned self] in now }
        drafts.after = { [unowned self] delay, work in due.append((now.addingTimeInterval(delay), work)) }
    }

    private func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        while let next = due.firstIndex(where: { $0.at <= now }) {
            due.remove(at: next).work()
        }
    }

    private func message(
        _ name: String, setsDraftAside: @escaping () -> Bool = { true }, isBlocked: @escaping () -> Bool = { false }
    ) -> PaneDrafts.Message {
        PaneDrafts.Message(
            isTask: false, setsDraftAside: setsDraftAside, isBlocked: isBlocked,
            deliver: { [unowned self] in delivered.append((name, $0)) },
            drop: { [unowned self] _ in dropped.append(name) })
    }

    func test_aMessageBehindADroppedOneIsJudgedOnItsOwn_soOneThatCannotSetTheDraftAsideWaits() {
        var blocked = true
        drafts.typed(.add("mine"), into: surface)
        drafts.queue(surface, message("submits", isBlocked: { blocked }))
        drafts.queue(surface, message("only pastes", setsDraftAside: { false }))

        advance(PaneDrafts.draftWait)
        for _ in 0...Int(PaneDrafts.longestBlockedHold) {
            if dropped.isEmpty { advance(PaneDrafts.blockedRecheck) } else { blocked = false }
        }
        advance(3600)

        XCTAssertEqual(dropped, ["submits"])
        XCTAssertTrue(delivered.isEmpty, "\(delivered)")
    }

    func test_anAgentThatCanSetTheDraftAsideOnlyLaterStillGetsTheMinute() {
        var canSetAside = false
        drafts.typed(.add("mine"), into: surface)
        drafts.queue(surface, message("go", setsDraftAside: { canSetAside }))
        canSetAside = true

        advance(PaneDrafts.draftWait)

        XCTAssertEqual(delivered.map(\.name), ["go"])
        XCTAssertEqual(delivered.map(\.overDraft), [true])
    }
}
