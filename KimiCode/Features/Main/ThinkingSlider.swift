import SwiftUI

/// 点 composer 上的「模型名 High」弹出的面板。首页两张同样式的卡片：「当前模型」「思考强度」，
/// 点了推入子页（模型列表 / 大号思考强度滑杆），左上角返回。改动立刻写入会话。
/// 面板高度跟着当前页走（各页量出自己的高度报给外面设 detent）。
struct ModelPanel: View {
    let models: [ModelInfo]
    let config: ComposerConfig
    let client: (any KapServicing)?
    let applyModel: (ModelInfo, String?) -> Void
    let applyEffort: (ModelInfo, String) -> Void
    var onProvidersChanged: () async -> Void = {}
    var onHeight: ((CGFloat) -> Void)?

    private enum Page { case home, models, thinking }

    @Environment(\.dismiss) private var dismiss
    @State private var page = Page.home
    /// 往里推还是往回退，决定子页从哪边滑进来。
    @State private var goingBack = false
    /// 刚拖完、会话配置还没回写时先用本地选中值，免得滑块闪回去。换模型时清掉。
    @State private var pendingEffort: String?

    private var model: ModelInfo? { models.first { $0.model == config.modelID } }

    private var effort: String? {
        guard let model else { return nil }
        return pendingEffort ?? model.normalizedThinking(config.effort)
    }

    /// 「关闭」永远在最左（只有开 / 关的模型服务端给的是 on、off）。
    private var thinkingOptions: [String] {
        guard let model else { return [] }
        return model.thinkingOptions.filter { $0 == "off" } + model.thinkingOptions.filter { $0 != "off" }
    }

