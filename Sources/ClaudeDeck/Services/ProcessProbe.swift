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
            result.append(proc)
        }
        return result
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

    private static func terminalContext(of pid: Int32) -> (program: String?, sessionId: String?) {
        let out = Shell.run("/bin/ps", ["-Ewwo", "command=", "-p", "\(pid)"])
        var program: String?
        var sessionId: String?
        for token in out.split(separator: " ") {
            if token.hasPrefix("TERM_PROGRAM=") {
                program = String(token.dropFirst("TERM_PROGRAM=".count))
            } else if token.hasPrefix("TERM_SESSION_ID=") {
                sessionId = String(token.dropFirst("TERM_SESSION_ID=".count))
            }
        }
        return (program, sessionId)
    }
}
