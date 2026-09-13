import Foundation

extension Bundle {
    /// Finds `name`.bundle in `Contents/Resources` or the app root, evaluating `fallback` only if both miss.
    public static func zenResourceBundle(named name: String, fallback: @autoclosure () -> Bundle)
        -> Bundle
    {
        zenResourceBundle(
            named: name,
            searchRoots: [Bundle.main.resourceURL, Bundle.main.bundleURL],
            fallback: fallback())
    }

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
