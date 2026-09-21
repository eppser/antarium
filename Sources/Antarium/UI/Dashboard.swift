import SwiftUI
import AppKit

/// Reports a measured height up through the view tree.
private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MeasureHeight: ViewModifier {
    func body(content: Content) -> some View {
        content.background(GeometryReader { proxy in
            Color.clear.preference(key: HeightKey.self, value: proxy.size.height)
        })
    }
}

struct DashboardView: View {
    @ObservedObject var store: AgentStore
    /// Re-reads the settings below whenever any surface changes one.
    @ObservedObject private var settingsBus = SettingsBus.shared
    var onSettings: () -> Void
    var onTogglePin: () -> Void
    var onClose: () -> Void = {}
    /// Fired whenever the natural size changes, so the panel can resize.
    var onResize: () -> Void = {}

    private var sort: AgentSort { Settings.agentSort }
    /// Read straight from settings, never mirrored: a copy taken at init is a
    /// copy that stops matching the moment the settings panel changes it.
    private var pinned: Bool { Settings.dashboardPinned }
    private var notify: Bool { Settings.notifyOnIdle }
    private var reduced: Bool { Settings.agentListCompact }
    /// Height the rows actually want; a ScrollView alone reports an unbounded
    /// ideal, which sized the window to the whole screen.
    @State private var listHeight: CGFloat = 0
    /// Which row the pointer is over. One value for the whole list, so two rows
    /// cannot both look hovered: per-row flags drifted out of sync whenever the
    /// pointer moved between rows faster than SwiftUI delivered the matching
    /// "false", or when a refresh rebuilt the rows mid-hover.
    @State private var hoveredID: AgentRow.ID?

    /// Show every agent; scroll only once the list would outgrow the screen.
    private var maxListHeight: CGFloat {
        max(200, (NSScreen.main?.visibleFrame.height ?? 900) - 130)
    }

    /// Reduced mode drops the whole second line, so the full width would just
    /// be a gap in the middle of every row. Narrow the panel to match.
    private var panelWidth: CGFloat { reduced ? 400 : 600 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)

            if store.rows.isEmpty {
                placeholder
            } else {
                ScrollView(.vertical, showsIndicators: listHeight > maxListHeight) {
                    VStack(spacing: 1) {
                        ForEach(store.rows) { row in
                            AgentRowView(row: row, reduced: reduced, hoveredID: $hoveredID)
                        }
                    }
                    .padding(.horizontal, reduced ? 5 : 6).padding(.vertical, 5)
                    .modifier(MeasureHeight())
                }
                .onPreferenceChange(HeightKey.self) { listHeight = $0 }
                // Definite height: everything the rows need, capped at the screen.
                .frame(height: min(max(listHeight, 30), maxListHeight))
            }

