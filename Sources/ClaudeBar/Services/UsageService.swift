import Foundation

/// Computes token usage from the local JSONL transcripts: rolling 5h/7day
/// windows, a daily histogram, and headline stats.
///
/// Performance: a full 30-day scan must stay well under a second so the Usage
/// tab is ready on first open. Three things keep it fast:
///   1. Byte-level (UTF-8) scanning — Swift `String` Unicode operations are far
///      too slow for multi-MB transcripts; we work on raw bytes.
///   2. ISO-8601 UTC timestamps are lexicographically ordered, so window
///      membership is a string-prefix comparison — no `Date` parsing in the loop.
///   3. A per-file cache keyed by modification time, so only the active session
///      files are re-parsed on subsequent refreshes.
///
/// The accurate rate-limit windows that `/usage` shows come from an
/// authenticated Anthropic endpoint; that path is stubbed (`officialUsage`).
enum UsageService {

    static let historyDays = 30

    struct Snapshot {
        var windows: [UsageWindow]
        var daily: [DailyUsage]
        var lifetimeByModel: [String: ModelTokenSum]
        var totalTokensHistory: Int
        var todayTokens: Int
        var todayCost: Double
        var historyCost: Double
        var topModel: String?
        var officialAvailable: Bool
    }

    // MARK: Per-file cache

    private struct FileStats {
        var mtime: Date
        var daily: [String: Int]               // local "YYYY-MM-DD" -> tokens
        var dailyCost: [String: Double]        // local "YYYY-MM-DD" -> est. cost
        var models: [String: Int]
        var recent: [(ts: String, tok: ModelTokenSum, cost: Double)]  // ts = 19-char prefix
    }

    /// Single-flight (one usage task at a time), so a plain dictionary is safe.
    nonisolated(unsafe) private static var cache: [String: FileStats] = [:]

    static func snapshot(now: Date = Date()) -> Snapshot {
        // Window cutoffs compare against the transcripts' UTC timestamps.
        let fiveHoursAgo = isoPrefix(now.addingTimeInterval(-5 * 3600))
        let sevenDaysAgo = isoPrefix(now.addingTimeInterval(-7 * 24 * 3600))
        let recentCutoff = isoPrefix(now.addingTimeInterval(-8 * 24 * 3600))

        // Daily histogram buckets by local day.
        let offsetSeconds = TimeZone.current.secondsFromGMT(for: now)
        let historyStartDay = localDay(
            now.addingTimeInterval(-Double(historyDays - 1) * 24 * 3600))

        let fm = FileManager.default
        let projectDirs = (try? fm.contentsOfDirectory(
            at: ClaudePaths.projectsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var liveKeys = Set<String>()
        var dailyTotals: [String: Int] = [:]
        var dailyCostTotals: [String: Double] = [:]
        var modelTotals: [String: Int] = [:]
        var win5 = ModelTokenSum()
        var win7 = ModelTokenSum()
        var win5Cost = 0.0
        var win7Cost = 0.0

        for dir in projectDirs {
            let files = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let key = file.path
                liveKeys.insert(key)

                let stats: FileStats
                if let cached = cache[key], cached.mtime == mtime {
                    stats = cached
                } else {
                    stats = parse(file: file, mtime: mtime, recentCutoff: recentCutoff,
                                  offsetSeconds: offsetSeconds)
                    cache[key] = stats
                }

                for (day, n) in stats.daily where day >= historyStartDay {
                    dailyTotals[day, default: 0] += n
                }
                for (day, c) in stats.dailyCost where day >= historyStartDay {
                    dailyCostTotals[day, default: 0] += c
                }
                for (model, n) in stats.models { modelTotals[model, default: 0] += n }
                for entry in stats.recent where entry.ts >= sevenDaysAgo {
                    win7.add(entry.tok)
                    win7Cost += entry.cost
                    if entry.ts >= fiveHoursAgo {
                        win5.add(entry.tok)
                        win5Cost += entry.cost
                    }
                }
            }
        }

        cache = cache.filter { liveKeys.contains($0.key) }

        win5.costUSD = win5Cost
        win7.costUSD = win7Cost
        let windows = [
            makeWindow(id: "5h", title: "최근 5시간", sum: win5),
            makeWindow(id: "7d", title: "최근 7일", sum: win7)
        ]
        let daily = buildDailySeries(dailyTotals, now: now)
        let todayKey = localDay(now)

        let lifetime = ConfigStore()?.aggregatedModelUsage() ?? [:]

        return Snapshot(
            windows: windows,
            daily: daily,
            lifetimeByModel: lifetime,
            totalTokensHistory: daily.reduce(0) { $0 + $1.tokens },
            todayTokens: dailyTotals[todayKey] ?? 0,
            todayCost: dailyCostTotals[todayKey] ?? 0,
            historyCost: dailyCostTotals.values.reduce(0, +),
            topModel: modelTotals.max { $0.value < $1.value }?.key,
            officialAvailable: officialUsage() != nil
        )
    }

    // MARK: - Byte-level parsing

    // Search patterns as UTF-8 byte arrays.
    private static let pUsage: [UInt8]   = Array("\"usage\":{".utf8)
    private static let pTs: [UInt8]      = Array("\"timestamp\":\"".utf8)
    private static let pInput: [UInt8]   = Array("\"input_tokens\":".utf8)
    private static let pOutput: [UInt8]  = Array("\"output_tokens\":".utf8)
    private static let pCacheR: [UInt8]  = Array("\"cache_read_input_tokens\":".utf8)
    private static let pCacheC: [UInt8]  = Array("\"cache_creation_input_tokens\":".utf8)
    private static let pModel: [UInt8]   = Array("\"model\":\"".utf8)

    private static func parse(file: URL, mtime: Date, recentCutoff: String,
                              offsetSeconds: Int) -> FileStats {
        var stats = FileStats(mtime: mtime, daily: [:], dailyCost: [:], models: [:], recent: [])
        guard let data = try? Data(contentsOf: file) else { return stats }

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            let b = UnsafeBufferPointer(
                start: base.assumingMemoryBound(to: UInt8.self), count: raw.count)
            let n = b.count
            var lineStart = 0
            var i = 0
            while i <= n {
                if i == n || b[i] == 0x0A {
                    if i > lineStart {
                        parseLine(b, lineStart, i, &stats, recentCutoff, offsetSeconds)
                    }
                    lineStart = i + 1
                }
                i += 1
            }
        }
        return stats
    }

