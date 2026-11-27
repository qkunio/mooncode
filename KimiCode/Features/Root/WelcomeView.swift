import SwiftUI

/// 首屏：欢迎（下一步）→ 选用的是 CLI 还是桌面端 → CLI：在终端运行 kimi rc / 桌面端：看示例动画在设置里打开远程控制
/// （我已完成）→ 登录。登录前的每步逐字出现，打完才出按钮；回到看过的一步不再重打。
/// 第一次出现时先放开场动效（`SplashFace`）。
struct WelcomeView: View {
    private enum Step { case intro, choose, terminal, desktop, login }
    private enum Splash { case cover, shrunk }

    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = Step.intro
    @State private var revealedCharacters = 0
    /// 文字已经全部打出来的步骤；登录页没有逐字动画。
    @State private var typedSteps: Set<Step> = []
    @State private var splash = Splash.cover
    /// 启动画面是系统默认的白底：开场先从白快速渐变成整屏蓝，再出眼睛。
    @State private var blueShown = false
    @State private var eyesShown = false
    @State private var blinking = false
    @State private var landed = false
    /// 第一行打完时喷一次彩条（计数既当 haptic 触发器，也当彩条视图的 id）。
    @State private var confettiBursts = 0
    @State private var showsConfetti = false
    /// 页面上 bot 的位置（全局坐标），开场的大脸收缩到这里。
    @State private var faceFrame = CGRect.zero

    private let welcome = "欢迎来到Moon Code！"
    private let tagline = "KimiCode的远程控制客户端"
    private let chooseTitle = "你使用的是哪个"
    private let chooseSubtitle = "Kimi Code？"
    private let instruction = "请你在任意终端运行"
    private let desktopTitle = "在 Kimi Code 桌面端"
    private let desktopSubtitle = "打开远程控制"
    private let command = "kimi rc"

    private var auth: AuthStore { model.auth }
    private var isWorking: Bool { auth.isPreparing || auth.isSigningIn }
    private var isLogin: Bool { step == .login }
    private var isTyped: Bool { isLogin || typedSteps.contains(step) }
    private var showsSplash: Bool { !model.hasPlayedSplash && !reduceMotion }

    private var lines: [String] { lines(for: step) }

