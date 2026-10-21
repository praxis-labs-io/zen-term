import AppKit
import TabKit

final class TerminalTabChip: TabChip {
    let id: TabID
    private var tabIndex: Int
    private let onClick: () -> Void
    private let onClose: () -> Void
    private let onDoubleClick: () -> Void
    private let directory: () -> URL?
    private var isFirstClickOfPair = false
    private lazy var tooltip = TooltipHost(label: "") { [weak self] in
        guard let self, self.tabIndex <= 9 else { return nil }
        return CommandCatalog.spec(for: .selectTab(self.tabIndex)).shortcut
    }

    var tooltipLabelForTesting: String? { directoryLabel }
    var tooltipShortcutForTesting: String? { tooltip.shortcutForTesting }

    static func closesOn(mouseButton number: Int) -> Bool { number == 2 }

    init(
        id: TabID, index: Int, onClick: @escaping () -> Void, onClose: @escaping () -> Void,
        onDoubleClick: @escaping () -> Void, directory: @escaping () -> URL?
    ) {
        self.id = id
        tabIndex = index
        self.onClick = onClick
        self.onClose = onClose
        self.onDoubleClick = onDoubleClick
        self.directory = directory
        super.init(closeLabel: "Close tab")
        onCloseButton = { [weak self] in self?.onClose() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(index: Int, title: String, isCurrent: Bool, dotColor: NSColor?) {
        tabIndex = index
        apply(title: title, isCurrent: isCurrent, isClosable: true, dotColor: dotColor)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { tooltip.hide(from: self) }
    }

    override func hoverDidChange() {
        guard isHovered, let path = directoryLabel else { return tooltip.hide(from: self) }
        tooltip.label = path
        tooltip.show(from: self)
    }

    private var directoryLabel: String? { directory().map { PathDisplay.abbreviatingHome($0.path) } }

    override func mouseDown(with event: NSEvent) {
        tooltip.hide(from: self)
        if event.clickCount == 2, isFirstClickOfPair {
            isFirstClickOfPair = false
            onDoubleClick()
        } else {
            isFirstClickOfPair = event.clickCount == 1
            onClick()
        }
    }

    override func otherMouseDown(with event: NSEvent) {
        if Self.closesOn(mouseButton: event.buttonNumber) { onClose() }
    }
}
