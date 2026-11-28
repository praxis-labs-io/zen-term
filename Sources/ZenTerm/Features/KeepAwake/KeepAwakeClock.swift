import Foundation

protocol KeepAwakeClock: AnyObject {
    typealias Cancel = () -> Void

    var now: Date { get }
    func schedule(after seconds: TimeInterval, _ fire: @escaping () -> Void) -> Cancel
}