    var body: some View {
        ZStack(alignment: .top) {
            switch page {
            case .home:
                home
                    .reportHeight(when: page == .home, to: onHeight)
                    .transition(.push(from: goingBack ? .leading : .trailing))
            case .models:
                ModelSelectionPanel(
                    models: models, config: config, apply: applyModel,
                    onHeight: { height in if page == .models { onHeight?(height) } },
                    client: client, onProvidersChanged: onProvidersChanged,
                    onBack: { go(.home) }
                )
                .transition(.push(from: goingBack ? .leading : .trailing))
            case .thinking:
                thinkingPage
                    .reportHeight(when: page == .thinking, to: onHeight)
                    .transition(.push(from: goingBack ? .leading : .trailing))
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .background(Color(.systemGroupedBackground))
        .onChange(of: config.modelID) { pendingEffort = nil }
    }

    /// 先定方向、下一帧再切页：离开的那页要先拿到新的滑出方向（前进往左推，返回往右退）。
    private func go(_ next: Page) {
        goingBack = next == .home
        DispatchQueue.main.async {
            withAnimation(.snappy(duration: 0.32)) { page = next }
        }
    }

    // MARK: 首页

    private var home: some View {
        VStack(alignment: .leading, spacing: 24) {
            header(title: "模型", back: false)

            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("当前模型")
                card(
                    title: model?.name ?? config.modelID.map { ($0 as NSString).lastPathComponent } ?? "选择模型",
                    subtitle: model?.providerLabel
                ) { go(.models) }
            }
            .padding(.horizontal, 24)

            if let model, model.thinkingOptions.count > 1, let effort {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle(model.efforts.isEmpty ? "思考" : "思考强度")
                    card(
                        title: effort.thinkingOptionLabel,
                        subtitle: thinkingOptions.map(\.thinkingOptionLabel).joined(separator: " · ")
                    ) { go(.thinking) }
                }
                .padding(.horizontal, 24)
            }
        }
        .padding(.bottom, 28)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 思考强度子页

    private var thinkingPage: some View {
        VStack(spacing: 20) {
            header(title: model?.efforts.isEmpty == true ? "思考" : "思考强度", back: true)
            if let model, let effort {
                ThinkingSlider(
                    title: model.name,
                    options: thinkingOptions,
                    selection: effort,
                    hasMaxLevel: !model.efforts.isEmpty
                ) { option in
                    pendingEffort = option
                    applyEffort(model, option)
                }
                .padding(20)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
                .padding(.horizontal, 24)
            }
        }
        .padding(.bottom, 28)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 零件

    /// 顶栏：左边 ✕（首页）或返回（子页），中间标题。
    private func header(title: String, back: Bool) -> some View {
        ZStack {
            Text(title)
                .font(.headline)
            HStack {
                Button(action: { if back { go(.home) } else { dismiss() } }) {
                    MoonIcon(back ? "mc-chevron-left" : "mc-close", size: 18)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel(back ? "返回" : "关闭")
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
    }

    /// 同用量面板卡片上方的灰色小标题。
    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    /// 首页两张卡片共用：标题 + 灰色副标题 + ›，点了推入子页。
    private func card(title: String, subtitle: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                MoonIcon("mc-chevron-right", size: 13)
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
            .contentShape(.rect(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }
}

private extension View {
    /// 只有当前页把高度报出去：切页动画里旧页还在，别让它把高度改回去。
    func reportHeight(when active: Bool, to report: ((CGFloat) -> Void)?) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if active { report?(height) }
        }
    }
}

/// 分档滑杆。拖动吸附到档位、每过一档轻震，松手（或点轨道）才写入。
/// 拉到最高一档：轨道变紫、白色小气泡不断向左飘；刚到顶时档位名弹一下、滑块迸出一圈星星、重震（彩蛋）。
struct ThinkingSlider: View {
    /// 档位名下面的小字（可选）。
    var title: String? = nil
    /// 从左到右、低 → 高（「关闭」在最左）。
    let options: [String]
    let selection: String
    /// 最高档是不是「真·最高强度」（只有带强度的模型才有彩蛋，单纯开 / 关没有）。
    let hasMaxLevel: Bool
    let commit: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 拖动中手指所在的位置（轨道坐标）。用 GestureState：手势被上拉栏等抢走、取消时也会自动复位，
    /// 不会把滑块卡在两档中间。
    @GestureState(resetTransaction: Transaction(animation: .spring(duration: 0.3, bounce: 0.25)))
    private var dragX: CGFloat?
    @State private var trackWidth: CGFloat = 0
    /// 每到顶一次加一：重震 + 迸星星 + 档位名弹跳。
    @State private var reachedMax = 0

    private let trackHeight: CGFloat = 40
    private let thumbSize: CGFloat = 46

    private var selectedIndex: Int { options.firstIndex(of: selection) ?? 0 }
    /// 正在显示的档位：拖动中跟着手指，平时就是选中的。
    private var shownIndex: Int {
        guard let dragX, trackWidth > 0 else { return selectedIndex }
        return nearestIndex(to: dragX, width: trackWidth)
    }
    private var isMax: Bool { hasMaxLevel && shownIndex == options.count - 1 && options.count > 1 }

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 2) {
                Text(options.indices.contains(shownIndex) ? options[shownIndex].thinkingOptionLabel : "")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isMax ? AnyShapeStyle(Self.maxGradient) : AnyShapeStyle(Palette.kimi))
                    .contentTransition(.numericText())
                    .keyframeAnimator(initialValue: 1.0, trigger: reachedMax) { content, scale in
                        content.scaleEffect(scale)
                    } keyframes: { _ in
                        SpringKeyframe(1.25, duration: 0.18)
                        SpringKeyframe(1.0, duration: 0.4, spring: .bouncy)
                    }
                if let title {
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .animation(.snappy, value: shownIndex)

            track
        }
        .sensoryFeedback(.selection, trigger: shownIndex)
        .sensoryFeedback(.impact(weight: .heavy, intensity: 1), trigger: reachedMax)
        .accessibilityElement()
        .accessibilityLabel(hasMaxLevel ? "思考强度" : "思考")
        .accessibilityValue(options.indices.contains(selectedIndex) ? options[selectedIndex].thinkingOptionLabel : "")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: select(min(selectedIndex + 1, options.count - 1))
            case .decrement: select(max(selectedIndex - 1, 0))
            @unknown default: break
            }
        }
    }

    // MARK: 轨道

    private var track: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let thumbX = dragX.map { clamp($0, width: width) } ?? stepX(selectedIndex, width: width)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.systemGray5))

                // 填充：从最左到滑块中心再多半个滑块，滑块压在填充的末端。
                Capsule()
                    .fill(isMax ? AnyShapeStyle(Self.maxGradient) : AnyShapeStyle(Palette.kimi))
                    .overlay {
                        if isMax, !reduceMotion { BubbleField().clipShape(.capsule) }
                    }
                    .frame(width: max(trackHeight, thumbX + thumbSize / 2 - (thumbSize - trackHeight) / 2))

                // 档位点。
                ForEach(options.indices, id: \.self) { index in
                    Circle()
                        .fill(stepX(index, width: width) <= thumbX ? Color.white.opacity(0.55) : Color(.systemGray3))
                        .frame(width: 6, height: 6)
                        .position(x: stepX(index, width: width), y: trackHeight / 2)
                }

                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.06)))
                    .frame(width: thumbSize, height: thumbSize)
                    .position(x: thumbX, y: trackHeight / 2)
                    .overlay {
                        if !reduceMotion {
                            SparkleBurst(trigger: reachedMax)
                                .position(x: thumbX, y: trackHeight / 2)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .frame(height: trackHeight)
            .contentShape(.rect)
            // 高优先级：别让上拉栏的下滑关闭手势把横向拖动抢走。
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragX) { value, state, _ in state = value.location.x }
                    .onEnded { value in
                        withAnimation(.spring(duration: 0.3, bounce: 0.25)) {
                            select(nearestIndex(to: value.location.x, width: width))
                        }
                    }
            )
        }
        .frame(height: trackHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { trackWidth = $0 }
        .padding(.vertical, (thumbSize - trackHeight) / 2)
    }

    private func select(_ index: Int) {
        guard options.indices.contains(index), index != selectedIndex else { return }
        let reachesMax = hasMaxLevel && options.count > 1 && index == options.count - 1
        commit(options[index])
        if reachesMax { reachedMax += 1 }
    }

    // MARK: 几何

    /// 第 i 档的滑块中心：两端各留半个滑块，档位均分。
    private func stepX(_ index: Int, width: CGFloat) -> CGFloat {
        let inset = thumbSize / 2 - (thumbSize - trackHeight) / 2
        guard options.count > 1 else { return inset }
        let span = width - inset * 2
        return inset + span * CGFloat(index) / CGFloat(options.count - 1)
    }

    private func clamp(_ x: CGFloat, width: CGFloat) -> CGFloat {
        min(max(x, stepX(0, width: width)), stepX(options.count - 1, width: width))
    }

    private func nearestIndex(to x: CGFloat, width: CGFloat) -> Int {
        let distances = options.indices.map { abs(stepX($0, width: width) - x) }
        return distances.indices.min { distances[$0] < distances[$1] } ?? 0
    }

    static let maxGradient = LinearGradient(
        colors: [Color(red: 0.31, green: 0.27, blue: 0.90), Color(red: 0.55, green: 0.36, blue: 0.96), Color(red: 0.66, green: 0.33, blue: 0.97)],
        startPoint: .leading,
        endPoint: .trailing
    )
}

