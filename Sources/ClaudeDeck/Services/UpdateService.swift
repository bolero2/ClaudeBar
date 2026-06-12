import Foundation
import AppKit

/// Lightweight self-updater for the ad-hoc GitHub-Releases distribution — no
/// Sparkle / external dependency. Checks the latest release, and (on user
/// confirmation) downloads the zip, swaps the running `.app` bundle in place
/// with a rollback-safe helper script, and relaunches.
enum UpdateService {
    static let repo = "bolero2/ClaudeDeck"
    static let assetName = "ClaudeDeck.zip"
    static let appBundleName = "ClaudeDeck.app"

    struct Release {
        let version: String   // tag without leading "v", e.g. "1.1.0"
        let tag: String       // "v1.1.0"
        let notes: String
        let zipURL: URL
    }

    /// Current app version from the bundle (CFBundleShortVersionString).
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// True only when running from an installed `.app` bundle (updates can't
    /// swap the bare SPM executable).
    static var canSelfUpdate: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    // MARK: - Version check

    /// Fetches the latest GitHub release; nil on network/parse failure.
    static func latestRelease() async -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")
        else { return nil }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ClaudeDeck", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String
        else { return nil }

        let notes = (obj["body"] as? String) ?? ""
        let assets = (obj["assets"] as? [[String: Any]]) ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String) == assetName }),
              let urlStr = asset["browser_download_url"] as? String,
              let zipURL = URL(string: urlStr)
        else { return nil }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, tag: tag, notes: notes, zipURL: zipURL)
    }

    /// True if `latest` is a strictly newer semantic version than `current`.
    static func isNewer(_ latest: String, than current: String) -> Bool {
        compareVersions(latest, current) == .orderedDescending
    }

    /// Compares dotted numeric versions (e.g. "1.10.0" vs "1.9.0").
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y ? .orderedDescending : .orderedAscending }
        }
        return .orderedSame
    }

    // MARK: - Download + install

    /// Downloads the release zip and launches a detached helper that swaps the
    /// bundle once this process exits, then relaunches. Returns nil on success
    /// (the caller must then terminate the app), or an error message on failure.
    static func downloadAndInstall(_ release: Release) async -> String? {
        let fm = FileManager.default
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else {
            return "설치된 앱(.app)에서만 업데이트할 수 있습니다."
        }

        // 1) Download the zip.
        guard let (tmp, resp) = try? await URLSession.shared.download(from: release.zipURL),
              (resp as? HTTPURLResponse)?.statusCode == 200 else {
            return "다운로드에 실패했습니다."
        }

        let work = fm.temporaryDirectory
            .appendingPathComponent("claudedeck-update-\(UUID().uuidString)")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent(assetName)
        do { try fm.moveItem(at: tmp, to: zip) }
        catch { return "임시 파일 처리에 실패했습니다." }

        // 2) Unzip via ditto and verify the new bundle.
        let extracted = work.appendingPathComponent("extracted")
        _ = Shell.run("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path], timeout: 60)
        let newApp = extracted.appendingPathComponent(appBundleName)
        guard fm.fileExists(atPath: newApp.path) else {
            try? fm.removeItem(at: work)
            return "압축 해제에 실패했습니다."
        }
        _ = Shell.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

        // 3) Rollback-safe swap script: wait for this PID to exit, move the old
        //    bundle aside, copy in the new one (restore on failure), relaunch.
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = work.appendingPathComponent("swap.sh")
        let body = """
        #!/bin/bash
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        BK="\(bundlePath).bak-$$"
        if /bin/mv "\(bundlePath)" "$BK"; then
          if /usr/bin/ditto "\(newApp.path)" "\(bundlePath)"; then
            /usr/bin/xattr -dr com.apple.quarantine "\(bundlePath)" 2>/dev/null
            /bin/rm -rf "$BK"
          else
            /bin/rm -rf "\(bundlePath)"; /bin/mv "$BK" "\(bundlePath)"
          fi
        fi
        /usr/bin/open "\(bundlePath)"
        /bin/rm -rf "\(work.path)"
        """
        do { try body.write(to: script, atomically: true, encoding: .utf8) }
        catch { try? fm.removeItem(at: work); return "업데이트 스크립트 작성에 실패했습니다." }
        _ = Shell.run("/bin/chmod", ["+x", script.path])

        // 4) Launch the helper detached (survives our termination).
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script.path]
        do { try proc.run() }
        catch { try? fm.removeItem(at: work); return "업데이트 실행에 실패했습니다." }

        return nil   // success — caller terminates the app; helper relaunches it
    }
}
