import Foundation

extension Bundle {
    /// Resolve a SwiftPM resource bundle (`<Package>_<Target>.bundle`) the way a
    /// packaged, signed `.app` needs, which the generated `Bundle.module` accessor
    /// does not.
    ///
    /// For a statically-linked executable target, SwiftPM emits the "executable"
    /// flavor of the accessor: it looks only at `Bundle.main.bundleURL/<name>.bundle`
    /// — the `.app` *root*, where codesign refuses to seal loose content, so nothing
    /// can live — and a build-machine-absolute `.build` path. A shipped app finds
    /// neither and `fatalError`s on first access; v0.1.1 only launched on the build
    /// machine, whose `.build` path happened to exist, and SIGTRAP'd for every
    /// downloader.
    ///
    /// The bundle actually ships in `Contents/Resources`, which is `Bundle.main`'s
    /// `resourceURL`; a bare `swift build` puts it beside the binary, also
    /// `resourceURL`/`bundleURL`. Check those, then defer to the caller's
    /// `Bundle.module`, which still resolves under `swift test`. `fallback` is an
    /// `@autoclosure` so `Bundle.module` is evaluated (and can `fatalError`) only if
    /// both real locations miss — which never happens in a packaged app.
    ///
    /// `name` is `<PackageName>_<TargetName>`, matching what `Bundle.module` hardcodes
    /// and what `bin/package-app`'s `EXPECTED_BUNDLES` asserts; a rename breaks that
    /// assertion loudly rather than reaching a user.
    public static func zenResourceBundle(named name: String, fallback: @autoclosure () -> Bundle)
        -> Bundle
    {
        zenResourceBundle(
            named: name,
            searchRoots: [Bundle.main.resourceURL, Bundle.main.bundleURL],
            fallback: fallback())
    }

    /// The `searchRoots` seam exists so the packaged-app resolution path is
    /// directly testable: under `swift test`, `Bundle.main` is the xctest host, so
    /// the public entry point's real roots always miss and `fallback` (`.module`)
    /// silently rescues — a broken probe order or wrong subpath would ship green.
    /// Tests drive this overload with fixture roots to exercise the primary path.
    static func zenResourceBundle(
        named name: String, searchRoots: [URL?], fallback: @autoclosure () -> Bundle
    ) -> Bundle {
        for root in searchRoots {
            if let url = root?.appendingPathComponent("\(name).bundle"),
                let bundle = Bundle(url: url)
            {
                return bundle
            }
        }
        return fallback()
    }
}
