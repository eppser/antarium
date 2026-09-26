import Foundation
import Testing
@testable import Antarium

/// A field the classification calls a path must accept one.
///
/// `WindowFieldPathTests` reflects over the block and insists every field is
/// classified. That catches a field added without being thought about, and it
/// cannot catch a field classified wrongly — it compares the list against
/// itself. Four were wrong, and one of them mattered: `title` was on the
/// not-a-path list because it ends up drawn in a menu, when it is a path *to*
/// the text. So the validator excused a bracket group in it and the code
/// resolved it with `lookup`, which cannot see one — a filter written there
/// would have passed `--check` and then silently matched nothing, which is the
/// shape of guard this repository refuses.
///
/// This suite is the claim that cannot be satisfied by agreeing with itself:
/// every path field carries a filter, against a reply built so the filter has
/// to work for the assertion to hold. An entry the filter did not select has
/// values that would produce a different answer, so resolving the path flatly —
/// or not at all — fails rather than coincidentally passing.
@Suite("Every field classified as a path resolves a filter written in it")
struct WindowPathFilterTests {

    /// One window, reached through a filtered root, with every figure available
    /// both inside the entry meant and inside a decoy the filter must not pick.
    private func provider(_ windows: String) throws -> DescriptorProvider {
        let document = Data("""
        {
          "formatVersion":\(HarnessDocument.currentVersion),
          "id":"path-fixture","name":"Path fixture",
          "process":{"pathContains":["/path-fixture"]},
          "source":{"kind":"none","path":""},
          "quota":{"endpoint":"https://example.invalid/usage","windows":\(windows)}
        }
        """.utf8)
        return try #require(DescriptorProvider(try HarnessDocument.decode(document).descriptor))
    }

