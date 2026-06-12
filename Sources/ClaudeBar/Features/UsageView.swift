import SwiftUI
import Charts

struct UsageView: View {
    @EnvironmentObject var state: AppState
    var scroll = true

    var body: some View {
        if scroll {
            ScrollView { content }
        } else {
            content
        }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: 10) {
                if let rate = state.rateLimit, !rate.windows.isEmpty {
                    RateLimitCard(rate: rate)
                }

                if let usage = state.usage {
                    ForEach(usage.windows) { window in
                        UsageCard(window: window)
                    }

                    DailyChartCard(usage: usage)

                    if !usage.lifetimeByModel.isEmpty {
                        SectionHeader(title: "모델별 누적", count: nil)
                        ForEach(usage.lifetimeByModel.sorted { $0.value.outputTokens > $1.value.outputTokens }, id: \.key) { model, sum in
                            ModelUsageRow(model: model, sum: sum)
                        }
                    }

                    Text(state.rateLimit == nil
                         ? "공식 사용 한도를 가져오지 못했습니다 · 아래는 로컬 집계"
                         : "위는 공식 한도 · 아래 토큰/비용은 로컬 트랜스크립트 기반(비용은 API 단가 환산 추정)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.top, 2)
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("사용량을 집계하는 중…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            }
            .padding(8)
    }
}

// MARK: - Official rate-limit

private struct RateLimitCard: View {
    let rate: RateLimitUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 11))
                    .foregroundStyle(.tint)
                Text("사용 한도")
                    .font(.system(size: 12, weight: .semibold))
            }
            ForEach(rate.windows) { window in
                RateRow(window: window)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
    }
}

private struct RateRow: View {
    let window: RateWindow

    private var fraction: Double { min(1, max(0, window.utilization / 100)) }
    private var color: Color {
        switch fraction {
        case ..<0.6: return .green
        case ..<0.85: return .orange
        default: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.title)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text("\(Int(window.utilization))% 사용")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(color)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(color).frame(width: max(3, geo.size.width * fraction))
                }
            }
            .frame(height: 5)
            HStack {
                Text("\(Int(window.remaining))% 남음")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Spacer()
                Label(Format.resetIn(window.resetsAt), systemImage: "arrow.clockwise")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }
        }
    }
}

// MARK: - Daily histogram

private struct DailyChartCard: View {
    let usage: UsageService.Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                stat("오늘", Format.cost(usage.todayCost),
                     "\(Format.tokens(usage.todayTokens)) 토큰")
                Spacer()
                stat("\(UsageService.historyDays)일", Format.cost(usage.historyCost),
                     "\(Format.tokens(usage.totalTokensHistory)) 토큰", align: .trailing)
            }

            Chart(usage.daily) { day in
                BarMark(
                    x: .value("날짜", day.date, unit: .day),
                    y: .value("토큰", day.tokens),
                    width: .ratio(0.7)
                )
                .foregroundStyle(Color.claudeCoral)
                .cornerRadius(1.5)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 80)

            if let top = usage.topModel {
                Text("Top 모델: \(Format.model(top))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
    }

    private func stat(_ label: String, _ value: String, _ sub: String,
                      align: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: align, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .bold))
            Text(sub).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Rolling window cards

private struct UsageCard: View {
    let window: UsageWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(window.title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if window.costUSD > 0 {
                    Text(Format.cost(window.costUSD))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(Format.tokens(window.totalTokens))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.claudeCoral)
            }
            HStack(spacing: 12) {
                stat("입력", window.inputTokens)
                stat("출력", window.outputTokens)
                stat("캐시읽기", window.cacheReadTokens)
                stat("캐시생성", window.cacheCreationTokens)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(8)
    }

    private func stat(_ label: String, _ n: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(Format.tokens(n)).font(.system(size: 11, weight: .medium))
        }
    }
}

private struct ModelUsageRow: View {
    let model: String
    let sum: ModelTokenSum
    var body: some View {
        HStack {
            Text(Format.model(model))
                .font(.system(size: 11, weight: .medium))
            Spacer()
            Text("출력 \(Format.tokens(sum.outputTokens))")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(Format.cost(sum.costUSD))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.claudeCoral)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}
