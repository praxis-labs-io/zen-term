import Foundation

/// A reference-typed node the `NSOutlineView` can hold by identity. `DiffTreeNode` is a value
/// enum, and an outline view keys its rows on object identity (expansion state, selection), so a
/// freshly-boxed value each call would break it. This wraps the tree once into stable objects.
final class DiffOutlineItem {
    enum Kind {
        case directory(String)
        case file(FileDiff)
    }
    let kind: Kind
    let children: [DiffOutlineItem]
    /// Cached at build so a scrolled-into-view row doesn't re-reduce the file's hunks each time it
    /// is rendered (the row view is reused, but `configure` still reads these).
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
        case .directory(let name): return name
        case .file(let file): return String(file.path.split(separator: "/").last ?? Substring(file.path))
        }
    }

    /// Build the outline's root items from a flat file list, folding through the shared `DiffTree`.
    static func roots(from files: [FileDiff]) -> [DiffOutlineItem] {
        DiffTree.build(files).map(DiffOutlineItem.init)
    }
}
