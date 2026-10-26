import RegexBuilder
import SwiftMath
import SwiftUI
import Synchronization
import UIKit

// LaTeX 公式：用 SwiftMath 原生排版成图片。
//
// 行内公式（`$…$`、`\(…\)`）在正文 UITextView 里是 `MathAttachment`，跟着文字一起换行、可选中；
// 拷贝时换回 `$源码$`。块级公式（`$$…$$`、`\[…\]` 独占几行）由 `MarkdownBlock.math` 单独排，见 `MathBlockView`。
// 排不出来（语法不支持、流式输出还没写完）就原样显示源码。

enum MathSyntax {
    struct Formula: Equatable {
        /// 定界符里面的 LaTeX。
        let latex: String
        /// 连定界符在内的原文，排版失败时原样放回。
        let source: String
    }

    enum Segment: Equatable {
        case text(String)
        case math(Formula)
    }

    /// 占位符：先把公式换成它再交给 Markdown 解析，解析完再换回附件，公式里的 `*` `_` 才不会被当成强调。
    static let placeholder: Character = "\u{FFFC}"

    /// 切出行内公式。行内代码原样跳过；`\$` 是转义的美元符；
    /// `$…$` 开头紧跟空白、结尾紧挨空白或后面跟数字（`$5 和 $10`）的不算公式。
    static func segments(_ text: String) -> [Segment] {
        guard text.contains("$") || text.contains("\\(") || text.contains("\\[") else { return [.text(text)] }
        let chars = Array(text)
        var segments: [Segment] = []
        var buffer = ""
        var index = 0

        func emit(_ latex: ArraySlice<Character>, from start: Int, to end: Int) {
            if !buffer.isEmpty { segments.append(.text(buffer)) }
            buffer = ""
            segments.append(.math(Formula(latex: String(latex).trimmingCharacters(in: .whitespacesAndNewlines),
                                          source: String(chars[start..<end]))))
        }

        while index < chars.count {
            let char = chars[index]
            if char == "`" {
                // 行内代码：同样长度的反引号收尾。
                let run = chars[index...].prefix { $0 == "`" }.count
                let fence = String(repeating: "`", count: run)
                if let close = find(fence, in: chars, from: index + run, escapes: false) {
                    buffer += String(chars[index..<(close + run)])
                    index = close + run
                } else {
                    buffer += fence
                    index += run
                }
                continue
            }
            if char == "\\", index + 1 < chars.count {
                let next = chars[index + 1]
                if next == "(" || next == "[", let close = find(next == "(" ? "\\)" : "\\]", in: chars, from: index + 2) {
                    emit(chars[(index + 2)..<close], from: index, to: close + 2)
                    index = close + 2
                } else {
                    buffer += String(chars[index...(index + 1)])
                    index += 2
                }
                continue
            }
            if char == "$" {
                if index + 1 < chars.count, chars[index + 1] == "$" {
                    if let close = find("$$", in: chars, from: index + 2), close > index + 2 {
                        emit(chars[(index + 2)..<close], from: index, to: close + 2)
                        index = close + 2
                    } else {
                        buffer += "$$"
                        index += 2
                    }
                    continue
                }
                if let close = closingDollar(chars, from: index) {
                    emit(chars[(index + 1)..<close], from: index, to: close + 1)
                    index = close + 1
                    continue
                }
            }
            buffer.append(char)
            index += 1
        }
        if !buffer.isEmpty { segments.append(.text(buffer)) }
        return segments
    }

    /// 公式换成占位符后的文本，和按顺序排好的公式。
    static func mask(_ text: String) -> (text: String, formulas: [Formula]) {
        var masked = ""
        var formulas: [Formula] = []
        for segment in segments(text.replacingOccurrences(of: String(placeholder), with: "")) {
            switch segment {
            case let .text(part): masked += part
            case let .math(formula):
                masked.append(placeholder)
                formulas.append(formula)
            }
        }
        return (masked, formulas)
    }

    /// `escapes`：跳过反斜杠转义（行内代码里没有转义）。
    private static func find(_ needle: String, in chars: [Character], from start: Int, escapes: Bool = true) -> Int? {
        let needle = Array(needle)
        guard start <= chars.count - needle.count else { return nil }
        var index = start
        while index <= chars.count - needle.count {
            if escapes, chars[index] == "\\", needle.first != "\\" {
                index += 2
                continue
            }
            if Array(chars[index..<(index + needle.count)]) == needle { return index }
            index += 1
        }
        return nil
    }

