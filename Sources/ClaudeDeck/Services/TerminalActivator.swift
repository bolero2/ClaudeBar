import Foundation
import AppKit

/// Brings the terminal window/tab that owns a given session to the front by
/// matching the session's tty inside the terminal app via AppleScript. For
/// ended sessions, opens a fresh terminal window and resumes the session.
enum TerminalActivator {

    enum Result {
        case activated
        case notFound
        case noTTY
        case unsupported(String)
    }

    /// Brings a live session's terminal tab to the front. If the tab can't be
    /// found (e.g. it was closed), falls back to opening a new window that
    /// resumes the session.
    @discardableResult
    static func activate(_ proc: LiveProcess, cwd: String, sessionId: String,
                         resumeModel: String? = nil, permissionMode: String? = nil,
                         extendedContext: Bool = false) -> Result {
        guard let tty = proc.tty else {
            return openResume(cwd: cwd, sessionId: sessionId, resumeModel: resumeModel,
                              permissionMode: permissionMode, extendedContext: extendedContext)
        }
        let devTTY = "/dev/" + tty

        let program = proc.termProgram ?? ""
        let result: Result
        if program.contains("Apple_Terminal") {
            result = run(appleTerminalScript(devTTY))
        } else if program.lowercased().contains("iterm") {
            result = run(iTermScript(devTTY))
        } else {
            if case .activated = run(appleTerminalScript(devTTY)) { return .activated }
            result = run(iTermScript(devTTY))
        }
        if case .activated = result { return result }
        return openResume(cwd: cwd, sessionId: sessionId, resumeModel: resumeModel,
                          permissionMode: permissionMode, extendedContext: extendedContext)
    }

    /// Opens a new terminal window, cd's into the session's directory and runs
    /// `claude --resume <sessionId>` to restore an ended session.
    ///
    /// `claude --resume` does not reliably restore the original session's 1M
    /// context window or permission mode, so we reconstruct those flags from the
    /// session's detected state:
    ///  - extended (1M) context → `--model '<base>[1m]'`
    ///  - bypass / plan / acceptEdits → the matching permission flag
    @discardableResult
    static func openResume(cwd: String, sessionId: String,
                           resumeModel: String? = nil, permissionMode: String? = nil,
                           extendedContext: Bool = false) -> Result {
        let cmd = "cd '\(escapeShell(cwd))' && claude --resume \(sessionId)"
        return open(cmd + sessionFlags(resumeModel: resumeModel, permissionMode: permissionMode,
                                       extendedContext: extendedContext))
    }

    /// Opens a new terminal window and starts a *fresh* `claude` in `cwd`, carrying
    /// over the model / 1M-context / permission mode of a session that can't be
    /// resumed (its transcript was never flushed — see `Session.resumable`). The
    /// user lands in a working terminal in the right place instead of hitting
    /// `claude --resume`'s "No conversation found" dead-end.
    @discardableResult
    static func openFresh(cwd: String, resumeModel: String? = nil,
                          permissionMode: String? = nil,
                          extendedContext: Bool = false) -> Result {
        let cmd = "cd '\(escapeShell(cwd))' && claude"
        return open(cmd + sessionFlags(resumeModel: resumeModel, permissionMode: permissionMode,
                                       extendedContext: extendedContext))
    }

    /// Builds the shared `--model '<base>[1m]'` / permission-mode flags appended to
    /// both the resume and fresh-session commands.
    private static func sessionFlags(resumeModel: String?, permissionMode: String?,
                                     extendedContext: Bool) -> String {
        var flags = ""
        if extendedContext, let base = resumeModel.map(stripModelSuffix), !base.isEmpty {
            flags += " --model '\(base)[1m]'"
        }
        switch permissionMode {
        case "bypassPermissions": flags += " --dangerously-skip-permissions"
        case "plan":              flags += " --permission-mode plan"
        case "acceptEdits":       flags += " --permission-mode acceptEdits"
        default: break
        }
        return flags
    }

