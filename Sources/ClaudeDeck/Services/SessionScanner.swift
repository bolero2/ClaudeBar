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
            let dirName = sessions[i].projectDirName
            let detail = parseTail(url, projectDirName: dirName)
            sessions[i].model = detail.model
            sessions[i].gitBranch = detail.gitBranch
            // The session's true launch cwd is the one whose encoding matches
            // its project folder — NOT a sub-agent's cwd that may also appear in
            // the transcript. Using the wrong cwd breaks `claude --resume`.
            sessions[i].cwd = detail.matchedCwd
                ?? matchedCwdInHead(url, projectDirName: dirName)
                ?? ClaudePaths.decodeProjectDirName(dirName)
            sessions[i].contextTokens = detail.contextCurrent
            sessions[i].activity = detail.activity
            sessions[i].permissionMode = detail.permissionMode
            sessions[i].resumable = detail.hasConversation
            let baseModel = detail.model.map(Self.stripModelSuffix)
            let configExtended = config?.projectUsesExtendedContext(
                path: sessions[i].cwd, baseModel: baseModel) ?? false
            sessions[i].contextLimit = SessionContext.inferWindow(
                maxObserved: detail.contextMax, configExtended: configExtended)
        }

        attachLiveProcesses(&sessions)
        overlayCachedContext(&sessions)
        return sessions
    }

    /// Fills context/model from the statusLine cache for any session whose JSONL
    /// yielded none. On Claude Code 2.1.x a session's transcript isn't written to
    /// disk while it runs (only flushed on clean exit), so live — and even
    /// force-closed — sessions have no `usage` on disk; `claudedeck-statusline.sh`
    /// captures the last figures instead. Applied only when the transcript gave
    /// nothing, so a real `usage` record always wins. (Sessions that ran before
    /// the helper was set up have no cache and stay blank — unrecoverable.)
    private static func overlayCachedContext(_ sessions: inout [Session]) {
        for i in sessions.indices where sessions[i].contextTokens == nil {
            guard let e = StatusCache.entry(for: sessions[i].id) else { continue }
            sessions[i].contextTokens = e.contextTokens
            sessions[i].contextLimit = e.contextLimit
            if sessions[i].model == nil { sessions[i].model = e.model }
        }
    }

    /// Removes a trailing `[1m]` marker so the base model id can be matched
    /// against the config's `[1m]` key.
    private static func stripModelSuffix(_ model: String) -> String {
        model.hasSuffix("[1m]") ? String(model.dropLast(4)) : model
    }

    /// Searches the head of the transcript for the cwd whose encoding matches
    /// the project folder (the true launch dir), as a fallback when the tail
    /// only contains sub-agent cwds.
    private static func matchedCwdInHead(_ url: URL, projectDirName: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 16_384)) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let c = obj["cwd"] as? String, !c.isEmpty,
                  ClaudePaths.encodeCwd(c) == projectDirName else { continue }
            return c
        }
        return nil
    }

    // MARK: - Tail parsing

    private static func parseTail(_ url: URL, projectDirName: String)
        -> (model: String?, gitBranch: String?, matchedCwd: String?,
            contextCurrent: Int?, contextMax: Int, activity: String?,
            permissionMode: String?, hasConversation: Bool) {
        let text = FileTail.tail(url)
        var model: String?
        var gitBranch: String?
        var matchedCwd: String?    // cwd whose encoding == projectDirName (true launch dir)
        var contextCurrent: Int?   // latest assistant turn's context
        var contextMax = 0         // peak context seen in the tail
        var activity: String?      // latest assistant action (running tool / message)
        var permissionMode: String?
        var hasConversation = false  // saw a real user/assistant turn (→ resumable)

        // Newest to oldest: keep the first value seen for model/branch and the
        // first (latest) assistant usage as the current context.
        for line in text.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            // A resumable transcript has at least one conversation turn. A
            // force-quit stub holds only metadata records (e.g. `ai-title`), so
            // it never matches here and the session is flagged non-resumable.
            if let t = obj["type"] as? String, t == "user" || t == "assistant" {
                hasConversation = true
            }

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
                if activity == nil, (obj["type"] as? String) == "assistant",
                   let content = msg["content"] as? [[String: Any]] {
                    activity = summarizeContent(content)
                }
            }
            if model == nil, let m = obj["model"] as? String { model = m }
            if gitBranch == nil, let b = obj["gitBranch"] as? String, !b.isEmpty {
                gitBranch = b
            }
            if matchedCwd == nil, let c = obj["cwd"] as? String, !c.isEmpty,
               ClaudePaths.encodeCwd(c) == projectDirName {
                matchedCwd = c
            }
            if permissionMode == nil, let p = obj["permissionMode"] as? String, !p.isEmpty {
                permissionMode = p
            }
        }
        return (model, gitBranch, matchedCwd, contextCurrent, contextMax,
                activity, permissionMode, hasConversation)
    }

    /// Summarizes an assistant message's content blocks into a one-line activity:
    /// the tool it's invoking (preferred) or a snippet of its text.
    private static func summarizeContent(_ blocks: [[String: Any]]) -> String? {
        for block in blocks.reversed()
        where (block["type"] as? String) == "tool_use" {
            guard let name = block["name"] as? String else { continue }
            let input = block["input"] as? [String: Any] ?? [:]
            return name + briefInput(input)
        }
        for block in blocks.reversed()
        where (block["type"] as? String) == "text" {
            guard let text = block["text"] as? String else { continue }
            let line = text.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return String(line.prefix(80)) }
        }
        return nil
    }

    private static func briefInput(_ input: [String: Any]) -> String {
        let value = (input["command"] as? String)
            ?? (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent }
            ?? (input["pattern"] as? String)
            ?? (input["path"] as? String).map { ($0 as NSString).lastPathComponent }
            ?? (input["description"] as? String)
        guard let v = value, !v.isEmpty else { return "" }
        let oneLine = v.replacingOccurrences(of: "\n", with: " ")
        return ": " + String(oneLine.prefix(48))
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

        // Freshest statusLine cache per folder. This — not jsonl mtime — names the
        // session that is actually running: Claude Code 2.1.x may write the live
        // transcript to disk late or not at all (so the running session can look
        // older than a sibling, or be absent entirely), whereas the statusLine
        // cache `ts` is rewritten on every render.
        var freshestCacheByDir: [String: StatusCache.Entry] = [:]
        for e in StatusCache.allEntries() {
            guard let cwd = e.cwd else { continue }
            let dir = ClaudePaths.encodeCwd(cwd)
            if let cur = freshestCacheByDir[dir], cur.ts >= e.ts { continue }
            freshestCacheByDir[dir] = e
        }

        var indicesByDir: [String: [Int]] = [:]
        for i in sessions.indices {
            indicesByDir[sessions[i].projectDirName, default: []].append(i)
        }

        let now = Date()
        var synthesized: [Session] = []
        for (dir, proc) in liveByDir {
            if let cache = freshestCacheByDir[dir] {
                if let i = sessions.firstIndex(where: { $0.id == cache.sessionId }) {
                    markLive(&sessions[i], proc: proc, cache: cache, now: now)
                } else {
                    // The live session has no transcript on disk yet — build it
                    // from the cache so it still shows up (live + context).
                    synthesized.append(synthesizeLive(cache: cache, proc: proc, dir: dir, now: now))
                }
                continue
            }
            // No cache (helper not installed): fall back to newest-by-mtime.
            if let i = indicesByDir[dir]?.max(by: { sessions[$0].lastActivity < sessions[$1].lastActivity }) {
                sessions[i].live = proc
                if sessions[i].permissionMode == nil {
                    sessions[i].permissionMode = proc.permissionMode
                }
                let idle = now.timeIntervalSince(sessions[i].lastActivity)
                sessions[i].status = idle < 8 ? .busy : .waiting
            }
        }

        if !synthesized.isEmpty {
            sessions.append(contentsOf: synthesized)
            sessions.sort { $0.lastActivity > $1.lastActivity }
        }
    }

    /// Marks an existing session live and fills context/model/recency from its
    /// statusLine cache (transcript values, when present, still win for context).
    private static func markLive(_ s: inout Session, proc: LiveProcess,
                                 cache: StatusCache.Entry, now: Date) {
        s.live = proc
        // The statusLine cache is the authoritative live state: Claude Code hands
        // it the real model id (with the `[1m]` marker) and the real context-window
        // size on every render. The on-disk transcript records only the *base*
        // model id and an inferred window, and on 2.1.x it may lag behind a running
        // session — so for a live row the cache wins for model + window.
        s.contextLimit = cache.contextLimit
        if let m = cache.model { s.model = m }
        if cache.contextTokens > 0 || s.contextTokens == nil {
            s.contextTokens = cache.contextTokens
        }
        // Permission mode: keep the transcript's value when present (it tracks
        // mid-session changes), else fall back to the launch flag from the process.
        if s.permissionMode == nil { s.permissionMode = proc.permissionMode }
        s.lastActivity = max(s.lastActivity, Date(timeIntervalSince1970: cache.ts))
        let idle = now.timeIntervalSince(s.lastActivity)
        s.status = idle < 8 ? .busy : .waiting
    }

    /// Builds a Session for a live process whose transcript isn't on disk, using
    /// only the statusLine cache.
    private static func synthesizeLive(cache: StatusCache.Entry, proc: LiveProcess,
                                       dir: String, now: Date) -> Session {
        let when = Date(timeIntervalSince1970: cache.ts)
        var s = Session(
            id: cache.sessionId,
            cwd: cache.cwd ?? proc.cwd ?? ClaudePaths.decodeProjectDirName(dir),
            projectDirName: dir,
            gitBranch: nil,
            model: cache.model,
            lastActivity: when,
            status: now.timeIntervalSince(when) < 8 ? .busy : .waiting,
            live: proc)
        s.contextTokens = cache.contextTokens
        s.contextLimit = cache.contextLimit
        s.permissionMode = proc.permissionMode
        return s
    }
}
