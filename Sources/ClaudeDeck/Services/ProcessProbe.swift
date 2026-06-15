import Foundation

/// Discovers live `claude` CLI processes and the terminal context needed to
/// re-focus their window/tab.
///
/// Security note: `ps -E` appends the full process environment (which contains
/// CLAUDE_API_KEY and other secrets). We extract only TERM_PROGRAM and
/// TERM_SESSION_ID and never store or log the rest.
enum ProcessProbe {

    static func liveProcesses() -> [LiveProcess] {
        let out = Shell.run("/bin/ps", ["-axo", "pid=,tty=,comm="])
        var result: [LiveProcess] = []

        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Columns: <pid> <tty> <comm...>
            let parts = trimmed.split(separator: " ", maxSplits: 2,
                                      omittingEmptySubsequences: true)
            guard parts.count >= 3 else { continue }
            guard let pid = Int32(parts[0]) else { continue }
            let tty = String(parts[1])
            // The final chunk after `maxSplits` keeps any extra padding spaces
            // (ps pads columns), so trim it before matching.
            let comm = String(parts[2]).trimmingCharacters(in: .whitespaces)

            guard isClaudeCLI(comm) else { continue }

            let ttyName = tty == "??" ? nil : tty
            var proc = LiveProcess(id: pid, tty: ttyName, cwd: nil,
                                   termProgram: nil, termSessionId: nil)
            proc.cwd = cwd(of: pid)
            let term = terminalContext(of: pid)
            proc.termProgram = term.program
            proc.termSessionId = term.sessionId
            proc.permissionMode = term.permissionMode
            result.append(proc)
        }
        return result
    }

    /// Finds a local terminal tab running an interactive `ssh` to `host`, so a
    /// remote session can be brought to the front instead of always opening a new
    /// window. Requires a real controlling tty (so ClaudeDeck's own ControlMaster
    /// mux — which has none — is skipped), and matches `host` as a whole argv
    /// token (the alias or `user@host`).
    static func remoteSSHProcess(forHost host: String) -> LiveProcess? {
        let needle = host.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return nil }
        let out = Shell.run("/bin/ps", ["-axo", "pid=,tty=,command="])
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int32(parts[0]) else { continue }
            let tty = String(parts[1])
            guard tty != "??" else { continue }   // need a real tab tty
            let command = String(parts[2])
            let tokens = command.split(separator: " ").map(String.init)
            guard let first = tokens.first,
                  (first as NSString).lastPathComponent == "ssh" else { continue }
            // The host appears as its own token (`ssh 3090f`, `ssh -t 3090f …`),
            // or as the host part of `user@3090f`.
            guard tokens.contains(needle)
                    || tokens.contains(where: { $0.hasSuffix("@\(needle)") }) else { continue }
            var proc = LiveProcess(id: pid, tty: tty, cwd: nil,
                                   termProgram: nil, termSessionId: nil)
            let term = terminalContext(of: pid)
            proc.termProgram = term.program
            proc.termSessionId = term.sessionId
            return proc
        }
        return nil
    }

    /// Matches the Claude Code CLI while excluding the MCP children
    /// (npm/node/playwright) and this menu bar app itself.
    private static func isClaudeCLI(_ comm: String) -> Bool {
        let base = (comm as NSString).lastPathComponent.lowercased()
        guard base == "claude" || base.hasPrefix("claude ") else {
            // node-based installs surface as `node`; fall back to a path match.
            return comm.contains("/claude") && !comm.contains("claude-bar")
        }
        return !comm.contains("claude-bar")
    }

    private static func cwd(of pid: Int32) -> String? {
        // lsof -a -p <pid> -d cwd -Fn  ->  a line beginning with 'n' is the path.
        let out = Shell.run("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"])
        for line in out.split(separator: "\n") where line.hasPrefix("n") {
            return String(line.dropFirst())
        }
        return nil
    }

    private static func terminalContext(of pid: Int32)
        -> (program: String?, sessionId: String?, permissionMode: String?) {
        // `-E` appends the environment after the argv; we pull only TERM_PROGRAM /
        // TERM_SESSION_ID from it and the permission-mode flag from the argv — the
        // rest (which holds secrets like CLAUDE_API_KEY) is never stored or logged.
        let out = Shell.run("/bin/ps", ["-Ewwo", "command=", "-p", "\(pid)"])
        var program: String?
        var sessionId: String?
        var permissionMode: String?
        let tokens = out.split(separator: " ").map(String.init)
        for (i, token) in tokens.enumerated() {
            if token.hasPrefix("TERM_PROGRAM=") {
                program = String(token.dropFirst("TERM_PROGRAM=".count))
            } else if token.hasPrefix("TERM_SESSION_ID=") {
                sessionId = String(token.dropFirst("TERM_SESSION_ID=".count))
            } else if token == "--dangerously-skip-permissions" {
                permissionMode = "bypassPermissions"
            } else if token == "--permission-mode", i + 1 < tokens.count {
                permissionMode = tokens[i + 1]   // "plan" | "acceptEdits" | …
            } else if token.hasPrefix("--permission-mode=") {
                permissionMode = String(token.dropFirst("--permission-mode=".count))
            }
        }
        return (program, sessionId, permissionMode)
    }
}
