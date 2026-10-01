import Foundation
import Testing
@testable import Antarium

/// A `none` source with a path means "read by native code", for one harness.
///
/// `claude-code` declares `kind: none` and `path: ~/.claude/sessions`, which
/// looks like a contradiction and is not: its sessions come from
/// `AgentScan.claudeRows`, native code selected by *id*, and the path is the root
/// that reader uses and the one install detection looks for.
///
/// For anybody else the same declaration reads nothing. `AgentScan.rows` and
/// `HarnessEngine.sessions` both return early on a `none` kind, so a third-party
/// author who wrote it would see their agent detected, listed in settings, and
/// permanently without sessions — with nothing anywhere saying why.
@Suite("A none source with a path is read only where a native reader exists")
struct NativeSessionReaderTests {

    private var descriptors: [HarnessDescriptor] { HarnessCLI.bundledDescriptors() }

    /// The guard that matters: the shipped set is exactly the harnesses that
    /// have a native reader. A second one appearing without one fails here.
    @Test("Only the harnesses with a native reader declare a none source with a path")
    func onlyNativeReadersDeclareIt() {
        let declaring = descriptors
            .filter { $0.source.kind == .none && !$0.source.path.isEmpty }
            .map(\.id)
            .sorted()
        #expect(Set(declaring) == HarnessCheck.nativeSessionReaders,
                Comment(rawValue: "declaring a none source with a path: \(declaring); "
                        + "known native readers: "
                        + "\(HarnessCheck.nativeSessionReaders.sorted())"))
    }

    /// And the list is not empty, or the claim above would be satisfied by
    /// nothing declaring it.
    @Test("Claude Code is the one, and it still declares both halves")
    func claudeIsTheOne() throws {
        #expect(HarnessCheck.nativeSessionReaders == ["claude-code"])
        let claude = try #require(descriptors.first { $0.id == "claude-code" })
        #expect(claude.source.kind == .none)
        #expect(!claude.source.path.isEmpty,
                "install detection and the native reader both need this path")
    }

    /// The warning a third-party author gets. Written as a document rather than
    /// a shipped harness, because the point is what happens to somebody else's.
    @Test("A third-party none source with a path is reported")
    func thirdPartyIsWarned() throws {
        let data = Data("""
        {
          "formatVersion":1,"id":"none-with-path","name":"None with path",
          "process":{"pathContains":["/none-with-path"],"names":["none-with-path"]},
          "source":{"kind":"none","path":"~/.none-with-path/sessions"}
        }
        """.utf8)
        let descriptor = try HarnessDocument.decode(data).descriptor
        let message = try #require(HarnessCheck.unreadSourcePath(descriptor),
                                   "the check says nothing about it")
        #expect(message.contains("reads no sessions"))
        #expect(message.contains("~/.none-with-path/sessions"),
                "the warning does not name the path it is about")
        #expect(message.contains("claude-code"),
                "the warning does not say whose path is read")
    }

    /// And a harness that declares a real kind is not warned about, or the
    /// message would be noise on every ordinary file.
    @Test("A source that declares its kind is not reported")
    func ordinarySourceIsNotWarned() throws {
        let data = Data("""
        {
          "formatVersion":1,"id":"ordinary","name":"Ordinary",
          "process":{"pathContains":["/ordinary"],"names":["ordinary"]},
          "source":{"kind":"jsonl","path":"~/.ordinary/sessions","glob":"*.jsonl"}
        }
        """.utf8)
        #expect(HarnessCheck.unreadSourcePath(
            try HarnessDocument.decode(data).descriptor) == nil)
    }

    /// Nor is a quota-only harness, which is the ordinary use of `none`: no
    /// session store, so no path.
    @Test("A quota-only harness is not reported")
    func quotaOnlyIsNotWarned() throws {
        let data = Data("""
        {
          "formatVersion":1,"id":"quota-only","name":"Quota only",
          "process":{"pathContains":["/quota-only"],"names":["quota-only"]},
          "source":{"kind":"none","path":""},
          "quota":{"endpoint":"https://example.invalid/usage",
                   "windows":{"single":"b","balance":"balance","currency":"USD"}}
        }
        """.utf8)
        #expect(HarnessCheck.unreadSourcePath(
            try HarnessDocument.decode(data).descriptor) == nil)
    }

    /// And the one harness that does have a native reader is not warned about.
    @Test("Claude Code is not reported")
    func claudeIsNotWarned() throws {
        let claude = try #require(HarnessCLI.bundledDescriptors().first { $0.id == "claude-code" })
        #expect(HarnessCheck.unreadSourcePath(claude) == nil)
    }

    /// Every shipped quota-only harness is in that ordinary case, so the rule
    /// above costs the collection nothing.
    @Test("Every shipped quota-only harness leaves its path empty")
    func shippedQuotaOnlyHarnessesAreClean() {
        for descriptor in descriptors where descriptor.source.kind == .none {
            guard !HarnessCheck.nativeSessionReaders.contains(descriptor.id) else { continue }
            #expect(descriptor.source.path.isEmpty,
                    Comment(rawValue: "\(descriptor.id) declares a none source with a path "
                            + "and has no native reader"))
        }
    }
}