            Divider().opacity(0.4)
            footer
        }
        .frame(width: panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in
            // Watch the whole size, not just height — switching to reduced mode
            // changes the width, and the panel has to follow.
            Color.clear.onChange(of: proxy.size) { _ in onResize() }
                .onAppear { onResize() }
        })
    }

    // MARK: - Header

    /// Loaded once: the header rebuilds on every scan, and reading a PNG off
    /// disk each time would be the most expensive thing in it.
    private static let mark: NSImage? = AppResources.bundle
        .url(forResource: "antarium-mark", withExtension: "png", subdirectory: "logo")
        .flatMap { NSImage(contentsOf: $0) }

    private var header: some View {
        HStack(spacing: 6) {
            if let mark = Self.mark {
                // Larger than the controls beside it on purpose: the mark is a
                // shaded illustration, and below about 20pt its legs and body
                // merge into an orange smudge. The buttons stay where they are.
                Image(nsImage: mark).resizable().interpolation(.high)
                    .frame(width: 24, height: 24)
                    .accessibilityLabel("Antarium")
            }
            // The narrow list has no room for the word and the whole toolbar;
            // squeezed, it wrapped to "Ag / ent / s". The mark carries the name
            // there instead.
            if !reduced {
                Text("Antarium").font(.system(size: 13, weight: .semibold)).fixedSize()
            }
            Text(verbatim: "\(store.rows.count)")
                .font(.system(size: reduced ? 12 : 10, weight: .semibold))
                .foregroundStyle(reduced ? .secondary : .tertiary)
                .fixedSize()

            SortControl(sort: sort, iconsOnly: reduced) { store.setSort($0) }
                .padding(.leading, 2)

            IconButton(symbol: reduced ? "list.bullet" : "list.bullet.indent",
                       help: reduced ? "Show full detail" : "Reduced list — name, status, context, last reply",
                       active: reduced) {
                Settings.agentListCompact.toggle()
                SettingsBus.shared.changed()
            }

            Spacer(minLength: 4)

            if store.isScanning {
                ProgressView().controlSize(.small).scaleEffect(0.55).frame(width: 10, height: 10)
            }
            IconButton(symbol: notify ? "bell.fill" : "bell.slash",
                       help: notify ? "Notifying when an agent stops working"
                                    : "Notify me when an agent stops working",
                       active: notify) {
                Settings.notifyOnIdle.toggle()
                SettingsBus.shared.changed()
            }
            IconButton(symbol: pinned ? "pin.fill" : "pin",
                       help: pinned ? "Unpin" : "Keep on screen, docked right",
                       active: pinned) {
                Settings.dashboardPinned.toggle()
                SettingsBus.shared.changed()
                onTogglePin()
            }
            IconButton(symbol: "arrow.clockwise",
                       help: "Re-read every agent now") { store.refresh(force: true) }
            IconButton(symbol: "gearshape", help: "Settings", action: onSettings)
            // Always offered. Unpinned, a click outside also closes it, but
            // hiding the button meant unpinning made the close control vanish
            // — the one action every panel is expected to have.
            IconButton(symbol: "xmark", help: "Close", action: onClose)
        }
        // Trimmed around the controls, not off them: the clickable area is the
        // button's own frame, so the header loses height without losing target.
        .padding(.horizontal, 9).padding(.vertical, 2)
    }

    private var placeholder: some View {
        VStack(spacing: 5) {
            Image(systemName: store.isScanning ? "hourglass" : "moon.zzz")
                .font(.system(size: 18)).foregroundStyle(.tertiary)
            Text(store.isScanning ? "Scanning…" : "No agent sessions found")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 22)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            // Leftmost, so it sits in the corner and never moves: the cost and
            // memory labels next to it come and go with what is running.
            Button { NSWorkspace.shared.open(AppLinks.bugReport()) } label: {
                Image(systemName: "ladybug")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Report a bug on GitHub")
            .accessibilityLabel("Report a bug on GitHub")

            if store.totalCost > 0 {
                Label(Pricing.money(store.totalCost), systemImage: "creditcard")
                    .help("Estimated list-price cost of every session's tokens. "
                        + "On a subscription plan this is a size signal, not a bill.")
            }
            if store.totalRAM > 0 { Label(Fmt.bytes(store.totalRAM), systemImage: "memorychip") }
            // Why some rows have no figures. It is on each row's tooltip too,
            // but that needs knowing to hover: the totals beside this are
            // incomplete while any session is still being read, and a cost of
            // $670 appearing later is a worse surprise than a line saying it
            // is coming.
            if let waiting = Self.rowsAwaitingHistory(store.rows) {
                Label(waiting, systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.tertiary)
                    .help("These sessions have history still to read. Their tokens, "
                        + "tool calls and cost are withheld until it is finished, "
                        + "rather than shown low.")
            }
            Spacer()
            Spacer()
            Text(store.scannedAt.map { Format.age($0) } ?? "—").foregroundStyle(.tertiary)
        }
        .font(.system(size: 9.5)).foregroundStyle(.secondary)
        .padding(.horizontal, 9).padding(.vertical, 5)
    }
}

extension DashboardView {
    /// How many rows are withholding figures because their history is still
    /// being read, or nil when none are.
    ///
    /// Counted from the note the scan already put on each row rather than from
    /// a second source, so the summary cannot disagree with the tooltips.
    static func rowsAwaitingHistory(_ rows: [AgentRow]) -> String? {
        let waiting = rows.filter { ($0.note ?? "").contains("still being read") }.count
        guard waiting > 0 else { return nil }
        return waiting == 1 ? "1 still reading" : "\(waiting) still reading"
    }
}

// MARK: - Sort

