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
    private func rebuildItems() {
        let wanted = ProviderRegistry.enabled
        let wantedIDs = Set(wanted.map(\.id))

        for item in items where !wantedIDs.contains(item.provider.id) { item.dispose() }
        items.removeAll { !wantedIDs.contains($0.provider.id) }

        for provider in wanted where !items.contains(where: { $0.provider.id == provider.id }) {
            items.append(AgentItem(provider: provider, coordinator: self))
        }
        // Keep registry order so the row reads consistently.
        items.sort { a, b in
            let order = ProviderRegistry.all.map(\.id)
            return (order.firstIndex(of: a.provider.id) ?? 0) < (order.firstIndex(of: b.provider.id) ?? 0)
        }
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

    @objc private func didWake() { items.forEach { $0.refresh(reason: .wake) } }

    /// Dynamic colours are baked in at draw time, so a theme or display change
    /// needs an explicit redraw.
    @objc private func appearanceChanged() {
        items.forEach { $0.forceRender() }
        countItem?.forceRender()
    }
}
