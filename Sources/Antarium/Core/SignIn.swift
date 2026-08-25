import AppKit

/// Opens Terminal on the command that re-authenticates an agent.
///
/// A `.command` file rather than AppleScript: `open` needs no Automation
/// permission, and being asked to grant one is a poor thing to meet when you
/// clicked this precisely because your quota had stopped showing.
///
/// The command runs through a login shell so it finds the PATH the user would
/// have typed it into — `codex` and `claude` both install into `~/.local/bin`,
/// which a plain `#!/bin/bash` script does not see.
enum SignIn {
    /// Single-quoted for `sh`, with embedded quotes closed and reopened.
    private static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Separated from `launch` so the quoting can be tested without opening a
    /// window: an agent's name or command containing a quote used to be the
    /// kind of thing that only showed up in front of a user.
    static func script(_ command: String, label: String) -> String {
        """
        #!/bin/bash
        echo \(quoted("Signing in to \(label) — Antarium picks the new credential up on its next refresh."))
        echo
        exec "$SHELL" -lc \(quoted(command))
        """
    }

    @discardableResult
    static func launch(_ command: String, label: String) -> Bool {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("antarium-sign-in.command")
        let script = script(command, label: label)
        Log.info("signin", "launching \(command) for \(label)")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: url.path)
            let opened = NSWorkspace.shared.open(url)
            Log.info("signin", "opened \(url.lastPathComponent): \(opened)")
            return opened
        } catch {
            NSLog("Antarium: couldn't start sign-in — %@", error.localizedDescription)
            return false
        }
    }
}