/// 最高档轨道里的白色小气泡：大小、速度、高度各不相同，一直往左飘，飘出左边从右边再进来。
private struct BubbleField: View {
    private static let bubbles: [(x: Double, y: Double, size: Double, speed: Double, alpha: Double)] =
        (0 ..< 18).map { index in
            let seed = Double(index)
            func noise(_ k: Double) -> Double { (sin(seed * k) * 43758.5453).truncatingRemainder(dividingBy: 1).magnitude }
            return (
                x: noise(12.9898),
                y: 0.2 + noise(78.233) * 0.6,
                size: 1.5 + noise(3.71) * 3,
                // 每秒走轨道宽度的 6%～18%：大的慢、小的快，有层次。
                speed: 0.06 + noise(9.13) * 0.12,
                alpha: 0.35 + noise(5.27) * 0.55
            )
        }

    var body: some View {
        TimelineView(.animation) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                for bubble in Self.bubbles {
                    var x = (bubble.x - time * bubble.speed).truncatingRemainder(dividingBy: 1)
                    if x < 0 { x += 1 }
                    // 上下轻轻晃一点，像在飘。
                    let y = bubble.y + sin(time * 1.6 + bubble.x * 9) * 0.06
                    let rect = CGRect(
                        x: x * (size.width + bubble.size * 2) - bubble.size,
                        y: y * size.height - bubble.size / 2,
                        width: bubble.size,
                        height: bubble.size
                    )
                    canvas.fill(Path(ellipseIn: rect), with: .color(.white.opacity(bubble.alpha)))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// 彩蛋：一圈星星从滑块迸出、往外飞、淡掉。trigger 每变一次放一遍。
/// 用 KeyframeAnimator：同一帧里先置 0 再动画到 1 会被合并成「不动」。
private struct SparkleBurst: View {
    let trigger: Int

    private static let count = 14

    var body: some View {
        KeyframeAnimator(initialValue: CGFloat(1), trigger: trigger) { progress in
            particles(progress)
        } keyframes: { _ in
            MoveKeyframe(0)
            CubicKeyframe(1, duration: 0.9)
        }
    }

    private func particles(_ progress: CGFloat) -> some View {
        ZStack {
            ForEach(0 ..< Self.count, id: \.self) { index in
                let angle = Double(index) / Double(Self.count) * 2 * .pi + (index.isMultiple(of: 2) ? 0.2 : 0)
                let distance = (index.isMultiple(of: 3) ? 70 : 52) * progress
                Image(systemName: index.isMultiple(of: 2) ? "sparkle" : "star.fill")
                    .font(.system(size: index.isMultiple(of: 3) ? 13 : 9, weight: .bold))
                    .foregroundStyle(index.isMultiple(of: 2)
                        ? Color(red: 0.66, green: 0.33, blue: 0.97)
                        : Color(red: 1.0, green: 0.78, blue: 0.25))
                    .rotationEffect(.degrees(Double(progress) * 180))
                    .scaleEffect(progress < 0.15 ? progress / 0.15 : 1 - (progress - 0.15) * 0.6)
                    .offset(x: cos(angle) * distance, y: sin(angle) * distance)
                    .opacity(progress >= 1 ? 0 : 1 - Double(progress) * 0.9)
            }
        }
    }
}
