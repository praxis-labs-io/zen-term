import TabKit
import XCTest

@testable import ZenTerm

final class WorkspaceOrderTests: XCTestCase {
    private func workspace(_ raw: Int, host: SSHHostID? = nil) -> WorkspaceController {
        WorkspaceController(
            id: WorkspaceID(raw: raw), isConfigured: false, name: "Workspace \(raw)",
            folder: URL(fileURLWithPath: "/tmp/\(raw)"), firstTab: TabID(raw),
            connection: host.map { SSHConnection(host: $0) })
    }

    private func host(_ name: String, _ status: SSHHostStatus) -> WorkspaceOrder.Host {
        WorkspaceOrder.Host(id: SSHHostID(name: name), status: status)
    }

    private func ws(_ raw: Int) -> WorkspaceOrder.Target { .workspace(WorkspaceID(raw: raw)) }
    private func h(_ name: String) -> WorkspaceOrder.Target { .host(SSHHostID(name: name)) }

    func test_navigable_putsReachableHostsAfterWorkspaces_inConfigOrder() {
        let order = WorkspaceOrder(
            [workspace(1), workspace(2)],
            hosts: [host("live", .connected), host("down", .offline), host("up", .online)])

        XCTAssertEqual(order.navigable, [ws(1), ws(2), h("live"), h("up")])
    }

    func test_navigable_withEveryHostOffline_isTheWorkspaces() {
        let order = WorkspaceOrder([workspace(1)], hosts: [host("a", .offline), host("b", .offline)])

        XCTAssertEqual(order.navigable, [ws(1)])
    }

    func test_aHostsWorkspace_isNotAWorkspaceRow() {
        let order = WorkspaceOrder(
            [workspace(1), workspace(2, host: SSHHostID(name: "devbox"))], hosts: [host("devbox", .connected)])

        XCTAssertEqual(order.entries, [.workspace(WorkspaceID(raw: 1))])
        XCTAssertEqual(order.navigable, [ws(1), h("devbox")])
    }

    func test_aWorkspacesPosition_ignoresHosts() {
        let order = WorkspaceOrder([workspace(1), workspace(2)], hosts: [host("up", .online)])

        XCTAssertEqual(order.position(of: WorkspaceID(raw: 2)), 1)
        XCTAssertEqual(order.navigableWorkspaces, [WorkspaceID(raw: 1), WorkspaceID(raw: 2)])
    }

    func test_next_fromTheLastWorkspace_skipsOfflineHosts() {
        let order = WorkspaceOrder([workspace(1)], hosts: [host("down", .offline), host("up", .online)])

        XCTAssertEqual(order.stop(after: ws(1), 1), h("up"))
    }

    func test_next_fromTheLastHost_wrapsToTheFirstWorkspace() {
        let order = WorkspaceOrder([workspace(1)], hosts: [host("up", .online), host("down", .offline)])

        XCTAssertEqual(order.stop(after: h("up"), 1), ws(1))
    }

    func test_previous_fromTheFirstWorkspace_wrapsToTheLastReachableHost() {
        let order = WorkspaceOrder(
            [workspace(1), workspace(2)],
            hosts: [host("up", .online), host("live", .connected), host("down", .offline)])

        XCTAssertEqual(order.stop(after: ws(1), -1), h("live"))
    }

    func test_fromAnOfflineHost_stepsToTheNearestReachableStopInEachDirection() {
        let order = WorkspaceOrder(
            [workspace(1)],
            hosts: [host("before", .online), host("down", .offline), host("gone", .offline), host("after", .online)])

        XCTAssertEqual(order.stop(after: h("down"), 1), h("after"))
        XCTAssertEqual(order.stop(after: h("down"), -1), h("before"))
    }

    func test_fromAnOfflineHost_withNothingReachableAfterIt_wrapsToTheFirstWorkspace() {
        let order = WorkspaceOrder([workspace(1)], hosts: [host("down", .offline)])

        XCTAssertEqual(order.stop(after: h("down"), 1), ws(1))
        XCTAssertEqual(order.stop(after: h("down"), -1), ws(1))
    }

    func test_theOnlyStop_hasNoNeighbour() {
        let order = WorkspaceOrder([workspace(1)], hosts: [host("down", .offline)])

        XCTAssertNil(order.stop(after: ws(1), 1))
    }
}
