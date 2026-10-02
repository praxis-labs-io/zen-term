import XCTest

@testable import zen

final class SocketOptionPositionTests: XCTestCase {
    private func listSocket(_ arguments: [String]) throws -> String? {
        let list = try XCTUnwrap(try Zen.parseAsRoot(arguments) as? Zen.List)
        return list.connection.socket
    }

    private func helloSocket(_ arguments: [String]) throws -> String? {
        let hello = try XCTUnwrap(try Zen.parseAsRoot(arguments) as? Zen.Hello)
        return hello.connection.socket
    }

    func test_theSocketBeforeTheSubcommandIsUsed() throws {
        XCTAssertEqual(try listSocket(["--socket", "/a.sock", "list"]), "/a.sock")
        XCTAssertEqual(try helloSocket(["--socket", "/a.sock", "hello"]), "/a.sock")
    }

    func test_theSocketAfterTheSubcommandIsUsed() throws {
        XCTAssertEqual(try listSocket(["list", "--socket", "/b.sock", "--pretty"]), "/b.sock")
        XCTAssertEqual(try helloSocket(["hello", "--socket", "/b.sock"]), "/b.sock")
    }

    func test_givenInBothPlaces_theSubcommandsWins() throws {
        XCTAssertEqual(try listSocket(["--socket", "/a.sock", "list", "--socket", "/b.sock"]), "/b.sock")
    }

    func test_givenNowhere_thereIsNone() throws {
        XCTAssertNil(try listSocket(["list"]))
    }

    func test_aDeadSocketBeforeTheSubcommandIsNoInstance() {
        XCTAssertEqual(Zen.exitCode(running: ["--socket", "/tmp/zt-nothing-\(getpid()).sock", "list"]), 3)
    }
}
