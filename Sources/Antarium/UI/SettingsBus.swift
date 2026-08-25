import Foundation

/// One signal that a setting changed, for every surface that shows one.
///
/// The dashboard and the settings panel both display the same handful of
/// choices — sort order, reduced list, notifications, pinning. Each used to
/// keep its own copy: the dashboard in `@State`, whose initialiser runs once,
/// and the panel behind its own revision counter. So a change made in one was
/// invisible to the other until it was rebuilt, and the two disagreed about
/// what was switched on.
///
/// Nothing here stores a setting. `Settings` remains the only place a value
/// lives; this exists purely to say "read it again".
@MainActor
final class SettingsBus: ObservableObject {
    static let shared = SettingsBus()

    @Published private(set) var revision = 0

    /// Call after writing any setting that a surface displays.
    func changed() { revision += 1 }
}