    private func snapshot(_ provider: DescriptorProvider, _ json: String) throws -> Snapshot {
        let reply = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8))
                                     as? [String: Any])
        return try provider.makeSnapshot(reply)
    }

    /// Scopes in an array, the wanted one second so position cannot be relied
    /// on, and the decoy's figures deliberately different from the wanted
    /// entry's.
    private let scoped = #"""
    {"scopes":[
      {"name":"decoy","limit":1000,"remaining":1000,"used":0,"spent":9,
       "pct":99,"left":99,"secs":60,"reset":"2030-01-01T00:00:00Z","cur":"XXX",
       "label":"Decoy","money":9.99,"tags":[{"k":"unit","v":"decoy"}]},
      {"name":"wanted","limit":100,"remaining":25,"used":75,"spent":75,
       "pct":75,"left":25,"secs":18000,"reset":"2026-10-01T00:00:00Z","cur":"EUR",
       "label":"Wanted","money":4.20,"tags":[{"k":"unit","v":"weekly"}]}
    ]}
    """#

    /// `root` — the container holding the windows, reached by a filter.
    @Test("root")
    func filteredRoot() throws {
        let provider = try provider(#"""
        {"root":"envelopes[kind=live].report","keys":["weekly"],
         "used":"used","limit":"limit"}
        """#)
        let json = #"""
        {"envelopes":[{"kind":"stale","report":{"weekly":{"used":1,"limit":1}}},
                      {"kind":"live","report":{"weekly":{"used":75,"limit":100}}}]}
        """#
        let gauge = try #require(try snapshot(provider, json).gauges.first)
        #expect(abs(gauge.used - 0.75) < 0.001,
                "a filtered root resolved to the wrong envelope")
    }

    /// `list`, `key`, `used`, `limit`, `resetsAt`, `windowSeconds` at once: the
    /// list is reached by a filter on its own path, and the window drawn from it
    /// has to be the wanted entry rather than the decoy.
    @Test("list, key, used, limit, resetsAt, windowSeconds")
    func filteredList() throws {
        let provider = try provider(#"""
        {"list":"envelopes[kind=live].scopes","key":["name"],"keys":["wanted"],
         "used":"used","limit":"limit","resetsAt":"reset","windowSeconds":"secs"}
        """#)
        let json = #"""
        {"envelopes":[{"kind":"stale","scopes":[]},{"kind":"live","scopes":[
          {"name":"decoy","used":0,"limit":1000,"reset":"2030-01-01T00:00:00Z","secs":60},
          {"name":"wanted","used":75,"limit":100,"reset":"2026-10-01T00:00:00Z","secs":18000}]}]}
        """#
        let snapshot = try self.snapshot(provider, json)
        let gauge = try #require(snapshot.gauges.first)
        #expect(snapshot.gauges.count == 1)
        #expect(gauge.id == "wanted")
        #expect(abs(gauge.used - 0.75) < 0.001, "a filtered list drew the wrong entry's figures")
        #expect(gauge.resetsAt != nil, "resetsAt did not resolve")
    }

    /// `key` as a filter in its own right — the name of a list element taken
    /// from a tag rather than a plain field.
    @Test("key")
    func filteredKey() throws {
        let provider = try provider(#"""
        {"list":"scopes","key":["tags[k=unit].v"],"keys":["weekly"],
         "used":"used","limit":"limit"}
        """#)
        let gauge = try #require(try snapshot(provider, scoped).gauges.first)
        #expect(gauge.id == "weekly", "a filtered key part did not name the row")
        #expect(abs(gauge.used - 0.75) < 0.001)
    }

    /// `usedPercent`.
    @Test("usedPercent")
    func filteredUsedPercent() throws {
        let provider = try provider(#"""
        {"list":"scopes","key":["name"],"keys":["wanted"],
         "usedPercent":"tags[k=unit].pct"}
        """#)
        let json = #"""
        {"scopes":[{"name":"wanted","tags":[{"k":"other","pct":99},{"k":"unit","pct":75}]}]}
        """#
        #expect(abs(try #require(try snapshot(provider, json).gauges.first).used - 0.75) < 0.001,
                "a filtered usedPercent read the wrong entry")
    }

    /// `percentRemaining`.
    @Test("percentRemaining")
    func filteredPercentRemaining() throws {
        let provider = try provider(#"""
        {"list":"scopes","key":["name"],"keys":["wanted"],
         "percentRemaining":"tags[k=unit].left"}
        """#)
        let json = #"""
        {"scopes":[{"name":"wanted","tags":[{"k":"other","left":99},{"k":"unit","left":25}]}]}
        """#
        #expect(abs(try #require(try snapshot(provider, json).gauges.first).used - 0.75) < 0.001,
                "a filtered percentRemaining read the wrong entry")
    }

    /// `remaining` with `limit`, which is the branch Kimi takes.
    @Test("remaining")
    func filteredRemaining() throws {
        let provider = try provider(#"""
        {"list":"scopes","key":["name"],"keys":["wanted"],
         "remaining":"tags[k=unit].left","limit":"tags[k=unit].cap"}
        """#)
        let json = #"""
        {"scopes":[{"name":"wanted","tags":[{"k":"other","left":1,"cap":1},
                                            {"k":"unit","left":25,"cap":100}]}]}
        """#
        #expect(abs(try #require(try snapshot(provider, json).gauges.first).used - 0.75) < 0.001,
                "a filtered remaining/limit pair read the wrong entry")
    }

    /// `balance` and `currency`, which are the other kind of gauge entirely.
    @Test("balance, currency")
    func filteredBalanceAndCurrency() throws {
        let provider = try provider(#"""
        {"list":"scopes","key":["name"],"keys":["wanted"],"single":null,
         "balance":"tags[k=unit].money","currency":"tags[k=unit].cur"}
        """#)
        let json = #"""
        {"scopes":[{"name":"wanted","tags":[{"k":"other","money":9.99,"cur":"XXX"},
                                            {"k":"unit","money":4.20,"cur":"EUR"}]}]}
        """#
        let gauge = try #require(try snapshot(provider, json).gauges.first)
        #expect(gauge.amount?.value == 4.20, "a filtered balance read the wrong entry")
        #expect(gauge.amount?.currency == "EUR", "a filtered currency read the wrong entry")
    }

    /// `title` — the one the classification had wrong.
    @Test("title")
    func filteredTitle() throws {
        let provider = try provider(#"""
        {"list":"scopes","key":["name"],"keys":["wanted"],
         "used":"used","limit":"limit","title":"tags[k=unit].label"}
        """#)
        let json = #"""
        {"scopes":[{"name":"wanted","used":75,"limit":100,
          "tags":[{"k":"other","label":"Decoy"},{"k":"unit","label":"Wanted"}]}]}
        """#
        #expect(try #require(try snapshot(provider, json).gauges.first).title == "Wanted",
                "a filtered title did not reach the entry it named")
    }

    /// `criticalWhen` and `require` keys, already covered in `FlagKeyPathTests`
    /// but asserted here too so this suite is the whole classification rather
    /// than most of it.
    @Test("criticalWhen, require")
    func filteredFlags() throws {
        let provider = try provider(#"""
        {"list":"scopes","key":["name"],"keys":["wanted"],
         "used":"used","limit":"limit",
         "criticalWhen":{"tags[k=unit].blocked":true},
         "require":{"tags[k=unit].live":true}}
        """#)
        let json = #"""
        {"scopes":[{"name":"wanted","used":75,"limit":100,
          "tags":[{"k":"other","blocked":false,"live":true},
                  {"k":"unit","blocked":true,"live":true}]}]}
        """#
        #expect(try #require(try snapshot(provider, json).gauges.first).reportedSeverity
                == .critical, "a filtered criticalWhen key did not reach the flag")
        // And the requirement, by failing it in the entry the filter names
        // while the decoy would have passed it.
        let dropped = #"""
        {"scopes":[{"name":"wanted","used":75,"limit":100,
          "tags":[{"k":"other","live":true},{"k":"unit","live":false}]}]}
        """#
        #expect((try? snapshot(provider, dropped))?.gauges.isEmpty ?? true,
                "a filtered require key read the decoy's flag")
    }

    /// `keys` against an object response, where a member may be reached by a
    /// path — which is how Kimi's two windows are named.
    @Test("keys")
    func filteredKeys() throws {
        let provider = try provider(#"""
        {"root":"report","keys":["weekly","windows[span=5h].detail"],
         "used":"used","limit":"limit"}
        """#)
        let json = #"""
        {"report":{"weekly":{"used":75,"limit":100},
          "windows":[{"span":"1h","detail":{"used":9,"limit":10}},
                     {"span":"5h","detail":{"used":20,"limit":40}}]}}
        """#
        let gauges = try snapshot(provider, json).gauges
        #expect(gauges.count == 2)
        #expect(abs(try #require(gauges.first).used - 0.75) < 0.001)
        #expect(abs(try #require(gauges.last).used - 0.5) < 0.001,
                "a filtered key selected the wrong window")
    }

    /// `roots` — the candidate list, with a filter in a candidate.
    @Test("roots")
    func filteredRoots() throws {
        let provider = try provider(#"""
        {"roots":["absent.here","envelopes[kind=live].report"],"keys":["weekly"],
         "used":"used","limit":"limit"}
        """#)
        let json = #"""
        {"envelopes":[{"kind":"stale","report":{"weekly":{"used":0,"limit":1}}},
                      {"kind":"live","report":{"weekly":{"used":75,"limit":100}}}]}
        """#
        #expect(abs(try #require(try snapshot(provider, json).gauges.first).used - 0.75) < 0.001,
                "a filtered root candidate resolved to the wrong envelope")
    }

    /// The whole point, restated as coverage: every field the classification
    /// calls a path is exercised above. Listed rather than reflected, because
    /// the list is what a reader checks against the suite.
    @Test("Every path field above is one of the fields classified as a path")
    func coverageIsComplete() {
        let exercised: Set<String> = [
            "root", "roots", "list", "key", "keys", "usedPercent", "percentRemaining",
            "balance", "currency", "used", "remaining", "limit", "windowSeconds",
            "resetsAt", "title", "criticalWhen", "require",
        ]
        var populated = HarnessDescriptor.Quota.Windows()
        let labels = Set(Mirror(reflecting: populated).children.compactMap(\.label))
        let names = labels.subtracting(HarnessDescriptor.Quota.Windows.nonPathFields)
        #expect(names == exercised,
                Comment(rawValue: "classified as paths: \(names.sorted()); exercised here: "
                        + "\(exercised.sorted())"))
        _ = populated
    }
}
