import SwiftUI

/// 引导里「Kimi Code 桌面端」的示例动画：一个缩小的桌面端窗口，光标依次点
/// 左下角 ⚙︎ → 设置里的「远程控制」→ 打开开关，循环播放。
/// 画面按 340×220 的设计尺寸摆放，整体等比缩放到可用空间。
struct DesktopRemoteDemo: View {
    private enum Pane { case general, remote }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cursor = Self.restPoint
    @State private var pressing = false
    @State private var ripples = 0
    @State private var rippleAt = CGPoint.zero
    @State private var settingsShown = false
    @State private var pane = Pane.general
    @State private var toggleOn = false
    @State private var visible = true

    private static let size = CGSize(width: 340, height: 220)
    private static let restPoint = CGPoint(x: 236, y: 150)
    private static let gear = CGPoint(x: 82, y: 205)
    private static let modal = CGRect(x: 34, y: 18, width: 292, height: 192)
    private static let listWidth: CGFloat = 86
    private static let rowTitles = ["通用", "账户", "模型供应商", "远程控制", "关于"]
    private static let rowIcons = ["mc-settings", "mc-user", "mc-skill-bolt", "mc-remote-control", "mc-info-circle"]
    private static func rowY(_ index: Int) -> CGFloat { modal.minY + 40 + CGFloat(index) * 19 }
    private static let remoteRow = CGPoint(x: modal.minX + 50, y: rowY(3))
    private static let toggle = CGPoint(x: modal.maxX - 26, y: modal.minY + 54)

