import Foundation

// One `ssh-host` line: the alias ssh connects with, and the name ZenTerm shows in its place.
struct SSHHostEntry: Equatable {
    let alias: String
    var name: String?

    init(alias: String, name: String? = nil) {
        self.alias = alias
        self.name = name
    }

    init?(configValue value: String) {
        let separator = value.indices.first { index in
            let next = value.index(after: index)
            return value[index] == ":" && (next == value.endIndex || value[next].isWhitespace)
        }
        let alias = (separator.map { value[..<$0] } ?? Substring(value)).trimmingCharacters(in: .whitespaces)
        guard !alias.isEmpty, !alias.hasPrefix("-"), !alias.contains(where: \.isWhitespace) else { return nil }
        let name = separator.map {
            ConfigText.unquote(value[value.index(after: $0)...].trimmingCharacters(in: .whitespaces))
        }
        self.init(alias: alias, name: name.flatMap { $0.isEmpty ? nil : $0 })
    }

    var displayName: String { name ?? alias }

    var configValue: String {
        guard let name else { return alias }
        return "\(alias): \(name.contains("#") ? "\"\(name)\"" : name)"
    }
}
