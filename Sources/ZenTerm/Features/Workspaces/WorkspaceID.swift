/// Names one workspace for its window's lifetime. Minted per window, like `TabID`.
struct WorkspaceID: Hashable {
    let raw: Int
}