    private static func parseLine(_ b: UnsafeBufferPointer<UInt8>, _ lo: Int, _ hi: Int,
                                  _ stats: inout FileStats, _ recentCutoff: String,
                                  _ offsetSeconds: Int) {
        guard let usagePos = find(b, pUsage, lo, hi) else { return }
        guard let tsPos = find(b, pTs, lo, hi) else { return }

        // Timestamp: 19-char prefix "YYYY-MM-DDTHH:MM:SS" is enough for ordering.
        let tsStart = tsPos + pTs.count
        guard tsStart + 19 <= hi else { return }
        let tsPrefix = ascii(b, tsStart, tsStart + 19)
        // Histogram buckets by *local* day; windows below stay on UTC instants.
        let dayKey = localDayKey(b, tsStart, offsetSeconds)

        let input = readInt(b, find(b, pInput, usagePos, hi), hi)
        let output = readInt(b, find(b, pOutput, usagePos, hi), hi)
        let cacheRead = readInt(b, find(b, pCacheR, usagePos, hi), hi)
        let cacheCreate = readInt(b, find(b, pCacheC, usagePos, hi), hi)
        let total = input + output + cacheRead + cacheCreate
        guard total > 0 else { return }

        stats.daily[dayKey, default: 0] += total

        var model = ""
        if let mPos = find(b, pModel, lo, hi) {
            let mStart = mPos + pModel.count
            if let mEnd = findByte(b, 0x22, mStart, hi) {
                model = ascii(b, mStart, mEnd)
                stats.models[model, default: 0] += total
            }
        }

        let cost = Pricing.cost(model: model, input: input, output: output,
                                cacheRead: cacheRead, cacheWrite: cacheCreate)
        stats.dailyCost[dayKey, default: 0] += cost

        if tsPrefix >= recentCutoff {
            var tok = ModelTokenSum()
            tok.inputTokens = input
            tok.outputTokens = output
            tok.cacheReadTokens = cacheRead
            tok.cacheCreationTokens = cacheCreate
            stats.recent.append((tsPrefix, tok, cost))
        }
    }

    /// Naive byte-pattern search within [from, hi).
    private static func find(_ b: UnsafeBufferPointer<UInt8>, _ pat: [UInt8],
                             _ from: Int, _ hi: Int) -> Int? {
        let m = pat.count
        guard m > 0, hi - from >= m else { return nil }
        let first = pat[0]
        var i = from
        let last = hi - m
        while i <= last {
            if b[i] == first {
                var j = 1
                while j < m, b[i + j] == pat[j] { j += 1 }
                if j == m { return i }
            }
            i += 1
        }
        return nil
    }

