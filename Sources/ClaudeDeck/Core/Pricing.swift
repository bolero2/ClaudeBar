import Foundation

/// Approximate Claude API pricing ($ per 1M tokens) used to estimate cost from
/// token counts. Subscription (Max) usage is "included", so this is the
/// API-equivalent estimate, matching what `/usage` and ccusage-style tools show.
///
/// Rates as of 2026-07 (cache read = 0.1x input, cache write = 1.25x input):
///   Fable 5 / Mythos 5  $10 / $50
///   Opus 4.5–4.8        $5  / $25   (legacy Opus ≤4.1: $15 / $75)
///   Sonnet              $3  / $15
///   Haiku 4.5           $1  / $5    (legacy Haiku 3.x: $0.80 / $4)
enum Pricing {
    struct Rate {
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheWrite: Double
    }

    static func rate(for model: String) -> Rate {
        let m = model.lowercased()
        if m.contains("fable") || m.contains("mythos") {
            return Rate(input: 10, output: 50, cacheRead: 1.0, cacheWrite: 12.5)
        }
        if m.contains("opus") {
            // Opus 4.1 and older kept the original $15/$75 pricing.
            if m.contains("opus-4-1") || m.contains("opus-4-0")
                || m.contains("opus-4-2025") || m.contains("3-opus") {
                return Rate(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75)
            }
            return Rate(input: 5, output: 25, cacheRead: 0.5, cacheWrite: 6.25)
        }
        if m.contains("haiku") {
            if m.contains("3-5-haiku") || m.contains("3-haiku") {
                return Rate(input: 0.80, output: 4, cacheRead: 0.08, cacheWrite: 1.0)
            }
            return Rate(input: 1, output: 5, cacheRead: 0.1, cacheWrite: 1.25)
        }
        // sonnet / default
        return Rate(input: 3, output: 15, cacheRead: 0.30, cacheWrite: 3.75)
    }

    static func cost(model: String, input: Int, output: Int,
                     cacheRead: Int, cacheWrite: Int) -> Double {
        let r = rate(for: model)
        return (Double(input) * r.input
                + Double(output) * r.output
                + Double(cacheRead) * r.cacheRead
                + Double(cacheWrite) * r.cacheWrite) / 1_000_000
    }
}
