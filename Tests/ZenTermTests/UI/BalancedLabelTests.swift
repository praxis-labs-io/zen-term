import AppKit
import XCTest

@testable import ZenTerm

@MainActor
final class BalancedLabelTests: WindowTestCase {
    private let font = ChromeType.font(.small)
    private let text = "Enter the six digit code from the authenticator app on your phone to finish signing in"

    private func mounted(_ label: BalancedLabel) -> BalancedLabel {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled], backing: .buffered,
            defer: false)
        let content = NSView()
        window.contentView = content
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        content.layoutSubtreeIfNeeded()
        return label
    }

    private func greedyLineCount(at width: CGFloat) -> Int {
        let plain = NSTextField(wrappingLabelWithString: text)
        plain.font = font
        let bounds = NSRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        let height = plain.cell?.cellSize(forBounds: bounds).height ?? 0
        return Int((height / NSLayoutManager().defaultLineHeight(for: font)).rounded())
    }

    func test_wrappedText_keepsItsLineCount_atTheNarrowestWidth() {
        let label = mounted(BalancedLabel(font: font, wrapWidth: 360))
        label.stringValue = text
        label.superview?.layoutSubtreeIfNeeded()

        XCTAssertEqual(label.lineCountForTesting, greedyLineCount(at: 360), "balancing never adds a line")
        XCTAssertLessThan(label.frame.width, 359, "the lines sit narrower than the wrap width")
        let narrower = BalancedLabel(font: font, wrapWidth: label.intrinsicContentSize.width - 1)
        narrower.stringValue = text
        XCTAssertGreaterThan(
            narrower.intrinsicContentSize.height, label.intrinsicContentSize.height,
            "one point narrower takes another line")
    }

    func test_shortText_staysOneLine_atItsOwnWidth() {
        let label = mounted(BalancedLabel(font: font, wrapWidth: 360))
        label.stringValue = "Connecting…"
        label.superview?.layoutSubtreeIfNeeded()

        XCTAssertEqual(label.lineCountForTesting, 1)
        XCTAssertLessThan(label.frame.width, 120)
    }

    func test_aNarrowerWrapWidth_wrapsInsteadOfTruncating() {
        let label = mounted(BalancedLabel(font: font, wrapWidth: 360))
        label.stringValue = text
        label.wrapWidth = 160
        label.superview?.layoutSubtreeIfNeeded()

        XCTAssertLessThanOrEqual(label.frame.width, 160)
        XCTAssertEqual(label.lineCountForTesting, greedyLineCount(at: 160))
    }
}
