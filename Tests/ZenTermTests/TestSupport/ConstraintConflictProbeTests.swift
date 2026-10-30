import AppKit
import XCTest

final class ConstraintConflictProbeTests: WindowTestCase {
    func test_aViewAskedForTwoWidths_isReportedAsAConflict() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let content = window.contentView!
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)

        let conflicts = constraintConflicts {
            NSLayoutConstraint.activate([
                view.widthAnchor.constraint(equalToConstant: 100),
                view.widthAnchor.constraint(equalToConstant: 200),
            ])
            content.layoutSubtreeIfNeeded()
        }

        XCTAssertEqual(conflicts.count, 1)
    }
}
