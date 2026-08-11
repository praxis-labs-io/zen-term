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
    /// A value name for this row that survives the rebuild every changed load does, so the
    /// folds and the selection can be put back on the new objects: the section title plus the row's
    /// path, `\u{1}`-separated the way `FileDiff.highlightKey` is. Section-qualified for the same reason
    /// that key carries scope — one path can sit in two slices at once (changed in the working tree
    /// *and* since the base), and those are two rows, not one.
    ///
    /// Directories name themselves by their folded path, which is not perfectly stable: `DiffTree`
    /// folds single-child chains into one `a/b` node, so a load that gives `a` a second child splits
    /// that row into `a` > `b` and mints new identities. A row the viewer can't match comes back at its
    /// default (expanded), which is what a row it has never seen should look like.
    let identity: String

    init(node: DiffTreeNode, section: String, parentPath: String) {
        switch node {
        case .directory(let name, let nodes):
            kind = .directory(name)
            let path = parentPath.isEmpty ? name : parentPath + "/" + name
            identity = "\(section)\u{1}\(path)"
            children = nodes.map { DiffOutlineItem(node: $0, section: section, parentPath: path) }
        case .file(let file):
            kind = .file(file)
            // The file's own repo-relative path, not the accumulated one: it says the same thing and
            // can't be re-folded out from under the row.
            identity = "\(section)\u{1}\(file.path)"
            children = []
        }
    }

    private init(kind: Kind, children: [DiffOutlineItem], identity: String) {
        self.kind = kind
        self.children = children
        self.identity = identity
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

    /// Added/removed line totals for the subtree rooted here — a file's own counts, or the sum across
    /// descendants for a section or directory. Derived from the hunks each time, so a section header's
    /// badge can never drift from the lines under it.
    var addedCount: Int {
        if let file = fileDiff { return file.addedCount }
        return children.reduce(0) { $0 + $1.addedCount }
    }
    var removedCount: Int {
        if let file = fileDiff { return file.removedCount }
        return children.reduce(0) { $0 + $1.removedCount }
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
            let children = DiffTree.build(files).map {
                DiffOutlineItem(node: $0, section: title, parentPath: "")
            }
            roots.append(DiffOutlineItem(kind: .section(title: title), children: children, identity: title))
        }
        add("Unstaged", status.unstaged)
        add("Staged", status.staged)
        add("Committed", status.committed)
        return roots
    }
}
