import Foundation
import Testing
@testable import Antarium

@MainActor
struct AppLinksAndLoginTests {

    @Test("The bug link points at this project's issue tracker")
    func bugReportURLTargetsTheRepository() {
        let url = AppLinks.bugReport(version: "0.1", system: "26.0.0",
                                     architecture: "Apple silicon")
        #expect(url.absoluteString.hasPrefix("https://github.com/eppser/antarium/issues/new"))
        // https, and github.com exactly — not a look-alike host.
        #expect(url.scheme == "https")
        #expect(url.host == "github.com")
    }

    @Test("The report is pre-filled with what a maintainer needs")
    func bugReportCarriesTheDiagnosticFacts() {
        let url = AppLinks.bugReport(version: "0.1", system: "26.0.0",
                                     architecture: "Apple silicon")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let body = items.first { $0.name == "body" }?.value ?? ""
        #expect(items.first { $0.name == "labels" }?.value == "bug")
        #expect(body.contains("Antarium 0.1"))
        #expect(body.contains("macOS 26.0.0"))
        #expect(body.contains("Apple silicon"))
    }

    @Test("The report carries nothing that identifies the machine or its user")
    func bugReportLeaksNothingPrivate() {
        // A GitHub issue is a public document, and this app knows the user's
        // home directory, their project paths and the machines they ssh to.
        // None of that may travel with a bug report.
        let url = AppLinks.bugReport()
        // Scoped to the body, not the whole URL: the path legitimately carries
        // the repository owner's name, and a short username ("se") appears by
        // coincidence inside "issues" and "eppser". Substring-matching the
        // whole URL reports a leak that is not there and hides one that is.
        let body = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "body" }?.value ?? ""
        #expect(!body.isEmpty)
        #expect(!body.contains(FileManager.default.homeDirectoryForCurrentUser.path))
        #expect(!body.contains("/Users/"))
        #expect(!body.contains(NSUserName()))
        #expect(!body.contains(ProcessInfo.processInfo.hostName))
        // No filesystem path of any kind, and no user@host.
        #expect(!body.contains("/"))
        #expect(!body.contains("@"))
        // Nothing from the remote-tmux configuration either.
        #expect(!body.lowercased().contains("remotetmux"))
        #expect(!body.lowercased().contains("keychain"))
    }

    @Test("Special characters in the body survive as a usable URL")
    func bugReportEncodesItsBody() {
        // The body contains an HTML comment, newlines and a middot. If any of
        // those escaped unencoded the link would break on click, which is the
        // one thing a bug-report button must not do.
        let url = AppLinks.bugReport(version: "0.1 (beta)", system: "26.0",
                                     architecture: "Apple silicon")
        #expect(!url.absoluteString.contains(" "))
        #expect(!url.absoluteString.contains("\n"))
        #expect(!url.absoluteString.contains("<"))
        // Still parseable, and still carrying the version through encoding.
        let body = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "body" }?.value ?? ""
        #expect(body.contains("0.1 (beta)"))
    }

    @Test("Both surfaces open the same link")
    func oneDefinitionForEverySurface() {
        // The dashboard and the settings panel each call AppLinks.bugReport();
        // pinning it here is what stops one of them drifting.
        #expect(AppLinks.bugReport(version: "1", system: "2", architecture: "3")
                == AppLinks.bugReport(version: "1", system: "2", architecture: "3"))
        #expect(AppLinks.repository.absoluteString == "https://github.com/eppser/antarium")
    }

    @Test("Open at Login reports the system's state, not a stored preference")
    func launchAtLoginReadsTheSystem() {
        // Reading it back from config.json would let the two disagree after a
        // change made in System Settings. This must be a live read.
        let observed = LaunchAtLogin.isEnabled
        #expect(observed == LaunchAtLogin.isEnabled)
        // It is not backed by our settings file at all.
        #expect(Config.bool("launchAtLogin") == nil)
    }

    @Test("Setting Open at Login to what it already is changes nothing")
    func launchAtLoginIsIdempotent() {
        // The no-op path must not call register()/unregister() at all: doing so
        // repeatedly is how a login item ends up duplicated or revoked.
        let before = LaunchAtLogin.isEnabled
        #expect(LaunchAtLogin.set(before))
        #expect(LaunchAtLogin.isEnabled == before)
    }
}

/// Which menu bar items exist, and in what order. Disposing an item is not
/// what stops it working — the coordinator ticks everything still in the
/// list once a minute, so an item disposed and left there goes on fetching,
/// contacting the service and sending its credential, with nothing on screen
/// to show for it. Three mutations of this survived before these existed.
@Suite("Menu bar membership follows the enabled set")
@MainActor
struct MenuBarMembershipTests {

    @Test("Switching an agent off removes it from the list, not just the bar")
    func disabledIsRemoved() {
        let change = AppController.membership(current: ["a", "b", "c"], wanted: ["a", "c"])
        #expect(change.remove == ["b"])
        #expect(change.add.isEmpty)
    }

