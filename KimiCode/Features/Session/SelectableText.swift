import SwiftUI
import UIKit

// 正文原地选择：长按选词、拖两端手柄调整范围，全部是 UITextView 自带的行为，不加自定义手势。
//
// iOS 上 SwiftUI `Text` 的 `.textSelection(.enabled)` 长按只能拷贝整段，选不了一部分，所以正文改用
// 不可编辑的 UITextView。连续的段落 / 标题 / 列表排进同一个 UITextView，可以跨段连着选；
// 代码块、表格、引用、分隔线各自独立，选区到它们就停（代码块有复制按钮，表格长按弹系统菜单拷贝）。

/// 可选中的富文本。内容没变不重排，尺寸按宽度缓存。
struct SelectableText: UIViewRepresentable {
    let content: RichText
    /// 宽度贴着文字（用户气泡）；否则占满给的宽度。
    var hugsWidth = false
    /// 最多显示几行，超出省略；0 = 不限。
    var lineLimit = 0

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SelectableTextView {
        let view = SelectableTextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        view.linkTextAttributes = [.foregroundColor: Palette.uiKimi]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: SelectableTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.addToComposer = context.environment.addToComposer
        let colorScheme = context.environment.colorScheme
        let key = Coordinator.Key(content: content, dynamicTypeSize: context.environment.dynamicTypeSize, colorScheme: colorScheme)
        if coordinator.key != key {
            coordinator.key = key
            coordinator.sizes = [:]
            let selection = view.selectedRange
            // 公式是画好的图片，颜色得按这时的深浅色定（换主题时 key 变了会重排）。
            let traits = view.traitCollection.modifyingTraits { $0.userInterfaceStyle = colorScheme == .dark ? .dark : .light }
            view.attributedText = content.attributedString(traits: traits)
            // 流式输出只往后追加：正在选的范围还在就留着。
            if selection.length > 0, NSMaxRange(selection) <= view.attributedText.length {
                view.selectedRange = selection
            }
        }
        if view.textContainer.maximumNumberOfLines != lineLimit {
            view.textContainer.maximumNumberOfLines = lineLimit
            view.textContainer.lineBreakMode = lineLimit > 0 ? .byTruncatingTail : .byWordWrapping
            coordinator.sizes = [:]
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SelectableTextView, context: Context) -> CGSize? {
        // 没给宽度（问理想尺寸）时按一行排开，和 `Text` 一样。
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 10_000
        let hug = hugsWidth || proposal.width == nil
        let key = Coordinator.SizeKey(width: width, hug: hug)
        if let size = context.coordinator.sizes[key] { return size }

        var measureWidth = width
        if hug {
            let used = uiView.attributedText.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).width
            // 多留 1pt：TextKit 2 和 boundingRect 的小数差一点就会多折一行。
            measureWidth = min(width, ceil(used) + 1)
        }
        let fitted = uiView.sizeThatFits(CGSize(width: measureWidth, height: .greatestFiniteMagnitude))
        let size = CGSize(width: measureWidth, height: ceil(fitted.height))
        context.coordinator.sizes[key] = size
        return size
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        struct Key: Equatable {
            let content: RichText
            let dynamicTypeSize: DynamicTypeSize
            let colorScheme: ColorScheme
        }

        struct SizeKey: Hashable {
            let width: CGFloat
            let hug: Bool
        }

        var key: Key?
        var sizes: [SizeKey: CGSize] = [:]
        var addToComposer: ((String) -> Void)?

        /// 长按菜单：拷贝 → 添加到会话框 → 搜索网页 排最前，「查询」去掉，其余照系统的。
        /// 没有输入框（拿不到回调）时原样不动。
        /// 自定义项不能塞进系统的 lookup 组（塞进去不显示），所以把要排前面的几项拎出来单放。
        /// 模拟器里没有「搜索网页」，选择器名没法实测，按选择器和标题两样认。
        func textView(
            _ textView: UITextView,
            editMenuForTextIn range: NSRange,
            suggestedActions: [UIMenuElement]
        ) -> UIMenu? {
            guard let addToComposer, range.length > 0, NSMaxRange(range) <= textView.attributedText.length else { return nil }
            let text = textView.attributedText.attributedSubstring(from: range).stringWithMathSource
            let add = UIAction(title: "添加到会话框", image: UIImage(systemName: "text.badge.plus")) { [weak textView] _ in
                addToComposer(text)
                _ = textView?.resignFirstResponder()
            }
            var copy: UICommand?
            var searchWeb: UICommand?
            let rest = Self.filter(suggestedActions) { command in
                let name = NSStringFromSelector(command.action)
                if command.action == #selector(UIResponderStandardEditActions.copy(_:)) {
                    copy = command
                } else if name.localizedCaseInsensitiveContains("searchWeb")
                            || ["搜索网页", "Search Web"].contains(command.title) {
                    searchWeb = command
                } else if name != "_define:" {
                    return true
                }
                return false
            }
            let front: [UIMenuElement] = [copy, add, searchWeb].compactMap { $0 }
            return UIMenu(children: [UIMenu(options: .displayInline, children: front)] + rest)
        }

