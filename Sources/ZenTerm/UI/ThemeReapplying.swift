import AppKit

protocol ThemeReapplying: AnyObject {
    func reapplyTheme()
}
extension FieldBox: ThemeReapplying {}
extension TextAreaBox: ThemeReapplying {}
extension PopoverPicker: ThemeReapplying {}
extension AppButton: ThemeReapplying {}
