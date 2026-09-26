import Foundation

/// Pure presentation contract shared by SwiftUI and tests. Keeping the spoken
/// value out of view structure prevents icons, badges or future layout changes
/// from silently removing essential compatibility information.
struct HarnessRowPresentation {
    let name: String
    let sourceLabel: String
    let compatibilityLabel: String
    let accessibilityLabel: String

    init(descriptor: HarnessDescriptor, edited: Bool,
         compatibilityStatus supplied: HarnessCompatibility.Status? = nil) {
        name = descriptor.name
        // A descriptor with no session source and a quota block reads no
        // sessions at all — it is there for the menu bar gauge. Calling that
        // "Native metadata", which is what an unqualified `none` used to say,
        // implied a reader that does not exist.
        let quotaOnly = descriptor.source.kind == .none && descriptor.quota != nil
        sourceLabel = descriptor.presentation?.sourceLabel
            ?? (quotaOnly ? "Quota only" : Self.source(descriptor.source.kind))
        if quotaOnly {
            // Its evidence is the quota fixture, not a session fixture, so
            // that is what the row reports.
            //
            // Three answers, not two. A descriptor with no fixture beside it
            // has not been checked against anything, and `verify` reports
            // that as a failed report — so the row said "Quota mapping
            // failed", which claims the mapping was tried and broke. For a
            // shipped harness that cannot happen, because verify.sh requires
            // a fixture; for somebody's own descriptor it is the ordinary
            // case, and telling them their mapping is broken when they have
            // simply not written a fixture sends them to look at the wrong
            // thing.
            if QuotaFixture.fixtureURL(for: descriptor.id, in: AppResources.bundle) == nil {
                compatibilityLabel = "Declared"
            } else {
                let report = QuotaFixture.verify(descriptor, in: AppResources.bundle)
                compatibilityLabel = report.map { $0.passed ? "Quota fixture verified"
                                                            : "Quota mapping failed" }
                    ?? "Declared"
            }
        } else {
            let status = supplied
                ?? HarnessCompatibility.verifyFixture(descriptor, in: AppResources.bundle).status
            compatibilityLabel = Self.compatibility(status)
        }
        accessibilityLabel = [descriptor.name, sourceLabel, compatibilityLabel,
                              edited ? "edited" : "bundled"]
            .joined(separator: ", ")
    }

    private static func source(_ kind: HarnessDescriptor.Source.Kind) -> String {
        switch kind {
        case .jsonl: return "JSON Lines"
        case .json: return "JSON"
        case .sqlite: return "SQLite"
        case .command: return "Command"
        case .none: return "Native metadata"
        }
    }

    private static func compatibility(_ status: HarnessCompatibility.Status) -> String {
        switch status {
        case .experimental: return "Experimental"
        case .declared: return "Declared"
        case .fixtureVerified: return "Fixture verified"
        case .liveAvailable: return "Live source available"
        case .incompatible: return "Compatibility check failed"
        }
    }
}
