import Foundation

/// The assembled application keeps resources in its main bundle; SwiftPM uses
/// a generated resource bundle. Prefer the app layout so an installed build
/// never depends on the build machine's absolute bundle fallback.
enum AppResources {
    static let bundle: Bundle = {
        if Bundle.main.url(forResource: "pricing", withExtension: "json") != nil {
            return Bundle.main
        }
        return Bundle.module
    }()
}
