import SwiftUI

struct DeviceUsageDashboard: View {
    let client: any KapServicing
    let deviceName: String

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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                deviceCard
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
                    retry: { Task { await loadFiveHourTokens() } }
                )
                usageSection(
                    periodTitle: "每周",
                    report: weeklyReport,
                    isLoading: isLoadingWeekly,
                    error: weeklyError,
                    progress: weeklyProgress,
                    usedRatio: usedRatio(for: "limit7d"),
                    retry: { Task { await loadWeeklyTokens() } }
                )
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.footnote)
                        .padding(.top, 1)
                    Text("仅根据本机用量统计，多台机器使用订阅可能产生偏差。")
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("额度看板")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadDashboard() }
        .refreshable { await loadDashboard() }
    }

    private var deviceCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(Palette.kimi)
                .frame(width: 42, height: 42)
                .background(Palette.kimi.opacity(0.12), in: .rect(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(deviceName)
                    .font(.headline)
                    .lineLimit(1)
                Text("当前设备")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
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
                            value: Self.estimatedLimit(for: report, usedRatio: usedRatio).map(Self.tokens) ?? "—"
                        )
                        Spacer(minLength: 8)
                        DashboardNumber(title: "已使用量", value: Self.tokens(report.totals.total), alignment: .trailing)
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
        async let fiveHour: Void = loadFiveHourTokens()
        async let weekly: Void = loadWeeklyTokens()
        await fiveHour
        await weekly
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

    private func loadFiveHourTokens() async {
        let now = Date()
        let resetAt = planUsage?.rows.first(where: { $0.id == "limit5h" })?.resetAt
        let cycleReset = resetAt.flatMap { $0 > now ? $0 : nil }
        let start = cycleReset?.addingTimeInterval(-5 * 3_600) ?? now.addingTimeInterval(-5 * 3_600)
        let range = TokenUsageTimeRange(start: start, end: now)
        isLoadingFiveHour = true
        fiveHourReport = nil
        fiveHourError = nil
        fiveHourProgress = nil
        defer { isLoadingFiveHour = false }
        do {
            fiveHourReport = try await DeviceUsageLoader(client: client).tokenUsage(in: range) { progress in
                await MainActor.run { fiveHourProgress = progress }
            }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { fiveHourError = error.localizedDescription }
        }
    }

    private func loadWeeklyTokens() async {
        let now = Date()
        let resetAt = planUsage?.rows.first(where: { $0.id == "limit7d" })?.resetAt
        let cycleReset = resetAt.flatMap { $0 > now ? $0 : nil }
        let start = cycleReset?.addingTimeInterval(-7 * 86_400) ?? now.addingTimeInterval(-7 * 86_400)
        let range = TokenUsageTimeRange(start: start, end: now)
        isLoadingWeekly = true
        weeklyReport = nil
        weeklyError = nil
        weeklyProgress = nil
        defer { isLoadingWeekly = false }
        do {
            weeklyReport = try await DeviceUsageLoader(client: client).tokenUsage(in: range) { progress in
                await MainActor.run { weeklyProgress = progress }
            }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { weeklyError = error.localizedDescription }
        }
    }

    private static func tokens(_ value: Int) -> String {
        tokens(Double(value))
    }

    private static func tokens(_ value: Double) -> String {
        let magnitude = abs(value)
        let locale = Locale(identifier: "zh_CN")
        if magnitude >= 100_000_000 {
            return (value / 100_000_000).formatted(
                .number.precision(.fractionLength(0 ... 2)).locale(locale)
            ) + "亿"
        }
        if magnitude >= 10_000 {
            return (value / 10_000).formatted(
                .number.precision(.fractionLength(0 ... 2)).locale(locale)
            ) + "万"
        }
        return value.formatted(.number.precision(.fractionLength(0 ... 1)).locale(locale))
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
                    Text("\(ModelUsageStyle.name(for: model.model)) \(share(of: model).formatted(.percent.precision(.fractionLength(0 ... 1))))")
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

    static func name(for model: String) -> String {
        guard model != DeviceUsageLoader.unknownModel else { return "未记录模型" }
        let component = (model as NSString).lastPathComponent
        return component.hasPrefix("k") ? component.uppercased() : component
    }
}
