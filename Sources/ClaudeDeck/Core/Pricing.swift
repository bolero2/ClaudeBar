import Foundation

/// Approximate Claude API pricing ($ per 1M tokens) used to estimate cost from
/// token counts. Subscription (Max) usage is "included", so this is the
/// API-equivalent estimate, matching what `/usage` and ccusage-style tools show.
enum Pricing {
    struct Rate {
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheWrite: Double
    }

    static func rate(for model: String) -> Rate {
        let m = model.lowercased()
        if m.contains("opus") {
            return Rate(input: 15, output: 75, cacheRead: 1.5, cacheWrite: 18.75)
        }
        if m.contains("haiku") {
            return Rate(input: 0.80, output: 4, cacheRead: 0.08, cacheWrite: 1.0)
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
