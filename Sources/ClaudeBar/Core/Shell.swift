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
