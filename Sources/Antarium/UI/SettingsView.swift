import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    /// So a change made on the dashboard shows here too, not only the reverse.
    @ObservedObject private var settingsBus = SettingsBus.shared
    /// Only meaningful once there are enough harnesses to hunt through.
    @State private var harnessFilter = ""
    /// The host being typed into the remote tmux section, before it is added.
    @State private var newRemoteHost = ""
    /// Which host has its password field open. One at a time: a column of
    /// secure fields invites typing a password into the wrong machine's row.
    @State private var passwordHost: String?
    @State private var passwordEntry = ""
    @State private var showRemoteHelp = false

    /// Renders every section at full height instead of scrolling.
    ///
    /// The panel is capped at the screen's height so it scrolls on a small
    /// display, which is right in the app and wrong for `--settings`: the
    /// image then depends on whichever screen happened to be attached, and two
    /// runs on two machines produce different sheets with different sections
    /// missing. A preview nobody can compare is not a preview.
    var unbounded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let issue = Config.issue {
                        Label(issue, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("Settings need attention. \(issue)")
                    }
                    section("Menu Bar") { menuBarControls }
                    section("Agents") { agentControls }
                    section("Dashboard") { dashboardControls }
                    section("Remote tmux", help: Self.remoteHelp,
                            showing: $showRemoteHelp) { remoteTmuxControls }
                    section("Refresh") { refreshControls }
                    section("Sounds") { soundControls }
                    section("Harnesses") { harnessControls }
                }
                .padding(14)
            }
            // Show the whole thing where the screen allows; scroll only if not.
            .frame(maxHeight: unbounded
                ? .infinity
                : max(320, (NSScreen.main?.visibleFrame.height ?? 900) - 160))

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
            // Just the version. The config path used to be spelled out here,
            // but a fourth button left no room for both and truncation ate the
            // version instead — and the path was already redundant, since the
            // button next to it opens that exact file.
            Text("Antarium \(Self.version)")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .lineLimit(1).fixedSize()
            Spacer()
            Button("Report a bug") { NSWorkspace.shared.open(AppLinks.bugReport()) }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .help("Open a pre-filled GitHub issue")
            Button("Open") { NSWorkspace.shared.open(Config.url) }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .help("Open ~/.antarium/config.json")
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

    /// A section whose heading carries a "?" — for the ones where knowing what
    /// to type is the hard part, and a subtitle would not be enough room.
    private func section<Content: View>(_ title: String, help: String,
                                        showing: Binding<Bool>,
                                        @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .bold)).tracking(0.6)
                    .foregroundStyle(.secondary)
                Button { showing.wrappedValue.toggle() } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("How to set this up")
                .accessibilityLabel("\(title): how to set this up")
                .popover(isPresented: showing, arrowEdge: .bottom) {
                    ScrollView {
                        Text(help)
                            .font(.system(size: 11))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                    }
                    .frame(width: 380)
                    .frame(maxHeight: 420)
                }
            }
            content()
        }
    }

    static let remoteHelp = """
        Antarium runs `ssh <host>`, asks tmux what is running there, and turns \
        anything that looks like a coding agent into a row tagged \
        \(RemoteTmux.tag).

        HOW TO ONBOARD A MACHINE

        1. Check that `ssh <host>` already works from Terminal on this Mac. \
        That is the whole prerequisite. Antarium reuses your ~/.ssh/config, so \
        a Host entry carrying a port, an identity file or a jump host is \
        picked up automatically and does not need repeating here.

        2. Add the host below, written exactly as you would type it after \
        `ssh` — "quibus", "10.0.0.4", or "deploy@quibus". That is the only \
        thing you have to configure.

        3. Key authentication needs nothing further. This is the normal case, \
        and the one to prefer.

        4. Password authentication: click the key button on the host's row and \
        enter it once. It goes into your login Keychain, never into \
        ~/.antarium/config.json. It also needs sshpass on this Mac:

            brew install sshpass

        5. tmux has to be running on the far side already. Antarium only \
        looks; it never starts a session.

        WHAT YOU GET

        The agent, its project name and path, and which pane it is in. Status, \
        token counts and cost are not read over SSH — those come from \
        transcript files that stay on the remote machine — so a remote row \
        shows the machine and pane in its tooltip instead of a live status.

        IF A HOST STAYS EMPTY

        Antarium keeps the last rows it saw rather than blinking a machine out \
        of the list on one bad connection. Run with --log to see why a host \
        was skipped: a refused key, a missing sshpass, or no tmux server.
        """

    private var remoteTmuxControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle(title: "Include remote tmux agents",
                   subtitle: "Agents in tmux on other machines, over SSH",
                   on: Settings.includeRemoteTmux) { on in
                model.update { Settings.includeRemoteTmux = on }
                AgentStore.shared.refresh(force: true)
            }

            if Settings.includeRemoteTmux {
                ForEach(Settings.remoteTmuxHosts, id: \.self) { host in
                    remoteHostRow(host)
                }

                HStack(spacing: 6) {
                    TextField("host or user@host", text: $newRemoteHost)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit { addRemoteHost() }
                    Button("Add") { addRemoteHost() }
                        .font(.system(size: 11))
                        .disabled(!RemoteTmux.isSafeHost(newRemoteHost) || Settings.remoteTmuxHosts.count >= RemoteTmux.fleetLimit)
                }

                Text("Up to 256 machines. Four connections run at once; larger fleets are checked in rotating passes.")
                    .font(.system(size:10)).foregroundStyle(.secondary)
                let typed = newRemoteHost.trimmingCharacters(in: .whitespaces)
                if !typed.isEmpty, !RemoteTmux.isSafeHost(typed) {
                    // Otherwise Add simply greys out and the reason is a
                    // guessing game.
                    Text("A host is a name or address — \"quibus\", \"10.0.0.4\", "
                         + "\"deploy@quibus\". No spaces, and it cannot begin with \"-\".")
                        .font(.system(size: 10)).foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if Settings.remoteTmuxHosts.isEmpty {
                    Text("No machines yet — add one above, then press ? for how to set it up.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func remoteHostRow(_ host: String) -> some View {
        // With several machines configured, "some rows are missing" is not a
        // useful signal — you need to know which one is failing and why.
        let issue = AgentStore.shared.remoteIssues[host]
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "server.rack").font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(host).font(.system(size: 11)).lineLimit(1)
                Spacer()
                // Says which way this host authenticates without the user
                // having to remember what they set up.
                // A host edited into config.json by hand can be one the
                // scanner refuses. Showing that only in the log leaves the
                // row looking configured and simply never producing agents.
                let usable = RemoteTmux.isSafeHost(host)
                Text(!usable ? "invalid"
                             : (RemoteTmux.hasPassword(for: host) ? "password" : "key"))
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(usable ? Color.secondary.opacity(0.7) : Color.orange)
                    .padding(.horizontal, 4).padding(.vertical, 0.5)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .help(usable ? "" : "Not a usable ssh destination — it is skipped")
                Button {
                    passwordEntry = ""
                    passwordHost = passwordHost == host ? nil : host
                } label: {
                    Image(systemName: "key").font(.system(size: 10))
                        .foregroundStyle(.secondary).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Set or clear the password for \(host)")
                .accessibilityLabel("Set or clear the password for \(host)")
                Button {
                    RemoteTmux.removePassword(for: host)
                    model.update {
                        Settings.remoteTmuxHosts = Settings.remoteTmuxHosts.filter { $0 != host }
                    }
                    AgentStore.shared.refresh(force: true)
                } label: {
                    Image(systemName: "minus.circle").font(.system(size: 10))
                        .foregroundStyle(.secondary).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Stop watching \(host)")
                .accessibilityLabel("Stop watching \(host)")
            }

            if let issue {
                Text(issue)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if passwordHost == host {
                HStack(spacing: 6) {
                    SecureField("password (leave empty to clear)", text: $passwordEntry)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit { saveRemotePassword(for: host) }
                    Button("Save") { saveRemotePassword(for: host) }
                        .font(.system(size: 11))
                }
                Text(RemoteTmux.sshpassPath() == nil
                     ? "Needs sshpass on this Mac — brew install sshpass"
                     : "Stored in your login Keychain, not in the config file.")
                    .font(.system(size: 9.5))
                    .foregroundStyle(RemoteTmux.sshpassPath() == nil
                                     ? Color.orange : Color.secondary.opacity(0.7))
            }
        }
    }

    private func addRemoteHost() {
        let host = newRemoteHost.trimmingCharacters(in: .whitespaces)
        // Rejected here as well as in the scanner: a destination beginning
        // with "-" is parsed by ssh as an option, and -oProxyCommand= runs a
        // command on this Mac.
        guard !host.isEmpty, RemoteTmux.isSafeHost(host),
              Settings.remoteTmuxHosts.count < RemoteTmux.fleetLimit,
              !Settings.remoteTmuxHosts.contains(host) else { return }
        model.update { Settings.remoteTmuxHosts = Settings.remoteTmuxHosts + [host] }
        newRemoteHost = ""
        AgentStore.shared.refresh(force: true)
    }

    private func saveRemotePassword(for host: String) {
        let entry = passwordEntry
        if entry.isEmpty { RemoteTmux.removePassword(for: host) }
        else { RemoteTmux.setPassword(entry, for: host) }
        passwordEntry = ""
        passwordHost = nil
        model.update { }
        AgentStore.shared.refresh(force: true)
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
            // The state is the system's, not ours, so the toggle re-reads it
            // after the attempt: a registration macOS refuses springs the
            // switch back rather than showing a preference that is not real.
            Toggle(title: "Open at Login",
                   subtitle: "Start Antarium when you log in to this Mac",
                   on: LaunchAtLogin.isEnabled) { on in
                LaunchAtLogin.set(on)
                model.update { }
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

    /// One provider as the settings list needs it. Built once per redraw
    /// rather than asking each provider three questions from inside the loop.
    struct AgentRow: Identifiable {
        let id: String
        let name: String
        let enabled: Bool
        let detail: String
        let unverified: Bool
        /// Whether this Mac shows any sign of the agent at all.
        let present: Bool
    }

    /// Ten providers ship, and on most Macs only a few are real. Splitting the
    /// list on that means the ones you have are at the top and the rest are
    /// still there to switch on, rather than a flat list where "not signed in"
    /// is the most common line.
    static func agentRows(providers: [UsageProvider], enabled: Set<String>,
                          evidence: [AgentAutoEnable.Evidence]) -> [AgentRow] {
        let byID = Dictionary(uniqueKeysWithValues: evidence.map { ($0.id, $0) })
        return providers.map { provider in
            let found = byID[provider.id]
            let detail: String
            switch (found?.signedIn ?? false, found?.hasSessions ?? false) {
            case (true, true):   detail = "Signed in · sessions on this Mac"
            case (true, false):  detail = "Signed in"
            case (false, true):  detail = "Sessions on this Mac · " + provider.setupHint
            case (false, false): detail = provider.setupHint
            }
            return AgentRow(id: provider.id, name: provider.displayName,
                            enabled: enabled.contains(provider.id),
                            detail: detail, unverified: !provider.isVerified,
                            present: found?.present ?? false)
        }
        .sorted { ($0.present ? 0 : 1, $0.name.lowercased())
                < ($1.present ? 0 : 1, $1.name.lowercased()) }
    }

    /// "4 of 10 shown" reads the same on a Mac with four agents as on one
    /// where a fifth was found and cut: the first run enables at most
    /// `AgentAutoEnable.limit`, strongest evidence first, and says nothing
    /// about the ones it passed over. This line is the only place they are
    /// accounted for, and the only reason the user would know there is
    /// anything left to switch on.
    static func agentCountSummary(_ rows: [AgentRow]) -> String {
        let shown = rows.filter(\.enabled).count
        let waiting = rows.filter { $0.present && !$0.enabled }.count
        let base = "\(shown) of \(rows.count) shown"
        return waiting == 0 ? base : base + " · \(waiting) more found here"
    }

    private var agentControls: some View {
        let providers = ProviderRegistry.all
        let enabled = Settings.enabledAgents
        let rows = Self.agentRows(
            providers: providers, enabled: enabled,
            evidence: AgentAutoEnable.evidence(providers: providers,
                                               sessionsPresent: AgentAutoEnable.sessionsPresent()))
        let here = rows.filter(\.present)
        let elsewhere = rows.filter { !$0.present }

        return VStack(alignment: .leading, spacing: 7) {
            ForEach(here) { agentToggle($0) }
            if !elsewhere.isEmpty {
                Text(Onboarding.absent.prefix(1).uppercased() + Onboarding.absent.dropFirst())
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                ForEach(elsewhere) { agentToggle($0) }
            }
            HStack(spacing: 6) {
                Button("Detect installed agents") {
                    model.update {
                        ConfiguredProbe.invalidate()
                        AgentAutoEnable.apply(providers: ProviderRegistry.all)
                    }
                }
                .controlSize(.small)
                .help("Switch on every agent that is signed in or has sessions on this Mac, and switch off the rest.")
                Spacer()
                Text(Self.agentCountSummary(rows))
                    .font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
            .padding(.top, 2)
        }
    }

    private func agentToggle(_ row: AgentRow) -> some View {
        Toggle(title: row.name + (row.unverified ? " · unverified" : ""),
               subtitle: row.detail,
               on: row.enabled) { on in
            model.update {
                var set = Settings.enabledAgents
                if on { set.insert(row.id) } else { set.remove(row.id) }
                // Never leave an empty menu bar — there'd be no way back.
                if !set.isEmpty { Settings.enabledAgents = set }
            }
        }
        .help(row.unverified
            ? "\(row.name): the mapping is checked against a recorded response, but the figures have not been confirmed against a live account."
            : row.detail)
    }

    private var dashboardControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Segmented(title: "Sort", options: AgentSort.allCases.map { ($0.title, $0.rawValue) },
                      current: Settings.agentSort.rawValue) { raw in
                model.update { Settings.agentSort = AgentSort(rawValue: raw) ?? .name }
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
                        Text(verbatim: "\(n)")
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
