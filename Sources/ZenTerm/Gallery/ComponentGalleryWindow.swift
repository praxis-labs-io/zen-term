#if DEBUG
    import AppKit

    @MainActor
    final class ComponentGalleryWindow: NSObject, NSWindowDelegate {
        static let shared = ComponentGalleryWindow()

        private enum LiveState: Int {
            case list, noMatches, rename
        }

        // ListPopover caps a card at 260pt; the open lists drop into this room instead of over the body.
        private static let listRoom: CGFloat = 272
        private static let inset: CGFloat = 24

        private let theme = GalleryTheme()
        private var window: NSWindow?
        private var themeEntries: [ThemeEntry] = []
        private var pickedThemeName: String?
        private var liveState = LiveState.list
        private var liveDropdown: Dropdown?
        private var liveCheckbox: CheckboxDropdown?
        private var renameChip: WorkspaceTabChip?
        private var observers: [NSObjectProtocol] = []

        func show() {
            let window = window ?? build()
            observe(window)
            rebuild()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        func windowWillClose(_ notification: Notification) {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            window?.makeFirstResponder(nil)
            theme.restore()
        }

        private func build() -> NSWindow {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 900),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false)
            window.title = "Component Gallery"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 900, height: 640)
            window.delegate = self
            window.center()
            self.window = window
            return window
        }

        private func observe(_ window: NSWindow) {
            guard observers.isEmpty else { return }
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: .configDidChange, object: nil, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.configDidReload() }
                },
                center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: nil) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.openLiveState() }
                },
            ]
        }

        private func configDidReload() {
            theme.configDidReload()
            pickedThemeName = nil
            rebuild()
        }

        private func rebuild() {
            guard let window else { return }
            window.makeFirstResponder(nil)
            window.backgroundColor = Theme.current.chrome.background.nsColor
            window.contentView = makeContent()
            DispatchQueue.main.async { [weak self] in self?.openLiveState() }
        }

        private func makeContent() -> NSView {
            let chrome = Theme.current.chrome
            let root = NSView()
            root.wantsLayer = true
            root.layer?.backgroundColor = chrome.background.nsColor.cgColor

            let pinned = makePinnedPane()
            let divider = NSView()
            divider.wantsLayer = true
            divider.layer?.backgroundColor = chrome.fill(alpha: ChromeTheme.hairline).cgColor
            divider.translatesAutoresizingMaskIntoConstraints = false
            let body = makeBody()

            for view in [body, divider, pinned] { root.addSubview(view) }
            NSLayoutConstraint.activate([
                pinned.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.inset),
                pinned.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.inset),
                pinned.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -Self.inset),
                divider.topAnchor.constraint(equalTo: pinned.bottomAnchor),
                divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                divider.heightAnchor.constraint(equalToConstant: 1),
                body.topAnchor.constraint(equalTo: divider.bottomAnchor),
                body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                body.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
            return root
        }

        private func makePinnedPane() -> NSView {
            let live = SegmentedControl(
                options: ["List", "No matches", "Rename"], selectedIndex: liveState.rawValue,
                notifiesOnReselect: true
            ) { [weak self] index in self?.selectLiveState(index) }
            let controls = NSStackView(views: [
                FieldCaption("Theme", required: false), makeThemeDropdown(),
                FieldCaption("Live state", required: false), live,
            ])
            controls.orientation = .horizontal
            controls.alignment = .centerY
            controls.spacing = 10
            controls.setCustomSpacing(Self.inset, after: controls.arrangedSubviews[1])

            let dropdown = GalleryPickers.liveDropdown()
            let checkbox = GalleryPickers.liveCheckboxDropdown()
            let chip = GalleryTabs.renameChip()
            liveDropdown = dropdown
            liveCheckbox = checkbox
            renameChip = chip
            let samples = NSStackView(views: [dropdown, checkbox, GalleryTabs.host(chip)])
            samples.orientation = .horizontal
            samples.alignment = .centerY
            samples.spacing = Self.inset

            let room = NSView()
            room.translatesAutoresizingMaskIntoConstraints = false
            room.heightAnchor.constraint(equalToConstant: Self.listRoom).isActive = true

            let pane = NSStackView(views: [controls, samples, room])
            pane.orientation = .vertical
            pane.alignment = .leading
            pane.spacing = 16
            pane.translatesAutoresizingMaskIntoConstraints = false
            return pane
        }

        private func makeThemeDropdown() -> Dropdown {
            themeEntries = ThemeCatalog.entries()
            let name = pickedThemeName ?? GeneralConfig.current.themeName ?? ThemeCatalog.defaultThemeName
            let selected = themeEntries.firstIndex { $0.name == name } ?? 0
            let items = themeEntries.enumerated().map { index, entry in
                DropdownItem(
                    title: entry.displayName,
                    group: entry.source == .user ? "Your themes" : "Bundled",
                    note: entry.isDark ? "Dark" : "Light",
                    isSelected: index == selected)
            }
            let dropdown = Dropdown(items: items, selectedIndex: selected) { [weak self] index in
                self?.pickTheme(index)
            }
            dropdown.widthAnchor.constraint(equalToConstant: GalleryPickers.width).isActive = true
            return dropdown
        }

        private func makeBody() -> NSView {
            let sections =
                GalleryButtons.sections() + GalleryFields.sections() + GalleryPickers.sections()
                + GalleryCards.sections() + GalleryTabs.sections()
            let stack = NSStackView(views: sections)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 40
            stack.translatesAutoresizingMaskIntoConstraints = false

            let document = FlippedView()
            document.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(stack)
            let scroll = FadingScrollView(document: document)
            NSLayoutConstraint.activate([
                document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                stack.topAnchor.constraint(equalTo: document.topAnchor, constant: Self.inset),
                stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Self.inset),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -Self.inset),
                stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -Self.inset),
            ])
            return scroll
        }

        private func pickTheme(_ index: Int) {
            guard themeEntries.indices.contains(index) else { return }
            let name = themeEntries[index].name
            pickedThemeName = name
            theme.apply(themeName: name)
            DispatchQueue.main.async { [weak self] in self?.rebuild() }
        }

        private func selectLiveState(_ index: Int) {
            liveState = LiveState(rawValue: index) ?? .list
            window?.makeFirstResponder(nil)
            DispatchQueue.main.async { [weak self] in self?.openLiveState() }
        }

        private func openLiveState() {
            guard let window, window.isVisible else { return }
            liveCheckbox?.openListForTesting()
            if liveState == .rename {
                renameChip?.beginRename()
                return
            }
            guard let dropdown = liveDropdown, !dropdown.isPopoverOpen else { return }
            dropdown.openListForTesting()
            if liveState == .noMatches {
                dropdown.typeForTesting("zzz")
            } else {
                dropdown.moveHighlightForTesting(1)
            }
        }
    }
#endif
