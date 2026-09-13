import Foundation

extension WorktreeRemovalRollup.Row {
    var listRow: ConfirmCardList.Row {
        switch self {
        case .file(let file):
            let slash = file.path.lastIndex(of: "/").map { file.path.index(after: $0) } ?? file.path.startIndex
            let folder = String(file.path[..<slash])
            let name = String(file.path[slash...])
            let glyphs = file.categories.map { ConfirmCardList.Run(text: $0.glyph, tone: .role($0.role)) }
            return .entry(
                path: [.init(text: folder, tone: .ink(.muted)), .init(text: name, tone: .ink(.subtle))],
                status: [glyphs])
        case .folder(let path, let files):
            let counts = GitStatusCategory.allCases.compactMap { category -> [ConfirmCardList.Run]? in
                let count = files.filter { $0.categories.contains(category) }.count
                guard count > 0 else { return nil }
                return [.init(text: "\(category.glyph)\(count)", tone: .role(category.role))]
            }
            return .entry(path: [.init(text: "\(path)/", tone: .ink(.subtle))], status: counts)
        case .more(let hiddenFiles):
            return .note("and \(hiddenFiles) more")
        }
    }
}
