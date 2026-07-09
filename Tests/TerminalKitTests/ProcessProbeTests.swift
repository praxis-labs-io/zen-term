import Foundation
import XCTest

@testable import TerminalKit

final class ProcessProbeTests: XCTestCase {
    func test_nonPositivePid_isNotBusy() {
        XCTAssertFalse(ProcessProbe.hasChildren(0))
        XCTAssertFalse(ProcessProbe.hasChildren(-1))
    }

    func test_processWithLiveChild_hasChildren() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }
        let selfPid = ProcessInfo.processInfo.processIdentifier
        XCTAssertTrue(ProcessProbe.hasChildren(selfPid))
    }

    func test_leafChildProcess_hasNoChildrenOfItsOwn() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { child.terminate() }
        XCTAssertFalse(ProcessProbe.hasChildren(child.processIdentifier))
    }
}
