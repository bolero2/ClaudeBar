import Foundation

/// Reads `~/.ssh/config` to list concrete `Host` aliases, used to populate the
/// remote-hosts picker in Settings. Only a suggestion list — the actual SSH
/// connection lets `ssh` resolve the config itself.
enum SSHConfig {

    /// Concrete host aliases (patterns like `*` / `?` and the catch-all `Host *`
    /// are skipped), in file order, de-duplicated.
    static func hostAliases() -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config", isDirectory: false)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        var aliases: [String] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // A "Host" line may declare several space-separated aliases.
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2, parts[0].lowercased() == "host" else { continue }
            for token in parts.dropFirst() {
                let alias = String(token)
                guard !alias.contains("*"), !alias.contains("?"),
                      !aliases.contains(alias) else { continue }
                aliases.append(alias)
            }
        }
        return aliases
    }
}
