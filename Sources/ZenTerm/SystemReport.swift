import Foundation

/// App and OS metadata for a bug report: the one source both the exported diagnostics `metadata.txt`
/// and ZEN-212's issue body read, so the zip's header and a filed issue can never disagree about what
/// was reported.
///
/// The memberwise `init` takes fixed strings so `plainText` is unit-testable without touching the
/// running system; `current()` gathers the live values (and so isn't unit-tested).
struct SystemReport: Equatable {
    let appVersion: String  // "0.3.0" / "0.0.0+src" (no leading v)
    let build: String?  // CFBundleVersion; nil under `swift run`
    let osVersion: String  // "15.5 (24F74)"
    let architecture: String  // "arm64" / "x86_64"

    /// The rendered block shared by `metadata.txt` and the issue body. `build` is dropped when nil,
    /// mirroring the About panel: there's no honest fallback for a build number, and an empty one
    /// renders as a bare "(build )".
    var plainText: String {
        let version = build.map { "v\(appVersion) (build \($0))" } ?? "v\(appVersion)"
        return """
            - ZenTerm: \(version)
            - macOS: \(osVersion)
            - Architecture: \(architecture)
            """
    }

    /// Live values from the running app. `build`, like `showAbout`, is nil under `swift run`.
    static func current() -> SystemReport {
        SystemReport(
            appVersion: AppVersion.current,
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
            osVersion: liveOSVersion(),
            architecture: machineArchitecture())
    }

    /// "15.5 (24F74)" — the marketing version plus the OS build, parsed out of
    /// `operatingSystemVersionString` ("Version 15.5 (Build 24F74)"). The patch component is kept
    /// only when non-zero, so a ".0" point release reads "15.5", not "15.5.0".
    private static func liveOSVersion() -> String {
        let process = ProcessInfo.processInfo
        let version = process.operatingSystemVersion
        let semantic =
            version.patchVersion > 0
            ? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            : "\(version.majorVersion).\(version.minorVersion)"
        let full = process.operatingSystemVersionString
        guard let build = full.range(of: "Build "),
            let close = full.range(of: ")", range: build.upperBound..<full.endIndex)
        else { return semantic }
        return "\(semantic) (\(full[build.upperBound..<close.lowerBound]))"
    }

    /// The process architecture from `uname` ("arm64" on Apple Silicon, "x86_64" under Rosetta) — the
    /// binary that actually ran, which is what a bug report needs.
    private static func machineArchitecture() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        let size = MemoryLayout.size(ofValue: info.machine)
        return withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: size) { String(cString: $0) }
        }
    }
}