private struct SortControl: View {
    let sort: AgentSort
    /// The narrow panel has no room for four labels — they wrap to three lines
    /// each. Icons carry it, with the name on hover.
    var iconsOnly: Bool = false
    var onChange: (AgentSort) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(AgentSort.allCases, id: \.self) { option in
                let selected = option == sort
                Button {
                    onChange(option)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: option.symbol).font(.system(size: 11))
                        // Only the chosen one is named. Five labels and six
                        // buttons overflowed the panel once the icons were big
                        // enough to hit, and a centred frame clips both ends —
                        // which is how the close button and the app mark
                        // vanished off opposite edges of the header.
                        if !iconsOnly && selected {
                            Text(option.title)
                                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                                .fixedSize()
                        }
                    }
                    .padding(.horizontal, iconsOnly ? 7 : 8).padding(.vertical, 3)
                    .frame(minHeight: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(selected ? Color.accentColor.opacity(0.18) : .clear)
                    )
                    // An unselected pill fills with .clear; without a content
                    // shape only the glyph answered a click, which is why the
                    // sort buttons felt like they were ignoring you.
                    .contentShape(Rectangle())
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(option.title)
                .accessibilityLabel("Sort by \(option.title)")
                .accessibilityValue(selected ? "Selected" : "Not selected")
            }
        }
        .padding(1.5)
        .background(RoundedRectangle(cornerRadius: 5.5).fill(Color.primary.opacity(0.05)))
        .help("Sort order — remembered across launches")
    }
}

// MARK: - Row

/// One agent. Two lines normally; in reduced mode a single line carrying only
/// name, context, status and when it last replied. One view rather than two
/// near-identical ones.
private struct AgentRowView: View {
    let row: AgentRow
    var reduced = false
    @Binding var hoveredID: AgentRow.ID?
    @ObservedObject private var quotaStore = QuotaStore.shared

    private var hovering: Bool { hoveredID == row.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(nsImage: Glyphs.image(row.agentID, size: 12,
                                            color: .labelColor.withAlphaComponent(0.9),
                                            appearance: NSApp.effectiveAppearance))
                    .resizable().frame(width: 12, height: 12)

                Text(row.coreName).font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize(horizontal: !reduced, vertical: false)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                // Where it is running, before the path: it is the thing that
                // tells two rows of the same project apart, so it should not be
                // the part that gets truncated away.
                if let host = row.hostApp {
                    Text(host)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 4).padding(.vertical, 0.5)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .fixedSize()
                }
                if !reduced {
                    Text(row.displayPath).font(.system(size: 9.5)).foregroundStyle(.quaternary)
                        .lineLimit(1).truncationMode(.head)
                }

                if !reduced {
                    if let tmux = row.tmuxTarget {
                        Image(systemName: "square.split.2x2").font(.system(size: 7.5))
                            .foregroundStyle(.quaternary).help("tmux · \(tmux)")
                    }
                    // A machine you can ssh to is not "the cloud", and one
                    // icon for both would make a remote tmux pane look like a
                    // hosted task with no pane to attach to.
                    if row.hostApp == RemoteTmux.tag {
                        Image(systemName: "server.rack").font(.system(size: 7.5))
                            .foregroundStyle(.secondary)
                            .help(row.note ?? "tmux on another machine")
                    } else if row.isRemote {
                        Image(systemName: "cloud.fill").font(.system(size: 7.5))
                            .foregroundStyle(.secondary).help("Running in the cloud")
                    }
                }

