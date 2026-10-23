import AppKit
import TerminalKit

enum ScrollKeymap {
    enum Command: Equatable {
        case scroll(TerminalScroll)
        case step(Int)
        case paragraph(Int, times: Int)
        case column(Int)
        case word(ScrollWordMotion.Motion, wide: Bool, times: Int)
        case lineStart
        case lineEnd
        case firstNonBlank
        case viewportRow(ViewportPlace, offset: Int)
        case searchWordUnderCursor
        case yankRow(times: Int)
        case find(Find, times: Int)
        case repeatFind(reversed: Bool, times: Int)
        case pendingYank
        case pendingFind(Find.Target)
        case visual(ScrollSelection.Kind)
        case yank
        case pendingTop
        case cancel
        case exit
    }

    enum ViewportPlace: Equatable { case top, middle, bottom }

    struct Find: Equatable {
        enum Direction: Equatable { case forward, backward }
        var direction: Direction
        var till: Bool
        var character: Character

        var reversed: Find {
            Find(
                direction: direction == .forward ? .backward : .forward, till: till,
                character: character)
        }

        struct Target: Equatable {
            var direction: Direction
            var till: Bool

            func find(_ character: Character) -> Find {
                Find(direction: direction, till: till, character: character)
            }
        }
    }

    enum Key: Equatable {
        case run(Command)
        case count(Int)
    }

    struct Pending: Equatable {
        var afterG = false
        var afterY = false
        var awaitingFind: Find.Target?
        var count: Int?

        var times: Int { max(count ?? 1, 1) }

        static let maximumCount = 9999

        mutating func append(digit: Int) {
            let next = (count ?? 0) * 10 + digit
            count = min(next, Self.maximumCount)
        }
    }

    /// Shift comes from the modifier flags, never the character's case: Caps Lock would break `g` and `j`.
    static func key(for event: NSEvent, pending: Pending, hasSelection: Bool = false)
        -> Key?
    {
        let held = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if held == .control {
            let pages = Double(pending.times)
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "d": return .run(.scroll(.pageFraction(0.5 * pages)))
            case "u": return .run(.scroll(.pageFraction(-0.5 * pages)))
            case "f": return .run(.scroll(.pageFraction(pages)))
            case "b": return .run(.scroll(.pageFraction(-pages)))
            default: return nil
            }
        }
        guard held.isSubset(of: .shift) else { return nil }
        if event.keyCode == escapeKeyCode {
            return pending.awaitingFind == nil ? .run(.cancel) : nil
        }
        if let target = pending.awaitingFind {
            guard let character = event.characters?.first else { return nil }
            return .run(.find(target.find(character), times: pending.times))
        }
        let times = pending.times
        switch event.characters {
        case "{": return .run(.paragraph(-1, times: times))
        case "}": return .run(.paragraph(1, times: times))
        case "$": return .run(.lineEnd)
        case "^": return .run(.firstNonBlank)
        case "*": return .run(.searchWordUnderCursor)
        default: break
        }
        let shift = held.contains(.shift)
        switch (event.charactersIgnoringModifiers?.lowercased() ?? "", shift) {
        case ("j", false), (downArrow, false): return .run(.step(times))
        case ("k", false), (upArrow, false): return .run(.step(-times))
        case ("h", false), (leftArrow, false): return .run(.column(-times))
        case ("l", false), (rightArrow, false): return .run(.column(times))
        case ("w", false): return .run(.word(.next, wide: false, times: times))
        case ("b", false): return .run(.word(.back, wide: false, times: times))
        case ("e", false): return .run(.word(.end, wide: false, times: times))
        case ("w", true): return .run(.word(.next, wide: true, times: times))
        case ("b", true): return .run(.word(.back, wide: true, times: times))
        case ("e", true): return .run(.word(.end, wide: true, times: times))
        case ("h", true): return .run(.viewportRow(.top, offset: times - 1))
        case ("m", true): return .run(.viewportRow(.middle, offset: 0))
        case ("l", true): return .run(.viewportRow(.bottom, offset: times - 1))
        case ("0", false): return pending.count == nil ? .run(.lineStart) : .count(0)
        case ("1"..."9", false): return digit(event).map(Key.count)
        case ("v", false): return .run(.visual(.character))
        case ("v", true): return .run(.visual(.line))
        case ("y", false) where hasSelection: return .run(.yank)
        case ("y", false) where pending.afterY: return .run(.yankRow(times: times))
        case ("y", false): return .run(.pendingYank)
        case (" ", false): return .run(.scroll(.pageFraction(Double(times))))
        case ("g", false): return .run(pending.afterG ? .scroll(.top) : .pendingTop)
        case ("g", true): return .run(.scroll(.bottom))
        case ("f", false): return .run(.pendingFind(.init(direction: .forward, till: false)))
        case ("f", true): return .run(.pendingFind(.init(direction: .backward, till: false)))
        case ("t", false): return .run(.pendingFind(.init(direction: .forward, till: true)))
        case ("t", true): return .run(.pendingFind(.init(direction: .backward, till: true)))
        case (";", false): return .run(.repeatFind(reversed: false, times: times))
        case (",", false): return .run(.repeatFind(reversed: true, times: times))
        case ("q", false), ("i", false): return .run(.exit)
        default: return nil
        }
    }

    private static func digit(_ event: NSEvent) -> Int? {
        event.charactersIgnoringModifiers.flatMap(Int.init)
    }

    private static let escapeKeyCode: UInt16 = 53
    /// Arrow keys arrive as private-use scalars in `charactersIgnoringModifiers`.
    private static let upArrow = String(UnicodeScalar(NSUpArrowFunctionKey)!)
    private static let downArrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)
    private static let leftArrow = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    private static let rightArrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)
}
