import AppKit
import SwiftUI
import ServiceManagement

/// One agent, one menu bar item: its own status item, poll schedule and menu.
///
/// The coordinator drives `tick()`; nothing in here owns a timer, so adding an
/// agent doesn't add a wakeup source.
@MainActor
final class AgentItem: NSObject, NSMenuDelegate {

    enum State {
        case loading
        case ready(Snapshot)
        case failed(ProviderError, last: Snapshot?)

        var snapshot: Snapshot? {
            switch self {
            case .ready(let s): return s
            case .failed(_, let s): return s
            case .loading: return nil
            }
        }
    }

    let provider: UsageProvider
    private weak var coordinator: AppController?

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    private var state: State = .loading
    private var lastRender: StatusRender?
    private var inFlight = false
    private var settings: SettingsPanel { .shared }

    @objc private func openSettings() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.settings.toggle(under: self.statusItem.button) { [weak self] in
                self?.coordinator?.settingsChanged()
            }
        }
    }

    private var dashboard: DashboardPanel {
        let panel = DashboardPanel.shared
        // Idempotent: the shared panel takes the same closure whichever item
        // reaches it first.
        panel.onVisibilityChange = { visible in AgentStore.shared.setVisible(visible) }
        return panel
    }

    @objc private func statusItemClicked() {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
            || NSApp.currentEvent?.modifierFlags.contains(.control) == true
        if isRightClick { showMenu() } else { toggleDashboard() }
    }

    func toggleDashboard() {
        dashboard.toggle(relativeTo: statusItem.button) { [weak self] in
            self?.showSettingsFromDashboard()
        }
    }

    /// Reopen a pinned dashboard after a relaunch.
    func restorePinnedDashboard() { applyPinnedState() }

    /// Brings the dashboard into line with the setting.
    ///
    /// Turning "keep on screen" on used to change the config and nothing else —
    /// it only took effect on the next launch, which reads as the setting not
    /// working at all.
    func applyPinnedState() {
        guard Settings.dashboardPinned else { return }
        dashboard.show(relativeTo: statusItem.button) { [weak self] in
            self?.showSettingsFromDashboard()
        }
    }

    /// The gear on the dashboard opens settings, which is what a gear means.
    /// It used to raise the right-click menu, so the panel was two clicks away
    /// from the button that looks like it.
    private func showSettingsFromDashboard() {
        if !Settings.dashboardPinned { dashboard.close() }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.settings.toggle(under: self.statusItem.button) { [weak self] in
                self?.coordinator?.settingsChanged()
            }
        }
    }

    /// Lets other surfaces (the count item) open this item's settings menu.
    func showSettingsMenu() { showMenu() }

    private func showMenu() {
        rebuildMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private var nextFetch = Date.distantPast
    private var consecutiveFailures = 0
    /// Last reading, for spotting a crossing rather than a standing state.
    private var previousGauges: [String: Gauge] = [:]

    init(provider: UsageProvider, coordinator: AppController) {
        self.provider = provider
        self.coordinator = coordinator
        super.init()

        statusItem.button?.imagePosition = .imageOnly
        // Remembers where the user ⌘-dragged this item to.
        statusItem.autosaveName = "Antarium.\(provider.id)"
        menu.delegate = self
        menu.autoenablesItems = false
        // Left click opens the agent dashboard, right click the settings menu.
        // `statusItem.menu` is left unset so clicks reach us at all; it's
        // attached only for the moment the menu is being shown.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // Banners hang from whichever item was created first.
        if AgentAlert.shared.anchor == nil { AgentAlert.shared.anchor = statusItem.button }
        renderWhenAttached()

        render()
        refresh(reason: .launch)
    }

    /// Removing the status item is what takes it out of the menu bar.
    func dispose() {
        QuotaStore.shared.remove(providerID: provider.id)
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: - Poll loop

    enum Reason { case launch, timer, wake, manual }

    /// Called once a minute by the coordinator.
    func tick() {
        if Date() >= nextFetch { refresh(reason: .timer) }
        render()   // keeps the countdown text honest between fetches
    }

    func refresh(reason: Reason) {
        guard !inFlight else { return }
        if reason == .manual { consecutiveFailures = 0 }

        guard provider.isConfigured else {
            state = .failed(.notConfigured("\(provider.displayName) isn't set up on this Mac."),
                            last: state.snapshot)
            scheduleNext(success: false)
            render()
            return
        }

        inFlight = true
        let provider = self.provider
        Task { @MainActor in
            defer { self.inFlight = false }
            do {
                let snapshot = try await provider.fetch()
                self.noticeQuotaCrossings(in: snapshot)
                self.state = .ready(snapshot)
                self.consecutiveFailures = 0
                self.scheduleNext(success: true, snapshot: snapshot)
            } catch {
                let err = (error as? ProviderError) ?? .transport(error.localizedDescription)
                self.consecutiveFailures += 1
                self.state = .failed(err, last: self.state.snapshot)
                self.scheduleNext(success: false)
            }
            self.render()
        }
    }

    /// Which sounds a reading earns, at most one of each.
    ///
    /// A response may carry many windows, and several crossing at once is one
    /// event to a listener rather than several — firing per gauge is a burst
    /// of identical chirps.
    static func crossings(from previous: [String: Gauge],
                          to current: [Gauge]) -> (critical: Bool, rolledOver: Bool) {
        var critical = false
        var rolledOver = false
        for gauge in current {
            guard let was = previous[gauge.id] else { continue }
            if was.severity != .critical, gauge.severity == .critical { critical = true }
            // A window that rolled over: its reset moved later and headroom
            // jumped back up.
            if let old = was.resetsAt, let new = gauge.resetsAt,
               new > old, gauge.remaining > was.remaining + 0.2 {
                rolledOver = true
            }
        }
        return (critical, rolledOver)
    }

    /// Sounds fire on a *transition*, never on a standing state — otherwise a
    /// spent quota would chirp on every poll. Nothing fires on the first
    /// reading, when there is nothing to compare against.
    private func noticeQuotaCrossings(in snapshot: Snapshot) {
        defer {
            previousGauges = Dictionary(snapshot.gauges.map { ($0.id, $0) },
                                        uniquingKeysWith: { a, _ in a })
        }
        guard !previousGauges.isEmpty else { return }

        // At most one of each sound per reading. A response may carry many
        // windows, and several crossing at once is one event to a listener,
        // not several — playing it per gauge is a burst of identical chirps.
        let crossed = Self.crossings(from: previousGauges, to: snapshot.gauges)
        if crossed.critical { Sounds.play(.budgetCritical) }
        if crossed.rolledOver { Sounds.play(.quotaReset) }
    }

    /// When to look again. Pure, so the one place a response decides when the
    /// app *acts* rather than what it shows can be tested without a timer.
    ///
    /// If a window rolls over sooner than the refresh interval, look again
    /// just after it does — that is the moment the number the user cares
    /// about jumps. The reset time comes from the server, though, so a window
    /// reported as resetting a second from now, on every reading, would pull
    /// the next poll to twenty-one seconds out for as long as the server kept
    /// saying it: the user's refresh interval replaced by the endpoint's.
    /// Never sooner than `minimumPollInterval`.
    static func nextPoll(after now: Date, interval: TimeInterval,
                         resets: [Date]) -> Date {
        var next = now.addingTimeInterval(interval)
        let floor = now.addingTimeInterval(minimumPollInterval)
        for reset in resets {
            let after = reset.addingTimeInterval(20)
            // A reset already behind us says nothing about when to look next.
            // Flooring first would lift every stale date into a valid poll,
            // which is how a response full of yesterday's timestamps became a
            // reason to fetch a minute from now.
            guard after > now else { continue }
            let candidate = max(after, floor)
            if candidate < next { next = candidate }
        }
        return next
    }

    /// The soonest a reported reset may pull the next poll. Long enough that
    /// a server cannot set the refresh rate, short enough that a real window
    /// rollover — minutes or hours away — is unaffected.
    static let minimumPollInterval: TimeInterval = 60

    private func scheduleNext(success: Bool, snapshot: Snapshot? = nil) {
        let interval = TimeInterval(Settings.refreshMinutes * 60)
        guard success else {
            // Back off, but never past the normal interval.
            nextFetch = Date().addingTimeInterval(
                min(interval, pow(2, Double(min(consecutiveFailures, 4))) * 60))
            return
        }
        nextFetch = Self.nextPoll(after: Date(), interval: interval,
                                  resets: (snapshot?.gauges ?? []).compactMap(\.resetsAt))
    }

    /// Pull the next poll into line with a changed interval, without firing now.
    func intervalChanged() {
        let anchor = state.snapshot?.fetchedAt ?? Date()
        nextFetch = min(nextFetch, anchor.addingTimeInterval(TimeInterval(Settings.refreshMinutes * 60)))
    }

    // MARK: - Rendering

    private var appearance: NSAppearance {
        statusItem.button?.window?.effectiveAppearance
            ?? statusItem.button?.effectiveAppearance
            ?? NSApp.effectiveAppearance
    }
    private var scale: CGFloat {
        statusItem.button?.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    func forceRender() {
        lastRender = nil
        render()
    }

    /// The menu bar's appearance is unknowable until the button joins a window,
    /// which happens after init returns. Redraw once it has — otherwise a
    /// freshly created item bakes in black text and keeps it until something
    /// else forces a redraw. This is what made the counts black after the
    /// item was switched off and on again.
    private func renderWhenAttached(_ attempts: Int = 8) {
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.forceRender()
            if self.statusItem.button?.window == nil {
                self.renderWhenAttached(attempts - 1)
            }
        }
    }

    private func render() {
        publishQuota()
        let next = makeRender()
        guard next != lastRender else { return }
        lastRender = next
        statusItem.button?.image = Renderer.image(next, appearance: appearance, scale: scale)
        statusItem.button?.toolTip = tooltip()
    }

    private func publishQuota() {
        switch state {
        case .loading:
            QuotaStore.shared.set(providerID: provider.id, snapshot: nil)
        case .ready(let snapshot):
            QuotaStore.shared.set(providerID: provider.id, snapshot: snapshot)
        case .failed(let error, let last):
            QuotaStore.shared.set(providerID: provider.id, error: error, last: last)
        }
    }

    private func makeRender() -> StatusRender {
        switch state {
        case .loading:
            return StatusRender(agentID: provider.id, rows: [], message: "···")
        case .ready(let s):
            return StatusRender(agentID: provider.id, rows: StatusRender.rows(for: s), message: nil, stale: false)
        case .failed(let err, let last):
            if let last {
                return StatusRender(agentID: provider.id, rows: StatusRender.rows(for: last), message: nil, stale: true)
            }
            return StatusRender(agentID: provider.id, rows: [], message: err.badge)
        }
    }

    /// One tooltip line. A balance has no "used" and no "left" to report, so
    /// it states the figure instead of inventing both halves of a percentage.
    private static func line(_ g: Gauge) -> String {
        if let amount = g.amountText { return "\(g.title): \(amount) left" }
        return "\(g.title): \(g.usedPercentText) used, \(g.remainingPercentText) left"
    }

    private func tooltip() -> String {
        switch state {
        case .loading:
            return "\(provider.displayName) — checking…"
        case .ready(let s):
            let lines = (s.gauges + s.extras).map(Self.line)
            return ([provider.displayName] + lines).joined(separator: "\n")
        case .failed(let e, let last):
            guard let last else {
                return "\(provider.displayName) — \(e.errorDescription ?? "error")"
            }
            let lines = (last.gauges + last.extras).map(Self.line)
            return ([provider.displayName + " — as of " + Format.age(last.fetchedAt)]
                + lines + ["Last refresh failed: \(e.errorDescription ?? "error")"])
                .joined(separator: "\n")
        }
    }

    // MARK: - Menu

    func menuWillOpen(_ menu: NSMenu) {
        // `showMenu` prepared the complete item tree before AppKit began
        // tracking it. Removing and reinserting rows here (or after a refresh)
        // gives later items zero-sized layout frames on some macOS releases.
        // A completed refresh is reflected the next time this transient menu
        // opens; the menu-bar gauge itself still redraws immediately.
        // Opening the menu is an explicit "where am I?" — top up a cold reading,
        // but never hammer the endpoint.
        if Date().timeIntervalSince(state.snapshot?.fetchedAt ?? .distantPast) > 60 {
            refresh(reason: .manual)
        }
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        menu.addItem(headerItem())
        menu.addItem(.separator())

        switch state {
        case .loading:
            menu.addItem(infoItem("Checking usage…"))
        case .ready(let s):
            addGauges(s, stale: false)
        case .failed(let err, let last):
            if let last {
                addGauges(last, stale: true)
                menu.addItem(.separator())
            }
            menu.addItem(problemItem(err))
            // The whole point of the badge is that the credential went stale;
            // making the user go and find the right command defeats it.
            if let command = provider.signInCommand, err.suggestsSignIn {
                menu.addItem(action("Sign in to \(provider.displayName)…",
                                    #selector(signInAgain)))
                signInCommand = command
            }
        }
        if !provider.isVerified {
            menu.addItem(infoItem("Unverified integration — see README."))
        }

        menu.addItem(.separator())
        menu.addItem(infoItem("Updated \(Format.age(state.snapshot?.fetchedAt))"))
        menu.addItem(action("Refresh Now", #selector(refreshNow), key: "r", enabled: !inFlight))

        menu.addItem(.separator())
        menu.addItem(action("Agents on this Mac…", #selector(openDashboard), key: "a"))

        menu.addItem(.separator())
        menu.addItem(action("Settings…", #selector(openSettings), key: ","))

        let login = action("Open at Login", #selector(toggleLogin))
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Antarium", action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.isEnabled = true
        menu.addItem(quit)
    }

    private func action(_ title: String, _ selector: Selector,
                        key: String = "", enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        return item
    }

    private func addGauges(_ s: Snapshot, stale: Bool) {
        for (i, gauge) in s.gauges.enumerated() {
            menu.addItem(gaugeItem(gauge, stale: stale, row: i))
        }
        // A zero balance is a reading, not an absence — the filter is about
        // hiding windows that were never touched, which a balance never is.
        for extra in s.extras where extra.used > 0 || !extra.hasMeter {
            menu.addItem(gaugeItem(extra, stale: stale, row: 1))
        }
    }

    // MARK: - Menu item factories

    private func gaugeItem(_ g: Gauge, stale: Bool, row: Int) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = true
        if g.hasMeter {
            item.image = Renderer.chip(fill: Settings.meterMode == .used ? g.used : g.remaining,
                                       severity: g.severity, agentID: provider.id, row: row,
                                       appearance: NSApp.effectiveAppearance, scale: scale)
        }
        let title = NSMutableAttributedString(
            string: g.title + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                         .foregroundColor: stale ? NSColor.secondaryLabelColor : NSColor.labelColor])
        // Both framings, always — this is where "is 75% good or bad?" gets settled.
        let detail = g.amountText.map { "\($0) left · \(Format.longReset(g.resetsAt))" }
            ?? "\(g.usedPercentText) used · \(g.remainingPercentText) left · \(Format.longReset(g.resetsAt))"
        title.append(NSAttributedString(
            string: detail,
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        item.attributedTitle = title
        return item
    }

    private func headerItem() -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        let s = NSMutableAttributedString(
            string: provider.displayName,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                         .foregroundColor: NSColor.labelColor])
        if let account = state.snapshot?.accountLabel {
            s.append(NSAttributedString(
                string: "  \(account)",
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        item.attributedTitle = s
        return item
    }

    private func infoItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor])
        return item
    }

    private func problemItem(_ err: ProviderError) -> NSMenuItem {
        let item = NSMenuItem()
        item.isEnabled = false
        let s = NSMutableAttributedString(
            string: (err.errorDescription ?? "Couldn't read usage.") + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                         .foregroundColor: NSColor.systemRed])
        let hint: String
        switch err {
        case .needsAuth, .notConfigured, .unsupported: hint = provider.setupHint
        case .accessDenied:
            hint = "Open Keychain Access, select the agent's credential item, "
                 + "and allow Antarium under Access Control."
        case .transport:   hint = "Will retry automatically."
        case .badResponse: hint = "The usage API returned something unexpected."
        }
        s.append(NSAttributedString(
            string: hint,
            attributes: [.font: NSFont.systemFont(ofSize: 11),
                         .foregroundColor: NSColor.secondaryLabelColor]))
        item.attributedTitle = s
        return item
    }

    private func submenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.isEnabled = true
        let sub = NSMenu()
        sub.autoenablesItems = false
        items.forEach(sub.addItem)
        parent.submenu = sub
        return parent
    }

    // MARK: - Actions

    @objc private func openDashboard() {
        DispatchQueue.main.async { [weak self] in self?.toggleDashboard() }
    }

    /// Captured when the item is built, so the action does not have to re-ask
    /// a provider that may since have started refreshing.
    private var signInCommand: String?

    @objc private func signInAgain() {
        guard let command = signInCommand else { return }
        SignIn.launch(command, label: provider.displayName)
    }

    @objc private func refreshNow() {
        // Picks up hand-edits to config.json without a restart.
        Config.reload()
        coordinator?.styleChanged()
        refresh(reason: .manual)
    }

    @objc private func toggleLogin() { LaunchAtLogin.toggle() }
}
