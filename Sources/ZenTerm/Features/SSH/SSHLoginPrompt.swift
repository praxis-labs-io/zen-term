import Foundation

// What ssh asks a login through askpass, read from its prompt text, since ssh sends no kind for a question.
enum SSHLoginPrompt: Equatable {
    case hostKey(fingerprint: String?)
    case secret(label: String)

    private static let hostKeyMarks = [
        "(yes/no/[fingerprint])?", "Please type 'yes', 'no' or the fingerprint", "(yes/no)?",
        "Please type 'yes' or 'no'",
    ]

    static func parse(_ prompt: String) -> SSHLoginPrompt {
        if hostKeyMarks.contains(where: prompt.contains) { return .hostKey(fingerprint: fingerprint(in: prompt)) }
        return .secret(label: label(of: prompt))
    }

    private static func fingerprint(in prompt: String) -> String? {
        for line in prompt.split(whereSeparator: \.isNewline) {
            guard let mark = line.range(of: " key fingerprint is") else { continue }
            let type = line[..<mark.lowerBound].split(separator: " ").last.map(String.init)
            var value = line[mark.upperBound...].drop { $0 == ":" || $0 == " " }
            if value.hasSuffix(".") { value = value.dropLast() }
            guard !value.isEmpty else { continue }
            return [type, String(value)].compactMap { $0 }.joined(separator: " ")
        }
        return nil
    }

    private static func label(of prompt: String) -> String {
        var text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(":") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }
}