    private static func closingDollar(_ chars: [Character], from open: Int) -> Int? {
        let start = open + 1
        guard start < chars.count, !chars[start].isWhitespace else { return nil }
        var index = start
        while index < chars.count {
            if chars[index] == "\\" {
                index += 2
                continue
            }
            if chars[index] == "\n", index + 1 < chars.count, chars[index + 1] == "\n" { return nil }
            if chars[index] == "$" {
                guard !chars[index - 1].isWhitespace else { return nil }
                if index + 1 < chars.count, chars[index + 1].isNumber { return nil }
                return index
            }
            index += 1
        }
        return nil
    }
}

/// SwiftMath 排版 + 缓存。流式输出每来一段就整段重排，同一个公式不重复画。
enum MathRenderer {
    struct Rendered: Sendable {
        let image: UIImage
        /// 基线以上 / 以下的高度，行内附件靠它对齐基线。
        let ascent: CGFloat
        let descent: CGFloat
    }

    private struct Key: Hashable {
        let latex: String
        let fontSize: CGFloat
        let display: Bool
        let color: UInt32
    }

    private static let cache = Mutex<[Key: Rendered]>([:])
    /// 排不出来的也记下，免得每次重排都再试一遍。
    private static let failures = Mutex<Set<Key>>([])

    /// SwiftMath 的字形比系统字体显小，放大一点和正文齐平。
    static let scale: CGFloat = 1.1

    /// `color` 要先按当前深浅色解析好（动态色在这里拿不到界面风格）。
    static func render(_ latex: String, fontSize: CGFloat, color: UIColor, display: Bool) -> Rendered? {
        guard !latex.isEmpty else { return nil }
        let key = Key(latex: latex, fontSize: fontSize, display: display, color: color.rgba)
        if let hit = cache.withLock({ $0[key] }) { return hit }
        if failures.withLock({ $0.contains(key) }) { return nil }

        var math = MathImage(latex: normalized(latex), fontSize: fontSize * scale, textColor: color,
                             labelMode: display ? .display : .text, textAlignment: .left)
        let (error, image, layout) = math.asImage()
        guard error == nil, let image, let layout, image.size.width > 0 else {
            failures.withLock { _ = $0.insert(key) }
            return nil
        }
        let rendered = Rendered(image: image, ascent: layout.ascent, descent: layout.descent)
        cache.withLock { cache in
            if cache.count > 500 { cache.removeAll() }
            cache[key] = rendered
        }
        return rendered
    }

