import Foundation

protocol PowerAssertions: AnyObject {
    func hold(keepingDisplayOn: Bool)
    func release()
}
