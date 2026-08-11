import Foundation

/// App and OS metadata for a bug report: the one source both the exported diagnostics `metadata.txt`
/// and the issue body read, so the zip's header and a filed issue can never disagree about what
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

    /// "15.5 (24F74)" — the marketing version (from the numeric `operatingSystemVersion`, so no
    /// locale parsing) plus the OS build. The patch component is kept only when non-zero, so a ".0"
    /// point release reads "15.5", not "15.5.0"; the build is dropped if `sysctl` can't supply it.
    private static func liveOSVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let semantic =
            version.patchVersion > 0
            ? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            : "\(version.majorVersion).\(version.minorVersion)"
        guard let build = osBuild() else { return semantic }
        return "\(semantic) (\(build))"
    }

    /// The OS build ("24F74") from `sysctl kern.osversion`. `operatingSystemVersionString` carries
    /// the same build but is localized ("Build"/"Compilación"/…), so parsing it drops the build in a
    /// non-English locale; the sysctl value is not localized.
    private static func osBuild() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
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
