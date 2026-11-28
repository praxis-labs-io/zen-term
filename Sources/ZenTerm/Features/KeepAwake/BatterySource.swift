import Foundation

protocol BatterySource: AnyObject {
    var reading: BatteryReading? { get }
    var onChange: (() -> Void)? { get set }
}
