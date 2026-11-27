import SwiftUI

/// 会话右上角的上下文环（文件按钮左边）：实时显示此对话上下文占比，
/// 点开从底部拉起「用量」面板。
struct SessionInfoButton: View {
    let chat: ChatModel

    @Environment(AppModel.self) private var app
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
            Task { await app.refreshUsage() }
        } label: {
            // 不用 Label：工具栏遇到非图片的图标会改显示标题文字。
            ContextRingGauge(ratio: contextRatio(of: chat), lineWidth: 3)
                .frame(width: 22, height: 22)
        }
        .accessibilityLabel("上下文已使用 \(contextRatio(of: chat).formatted(.percent.precision(.fractionLength(0))))")
        .sheet(isPresented: $isPresented) {
            UsageSheet(chat: chat, usage: app.usage)
        }
    }
}

/// 草稿还没有上下文，按 0 算。
@MainActor private func contextRatio(of chat: ChatModel) -> Double {
    chat.isDraft ? 0 : min(max(chat.contextUsage ?? 0, 0), 1)
}

/// 「用量」上拉栏：每项统计一张卡片，卡片上方是灰色小标题。
///
///   此对话上下文
///   ┌──────────────────────────────┐
///   │ 上下文              已使用 3%  │
///   │ ━━━─────────────────────────  │
///   │ 25.8K / 1M tokens             │
///   └──────────────────────────────┘
///   每周使用限额
///   ┌──────────────────────────────┐
///   │ 所有模型           已使用 13%  │
///   │ ━━━━━──────────────────────  │
///   │ 21小时59分钟后重置              │
///   └──────────────────────────────┘
private struct UsageSheet: View {
    let chat: ChatModel
    let usage: PlanUsage?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    contextSection
                    planSections
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("用量")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton()
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color(.systemGroupedBackground))
    }

    private var contextSection: some View {
        let ratio = contextRatio(of: chat)
        return UsageSection(title: "此对话上下文") {
            UsageCard(
                title: "上下文",
                value: "已使用 \(ratio.formatted(.percent.precision(.fractionLength(0 ... 1))))",
                ratio: ratio,
                tint: ContextRingGauge.tint(for: ratio),
                caption: chat.isDraft ? nil : tokenCaption
            )
        }
    }

    private var tokenCaption: String? {
        guard let used = chat.contextTokens, let max = chat.maxContextTokens, max > 0 else { return nil }
        return "\(Self.tokens(used)) / \(Self.tokens(max)) tokens"
    }

    @ViewBuilder
    private var planSections: some View {
        if let rows = usage?.rows, !rows.isEmpty {
            ForEach(rows) { row in
                let used = 1 - row.remainingRatio
                UsageSection(title: "\(row.title)使用限额") {
                    UsageCard(
                        title: "所有模型",
                        value: "已使用 \(used.formatted(.percent.precision(.fractionLength(0))))",
                        ratio: used,
                        tint: Self.usedTint(used),
                        caption: row.resetAt.flatMap(Self.resetCaption)
                    )
                }
            }
        } else if usage == nil {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        } else {
            UsageSection(title: "套餐用量") {
                Text("暂无用量数据")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
            }
        }
    }

    /// 用得越多越醒目。
    private static func usedTint(_ ratio: Double) -> Color {
        switch ratio {
        case 0.9...: .red
        case 0.7...: .orange
        default: Palette.kimi
        }
    }

    /// 「21小时59分钟后重置」「6天3小时后重置」「12分钟后重置」。
    private static func resetCaption(_ date: Date) -> String? {
        let minutes = Int(date.timeIntervalSinceNow / 60)
        guard minutes >= 0 else { return nil }
        let days = minutes / 1440, hours = minutes % 1440 / 60, mins = minutes % 60
        let text: String
        if days > 0 {
            text = hours > 0 ? "\(days)天\(hours)小时" : "\(days)天"
        } else if hours > 0 {
            text = "\(hours)小时\(mins)分钟"
        } else {
            text = "\(max(mins, 1))分钟"
        }
        return "\(text)后重置"
    }

    /// 97.2K / 262K 这种写法，不用中文的「万」。
    private static func tokens(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.significantDigits(1 ... 3)).locale(Locale(identifier: "en_US")))
    }
}

/// 卡片上方的灰色小标题 + 卡片。
private struct UsageSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            content
        }
    }
}

private struct UsageCard: View {
    let title: String
    let value: String
    let ratio: Double
    let tint: Color
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Spacer(minLength: 16)
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            UsageBar(ratio: ratio, tint: tint)
            if let caption {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
        .accessibilityElement(children: .combine)
    }
}

/// 横条：浅色同色系轨道，上面按占比填深色。
private struct UsageBar: View {
    let ratio: Double
    let tint: Color

    var body: some View {
        Capsule()
            .fill(tint.opacity(0.18))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    // 0 时不画：圆头会留下一个点。
                    if ratio > 0 {
                        Capsule()
                            .fill(tint)
                            .frame(width: max(proxy.size.height, proxy.size.width * min(ratio, 1)))
                    }
                }
            }
            .frame(height: 10)
            .animation(.snappy, value: ratio)
    }
}

/// 同心圆占比：底圈是整圈轨道，上面一圈按占比描出来。
struct ContextRingGauge: View {
    let ratio: Double
    var lineWidth: CGFloat = 6

    static func tint(for ratio: Double) -> Color {
        switch ratio {
        case ..<0.7: Palette.kimi
        case ..<0.9: .orange
        default: .red
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)
            // 0% 时不画：圆头线帽会留下一个点。
            if ratio > 0 {
                Circle()
                    .trim(from: 0, to: ratio)
                    .stroke(Self.tint(for: ratio), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(lineWidth / 2)
        .animation(.snappy, value: ratio)
    }
}
