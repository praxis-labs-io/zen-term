import AppKit

extension NSView {
    func reapplyThemeTree() {
        var views: [NSView] = []
        collectViewTree(into: &views)
        for view in views where view === self || view.isDescendant(of: self) {
            (view as? ThemeReapplying)?.reapplyTheme()
        }
    }

    private func collectViewTree(into views: inout [NSView]) {
        views.append(self)
        for subview in subviews { subview.collectViewTree(into: &views) }
    }
}