    private static func findByte(_ b: UnsafeBufferPointer<UInt8>, _ byte: UInt8,
                                 _ from: Int, _ hi: Int) -> Int? {
        var i = from
        while i < hi { if b[i] == byte { return i }; i += 1 }
        return nil
    }

    /// Reads the first integer at/after `pos` (skipping the key's punctuation).
    private static func readInt(_ b: UnsafeBufferPointer<UInt8>, _ pos: Int?, _ hi: Int) -> Int {
        guard let pos else { return 0 }
        var i = pos
        while i < hi, !(b[i] >= 0x30 && b[i] <= 0x39) { i += 1 }
        var value = 0
        while i < hi, b[i] >= 0x30 && b[i] <= 0x39 {
            value = value * 10 + Int(b[i] - 0x30)
            i += 1
        }
        return value
    }

    private static func ascii(_ b: UnsafeBufferPointer<UInt8>, _ lo: Int, _ hi: Int) -> String {
        String(decoding: UnsafeBufferPointer(start: b.baseAddress! + lo, count: hi - lo),
               as: UTF8.self)
    }

    // MARK: - Date helpers (out of hot loop)

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]   // no fractional -> 19-char body
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// "YYYY-MM-DDTHH:MM:SS" (UTC), matching the 19-char prefix of transcript ts.
    private static func isoPrefix(_ date: Date) -> String {
        String(isoFormatter.string(from: date).prefix(19))
    }

    private static let localDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Local "YYYY-MM-DD" for a Date.
    private static func localDay(_ date: Date) -> String {
        localDayFormatter.string(from: date)
    }

    /// Local "YYYY-MM-DD" for a transcript timestamp, computed from its UTC
    /// fields via integer date math (no Date parsing in the hot loop).
    private static func localDayKey(_ b: UnsafeBufferPointer<UInt8>, _ tsStart: Int,
                                    _ offsetSeconds: Int) -> String {
        let y = digits(b, tsStart, 4)
        let mo = digits(b, tsStart + 5, 2)
        let d = digits(b, tsStart + 8, 2)
        let h = digits(b, tsStart + 11, 2)
        let mi = digits(b, tsStart + 14, 2)
        let s = digits(b, tsStart + 17, 2)

        let utcSecs = daysFromCivil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s
        let local = utcSecs + offsetSeconds
        let localDays = local >= 0 ? local / 86400 : (local - 86399) / 86400
        let (ly, lm, ld) = civilFromDays(localDays)
        return String(format: "%04d-%02d-%02d", ly, lm, ld)
    }

    private static func digits(_ b: UnsafeBufferPointer<UInt8>, _ pos: Int, _ count: Int) -> Int {
        var value = 0
        for k in 0..<count {
            let c = b[pos + k]
            if c >= 0x30 && c <= 0x39 { value = value * 10 + Int(c - 0x30) }
        }
        return value
    }

    // Howard Hinnant's civil <-> days algorithms (days relative to 1970-01-01).
    private static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }

    private static func civilFromDays(_ z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719468
        let era = (z >= 0 ? z : z - 146096) / 146097
        let doe = z - era * 146097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    private static func buildDailySeries(_ totals: [String: Int], now: Date) -> [DailyUsage] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let today = cal.startOfDay(for: now)

        var series: [DailyUsage] = []
        for offset in stride(from: historyDays - 1, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -offset, to: today)
            else { continue }
            series.append(DailyUsage(id: day, tokens: totals[localDay(day)] ?? 0))
        }
        return series
    }

    private static func makeWindow(id: String, title: String, sum: ModelTokenSum) -> UsageWindow {
        UsageWindow(id: id, title: title,
                    inputTokens: sum.inputTokens,
                    outputTokens: sum.outputTokens,
                    cacheReadTokens: sum.cacheReadTokens,
                    cacheCreationTokens: sum.cacheCreationTokens,
                    costUSD: sum.costUSD)
    }

    /// Placeholder for the authenticated Anthropic usage endpoint (v2).
    static func officialUsage() -> Snapshot? { nil }
}

private extension ModelTokenSum {
    mutating func add(_ other: ModelTokenSum) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheCreationTokens += other.cacheCreationTokens
    }
}
