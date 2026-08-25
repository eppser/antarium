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
        sourceLabel = descriptor.presentation?.sourceLabel ?? Self.source(descriptor.source.kind)
        let status = supplied
            ?? HarnessCompatibility.verifyFixture(descriptor, in: AppResources.bundle).status
        compatibilityLabel = Self.compatibility(status)
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