    /// Drops a trailing `[1m]` marker to get the base model id (the transcript
    /// records the base model; the 1M variant is re-requested via `--model`).
    private static func stripModelSuffix(_ model: String) -> String {
        model.hasSuffix("[1m]") ? String(model.dropLast(4)) : model
    }

    /// Opens a new terminal window and starts a fresh `claude` session in `cwd`,
    /// optionally with `--dangerously-skip-permissions`.
    @discardableResult
    static func openNew(cwd: String, skipPermissions: Bool = false) -> Result {
        let flag = skipPermissions ? " --dangerously-skip-permissions" : ""
        return open("cd '\(escapeShell(cwd))' && claude\(flag)")
    }

    /// Types a line of text (e.g. a `/compact` slash command) into the live
    /// session's terminal tab, brings it to the front, and submits it. Only
    /// meaningful at the prompt; if the session is busy, Claude Code queues it.
    @discardableResult
    static func sendText(_ proc: LiveProcess, text: String) -> Result {
        guard let tty = proc.tty else { return .noTTY }
        let devTTY = "/dev/" + tty
        // A slash command is a single line; collapse newlines so the whole
        // instruction is submitted as one prompt rather than several.
        let line = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let program = proc.termProgram ?? ""
        if program.contains("Apple_Terminal") {
            return run(appleTerminalSendScript(devTTY, line))
        } else if program.lowercased().contains("iterm") {
            return run(iTermSendScript(devTTY, line))
        } else {
            if case .activated = run(appleTerminalSendScript(devTTY, line)) { return .activated }
            return run(iTermSendScript(devTTY, line))
        }
    }

    /// Like `sendText`, but types into the session's tab WITHOUT bringing the
    /// terminal to the front — used by the prompt-queue auto-injector so it
    /// doesn't steal focus on every step.
    @discardableResult
    static func injectText(_ proc: LiveProcess, text: String) -> Result {
        guard let tty = proc.tty else { return .noTTY }
        let devTTY = "/dev/" + tty
        let line = text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let program = proc.termProgram ?? ""
        if program.contains("Apple_Terminal") {
            return run(appleTerminalInjectScript(devTTY, line))
        } else if program.lowercased().contains("iterm") {
            return run(iTermInjectScript(devTTY, line))
        } else {
            if case .activated = run(appleTerminalInjectScript(devTTY, line)) { return .activated }
            return run(iTermInjectScript(devTTY, line))
        }
    }

    private static func appleTerminalInjectScript(_ devTTY: String, _ line: String) -> String {
        // No `activate` / window reordering → the tab stays in the background.
        // The first `do script` only TYPES the text into the (TUI) input box —
        // its trailing return is swallowed by the line editor, not treated as
        // submit. A second, separate `do script ""` sends a bare return that
        // actually submits it. Verified against a live `claude` TUI.
        """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(devTTY)" then
                do script "\(escapeAS(line))" in t
                delay 0.2
                do script "" in t
                return "ok"
              end if
            end repeat
          end repeat
        end tell
        return "notfound"
        """
    }

    private static func iTermInjectScript(_ devTTY: String, _ line: String) -> String {
        // Same two-step as Apple Terminal: type the text, then a separate
        // newline to submit it past the TUI's line editor.
        """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "\(devTTY)" then
                  tell s to write text "\(escapeAS(line))" newline no
                  delay 0.2
                  tell s to write text ""
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return "notfound"
        """
    }

    // MARK: - Screen-content idle detection

    /// Whether Claude's TUI in a tab is mid-turn (`busy`) or awaiting input
    /// (`idle`). Derived from the *visible terminal contents* — robust to
    /// Claude Code buffering its JSONL transcript (which makes file-mtime based
    /// detection unreliable for live sessions).
    /// `awaitingChoice` is Claude waiting on an interactive *selection* (a
    /// permission prompt or an AskUserQuestion list) — distinct from `idle`
    /// (waiting for free-text). The queue injector must NOT inject into a choice,
    /// or the queued prompt would be typed in as the answer and consume the
    /// question, so this is treated as not-idle.
    enum ScreenState { case idle, busy, awaitingChoice, unknown }

