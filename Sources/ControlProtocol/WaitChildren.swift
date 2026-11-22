/// Which of the caller's children `pane.wait` answers on: the first with news, or once none is working.
public enum WaitChildren: String, Codable, Sendable, CaseIterable {
    case any, all
}
