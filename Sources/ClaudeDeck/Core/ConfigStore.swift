import Foundation

/// Reads and lightly parses ~/.claude.json. The file mixes many heterogeneous
/// shapes, so we use JSONSerialization and pull out only the keys we need
/// rather than modeling the whole document with Codable.
struct ConfigStore {
    let root: [String: Any]

    init?(url: URL = ClaudePaths.configFile) {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any]
        else { return nil }
        self.root = dict
    }

    // MARK: oauthAccount

    func account(activeUuidsRunning: Bool = true) -> Account? {
        guard let a = root["oauthAccount"] as? [String: Any],
              let uuid = a["accountUuid"] as? String,
              let email = a["emailAddress"] as? String
        else { return nil }
        return Account(
            accountUuid: uuid,
            email: email,
            displayName: a["displayName"] as? String,
            organizationName: a["organizationName"] as? String,
            organizationRole: a["organizationRole"] as? String,
            billingType: a["billingType"] as? String,
            isActive: true
        )
    }

    // MARK: mcpServers (global)

    func globalMCPServers() -> [MCPServerInfo] {
        var out: [MCPServerInfo] = []
        let servers = root["mcpServers"] as? [String: Any] ?? [:]
        for (name, raw) in servers {
            let cfg = raw as? [String: Any] ?? [:]
            out.append(MCPServerInfo(
                name: name, scope: .global,
                command: Self.commandSummary(cfg),
                transport: cfg["type"] as? String ?? "stdio",
                enabled: true, projectPath: nil, toggleable: true))
        }
        // Servers we've disabled live in our sidecar file, not in mcpServers.
        for (name, raw) in MCPService.disabledGlobalServers() {
            let cfg = raw as? [String: Any] ?? [:]
            out.append(MCPServerInfo(
                name: name, scope: .global,
                command: Self.commandSummary(cfg),
                transport: cfg["type"] as? String ?? "stdio",
                enabled: false, projectPath: nil, toggleable: true))
        }
        return out.sorted { $0.name < $1.name }
    }

    // MARK: projects

    var projects: [String: Any] {
        root["projects"] as? [String: Any] ?? [:]
    }

    /// Whether the given project path recently used the 1M context variant of
    /// `baseModel` (e.g. `lastModelUsage` contains `claude-opus-4-8[1m]`).
    /// Used to detect 1M sessions before they exceed the standard window.
    func projectUsesExtendedContext(path: String, baseModel: String?) -> Bool {
        guard let p = projects[path] as? [String: Any],
              let lmu = p["lastModelUsage"] as? [String: Any] else { return false }
        if let base = baseModel, !base.isEmpty {
            return lmu.keys.contains { $0 == base + "[1m]" }
        }
        return lmu.keys.contains { $0.contains("[1m]") }
    }

    /// Project-scoped MCP servers, derived from `.mcp.json` entries that Claude
    /// tracks per project via enabled/disabled lists, plus any inline servers.
    func projectMCPServers() -> [MCPServerInfo] {
        var out: [MCPServerInfo] = []
        for (path, raw) in projects {
            guard let p = raw as? [String: Any] else { continue }
            let enabled = (p["enabledMcpjsonServers"] as? [String]) ?? []
            let disabled = (p["disabledMcpjsonServers"] as? [String]) ?? []
            let inline = (p["mcpServers"] as? [String: Any]) ?? [:]

            for name in enabled {
                out.append(MCPServerInfo(name: name, scope: .project,
                                         command: ".mcp.json", transport: "stdio",
                                         enabled: true, projectPath: path, toggleable: true))
            }
            for name in disabled {
                out.append(MCPServerInfo(name: name, scope: .project,
                                         command: ".mcp.json", transport: "stdio",
                                         enabled: false, projectPath: path, toggleable: true))
            }
            // Inline project servers have no enable/disable list, so they are
            // shown but not toggleable from here.
            for (name, cfg) in inline {
                let c = cfg as? [String: Any] ?? [:]
                out.append(MCPServerInfo(name: name, scope: .project,
                                         command: Self.commandSummary(c),
                                         transport: c["type"] as? String ?? "stdio",
                                         enabled: true, projectPath: path, toggleable: false))
            }
        }
        return out.sorted { ($0.projectPath ?? "") < ($1.projectPath ?? "") }
    }

    /// Aggregates `lastModelUsage` across all projects into per-model token sums.
    /// Used as a coarse local usage signal for the Usage tab.
    func aggregatedModelUsage() -> [String: ModelTokenSum] {
        var totals: [String: ModelTokenSum] = [:]
        for (_, raw) in projects {
            guard let p = raw as? [String: Any],
                  let lmu = p["lastModelUsage"] as? [String: Any] else { continue }
            for (model, mRaw) in lmu {
                guard let m = mRaw as? [String: Any] else { continue }
                var sum = totals[model] ?? ModelTokenSum()
                sum.inputTokens += (m["inputTokens"] as? Int) ?? 0
                sum.outputTokens += (m["outputTokens"] as? Int) ?? 0
                sum.cacheReadTokens += (m["cacheReadInputTokens"] as? Int) ?? 0
                sum.cacheCreationTokens += (m["cacheCreationInputTokens"] as? Int) ?? 0
                sum.costUSD += (m["costUSD"] as? Double) ?? 0
                totals[model] = sum
            }
        }
        return totals
    }

    private static func commandSummary(_ cfg: [String: Any]) -> String {
        if let url = cfg["url"] as? String { return url }
        let command = cfg["command"] as? String ?? ""
        let args = (cfg["args"] as? [String]) ?? []
        return ([command] + args).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

struct ModelTokenSum {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadTokens = 0
    var cacheCreationTokens = 0
    var costUSD = 0.0

    var total: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }
}
