import Foundation

/// A node in the file tree the diff viewer's left pane renders: either a directory (holding
/// child nodes) or a leaf file carrying its `FileDiff`.
enum DiffTreeNode: Equatable {
    case directory(name: String, children: [DiffTreeNode])
    case file(FileDiff)
}

/// Folds a flat `[FileDiff]` into a hierarchical tree. Directories sort before files at each
/// level, both alphabetically; a directory whose only child is another directory collapses
/// into a single `parent/child` node, so deep single-use paths don't waste vertical space.
enum DiffTree {
    static func build(_ files: [FileDiff]) -> [DiffTreeNode] {
        let root = MutableDir()
        for file in files {
            let segments = file.path.split(separator: "/").map(String.init)
            var dir = root
            for segment in segments.dropLast() {
                if let existing = dir.subdirs[segment] {
                    dir = existing
                } else {
                    let child = MutableDir()
                    dir.subdirs[segment] = child
                    dir = child
                }
            }
            dir.files.append(file)
        }
        return nodes(of: root)
    }

    private static func nodes(of dir: MutableDir) -> [DiffTreeNode] {
        var result: [DiffTreeNode] = []
        for (name, subdir) in dir.subdirs.sorted(by: { $0.key < $1.key }) {
            result.append(collapsed(name: name, dir: subdir))
        }
        for file in dir.files.sorted(by: { basename($0.path) < basename($1.path) }) {
            result.append(.file(file))
        }
        return result
    }

    /// A directory node with single-child directory chains folded into its name.
    private static func collapsed(name: String, dir: MutableDir) -> DiffTreeNode {
        var name = name
        var dir = dir
        while dir.files.isEmpty, dir.subdirs.count == 1, let (childName, child) = dir.subdirs.first {
            name += "/" + childName
            dir = child
        }
        return .directory(name: name, children: nodes(of: dir))
    }

    private static func basename(_ path: String) -> String {
        String(path.split(separator: "/").last ?? Substring(path))
    }

    /// A mutable scaffold used only while folding; converted to immutable `DiffTreeNode`s.
    private final class MutableDir {
        var subdirs: [String: MutableDir] = [:]
        var files: [FileDiff] = []
    }
}
