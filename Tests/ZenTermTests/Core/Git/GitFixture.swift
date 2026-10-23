import Foundation
import XCTest

@testable import ZenTerm

enum GitFixture {
    @discardableResult
    static func makeRepoWithOrigin(under root: URL) throws -> URL {
        let origin = root.appendingPathComponent("origin.git", isDirectory: true)
        let work = try makeRepo(at: root.appendingPathComponent("work", isDirectory: true))
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        try run(["init", "--bare", "--initial-branch=main"], in: origin)
        try run(["remote", "add", "origin", origin.path], in: work)
        try run(["push", "-u", "origin", "main"], in: work)
        return work
    }

    @discardableResult
    static func makeRepo(at work: URL) throws -> URL {
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try run(["init", "--initial-branch=main"], in: work)
        try run(["config", "user.email", "test@example.com"], in: work)
        try run(["config", "user.name", "Test"], in: work)
        try write("one\n", to: work.appendingPathComponent("tracked.txt"))
        try write(".build/\n.env\n", to: work.appendingPathComponent(".gitignore"))
        try run(["add", "."], in: work)
        try run(["commit", "-m", "first"], in: work)
        return work
    }

    @discardableResult
    static func makeEmptyRepo(at dir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try run(["init", "--initial-branch=main"], in: dir)
        return dir
    }

    @discardableResult
    static func run(_ args: [String], in dir: URL) throws -> String {
        try GitCommand.run(args, in: dir).get()
    }

    static func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    static func branches(in repo: URL) throws -> [String] {
        let output = try run(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: repo)
        return output.split(separator: "\n").map(String.init).sorted()
    }
}
