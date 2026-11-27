import SwiftUI

/// 记录每次 App 更新后是否已经展示过「版本兼容与网页版入口」通知。
enum AppUpdateNotice {
    static let lastNotifiedKey = "kimi.lastNotifiedAppVersion"

    /// 展示用的短版本号（如 `1.7`）。
    static var shortVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    }

    /// 区分每次更新的版本标识（短版本号 + 构建号）。
    static var currentVersion: String {
        let short = shortVersion
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? ""
        if short.isEmpty { return build }
        return build.isEmpty ? short : "\(short) (\(build))"
    }

    static func shouldPresent(
        defaults: UserDefaults = .standard,
        currentVersion: String = currentVersion
    ) -> Bool {
        guard !currentVersion.isEmpty else { return false }
        return defaults.string(forKey: lastNotifiedKey) != currentVersion
    }

    static func markPresented(
        defaults: UserDefaults = .standard,
        currentVersion: String = currentVersion
    ) {
        guard !currentVersion.isEmpty else { return }
        defaults.set(currentVersion, forKey: lastNotifiedKey)
    }
}

/// 每次 App 更新后首次进入主界面时弹出：告知当前版本支持的 Kimi Code 截止日期，
/// 并用循环动画演示「侧栏 → 个人页面 → 打开Kimi Code网页版」的兜底路径。
struct UpdateNoticeSheet: View {
    let dismiss: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer(minLength: 20)

                    VStack(spacing: 28) {
                        VStack(spacing: 18) {
                            Text("版本兼容说明")
                                .font(.title.weight(.bold))
                                .multilineTextAlignment(.center)

                            Text("支持\(Text("「\(KimiConfig.supportedKimiCodeDate)」").foregroundStyle(.primary).fontWeight(.medium))前的 Kimi\u{00A0}Code 版本\n若 Kimi\u{00A0}Code 更新引发错误，可随时使用网页版")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineSpacing(4)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(spacing: 14) {
                            WebFallbackDemo()
                                .frame(maxHeight: 430)

                            HStack(spacing: 6) {
                                Label { Text("侧栏") } icon: { MoonIcon("mc-menu", size: 13) }
                                MoonIcon("mc-chevron-right", size: 11)
                                Text("账号")
                                MoonIcon("mc-chevron-right", size: 11)
                                Text("打开Kimi Code网页版")
                                    .foregroundStyle(.primary)
                                    .fontWeight(.medium)
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        }
                    }
                    .padding(.horizontal, 24)

                    Spacer(minLength: 20)
                }
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaBar(edge: .bottom, spacing: 0) {
            Button(action: dismiss) {
                Text("我知道了")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Palette.kimi, in: .capsule)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 14)
        }
        .background(Color(.systemBackground))
    }
}

