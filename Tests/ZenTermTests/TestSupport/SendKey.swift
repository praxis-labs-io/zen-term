import AppKit
import XCTest

@testable import ZenTerm

// A key a person types, through `KeyInterceptor` and then the window, the path it takes before the responder chain.
enum TypedKey {
    case character(String)
    case returnKey, escape, tab, arrowUp, arrowDown, arrowLeft, arrowRight, controlU, backspace, optionBackspace

    func event(in window: NSWindow) throws -> NSEvent {
        let (characters, bare, flags, keyCode): (String, String, NSEvent.ModifierFlags, UInt16) =
            switch self {
            case .character(let typed): (typed, typed, [], 12)
            case .returnKey: ("\r", "\r", [], 36)
            case .escape: ("\u{1b}", "\u{1b}", [], 53)
            case .tab: ("\t", "\t", [], 48)
            case .arrowUp: ("\u{F700}", "\u{F700}", [.function, .numericPad], 126)
            case .arrowDown: ("\u{F701}", "\u{F701}", [.function, .numericPad], 125)
            case .arrowLeft: ("\u{F702}", "\u{F702}", [.function, .numericPad], 123)
            case .arrowRight: ("\u{F703}", "\u{F703}", [.function, .numericPad], 124)
            case .controlU: ("\u{15}", "u", .control, 32)
            case .backspace: ("\u{7f}", "\u{7f}", [], 51)
            case .optionBackspace: ("\u{7f}", "\u{7f}", .option, 51)
            }
        return try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: bare, isARepeat: false, keyCode: keyCode))
    }
}

@MainActor
func sendKeys(_ keys: [TypedKey], to controller: WindowController) throws {
    let interceptor = KeyInterceptor()
    interceptor.onKeyToFocus = { [unowned controller] in controller.keyReachedFocus($0) }
    for key in keys {
        if let routed = interceptor.route(try key.event(in: controller.window)) {
            controller.window.sendEvent(routed)
        }
    }
}

@MainActor
func sendKeys(typing text: String, to controller: WindowController) throws {
    try sendKeys(text.map { .character(String($0)) }, to: controller)
}
