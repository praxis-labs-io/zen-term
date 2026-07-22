import Foundation

/// The bundled custom-shader catalog. Shaders ship as `Shaders/<token>.glsl` app resources, and a
/// `custom-shader = <token>` config line selects one by name. Bundled-only by design: only vetted,
/// tested shaders are selectable, so an un-vetted file can't black the window or tank the GPU.
enum ShaderCatalog {
    /// The vetted catalog, in picker order. Each token has a `Shaders/<token>.glsl` resource.
    static let bundled: [(token: String, displayName: String)] = [
        ("cursor_warp", "Cursor Warp"),
        ("cursor_tail", "Cursor Tail"),
    ]

    /// The bundled shader's file URL for a config token, or nil when no such shader ships.
    static func bundledURL(for token: String) -> URL? {
        ZenTermResources.bundle.url(forResource: token, withExtension: "glsl", subdirectory: "Shaders")
    }

    /// Display name for a catalog token, or the token itself when it isn't in the catalog.
    static func displayName(for token: String) -> String {
        bundled.first { $0.token == token }?.displayName ?? token
    }
}
