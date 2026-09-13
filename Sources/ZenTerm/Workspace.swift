import Foundation

// One `[Title]` section of `~/.config/zen-term/workspaces`.
struct Workspace: Equatable {
    enum Region: String { case main, right, bottom }

    let title: String
    let path: URL
    let main: String?
    let right: String?
    let bottom: String?
    let focus: Region
    let env: [String: String]
    let carry: [String]

    init(
        title: String, path: URL, main: String?, right: String?, bottom: String?,
        focus: Region, env: [String: String], carry: [String] = []
    ) {
        self.title = title
        self.path = path
        self.main = main
        self.right = right
        self.bottom = bottom
        self.focus = focus
        self.env = env
        self.carry = carry
    }
}
