import Foundation
import Testing
@testable import Antarium

/// A flag nothing stated is not a flag that is off.
///
/// Two rules read the flags in a quota reply, and they want opposite things
/// from an absent one. `require` decides whether a window is drawn at all, and
/// `unlimited: false` has to mean what it says rather than rejecting every
/// window that does not mention being unlimited — so absent has to read as
/// false there, and that was argued when the rule was written.
///
/// `criticalWhen` decides whether a gauge is painted as spent, which is an
/// assertion about somebody's account. It was reading an absent flag as false
/// too, so a reply that omitted `is_available` altogether marked every DeepSeek
/// balance critical on evidence that did not exist. Every fixture case stated
/// the field, which is why nothing saw it.
///
/// Replies are built by parsing JSON rather than as Swift dictionaries, and
/// that is not tidiness. `0 as? Bool` is nil for a Swift `Int` and false for
/// the `NSNumber` that `JSONSerialization` hands back — so a suite written with
/// literals would agree with itself about numeric flags and say nothing about
/// the values a real endpoint sends. The first draft of this file did exactly
/// that and passed for the wrong reason.
@Suite("An unstated flag is distinct from a flag that is off")
struct UnstatedFlagTests {

    private func reply(_ json: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// DeepSeek's shape: balances in a list, the flag stated once beside them.
    private func deepseek(_ json: String) throws -> Snapshot {
        let descriptor = try #require(HarnessCLI.bundledDescriptors().first { $0.id == "deepseek" })
        let provider = try #require(DescriptorProvider(descriptor))
        return try provider.makeSnapshot(try reply(json))
    }

    private let balances = #""balance_infos":[{"currency":"USD","total_balance":"12.50"},"#
        + #"{"currency":"CNY","total_balance":"80.00"}]"#

    /// The bug, stated as the reply that caused it.
    @Test("A reply that states no availability marks nothing critical")
    func unstatedIsNotCritical() throws {
        let snapshot = try deepseek("{\(balances)}")
        #expect(snapshot.gauges.count == 2)
        for gauge in snapshot.gauges {
            #expect(gauge.reportedSeverity != .critical,
                    Comment(rawValue: "\(gauge.id) was called spent by a reply that said nothing"))
        }
    }

    /// And the service saying so still works, or the fix would be "never
    /// critical", which is the same failure pointing the other way.
    @Test("A reply that says the balance cannot be spent still marks it critical")
    func statedFalseIsCritical() throws {
        let snapshot = try deepseek("{\(balances),\"is_available\":false}")
        #expect(snapshot.gauges.count == 2)
        for gauge in snapshot.gauges {
            #expect(gauge.reportedSeverity == .critical,
                    Comment(rawValue: "\(gauge.id) was not marked spent though the service said so"))
        }
    }

    @Test("A reply that says the balance can be spent marks nothing")
    func statedTrueIsNormal() throws {
        for gauge in try deepseek("{\(balances),\"is_available\":true}").gauges {
            #expect(gauge.reportedSeverity != .critical)
        }
    }

    /// `1` and `0` do read as flags, because `as? Bool` bridges an `NSNumber`
    /// holding either. Checked rather than assumed, and it is the reading to
    /// want from a service that states a flag as a number.
    @Test("A flag stated as one or nought is a flag")
    func numericFlagsAreFlags() throws {
        #expect(try deepseek("{\(balances),\"is_available\":0}")
            .gauges.allSatisfy { $0.reportedSeverity == .critical },
                "a flag stated as 0 was not read as off")
        #expect(try deepseek("{\(balances),\"is_available\":1}")
            .gauges.allSatisfy { $0.reportedSeverity != .critical },
                "a flag stated as 1 was not read as on")
    }

    /// A value the flag cannot be read from is unstated, not off. A gauge is
    /// not painted critical because a field held something nobody expected.
    @Test("A value that is not a flag is unstated", arguments: ["2", "-1", "\"false\"", "null", "[]"])
    func unreadableIsUnstated(literal: String) throws {
        let snapshot = try deepseek("{\(balances),\"is_available\":\(literal)}")
        #expect(snapshot.gauges.count == 2)
        for gauge in snapshot.gauges {
            #expect(gauge.reportedSeverity != .critical,
                    Comment(rawValue: "is_available: \(literal) was read as a stated false"))
        }
    }
}

