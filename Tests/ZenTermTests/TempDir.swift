import XCTest

extension XCTestCase {
    func tempDirPath() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-test-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func makeTempDir() throws -> URL {
        let dir = tempDirPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
