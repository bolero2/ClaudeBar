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

                    if !usage.officialAvailable {
                        Text("로컬 트랜스크립트 기준 추정 · 공식 한도 연동은 준비 중")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.top, 2)
                    }
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

// MARK: - Daily histogram

private struct DailyChartCard: View {
    let usage: UsageService.Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                stat("오늘", Format.tokens(usage.todayTokens))
                Spacer()
                stat("\(UsageService.historyDays)일 토큰", Format.tokens(usage.totalTokensHistory),
                     align: .trailing)
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

    private func stat(_ label: String, _ value: String,
                      align: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: align, spacing: 1) {
            Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .bold))
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
