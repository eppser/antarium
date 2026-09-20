import Foundation

/// Synthetic transport integration boundary. Does not load installed harnesses,
/// session sources, agent names, SSH configuration or stored credentials.
enum RemoteDiscoveryEvaluation {
    static func verify(file:String) -> Int32 {
        do {
            let data = try BoundedFile.read(URL(fileURLWithPath:file),maxBytes:8 * 1_024 * 1_024)
            guard let text = String(data:data,encoding:.utf8) else { return 2 }
            let descriptor = try HarnessDocument.decode(Data(#"{"formatVersion":1,"id":"fixture","name":"Synthetic","process":{"pathContains":["/fixture/agent"]},"source":{"kind":"none","path":""}}"#.utf8)).descriptor
            let reply = Shell.Result(stdout:text,stderr:"",exitCode:0,timedOut:false,launchError:nil)
            let accepted = RemoteTmux.usable(reply)
            let rows = accepted ? RemoteTmux.parse(text,host:"fixture",descriptors:{ [descriptor] }) : []
            let report:[String:Any] = ["accepted":accepted,"rows":rows.count,
                "allStatesUnknown":rows.allSatisfy { $0.state.label == "Unknown" },
                "allRowsRemote":rows.allSatisfy(\.isRemote),
                "localFocusDisabled":rows.allSatisfy { !Focus.canRevealLocally($0) }]
            print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self))
            return accepted ? 0 : 1
        } catch {
            print("Synthetic remote reply verification failed.")
            return 2
        }
    }
}
