import Foundation

enum TerminalKitResources {
    // Hand-kept because asking `Bundle.module` for it can `fatalError` in a packaged app.
    static let bundleName = "ZenTerm_TerminalKit"

    static let bundle: Bundle = Bundle.zenResourceBundle(named: bundleName, fallback: .module)

    // The no-op cursor shader an unfocused surface runs; nil leaves the surface shader-less.
    static var passthroughShaderPath: String? {
        bundle.url(forResource: "passthrough", withExtension: "glsl")?.path
    }
}
