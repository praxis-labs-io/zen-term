import Foundation

/// A reference-typed node the `NSOutlineView` can hold by identity. `DiffTreeNode` is a value enum,
/// and an outline view keys its rows on object identity (expansion state, selection), so a
/// freshly-boxed value each call would break it. This wraps the tree once into stable objects.
///
/// The diff viewer's tree is three top-level `section` nodes (Unstaged / Staged / Committed), each
/// holding a folded file tree of `directory` and `file` nodes. The committed slice's fork base is not
/// in the tree: it's a dropdown in the static header above the tree (`DiffViewerOverlay`).
final class DiffOutlineItem {
    enum Kind {
        case section(title: String)
        case directory(String)
        case file(FileDiff)
    }
    let kind: Kind
    let children: [DiffOutlineItem]

    init(node: DiffTreeNode) {
        switch node {
        case .directory(let name, let nodes):
            kind = .directory(name)
            children = nodes.map(DiffOutlineItem.init)
        case .file(let file):
            kind = .file(file)
            children = []
        }
    }

    private init(kind: Kind, children: [DiffOutlineItem]) {
        self.kind = kind
        self.children = children
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
        case .section(let title): return title
        case .directory(let name): return name
        case .file(let file): return String(file.path.split(separator: "/").last ?? Substring(file.path))
        }
    }

    /// The section roots for a status, skipping any slice with no changes.
    static func sections(from status: GitDiffRunner.StatusLoad) -> [DiffOutlineItem] {
        var roots: [DiffOutlineItem] = []
        func add(_ title: String, _ files: [FileDiff]) {
            guard !files.isEmpty else { return }
            let children = DiffTree.build(files).map(DiffOutlineItem.init)
            roots.append(DiffOutlineItem(kind: .section(title: title), children: children))
        }
        add("Unstaged", status.unstaged)
        add("Staged", status.staged)
        add("Committed", status.committed)
        return roots
    }
}
