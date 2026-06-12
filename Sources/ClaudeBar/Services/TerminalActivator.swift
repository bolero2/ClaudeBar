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
    static func activate(_ proc: LiveProcess, cwd: String, sessionId: String) -> Result {
        guard let tty = proc.tty else {
            return openResume(cwd: cwd, sessionId: sessionId)
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
        return openResume(cwd: cwd, sessionId: sessionId)
    }

    /// Opens a new terminal window, cd's into the session's directory and runs
    /// `claude --resume <sessionId>` to restore an ended session.
    @discardableResult
    static func openResume(cwd: String, sessionId: String) -> Result {
        open("cd '\(escapeShell(cwd))' && claude --resume \(sessionId)")
    }

    /// Opens a new terminal window and starts a fresh `claude` session in `cwd`.
    @discardableResult
    static func openNew(cwd: String) -> Result {
        open("cd '\(escapeShell(cwd))' && claude")
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
        """
        tell application "Terminal"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(devTTY)" then
                set selected of t to true
                set frontmost of w to true
                set index of w to 1
                return "ok"
              end if
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
          activate
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "\(devTTY)" then
                  tell s to select
                  set frontmost of w to true
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
