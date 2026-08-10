import Foundation

extension Bundle {
    /// Resolve a SwiftPM resource bundle the way a packaged, signed `.app` needs, which the
    /// generated `Bundle.module` accessor does not.
    ///
    /// For a statically-linked executable target, SwiftPM's accessor looks only at the `.app`
    /// *root*, where codesign refuses to seal loose content, and at a build-machine-absolute
    /// `.build` path. A shipped app finds neither and `fatalError`s on first access, which is how
    /// a release once launched only on the build machine and trapped for every downloader.
    ///
    /// The bundle actually ships in `Contents/Resources`. `fallback` is an `@autoclosure` so
    /// `Bundle.module` is evaluated, and can `fatalError`, only if both real locations miss.
    ///
    /// `name` is `<PackageName>_<TargetName>`, which `bin/package-app` asserts, so a rename breaks
    /// the build rather than reaching a user.
    public static func zenResourceBundle(named name: String, fallback: @autoclosure () -> Bundle)
        -> Bundle
    {
        zenResourceBundle(
            named: name,
            searchRoots: [Bundle.main.resourceURL, Bundle.main.bundleURL],
            fallback: fallback())
    }

    /// `searchRoots` exists so the packaged-app path is testable: under `swift test`,
    /// `Bundle.main` is the xctest host, so the real roots always miss and `fallback` silently
    /// rescues, which would let a broken probe order ship green.
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
