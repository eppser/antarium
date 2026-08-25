import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    /// So a change made on the dashboard shows here too, not only the reverse.
    @ObservedObject private var settingsBus = SettingsBus.shared
    /// Only meaningful once there are enough harnesses to hunt through.
    @State private var harnessFilter = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("Menu Bar") { menuBarControls }
                    section("Agents") { agentControls }
                    section("Dashboard") { dashboardControls }
                    section("Refresh") { refreshControls }
                    section("Sounds") { soundControls }
                    section("Harnesses") { harnessControls }
                }
                .padding(14)
            }
            // Show the whole thing where the screen allows; scroll only if not.
            .frame(maxHeight: max(320, (NSScreen.main?.visibleFrame.height ?? 900) - 160))

            Divider().opacity(0.4)
            footer
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        // Rebuild when a setting changes, wherever it was changed.
        .id("\(model.revision)-\(settingsBus.revision)")
    }

    // MARK: - Header and footer

    /// Loaded once — the panel rebuilds on every settings change.
    private static let mark: NSImage? = AppResources.bundle
        .url(forResource: "antarium-mark", withExtension: "png", subdirectory: "logo")
        .flatMap { NSImage(contentsOf: $0) }

    private var header: some View {
        // Centred, with the close button floated over the corner rather than
        // sharing the row: in a row it would pull the mark and the name off
        // centre by its own width.
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 1) {
                if let mark = Self.mark {
                    Image(nsImage: mark).resizable().interpolation(.high)
                        .frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                }
                Text("Antarium").font(.system(size: 17, weight: .semibold))
                Text("Settings").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            // Centred as a unit, which is why it is a frame around the stack
            // rather than alignment inside it.
            .frame(maxWidth: .infinity)

            // Where a close button belongs. Quitting Antarium is a different
            // thing and stays in the footer.
            Button { model.onClose?() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close settings")
            .accessibilityLabel("Close settings")
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
    }



    /// From the bundle, so the build script stays the one place a version is set.
    private static let version =
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Antarium \(Self.version) · ~/.antarium/config.json")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
            Button("Open") { NSWorkspace.shared.open(Config.url) }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Button("Reload") { model.update { Config.reload() } }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Button("Quit Antarium") { NSApp.terminate(nil) }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .help("Stop Antarium and remove it from the menu bar")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    /// What Antarium can read, and where to add more. Everything but the two
    /// native readers is a JSON file, so this doubles as the answer to "which
    /// agents are supported?" and "how do I add mine?".
    /// The harness list is the one section that grows without limit — a
    /// contributed agent is a file, and there is no reason the folder should
    /// hold twelve rather than fifty. Left as a plain stack it pushed every
    /// other section off the panel and then off the screen.
    ///
    /// So it is a list in the macOS sense: inset, hairline-bordered, a fixed
    /// height that scrolls inside itself. The panel's height stops depending on
    /// how many agents you have. The count sits in the summary line so you can
    /// read it without scrolling, filtering appears only once there is enough
    /// to filter, and the badge marks only the exception — a row that says
    /// "unchanged" on every line teaches you nothing, while one that says
    /// "edited" on two of forty is the whole message.
    private var harnessControls: some View {
        let all = HarnessDescriptor.all()
        let edited = all.filter { HarnessDescriptor.isEdited($0.id) }.count
        let shown = harnessFilter.isEmpty ? all : all.filter {
            $0.name.localizedCaseInsensitiveContains(harnessFilter)
                || $0.id.localizedCaseInsensitiveContains(harnessFilter)
        }
        // Eight rows is where a list stops being a glance and starts being a
        // scroll; below that it shrinks to fit rather than showing empty box.
        let rowHeight: CGFloat = 22
        let height = min(CGFloat(max(shown.count, 1)) * rowHeight, rowHeight * 8)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(edited > 0 ? "\(all.count) agents · \(edited) edited" : "\(all.count) agents")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                if all.count > 8 {
                    HStack(spacing: 3) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                        TextField("Filter", text: $harnessFilter)
                            .textFieldStyle(.plain)
                            .font(.system(size: 10))
                            .frame(width: 90)
                    }
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(0.05)))
                }
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, harness in
                        // `none` means its sessions are read in Swift; the file
                        // still says which processes are the agent and where its
                        // data lives.
                        harnessRow(harness,
                                   kind: harness.source.kind == .none
                                       ? "read natively" : harness.source.kind.rawValue,
                                   isEdited: HarnessDescriptor.isEdited(harness.id),
                                   height: rowHeight)
                        if index < shown.count - 1 {
                            Divider().opacity(0.25).padding(.leading, 8)
                        }
                    }
                    if shown.isEmpty {
                        Text("No agent matches \"\(harnessFilter)\"")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                            .frame(height: rowHeight)
                    }
                }
            }
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))

            ForEach(HarnessDescriptor.failures, id: \.self) { failure in
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                    Text(failure)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 10) {
                Button("Open harness folder") {
                    try? FileManager.default.createDirectory(
                        at: HarnessDescriptor.directory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(HarnessDescriptor.directory)
                }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                Button("Rescan") { model.update { HarnessDescriptor.reload() } }
                    .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.top, 2)
            Text("Every agent above is a file in ~/.antarium/harnesses, read at each start. "
                 + "Edit one and Antarium stops updating it — it is yours. Delete it to get "
                 + "the shipped version back.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func harnessRow(_ harness: HarnessDescriptor, kind: String,
                            isEdited: Bool, height: CGFloat) -> some View {
        let presentation = HarnessRowPresentation(descriptor: harness, edited: isEdited)
        return HStack(spacing: 6) {
            Image(nsImage: Glyphs.image(harness.id, size: 11,
                                        color: .labelColor.withAlphaComponent(0.75),
                                        appearance: NSApp.effectiveAppearance))
                .resizable().frame(width: 11, height: 11)
            Text(presentation.name).font(.system(size: 11))
            Text(presentation.sourceLabel).font(.system(size: 9.5)).foregroundStyle(.tertiary)
            Spacer()
            Text(presentation.compatibilityLabel)
                .font(.system(size: 8.5)).foregroundStyle(.tertiary)
            // Only the exception is worth a badge.
            if isEdited {
                Text("edited")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityIdentifier("harness.\(harness.id)")
    }

    // MARK: - Sections

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .bold)).tracking(0.6)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var menuBarControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Segmented(title: "Show", options: MeterMode.allCases.map { ($0.title, $0.rawValue) },
                      current: Settings.meterMode.rawValue) { raw in
                model.update { Settings.meterMode = MeterMode(rawValue: raw) ?? .used }
            }
            Segmented(title: "Colour", options: Palette.allCases.map { ($0.title, $0.rawValue) },
                      current: Settings.palette.rawValue) { raw in
                model.update { Settings.palette = Palette(rawValue: raw) ?? .vivid }
            }
            if Settings.palette == .accent { accentSwatches }
            Stepper(title: "Beams", value: Settings.beams, range: 3...12) { n in
                model.update { Settings.beams = n }
            }
            Toggle(title: "AGENTS count item", on: Settings.showAgentCount) { on in
                model.update { Settings.showAgentCount = on }
            }
        }
    }

    private var accentSwatches: some View {
        HStack(spacing: 6) {
            Text("Accent").font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            ForEach(Accents.all, id: \.id) { accent in
                let selected = accent.id == Settings.accent
                Button { model.update { Settings.accent = accent.id } } label: {
                    Circle()
                        .fill(Color(AgentStyle.color(hex: accent.hex) ?? .systemBlue))
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(Color.primary.opacity(selected ? 0.75 : 0.12),
                                                 lineWidth: selected ? 2 : 1))
                }
                .buttonStyle(.plain)
                .help(accent.title)
                .accessibilityLabel("\(accent.title) accent")
                .accessibilityValue(selected ? "Selected" : "Not selected")
            }
            Spacer()
        }
    }

    private var agentControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(ProviderRegistry.all, id: \.id) { provider in
                Toggle(title: provider.displayName,
                       subtitle: provider.isConfigured ? nil : provider.setupHint,
                       on: Settings.enabledAgents.contains(provider.id)) { on in
                    model.update {
                        var set = Settings.enabledAgents
                        if on { set.insert(provider.id) } else { set.remove(provider.id) }
                        // Never leave an empty menu bar — there'd be no way back.
                        if !set.isEmpty { Settings.enabledAgents = set }
                    }
                }
            }
        }
    }

    private var dashboardControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Segmented(title: "Sort", options: AgentSort.allCases.map { ($0.title, $0.rawValue) },
                      current: Settings.agentSort.rawValue) { raw in
                model.update { Settings.agentSort = AgentSort(rawValue: raw) ?? .status }
                AgentStore.shared.setSort(Settings.agentSort)
            }
            Toggle(title: "Reduced list", subtitle: "Name, status, context, last reply",
                   on: Settings.agentListCompact) { on in
                model.update { Settings.agentListCompact = on }
            }
            Toggle(title: "Notify when an agent finishes", on: Settings.notifyOnIdle) { on in
                model.update { Settings.notifyOnIdle = on }
            }
            Toggle(title: "Keep dashboard on screen", on: Settings.dashboardPinned) { on in
                model.update { Settings.dashboardPinned = on }
            }
        }
    }

    private var soundControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Sounds.Event.allCases, id: \.rawValue) { event in
                HStack(spacing: 6) {
                    Toggle(title: event.title, on: Sounds.isEnabled(event)) { on in
                        model.update { Sounds.setEnabled(event, on) }
                        if on { Sounds.preview(event) }
                    }
                    Spacer(minLength: 4)
                    // Picking the sound belongs here: it used to mean hand-editing
                    // config.json, so choices made elsewhere never took effect.
                    Picker("", selection: Binding(
                        get: { event.systemSound },
                        set: { name in
                            model.update { Sounds.setSound(event, name) }
                            NSSound(named: name)?.play()
                        })) {
                        ForEach(Sounds.available, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().controlSize(.small).frame(width: 108)
                    Button { Sounds.preview(event) } label: {
                        Image(systemName: "speaker.wave.2").font(.system(size: 9))
                    }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                    .help("Play \(event.systemSound)")
                    .accessibilityLabel("Play \(event.systemSound)")
                }
            }
            Text("macOS system sounds, played at your alert volume.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var refreshControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Segmented(title: "Usage",
                      options: Settings.refreshChoices.map { ("\($0)m", String($0)) },
                      current: String(Settings.refreshMinutes)) { raw in
                model.update { Settings.refreshMinutes = Int(raw) ?? 10 }
            }
            Segmented(title: "Agents",
                      options: Settings.agentScanChoices.map {
                          ($0 < 60 ? "\($0)s" : "\($0 / 60)m", String($0))
                      },
                      current: String(Settings.agentScanSeconds)) { raw in
                model.update { Settings.agentScanSeconds = Int(raw) ?? 10 }
                AgentStore.shared.intervalChanged()
            }
            Text("Quota moves over hours, agent state over seconds.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Controls

private struct Segmented: View {
    let title: String
    let options: [(String, String)]
    let current: String
    let onPick: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            HStack(spacing: 1) {
                ForEach(options, id: \.1) { option in
                    let selected = option.1 == current
                    Button { onPick(option.1) } label: {
                        Text(option.0)
                            .font(.system(size: 10.5, weight: selected ? .semibold : .regular))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(selected ? Color.accentColor.opacity(0.20) : .clear))
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title): \(option.0)")
                    .accessibilityValue(selected ? "Selected" : "Not selected")
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 6.5).fill(Color.primary.opacity(0.05)))
            Spacer()
        }
    }
}

private struct Stepper: View {
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            HStack(spacing: 1) {
                ForEach(Array(range), id: \.self) { n in
                    let selected = n == value
                    Button { onChange(n) } label: {
                        Text("\(n)")
                            .font(.system(size: 10, weight: selected ? .semibold : .regular)
                                .monospacedDigit())
                            .frame(width: 20, height: 18)
                            .background(RoundedRectangle(cornerRadius: 4)
                                .fill(selected ? Color.accentColor.opacity(0.20) : .clear))
                            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(title): \(n)")
                    .accessibilityValue(selected ? "Selected" : "Not selected")
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            Spacer()
        }
    }
}

private struct Toggle: View {
    let title: String
    var subtitle: String? = nil
    let on: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        Button { onChange(!on) } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(on ? Color.accentColor : Color.primary.opacity(0.10))
                        .frame(width: 16, height: 16)
                    if on {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 11.5))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityHint(subtitle ?? "")
    }
}
