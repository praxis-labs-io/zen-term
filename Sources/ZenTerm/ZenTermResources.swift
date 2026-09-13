import Foundation
import TerminalKit

enum ZenTermResources {
    /// Hand-maintained: asking `Bundle.module` for its name can `fatalError` in a packaged app.
    static let bundleName = "ZenTerm_ZenTerm"

    static let bundle: Bundle = Bundle.zenResourceBundle(named: bundleName, fallback: .module)
}