    /// 模型常写、SwiftMath 1.7.3 不认的写法换成它认的（逐条实测过）：
    /// `\dfrac` → `\frac`，`\lVert` → `\|`，`\boxed{x}` → `x`，`\tag` / `\label` / 颜色去掉，`equation` 去壳，
    /// `align` / `gather` → `aligned`，`\overset{a}{b}` → `{b}^{a}` 等。
    static func normalized(_ latex: String) -> String {
        guard latex.contains("\\") else { return latex }
        var text = latex
        for (old, new) in [("\\lVert", "\\|"), ("\\rVert", "\\|"), ("\\lvert", "|"), ("\\rvert", "|"),
                           ("\\nonumber", ""), ("\\notag", ""), ("\\xrightarrow", "\\rightarrow^"),
                           ("\\xleftarrow", "\\leftarrow^"), ("\\hline", ""),
                           ("{smallmatrix}", "{matrix}")] {
            text = text.replacingOccurrences(of: old, with: new)
        }
        // 整个命令名替换（后面不能再接字母，免得 `\R` 碰到 `\Rightarrow`）。
        for (old, new) in [("dfrac", "\\frac"), ("tfrac", "\\frac"), ("cfrac", "\\frac"),
                           ("dbinom", "\\binom"), ("tbinom", "\\binom"), ("operatorname", "\\mathrm"),
                           ("iiint", "\\int\\int\\int"), ("iint", "\\int\\int"), ("oint", "\\int"),
                           ("varnothing", "\\emptyset"), ("dots", "\\ldots"),
                           ("implies", "\\Rightarrow"), ("impliedby", "\\Leftarrow"), ("bmod", "\\;\\mathrm{mod}\\;"),
                           ("R", "\\mathbb{R}"), ("N", "\\mathbb{N}"), ("Z", "\\mathbb{Z}"),
                           ("Q", "\\mathbb{Q}"), ("C", "\\mathbb{C}"),
                           ("big", ""), ("Big", ""), ("bigg", ""), ("Bigg", ""),
                           ("bigl", ""), ("bigr", ""), ("Bigl", ""), ("Bigr", ""),
                           ("biggl", ""), ("biggr", ""), ("Biggl", ""), ("Biggr", "")] {
            text = text.replacing(Regex { "\\" + old; NegativeLookahead { .word } }, with: new)
        }
        text = text.replacing(/\\pmod\{([^{}]*)\}/) { "\\;(\\mathrm{mod}\\;\($0.1))" }
        text = text.replacing(/\\(?:overset|stackrel)\{([^{}]*)\}\{([^{}]*)\}/) { "{\($0.2)}^{\($0.1)}" }
        text = text.replacing(/\\underset\{([^{}]*)\}\{([^{}]*)\}/) { "{\($0.2)}_{\($0.1)}" }
        text = text.replacing(/\\(?:cancel|mathring)(?=\{)/, with: "")
        text = text.replacing(/\\(?:tag|label)\*?\{[^{}]*\}/, with: "")
        text = text.replacing(/\\textcolor\{[^{}]*\}/, with: "")
        text = text.replacing(/\\color\{[^{}]*\}/, with: "")
        text = text.replacing(/\\(?:boxed|fbox)(?=\{)/, with: "")
        text = text.replacing(/\\(begin|end)\{equation\*?\}/, with: "")
        text = text.replacing(/\\(begin|end)\{(?:align|gather|gathered|multline)\*?\}/) { "\\\($0.1){aligned}" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 正文里的行内公式。记着源码，拷贝 / 添加到会话框时换回去。
final class MathAttachment: NSTextAttachment {
    /// 连定界符的原文，拷贝选中文字时用。
    var source = ""
    /// 不带定界符的 LaTeX，长按「拷贝公式」用（和块级公式一致）。
    var latex = ""

    /// 排成附件；排不出来返回 nil，调用方放回源码。
    static func string(for formula: MathSyntax.Formula, font: UIFont, color: UIColor) -> NSAttributedString? {
        guard let rendered = MathRenderer.render(formula.latex, fontSize: font.pointSize, color: color, display: false) else {
            return nil
        }
        let attachment = MathAttachment()
        attachment.source = formula.source
        attachment.latex = formula.latex
        attachment.image = rendered.image
        attachment.bounds = CGRect(
            x: 0, y: -rendered.descent,
            width: rendered.image.size.width, height: rendered.image.size.height
        )
        return NSAttributedString(attachment: attachment)
    }
}

extension NSAttributedString {
    /// 纯文本，行内公式换回 `$源码$`。
    var stringWithMathSource: String {
        let result = NSMutableString(string: string)
        enumerateAttribute(.attachment, in: NSRange(location: 0, length: length), options: .reverse) { value, range, _ in
            if let math = value as? MathAttachment {
                result.replaceCharacters(in: range, with: math.source)
            }
        }
        return result as String
    }
}

/// 独占几行的块级公式：放得下居中，太宽就横向滚动。长按拷贝源码。
struct MathBlockView: View {
    let latex: String

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        let fontSize = UIFont.preferredFont(forTextStyle: .body).pointSize
        if let rendered = MathRenderer.render(latex, fontSize: fontSize,
                                              color: UIColor.label.resolvedColor(with: traits), display: true) {
            let image = Image(uiImage: rendered.image)
            ViewThatFits(in: .horizontal) {
                image.frame(maxWidth: .infinity)
                ScrollView(.horizontal, showsIndicators: false) { image }
            }
            .padding(.vertical, 4)
            .accessibilityLabel(latex)
            .contentShape(.rect)
            .contextMenu {
                Button("拷贝公式", systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = latex
                }
            }
        } else {
            // 语法不支持，或者流式输出时还没写完：先显示源码。
            Text(latex)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension MarkdownText {
    /// 表格格子这类 SwiftUI `Text` 里的行内 Markdown + 公式（公式作为图片嵌进文字）。
    static func inlineText(_ text: String, fontSize: CGFloat, colorScheme: ColorScheme) -> Text {
        let segments = MathSyntax.segments(text)
        guard segments.contains(where: { if case .math = $0 { true } else { false } }) else {
            return Text(inline(text))
        }
        let color = UIColor.label.resolvedColor(with: UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light))
        var result = Text(verbatim: "")
        for segment in segments {
            switch segment {
            case let .text(part):
                result = Text("\(result)\(Text(inline(part)))")
            case let .math(formula):
                if let rendered = MathRenderer.render(formula.latex, fontSize: fontSize, color: color, display: false) {
                    result = Text("\(result)\(Text(Image(uiImage: rendered.image)).baselineOffset(-rendered.descent))")
                } else {
                    result = Text("\(result)\(Text(verbatim: formula.source))")
                }
            }
        }
        return result
    }
}

private extension UIColor {
    var rgba: UInt32 {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func byte(_ value: CGFloat) -> UInt32 { UInt32(max(0, min(1, value)) * 255) }
        return byte(red) << 24 | byte(green) << 16 | byte(blue) << 8 | byte(alpha)
    }
}