                Spacer(minLength: 4)
                if !reduced { CostLabel(cost: row.costUSD, over: row.duration) }
                if let fraction = row.contextFraction {
                    ContextBar(fraction: fraction, tokens: row.contextTokens,
                               window: row.contextWindow)
                } else if let gauge = quotaStore.primaryGauge(for: row.agentID) {
                    AccountQuotaBar(gauge: gauge,
                                    plan: quotaStore.snapshot(for: row.agentID)?.accountLabel)
                } else {
                    Color.clear.frame(width: 61, height: 1)
                }
                StatePill(state: row.state)
                if reduced { LastReply(date: row.lastActivity, width: 52) }
            }

            if !reduced {
                HStack(spacing: 7) {
                    CapabilityStrip(context: row.context)
                    Sparkline(series: row.activity, tint: stateTint(row.state))
                    Spacer(minLength: 6)
                    if let model = Pricing.shortName(row.model) {
                        Stat("cpu", model)
                    } else if let plan = quotaStore.snapshot(for: row.agentID)?.accountLabel {
                        Stat("creditcard", plan, help: "\(plan) plan")
                    }
                    if let tools = row.toolCalls {
                        Stat("hammer", Fmt.count(tools), help: "\(tools) tool calls")
                    }
                    if let subs = row.subAgents {
                        Stat("person.2", Fmt.count(subs), help: "\(subs) sub-agents")
                    }
                    if let turns = row.turns {
                        Stat("bubble.left", Fmt.count(turns), help: "\(turns) conversation turns")
                    }
                    if let up = row.sentTokens {
                        Stat("arrow.up", Fmt.count(up), help: "\(up) tokens sent")
                    }
                    if let down = row.receivedTokens {
                        Stat("arrow.down", Fmt.count(down), help: "\(down) tokens received")
                    }
                    if let ram = row.rssBytes { Stat("memorychip", Fmt.bytes(ram)) }
                    LastReply(date: row.lastActivity)
                }
            }
        }
        .padding(.horizontal, reduced ? 6 : 7).padding(.vertical, reduced ? 4 : 4.5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.075 : 0.03))
        )
        .onHover { inside in
            // Only ever clear our own claim: a "false" arriving late, after the
            // pointer already entered the next row, must not erase that row.
            if inside { hoveredID = row.id }
            else if hoveredID == row.id { hoveredID = nil }
        }
        .contentShape(Rectangle())
        // Double click attaches. A single click prefers whatever window is
        // already showing the session, which is usually what you want — but
        // when nothing is showing it, there was no way to ask for one.
        .onTapGesture(count: 2) {
            if let target = row.tmuxTarget { Focus.attachToPane(target) }
            else { Focus.reveal(row) }
        }
        .onTapGesture { Focus.reveal(row) }
        .contextMenu { RowActions(row: row) }
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint("Activate to reveal this agent session")
        .accessibilityAction { Focus.reveal(row) }
    }

    private var tooltip: String {
        var lines = [row.sessionName.isEmpty ? row.coreName : row.sessionName, row.cwd]
        if let note = row.note { lines.append(note) }
        if let t = row.tmuxTarget { lines.append("tmux \(t) — click to jump there") }
        else if row.pid != nil { lines.append("Click to bring its terminal to the front") }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    private var accessibilitySummary: String {
        var values = [row.coreName, row.state.label]
        if let host = row.hostApp { values.append(host) }
        if !row.displayPath.isEmpty { values.append(row.displayPath) }
        if let model = Pricing.shortName(row.model) { values.append("model \(model)") }
        if let fraction = row.contextFraction {
            values.append("context \(Int(fraction * 100)) percent")
        }
        if let tools = row.toolCalls { values.append("\(tools) tool calls") }
        if let turns = row.turns { values.append("\(turns) turns") }
        if let cost = row.costUSD { values.append("cost \(Pricing.money(cost))") }
        return values.joined(separator: ", ")
    }
}

/// Right-click actions. Everything here acts on a real path or a real pid —
/// entries whose target doesn't exist are simply absent rather than disabled.
private struct RowActions: View {
    let row: AgentRow