    /// Reads the visible contents of the tab/session bound to `proc.tty`
    /// WITHOUT changing focus, and classifies Claude's state.
    ///
    /// Two cross-checked signals so a single point of failure can't cause the
    /// *dangerous* misread (injecting while Claude is still working):
    ///  1. Screen markers (primary, fast).
    ///  2. Process CPU (backup): only consulted when the screen *looks* idle, to
    ///     veto a false-idle if Claude Code's UI strings ever change and the
    ///     markers stop matching — a streaming process still burns CPU.
    static func claudeScreenState(_ proc: LiveProcess) -> ScreenState {
        guard let tty = proc.tty else { return .unknown }
        let devTTY = "/dev/" + tty
        let program = proc.termProgram ?? ""
        let raw = program.lowercased().contains("iterm")
            ? Shell.osascript(iTermReadScript(devTTY))
            : Shell.osascript(appleTerminalReadScript(devTTY))
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "READ_FAIL" { return .unknown }
        if screenIsBusy(text) { return .busy }
        // Claude is waiting on a selection (permission / AskUserQuestion), not
        // free-text — injecting here would answer the question. Check before the
        // idle/CPU path since a choice prompt is idle by every other measure.
        if screenAwaitingChoice(text) { return .awaitingChoice }
        // Screen looks idle — confirm the process isn't quietly streaming (which
        // it would be if the busy markers above failed to match a newer UI).
        if processBurningCPU(proc.pid) { return .busy }
        return .idle
    }

    /// Busy markers seen in Claude Code's live spinner line: the interrupt hint
    /// or the streaming token widget `… (12s · ↓ 3.4k tokens)`. The idle status
    /// bar only ever shows `· ←` (a left arrow), so up/down arrows are a clean
    /// busy signal.
    static func screenIsBusy(_ text: String) -> Bool {
        text.contains("esc to interrupt") || text.contains("· ↓") || text.contains("· ↑")
    }

    /// True when Claude's TUI is showing an interactive selection list — a
    /// permission prompt or an AskUserQuestion — rather than the free-text input
    /// box. Such prompts mark the highlighted option with a "❯" pointer directly
    /// in front of a numbered choice (e.g. `❯ 1. Yes`); the text-input prompt and
    /// the streaming spinner never render this. The pointer is required to sit in
    /// front of a numbered option so a shell prompt's bare "❯" can't false-match.
    static func screenAwaitingChoice(_ text: String) -> Bool {
        text.range(of: #"[❯➤▸▶›]\s*\d+\."#, options: .regularExpression) != nil
    }

    /// True if `pid` accrues meaningful CPU over a short sample window — i.e. it's
    /// actively computing (token streaming), not blocked waiting for input. Uses
    /// cumulative CPU time deltas (precise) rather than `ps %cpu` (a decaying
    /// lifetime average). Returns false if the pid can't be sampled, so a missing
    /// process never *forces* a busy verdict.
    static func processBurningCPU(_ pid: Int32, sample: TimeInterval = 0.6,
                                  minCorePercent: Double = 8) -> Bool {
        guard let t0 = cpuSeconds(pid) else { return false }
        Thread.sleep(forTimeInterval: sample)
        guard let t1 = cpuSeconds(pid) else { return false }
        let usedCorePercent = (t1 - t0) / sample * 100
        return usedCorePercent >= minCorePercent
    }

    /// Cumulative CPU time (user+sys) of a pid in seconds, via `ps -o cputime`.
    /// Parses `[[DD-]HH:]MM:SS[.cc]`. nil if the process is gone/unreadable.
    private static func cpuSeconds(_ pid: Int32) -> Double? {
        let out = Shell.run("/bin/ps", ["-p", "\(pid)", "-o", "cputime="])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return nil }
        // Split optional "DD-" day prefix, then HH:MM:SS / MM:SS(.cc).
        var days = 0.0
        var rest = out
        if let dash = out.firstIndex(of: "-"), let d = Double(out[out.startIndex..<dash]) {
            days = d
            rest = String(out[out.index(after: dash)...])
        }
        let parts = rest.split(separator: ":").map { Double($0) ?? 0 }
        guard !parts.isEmpty else { return nil }
        var secs = 0.0
        for p in parts { secs = secs * 60 + p }   // ...:MM:SS folds left-to-right
        return days * 86_400 + secs
    }

