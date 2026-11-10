import SwiftUI

struct UsageEstimateView: View {
    let client: any KapServicing
    let deviceID: String
    let subscriptionName: String

    @Environment(\.dismiss) private var dismiss
    @State private var planUsage: PlanUsage?
    @State private var planError: String?
    @State private var fiveHourReport: DeviceTokenUsageReport?
    @State private var isLoadingFiveHour = false
    @State private var fiveHourError: String?
    @State private var fiveHourProgress: DeviceUsageProgress?
    @State private var weeklyReport: DeviceTokenUsageReport?
    @State private var isLoadingWeekly = false
    @State private var weeklyError: String?
    @State private var weeklyProgress: DeviceUsageProgress?
    @State private var fiveHourRange: TokenUsageTimeRange?
    @State private var weeklyRange: TokenUsageTimeRange?
    @State private var sharedPoster: SharedPoster?
    @State private var shareError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let planError {
                    Text(planError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                usageSection(
                    periodTitle: "5 小时",
                    report: fiveHourReport,
                    isLoading: isLoadingFiveHour,
                    error: fiveHourError,
                    progress: fiveHourProgress,
                    usedRatio: usedRatio(for: "limit5h"),
                    retry: { Task { await loadTokenReports() } }
                )
                usageSection(
                    periodTitle: "每周",
                    report: weeklyReport,
                    isLoading: isLoadingWeekly,
                    error: weeklyError,
                    progress: weeklyProgress,
                    usedRatio: usedRatio(for: "limit7d"),
                    retry: { Task { await loadTokenReports() } }
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("订阅 Token 估算")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("用量")
                    }
                }
                .accessibilityLabel("返回用量")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { sharePoster() } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(fiveHourReport == nil || weeklyReport == nil || isLoadingFiveHour || isLoadingWeekly)
                .accessibilityLabel("分享用量海报")
            }
        }
        .task { await loadDashboard() }
        .refreshable { await loadDashboard() }
        .sheet(item: $sharedPoster) { poster in
            UsageShareSheet(url: poster.url)
        }
        .alert("分享失败", isPresented: Binding(get: { shareError != nil }, set: { if !$0 { shareError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(shareError ?? "")
        }
        .presentationDetents([.large])
    }

    @ViewBuilder
    private func usageSection(
        periodTitle: String,
        report: DeviceTokenUsageReport?,
        isLoading: Bool,
        error: String?,
        progress: DeviceUsageProgress?,
        usedRatio: Double?,
        retry: @escaping () -> Void
    ) -> some View {
        UsageSection(title: periodTitle) {
            VStack(alignment: .leading, spacing: 18) {
                if isLoading {
                    VStack(spacing: 12) {
                        ProgressView(value: progress?.fraction ?? 0)
                            .progressViewStyle(.linear)
                            .tint(Palette.kimi)
                            .animation(.snappy, value: progress?.fraction)
                        Text(progress.map { "已统计 \($0.completedSessions) / \($0.totalSessions) 个会话" } ?? "正在读取会话列表…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
                } else if let error {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                        Button("重试", action: retry)
                    }
                    .padding(.vertical, 8)
                } else if let report {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        DashboardNumber(
                            title: "预估\(periodTitle) Token 总量",
                            value: Self.estimatedLimit(for: report, usedRatio: usedRatio).map(TokenUsageFormat.string) ?? "—"
                        )
                        Spacer(minLength: 8)
                        DashboardNumber(
                            title: "已使用量",
                            value: TokenUsageFormat.string(report.totals.total),
                            alignment: .trailing
                        )
                    }

                    ModelUsageBar(report: report, usedRatio: usedRatio)
                    ModelUsageLegend(report: report)

                    HStack {
                        Text("平均缓存命中")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(report.totals.cacheHitRatio.map { $0.formatted(.percent.precision(.fractionLength(0 ... 1))) } ?? "—")
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
        }
    }

    private func usedRatio(for key: String) -> Double? {
        guard let row = planUsage?.rows.first(where: { $0.id == key }) else { return nil }
        return 1 - row.remainingRatio
    }

    private static func estimatedLimit(for report: DeviceTokenUsageReport, usedRatio: Double?) -> Int? {
        guard let usedRatio, usedRatio > 0, report.totals.total > 0 else { return nil }
        return Int((Double(report.totals.total) / usedRatio).rounded())
    }

    private func loadDashboard() async {
        await loadPlan()
        await loadTokenReports()
    }

    private func loadPlan() async {
        planError = nil
        do {
            planUsage = try await client.usage()
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { planError = error.localizedDescription }
        }
    }

    private func loadTokenReports() async {
        let now = Date()
        let fiveHourResetAt = planUsage?.rows.first(where: { $0.id == "limit5h" })?.resetAt
        let fiveHourCycleReset = fiveHourResetAt.flatMap { $0 > now ? $0 : nil }
        let fiveHourStart = fiveHourCycleReset?.addingTimeInterval(-5 * 3_600) ?? now.addingTimeInterval(-5 * 3_600)
        let fiveRange = TokenUsageTimeRange(start: fiveHourStart, end: now)
        let weeklyResetAt = planUsage?.rows.first(where: { $0.id == "limit7d" })?.resetAt
        let weeklyCycleReset = weeklyResetAt.flatMap { $0 > now ? $0 : nil }
        let weeklyStart = weeklyCycleReset?.addingTimeInterval(-7 * 86_400) ?? now.addingTimeInterval(-7 * 86_400)
        let weekRange = TokenUsageTimeRange(start: weeklyStart, end: now)
        fiveHourRange = fiveRange
        weeklyRange = weekRange

        isLoadingFiveHour = true
        isLoadingWeekly = true
        fiveHourReport = nil
        weeklyReport = nil
        fiveHourError = nil
        weeklyError = nil
        fiveHourProgress = nil
        weeklyProgress = nil
        defer {
            isLoadingFiveHour = false
            isLoadingWeekly = false
        }
        do {
            let reports = try await DeviceUsageLoader(client: client, cacheKey: deviceID).tokenUsage(
                in: [fiveRange, weekRange]
            ) { progress in
                await MainActor.run {
                    fiveHourProgress = progress
                    weeklyProgress = progress
                }
            }
            fiveHourReport = reports[0]
            weeklyReport = reports[1]
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled {
                fiveHourError = error.localizedDescription
                weeklyError = error.localizedDescription
            }
        }
    }

    private func sharePoster() {
        guard let fiveHourReport, let weeklyReport, let weeklyRange else { return }
        let poster = UsagePosterView(
            subscriptionName: subscriptionName,
            fiveHourReport: fiveHourReport,
            weeklyReport: weeklyReport,
            fiveHourLimit: Self.estimatedLimit(for: fiveHourReport, usedRatio: usedRatio(for: "limit5h")),
            weeklyLimit: Self.estimatedLimit(for: weeklyReport, usedRatio: usedRatio(for: "limit7d")),
            weeklyUsedRatio: usedRatio(for: "limit7d"),
            weeklyRange: weeklyRange
        )
        do {
            sharedPoster = try UsagePosterRenderer.render(poster)
        } catch {
            shareError = error.localizedDescription
        }
    }
}

private struct DashboardNumber: View {
    let title: String
    let value: String
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .monospacedDigit()
        }
    }
}

private struct ModelUsageBar: View {
    let report: DeviceTokenUsageReport
    let usedRatio: Double?

    var body: some View {
        GeometryReader { proxy in
            let total = report.totals.total
            let fillRatio = min(max(usedRatio ?? (total > 0 ? 1 : 0), 0), 1)
            Capsule()
                .fill(Color(.tertiarySystemFill))
                .overlay(alignment: .leading) {
                    HStack(spacing: 0) {
                        ForEach(Array(report.models.enumerated()), id: \.element.id) { index, model in
                            if total > 0 {
                                Rectangle()
                                    .fill(ModelUsageStyle.color(for: model.model, at: index))
                                    .frame(width: proxy.size.width * fillRatio * Double(model.totals.total) / Double(total))
                            }
                        }
                    }
                    .frame(width: proxy.size.width * fillRatio, alignment: .leading)
                    .clipShape(Capsule())
                }
        }
        .frame(height: 18)
        .accessibilityLabel("已使用 \(min(max(usedRatio ?? 0, 0), 1).formatted(.percent.precision(.fractionLength(0))))")
    }
}

private struct ModelUsageLegend: View {
    let report: DeviceTokenUsageReport

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
            ForEach(Array(report.models.enumerated()), id: \.element.id) { index, model in
                HStack(spacing: 6) {
                    Circle()
                        .fill(ModelUsageStyle.color(for: model.model, at: index))
                        .frame(width: 7, height: 7)
                    Text("\(TokenUsageFormat.modelName(model.model)) \(share(of: model).formatted(.percent.precision(.fractionLength(0 ... 1))))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private func share(of model: ModelTokenUsage) -> Double {
        guard report.totals.total > 0 else { return 0 }
        return Double(model.totals.total) / Double(report.totals.total)
    }
}

private enum ModelUsageStyle {
    private static let colors: [Color] = [Palette.kimi, .purple, .teal, .orange, .pink, .indigo, .mint, .brown]

    static func color(for model: String, at index: Int) -> Color {
        if model == DeviceUsageLoader.unknownModel { return .gray }
        return colors[index % colors.count]
    }
}

enum TokenUsageFormat {
    struct Parts {
        let number: String
        let unit: String
    }

    static func string(_ value: Int) -> String {
        string(Double(value))
    }

    static func string(_ value: Double) -> String {
        let parts = parts(value)
        return parts.number + parts.unit
    }

    static func parts(_ value: Int) -> Parts {
        parts(Double(value))
    }

    static func parts(_ value: Double) -> Parts {
        let magnitude = abs(value)
        let locale = Locale(identifier: "zh_CN")
        if magnitude >= 100_000_000 {
            return Parts(
                number: (value / 100_000_000).formatted(
                    .number.precision(.fractionLength(0 ... 2)).grouping(.never).locale(locale)
                ),
                unit: "亿"
            )
        }
        if magnitude >= 10_000 {
            return Parts(
                number: (value / 10_000).formatted(
                    .number.precision(.fractionLength(0 ... 2)).grouping(.never).locale(locale)
                ),
                unit: "万"
            )
        }
        return Parts(
            number: value.formatted(.number.precision(.fractionLength(0 ... 1)).grouping(.never).locale(locale)),
            unit: ""
        )
    }

    static func modelName(_ model: String) -> String {
        guard model != DeviceUsageLoader.unknownModel else { return "未记录模型" }
        let component = (model as NSString).lastPathComponent
        return component.hasPrefix("k") ? component.uppercased() : component
    }
}
