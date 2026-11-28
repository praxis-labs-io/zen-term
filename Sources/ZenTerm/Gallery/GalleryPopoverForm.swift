#if DEBUG
    import AppKit

    enum GalleryPopoverForm {
        static func section() -> GallerySection {
            GallerySection(
                title: "PopoverForm",
                rows: [
                    GallerySection.Row(label: "Off", samples: [form(isOn: false)]),
                    GallerySection.Row(label: "On, with status", samples: [form(isOn: true)]),
                    GallerySection.Row(label: "Live in a popover", samples: [LiveSample()]),
                ])
        }

        static let onStatus = "Awake until 3 working agents finish. The display can still sleep."

        static func rows(current: Int?, agentsWorking: Bool) -> [PopoverForm.ChecklistRow] {
            let titles: [(String, String?)] = [
                ("Until I turn it off", nil), ("Until agents finish", agentsWorking ? "3 working" : nil),
                ("For 30 minutes", nil), ("For 1 hour", nil), ("For 2 hours", nil),
            ]
            return titles.enumerated().map { index, row in
                PopoverForm.ChecklistRow(
                    title: row.0, note: row.1, isCurrent: index == current, isEnabled: index != 1 || agentsWorking)
            }
        }

        static func form(
            isOn: Bool, header: SegmentedControl? = nil, onChoose: @escaping (Int) -> Void = { _ in }
        ) -> PopoverForm {
            let header = header ?? SegmentedControl(options: ["Off", "On"], selectedIndex: isOn ? 1 : 0) { _ in }
            let scope = SegmentedControl(options: ["This Mac", "Mac and display"]) { _ in }
            return PopoverForm(
                header: PopoverForm.Header(symbol: "cup.and.saucer", title: "Keep Awake", control: header),
                status: isOn ? onStatus : nil,
                sections: [PopoverForm.Section(caption: "Keep awake", control: scope)],
                checklistCaption: "Until", rows: rows(current: isOn ? 1 : nil, agentsWorking: isOn),
                onChoose: onChoose)
        }

        private final class LiveSample: NSView {
            private lazy var button = AppButton(title: "Open", variant: .secondary) { [weak self] in self?.open() }
            private lazy var popover = ListPopover(anchor: button, anchorToggles: true)
            private lazy var onOff = SegmentedControl(options: ["Off", "On"]) { [weak self] in self?.setOn($0 == 1) }
            private var form: PopoverForm?
            private var isOn = false
            private var current: Int?

            init() {
                super.init(frame: .zero)
                translatesAutoresizingMaskIntoConstraints = false
                addSubview(button)
                NSLayoutConstraint.activate([
                    button.leadingAnchor.constraint(equalTo: leadingAnchor),
                    button.trailingAnchor.constraint(equalTo: trailingAnchor),
                    button.topAnchor.constraint(equalTo: topAnchor),
                    button.bottomAnchor.constraint(equalTo: bottomAnchor),
                ])
            }

            required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if window == nil { popover.close() }
            }

            private func open() {
                guard !popover.isOpen else { return popover.close() }
                let form = GalleryPopoverForm.form(isOn: isOn, header: onOff) { [weak self] in self?.choose($0) }
                self.form = form
                render()
                popover.open(content: form)
                form.takeFocus()
            }

            private func setOn(_ on: Bool) {
                isOn = on
                current = on ? current ?? 0 : nil
                render()
            }

            private func choose(_ index: Int) {
                isOn = true
                current = index
                onOff.setSelection(1)
                render()
            }

            private func render() {
                form?.render(
                    status: isOn ? GalleryPopoverForm.onStatus : nil,
                    rows: GalleryPopoverForm.rows(current: current, agentsWorking: true), in: popover)
            }
        }
    }
#endif
