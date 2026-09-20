import SwiftUI
import AppKit

/// One screen, one button. Everything on it was found without asking.
struct OnboardingView: View {
    let harnesses: [Onboarding.Finding]
    let accounts: [Onboarding.Finding]
    let sessions: Int?
    var onDone: () -> Void

    private var detected: [Onboarding.Finding] { harnesses.filter(\.found) }
    private var missing: [Onboarding.Finding] { harnesses.filter { !$0.found } }
    private var signedIn: [Onboarding.Finding] { Onboarding.partition(accounts).signedIn }
    private var connectable: [Onboarding.Finding] { Onboarding.partition(accounts).connectable }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Antarium is ready").font(.system(size: 17, weight: .semibold))
                Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 14)

            Divider().opacity(0.4)

            VStack(alignment: .leading, spacing: 14) {
                group("Agents found") {
                    ForEach(detected) { row($0) }
                    if detected.isEmpty {
                        Text("None yet — start any coding agent and it appears here.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if !signedIn.isEmpty {
                    group("Quota") { ForEach(signedIn) { row($0) } }
                }
                // Ten providers ship, and on most Macs a few are signed in.
                // Listing the rest as unchecked rows with a setup hint each
                // filled the panel with things the user has not got, under a
                // heading that says Antarium is ready. They are named, once,
                // and Settings is where they get switched on.
                if !connectable.isEmpty {
                    Text((signedIn.isEmpty ? "Quota available for: " : "Also connectable: ")
                         + connectable.map(\.name).joined(separator: ", "))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                let workspaces = Onboarding.workspaces().filter(\.found)
                if !workspaces.isEmpty {
                    Text("Workspace: " + workspaces.map(\.name).joined(separator: ", ")
                         + " — clicking a session opens its pane there")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !missing.isEmpty {
                    Text("Also supported, not installed here: "
                         + missing.map(\.name).joined(separator: ", "))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)

            Divider().opacity(0.4)

            HStack(spacing: 10) {
                Text("Nothing to configure. Settings has the rest.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button(action: onDone) {
                    Text("Start").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var summary: String {
        let n = detected.count
        guard let sessions else {
            return "Found \(n) agent\(n == 1 ? "" : "s") on this Mac. Counting sessions…"
        }
        if sessions == 0 { return "Found \(n) agent\(n == 1 ? "" : "s"). Nothing running right now." }
        return "Found \(n) agent\(n == 1 ? "" : "s") and \(sessions) running "
            + "session\(sessions == 1 ? "" : "s"), including any launched through ACP."
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .bold)).tracking(0.6)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ finding: Onboarding.Finding) -> some View {
        HStack(spacing: 7) {
            Image(systemName: finding.found ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 11))
                .foregroundStyle(finding.found ? Color.accentColor : Color.secondary)
            Text(finding.name).font(.system(size: 11.5))
            Spacer()
            Text(finding.hint ?? finding.detail)
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}
