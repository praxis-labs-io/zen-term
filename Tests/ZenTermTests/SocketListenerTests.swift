import ControlProtocol
import XCTest

@testable import ZenTerm

final class SocketListenerTests: XCTestCase {
    func test_socketFileIsOwnerOnly() throws {
        let path = "/tmp/zt-listener-mode-\(getpid()).sock"
        let listener = SocketListener(prefix: "test.", path: path, name: "Test", category: .app) { close($0) }
        XCTAssertTrue(listener.start())
        defer { listener.stop() }

        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode, 0o600)
    }

    func test_createsAMissingDirectoryOwnerOnly() throws {
        let directory = "/tmp/zt-listener-dir-\(getpid())"
        try? FileManager.default.removeItem(atPath: directory)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let listener = SocketListener(
            prefix: "test.", path: directory + "/s.sock", name: "Test", category: .app
        ) { close($0) }
        XCTAssertTrue(listener.start())
        defer { listener.stop() }

        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: directory)[.posixPermissions] as? Int)
        XCTAssertEqual(mode, 0o700)
    }

    func test_admitsAPeerRunningAsTheOwner() throws {
        let path = "/tmp/zt-listener-own-\(getpid()).sock"
        let accepted = expectation(description: "accepted")
        let listener = SocketListener(prefix: "test.", path: path, name: "Test", category: .app) { conn in
            close(conn)
            accepted.fulfill()
        }
        listener.start()
        defer { listener.stop() }

        let fd = try UnixSocket.connect(to: path)
        defer { close(fd) }
        wait(for: [accepted], timeout: 3)
    }

    func test_refusesAPeerRunningAsAnotherUser() throws {
        let path = "/tmp/zt-listener-uid-\(getpid()).sock"
        let accepted = expectation(description: "never accepted")
        accepted.isInverted = true
        let listener = SocketListener(
            prefix: "test.", path: path, name: "Test", category: .app, ownerUID: geteuid() &+ 1
        ) { conn in
            close(conn)
            accepted.fulfill()
        }
        listener.start()
        defer { listener.stop() }

        let fd = try UnixSocket.connect(to: path)
        defer { close(fd) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var byte: UInt8 = 0
        XCTAssertEqual(read(fd, &byte, 1), 0, "the refused connection was not closed (errno \(errno))")
        wait(for: [accepted], timeout: 0.2)
    }

    func test_finalPathAppearsOnlyOnceListening() throws {
        let path = "/tmp/zt-listener-late-\(getpid()).sock"
        let bindingPath = SocketListener.bindingPath(for: path)
        try FileManager.default.createDirectory(atPath: bindingPath, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: bindingPath) }
        let listener = SocketListener(prefix: "test.", path: path, name: "Test", category: .app) { close($0) }
        defer { listener.stop() }

        XCTAssertFalse(listener.start())
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func test_sweep_removesOnlyBindingsWhosePidIsGone() throws {
        let dir = NSTemporaryDirectory() + "zt-listener-sweep-\(getpid())"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sibling = "\(dir)/test.\(getppid()).bind"
        let crashed = "\(dir)/test.\(Self.unassignablePid).bind"
        for path in [sibling, crashed] {
            FileManager.default.createFile(atPath: path, contents: nil)
        }

        SocketListener.sweepStaleSockets(prefix: "test.", in: dir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling))
        XCTAssertFalse(FileManager.default.fileExists(atPath: crashed))
    }

    private static let unassignablePid: pid_t = 99999  // xnu's PID_MAX: pids wrap one short of it
}
