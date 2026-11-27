import AgentSetup
import AppKit

// One agent's Settings rows: setup on or off, and an Update row shown only while an update would change something.
@MainActor
final class SetupRows<Agent: SetupAgent> {
    let setupKey: String
    let updateKey: String
    private weak var section: SettingsFormSection?
    private weak var setupControl: SegmentedControl?
    private weak var updateButton: AppButton?
    private var state: SetupState = .notInstalled

    init(setupKey: String, updateKey: String) {
        self.setupKey = setupKey
        self.updateKey = updateKey
    }

    func add(to section: SettingsFormSection, caption: String, description: String, updateCaption: String) {
        self.section = section
        let control = SegmentedControl(options: ["On", "Off"], selectedIndex: 1, notifiesOnReselect: true) {
            [weak self] index in
            self?.apply(index == 0 ? .install : .remove)
        }
        control.isEnabled = false
        setupControl = control
        section.addCustomRow(
            key: setupKey, caption: caption, description: description, control: control, focusStop: control,
            width: nil, refresh: {})
        let update = AppButton(title: "Update", variant: .muted)
        update.isKeyboardFocusable = true
        update.onTap = { [weak self] in self?.apply(.install) }
        updateButton = update
        section.addCustomRow(
            key: updateKey, caption: updateCaption, description: "", control: update, focusStop: update,
            width: nil, refresh: { [weak self] in self?.showUpdate() })
        showUpdate()
        Agent.refresh { [weak self] in self?.show($0) }
    }

    private func showUpdate() {
        let description = Self.updateDescription(for: state)
        let row = section?.rowFor(updateKey)
        row?.setDescription(description ?? "")
        row?.isHidden = description == nil
        updateButton?.isHidden = description == nil
    }

    private func apply(_ change: SetupChange) {
        setupControl?.isEnabled = false
        updateButton?.isEnabled = false
        Agent.refresh(applying: change) { [weak self] in self?.show($0) }
    }

    private func show(_ result: Result<SetupState, SetupError>) {
        let row = section?.rowFor(setupKey)
        switch result {
        case .success(let state):
            self.state = state
            row?.showMessage(nil)
        case .failure(let error):
            row?.showMessage(error.message)
        }
        setupControl?.setSelection(state == .notInstalled ? 1 : 0)
        setupControl?.isEnabled = true
        updateButton?.isEnabled = true
        showUpdate()
    }

    private static func updateDescription(for state: SetupState) -> String? {
        switch state {
        case .outdated: "An older version is installed."
        case .edited: "Your zen setup has changes, and updating replaces them."
        case .notInstalled, .newer, .current: nil
        }
    }
}