/// 网页版入口演示动画（参考 `DesktopRemoteDemo`）：
/// 按 iPhone 17 逻辑尺寸（402×874，1:2 缩小为 201×437）等比绘制的 Moon Code 界面，
/// 触点依次点左上角 `≡` 打开侧栏 → 点底部账号卡片 → 在个人页点击「打开Kimi Code网页版」跳转到 Safari，循环播放。
struct WebFallbackDemo: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pointer = Self.restPoint
    @State private var pressing = false
    @State private var ripples = 0
    @State private var rippleAt = CGPoint.zero
    @State private var sidebarOpen = false
    @State private var accountOpen = false
    @State private var webRowHighlighted = false
    @State private var safariShown = false
    @State private var visible = true

    /// iPhone 17（402×874 pt）精确比例。
    private static let size = CGSize(width: 201, height: 437)
    private static let cornerRadius: CGFloat = 28
    private static let sidebarWidth: CGFloat = 168
    private static let restPoint = CGPoint(x: 132, y: 256)
    private static let menuButton = CGPoint(x: 23, y: 43)
    private static let accountButton = CGPoint(x: 84, y: 404)
    private static let webRowButton = CGPoint(x: 100.5, y: 225)

    var body: some View {
        Color.clear
            .aspectRatio(Self.size.width / Self.size.height, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let scale = min(proxy.size.width / Self.size.width, proxy.size.height / Self.size.height)
                    canvas
                        .frame(width: Self.size.width, height: Self.size.height)
                        .scaleEffect(scale, anchor: .topLeading)
                        .frame(width: Self.size.width * scale, height: Self.size.height * scale, alignment: .topLeading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .opacity(visible ? 1 : 0)
            .accessibilityElement()
            .accessibilityLabel("示例：点左上角打开侧栏，点底部账号进入个人页面，点击打开Kimi Code网页版")
            .task { await play() }
    }

    // MARK: - 画面

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            // 手机机身底与阴影
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.14), radius: 12, y: 5)

            // 屏幕内容裁剪在机身圆角内
            ZStack(alignment: .topLeading) {
                homeScreen
                    .offset(x: sidebarOpen ? Self.sidebarWidth : 0)

                if sidebarOpen {
                    Color.black.opacity(0.18)
                        .transition(.opacity)
                }

                sidebarScreen
                    .frame(width: Self.sidebarWidth, height: Self.size.height, alignment: .topLeading)
                    .offset(x: sidebarOpen ? 0 : -Self.sidebarWidth)

                if accountOpen {
                    accountScreen
                        .transition(.move(edge: .bottom))
                }

                if safariShown {
                    safariOverlay
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }

                statusBar

                // 底部 Home 指示条
                VStack {
                    Spacer()
                    Capsule()
                        .fill(Color.primary.opacity(0.24))
                        .frame(width: 68, height: 2.5)
                        .padding(.bottom, 6)
                }
                .frame(width: Self.size.width, height: Self.size.height)
                .allowsHitTesting(false)

                // 点击波纹
                Circle()
                    .stroke(Palette.kimi, lineWidth: 2)
                    .frame(width: 24, height: 24)
                    .keyframeAnimator(initialValue: 1.0, trigger: ripples) { view, progress in
                        view.scaleEffect(0.45 + progress).opacity(1 - progress)
                    } keyframes: { _ in
                        LinearKeyframe(0.0, duration: 0)
                        LinearKeyframe(1.0, duration: 0.45)
                    }
                    .position(rippleAt)

                // 触控圆点（跳进 Safari 后隐去，避免挡住页面文字）
                Circle()
                    .fill(Palette.kimi.opacity(pressing ? 0.42 : 0.24))
                    .overlay {
                        Circle()
                            .stroke(Color(.systemBackground), lineWidth: 2)
                    }
                    .overlay {
                        Circle()
                            .stroke(Palette.kimi, lineWidth: 1.2)
                    }
                    .frame(width: 18, height: 18)
                    .scaleEffect(pressing ? 0.82 : 1)
                    .opacity(safariShown ? 0 : 1)
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                    .position(pointer)
            }
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
            .clipShape(.rect(cornerRadius: Self.cornerRadius, style: .continuous))

            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .stroke(Color(.separator), lineWidth: 1)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }

    private var statusBar: some View {
        ZStack {
            Capsule()
                .fill(Color.primary.opacity(0.88))
                .frame(width: 56, height: 15)
            HStack {
                Text("9:41")
                    .font(.system(size: 8.5, weight: .semibold))
                Spacer()
                HStack(spacing: 3) {
                    MoonIcon("mc-wifi", size: 8)
                    MoonIcon("mc-battery", size: 9)
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(width: Self.size.width, height: 18)
        .padding(.top, 7)
    }

    private var homeScreen: some View {
        ZStack(alignment: .topLeading) {
            Color(.systemBackground)

            // 顶部工具栏：≡ 与右侧图标
            HStack {
                Circle()
                    .fill(Color(.secondarySystemBackground))
                    .frame(width: 22, height: 22)
                    .overlay {
                        MoonIcon("mc-menu", size: 9.5)
                    }
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color(.secondarySystemBackground))
                        .frame(width: 22, height: 22)
                        .overlay {
                            Image(systemName: "chart.pie")
                                .font(.system(size: 9))
                        }
                    Circle()
                        .fill(Color(.secondarySystemBackground))
                        .frame(width: 22, height: 22)
                        .overlay {
                            MoonIcon("mc-workspace", size: 9)
                        }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 32)

            // 中间欢迎小脸 + 对话占位
            VStack(spacing: 12) {
                KimiFace(animating: false)
                    .scaleEffect(1.25)
                Capsule()
                    .fill(Color(.tertiarySystemFill))
                    .frame(width: 102, height: 6.5)
            }
            .position(x: Self.size.width / 2, y: 205)

            // 底部输入框
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(Color(.secondarySystemBackground))
                .frame(width: Self.size.width - 20, height: 46)
                .overlay(alignment: .topLeading) {
                    Text("让 Kimi 做点什么…")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.top, 9)
                }
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(Color.primary)
                        .frame(width: 15, height: 15)
                        .overlay {
                            MoonIcon("mc-arrow-up", size: 7.5)
                                .foregroundStyle(Color(.systemBackground))
                        }
                        .padding(7)
                }
                .position(x: Self.size.width / 2, y: 392)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var sidebarScreen: some View {
        ZStack(alignment: .topLeading) {
            Color(.systemGroupedBackground)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    KimiFace(animating: false)
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 12)
                    (Text("Moon").foregroundStyle(Palette.kimi) + Text(" Code"))
                        .font(.system(size: 11.5, weight: .black))
                }
                .padding(.top, 34)

                // 设备条
                HStack(spacing: 5) {
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 5, height: 5)
                        Text("MacBook")
                            .font(.system(size: 7.5, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.secondarySystemGroupedBackground), in: .capsule)
                }

                HStack(spacing: 6) {
                    MoonIcon("mc-add-workspace", size: 9)
                    Text("添加文件夹")
                        .font(.system(size: 8))
                }
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 9) {
                    ForEach(0..<6, id: \.self) { index in
                        let isFolder = index % 3 == 0
                        HStack(spacing: 6) {
                            if isFolder {
                                MoonIcon("mc-workspace", size: 8)
                                    .foregroundStyle(.secondary)
                            }
                            Capsule()
                                .fill(Color(.tertiarySystemFill))
                                .frame(width: isFolder ? 82 : (index.isMultiple(of: 2) ? 68 : 54), height: 6)
                        }
                        .padding(.leading, isFolder ? 0 : 12)
                    }
                }
                .padding(.top, 2)

                Spacer()

                // 底部账号胶囊
                HStack(spacing: 6) {
                    Circle()
                        .fill(Palette.kimi.opacity(0.2))
                        .frame(width: 18, height: 18)
                        .overlay {
                            MoonIcon("mc-user", size: 8.5)
                                .foregroundStyle(Palette.kimi)
                        }
                    Text("Kimi 用户")
                        .font(.system(size: 8, weight: .semibold))
                    MoonIcon("mc-chevron-right", size: 6.5)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemGroupedBackground), in: .capsule)
                .shadow(color: .black.opacity(0.06), radius: 3, y: 1)
                .padding(.bottom, 18)
            }
            .padding(.horizontal, 12)
        }
    }

    private var accountScreen: some View {
        ZStack(alignment: .topLeading) {
            Color(.systemGroupedBackground)

            VStack(alignment: .leading, spacing: 10) {
                Capsule()
                    .fill(Color(.tertiaryLabel))
                    .frame(width: 26, height: 3)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)

                // 头像卡
                HStack(spacing: 8) {
                    Circle()
                        .fill(Palette.kimi.opacity(0.2))
                        .frame(width: 24, height: 24)
                        .overlay {
                            MoonIcon("mc-user", size: 10.5)
                                .foregroundStyle(Palette.kimi)
                        }
                    Text("Kimi 用户")
                        .font(.system(size: 9.5, weight: .semibold))
                    Spacer()
                }
                .padding(9)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 11))

                // 默认配置占位卡
                VStack(spacing: 8) {
                    ForEach(["默认模型", "默认强度", "默认权限"], id: \.self) { title in
                        HStack {
                            Text(title).font(.system(size: 8))
                            Spacer()
                            Capsule().fill(Color(.tertiarySystemFill)).frame(width: 34, height: 5.5)
                        }
                    }
                }
                .padding(9)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 11))

                // 设备显示开关
                HStack {
                    Text("在会话栏中显示设备列表")
                        .font(.system(size: 7.5))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Capsule()
                        .fill(Color.green)
                        .frame(width: 20, height: 12)
                        .overlay(alignment: .trailing) {
                            Circle().fill(.white).padding(1.5)
                        }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 11))

                // 网页版入口卡（高亮目标）
                HStack(spacing: 5) {
                    Text("打开Kimi Code网页版")
                        .font(.system(size: 8, weight: webRowHighlighted ? .semibold : .regular))
                        .foregroundStyle(webRowHighlighted ? Palette.kimi : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    MoonIcon("mc-globe", size: 8.5)
                        .foregroundStyle(webRowHighlighted ? Palette.kimi : .secondary)
                    MoonIcon("mc-arrow-up-right", size: 6.5)
                        .foregroundStyle(webRowHighlighted ? Palette.kimi : .secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 9)
                .background(
                    webRowHighlighted ? Palette.kimi.opacity(0.14) : Color(.secondarySystemGroupedBackground),
                    in: .rect(cornerRadius: 11)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(webRowHighlighted ? Palette.kimi : .clear, lineWidth: 1.2)
                }

                Spacer()

                Text("退出登录")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 11))
                    .padding(.bottom, 18)
            }
            .padding(.horizontal, 12)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var safariOverlay: some View {
        ZStack {
            Color(.systemBackground)

            VStack(spacing: 12) {
                HStack(spacing: 4) {
                    MoonIcon("mc-lock", size: 7)
                        .foregroundStyle(.secondary)
                    Text("code-rc.kimi.com")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(.secondarySystemBackground), in: .capsule)
                .padding(.top, 36)

                Spacer()

                VStack(spacing: 8) {
                    MoonIcon("mc-globe", size: 30)
                        .foregroundStyle(Palette.kimi)
                    Text("Kimi Code 网页版")
                        .font(.system(size: 10.5, weight: .bold))
                    Text("已在 Safari 中打开")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(Color(.tertiarySystemFill)).frame(width: 105, height: 6)
                    Capsule().fill(Color(.tertiarySystemFill)).frame(width: 145, height: 6)
                    Capsule().fill(Color(.tertiarySystemFill)).frame(width: 84, height: 6)
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 11))
                .padding(.horizontal, 12)
                .padding(.bottom, 22)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    // MARK: - 播放

    private func play() async {
        do {
            while true {
                try await step { pointer = Self.menuButton }
                try await tap { sidebarOpen = true }
                try await step { pointer = Self.accountButton }
                try await tap { accountOpen = true }
                try await step { pointer = Self.webRowButton }
                try await tap { webRowHighlighted = true }
                try await Task.sleep(for: .milliseconds(250))
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
                    safariShown = true
                }
                try await Task.sleep(for: .seconds(2.2))
                withAnimation(.easeOut(duration: 0.3)) { visible = false }
                try await Task.sleep(for: .milliseconds(350))
                pointer = Self.restPoint
                sidebarOpen = false
                accountOpen = false
                webRowHighlighted = false
                safariShown = false
                withAnimation(.easeIn(duration: 0.3)) { visible = true }
                try await Task.sleep(for: .milliseconds(500))
            }
        } catch {}
    }

    private func step(move: () -> Void) async throws {
        try await Task.sleep(for: .milliseconds(450))
        if reduceMotion { move() } else { withAnimation(.easeInOut(duration: 0.75), move) }
        try await Task.sleep(for: .milliseconds(850))
    }

    private func tap(then change: () -> Void) async throws {
        withAnimation(.easeIn(duration: 0.08)) { pressing = true }
        rippleAt = pointer
        if !reduceMotion { ripples += 1 }
        try await Task.sleep(for: .milliseconds(120))
        withAnimation(.easeOut(duration: 0.12)) { pressing = false }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.35), change)
        try await Task.sleep(for: .milliseconds(750))
    }
}

#Preview {
    UpdateNoticeSheet {}
}