    var body: some View {
        // For a tmux session, attaching is the thing you actually want, so it
        // goes first and is what Return picks.
        if let target = row.tmuxTarget {
            Button("Attach to tmux Session") { Focus.attachTmux(target) }
        }
        if !row.cwd.isEmpty {
            Button("Go to Window") { Focus.reveal(row) }
            Divider()
            Button("Open Directory") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.cwd)])
            }
            Button("Open in Terminal") {
                let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
                NSWorkspace.shared.open([URL(fileURLWithPath: row.cwd)],
                                        withApplicationAt: terminal,
                                        configuration: NSWorkspace.OpenConfiguration())
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.cwd, forType: .string)
            }
        }
        let files = row.context.present
        if !files.isEmpty {
            Divider()
            ForEach(files) { capability in
                if let url = capability.url {
                    Button("Open \(capability.kind.label)") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
}

private struct LastReply: View {
    let date: Date?
    var width: CGFloat = 54
    var body: some View {
        Text(date.map { Format.age($0) } ?? "—")
            .font(.system(size: 9)).foregroundStyle(.tertiary)
            // One line, always: "10 min ago" wrapping made that row taller than
            // its neighbours and broke the rhythm of the list.
            .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            .frame(width: width, alignment: .trailing)
            .help("Last reply")
    }
}

private func stateTint(_ state: AgentRow.State) -> Color {
    switch state {
    case .waiting: return .orange
    case .working: return .green
    case .looping: return .green
    case .shell:   return .purple
    case .ended:   return .secondary
    case .cloud:   return .blue
    // Not observed is not idle. It reads as secondary rather than borrowing
    // another state's colour, so an unknown never looks like a fact.
    case .unobserved: return .secondary
    }
}

// MARK: - Activity

/// Assistant turns per 10 minutes over the last six hours, newest on the
/// right, scaled to this agent's own busiest bucket and tinted by its state.
private struct Sparkline: View {
    let series: [Int]
    let tint: Color

    private let barWidth: CGFloat = 1.6
    private let gap: CGFloat = 0.9
    private let height: CGFloat = 13

    var body: some View {
        let peak = max(series.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: gap) {
            ForEach(Array(series.enumerated()), id: \.offset) { index, value in
                let fraction = Double(value) / Double(peak)
                // Fade the past so "now" reads at a glance.
                let age = Double(index) / Double(max(series.count - 1, 1))
                Capsule()
                    .fill(value == 0
                          ? Color.primary.opacity(0.07)
                          : tint.opacity(0.35 + 0.65 * age))
                    .frame(width: barWidth,
                           height: value == 0 ? 1.5 : max(2, height * CGFloat(fraction)))
            }
        }
        .frame(height: height, alignment: .bottom)
        .opacity(series.isEmpty ? 0 : 1)
        .help(series.reduce(0, +) == 0
              ? "No activity in the last 6 hours"
              : "\(series.reduce(0, +)) turns in the last 6 hours · newest on the right")
    }
}

// MARK: - Capabilities

private struct CapabilityStrip: View {
    let context: ProjectContext
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(context.capabilities) { CapabilityDot(capability: $0) }
        }
    }
}

private struct CapabilityDot: View {
    let capability: Capability
    @State private var hovering = false

    // One rule, so the strip reads consistently: has content, or it doesn't.
    private var fill: Color {
        capability.isPresent
            ? Color.accentColor.opacity(hovering ? 0.32 : 0.18)
            : Color.primary.opacity(0.04)
    }
    private var stroke: Color {
        capability.isPresent ? Color.accentColor : Color.primary.opacity(0.18)
    }

    var body: some View {
        Group {
            if let url = capability.url {
                Button { NSWorkspace.shared.open(url) } label: { icon }
                    .buttonStyle(.plain)
                    .help("\(capability.kind.label)\(capability.scope == .inherited ? " (inherited)" : "") — \(url.path)\nClick to open")
            } else {
                icon.help("\(capability.kind.label) — not present")
            }
        }
        .onHover { hovering = $0 }
    }

    private var icon: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .fill(fill).frame(width: 17, height: 14)
                .overlay(Image(systemName: capability.kind.symbol)
                    .font(.system(size: 8, weight: .medium)).foregroundStyle(stroke))
            if capability.count > 1 {
                Text(verbatim: "\(min(capability.count, 99))")
                    .font(.system(size: 6.5, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 1.8).padding(.vertical, 0.3)
                    .background(Capsule().fill(Color.accentColor))
                    .offset(x: 4.5, y: -1)
            }
        }
    }
}

// MARK: - Small pieces

/// The blink, as a pure function of the clock — separated out so it can be
/// checked without a running view.
enum Blink {
    /// Half a beat. Two of these make one on-off cycle.
    static let beat: TimeInterval = 0.55

    /// Alternates every `beat`, from absolute time — so every pill in the list
    /// blinks together instead of each on its own schedule, and none of it
    /// depends on when a view happened to appear.
    static func isDim(at date: Date) -> Bool {
        Int(date.timeIntervalSinceReferenceDate / beat) % 2 == 1
    }
}

private struct StatePill: View {
    let state: AgentRow.State

    /// Only a genuinely busy agent blinks, so motion in the list always means
    /// "something is happening right now".
    private var isLive: Bool {
        switch state {
        case .working, .shell: return true
        default: return false
        }
    }

    /// Half a beat. Two of these make one on-off cycle.
    private static let beat: TimeInterval = Blink.beat

    /// A blink, not a pulse — and read from the clock rather than animated.
    ///
    /// Two things were wrong before. It toggled a `@State` flag inside
    /// `withAnimation` having just set it to `false` in the same update, which
    /// SwiftUI coalesces, so the transition sometimes never happened and the
    /// pill sat still — the "sometimes blinking" this replaces. And it only
    /// started `onAppear`, which a reused row never fires.
    ///
    /// It is a discrete step rather than a fade because *any* continuous
    /// animation forces this panel's vibrancy backdrop to re-composite every
    /// frame: measured at 25% CPU with a pinned dashboard, for a single fading
    /// dot, versus 0% with none. Stepping twice a second costs nothing and is
    /// easier to see across a room.
    var body: some View {
        if isLive {
            TimelineView(.periodic(from: .now, by: Self.beat)) { context in
                pill(dim: Self.isDim(at: context.date))
            }
        } else {
            pill(dim: false)
        }
    }

