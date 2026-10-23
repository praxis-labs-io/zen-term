import Foundation

/// Bundled-only, so an unvetted shader cannot black the window or tank the GPU.
enum ShaderCatalog {
    static let bundled: [(token: String, displayName: String)] = [
        ("cursor_warp", "Cursor Warp"),
        ("cursor_tail", "Cursor Tail"),
    ]

    static func bundledURL(for token: String) -> URL? {
        ZenTermResources.bundle.url(forResource: token, withExtension: "glsl", subdirectory: "Shaders")
    }

    static func displayName(for token: String) -> String {
        bundled.first { $0.token == token }?.displayName ?? token
    }
}
