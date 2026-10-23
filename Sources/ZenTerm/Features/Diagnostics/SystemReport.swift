import Foundation

struct SystemReport: Equatable {
    let appVersion: String
    let build: String?  // nil under `swift run`
    let osVersion: String
    let architecture: String

    var plainText: String {
        let version = build.map { "v\(appVersion) (build \($0))" } ?? "v\(appVersion)"
        return """
            - ZenTerm: \(version)
            - macOS: \(osVersion)
            - Architecture: \(architecture)
            """
    }

    static func current() -> SystemReport {
        SystemReport(
            appVersion: AppVersion.current,
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
            osVersion: liveOSVersion(),
            architecture: machineArchitecture())
    }

    private static func liveOSVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let semantic =
            version.patchVersion > 0
            ? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            : "\(version.majorVersion).\(version.minorVersion)"
        guard let build = osBuild() else { return semantic }
        return "\(semantic) (\(build))"
    }

    // `operatingSystemVersionString` is localized, so the build comes from `sysctl kern.osversion`.
    private static func osBuild() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func machineArchitecture() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        let size = MemoryLayout.size(ofValue: info.machine)
        return withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: size) { String(cString: $0) }
        }
    }
}
