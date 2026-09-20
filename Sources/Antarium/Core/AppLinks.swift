import Foundation

/// Where the app sends someone who wants to report a problem.
///
/// The URL lives here rather than at each call site so the dashboard and the
/// settings panel cannot drift apart, and so it is testable without a browser.
enum AppLinks {
    static let repository = URL(string: "https://github.com/eppser/antarium")!

    /// A new issue, pre-filled with the three facts every bug report needs and
    /// nobody remembers to include.
    ///
    /// Deliberately nothing else: the app version, the OS version and the
    /// architecture are what a maintainer needs to reproduce a problem. No
    /// hostname, no username, no paths, no configured hosts — a bug report is
    /// a public document, and this app knows things that should stay private.
    static func bugReport(version: String = appVersion,
                          system: String = systemVersion,
                          architecture: String = architecture) -> URL {
        guard var components = URLComponents(
            url: repository.appendingPathComponent("issues").appendingPathComponent("new"),
            resolvingAgainstBaseURL: false)
        else { return repository }
        components.queryItems = [
            URLQueryItem(name: "labels", value: "bug"),
            URLQueryItem(name: "body", value: """
                <!-- What happened, and what you expected instead. -->


                ---
                Antarium \(version) · macOS \(system) · \(architecture)
                """),
        ]
        // A malformed query should still get the reporter to the right place.
        return components.url ?? repository
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    static var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var architecture: String {
        #if arch(arm64)
        return "Apple silicon"
        #elseif arch(x86_64)
        return "Intel"
        #else
        return "unknown"
        #endif
    }
}
