import Foundation
import Testing
@testable import Antarium

/// Which strings in a `quota.windows` block are field paths.
///
/// The classification exists because paths may now filter — `usages[scope=X]`
/// — and a misspelled filter selects nothing. The validator refuses one where
/// it is written, and to do that it has to know which of the twenty-odd
/// strings in the block are paths at all. That list lives in the SDK beside
/// the declarations; this suite is what keeps it from drifting away from them.
@Suite("Window field paths are classified beside their declarations")
struct WindowFieldPathTests {

    /// Every field set to a value naming itself, so an unclassified one is
    /// identifiable by name rather than by position.
    private var populated: HarnessDescriptor.Quota.Windows {
        var windows = HarnessDescriptor.Quota.Windows()
        windows.root = "p-root"
        windows.roots = ["p-roots"]
        windows.list = "p-list"
        windows.key = ["p-key"]
        windows.keys = ["p-keys"]
        windows.usedPercent = "p-usedPercent"
        windows.percentRemaining = "p-percentRemaining"
        windows.balance = "p-balance"
        windows.currency = "p-currency"
        windows.single = "not-a-path-single"
        windows.used = "p-used"
        windows.remaining = "p-remaining"
        windows.criticalWhen = ["p-criticalWhen": true]
        windows.limit = "p-limit"
        windows.require = ["p-require": true]
        windows.labels = ["not-a-path-labels": "not-a-path-label"]
        windows.badges = ["not-a-path-badges": "not-a-path-badge"]
        windows.windowSeconds = "p-windowSeconds"
        windows.resetsAt = "p-resetsAt"
        windows.title = "p-title"
        return windows
    }

    /// The test that catches drift. Reflection walks the struct's own fields,
    /// so adding one and forgetting to classify it leaves a nil child that is
    /// neither excluded by name nor represented in `fieldPaths` — and this
    /// fails naming it, rather than the new path quietly going unvalidated.
    @Test("Every field of the block is either a path or named as not one")
    func everyFieldIsClassified() {
        let windows = populated
        let paths = Set(windows.fieldPaths)
        let excluded = HarnessDescriptor.Quota.Windows.nonPathFields
        let labels = Mirror(reflecting: windows).children.compactMap(\.label)
        #expect(labels.count == Mirror(reflecting: windows).children.count,
                "reflection returned an unnamed field, so it cannot be classified")
        for label in labels where !excluded.contains(label) {
            #expect(paths.contains("p-\(label)"),
                    Comment(rawValue: "quota.windows.\(label) is not in fieldPaths and is not "
                            + "listed in nonPathFields — a filter written in it would go "
                            + "unvalidated"))
        }
    }

    /// And the other direction: the exclusions have to be real fields, or a
    /// renamed one leaves a stale name silently excusing nothing.
    @Test("Every excluded name is a field that exists")
    func exclusionsExist() {
        let labels = Set(Mirror(reflecting: populated).children.compactMap(\.label))
        for name in HarnessDescriptor.Quota.Windows.nonPathFields {
            #expect(labels.contains(name),
                    Comment(rawValue: "nonPathFields names \(name), which is not a field"))
        }
    }

    /// A field that names a window is not a path, and must not be checked as
    /// one: a bracket group in an identifier is not a filter anyone meant.
    ///
    /// `title` used to be on this list, and it is a path — it reads as text
    /// because it is drawn in a menu, and it is a path *to* the text. The
    /// reflection test above proves every field is classified and cannot prove
    /// one is classified right; `WindowPathFilterTests` is what caught it.
    @Test("Fields that name a window are left out of the paths")
    func windowNamesAreNotPaths() {
        let paths = Set(populated.fieldPaths)
        #expect(!paths.contains("not-a-path-single"))
        #expect(!paths.contains("not-a-path-labels"), "a label key is a window id")
        #expect(!paths.contains("not-a-path-badges"), "a badge key is a window id")
        // And the value halves were never paths either.
        #expect(!paths.contains("not-a-path-label"))
        #expect(!paths.contains("not-a-path-badge"))
        #expect(paths.contains("p-title"), "a declared title is a path to the text")
    }

    @Test("An empty block names no paths")
    func emptyBlock() {
        #expect(HarnessDescriptor.Quota.Windows().fieldPaths.isEmpty)
    }
}

/// The refusal itself, through the document boundary every harness passes.
@Suite("A malformed filter is refused where it is written")
struct WindowFilterValidationTests {

    private func document(remaining: String) -> Data {
        Data("""
        {
          "formatVersion":\(HarnessDocument.currentVersion),
          "id":"filter-fixture","name":"Filter fixture",
          "process":{"pathContains":["/filter-fixture"]},
          "source":{"kind":"none","path":""},
          "quota":{
            "endpoint":"https://example.invalid/usage",
            "windows":{"remaining":"\(remaining)","limit":"usages[scope=C].detail.limit"}
          }
        }
        """.utf8)
    }

