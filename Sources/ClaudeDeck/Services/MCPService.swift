import Foundation

/// Enables/disables MCP servers by editing `~/.claude.json`.
///
/// Safety:
/// - Project `.mcp.json` servers use Claude Code's own `enabledMcpjsonServers` /
///   `disabledMcpjsonServers` lists, which Claude preserves.
/// - Global `mcpServers` has no disable flag, so a disabled global server's
///   config is stashed in a sidecar file we own (`claudedeck-disabled-mcp.json`)
///   and removed from `mcpServers`. This avoids losing the config if Claude
///   rewrites `~/.claude.json` and drops unknown keys.
/// - Writes are atomic, and a single rolling backup is kept.
///
/// Changes take effect for newly started sessions; running sessions keep their
/// already-loaded servers.
enum MCPService {

    enum Result {
        case ok
        case failed(String)
    }

    private static var sidecarURL: URL {
        ClaudePaths.claudeDir.appendingPathComponent("claudedeck-disabled-mcp.json")
    }

    /// Disabled global servers stashed in our sidecar file (name -> config).
    static func disabledGlobalServers() -> [String: Any] {
        guard let data = try? Data(contentsOf: sidecarURL),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return dict
    }

    static func toggle(_ server: MCPServerInfo) -> Result {
        let enable = !server.enabled
        switch server.scope {
        case .global:
            return setGlobalEnabled(server.name, enabled: enable)
        case .project:
            guard let path = server.projectPath else { return .failed("프로젝트 경로 없음") }
            return setProjectEnabled(projectPath: path, name: server.name, enabled: enable)
        }
    }

    // MARK: - Register (global)

    /// Registers a new global MCP server by writing `config` under `mcpServers`
    /// in `~/.claude.json`. Takes effect for newly started sessions.
    static func addGlobalServer(name: String, config: [String: Any]) -> Result {
        mutateConfig { root in
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            servers[name] = config
            root["mcpServers"] = servers
        }
    }

    // MARK: - Global

    static func setGlobalEnabled(_ name: String, enabled: Bool) -> Result {
        var sidecar = disabledGlobalServers()
        let result = mutateConfig { root in
            var servers = root["mcpServers"] as? [String: Any] ?? [:]
            if enabled {
                if let cfg = sidecar[name] {
                    servers[name] = cfg
                    sidecar[name] = nil
                }
            } else {
                if let cfg = servers[name] {
                    sidecar[name] = cfg
                    servers[name] = nil
                }
            }
            root["mcpServers"] = servers
        }
        guard case .ok = result else { return result }
        return writeSidecar(sidecar)
    }

    // MARK: - Project (.mcp.json)

    static func setProjectEnabled(projectPath: String, name: String, enabled: Bool) -> Result {
        mutateConfig { root in
            var projects = root["projects"] as? [String: Any] ?? [:]
            var p = projects[projectPath] as? [String: Any] ?? [:]
            var on = Set(p["enabledMcpjsonServers"] as? [String] ?? [])
            var off = Set(p["disabledMcpjsonServers"] as? [String] ?? [])
            if enabled { on.insert(name); off.remove(name) }
            else { off.insert(name); on.remove(name) }
            p["enabledMcpjsonServers"] = on.sorted()
            p["disabledMcpjsonServers"] = off.sorted()
            projects[projectPath] = p
            root["projects"] = projects
        }
    }

    // MARK: - Atomic config edit

    private static func mutateConfig(_ change: (inout [String: Any]) -> Void) -> Result {
        let url = ClaudePaths.configFile
        guard let data = try? Data(contentsOf: url),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return .failed("~/.claude.json 읽기 실패") }

        // Rolling backup before we touch it.
        try? data.write(to: url.appendingPathExtension("claudedeck-bak"))

        change(&root)

        guard let out = try? JSONSerialization.data(withJSONObject: root) else {
            return .failed("직렬화 실패")
        }
        do {
            try out.write(to: url, options: .atomic)
            return .ok
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func writeSidecar(_ dict: [String: Any]) -> Result {
        guard let out = try? JSONSerialization.data(withJSONObject: dict) else {
            return .failed("사이드카 직렬화 실패")
        }
        do {
            try out.write(to: sidecarURL, options: .atomic)
            return .ok
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