    /// `contents of <loopVar>` returns a tab *reference*, not text, so the tab
    /// must be addressed explicitly as `tab j of window i`. Window order is
    /// unstable (front-most first), so we match by tty inside one atomic script,
    /// guarding each window with `try` (some windows raise on `tabs`).
    private static func appleTerminalReadScript(_ devTTY: String) -> String {
        """
        tell application "Terminal"
          set wc to count of windows
          repeat with i from 1 to wc
            try
              set tc to count of tabs of window i
              repeat with j from 1 to tc
                if (tty of tab j of window i) is "\(devTTY)" then
                  return (contents of tab j of window i)
                end if
              end repeat
            end try
          end repeat
        end tell
        return "READ_FAIL"
        """
    }

    private static func iTermReadScript(_ devTTY: String) -> String {
        """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if (tty of s) is "\(devTTY)" then
                  return (contents of s)
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return "READ_FAIL"
        """
    }

    private static func escapeShell(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "'\\''")
    }

    private static func open(_ command: String) -> Result {
        switch preferredTerminal() {
        case .iTerm: return run(iTermOpenScript(command))
        case .appleTerminal: return run(appleTerminalOpenScript(command))
        }
    }

    private enum TerminalApp { case appleTerminal, iTerm }

    private static func preferredTerminal() -> TerminalApp {
        // Explicit user choice (read from UserDefaults — thread-safe).
        switch UserDefaults.standard.string(forKey: AppSettings.Key.preferredTerminal) {
        case "Terminal": return .appleTerminal
        case "iTerm": return .iTerm
        default: break   // "auto"
        }
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        if running.contains("com.googlecode.iterm2") && !running.contains("com.apple.Terminal") {
            return .iTerm
        }
        return .appleTerminal
    }

    private static func run(_ script: String) -> Result {
        let out = Shell.osascript(script).trimmingCharacters(in: .whitespacesAndNewlines)
        return out == "ok" ? .activated : .notFound
    }

    /// Escapes a shell command string for embedding in an AppleScript literal.
    private static func escapeAS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func appleTerminalScript(_ devTTY: String) -> String {
        // `activate` must come AFTER reordering the window, otherwise Terminal
        // just brings its current front window forward and the target stays put.
        """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(devTTY)" then
                set selected of t to true
                set index of w to 1
                activate
                return "ok"
              end if
            end repeat
          end repeat
        end tell
        return "notfound"
        """
    }

    private static func appleTerminalSendScript(_ devTTY: String, _ line: String) -> String {
        // `do script ... in t` types the text into the existing tab's tty and
        // submits it (adds a return), which Claude Code receives as a prompt.
        """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(devTTY)" then
                set selected of t to true
                set index of w to 1
                activate
                do script "\(escapeAS(line))" in t
                return "ok"
              end if
            end repeat
          end repeat
        end tell
        return "notfound"
        """
    }

    private static func iTermSendScript(_ devTTY: String, _ line: String) -> String {
        """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "\(devTTY)" then
                  tell t to select
                  tell s to select
                  activate
                  tell s to write text "\(escapeAS(line))"
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return "notfound"
        """
    }

    private static func appleTerminalOpenScript(_ command: String) -> String {
        """
        tell application "Terminal"
          activate
          do script "\(escapeAS(command))"
          return "ok"
        end tell
        """
    }

    private static func iTermOpenScript(_ command: String) -> String {
        """
        tell application "iTerm2"
          activate
          set newWindow to (create window with default profile)
          tell current session of newWindow to write text "\(escapeAS(command))"
          return "ok"
        end tell
        """
    }

    private static func iTermScript(_ devTTY: String) -> String {
        """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "\(devTTY)" then
                  tell t to select
                  tell s to select
                  activate
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return "notfound"
        """
    }
}
