import Foundation

/// Reconstructs sessions from ~/.claude/projects and joins them with the live
/// `claude` processes so each session gets a status and (when live) a terminal
/// handle.
enum SessionScanner {

    /// How many of the most-recent sessions to enrich with model/branch by
    /// reading the JSONL tail. The rest are listed with cheap metadata only.
    static let detailLimit = 40

    static func scan() -> [Session] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: ClaudePaths.projectsDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var sessions: [Session] = []

        for dir in projectDirs {
            let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            let dirName = dir.lastPathComponent
            let cwd = ClaudePaths.decodeProjectDirName(dirName)

            guard let files = try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                sessions.append(Session(
                    id: file.deletingPathExtension().lastPathComponent,
                    cwd: cwd,
                    projectDirName: dirName,
                    gitBranch: nil,
                    model: nil,
                    lastActivity: mtime,
                    status: .inactive,
                    live: nil
                ))
            }
        }

        sessions.sort { $0.lastActivity > $1.lastActivity }

        let config = ConfigStore()

        // Enrich only the most recent sessions with model/branch from the tail.
        for i in sessions.indices where i < detailLimit {
            let url = ClaudePaths.projectsDir
                .appendingPathComponent(sessions[i].projectDirName, isDirectory: true)
                .appendingPathComponent(sessions[i].id + ".jsonl", isDirectory: false)
            let detail = parseTail(url)
            sessions[i].model = detail.model
            sessions[i].gitBranch = detail.gitBranch
            if let cwd = detail.cwd, !cwd.isEmpty {
                sessions[i].cwd = cwd   // real path, overrides lossy folder decode
            }
            sessions[i].contextTokens = detail.contextCurrent
            let baseModel = detail.model.map(Self.stripModelSuffix)
            let configExtended = config?.projectUsesExtendedContext(
                path: sessions[i].cwd, baseModel: baseModel) ?? false
            sessions[i].contextLimit = SessionContext.inferWindow(
                maxObserved: detail.contextMax, configExtended: configExtended)
        }

        attachLiveProcesses(&sessions)
        return sessions
    }

    /// Removes a trailing `[1m]` marker so the base model id can be matched
    /// against the config's `[1m]` key.
    private static func stripModelSuffix(_ model: String) -> String {
        model.hasSuffix("[1m]") ? String(model.dropLast(4)) : model
    }

    // MARK: - Tail parsing

    private static func parseTail(_ url: URL)
        -> (model: String?, gitBranch: String?, cwd: String?,
            contextCurrent: Int?, contextMax: Int) {
        let text = FileTail.tail(url)
        var model: String?
        var gitBranch: String?
        var cwd: String?
        var contextCurrent: Int?   // latest assistant turn's context
        var contextMax = 0         // peak context seen in the tail

        // Newest to oldest: keep the first value seen for model/branch/cwd and
        // the first (latest) assistant usage as the current context.
        for line in text.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let msg = obj["message"] as? [String: Any] {
                if model == nil, let m = msg["model"] as? String { model = m }
                if let usage = msg["usage"] as? [String: Any] {
                    let ctx = ((usage["input_tokens"] as? Int) ?? 0)
                        + ((usage["cache_read_input_tokens"] as? Int) ?? 0)
                        + ((usage["cache_creation_input_tokens"] as? Int) ?? 0)
                        + ((usage["output_tokens"] as? Int) ?? 0)
                    if ctx > 0 {
                        if contextCurrent == nil { contextCurrent = ctx }
                        contextMax = max(contextMax, ctx)
                    }
                }
            }
            if model == nil, let m = obj["model"] as? String { model = m }
            if gitBranch == nil, let b = obj["gitBranch"] as? String, !b.isEmpty {
                gitBranch = b
            }
            if cwd == nil, let c = obj["cwd"] as? String, !c.isEmpty {
                cwd = c
            }
        }
        return (model, gitBranch, cwd, contextCurrent, contextMax)
    }

    // MARK: - Live join

    private static func attachLiveProcesses(_ sessions: inout [Session]) {
        let live = ProcessProbe.liveProcesses()
        guard !live.isEmpty else { return }

        // Index live processes by the *encoded* cwd (lossless), matching the
        // project folder name. This avoids the lossy decode for paths whose
        // own segments contain `-` (e.g. ".../claude-bar").
        var liveByDir: [String: LiveProcess] = [:]
        for proc in live {
            if let cwd = proc.cwd { liveByDir[ClaudePaths.encodeCwd(cwd)] = proc }
        }

        // For each project folder that has a live process, the newest session
        // is the active one. `sessions` is already sorted newest-first.
        var claimedDirs = Set<String>()
        let now = Date()
        for i in sessions.indices {
            let dir = sessions[i].projectDirName
            guard let proc = liveByDir[dir] else { continue }
            guard !claimedDirs.contains(dir) else { continue }
            claimedDirs.insert(dir)
            sessions[i].live = proc
            let idle = now.timeIntervalSince(sessions[i].lastActivity)
            sessions[i].status = idle < 8 ? .busy : .waiting
        }
    }
}
