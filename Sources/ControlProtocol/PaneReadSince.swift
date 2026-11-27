/// Where `pane.read` starts: `task` is where the pane's last task or message sent with `enter` began.
public enum PaneReadSince: String, Codable, Sendable, CaseIterable {
    case task
}
