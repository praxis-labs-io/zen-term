import Foundation

/// Builds the child-process environment by layering overrides over a base.
public enum EnvBuilder {
    public static func merged(base: [String], overrides: [String: String]) -> [String] {
        guard !overrides.isEmpty else { return base }

        var remaining = overrides
        var result: [String] = []
        result.reserveCapacity(base.count + overrides.count)

        for entry in base {
            let key = String(entry.prefix { $0 != "=" })
            if let value = remaining.removeValue(forKey: key) {
                result.append("\(key)=\(value)")
            } else {
                result.append(entry)
            }
        }
        for (key, value) in remaining.sorted(by: { $0.key < $1.key }) {
            result.append("\(key)=\(value)")
        }
        return result
    }
}