    /// Alternates every `beat`, from absolute time — so every pill in the list
    /// blinks together instead of each on its own schedule.
    static func isDim(at date: Date) -> Bool { Blink.isDim(at: date) }

    private func pill(dim: Bool) -> some View {
        let tint = stateTint(state)
        return HStack(spacing: 3) {
            Circle().fill(tint).frame(width: 5, height: 5)
                .opacity(dim ? 0.25 : 1)
            Text(state.label).font(.system(size: 9, weight: isLive ? .semibold : .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 5).padding(.vertical, 1.5)
        .background(Capsule().fill(tint.opacity(0.18)))
        .frame(width: 68, alignment: .trailing)
    }
}

/// Spend, with the window it accrued over — "$167" alone invites the question
/// "since when?", and the answer is the session's own lifetime.
private struct CostLabel: View {
    let cost: Double?
    let over: TimeInterval?

    var body: some View {
        Group {
            if let cost, cost > 0 {
                HStack(spacing: 3) {
                    Text(Pricing.money(cost))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let over {
                        Text("/ " + Fmt.duration(over))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.quaternary)
                    }
                }
                .help(over.map {
                    "Estimated list-price cost of this session's tokens, over \(Fmt.duration($0))"
                } ?? "Estimated list-price cost of this session's tokens")
            } else {
                Text("")
            }
        }
        .frame(width: 78, alignment: .trailing)
    }
}

private struct ContextBar: View {
    let fraction: Double
    let tokens: Int?, window: Int?
    private var tint: Color { fraction > 0.85 ? .red : (fraction > 0.6 ? .orange : .green) }
    var body: some View {
        HStack(spacing: 3.5) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.13)).frame(width: 34, height: 4)
                Capsule().fill(tint).frame(width: max(2, 34 * fraction), height: 4)
            }
            Text(verbatim: "\(Int(fraction * 100))%")
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary).fixedSize()
        }
        .help(tokens.map { "\($0 / 1000)k of \((window ?? 0) / 1000)k context used" } ?? "Context")
    }
}

/// Account included-usage from a quota provider when the session has no
/// per-transcript context figure to draw.
private struct AccountQuotaBar: View {
    let gauge: Gauge
    let plan: String?

    private var tint: Color {
        switch gauge.severity {
        case .critical: return .red
        case .low: return .orange
        case .normal: return .green
        }
    }

    var body: some View {
        HStack(spacing: 3.5) {
            // A credit balance has no denominator, so it shows the figure and
            // no meter rather than a full bar that means nothing.
            if gauge.hasMeter {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.13)).frame(width: 34, height: 4)
                    Capsule().fill(tint).frame(width: max(2, 34 * gauge.used), height: 4)
                }
            }
            Text(gauge.amountText ?? gauge.usedPercentText)
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary).fixedSize()
        }
        .help(gauge.amountText.map { "\(gauge.title): \($0) left" }
            ?? "\(gauge.title): \(gauge.usedPercentText) of included \(plan ?? "plan") usage")
    }
}

private struct Stat: View {
    let symbol: String, text: String, help: String?
    init(_ symbol: String, _ text: String, help: String? = nil) {
        self.symbol = symbol; self.text = text; self.help = help
    }
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 8))
            Text(text).font(.system(size: 9.5).monospacedDigit())
        }
        .foregroundStyle(.secondary).fixedSize().help(help ?? "")
    }
}

private struct IconButton: View {
    let symbol: String, help: String
    var active: Bool = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11.5, weight: .medium))
                .frame(width: 21, height: 21)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(active ? Color.accentColor.opacity(0.20)
                                 : Color.primary.opacity(hovering ? 0.10 : 0)))
                // Without this the transparent parts of the label are not
                // hit-testable, so an unhighlighted button only answers on the
                // few pixels of the glyph itself.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.accentColor : Color.secondary)
        .onHover { hovering = $0 }.help(help)
        .accessibilityLabel(help)
    }
}
