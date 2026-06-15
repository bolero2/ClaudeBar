import Foundation

/// Discovers claude sessions on a remote SSH host by piping a small Python probe
/// over `ssh <host> python3 -` and decoding the JSON it prints. Nothing is
/// installed on the remote — the probe runs from stdin and exits. Reads only
/// metadata (model / branch / token counts / permission mode / last activity),
/// never transcript bodies or secrets.
enum RemoteScanner {

    /// Probes one host and returns its sessions tagged with `remoteHost`. Empty on
    /// offline / timeout / parse failure (so a dead host never blocks the refresh).
    static func scan(host: String) -> [Session] {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        let args = sshOptions + [trimmed, "python3", "-"]
        guard let out = Shell.runWithStdin("/usr/bin/ssh", args, stdin: probe, timeout: 12),
              let data = jsonSlice(out)?.data(using: .utf8),
              let dtos = try? JSONDecoder().decode([RemoteSessionDTO].self, from: data)
        else { return [] }

        return dtos.map { dto in
            var s = Session(
                id: dto.id,
                cwd: dto.cwd,
                projectDirName: dto.projectDirName,
                gitBranch: dto.gitBranch,
                model: dto.model,
                lastActivity: Date(timeIntervalSince1970: dto.lastActivity),
                status: SessionStatus(rawValue: dto.status) ?? .inactive,
                live: nil)
            s.remoteHost = trimmed
            s.permissionMode = dto.permissionMode
            s.contextTokens = dto.contextTokens
            s.contextLimit = dto.contextLimit
            s.activity = dto.activity
            s.resumable = dto.resumable ?? true
            // A remote row has no local LiveProcess; its running state is carried
            // by `status` (busy/waiting/inactive) and surfaced via `Session.isLive`.
            return s
        }
    }

    /// Reuse one master connection per host (ControlPersist) so repeated refreshes
    /// don't pay the SSH handshake each time. BatchMode avoids any interactive
    /// prompt blocking the probe; ConnectTimeout bounds an unreachable host.
    private static let sshOptions = [
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=6",
        "-o", "ControlMaster=auto",
        "-o", "ControlPath=/tmp/.claudedeck-ssh-%r@%h:%p",
        "-o", "ControlPersist=60s",
    ]

    /// The probe may print a stray locale warning to stdout-adjacent streams; pull
    /// out the JSON array (first '[' … last ']').
    private static func jsonSlice(_ s: String) -> String? {
        guard let lo = s.firstIndex(of: "["), let hi = s.lastIndex(of: "]"),
              lo <= hi else { return nil }
        return String(s[lo...hi])
    }
}

/// One session as emitted by the remote probe (see `RemoteScanner.probe`).
private struct RemoteSessionDTO: Decodable {
    let id: String
    let projectDirName: String
    let cwd: String
    let model: String?
    let gitBranch: String?
    let contextTokens: Int?
    let contextLimit: Int
    let lastActivity: Double
    let permissionMode: String?
    let activity: String?
    let resumable: Bool?
    let live: Bool
    let status: String
}

