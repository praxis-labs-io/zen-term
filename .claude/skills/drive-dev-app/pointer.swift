import CoreGraphics
import Foundation

// pointer move|click|hold-key <x> <y> | hold-key <keycode> <count>
let args = CommandLine.arguments
func fail(_ m: String) -> Never { FileHandle.standardError.write((m + "\n").data(using: .utf8)!); exit(2) }
guard args.count == 4 else { fail("usage: pointer move|click <x> <y> | pointer repeat-key <code> <count>") }
let src = CGEventSource(stateID: .hidSystemState)
switch args[1] {
case "move", "click":
    guard let x = Double(args[2]), let y = Double(args[3]) else { fail("bad point") }
    let p = CGPoint(x: x, y: y)
    CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    if args[1] == "click" {
        usleep(120_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(60_000)
        CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
case "repeat-key":
    guard let code = UInt16(args[2]), let n = Int(args[3]), (1...40).contains(n),
        [123, 124, 125, 126].contains(code) else { fail("repeat-key takes an arrow key code and 1-40") }
    for i in 0..<n {
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)!
        if i > 0 { down.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        down.post(tap: .cghidEventTap)
        usleep(i == 0 ? 400_000 : 35_000)
    }
    CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)!.post(tap: .cghidEventTap)
default: fail("unknown verb")
}
