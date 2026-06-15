import Foundation

/// Minimal synchronous process runner for read-only system probes
/// (`ps`, `lsof`, `osascript`). Returns stdout as a UTF-8 string.
enum Shell {
    @discardableResult
    static func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 5) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Runs an AppleScript snippet via `osascript` and returns its output.
    @discardableResult
    static func osascript(_ script: String) -> String {
        run("/usr/bin/osascript", ["-e", script])
    }

    /// Runs a process feeding `stdin` to it, enforcing `timeout` (the process is
    /// killed and `nil` returned if it overruns). Used for the SSH remote probe:
    /// the probe script is piped in, and a hung/offline host can't block the UI
    /// refresh forever. Returns stdout, or nil on launch failure / timeout.
    static func runWithStdin(_ launchPath: String, _ args: [String],
                             stdin: String, timeout: TimeInterval = 12) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launchPath)
        proc.arguments = args
        let outPipe = Pipe()
        let inPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        proc.standardInput = inPipe
        do {
            try proc.run()
        } catch {
            return nil
        }
        // The probe script is a few KB — well under the pipe buffer, so a single
        // write + close won't deadlock against a not-yet-reading remote.
        if let data = stdin.data(using: .utf8) {
            inPipe.fileHandleForWriting.write(data)
        }
        try? inPipe.fileHandleForWriting.close()

        // Read stdout on a background queue so we can bound the wait.
        let sem = DispatchSemaphore(value: 0)
        var output = ""
        DispatchQueue.global().async {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            output = String(data: data, encoding: .utf8) ?? ""
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            return nil
        }
        proc.waitUntilExit()
        return output
    }
}

/// Reads the trailing `maxBytes` of a (potentially large) file without loading
/// the whole thing. Used to recover the most recent records of a session JSONL.
enum FileTail {
    static func tail(_ url: URL, maxBytes: Int = 65_536) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
