import Foundation

// One `[Title]` section of `~/.config/zen-term/workspaces`.
struct Workspace: Equatable {
    enum Region: String, CaseIterable { case main, right, bottom }

    struct Tab: Equatable {
        var name: String?
        var main: String?
        var right: String?
        var bottom: String?

        init(name: String? = nil, main: String? = nil, right: String? = nil, bottom: String? = nil) {
            self.name = name
            self.main = main
            self.right = right
            self.bottom = bottom
        }

        func command(in region: Region) -> String? {
            switch region {
            case .main: return main
            case .right: return right
            case .bottom: return bottom
            }
        }
    }

    struct LaunchFocus: Equatable {
        var tab: Int
        var region: Region

        static let start = LaunchFocus(tab: 0, region: .main)
    }

    let title: String
    let path: URL
    let tabs: [Tab]
    let focus: LaunchFocus
    let env: [String: String]
    let carry: [String]

    init(
        title: String, path: URL, tabs: [Tab], focus: LaunchFocus = .start, env: [String: String],
        carry: [String] = []
    ) {
        self.title = title
        self.path = path
        self.tabs = tabs.isEmpty ? [Tab()] : tabs
        self.focus = LaunchFocus(tab: min(max(focus.tab, 0), self.tabs.count - 1), region: focus.region)
        self.env = env
        self.carry = carry
    }
}
