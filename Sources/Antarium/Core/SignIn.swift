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

    static func prepare(_ command:String,label:String,directory:URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = directory.appendingPathComponent("antarium-sign-in-\(UUID()).command")
        Log.info("signin", "Preparing a private sign-in launcher.")
        // Bind cleanup to the file we created, never to caller-controlled argv[0].
        let header = "#!/bin/bash\n"
        let content = header + "/bin/rm -f -- \(quoted(url.path))\n"
            + script(command,label:label).dropFirst(header.count)
        try PrivateFile.write(Data(content.utf8),to:url,maxBytes:65_536,executable:true)
        return url
    }
    @discardableResult
    static func launch(_ command: String, label: String) -> Bool {
        do {
            let url = try prepare(command,label:label)
            let opened = NSWorkspace.shared.open(url)
            Log.info("signin", "Sign-in launcher opened: \(opened)")
            if !opened { try? FileManager.default.removeItem(at:url) }
            return opened
        } catch {
            Log.warn("signin", "Could not prepare or open the sign-in launcher.")
            return false
        }
    }
}