    private func lines(for step: Step) -> [String] {
        switch step {
        case .intro: [welcome, tagline]
        case .choose: [chooseTitle, chooseSubtitle]
        case .terminal: [instruction, command]
        case .desktop: [desktopTitle, desktopSubtitle]
        case .login: []
        }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Spacer(minLength: 32)

                // 登录页只有一行字标，贴近 bot 一些
                VStack(spacing: isLogin ? 10 : 28) {
                    KimiFace(animating: true)
                        .scaleEffect(4.5)
                        .frame(width: 120, height: 104)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { faceFrame = $0 }
                        .opacity(showsSplash ? 0 : 1)
                        .accessibilityHidden(true)

                    // 三步的文字块高度不同，固定高度免得换步时 bot 上下跳
                    Group {
                    switch step {
                    case .intro:
                        VStack(spacing: 10) {
                            Text(streamed(welcome, offset: 0, brand: true))
                                .font(.system(size: 26, weight: .bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text(streamed(tagline, offset: welcome.count))
                                .font(.system(size: 26, weight: .bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .multilineTextAlignment(.center)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(welcome)\n\(tagline)")
                        .transition(.opacity)
                    case .choose:
                        twoLines(chooseTitle, chooseSubtitle)
                    case .desktop:
                        twoLines(desktopTitle, desktopSubtitle)
                    case .terminal:
                        VStack(spacing: 20) {
                            Text(streamed(instruction, offset: 0))
                                .font(.system(size: 26, weight: .bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text(streamed(command, offset: instruction.count))
                                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .multilineTextAlignment(.center)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(instruction)\n\(command)")
                        .transition(.opacity)
                    case .login:
                        (Text("Moon").foregroundStyle(Palette.kimi) + Text(" Code"))
                            .font(.system(size: 40, weight: .black))
                            .transition(.opacity)
                    }
                    }
                    .frame(height: 96, alignment: isLogin ? .top : .center)
                }
                .frame(maxWidth: .infinity)

                if step == .desktop {
                    DesktopRemoteDemo()
                        .frame(maxWidth: 420)
                        .padding(.top, 8)
                        .opacity(isTyped ? 1 : 0)
                        .transition(.opacity)
                }

                Spacer(minLength: step == .desktop ? 24 : 40)

                VStack(spacing: 18) {
                    if let error = auth.lastError, isLogin {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    if step == .choose {
                        choice("Kimi Code 桌面端", icon: "KimiCodeDesktopIcon") { go(to: .desktop) }
                        choice("Kimi Code CLI", icon: "KimiCodeCLIIcon") { go(to: .terminal) }
                    } else {
                    Button {
                        switch step {
                        case .intro:
                            go(to: .choose)
                        case .choose:
                            break
                        case .terminal, .desktop:
                            auth.prepareSignIn()
                            go(to: .login)
                        case .login:
                            Task { await auth.signIn() }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if isLogin && isWorking {
                                ProgressView().tint(.white)
                                Text(auth.isSigningIn ? "正在登录…" : "正在准备…")
                            } else {
                                Text(buttonTitle)
                                MoonIcon("mc-arrow-right", size: 18)
                            }
                        }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Palette.kimi, in: .capsule)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .disabled(isLogin && isWorking)
                    }

                    if isLogin {
                        // 不登录进体验模式：界面全功能可点，数据来自本地演示后端（App Store 审核用）。
                        Button {
                            model.startDemo()
                        } label: {
                            Text("暂不登录，体验功能")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(Color(.tertiarySystemFill), in: .capsule)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                }
                .opacity(isTyped ? 1 : 0)
                .allowsHitTesting(isTyped)
                .accessibilityHidden(!isTyped)
                .frame(maxWidth: 420)
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 28)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .overlay(alignment: .topLeading) {
            if step == .terminal || step == .desktop {
                Button {
                    go(to: .choose)
                } label: {
                    MoonIcon("mc-chevron-left", size: 18)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .accessibilityLabel("返回")
                .padding(.leading, 16)
                .transition(.opacity)
            }
        }
        .background {
            ZStack {
                Color(.systemBackground)
                LinearGradient(
                    colors: [Palette.kimi.opacity(0.06), .clear, .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .ignoresSafeArea()
        }
        .overlay {
            if showsSplash {
                GeometryReader { proxy in
                    let origin = proxy.frame(in: .global).origin
                    // KimiFace 是 24×16 单位、放大 4.5 倍画在 bot 框正中
                    let bot = CGRect(x: faceFrame.midX - 54 - origin.x, y: faceFrame.midY - 36 - origin.y, width: 108, height: 72)
                    let covering = splash == .cover
                    SplashFace(
                        rect: covering ? CGRect(origin: .zero, size: proxy.size) : bot,
                        unit: covering ? 14 : 4.5,
                        cornerRadius: covering ? 0 : 2.3 * 4.5,
                        eyesShown: eyesShown,
                        blinking: blinking
                    )
                    .opacity(blueShown ? 1 : 0)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .overlay {
            if showsConfetti {
                ConfettiBurst().id(confettiBursts)
            }
        }
        .statusBarHidden(showsSplash)
        .sensoryFeedback(.impact(weight: .medium), trigger: landed)
        .sensoryFeedback(.success, trigger: confettiBursts)
        // 逐字打出时每个字轻震一下，像在敲键盘；换步清零、回到打过的一步时不震
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.6), trigger: revealedCharacters) { old, new in new == old + 1 }
        .animation(.default, value: auth.lastError)
        .task(id: step) {
            if showsSplash { await playSplash() }
            guard !isTyped else { return }
            let total = lines.reduce(0) { $0 + $1.count }
            if reduceMotion {
                revealedCharacters = total
                typedSteps.insert(step)
                return
            }
            while revealedCharacters < total {
                do { try await Task.sleep(for: .milliseconds(55)) } catch { return }
                revealedCharacters += 1
                // 「欢迎来到Moon Code！」打完：喷彩条，停一下再打第二行
                if step == .intro && revealedCharacters == welcome.count {
                    await celebrate()
                }
            }
            withAnimation(.easeIn(duration: 0.3)) { _ = typedSteps.insert(step) }
        }
    }

    private var buttonTitle: String {
        switch step {
        case .intro: "下一步"
        case .choose: ""
        case .terminal, .desktop: "我已完成"
        case .login: "登录 Kimi 账号"
        }
    }

    /// 开场：白底快速渐变成整屏蓝（bot 的脸）→ 眼睛弹出、眨一下 → 收缩成页面上的 bot（不回弹，落定时震一下）→ 开始打字。
    private func playSplash() async {
        defer { model.hasPlayedSplash = true }
        do {
            withAnimation(.easeOut(duration: 0.25)) { blueShown = true }
            try await Task.sleep(for: .milliseconds(300))
            withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) { eyesShown = true }
            try await Task.sleep(for: .milliseconds(450))
            withAnimation(.easeIn(duration: 0.07)) { blinking = true }
            try await Task.sleep(for: .milliseconds(90))
            withAnimation(.easeOut(duration: 0.1)) { blinking = false }
            try await Task.sleep(for: .milliseconds(300))
            // 不带回弹：一口气收到位，不压过头
            withAnimation(.smooth(duration: 0.5)) { splash = .shrunk }
            try await Task.sleep(for: .milliseconds(450))
            landed = true
            try await Task.sleep(for: .milliseconds(200))
        } catch {}
    }

    private func celebrate() async {
        // 先让「！」露出来一拍，再喷
        try? await Task.sleep(for: .milliseconds(180))
        confettiBursts += 1
        showsConfetti = true
        try? await Task.sleep(for: .milliseconds(900))
        // 彩条自己飘完后再拿掉；期间换步也不影响
        Task {
            try? await Task.sleep(for: .seconds(ConfettiBurst.duration))
            showsConfetti = false
        }
    }

    /// 换步时同时清零逐字进度，新一步的文字不会先整段闪一下；打过的一步直接整段显示。
    private func go(to next: Step) {
        withAnimation(.smooth(duration: 0.3)) {
            // 别用 .max：触感回调里的 old + 1 会溢出闪退
            revealedCharacters = typedSteps.contains(next) ? lines(for: next).reduce(0) { $0 + $1.count } : 0
            step = next
        }
    }

    private func twoLines(_ first: String, _ second: String) -> some View {
        VStack(spacing: 10) {
            Text(streamed(first, offset: 0))
                .font(.system(size: 26, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(streamed(second, offset: first.count))
                .font(.system(size: 26, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(first)\n\(second)")
        .transition(.opacity)
    }

    /// 「桌面端 / CLI」二选一的卡片。图标：桌面端取自 Kimi Code App，CLI 用 MoonshotAI 的 GitHub 头像。
    private func choice(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(icon)
                    .resizable()
                    .frame(width: 44, height: 44)
                    .clipShape(.rect(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                    .accessibilityHidden(true)
                Text(title).font(.body.weight(.semibold))
                Spacer(minLength: 0)
                MoonIcon("mc-chevron-right", size: 13)
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .frame(height: 72)
            .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 24))
            .contentShape(.rect(cornerRadius: 24))
        }
        .buttonStyle(.plain)
    }

    /// 保留未显示字符的排版空间，逐字出现时不会挤动 bot 和按钮。
    private func streamed(_ text: String, offset: Int, brand: Bool = false) -> AttributedString {
        var result = AttributedString(text)
        result.foregroundColor = .primary
        if brand, let range = result.range(of: "Moon") {
            result[range].foregroundColor = Palette.kimi
        }
        let visible = min(max(revealedCharacters - offset, 0), text.count)
        let start = result.characters.index(result.startIndex, offsetBy: visible)
        result[start..<result.endIndex].foregroundColor = .clear
        return result
    }

}

/// 开场动效里的 bot：几何与 `KimiFace` 一致（24×16 单位，眼睛 3×4.5、间距 6、偏移 (2.7, -2.8)），
/// `unit` 收到 4.5、圆角收到 2.3×4.5 时和页面上的真 bot 严丝合缝，换过去看不出接缝。
private struct SplashFace: View {
    let rect: CGRect
    let unit: CGFloat
    let cornerRadius: CGFloat
    let eyesShown: Bool
    let blinking: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Palette.kimi)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
            ForEach([-1.0, 1.0], id: \.self) { side in
                Rectangle()
                    .fill(.white)
                    .frame(width: 3 * unit, height: 4.5 * unit)
                    .scaleEffect(x: eyesShown ? 1 : 0, y: eyesShown ? (blinking ? 0.12 : 1) : 0)
                    .position(x: rect.midX + (2.7 + 4.5 * side) * unit, y: rect.midY - 2.8 * unit)
            }
        }
    }
}
