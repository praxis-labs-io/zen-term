import AppKit

protocol ThemeReapplying: AnyObject {
    func reapplyTheme()
}
extension FieldBox: ThemeReapplying {}
extension TextAreaBox: ThemeReapplying {}
extension Dropdown: ThemeReapplying {}
extension AppButton: ThemeReapplying {}
extension CheckboxDropdown: ThemeReapplying {}
