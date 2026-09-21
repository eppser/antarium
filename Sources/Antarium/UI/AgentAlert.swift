import AppKit
import SwiftUI

/// A banner shown when an agent stops working.
///
/// Deliberately not `UNUserNotificationCenter`: that needs an authorisation
/// prompt and a properly signed bundle, and an ad-hoc build often just fails
/// silently. A window we own always shows, can be as loud as it needs to be,
/// and takes a click straight through to the agent.
@MainActor
final class AgentAlert: NSObject {
    static let shared = AgentAlert()

    private var panels: [NSPanel] = []
    /// The status item to hang banners from, set by the first AgentItem.
    weak var anchor: NSStatusBarButton?
    private let width: CGFloat = 330
    private let spacing: CGFloat = 8

    func post(_ row: AgentRow) {
        guard Settings.notifyOnIdle else { return }

        let panel = makePanel(row)

        panels.insert(panel, at: 0)
        restack()

        // Slide in from the right.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().alphaValue = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self, weak panel] in
            guard let panel else { return }
            self?.dismiss(panel)
        }
    }

    /// Builds an alert without showing it; construction owns no global state.
    func makePanel(_ row: AgentRow) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 78),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .screenSaver          // above full-screen apps too
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = false

        let card = AlertCard(row: row,
                             onOpen: { [weak self, weak panel] in
                                 guard let panel else { return }
                                 Focus.reveal(row)
                                 self?.dismiss(panel)
                             },
                             onClose: { [weak self, weak panel] in
                                 guard let panel else { return }
                                 self?.dismiss(panel)
                             })
        // Same reason as the dashboard: an alert nobody can dismiss on the
        // first click is worse than no alert.
        let hosting = PanelChrome.ClickThrough(rootView: card)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.wantsLayer = true
        panel.contentView = container
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        hosting.layoutSubtreeIfNeeded()
        panel.setContentSize(hosting.fittingSize)

        return panel
    }

    private func dismiss(_ panel: NSPanel) {
        guard panels.contains(panel) else { return }
        panels.removeAll { $0 == panel }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
                // Tear down the SwiftUI tree, including its animations and
                // observers, as soon as the dismissal finishes.
                panel.contentView = nil
            }
        }
        restack()
    }

    /// Newest directly under our menu bar item, the rest stacking beneath it,
    /// so a banner always appears where the app itself lives.
    private func restack() {
        let screen = anchor?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var y = visible.maxY - 6

        for panel in panels {
            let size = panel.frame.size
            y -= size.height
            var x = visible.maxX - size.width - 12
            if let button = anchor, let window = button.window {
                // Right-align to the status item, but never past the screen edge.
                let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
                x = min(max(frame.maxX - size.width, visible.minX + 12),
                        visible.maxX - size.width - 12)
            }
            panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height),
                           display: true)
            y -= spacing
        }
    }
}

extension AgentAlert {
    /// For the `--alert` design harness.
    static func previewCard(_ row: AgentRow) -> some View {
        AlertCard(row: row, onOpen: {}, onClose: {})
    }
}

// MARK: - Card

struct AlertCard: View {
    let row: AgentRow
    let onOpen: () -> Void
    let onClose: () -> Void

    @State private var hovering = false
    @State private var pulse = false

    private var tint: Color {
        if case .ended = row.state { return .secondary }
        return .orange
    }

    var body: some View {
        HStack(spacing: 0) {
            // Loud accent edge — the part you catch out of the corner of an eye.
            Rectangle().fill(tint).frame(width: 4)

            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(tint.opacity(0.18)).frame(width: 34, height: 34)
                    Circle().stroke(tint.opacity(0.5), lineWidth: 2)
                        .frame(width: 34, height: 34)
                        .scaleEffect(pulse ? 1.35 : 1)
                        .opacity(pulse ? 0 : 1)
                    Image(nsImage: Glyphs.image(row.agentID, size: 17,
                                                color: NSColor(tint).withAlphaComponent(0.95),
                                                appearance: NSApp.effectiveAppearance))
                        .resizable().frame(width: 17, height: 17)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(row.coreName) finished its task")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(row.state.label).foregroundStyle(tint)
                        if let d = row.duration {
                            Text("· ran " + Fmt.duration(d))
                        }
                        // Interpolating an Int into Text applies locale grouping —
                        // 10259 rendered as "10.259" here. Format it ourselves.
                        if let tools = row.toolCalls { Text("· " + Fmt.count(tools) + " tools") }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    Text(hovering ? "Click to jump to it" : row.displayPath)
                        .font(.system(size: 9.5))
                        .foregroundStyle(hovering ? Color.accentColor : Color.secondary.opacity(0.7))
                        .lineLimit(1).truncationMode(.head)
                }

                Spacer(minLength: 4)

                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(Color.primary.opacity(hovering ? 0.10 : 0)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss notification")
            }
            .padding(.horizontal, 11).padding(.vertical, 10)
        }
        .frame(width: 330)
        .background(
            ZStack {
                VisualEffect()
                tint.opacity(hovering ? 0.10 : 0.05)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(tint.opacity(hovering ? 0.55 : 0.28), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.coreName) finished its task, \(row.state.label)")
        .accessibilityHint("Activate to reveal the agent session")
        .accessibilityAction { onOpen() }
        .onHover { hovering = $0 }
        .onAppear {
            withAnimation(.easeOut(duration: 1.1)) {
                pulse = true
            }
        }
    }
}

private struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