        /// 逐层过滤系统菜单里的命令（「查询」「搜索网页」都嵌在子菜单里）。
        private static func filter(_ elements: [UIMenuElement], keep: (UICommand) -> Bool) -> [UIMenuElement] {
            elements.compactMap { element in
                if let command = element as? UICommand {
                    return keep(command) ? command : nil
                }
                if let menu = element as? UIMenu {
                    return menu.replacingChildren(filter(menu.children, keep: keep))
                }
                return element
            }
        }
    }
}

extension EnvironmentValues {
    /// 正文长按菜单「添加到会话框」：把选中的字放进输入框。
    @Entry var addToComposer: ((String) -> Void)?
}

final class SelectableTextView: UITextView {
    /// 正在选字的那一个。有选区时侧栏的横滑手势让路，不抢拖手柄的手指（见 `MainView`）。
    private(set) static weak var selecting: SelectableTextView?

    static var isSelecting: Bool {
        guard let view = selecting else { return false }
        return view.isFirstResponder && view.selectedRange.length > 0
    }

    /// 对话页「点空白收起键盘」用：这一下点在选中的字或两端手柄上就不处理，交给文本自己（轻碰手柄不该把选区清掉）。
    /// 点在别处（哪怕是同一段文字的其他地方）照常收起、取消选择。
    static func ownsTap(atGlobal point: CGPoint) -> Bool {
        guard let view = selecting, view.isFirstResponder, view.window != nil,
              let range = view.selectedTextRange, !range.isEmpty else { return false }
        let rects = view.selectionRects(for: range).map(\.rect).filter { !$0.isEmpty && $0.width.isFinite }
        guard let first = rects.first else { return false }
        let selection = rects.dropFirst().reduce(first) { $0.union($1) }
        // 手柄画在选区两端外面一点，留 24pt 余量。
        return view.convert(selection, to: nil).insetBy(dx: -24, dy: -24).contains(point)
    }

    /// 拷贝时行内公式换回 `$源码$`，不然只拷到一个占位符。
    override func copy(_ sender: Any?) {
        let range = selectedRange
        guard range.length > 0, NSMaxRange(range) <= attributedText.length else { return super.copy(sender) }
        UIPasteboard.general.string = attributedText.attributedSubstring(from: range).stringWithMathSource
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { Self.selecting = self }
        return became
    }

    /// 点别处取消选择：高亮和手柄系统在失去第一响应者时自己就藏了，菜单也自己缩回去。
    /// 这时不能马上改选区 —— 菜单正往选区那里缩，选区一动它就跟着滑走。等动画完了再把藏着的旧选区清掉。
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            if Self.selecting === self { Self.selecting = nil }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.isFirstResponder, self.selectedRange.length > 0 else { return }
                self.selectedRange = NSRange(location: self.selectedRange.location, length: 0)
            }
        }
        return resigned
    }
}

// MARK: - 富文本

