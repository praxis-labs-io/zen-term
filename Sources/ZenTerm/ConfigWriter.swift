import CoreGraphics
import Foundation

enum ConfigWriter {
    static func apply(
        scalars: [String: String] = [:],
        removals: Set<String> = [],
        keybinds: KeymapOverrides? = nil,
        floatUpserts: [ToolFloat] = [],
        floatRemovals: Set<String> = [],
        configRoot: URL = ConfigLoader.defaultRoot
    ) throws {
        try FileManager.default.createDirectory(at: configRoot, withIntermediateDirectories: true)
        let url = configRoot.appendingPathComponent("config")
        let existing = try ConfigFileIO.readExistingOrEmpty(url)

        var lines = splitLines(existing)
        for (key, value) in scalars { setScalar(key, value, in: &lines) }
        for key in removals { removeScalar(key, in: &lines) }
        if let keybinds { applyKeybinds(keybinds, to: &lines) }
        if !floatUpserts.isEmpty || !floatRemovals.isEmpty {
            applyFloats(upserts: floatUpserts, removals: floatRemovals, in: &lines)
        }

        var output = lines.joined(separator: "\n")
        if !output.isEmpty { output += "\n" }
        try ConfigFileIO.writePreservingSymlink(output, to: url)
    }

    private static func splitLines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var body = text
        if body.hasSuffix("\n") { body.removeLast() }
        return body.components(separatedBy: "\n")
    }

    private static func setScalar(_ key: String, _ value: String, in lines: inout [String]) {
        let rendered = "\(key) = \(value)"
        if let index = lines.firstIndex(where: { activeAssignmentKey($0) == key }) {
            if let comment = ConfigText.trailingComment(of: lines[index]) {
                lines[index] = "\(rendered)  \(comment)"
            } else {
                lines[index] = rendered
            }
            return
        }
        if let index = lines.firstIndex(where: { commentedAssignmentKey($0) == key }) {
            lines.insert(rendered, at: index + 1)
            return
        }
        lines.append(rendered)
    }

    private static func removeScalar(_ key: String, in lines: inout [String]) {
        lines.removeAll { activeAssignmentKey($0) == key }
    }

    /// Diffs per action: the assembler drops all of an action's defaults once any user line names it.
    private static func applyKeybinds(_ keybinds: KeymapOverrides, to lines: inout [String]) {
        let floatBinds = lines.filter(isFloatKeybindLine)

        let rebinds =
            keybinds.binds
            .filter { _, action in keybinds.chords(of: action) != chords(of: action, in: KeymapDefaults.map) }
            .map { chord, action in "keybind = \(action.actionToken)=\(chord.configToken)" }
        let unbinds = keybinds.unbound.map { "keybind = \($0.actionToken)=none" }
        let block = floatBinds + (rebinds + unbinds).sorted()

        var result: [String] = []
        var inserted = false
        for line in lines {
            if isKeybindLine(line) {
                if !inserted {
                    result.append(contentsOf: block)
                    inserted = true
                }
                continue
            }
            result.append(line)
        }
        if !inserted, !block.isEmpty {
            if let headerIndex = result.firstIndex(where: { $0.contains("─── Keybinds") }) {
                result.insert(contentsOf: block, at: headerIndex + 1)
            } else {
                if let last = result.last, !last.isEmpty { result.append("") }
                result.append(contentsOf: block)
            }
        }
        lines = result
    }

    private static func chords(
        of action: KeyInterceptor.ReservedChord, in map: [Chord: KeyInterceptor.ReservedChord]
    ) -> Set<Chord> {
        Set(map.filter { $0.value == action }.map(\.key))
    }

    private static func isKeybindLine(_ line: String) -> Bool { activeAssignmentKey(line) == "keybind" }

    /// Excludes Scratch, which the per-action diff already writes, or its line would duplicate.
    private static func isFloatKeybindLine(_ line: String) -> Bool {
        guard isKeybindLine(line), let equals = line.firstIndex(of: "=") else { return false }
        let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("toggle_float:") else { return false }
        let id = value.dropFirst("toggle_float:".count).prefix { $0 != "=" }
            .trimmingCharacters(in: .whitespaces)
        return !ToolFloat.isBuiltIn(id)
    }

    static func serializeFloat(_ float: ToolFloat) -> String {
        var tokens = [
            "order:\(float.order)", "title:\(quotedValue(float.title))",
            "key:\(float.toggle.configToken)",
        ]
        if float.icon != ToolFloatParser.defaultIcon { tokens.append("icon:\(quotedValue(float.icon))") }
        tokens.append("command:\(quotedValue(float.command))")
        if let dir = float.dir { tokens.append("dir:\(quotedValue(PathDisplay.abbreviatingHome(dir.path)))") }
        if float.widthFraction != ToolFloatParser.defaultFraction {
            tokens.append("width:\(ToolFloatParser.fractionText(float.widthFraction))")
        }
        if float.heightFraction != ToolFloatParser.defaultFraction {
            tokens.append("height:\(ToolFloatParser.fractionText(float.heightFraction))")
        }
        if float.requiresGitRepo { tokens.append("git:true") }
        if float.persist != ToolFloatParser.defaultPersist { tokens.append("persist:\(float.persist.rawValue)") }
        if !float.showsInToolbar { tokens.append("toolbar:false") }
        return "float = " + tokens.joined(separator: " ")
    }

    /// Stamps every float so a config with no `order:` fields becomes a contiguous sequence.
    static func applyFloatOrder(_ floats: [ToolFloat], configRoot: URL = ConfigLoader.defaultRoot) throws {
        let resequenced = floats.enumerated().map { index, float -> ToolFloat in
            var float = float
            float.order = index + 1
            return float
        }
        try apply(floatUpserts: resequenced, configRoot: configRoot)
    }

    /// Inserts into a removal's vacated slot so a rename keeps its dock position.
    private static func applyFloats(upserts: [ToolFloat], removals: Set<String>, in lines: inout [String]) {
        var vacated: Int?
        if !removals.isEmpty {
            vacated = lines.firstIndex { floatID(of: $0).map(removals.contains) ?? false }
            lines.removeAll { floatID(of: $0).map(removals.contains) ?? false }
        }
        for float in upserts {
            let rendered = serializeFloat(float)
            if let index = lines.firstIndex(where: { floatID(of: $0) == float.id }) {
                if let comment = ConfigText.trailingComment(of: lines[index]) {
                    lines[index] = "\(rendered)  \(comment)"
                } else {
                    lines[index] = rendered
                }
            } else if let slot = vacated, slot <= lines.count {
                lines.insert(rendered, at: slot)
                vacated = nil
            } else if let lastFloat = lines.lastIndex(where: { floatID(of: $0) != nil }) {
                lines.insert(rendered, at: lastFloat + 1)
            } else {
                lines.append(rendered)
            }
        }
    }

    private static func floatID(of line: String) -> String? {
        guard activeAssignmentKey(line) == "float", let equals = line.firstIndex(of: "=") else { return nil }
        let value = ConfigText.stripComment(String(line[line.index(after: equals)...]))
        return ToolFloatParser.identity(fields: ToolFloatParser.fields(value))
    }

    private static func quotedValue(_ value: String) -> String {
        let needsQuoting = value.contains("#") || value.contains(where: \.isWhitespace)
        return needsQuoting ? "\"\(value)\"" : value
    }

    static func activeAssignmentKey(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { return nil }
        return key
    }

    private static func commentedAssignmentKey(_ line: String) -> String? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        trimmed.removeFirst()
        trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        guard let equals = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { return nil }
        return key
    }

}
