import AppKit

/// Coordinates one `AgentItem` per enabled agent.
///
/// Cost profile: a single 60-second timer (60s tolerance) shared by every
/// agent, one network request per agent per refresh interval, and a redraw
/// only when the rendered content actually changes. Enabling a second agent
/// adds a request, not a wakeup source.
@MainActor
final class AppController: NSObject {

    private var items: [AgentItem] = []
    private var countItem: CountItem?
    private var timer: Timer?

    func start() {
        Config.migrateFromUserDefaults()
        // Before anything is seeded into it: the settings directory holds
        // credentials now, and every local account on a Mac is in `staff`.
        // The settings panel shows this too. Logged as well because a
        // launch is when it starts mattering, and a log is what somebody
        // reads afterwards to work out why nothing was being saved.
        if let issue = Config.issue { Log.warn("config", issue) }
        // Secured in main.swift now, before any entry point reads the
        // folder — the app was the only one doing it, and a folder that
        // already existed stayed open through every command.
        // Ship the harnesses into the folder people actually edit, and keep
        // untouched ones current. Runs before anything reads them.
        HarnessDescriptor.seed()
        // Nothing is shown by default any more: the first launch that finds no
        // recorded choice picks the agents this Mac actually has. Must follow
        // the seed, or descriptor-contributed providers would not exist yet.
        let providers = ProviderRegistry.all
        if AgentAutoEnable.applyIfNeeded(providers: providers) == nil {
            // A choice exists, so it stands — except for agents that did not
            // exist when it was made, which the user has never been asked about.
            AgentAutoEnable.adoptNewProviders(providers: providers)
        }
        rebuildItems()
        // Warm the agent picture in the background so the dashboard opens full.
        AgentStore.shared.onRowsChanged = { [weak self] rows in
            self?.countItem?.update(with: rows)
        }
        applyCountItem()
        AgentStore.shared.start()
        items.first?.restorePinnedDashboard()
        showOnboardingIfNeeded()

        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.items.forEach { $0.tick() } }
        }
        t.tolerance = 15
        RunLoop.main.add(t, forMode: .common)   // .common so it survives menu tracking
        timer = t

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(appearanceChanged),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appearanceChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// First launch only: show what was detected, ask nothing.
    private var onboardingPanel: NSPanel?

    func showOnboardingIfNeeded() {
        guard !Onboarding.hasRun else { return }
        let panel = PanelChrome.makePanel()
        onboardingPanel = panel
        let providers = items.map(\.provider)
        let view = OnboardingView(
            harnesses: Onboarding.harnesses(),
            accounts: Onboarding.accounts(providers),
            sessions: AgentStore.shared.rows.isEmpty ? nil : AgentStore.shared.rows.count,
            onDone: { [weak self] in
                Onboarding.complete()
                self?.onboardingPanel?.orderOut(nil)
                self?.onboardingPanel = nil
            })
        let hosting = PanelChrome.host(view, in: panel)
        hosting.layoutSubtreeIfNeeded()
        panel.setContentSize(hosting.fittingSize)
        panel.center()
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Adds or removes the AGENTS count item to match the setting.
    func applyCountItem() {
        if Settings.showAgentCount, countItem == nil {
            countItem = CountItem(
                onClick: { [weak self] in self?.items.first?.toggleDashboard() },
                onRightClick: { [weak self] in self?.items.first?.showSettingsMenu() })
            countItem?.update(with: AgentStore.shared.rows)
            DispatchQueue.main.async { [weak self] in self?.countItem?.forceRender() }
        } else if !Settings.showAgentCount {
            countItem?.dispose()
            countItem = nil
        }
    }

    func stop() {
        AgentStore.shared.stop()
        countItem?.dispose()
        timer?.invalidate()
        items.forEach { $0.dispose() }
        items.removeAll()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Membership

    /// Adds and removes items to match the enabled set, leaving untouched
    /// agents alone so their readings and menu bar positions survive.
    /// What has to change for the items to match the enabled set.
    ///
    /// Pure, because disposing an item is not what stops it working: the
    /// coordinator ticks everything in `items` once a minute, so an item
    /// disposed and left in the list goes on fetching — contacting the
    /// service and sending its credential — with no menu bar item to show
    /// for it. Removing it from the list is the part that matters and the
    /// part that had no test.
    static func membership(current: [String], wanted: [String])
        -> (remove: [String], add: [String]) {
        let wantedSet = Set(wanted), currentSet = Set(current)
        return (current.filter { !wantedSet.contains($0) },
                wanted.filter { !currentSet.contains($0) })
    }

    /// Menu bar order follows the registry, so items keep the same
    /// left-to-right positions between launches rather than the order the
    /// user happened to switch them on in.
    static func ordered(_ ids: [String], by registry: [String]) -> [String] {
        ids.sorted { (registry.firstIndex(of: $0) ?? 0) < (registry.firstIndex(of: $1) ?? 0) }
    }

    private func rebuildItems() {
        let wanted = ProviderRegistry.enabled
        let change = Self.membership(current: items.map(\.provider.id),
                                     wanted: wanted.map(\.id))
        let removing = Set(change.remove)

        for item in items where removing.contains(item.provider.id) { item.dispose() }
        items.removeAll { removing.contains($0.provider.id) }

        let adding = Set(change.add)
        for provider in wanted where adding.contains(provider.id) {
            items.append(AgentItem(provider: provider, coordinator: self))
        }
        let order = Self.ordered(items.map(\.provider.id), by: ProviderRegistry.all.map(\.id))
        items.sort { (order.firstIndex(of: $0.provider.id) ?? 0)
                   < (order.firstIndex(of: $1.provider.id) ?? 0) }
    }


    func styleChanged() { items.forEach { $0.forceRender() } }

    /// A settings change can alter the gauges, the count item, or both.
    func settingsChanged() {
        SettingsBus.shared.changed()
        applyCountItem()
        items.first?.applyPinnedState()
        rebuildItems()
        items.forEach { $0.forceRender() }
        countItem?.update(with: AgentStore.shared.rows)
    }

    func intervalChanged() { items.forEach { $0.intervalChanged() } }

    /// Both readings, not one. The gauges refreshed on wake from the first
    /// version of this; the rows did not, and stale rows beside current
    /// gauges is a worse answer than both arriving a moment late.
    @objc private func didWake() {
        items.forEach { $0.refresh(reason: .wake) }
        AgentStore.shared.wake()
    }

    /// Dynamic colours are baked in at draw time, so a theme or display change
    /// needs an explicit redraw.
    @objc private func appearanceChanged() {
        items.forEach { $0.forceRender() }
        countItem?.forceRender()
    }
}