    var body: some View {
        Color.clear
            .aspectRatio(Self.size.width / Self.size.height, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let scale = proxy.size.width / Self.size.width
                    canvas
                        .frame(width: Self.size.width, height: Self.size.height)
                        .scaleEffect(scale, anchor: .topLeading)
                }
            }
            .opacity(visible ? 1 : 0)
            .accessibilityElement()
            .accessibilityLabel("示例：点左下角的设置，选择远程控制，打开远程控制开关")
            .task { await play() }
    }

    // MARK: - 画面

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            window
            if settingsShown {
                Color.black.opacity(0.18)
                    .clipShape(.rect(cornerRadius: 12))
                    .transition(.opacity)
                settings
                    .transition(.scale(scale: 0.94).combined(with: .opacity))
            }
            Circle()
                .stroke(Palette.kimi, lineWidth: 2)
                .frame(width: 22, height: 22)
                .keyframeAnimator(initialValue: 1.0, trigger: ripples) { view, progress in
                    view.scaleEffect(0.4 + progress).opacity(1 - progress)
                } keyframes: { _ in
                    LinearKeyframe(0.0, duration: 0)
                    LinearKeyframe(1.0, duration: 0.45)
                }
                .position(rippleAt)
            MoonIcon("mc-cursor", size: 17)
                .foregroundStyle(.primary)
                .shadow(color: Color(.systemBackground), radius: 1.5)
                .scaleEffect(pressing ? 0.85 : 1, anchor: .topLeading)
                // 箭头尖在字形左上角
                .position(x: cursor.x + 5, y: cursor.y + 8)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }

    private var window: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(.separator), lineWidth: 0.5)

            // 侧栏
            UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12)
                .fill(Color(.secondarySystemBackground))
                .frame(width: 96, height: Self.size.height)
            HStack(spacing: 4) {
                ForEach([Color.red, .yellow, .green], id: \.self) { color in
                    Circle().fill(color.opacity(0.8)).frame(width: 7, height: 7)
                }
            }
            .offset(x: 10, y: 10)
            VStack(alignment: .leading, spacing: 8) {
                Label { Text("新建会话") } icon: { MoonIcon("mc-plus-circle", size: 10) }
                Label { Text("搜索") } icon: { MoonIcon("mc-search", size: 10) }
                ForEach(0..<5) { index in
                    Capsule()
                        .fill(Color(.tertiarySystemFill))
                        .frame(width: index.isMultiple(of: 2) ? 58 : 44, height: 6)
                        .padding(.leading, index.isMultiple(of: 2) ? 0 : 10)
                }
            }
            .font(.system(size: 8, weight: .medium))
            .labelStyle(.titleAndIcon)
            .offset(x: 10, y: 30)
            Circle()
                .fill(Palette.kimi.opacity(0.5))
                .frame(width: 13, height: 13)
                .position(x: 18, y: Self.gear.y)
            Capsule()
                .fill(Color(.tertiarySystemFill))
                .frame(width: 30, height: 6)
                .position(x: 46, y: Self.gear.y)
            MoonIcon("mc-settings", size: 10)
                .foregroundStyle(.secondary)
                .position(Self.gear)

            // 主区：空对话 + 输入框
            KimiFace(animating: false)
                .scaleEffect(1.4)
                .opacity(0.25)
                .position(x: 218, y: 96)
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(.separator), lineWidth: 0.8)
                .frame(width: 196, height: 34)
                .position(x: 218, y: 186)
        }
    }

    private var settings: some View {
        let modal = Self.modal
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10)
                .fill(Color(.secondarySystemBackground).opacity(0.6))
                .frame(width: Self.listWidth, height: modal.height)
            Text("设置")
                .font(.system(size: 10, weight: .bold))
                .offset(x: 10, y: 10)
            ForEach(Self.rowTitles.indices, id: \.self) { index in
                let selected = index == (pane == .remote ? 3 : 0)
                HStack(spacing: 4) {
                    MoonIcon(Self.rowIcons[index], size: 9).frame(width: 10)
                    Text(Self.rowTitles[index])
                }
                .font(.system(size: 7.5, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 5)
                .frame(width: Self.listWidth - 12, height: 15, alignment: .leading)
                .background(selected ? Color(.tertiarySystemFill) : .clear, in: .rect(cornerRadius: 4))
                .position(x: Self.listWidth / 2, y: Self.rowY(index) - modal.minY)
            }

            Group {
                if pane == .remote { remotePane } else { generalPane }
            }
            .frame(width: modal.width - Self.listWidth - 20, alignment: .topLeading)
            .offset(x: Self.listWidth + 10, y: 12)
        }
        .frame(width: modal.width, height: modal.height)
        .offset(x: modal.minX, y: modal.minY)
    }

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("外观").font(.system(size: 9, weight: .bold))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<4) { index in
                    HStack {
                        Capsule().fill(Color(.tertiarySystemFill)).frame(width: 46, height: 6)
                        Spacer()
                        Capsule().fill(Color(.tertiarySystemFill)).frame(width: index == 3 ? 18 : 40, height: 9)
                    }
                }
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 8))
        }
        .transition(.opacity)
    }

    private var remotePane: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("远程控制").font(.system(size: 9, weight: .bold))
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("远程控制").font(.system(size: 7.5, weight: .semibold))
                        Text("开启后可用其他设备控制本机").font(.system(size: 6)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Capsule()
                        .fill(toggleOn ? Palette.kimi : Color(.systemGray4))
                        .frame(width: 22, height: 13)
                        .overlay(alignment: toggleOn ? .trailing : .leading) {
                            Circle().fill(.white).padding(1.5)
                        }
                }
                MoonIcon("mc-qr-code", size: 46)
                    .foregroundStyle(toggleOn ? Color.primary : Color(.tertiaryLabel))
                    .padding(6)
                    .background(Color(.systemBackground), in: .rect(cornerRadius: 6))
                Text(toggleOn ? "● 在线" : "未开启")
                    .font(.system(size: 6.5, weight: .medium))
                    .foregroundStyle(toggleOn ? Color.green : Color.secondary)
            }
            .padding(10)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 8))
        }
        .transition(.opacity)
    }

    // MARK: - 播放

    private func play() async {
        do {
            while true {
                try await step { cursor = Self.gear }
                try await click { settingsShown = true }
                try await step { cursor = Self.remoteRow }
                try await click { pane = .remote }
                try await step { cursor = Self.toggle }
                try await click { toggleOn = true }
                try await Task.sleep(for: .seconds(2.2))
                withAnimation(.easeOut(duration: 0.3)) { visible = false }
                try await Task.sleep(for: .milliseconds(350))
                cursor = Self.restPoint
                settingsShown = false
                pane = .general
                toggleOn = false
                withAnimation(.easeIn(duration: 0.3)) { visible = true }
                try await Task.sleep(for: .milliseconds(500))
            }
        } catch {}
    }

    /// 停一拍，光标移到下一个目标。
    private func step(move: () -> Void) async throws {
        try await Task.sleep(for: .milliseconds(500))
        if reduceMotion { move() } else { withAnimation(.easeInOut(duration: 0.8), move) }
        try await Task.sleep(for: .milliseconds(950))
    }

    private func click(then change: () -> Void) async throws {
        withAnimation(.easeIn(duration: 0.08)) { pressing = true }
        rippleAt = cursor
        if !reduceMotion { ripples += 1 }
        try await Task.sleep(for: .milliseconds(120))
        withAnimation(.easeOut(duration: 0.12)) { pressing = false }
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3), change)
        try await Task.sleep(for: .milliseconds(800))
    }
}

#Preview {
    DesktopRemoteDemo().padding(28)
}