/// A flag key is a field path, which is what it is classified as.
///
/// It resolved as a flat member until now, so a dotted key silently matched
/// nothing and a filtered one would have passed the validator — which checks
/// bracket groups in these keys — and then never matched. A guard that validates
/// and does nothing is worse than no guard. No shipped descriptor uses either
/// form, which is why nothing caught it; these are synthetic harnesses so the
/// vocabulary is held to being one vocabulary.
@Suite("A flag key reaches where a field path reaches")
struct FlagKeyPathTests {

    private func provider(criticalWhen: String) throws -> DescriptorProvider {
        let document = Data("""
        {
          "formatVersion":\(HarnessDocument.currentVersion),
          "id":"flag-fixture","name":"Flag fixture",
          "process":{"pathContains":["/flag-fixture"]},
          "source":{"kind":"none","path":""},
          "quota":{
            "endpoint":"https://example.invalid/usage",
            "windows":{
              "root":"windows","keys":["weekly"],
              "remaining":"remaining","limit":"limit",
              "criticalWhen":\(criticalWhen)
            }
          }
        }
        """.utf8)
        let descriptor = try HarnessDocument.decode(document).descriptor
        return try #require(DescriptorProvider(descriptor))
    }

    private func snapshot(_ provider: DescriptorProvider, _ json: String) throws -> Snapshot {
        let reply = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8))
                                     as? [String: Any])
        return try provider.makeSnapshot(reply)
    }

    /// One window with a meter, plus whatever the case needs. `inWindow` is
    /// spliced into the window object, `atRoot` beside it — so a flag stated
    /// once for the whole reply and one stated per window are both reachable.
    private func reply(inWindow: String = "", atRoot: String = "") -> String {
        #"{"windows":{"weekly":{"limit":100,"remaining":40\#(inWindow)}}\#(atRoot)}"#
    }

    @Test("A dotted flag key reaches into a nested object")
    func dottedKey() throws {
        let provider = try provider(criticalWhen: #"{"state.blocked":true}"#)
        #expect(try snapshot(provider, reply(inWindow: #","state":{"blocked":true}"#))
            .gauges.first?.reportedSeverity == .critical,
                "a dotted flag key did not reach the flag")
        #expect(try snapshot(provider, reply(inWindow: #","state":{"blocked":false}"#))
            .gauges.first?.reportedSeverity != .critical)
        // The nested object being absent is unstated, not a stated false.
        #expect(try snapshot(provider, reply()).gauges.first?.reportedSeverity != .critical)
        // And so is the object being there without the field in it.
        #expect(try snapshot(provider, reply(inWindow: #","state":{}"#))
            .gauges.first?.reportedSeverity != .critical)
    }

    @Test("A filtered flag key selects the entry it names")
    func filteredKey() throws {
        let provider = try provider(criticalWhen: #"{"flags[name=blocked].on":true}"#)
        #expect(try snapshot(provider, reply(inWindow:
            #","flags":[{"name":"other","on":false},{"name":"blocked","on":true}]"#))
            .gauges.first?.reportedSeverity == .critical,
                "a filtered flag key did not reach the entry it named")
        #expect(try snapshot(provider, reply(inWindow:
            #","flags":[{"name":"blocked","on":false},{"name":"other","on":true}]"#))
            .gauges.first?.reportedSeverity != .critical,
                "the wrong entry's flag was read")
        // A filter matching nothing is unstated, which is what keeps a
        // misspelled name from painting a gauge spent.
        #expect(try snapshot(provider, reply(inWindow: #","flags":[{"name":"other","on":true}]"#))
            .gauges.first?.reportedSeverity != .critical)
    }

    /// A flat key still means a member of the window, which is every shipped
    /// descriptor and the case this must not have changed.
    @Test("A flat flag key is still the member it names")
    func flatKey() throws {
        let provider = try provider(criticalWhen: #"{"blocked":true}"#)
        #expect(try snapshot(provider, reply(inWindow: #","blocked":true"#))
            .gauges.first?.reportedSeverity == .critical)
        #expect(try snapshot(provider, reply()).gauges.first?.reportedSeverity != .critical)
    }

    /// The response-level fallback reaches through a path too, so the rule that
    /// a service may state something once for every window it reports is not
    /// narrower for a nested statement than for a flat one.
    @Test("A path resolves against the response when the window is silent")
    func pathAtResponseLevel() throws {
        let provider = try provider(criticalWhen: #"{"account.blocked":true}"#)
        #expect(try snapshot(provider, reply(atRoot: #","account":{"blocked":true}"#))
            .gauges.first?.reportedSeverity == .critical,
                "a nested response-level flag was not seen by the window")
        #expect(try snapshot(provider, reply(atRoot: #","account":{"blocked":false}"#))
            .gauges.first?.reportedSeverity != .critical)
    }

    /// And the window wins over the response, which is the existing precedence
    /// and has to survive the paths.
    @Test("A window's own flag beats the one stated for the response")
    func windowWins() throws {
        let provider = try provider(criticalWhen: #"{"state.blocked":true}"#)
        #expect(try snapshot(provider, reply(inWindow: #","state":{"blocked":false}"#,
                                             atRoot: #","state":{"blocked":true}"#))
            .gauges.first?.reportedSeverity != .critical,
                "the response's flag overrode the window's own")
    }
}

