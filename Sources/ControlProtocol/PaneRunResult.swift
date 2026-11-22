/// The pane `pane.run` opened, and how its first task went. `firstTask` is absent when there was no task.
public struct PaneRunResult: ControlPayload, Equatable {
    public let pane: Int
    public let firstTask: FirstTask?

    public init(pane: Int, firstTask: FirstTask?) {
        self.pane = pane
        self.firstTask = firstTask
    }

    private enum CodingKeys: String, CodingKey {
        case pane
        case firstTask = "first_task"
    }
}
