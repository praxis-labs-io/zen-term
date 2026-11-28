import AppKit

// One window's Keep Awake surfaces: the footer indicator, its popover, and the collapsed sidebar's dot.
@MainActor
final class KeepAwakeMenu {
    static let choices: [(title: String, until: KeepAwake.Until)] = [
        ("Until I turn it off", .turnedOff), ("Until agents finish", .agentsFinish),
        ("For 30 minutes", .duration(30 * 60)), ("For 1 hour", .duration(60 * 60)),
        ("For 2 hours", .duration(2 * 60 * 60)),
    ]
    private static let agentsRow = 1

    private let keepAwake: KeepAwake
    private let indicator: KeepAwakeIndicator
    private let clock: KeepAwakeClock
    private let onRefused: (KeepAwake.Refusal) -> Void
    private let onActivityChanged: (IconButton.Activity?) -> Void
    private lazy var popover: ListPopover = {
        let popover = ListPopover(anchor: indicator, anchorToggles: true)
        popover.onSelfClose = { [weak self] in self?.didClose() }
        return popover
    }()
    private var form: PopoverForm?
    private var toggle: ToggleSwitch?
    private var scope: SegmentedControl?
    private var observer: NSObjectProtocol?
    var onOpenChanged: (Bool) -> Void = { _ in }
    private var cancelTick: KeepAwakeClock.Cancel?

    init(
        keepAwake: KeepAwake, indicator: KeepAwakeIndicator, clock: KeepAwakeClock,
        onRefused: @escaping (KeepAwake.Refusal) -> Void,
        onActivityChanged: @escaping (IconButton.Activity?) -> Void
    ) {
        self.keepAwake = keepAwake
        self.indicator = indicator
        self.clock = clock
        self.onRefused = onRefused
        self.onActivityChanged = onActivityChanged
        indicator.onClick = { [weak self] in self?.togglePopover() }
        observer = NotificationCenter.default.addObserver(
            forName: .keepAwakeDidChange, object: keepAwake, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func shutdown() {
        onOpenChanged = { _ in }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        cancelTick?()
        cancelTick = nil
        close()
    }

    var isOpen: Bool { popover.isOpen }

    func togglePopover() {
        guard !popover.isOpen else { return close() }
        let toggle = ToggleSwitch(isOn: keepAwake.isOn) { [weak self] in self?.flip($0) }
        let scope = SegmentedControl(options: ["This Mac", "Mac and display"]) { [weak self] in
            self?.chooseDisplay($0 == 1)
        }
        let form = PopoverForm(
            header: PopoverForm.Header(symbol: KeepAwakeIndicator.cupSymbol, title: "Keep Awake", control: toggle),
            status: status(now: clock.now), sections: [PopoverForm.Section(caption: "Keep awake", control: scope)],
            checklistCaption: "Until", rows: rows()
        ) { [weak self] in self?.choose($0) }
        self.toggle = toggle
        self.scope = scope
        self.form = form
        syncControls()
        popover.open(content: form)
        guard popover.isOpen else { return didClose() }
        if !keepAwake.isOn, keepAwake.activeCount > 0 { form.highlightedRow = Self.agentsRow }
        form.takeFocus()
        indicator.isActive = true
        onOpenChanged(true)
    }

    var formForTesting: PopoverForm? { form }
    var toggleForTesting: ToggleSwitch? { toggle }
    var scopeForTesting: SegmentedControl? { scope }

    func close() {
        popover.close()
        didClose()
    }

    private func didClose() {
        let wasOpen = form != nil && indicator.isActive
        form = nil
        toggle = nil
        scope = nil
        indicator.isActive = false
        if wasOpen { onOpenChanged(false) }
    }

    private func flip(_ on: Bool) {
        if on {
            start(nil)
        } else {
            keepAwake.turnOff()
        }
        refresh()
    }

    private func choose(_ index: Int) {
        start(Self.choices[index].until)
        refresh()
    }

    private func chooseDisplay(_ display: Bool) {
        keepAwake.setKeepsDisplayOn(display)
        refresh()
    }

    private func start(_ until: KeepAwake.Until?) {
        if let refusal = keepAwake.start(until) { onRefused(refusal) }
    }

    private func refresh() {
        let now = clock.now
        let hold = keepAwake.hold
        let isOn = keepAwake.isOn
        let isBatteryLow = isOn && KeepAwakeSummary.isBatteryLow(keepAwake.battery, stop: keepAwake.batteryStop)
        let detail =
            hold.map { KeepAwakeSummary.footerDetail(hold: $0, activeCount: keepAwake.activeCount, now: now) }
            ?? KeepAwakeSummary.paneDetail(count: keepAwake.paneHolds.count)
        indicator.render(
            KeepAwakeIndicator.Content(
                isOn: isOn, keepsDisplayOn: keepAwake.holdsDisplay, detail: detail, isBatteryLow: isBatteryLow))
        onActivityChanged(isOn ? isBatteryLow ? .warning : .live : nil)
        scheduleTick(hold: hold, now: now)
        guard let form, popover.isOpen else { return }
        syncControls()
        form.render(status: status(now: now), rows: rows(), in: popover)
    }

    private func scheduleTick(hold: KeepAwake.Hold?, now: Date) {
        cancelTick?()
        cancelTick = nil
        guard let hold, let delay = KeepAwakeSummary.nextChange(hold: hold, now: now) else { return }
        cancelTick = clock.schedule(after: delay) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func syncControls() {
        toggle?.setOn(keepAwake.isOn)
        scope?.setSelection(
            keepAwake.keepsDisplayOn ? 1 : 0)
        form?.setHeaderAccented(keepAwake.isOn)
    }

    private func status(now: Date) -> String? {
        let panes = keepAwake.holdingPanes
        guard let hold = keepAwake.hold else { return KeepAwakeSummary.panesSentence(panes, alone: true) }
        let own = KeepAwakeSummary.sentence(
            hold: hold, keepsDisplayOn: keepAwake.keepsDisplayOn, activeCount: keepAwake.activeCount, now: now)
        return ([own] + [KeepAwakeSummary.panesSentence(panes, alone: false)].compactMap { $0 }).joined(separator: " ")
    }

    private func rows() -> [PopoverForm.ChecklistRow] {
        let working = keepAwake.activeCount
        let current = keepAwake.hold?.until
        return Self.choices.enumerated().map { index, choice in
            let isAgents = index == Self.agentsRow
            return PopoverForm.ChecklistRow(
                title: choice.title, note: isAgents && working > 0 ? "\(working) working" : nil,
                isCurrent: choice.until == current, isEnabled: !isAgents || working > 0)
        }
    }
}