    @Test("A well-formed filter decodes")
    func accepted() throws {
        let decoded = try HarnessDocument.decode(document(remaining: "usages[scope=C].detail.remaining"))
        #expect(decoded.descriptor.quota?.windows.remaining == "usages[scope=C].detail.remaining")
    }

    @Test("So do the brackets that were always there")
    func existingBracketsStillDecode() throws {
        for path in ["rows[].n", "rows[-1].n", "plain.path"] {
            let decoded = try HarnessDocument.decode(document(remaining: path))
            #expect(decoded.descriptor.quota?.windows.remaining == path)
        }
    }

    @Test("A bracket group that is not a filter is refused", arguments: [
        "usages[scope].detail.remaining",
        "usages[=C].detail.remaining",
        "usages[scope=].detail.remaining",
        "usages[scope=C,].detail.remaining",
        "usages[scope=C].limits[dur].detail.remaining",
    ])
    func refused(path: String) {
        #expect(throws: HarnessDocument.Error.self,
                Comment(rawValue: "\(path) was accepted")) {
            _ = try HarnessDocument.decode(document(remaining: path))
        }
    }

    @Test("An unclosed bracket is refused rather than ignored")
    func unclosed() {
        #expect(throws: HarnessDocument.Error.self) {
            _ = try HarnessDocument.decode(document(remaining: "usages[scope=C.detail.remaining"))
        }
    }

    /// The message has to name the path, or an author with twenty windows is
    /// told only that one of them is wrong.
    @Test("The refusal names the path and the group")
    func messageNamesIt() {
        do {
            _ = try HarnessDocument.decode(document(remaining: "usages[scope].detail.remaining"))
            Issue.record("a malformed filter was accepted")
        } catch let error as HarnessDocument.Error {
            let message = error.errorDescription ?? ""
            #expect(message.contains("usages[scope].detail.remaining"))
            #expect(message.contains("[scope]"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

/// What a document may declare about its body.
///
/// Both refusals below survived their catalogue entries when they were written,
/// which is the whole reason this suite exists: the rules were in the validator
/// and nothing asked for them. A body key declared twice would have been
/// resolved by whichever half the merge applied second, and a list body
/// declared on a GET would have been built and silently never sent.
@Suite("A body declaration that cannot be honoured is refused")
struct BodyDeclarationTests {

    private func document(_ quota: String) -> Data {
        Data("""
        {
          "formatVersion":\(HarnessDocument.currentVersion),
          "id":"body-fixture","name":"Body fixture",
          "process":{"pathContains":["/body-fixture"]},
          "source":{"kind":"none","path":""},
          "quota":{\(quota),"windows":{"single":"b","balance":"balance","currency":"USD"}}
        }
        """.utf8)
    }

    private let endpoint = #""endpoint":"https://example.invalid/usage""#

    @Test("A POST may declare both halves of its body, for different keys")
    func differentKeysAreFine() throws {
        let decoded = try HarnessDocument.decode(document(
            endpoint + #","method":"POST","body":{"view":"plan"},"bodyList":{"scope":["A"]}"#))
        #expect(decoded.descriptor.quota?.body?["view"] == "plan")
        #expect(decoded.descriptor.quota?.bodyList?["scope"] == ["A"])
    }

    @Test("One key in both halves has two values and one slot")
    func keyInBothHalves() {
        #expect(throws: HarnessDocument.Error.self) {
            _ = try HarnessDocument.decode(document(
                endpoint + #","method":"POST","body":{"scope":"A"},"bodyList":{"scope":["A"]}"#))
        }
    }

    /// And the refusal names the key, or an author with a dozen of them is told
    /// only that one is wrong.
    @Test("The refusal names the key that was declared twice")
    func refusalNamesTheKey() {
        do {
            _ = try HarnessDocument.decode(document(
                endpoint + #","method":"POST","body":{"scope":"A"},"bodyList":{"scope":["A"]}"#))
            Issue.record("a key declared in both halves was accepted")
        } catch let error as HarnessDocument.Error {
            #expect((error.errorDescription ?? "").contains("scope"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// A list body on a GET is a body that is never sent. Refused where it is
    /// written rather than by an endpoint answering the wrong question.
    @Test("A list body is refused on anything but a POST")
    func listBodyNeedsAPost() {
        for method in [#","method":"GET""#, ""] {
            #expect(throws: HarnessDocument.Error.self,
                    Comment(rawValue: "accepted a list body with method \(method.isEmpty ? "absent" : method)")) {
                _ = try HarnessDocument.decode(document(
                    self.endpoint + method + #","bodyList":{"scope":["A"]}"#))
            }
        }
    }

    /// A list half whose values are not lists of strings.
    ///
    /// `Codable` would decode the object and drop the keys it could not read,
    /// so a body declared as `{"scope":"A"}` would post nothing under `scope`
    /// and the endpoint would answer whatever it answers with no scope — a
    /// reply that parses, mapped onto gauges, wrong. Refused at the boundary
    /// for the same reason the shape of `body` is.
    @Test("A list body whose values are not lists of strings is refused", arguments: [
        #""bodyList":{"scope":"A"}"#,
        #""bodyList":{"scope":[1,2]}"#,
        #""bodyList":{"scope":[["nested"]]}"#,
        #""bodyList":{"scope":[true]}"#,
        #""bodyList":{"scope":{"a":"b"}}"#,
        #""bodyList":["scope"]"#,
        #""bodyList":{"scope":["ok",3]}"#,
    ])
    func listBodyShape(declaration: String) {
        #expect(throws: HarnessDocument.Error.self,
                Comment(rawValue: "accepted \(declaration)")) {
            _ = try HarnessDocument.decode(self.document(
                self.endpoint + #","method":"POST","# + declaration))
        }
    }

    /// And an empty list is a list, which is a different thing from a key whose
    /// value is not one. A vendor asking for every scope states it as `[]`.
    @Test("An empty list is a shape, not a mistake")
    func emptyListIsFine() throws {
        let decoded = try HarnessDocument.decode(document(
            endpoint + #","method":"POST","bodyList":{"scope":[]}"#))
        #expect(decoded.descriptor.quota?.bodyList?["scope"] == [])
    }

    /// The scalar half on a GET is refused elsewhere and already covered; this
    /// says the new half is refused the same way rather than more loosely.
    @Test("A list body on a POST is accepted")
    func listBodyOnAPost() throws {
        let decoded = try HarnessDocument.decode(document(
            endpoint + #","method":"POST","bodyList":{"scope":["A","B"]}"#))
        #expect(decoded.descriptor.quota?.bodyList?["scope"] == ["A", "B"])
    }
}

/// What gets posted.
///
/// A descriptor may state the body in two halves — scalars, and the keys whose
/// value is a list — and until this was a function the only way to see the
/// result was to make the request. A quota fixture cannot: it replays
/// `makeSnapshot` against a recorded reply, which happens after the body has
/// already gone out. So a merge that dropped the list half would have shipped
/// with every fixture green and the endpoint answering a question nobody asked.
@Suite("A posted body is built from both halves a descriptor may declare")
struct PostBodyTests {

    private func quota(body: [String: String]? = nil,
                       bodyList: [String: [String]]? = nil) -> HarnessDescriptor.Quota {
        var quota = HarnessDescriptor.Quota(
            endpoint: "https://example.invalid/usage",
            windows: HarnessDescriptor.Quota.Windows())
        quota.method = "POST"
        quota.body = body
        quota.bodyList = bodyList
        return quota
    }

    private func strings(_ body: [String: Any], _ key: String) -> [String]? {
        body[key] as? [String]
    }

    @Test("A list-valued key is posted as a list, not as its first element")
    func listStaysAList() {
        let body = DescriptorProvider.postBody(quota(bodyList: ["scope": ["FEATURE_CODING"]]),
                                               token: "t", account: nil)
        #expect(strings(body, "scope") == ["FEATURE_CODING"])
        #expect(body["scope"] as? String == nil,
                "the list was flattened to a string, which is a different request")
    }

    @Test("Both halves reach the same body")
    func bothHalves() {
        let body = DescriptorProvider.postBody(
            quota(body: ["view": "plan"], bodyList: ["scope": ["A", "B"]]),
            token: "t", account: nil)
        #expect(body["view"] as? String == "plan")
        #expect(strings(body, "scope") == ["A", "B"])
        #expect(body.count == 2)
    }

    @Test("A scalar body still has its token substituted")
    func tokenInScalars() {
        let body = DescriptorProvider.postBody(quota(body: ["key": "{token}"]),
                                               token: "secret", account: nil)
        #expect(body["key"] as? String == "secret")
    }

    /// And not in the list half. Nothing needs it, and substituting into a
    /// list of scope names would put a credential in a field that is not one.
    @Test("A list is posted as written, with no substitution")
    func noSubstitutionInLists() {
        let body = DescriptorProvider.postBody(quota(bodyList: ["scope": ["{token}"]]),
                                               token: "secret", account: nil)
        #expect(strings(body, "scope") == ["{token}"])
    }

    @Test("A descriptor declaring neither half posts an empty body")
    func neitherHalf() {
        #expect(DescriptorProvider.postBody(quota(), token: "t", account: nil).isEmpty)
    }

    /// The shipped descriptor, end to end, because the point of all of this is
    /// one request.
    @Test("Kimi's body is the scope its gateway expects")
    func kimiPostsItsScope() throws {
        let kimi = try #require(HarnessCLI.bundledDescriptors().first { $0.id == "kimi" })
        let quota = try #require(kimi.quota)
        #expect(quota.resolvedMethod == .post)
        let body = DescriptorProvider.postBody(quota, token: "t", account: nil)
        #expect(strings(body, "scope") == ["FEATURE_CODING"])
    }
}