extension RemoteScanner {
    /// Inline Python 3 probe. Raw string so Python's `\n` literals are preserved
    /// verbatim. Mirrors `SessionScanner.parseTail` + the live-process join, but
    /// matches a live `claude` to its session by comparing the process's real cwd
    /// (`/proc/<pid>/cwd`) to the transcript's `cwd` — no encoding round-trip.
    static let probe = #"""
import os, sys, json, glob, time

HOME = os.path.expanduser("~")
PROJECTS = os.path.join(HOME, ".claude", "projects")
DETAIL = 20
TAIL = 65536
STD, EXT = 200000, 1000000

def tail_text(path):
    sz = os.path.getsize(path)
    with open(path, "rb") as fh:
        fh.seek(max(0, sz - TAIL))
        return fh.read().decode("utf-8", "ignore")

def summarize(blocks):
    for b in reversed(blocks):
        if b.get("type") == "tool_use" and b.get("name"):
            inp = b.get("input", {}) or {}
            v = (inp.get("command") or inp.get("file_path") or inp.get("pattern")
                 or inp.get("path") or inp.get("description") or "")
            v = str(v).replace("\n", " ")[:48]
            return b["name"] + ((": " + v) if v else "")
    for b in reversed(blocks):
        if b.get("type") == "text" and b.get("text"):
            return b["text"].replace("\n", " ").strip()[:80]
    return None

def parse_tail(path):
    model = branch = pmode = activity = matched = None
    cur = None; mx = 0; has_conv = False
    for line in reversed(tail_text(path).split("\n")):
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        t = o.get("type")
        if t in ("user", "assistant"):
            has_conv = True
        m = o.get("message") if isinstance(o.get("message"), dict) else None
        if m:
            if model is None and m.get("model"):
                model = m["model"]
            u = m.get("usage")
            if isinstance(u, dict):
                c = (u.get("input_tokens", 0) + u.get("cache_read_input_tokens", 0)
                     + u.get("cache_creation_input_tokens", 0) + u.get("output_tokens", 0))
                if c > 0:
                    if cur is None:
                        cur = c
                    mx = max(mx, c)
            if activity is None and t == "assistant" and isinstance(m.get("content"), list):
                activity = summarize(m["content"])
        if model is None and o.get("model"):
            model = o["model"]
        if branch is None and o.get("gitBranch"):
            branch = o["gitBranch"]
        if matched is None and o.get("cwd"):
            matched = o["cwd"]
        if pmode is None and o.get("permissionMode"):
            pmode = o["permissionMode"]
    limit = EXT if mx > STD else STD
    return dict(model=model, gitBranch=branch, contextTokens=cur, contextLimit=limit,
                permissionMode=pmode, activity=activity, matchedCwd=matched,
                hasConversation=has_conv)

def decode_dir(name):
    return ("/" + name[1:].replace("-", "/")) if name.startswith("-") else name

def live_procs():
    out = {}
    try:
        ps = os.popen("ps -eo pid=,args=").read()
    except Exception:
        return out
    for line in ps.split("\n"):
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) < 2:
            continue
        pid, args = parts[0], parts[1]
        first = args.split()[0]
        base = first.rsplit("/", 1)[-1]
        if not (base == "claude" or "/claude" in first):
            continue
        if "claude-bar" in args or " mcp" in args:
            continue
        try:
            cwd = os.readlink("/proc/%s/cwd" % pid)
        except Exception:
            cwd = None
        toks = args.split()
        pm = None
        for i, tk in enumerate(toks):
            if tk == "--dangerously-skip-permissions":
                pm = "bypassPermissions"
            elif tk == "--permission-mode" and i + 1 < len(toks):
                pm = toks[i + 1]
            elif tk.startswith("--permission-mode="):
                pm = tk.split("=", 1)[1]
        out[pid] = (cwd, pm)
    return out

def main():
    sessions = []
    if not os.path.isdir(PROJECTS):
        print("[]"); return
    files = []
    for d in glob.glob(PROJECTS + "/*"):
        if not os.path.isdir(d):
            continue
        for f in glob.glob(d + "/*.jsonl"):
            try:
                files.append((f, os.path.getmtime(f), os.path.basename(d)))
            except Exception:
                pass
    files.sort(key=lambda x: x[1], reverse=True)

    live = live_procs()
    live_cwds = set(c for c, _ in live.values() if c)
    now = time.time()

    seen_live = set()
    for f, mt, dirname in files[:DETAIL]:
        det = parse_tail(f)
        cwd = det.get("matchedCwd") or decode_dir(dirname)
        s = dict(id=os.path.basename(f)[:-6], projectDirName=dirname, cwd=cwd,
                 model=det.get("model"), gitBranch=det.get("gitBranch"),
                 contextTokens=det.get("contextTokens"),
                 contextLimit=det.get("contextLimit", STD),
                 lastActivity=mt, permissionMode=det.get("permissionMode"),
                 activity=det.get("activity"),
                 resumable=det.get("hasConversation", True),
                 live=False, status="inactive")
        if cwd in live_cwds and cwd not in seen_live:
            seen_live.add(cwd)
            s["live"] = True
            s["status"] = "busy" if (now - mt) < 8 else "waiting"
            if not s["permissionMode"]:
                for c, pm in live.values():
                    if c == cwd and pm:
                        s["permissionMode"] = pm
                        break
        sessions.append(s)

    # Live claude whose cwd has no transcript yet (brand-new / buffering session):
    # synthesize a minimal live row so it's visible, like the local app does.
    # No session id is known yet, so it isn't resumable until its jsonl appears.
    for c, pm in live.values():
        if not c or c in seen_live:
            continue
        seen_live.add(c)
        sessions.append(dict(id="live:" + c, projectDirName="", cwd=c,
                             model=None, gitBranch=None, contextTokens=None,
                             contextLimit=STD, lastActivity=now, permissionMode=pm,
                             activity=None, resumable=False, live=True, status="waiting"))
    print(json.dumps(sessions))

main()
"""#
}
