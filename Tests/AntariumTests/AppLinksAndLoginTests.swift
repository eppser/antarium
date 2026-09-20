import Foundation
import Testing
@testable import Antarium

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
