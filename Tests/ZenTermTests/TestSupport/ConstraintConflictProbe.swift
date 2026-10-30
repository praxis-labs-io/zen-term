import XCTest

extension XCTestCase {
    // AppKit reports an unsatisfiable layout as an XCTest issue on a later run-loop turn, so this drains one.
    @MainActor
    func constraintConflicts(during body: () throws -> Void) rethrows -> [String] {
        let probe = ConstraintConflictObserver()
        XCTestObservationCenter.shared.addTestObserver(probe)
        defer { XCTestObservationCenter.shared.removeTestObserver(probe) }
        try body()
        let flushed = expectation(description: "run loop turn")
        DispatchQueue.main.async { flushed.fulfill() }
        wait(for: [flushed], timeout: 5)
        return probe.messages
    }
}

private final class ConstraintConflictObserver: NSObject, XCTestObservation {
    private(set) var messages: [String] = []

    func testCase(_ testCase: XCTestCase, didRecord issue: XCTIssue) {
        guard issue.compactDescription.hasPrefix("Conflicting constraints") else { return }
        messages.append(issue.compactDescription)
    }
}
