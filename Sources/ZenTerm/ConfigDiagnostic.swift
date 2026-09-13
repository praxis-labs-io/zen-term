/// Stores facts, not phrasing: keybind diagnostics are built while `GeneralConfig.current` still holds the old config.
struct ConfigDiagnostic: Hashable {
    enum Scope: Hashable {
        case keybind(KeyInterceptor.ReservedChord)
        case setting(key: String)
        case toolFloat(label: String)
        case toolFloatField(id: String, label: String)
        case keybindLine
    }

    enum Problem: Hashable {
        case chordTaken(Chord, by: KeyInterceptor.ReservedChord)
        case menuBind(Chord, menuItem: String?)
        case floatMenuKey(Chord, menuItem: String?)
        case unusableBind(Chord)
        case invalidValue(got: String, expected: String)
        case ignoredListItem(got: String, expected: String)
        case clamped(value: String, to: String)
        case floatMissingField(String)
        case floatUnusableKey(String)
        case floatReservedID(String)
        case floatFieldInvalid(field: String, got: String, using: String)
        case floatFieldClamped(field: String, got: String, to: String)
        case unparseableLine(String)
    }

    var scope: Scope
    var problem: Problem

    var isChordConflict: Bool {
        if case .chordTaken = problem { return true }
        return false
    }

    private static func owner(_ menuItem: String?) -> String {
        menuItem.map { "the \($0)" } ?? "a"
    }

    private var keybindActionToken: String {
        if case .keybind(let action) = scope { return action.actionToken }
        return ""
    }

    var title: String {
        switch scope {
        case .keybind(let action): return CommandCatalog.spec(for: action).title
        case .setting(let key): return key
        case .toolFloat(let label): return label
        case .toolFloatField(_, let label): return label
        case .keybindLine: return "Shortcut"
        }
    }

    var headline: String {
        switch problem {
        case .chordTaken: return "\(title) has no shortcut"
        case .menuBind, .floatMenuKey: return title
        case .unusableBind: return "\(title) has an unusable shortcut"
        case .invalidValue: return "\(title) has an invalid value"
        case .ignoredListItem: return "\(title) has an invalid item"
        case .clamped: return "\(title) is out of range"
        case .floatMissingField, .floatUnusableKey, .floatReservedID:
            return "A tool float was ignored"
        case .floatFieldInvalid, .floatFieldClamped: return "\(title) has an invalid setting"
        case .unparseableLine: return "A shortcut line was ignored"
        }
    }

    var message: String {
        switch problem {
        case .chordTaken(let chord, let winner):
            return "\(chord.displayGlyph) goes to \(winner.actionToken)."
        case .menuBind(let chord, let menuItem):
            return "\(keybindActionToken)=\(chord.configToken) is \(Self.owner(menuItem)) menu shortcut. Ignoring it."
        case .floatMenuKey(let chord, let menuItem):
            return "key:\(chord.configToken) is \(Self.owner(menuItem)) menu shortcut. Ignoring it."
        case .unusableBind(let chord):
            return "\(keybindActionToken)=\(chord.configToken) can't be typed on your keyboard. Ignoring it."
        case .invalidValue(let got, let expected):
            return "\(title) = \(got) isn't valid (\(expected)). Using the default."
        case .ignoredListItem(let got, let expected):
            return "\(title): \(got) isn't valid (\(expected)). Ignoring it; the rest still applies."
        case .clamped(let value, let to):
            return "\(title) = \(value) is out of range. Using \(to)."
        case .floatMissingField(let field):
            return "\(title) is missing \(field). Ignoring this tool float."
        case .floatUnusableKey(let key):
            return "\(title) has an unusable key: \(key). Ignoring this tool float."
        case .floatReservedID(let id):
            return "\(title) takes the name \(id), which ZenTerm's built-in Scratch float owns. "
                + "Rename it. Ignoring this tool float."
        case .floatFieldInvalid(let field, let got, let using):
            return "\(title): \(field)\(got) isn't valid. Using \(using)."
        case .floatFieldClamped(let field, let got, let to):
            return "\(title): \(field)\(got) is out of range. Using \(to)."
        case .unparseableLine(let raw):
            return "Couldn't read this line in your config: `keybind = \(raw)`. Ignoring it."
        }
    }

    /// Terse because it has to fit `ToastView.messageMaxWidth`.
    var detail: String {
        switch problem {
        case .chordTaken(let chord, let winner):
            return "\(chord.displayGlyph) → \(winner.actionToken)"
        case .menuBind(let chord, let menuItem), .floatMenuKey(let chord, let menuItem):
            return "\(chord.configToken) → \(menuItem ?? "the menu")"
        case .unusableBind(let chord):
            return "\(chord.configToken) can't be typed"
        case .invalidValue(let got, _):
            return "\(got) isn't valid"
        case .ignoredListItem(let got, _):
            return "\(got) ignored"
        case .clamped(let value, let to):
            return "\(value) → \(to)"
        case .floatMissingField(let field):
            return "missing \(field)"
        case .floatUnusableKey:
            return "key can't be typed"
        case .floatReservedID(let id):
            return "\(id) is reserved"
        case .floatFieldInvalid(let field, let got, _):
            return "\(field)\(got) isn't valid"
        case .floatFieldClamped(let field, let got, let to):
            return "\(field)\(got) → \(to)"
        case .unparseableLine:
            return "couldn't be read"
        }
    }

    /// Two lines because a long title plus its detail overruns the 236pt toast column.
    var summary: String { "\(title)\n  \(detail)" }

    /// Compared as a set: `ConfigWriter` sorts the lines it emits, so any Settings write can reorder them.
    static func announcement(
        for diagnostics: [ConfigDiagnostic], alreadyAnnounced: [ConfigDiagnostic]
    ) -> ToastContent? {
        guard Set(diagnostics) != Set(alreadyAnnounced) else { return nil }
        return toast(for: diagnostics)
    }

    static func toast(for diagnostics: [ConfigDiagnostic]) -> ToastContent? {
        guard !diagnostics.isEmpty else { return nil }
        if diagnostics.count == 1, let only = diagnostics.first {
            return ToastContent(variant: .warning, title: only.headline, message: only.message)
        }
        return ToastContent(
            variant: .warning, title: "\(diagnostics.count) problems in your config",
            message: diagnostics.map(\.summary).joined(separator: "\n\n"))
    }
}
