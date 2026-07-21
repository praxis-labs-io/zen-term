import Foundation

/// A reference-typed node the `NSOutlineView` can hold by identity. `DiffTreeNode` is a value enum,
/// and an outline view keys its rows on object identity (expansion state, selection), so a
/// freshly-boxed value each call would break it. This wraps the tree once into stable objects.
///
/// The diff viewer's tree is three top-level `section` nodes (Unstaged / Staged / Committed), each
/// holding a folded file tree of `directory` and `file` nodes.
final class DiffOutlineItem {
    enum Kind {
        case section(title: String, subtitle: String?)
        case directory(String)
        case file(FileDiff)
    }
    let kind: Kind
    let children: [DiffOutlineItem]
    /// Cached at build so a scrolled-into-view row doesn't re-reduce the file's hunks each time it is
    /// rendered (the row view is reused, but `configure` still reads these).
    let addedCount: Int
    let removedCount: Int

    init(node: DiffTreeNode) {
        switch node {
        case .directory(let name, let nodes):
            kind = .directory(name)
            children = nodes.map(DiffOutlineItem.init)
            addedCount = 0
            removedCount = 0
        case .file(let file):
            kind = .file(file)
            children = []
            addedCount = file.addedCount
            removedCount = file.removedCount
        }
    }

    private init(section title: String, subtitle: String?, children: [DiffOutlineItem]) {
        kind = .section(title: title, subtitle: subtitle)
        self.children = children
        addedCount = 0
        removedCount = 0
    }

    var isSection: Bool {
        if case .section = kind { return true }
        return false
    }

    var isDirectory: Bool {
        if case .directory = kind { return true }
        return false
    }

    var fileDiff: FileDiff? {
        if case .file(let file) = kind { return file }
        return nil
    }

    var displayName: String {
        switch kind {
        case .section(let title, _): return title
        case .directory(let name): return name
        case .file(let file): return String(file.path.split(separator: "/").last ?? Substring(file.path))
        }
    }

    var sectionSubtitle: String? {
        if case .section(_, let subtitle) = kind { return subtitle }
        return nil
    }

    /// The three section roots for a status, skipping any slice with no changes. The committed
    /// section carries the fork base as its subtitle so the base is visible without a header.
    static func sections(from status: GitDiffRunner.StatusLoad) -> [DiffOutlineItem] {
        var roots: [DiffOutlineItem] = []
        func add(_ title: String, _ files: [FileDiff], subtitle: String? = nil) {
            guard !files.isEmpty else { return }
            let children = DiffTree.build(files).map(DiffOutlineItem.init)
            roots.append(DiffOutlineItem(section: title, subtitle: subtitle, children: children))
        }
        add("Unstaged", status.unstaged)
        add("Staged", status.staged)
        let base = status.baseBranch.map { branch in
            status.baseSHA.map { "\(branch) \($0)" } ?? branch
        }
        add("Committed", status.committed, subtitle: base)
        return roots
    }
}