/// 交给 `SelectableText` 排的内容。Equatable：内容不变就不重排。
enum RichText: Equatable {
    /// 连续的 Markdown 块（段落 / 标题 / 列表）。
    case markdown([MarkdownBlock], tone: TextTone)
    case plain(String, tone: TextTone, lineSpacing: CGFloat)

    /// `traits`：按它的深浅色画行内公式。
    func attributedString(traits: UITraitCollection = .current) -> NSAttributedString {
        switch self {
        case let .markdown(blocks, tone):
            let result = NSMutableAttributedString()
            for block in blocks {
                guard let segment = Self.markdown(block, tone: tone, traits: traits) else { continue }
                if result.length > 0 {
                    // 换行符跟着上一块的样式，段间距才算在上一块上。
                    let attributes = result.attributes(at: result.length - 1, effectiveRange: nil)
                    result.append(NSAttributedString(string: "\n", attributes: attributes))
                }
                result.append(segment)
            }
            Self.trimTrailingSpacing(result)
            return result
        case let .plain(text, tone, lineSpacing):
            let result = NSMutableAttributedString(
                string: text,
                attributes: [.font: tone.font, .foregroundColor: tone.color]
            )
            Self.applyParagraphs(result, lineSpacing: lineSpacing, spacingAfter: 0)
            return result
        }
    }

    /// 和 `MarkdownText` 里各块的 SwiftUI 样式对应：字号、行距、块间距 8。
    private static func markdown(_ block: MarkdownBlock, tone: TextTone, traits: UITraitCollection) -> NSAttributedString? {
        let body = tone.font
        func inline(_ text: String, font: UIFont, color: UIColor) -> NSMutableAttributedString {
            Self.inline(text, font: font, color: color, traits: traits)
        }
        switch block {
        case let .paragraph(text):
            let result = inline(text, font: body, color: tone.color)
            applyParagraphs(result, lineSpacing: 4, spacingAfter: 8)
            return result
        case let .heading(level, text):
            let font = level <= 1 ? semibold(.title3) : level == 2 ? .preferredFont(forTextStyle: .headline) : semibold(.subheadline)
            let result = inline(text, font: font, color: tone.color)
            applyParagraphs(result, lineSpacing: 0, spacingBefore: 4, spacingAfter: 8)
            return result
        case let .list(items, ordered):
            let result = NSMutableAttributedString()
            let widest = ordered ? "\(items.count)." : "•"
            let markerWidth = ceil((widest as NSString).size(withAttributes: [.font: body]).width) + 6
            for (index, item) in items.enumerated() {
                let line = NSMutableAttributedString(
                    string: (ordered ? "\(index + 1)." : "•") + "\t",
                    attributes: [.font: body, .foregroundColor: UIColor.secondaryLabel]
                )
                line.append(inline(item.text, font: body, color: tone.color))
                let indent = CGFloat(item.indent) * 16
                applyParagraphs(
                    line, lineSpacing: 4,
                    spacingAfter: index == items.count - 1 ? 8 : 4,
                    firstLineIndent: indent, headIndent: indent + markerWidth
                )
                if index < items.count - 1 {
                    line.append(NSAttributedString(string: "\n", attributes: line.attributes(at: line.length - 1, effectiveRange: nil)))
                }
                result.append(line)
            }
            return result
        case .quote, .code, .math, .table, .rule:
            // 这几种在 `MarkdownText` 里单独排，不进连续的选区。
            return nil
        }
    }

    /// 行内 Markdown（粗体 / 斜体 / 行内代码 / 删除线 / 链接），对应 `MarkdownText.inline`；
    /// 行内公式先换成占位符，解析完再换成 `MathAttachment`。
    private static func inline(_ text: String, font: UIFont, color: UIColor, traits: UITraitCollection) -> NSMutableAttributedString {
        let (masked, formulas) = MathSyntax.mask(text)
        let result = inlineMarkdown(masked, font: font, color: color)
        guard !formulas.isEmpty else { return result }
        let resolved = color.resolvedColor(with: traits)
        var next = formulas.startIndex
        var location = 0
        let placeholder = String(MathSyntax.placeholder) as NSString
        while next < formulas.endIndex {
            let found = (result.string as NSString).range(of: placeholder as String, range: NSRange(location: location, length: result.length - location))
            guard found.location != NSNotFound else { break }
            let formula = formulas[next]
            let attributes = result.attributes(at: found.location, effectiveRange: nil)
            let runFont = attributes[.font] as? UIFont ?? font
            let replacement = NSMutableAttributedString(
                attributedString: MathAttachment.string(for: formula, font: runFont, color: resolved)
                    ?? NSAttributedString(string: formula.source)
            )
            replacement.addAttributes(attributes.filter { $0.key != .attachment }, range: NSRange(location: 0, length: replacement.length))
            result.replaceCharacters(in: found, with: replacement)
            location = found.location + replacement.length
            next += 1
        }
        return result
    }

