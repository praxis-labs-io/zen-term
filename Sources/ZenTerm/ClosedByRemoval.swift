import Foundation

struct ClosedByRemoval: Equatable {
    var thisWindow = false
    var otherWindows = 0
    var workspaces: [String] = []
    var tabs = 0

    func adding(_ window: ClosedByRemoval, isThisWindow: Bool) -> ClosedByRemoval {
        var sum = self
        if window.thisWindow {
            if isThisWindow { sum.thisWindow = true } else { sum.otherWindows += 1 }
        } else {
            sum.workspaces += window.workspaces.filter { !sum.workspaces.contains($0) }
            sum.tabs += window.tabs
        }
        return sum
    }
}
