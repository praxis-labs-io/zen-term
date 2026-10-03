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
        WorkspaceOrder.Host(id: SSHHostID(alias: name), status: status)
    }

    private func ws(_ raw: Int) -> WorkspaceOrder.Target { .workspace(WorkspaceID(raw: raw)) }
    private func h(_ name: String) -> WorkspaceOrder.Target { .host(SSHHostID(alias: name)) }

    func test_navigable_putsConnectedHostsAfterWorkspaces_inConfigOrder() {
        let order = WorkspaceOrder(
            [workspace(1), workspace(2)],
            hosts: [
                host("live", .connected), host("down", .offline), host("up", .online), host("also", .connected),
            ])

        XCTAssertEqual(order.navigable, [ws(1), ws(2), h("live"), h("also")])
    }

    func test_navigable_withNoHostConnected_isTheWorkspaces() {
        let order = WorkspaceOrder([workspace(1)], hosts: [host("a", .offline), host("b", .online)])

        XCTAssertEqual(order.navigable, [ws(1)])
    }

    func test_aHostsWorkspace_isNotAWorkspaceRow() {
        let order = WorkspaceOrder(
            [workspace(1), workspace(2, host: SSHHostID(alias: "devbox"))], hosts: [host("devbox", .connected)])

        XCTAssertEqual(order.entries, [.workspace(WorkspaceID(raw: 1))])
        XCTAssertEqual(order.navigable, [ws(1), h("devbox")])
    }

    func test_aWorkspacesPosition_ignoresHosts() {
        let order = WorkspaceOrder([workspace(1), workspace(2)], hosts: [host("up", .online)])

        XCTAssertEqual(order.position(of: WorkspaceID(raw: 2)), 1)
        XCTAssertEqual(order.navigableWorkspaces, [WorkspaceID(raw: 1), WorkspaceID(raw: 2)])
    }

    func test_next_fromTheLastWorkspace_skipsHostsThatAreNotConnected() {
        let order = WorkspaceOrder(
            [workspace(1)], hosts: [host("down", .offline), host("up", .online), host("live", .connected)])

        XCTAssertEqual(order.stop(after: ws(1), 1), h("live"))
    }

    func test_next_fromTheLastHost_wrapsToTheFirstWorkspace() {
        let order = WorkspaceOrder([workspace(1)], hosts: [host("live", .connected), host("up", .online)])

        XCTAssertEqual(order.stop(after: h("live"), 1), ws(1))
    }

    func test_previous_fromTheFirstWorkspace_wrapsToTheLastConnectedHost() {
        let order = WorkspaceOrder(
            [workspace(1), workspace(2)],
            hosts: [host("live", .connected), host("up", .online), host("down", .offline)])

        XCTAssertEqual(order.stop(after: ws(1), -1), h("live"))
    }

    func test_fromAHostThatIsNotConnected_stepsToTheNearestStopInEachDirection() {
        let order = WorkspaceOrder(
            [workspace(1)],
            hosts: [
                host("before", .connected), host("down", .offline), host("up", .online), host("after", .connected),
            ])

        for current in [h("down"), h("up")] {
            XCTAssertEqual(order.stop(after: current, 1), h("after"))
            XCTAssertEqual(order.stop(after: current, -1), h("before"))
        }
    }

    func test_fromAHostThatIsNotConnected_withNoConnectedHost_wrapsToTheFirstWorkspace() {
        let order = WorkspaceOrder([workspace(1)], hosts: [host("up", .online), host("down", .offline)])

        for current in [h("up"), h("down")] {
            XCTAssertEqual(order.stop(after: current, 1), ws(1))
            XCTAssertEqual(order.stop(after: current, -1), ws(1))
        }
    }

    func test_theOnlyStop_hasNoNeighbour() {
        let order = WorkspaceOrder([workspace(1)], hosts: [host("up", .online), host("down", .offline)])

        XCTAssertNil(order.stop(after: ws(1), 1))
    }
}
