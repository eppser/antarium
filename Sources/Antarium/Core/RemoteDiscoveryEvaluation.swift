import Foundation

/// Synthetic transport integration boundary. Does not load installed harnesses,
/// session sources, agent names, SSH configuration or stored credentials.
enum RemoteDiscoveryEvaluation {
    /// What the reply showed, as the command prints it.
    ///
    /// Separated so the one field that matters can be checked by a test: the
    /// three properties beside it are `allSatisfy`, which holds of no rows at
    /// all, and `verified` is the one that does not. Left inline, it was
    /// reachable only by running the command and reading its output, which
    /// nothing did.
    static func report(accepted:Bool,rows:[AgentRow]) -> [String:Any] {
        ["accepted":accepted,"rows":rows.count,
         "verified":accepted && !rows.isEmpty,
         "allStatesUnknown":rows.allSatisfy(\.state.isUnobserved),
         "allRowsRemote":rows.allSatisfy(\.isRemote),
         "localFocusDisabled":rows.allSatisfy { !Focus.canRevealLocally($0) }]
    }

    static func verify(file:String) -> Int32 {
        do {
            let data = try BoundedFile.read(URL(fileURLWithPath:file),maxBytes:8 * 1_024 * 1_024)
            guard let text = String(data:data,encoding:.utf8) else { return 2 }
            let descriptor = try HarnessDocument.decode(Data(#"{"formatVersion":1,"id":"fixture","name":"Synthetic","process":{"pathContains":["/fixture/agent"]},"source":{"kind":"none","path":""}}"#.utf8)).descriptor
            let reply = Shell.Result(stdout:text,stderr:"",exitCode:0,timedOut:false,launchError:nil)
            let accepted = RemoteTmux.usable(reply)
            let rows = accepted ? RemoteTmux.parse(text,host:"fixture",descriptors:{ [descriptor] }) : []
            // Every property below is `allSatisfy`, which is true of no rows
            // at all. A reply that parses and yields nothing therefore
            // reported four ticks and exited zero — a verification passing on
            // no evidence, which is the one answer a verifier must never
            // give. Said out loud and failed instead.
            let report = Self.report(accepted:accepted,rows:rows)
            print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self))
            if accepted && rows.isEmpty {
                print("The reply was accepted and produced no rows, so the properties above "
                    + "hold of nothing. Give a reply that names at least one pane, process "
                    + "and executable.")
            }
            return accepted && !rows.isEmpty ? 0 : 1
        } catch {
            print("Synthetic remote reply verification failed.")
            return 2
        }
    }
}