/// And the other rule, which wants the opposite and must keep it.
@Suite("A requirement still reads an unstated flag as unmet")
struct RequirementFlagTests {

    private func copilot(_ json: String) throws -> Snapshot {
        let descriptor = try #require(HarnessCLI.bundledDescriptors().first { $0.id == "copilot" })
        let provider = try #require(DescriptorProvider(descriptor))
        let reply = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8))
                                     as? [String: Any])
        return try provider.makeSnapshot(reply)
    }

    /// Copilot's rule is `has_quota: true` and `unlimited: false`. A window
    /// that does not mention being unlimited is not unlimited, and must still
    /// be drawn — which is the case the `?? false` is kept for.
    @Test("A window that does not mention being unlimited is still drawn")
    func silenceMeansNotUnlimited() throws {
        let snapshot = try copilot("""
        {"quota_snapshots":{"chat":{"has_quota":true,"percent_remaining":80}}}
        """)
        #expect(snapshot.gauges.count == 1,
                "a window saying nothing about being unlimited was dropped")
    }

    /// A window that says it is unlimited is dropped, since there is no meter.
    @Test("A window that says it is unlimited is not drawn")
    func unlimitedIsDropped() throws {
        let snapshot = try? copilot("""
        {"quota_snapshots":{"chat":{"has_quota":true,"unlimited":true,"percent_remaining":100}}}
        """)
        #expect(snapshot?.gauges.isEmpty ?? true)
    }

    /// A requirement asking for a flag to be *on* is still unmet by silence,
    /// which is the direction that was never in doubt.
    @Test("A window that does not mention having a quota is not drawn")
    func silenceFailsAPositiveRequirement() throws {
        let snapshot = try? copilot("""
        {"quota_snapshots":{"chat":{"percent_remaining":80}}}
        """)
        #expect(snapshot?.gauges.isEmpty ?? true)
    }

    /// A flag stated as a number satisfies a requirement the same way, so the
    /// two rules read flags identically and only differ on silence.
    @Test("A requirement is met by a flag stated as a number")
    func numericFlagMeetsARequirement() throws {
        let snapshot = try copilot("""
        {"quota_snapshots":{"chat":{"has_quota":1,"unlimited":0,"percent_remaining":80}}}
        """)
        #expect(snapshot.gauges.count == 1)
    }
}
