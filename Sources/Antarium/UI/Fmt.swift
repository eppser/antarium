import Foundation

/// Display formatting shared by the dashboard and the alert banner.
///
/// These lived in both files. Beyond the duplication, `Text("\(int)")` in
/// SwiftUI applies locale grouping — under a German locale 10259 rendered as
/// "10.259" — so counts must be formatted explicitly, never interpolated.
enum Fmt {
    static func count(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return String(n)
    }

    static func bytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        return mb >= 1024 ? String(format: "%.1fGB", mb / 1024) : String(format: "%.0fMB", mb)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 3600 { return "\(max(1, Int(seconds / 60)))m" }
        if seconds < 86_400 { return String(format: "%.1fh", seconds / 3600) }
        return "\(Int(seconds / 86_400))d"
    }
}
