// Restores the process-wide config state between suites without ever reading the developer's own config.

import Foundation

@testable import ZenTerm

enum ConfigReset {
    static func toBuiltIn() {
        ConfigLoader.defaultRootOverrideForTesting = emptyRoot
        AppConfig.reload()
        ConfigLoader.defaultRootOverrideForTesting = nil
    }

    private static let emptyRoot: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zenterm-empty-config-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}
