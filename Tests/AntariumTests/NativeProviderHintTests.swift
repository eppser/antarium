import Foundation
import Testing
@testable import Antarium

/// Every provider offers a way to turn it on.
///
/// `everyQuotaProviderHasAHint` covers the descriptor-backed half, and it reads
/// `bundledDescriptors()` — so the seven providers written in Swift were never
/// checked. One shipping with an empty hint would leave a user looking at a row
/// that says "not signed in" and nothing to do about it, which is the one thing
/// the settings list exists to prevent.
///
/// Asked of `nativeProviders` rather than of `all`: `all` also includes whatever
/// the harness folder holds, so a test over it says something different on a
/// machine that has never run Antarium than on one that has — which is what
/// `verify.sh`'s bare-home configuration exists to catch.
@Suite("Every native provider says how to configure it")
struct NativeProviderHintTests {

    @Test("A hint is present and names something concrete")
    func hintsArePresent() {
        var examined = 0
        for provider in ProviderRegistry.nativeProviders {
            examined += 1
            let hint = provider.setupHint
            #expect(!hint.isEmpty,
                    Comment(rawValue: "\(provider.id) has no setup hint"))
            // The same bar the descriptor half is held to: long enough to name a
            // command or a file rather than restate the problem.
            #expect(hint.count > 12,
                    Comment(rawValue: "\(provider.id): hint is too vague — \(hint)"))
        }
        #expect(examined == 7,
                Comment(rawValue: "\(examined) native providers were examined"))
    }

    /// A hint tells the user to do something. "Not signed in" is the problem, not
    /// the action, and a hint that merely restates it is worse than none because
    /// it looks like help.
    @Test("No hint merely restates the problem")
    func hintsAreActions() {
        for provider in ProviderRegistry.nativeProviders {
            let hint = provider.setupHint.lowercased()
            #expect(hint != "not signed in",
                    Comment(rawValue: "\(provider.id) restates the problem"))
            // Something imperative or a path: a command to run, a file to write,
            // or an app to open. Every shipped hint does one of these.
            let acts = ["run ", "install", "put ", "add ", "point ", "sign in",
                        "~/", "login", "open "]
            #expect(acts.contains(where: hint.contains),
                    Comment(rawValue: "\(provider.id): \"\(provider.setupHint)\" names no action"))
        }
    }

    /// And where a provider does offer a sign-in command, it is a command rather
    /// than a sentence — it is put to the user as a menu item they can run.
    @Test("A sign-in command is a command")
    func signInCommandsAreCommands() {
        var offered = 0
        for provider in ProviderRegistry.nativeProviders {
            guard let command = provider.signInCommand else { continue }
            offered += 1
            #expect(!command.isEmpty)
            #expect(!command.hasSuffix("."),
                    Comment(rawValue: "\(provider.id): \"\(command)\" reads as prose"))
            #expect(command.count <= 64,
                    Comment(rawValue: "\(provider.id): \"\(command)\" is too long for a menu item"))
        }
        #expect(offered >= 3,
                Comment(rawValue: "only \(offered) native providers offer a sign-in command"))
    }

    /// A provider with no sign-in command must still leave the user something,
    /// because a rejected credential offers to sign them in and there would be
    /// nothing to offer. The hint is that something.
    @Test("A provider with no sign-in command still has a hint to fall back on")
    func fallbackIsTheHint() {
        var checked = 0
        for provider in ProviderRegistry.nativeProviders where provider.signInCommand == nil {
            checked += 1
            #expect(!provider.setupHint.isEmpty,
                    Comment(rawValue: "\(provider.id) offers neither a command nor a hint"))
        }
        // Not asserted to be non-zero: every native provider may well offer a
        // command one day, and that would be an improvement rather than a
        // failure. The loop is the claim; the count is not.
        _ = checked
    }

    /// The ids are distinct, since the hint a user sees is looked up by id and two
    /// providers sharing one would show the wrong advice for one of them.
    @Test("Native provider ids are distinct")
    func idsAreDistinct() {
        let ids = ProviderRegistry.nativeProviders.map(\.id)
        #expect(Set(ids).count == ids.count,
                Comment(rawValue: "duplicate native ids in \(ids.sorted())"))
    }
}
