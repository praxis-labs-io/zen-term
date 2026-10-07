import ControlProtocol
import XCTest

@testable import zen

final class ListTreeTests: XCTestCase {
    func test_aHostWorkspaceShowsItsAddressAndState_inPlaceOfAFolder() {
        let list = ListResult(windows: [
            .init(
                id: "w1", key: true,
                workspaces: [
                    .init(title: "app", folder: "/src/app", configured: true, worktree: nil, active: false, tabs: []),
                    .init(
                        title: "devbox", folder: nil, host: .init(alias: "devbox", state: .connecting),
                        configured: false, worktree: nil, active: true,
                        tabs: [
                            .init(
                                id: "w1.t4", title: "zsh", active: true,
                                panes: [.init(token: 9, drawer: nil, title: "", cwd: nil, busy: false, agent: nil)])
                        ]),
                ])
        ])

        XCTAssertEqual(
            ListTree.text(list),
            """
            w1  key
              app  /src/app  configured
              devbox  ssh:devbox connecting  active
                w1.t4  zsh  active
                  9
            """)
    }
}
