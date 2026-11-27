import SwiftUI

/// 渲染 `Assets.xcassets/Icons/` 中的统一单色矢量 SVG 模板图标。
/// 所有资源均配置为 `template-rendering-intent: template` + `preserves-vector-representation: true`，
/// 自动跟随 SwiftUI `.foregroundStyle`、`.tint` 与浅/深色外观。
struct MoonIcon: View {
    let name: String
    var size: CGFloat = 18

    init(_ name: String, size: CGFloat = 18) {
        self.name = name
        self.size = size
    }

    var body: some View {
        Image(name)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size, height: size)
    }
}

/// 思考中月食动效：满月 → 半月 → 月全食 → 半月 → 满月无缝循环（2.72s 周期），
/// 与 `assets/icons/thinking-moon.gif` 保持完全一致的几何与节奏，并原生支持 `foregroundStyle` 与减弱动态效果。
struct ThinkingMoonView: View {
    let animating: Bool
    var size: CGFloat = 16

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if animating && !reduceMotion {
            TimelineView(.animation) { context in
                let period = 2.72
                let t = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: period) / period
                let phase = t < 0 ? t + 1 : t
                lunarCanvas(t: phase)
            }
            .frame(width: size, height: size)
        } else {
            MoonIcon("mc-thinking", size: size)
        }
    }

    private func lunarCanvas(t: Double) -> some View {
        Canvas { ctx, canvasSize in
            let side = min(canvasSize.width, canvasSize.height)
            let sc = side / 24.0
            let ox = (canvasSize.width - side) / 2
            let oy = (canvasSize.height - side) / 2
            let strokeStyle = StrokeStyle(lineWidth: 1.8 * sc, lineCap: .round, lineJoin: .round)

            func circlePath(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> Path {
                let d = r * 2 * sc
                return Path(ellipseIn: CGRect(x: ox + (cx - r) * sc, y: oy + (cy - r) * sc, width: d, height: d))
            }

            // 68 帧时间轴：8 帧满月停留 → 24 帧亏食 → 8 帧月全食停留 → 24 帧复圆 → 4 帧满月落定
            let f = t * 68.0
            let rClip: CGFloat = 8.2
            let rShadow: CGFloat = 13.0

            // 1. 环形山（与 mc-thinking 静态 SVG 完全一致）
            ctx.stroke(circlePath(9.2, 9.2, 2.2), with: .foreground, style: strokeStyle)
            ctx.stroke(circlePath(15.4, 13.8, 1.5), with: .foreground, style: strokeStyle)
            ctx.fill(circlePath(10.2, 15.8, 0.9), with: .foreground)

            // 2. 月食阴影（始终紧贴月球内沿，不向内塌缩）
            if f >= 8 && f < 64 {
                var clipped = ctx
                clipped.clip(to: circlePath(12, 12, rClip))
                if f >= 32 && f < 40 {
                    clipped.fill(circlePath(12, 12, rClip), with: .foreground)
                } else {
                    let waning = f < 32
                    let rawU = waning ? (f - 8) / 24.0 : (f - 40) / 24.0
                    let u = max(0, min(1, rawU))
                    let ue = u * u * (3 - 2 * u)
                    let sx = (waning ? 12 + rShadow : 12 - rShadow) + rClip * CGFloat(1 - 2 * ue)
                    clipped.fill(circlePath(sx, 12, rShadow), with: .foreground)
                }
            }

            // 3. 外圈月轮
            ctx.stroke(circlePath(12, 12, 9.0), with: .foreground, style: strokeStyle)
        }
    }
}
