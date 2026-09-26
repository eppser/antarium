import Foundation

/// The assembled application keeps resources in its main bundle; SwiftPM uses
/// a generated resource bundle. Prefer the app layout so an installed build
/// never depends on the build machine's absolute bundle fallback.
///
/// The preference is not a safety net, which is the part worth knowing. If a
/// resource is missing from the .app, this falls through to `Bundle.module`
/// — and that resolves against the absolute path of `.build` on the machine
/// that compiled it. The app then runs perfectly for whoever built it and
/// finds nothing on anybody else's Mac. Verified by moving pricing.json
/// aside: the build succeeds, the app launches, `--status` exits zero.
/// `verify.sh` checks the assembled bundle against the names this code asks
/// for, because nothing at runtime will.
enum AppResources {
    static let bundle: Bundle = {
        if Bundle.main.url(forResource: "pricing", withExtension: "json") != nil {
            return Bundle.main
        }
        return Bundle.module
    }()
}
