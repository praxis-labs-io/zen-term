import XCTest

@testable import ZenTerm

final class DiffTreeTests: XCTestCase {
    private func fd(_ path: String) -> FileDiff {
        FileDiff(path: path, oldPath: nil, changeKind: .modified, hunks: [])
    }

    func test_build_groupsFilesUnderDirectories() {
        let nodes = DiffTree.build([fd("src/App.swift"), fd("src/Util.swift"), fd("README.md")])

        XCTAssertEqual(
            nodes,
            [
                .directory(name: "src", children: [.file(fd("src/App.swift")), .file(fd("src/Util.swift"))]),
                .file(fd("README.md")),
            ])
    }

    func test_build_dirsSortBeforeFiles() {
        let nodes = DiffTree.build([fd("z.txt"), fd("dir/a.txt")])

        XCTAssertEqual(
            nodes,
            [
                .directory(name: "dir", children: [.file(fd("dir/a.txt"))]),
                .file(fd("z.txt")),
            ])
    }

    func test_build_collapsesSingleChildDirectoryChain() {
        let nodes = DiffTree.build([fd("a/b/c/File.swift")])

        XCTAssertEqual(
            nodes,
            [.directory(name: "a/b/c", children: [.file(fd("a/b/c/File.swift"))])])
    }

    func test_build_doesNotCollapseWhenDirectoryHasSiblings() {
        let nodes = DiffTree.build([fd("a/b/One.swift"), fd("a/c/Two.swift")])

        XCTAssertEqual(
            nodes,
            [
                .directory(
                    name: "a",
                    children: [
                        .directory(name: "b", children: [.file(fd("a/b/One.swift"))]),
                        .directory(name: "c", children: [.file(fd("a/c/Two.swift"))]),
                    ])
            ])
    }

    func test_build_emptyInput_returnsEmpty() {
        XCTAssertTrue(DiffTree.build([]).isEmpty)
    }
}
