import AppKit
import XCTest

// A row chooses on the release, and only when the release lands inside it. `point` is in window coordinates.
@MainActor
func sendClick(to view: NSView, at point: NSPoint? = nil) throws {
    let location = point ?? view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1))
        type == .leftMouseDown ? view.mouseDown(with: event) : view.mouseUp(with: event)
    }
}
