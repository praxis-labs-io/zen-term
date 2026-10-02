import ControlProtocol

/// What every pane and drawer shell is launched with on top of its workspace's environment.
enum PaneEnvironment {
    static func variables(base: [String: String], token: Int) -> [String: String] {
        var variables = NavSocketServer.env(token: token)
        variables[ControlEndpoint.environmentKey] = ControlServer.socketPath
        return base.merging(variables) { _, new in new }
    }
}
