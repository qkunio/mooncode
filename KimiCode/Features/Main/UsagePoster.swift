import SwiftUI

struct SharedPoster: Identifiable {
    let id = UUID()
    let url: URL
}

enum UsagePosterRenderer {
    @MainActor
    static func render(_ view: UsagePosterView) throws -> SharedPoster {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.uiImage, let data = image.pngData() else {
            throw KapError.api(code: -1, message: "海报图片生成失败。")
        }
        let url = FileManager.default.temporaryDirectory.appending(path: "MoonCodeUsagePoster-\(UUID().uuidString).png")
        try data.write(to: url)
        return SharedPoster(url: url)
    }
}

struct UsageShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            try? FileManager.default.removeItem(at: url)
        }
        return controller
    }

    func updateUIViewController(_: UIActivityViewController, context: Context) {}
}

struct UsagePosterView: View {
    let subscriptionName: String
    let fiveHourReport: DeviceTokenUsageReport
    let weeklyReport: DeviceTokenUsageReport
    let fiveHourLimit: Int?
    let weeklyLimit: Int?
    let weeklyUsedRatio: Double?
    let weeklyRange: TokenUsageTimeRange

    private let ink = Color(red: 0.02, green: 0.02, blue: 0.02)
    private let blue = Color(red: 0.063, green: 0.208, blue: 1)
    private let paper = Color(red: 0.973, green: 0.953, blue: 0.914)

    var body: some View {
        ZStack {
            paper
            Image("UsagePaper")
                .resizable(resizingMode: .tile)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Image("UsageAppIcon")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 58, height: 58)
                        .clipShape(.rect(cornerRadius: 14))
                    Text("MoonCode")
                        .font(.system(size: 46, weight: .bold, design: .serif))
                    Spacer()
                }
                .frame(height: 70)

                Rectangle().fill(ink).frame(height: 3)

                Text("我的 Kimi Code 用量")
                    .font(.system(size: 72, weight: .black, design: .serif))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .padding(.top, 42)

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(subscriptionName)
                        .font(.system(size: 50, weight: .bold, design: .serif))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    Text("本周用量")
                        .font(.system(size: 34, weight: .semibold, design: .serif))
                        .fixedSize()
                }
                .padding(.top, 34)

                ZStack(alignment: .topLeading) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(weeklyParts.number)
                            .font(.system(size: 180, weight: .bold, design: .serif))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        if !weeklyParts.unit.isEmpty {
                            Text(weeklyParts.unit)
                                .font(.system(size: 116, weight: .black, design: .serif))
                        }
                    }
                    .frame(maxWidth: 810, alignment: .leading)
                    .padding(.top, 16)
                    Image("UsageMoon")
                        .frame(width: 75, height: 76)
                        .offset(x: 870, y: 8)
                }
                .frame(height: 260)

                Text("\(Self.date(weeklyRange.start)) — \(Self.date(weeklyRange.end))")
                    .font(.system(size: 31, weight: .medium, design: .serif))

                HStack(spacing: 24) {
                    Text("本周额度已用")
                        .font(.system(size: 29, weight: .semibold, design: .serif))
                        .fixedSize()
                    GeometryReader { proxy in
                        let ratio = min(max(weeklyUsedRatio ?? 0, 0), 1)
                        Rectangle()
                            .fill(Color(.tertiarySystemFill))
                            .overlay(alignment: .leading) {
                                Rectangle().fill(blue).frame(width: proxy.size.width * ratio)
                            }
                    }
                    .frame(height: 32)
                    Text((weeklyUsedRatio ?? 0).formatted(.percent.precision(.fractionLength(0))))
                        .font(.system(size: 34, weight: .bold, design: .serif))
                }
                .padding(.top, 36)

                Rectangle().fill(ink).frame(height: 2).padding(.top, 42)

                HStack(spacing: 0) {
                    PosterStat(title: "5 小时满额额度", value: fiveHourLimit.map(TokenUsageFormat.string) ?? "—")
                    Rectangle().fill(ink).frame(width: 2, height: 150).padding(.horizontal, 34)
                    PosterStat(title: "周满额额度", value: weeklyLimit.map(TokenUsageFormat.string) ?? "—")
                }
                .frame(height: 205)

                Rectangle().fill(ink).frame(height: 2)

                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("常用模型")
                            .font(.system(size: 28, weight: .semibold, design: .serif))
                        Text(TokenUsageFormat.modelName(preferredModel))
                            .font(.system(size: 52, weight: .bold, design: .serif))
                            .foregroundStyle(blue)
                            .lineLimit(2)
                            .minimumScaleFactor(0.45)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle().fill(ink).frame(width: 2, height: 130).padding(.horizontal, 30)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("本周用量")
                            .font(.system(size: 28, weight: .semibold, design: .serif))
                        Text(TokenUsageFormat.string(weeklyReport.totals.total))
                            .font(.system(size: 66, weight: .bold, design: .serif))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                        Text("Tokens")
                            .font(.system(size: 28, design: .serif))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 205)

                Spacer(minLength: 18)
                Rectangle().fill(ink).frame(height: 4)
                HStack(spacing: 16) {
                    Text("AppStore搜索「MoonCode」")
                        .font(.system(size: 29, weight: .semibold, design: .serif))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 8)
                    Text("在手机上，接管 Kimi Code。")
                        .font(.system(size: 27, weight: .medium, design: .serif))
                        .lineLimit(1)
                }
                .padding(.top, 12)
                Text("仅统计当前设备 · 额度为估算值")
                    .font(.system(size: 22, design: .serif))
                    .padding(.top, 8)
            }
            .padding(50)
            .foregroundStyle(ink)
        }
        .frame(width: 1086, height: 1448)
        .clipped()
    }

    private var weeklyParts: TokenUsageFormat.Parts {
        TokenUsageFormat.parts(weeklyReport.totals.total)
    }

    private var preferredModel: String {
        weeklyReport.models.first(where: { $0.model != DeviceUsageLoader.unknownModel })?.model
            ?? weeklyReport.models.first?.model
            ?? DeviceUsageLoader.unknownModel
    }

    private static func date(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d.%02d.%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

private struct PosterStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 29, weight: .semibold, design: .serif))
            Text(value)
                .font(.system(size: 82, weight: .bold, design: .serif))
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text("Tokens")
                .font(.system(size: 30, design: .serif))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
