import Foundation

// What ssh asks a login through askpass, read from its prompt text, since ssh sends no kind for a question.
enum SSHLoginPrompt: Equatable {
    case hostKey(type: String?, fingerprint: String?)
    case secret(headline: String)

    private static let hostKeyMarks = [
        "(yes/no/[fingerprint])?", "Please type 'yes', 'no' or the fingerprint", "(yes/no)?",
        "Please type 'yes' or 'no'",
    ]
    private static let passphrase = #"^Enter passphrase for key '(.+)':?$"#
    private static let password = #"^\S+'s password:?$"#
    private static let barePassword = #"^Password:?$"#
    private static let serverPromptPrefix = #"^\([^()\s]+@[^()\s]+\) "#

    static func parse(_ prompt: String) -> SSHLoginPrompt {
        if hostKeyMarks.contains(where: prompt.contains) {
            let key = hostKey(in: prompt)
            return .hostKey(type: key?.type, fingerprint: key?.fingerprint)
        }
        return .secret(headline: headline(of: prompt))
    }

    var headline: String {
        switch self {
        case .secret(let headline): return headline
        case .hostKey(let type?, _): return "New \(type) host key"
        case .hostKey(nil, _): return "New host key"
        }
    }

    // A fingerprint is one unbreakable token, so it splits into two equal halves rather than leave a lone character.
    static func fingerprintLines(_ fingerprint: String) -> String {
        let first = fingerprint.prefix((fingerprint.count + 1) / 2)
        let second = fingerprint.dropFirst(first.count)
        return second.isEmpty ? String(first) : "\(first)\n\(second)"
    }

    private static func hostKey(in prompt: String) -> (type: String?, fingerprint: String)? {
        for line in prompt.split(whereSeparator: \.isNewline) {
            guard let mark = line.range(of: " key fingerprint is") else { continue }
            let type = line[..<mark.lowerBound].split(separator: " ").last.map(String.init)
            var value = line[mark.upperBound...].drop { $0 == ":" || $0 == " " }
            if value.hasSuffix(".") { value = value.dropLast() }
            guard !value.isEmpty else { continue }
            return (type, String(value))
        }
        return nil
    }

    private static func headline(of prompt: String) -> String {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = text.range(of: passphrase, options: .regularExpression) {
            let quoted = text[match].drop { $0 != "'" }.dropFirst().prefix { $0 != "'" }
            return "Enter the passphrase for \(URL(fileURLWithPath: String(quoted)).lastPathComponent)"
        }
        if text.range(of: password, options: .regularExpression) != nil { return "Enter your password" }
        let asked = text.replacingOccurrences(of: serverPromptPrefix, with: "", options: .regularExpression)
        if asked.range(of: barePassword, options: [.regularExpression, .caseInsensitive]) != nil {
            return "Enter your password"
        }
        return asked
    }
}