    @Test("Switching an agent on adds it")
    func enabledIsAdded() {
        let change = AppController.membership(current: ["a"], wanted: ["a", "b"])
        #expect(change.add == ["b"])
        #expect(change.remove.isEmpty)
    }

    /// An agent that was already there is left alone, so its reading and its
    /// position survive a settings change that had nothing to do with it.
    @Test("An unchanged agent is neither added nor removed")
    func untouchedIsLeftAlone() {
        let change = AppController.membership(current: ["a", "b"], wanted: ["b", "a"])
        #expect(change.remove.isEmpty)
        #expect(change.add.isEmpty)
    }

    @Test("Switching everything off removes everything")
    func allDisabled() {
        let change = AppController.membership(current: ["a", "b"], wanted: [])
        #expect(change.remove == ["a", "b"])
    }

    @Test("A first run adds everything and removes nothing")
    func firstRun() {
        let change = AppController.membership(current: [], wanted: ["a", "b"])
        #expect(change.add == ["a", "b"])
        #expect(change.remove.isEmpty)
    }

    /// The order is the registry's, not the order the user switched things
    /// on in, so items keep their left-to-right positions between launches.
    @Test("Items are ordered by the registry, whatever order they arrived in")
    func registryOrder() {
        let registry = ["claude-code", "codex", "cursor", "copilot"]
        #expect(AppController.ordered(["copilot", "claude-code", "cursor"], by: registry)
                == ["claude-code", "cursor", "copilot"])
        // And the same input twice gives the same answer.
        #expect(AppController.ordered(["cursor", "copilot"], by: registry)
                == AppController.ordered(["copilot", "cursor"], by: registry))
    }

    @Test("An id the registry does not know does not crash the ordering")
    func unknownIdIsTolerated() {
        let ordered = AppController.ordered(["ghost", "codex"], by: ["claude-code", "codex"])
        #expect(ordered.count == 2)
    }

    /// Where it goes, which the test above only counted.
    ///
    /// `ProviderRegistry.all` is a computed property that re-reads the
    /// descriptor folder, and `rebuildItems` calls it twice — once for the
    /// items it wants and once for the order. A harness file edited between
    /// those two reads leaves an item whose id the second read no longer
    /// knows, which is the state this covers.
    @Test("An unrecognised id goes last, not first")
    func unknownIdSortsLast() {
        #expect(AppController.ordered(["ghost", "codex"], by: ["claude-code", "codex"])
                == ["codex", "ghost"])
        #expect(AppController.ordered(["ghost", "claude-code"], by: ["claude-code", "codex"])
                == ["claude-code", "ghost"])
    }

    /// Two ids the registry does not know tie on the only key the order has,
    /// and Swift's sort is not stable — so the menu bar rearranges itself
    /// between launches with nothing about the machine having changed, which
    /// is the one thing this function exists to prevent.
    @Test("Ids that tie still come back in one order")
    func tiesAreTotal() {
        let registry = ["claude-code", "codex"]
        let ids = ["ghost", "phantom", "wraith", "spectre", "shade", "revenant"]
        let wanted = AppController.ordered(ids, by: registry)
        for _ in 0..<25 {
            #expect(AppController.ordered(ids.shuffled(), by: registry) == wanted,
                    "unknown ids came back in a different order")
        }
    }
}

/// A reading outlives its item unless something removes it. Disposing a
/// disabled agent drops its stored snapshot, or the dashboard and the count
/// item go on reporting figures for an agent the user switched off — the
/// same shape as a remote row outliving the host that answered it.
@Suite("A disabled agent leaves no reading behind", .serialized)
@MainActor
struct QuotaStoreRemovalTests {

    private func snapshot(_ id: String) -> Snapshot {
        Snapshot(providerID: id,
                 gauges: [Gauge(id: "w", badge: "W", title: "Window",
                                used: 0.5, resetsAt: nil, reportedSeverity: .normal)],
                 extras: [], accountLabel: nil, fetchedAt: Date())
    }

    @Test("A stored reading is readable, and removing it takes it away")
    func removeDropsTheReading() {
        let store = QuotaStore.shared
        let id = "removal-fixture-\(UUID().uuidString)"
        store.set(providerID: id, snapshot: snapshot(id))
        #expect(store.snapshot(for: id) != nil, "nothing was stored, so the removal proves nothing")
        store.remove(providerID: id)
        #expect(store.snapshot(for: id) == nil, "a switched-off agent kept its figures")
    }

    @Test("Removing one agent leaves the others alone")
    func removalIsNarrow() {
        let store = QuotaStore.shared
        let kept = "kept-\(UUID().uuidString)", dropped = "dropped-\(UUID().uuidString)"
        store.set(providerID: kept, snapshot: snapshot(kept))
        store.set(providerID: dropped, snapshot: snapshot(dropped))
        store.remove(providerID: dropped)
        #expect(store.snapshot(for: kept) != nil, "removing one agent took another with it")
        store.remove(providerID: kept)
    }

    @Test("Removing an agent that was never stored is harmless")
    func removingUnknownIsSafe() {
        QuotaStore.shared.remove(providerID: "never-stored-\(UUID().uuidString)")
    }
}
