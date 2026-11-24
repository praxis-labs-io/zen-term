import AppKit
import XCTest

@testable import ZenTerm

final class GallerySamplesTests: WindowTestCase {
    private static let sampleWidth: CGFloat = 200

    private var window: NSWindow!
    private var samples: [NSView] = []
    private var flow: GallerySamples!

    override func setUpWithError() throws {
        try super.setUpWithError()
        samples = (0..<4).map { _ in Self.fixedSample() }
        flow = GallerySamples(samples)
        let content = NSView()
        content.addSubview(flow)
        NSLayoutConstraint.activate([
            flow.topAnchor.constraint(equalTo: content.topAnchor),
            flow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            flow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 400), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.orderFront(nil)
    }

    override func tearDownWithError() throws {
        window = nil
        try super.tearDownWithError()
    }

    @MainActor
    func test_samplesWrapToTheRowWidth_andReflowWhenTheWindowResizes() {
        resize(to: 1000)
        XCTAssertEqual(flow.lineCountForTesting, 1, "four 200pt samples fit one 1000pt row")
        assertSamplesFitTheRow()

        resize(to: 500)
        XCTAssertEqual(flow.lineCountForTesting, 2, "a narrower window wraps the row to two samples a line")
        assertSamplesFitTheRow()
        XCTAssertGreaterThan(flow.frame.height, samples[0].frame.height * 2, "the row grows to hold the wrapped line")

        resize(to: 1000)
        XCTAssertEqual(flow.lineCountForTesting, 1, "widening the window again unwraps the row")
        XCTAssertEqual(flow.frame.height, samples[0].frame.height, "the row shrinks back to one line")
    }

    @MainActor
    private func resize(to width: CGFloat) {
        window.setContentSize(NSSize(width: width, height: 400))
        window.layoutIfNeeded()
    }

    @MainActor
    private func assertSamplesFitTheRow(file: StaticString = #filePath, line: UInt = #line) {
        for sample in samples {
            XCTAssertLessThanOrEqual(
                sample.frame.maxX, flow.bounds.width, "a sample runs past the row's width", file: file, line: line)
        }
    }

    private static func fixedSample() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: sampleWidth),
            view.heightAnchor.constraint(equalToConstant: 40),
        ])
        return view
    }
}