    private static func inlineMarkdown(_ text: String, font: UIFont, color: UIColor) -> NSMutableAttributedString {
        let parsed = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(text)
        let code = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .callout).pointSize, weight: .regular)
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if intent.contains(.code) {
                attributes[.font] = code
                attributes[.foregroundColor] = Palette.uiKimi
                attributes[.backgroundColor] = Palette.uiFill
            } else {
                var traits: UIFontDescriptor.SymbolicTraits = []
                if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                if !traits.isEmpty,
                   let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits)) {
                    attributes[.font] = UIFont(descriptor: descriptor, size: 0)
                }
            }
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
            }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }

    private static func semibold(_ style: UIFont.TextStyle) -> UIFont {
        .systemFont(ofSize: UIFont.preferredFont(forTextStyle: style).pointSize, weight: .semibold)
    }

    /// 按段落设样式：段前 / 段后距只加在这一块的第一段 / 最后一段，块内的换行只有行距。
    private static func applyParagraphs(
        _ text: NSMutableAttributedString,
        lineSpacing: CGFloat,
        spacingBefore: CGFloat = 0,
        spacingAfter: CGFloat,
        firstLineIndent: CGFloat = 0,
        headIndent: CGFloat = 0
    ) {
        let ranges = paragraphRanges(text)
        for (index, range) in ranges.enumerated() {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = lineSpacing
            style.paragraphSpacingBefore = index == 0 ? spacingBefore : 0
            style.paragraphSpacing = index == ranges.count - 1 ? spacingAfter : 0
            style.firstLineHeadIndent = index == 0 ? firstLineIndent : headIndent
            style.headIndent = headIndent
            if headIndent > firstLineIndent {
                style.tabStops = [NSTextTab(textAlignment: .natural, location: headIndent)]
                style.defaultTabInterval = headIndent
            }
            text.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }

    /// 最后一段不要段后距，否则底下多出一截空白。
    private static func trimTrailingSpacing(_ text: NSMutableAttributedString) {
        guard let last = paragraphRanges(text).last,
              let style = text.attribute(.paragraphStyle, at: last.location, effectiveRange: nil) as? NSParagraphStyle,
              let trimmed = style.mutableCopy() as? NSMutableParagraphStyle
        else { return }
        trimmed.paragraphSpacing = 0
        text.addAttribute(.paragraphStyle, value: trimmed, range: last)
    }

    private static func paragraphRanges(_ text: NSAttributedString) -> [NSRange] {
        let string = text.string as NSString
        var ranges: [NSRange] = []
        string.enumerateSubstrings(
            in: NSRange(location: 0, length: string.length),
            options: [.byParagraphs, .substringNotRequired]
        ) { _, _, enclosing, _ in
            ranges.append(enclosing)
        }
        return ranges
    }
}

/// 基础字号 + 颜色（对应 SwiftUI 的 `.font` / `.foregroundStyle`，UIKit 里读不到环境，得显式给）。
struct TextTone: Equatable {
    var textStyle: UIFont.TextStyle = .body
    var secondary = false
    var weight: UIFont.Weight = .regular

    static let body = TextTone()

    var font: UIFont {
        let base = UIFont.preferredFont(forTextStyle: textStyle)
        return weight == .regular ? base : .systemFont(ofSize: base.pointSize, weight: weight)
    }

    var color: UIColor { secondary ? .secondaryLabel : .label }
}
