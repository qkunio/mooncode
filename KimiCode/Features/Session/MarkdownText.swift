import SwiftUI
import UIKit

/// 助手正文的 Markdown 渲染。
///
/// 块级（段落 / 标题 / 列表 / 引用 / 代码块 / 公式 / 表格 / 分隔线）自己切，行内（粗体 / 行内代码 /
/// 链接）交给 `AttributedString(markdown:)`，行内公式先抠出来再解析（见 `MathText.swift`）。流式输出时每次全量重排，只要切块是纯函数就不会闪。
///
/// 正文可以长按自由选择（见 `SelectableText`）：连续的段落 / 标题 / 列表排在同一个文本视图里，能跨段连着选；
/// 代码块、公式、表格、引用、分隔线把它们隔开，选区到这儿就停。
struct MarkdownText: View, Equatable {
    let text: String
    /// 正文的基础字号 / 颜色。可选文本是 UIKit 排的，读不到外面的 `.font` / `.foregroundStyle`。
    var tone: TextTone = .body
    /// 正在流式输出：对末尾未闭合的行内语法做柔化稳定，并推迟未闭合块级公式的 SwiftMath 渲染。
    var isStreaming = false

    var body: some View {
        let parsed = MarkdownBlock.parse(text)
        let stabilized = isStreaming ? StreamingMarkdown.stabilizeTail(parsed) : parsed
        let runs = Self.runs(stabilized)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(runs.enumerated()), id: \.offset) { index, run in
                MarkdownRunView(
                    run: run,
                    tone: tone,
                    isStreamingTail: isStreaming && index == runs.count - 1
                )
                .equatable()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    fileprivate enum Run: Equatable {
        /// 连续的段落 / 标题 / 列表。
        case prose([MarkdownBlock])
        case block(MarkdownBlock)
    }

    private static func runs(_ blocks: [MarkdownBlock]) -> [Run] {
        var runs: [Run] = []
        var prose: [MarkdownBlock] = []
        for block in blocks {
            switch block {
            case .paragraph, .heading, .list:
                prose.append(block)
            case .quote, .code, .math, .table, .rule:
                if !prose.isEmpty { runs.append(.prose(prose)) }
                prose = []
                runs.append(.block(block))
            }
        }
        if !prose.isEmpty { runs.append(.prose(prose)) }
        return runs
    }

    private struct MarkdownRunView: View, Equatable {
        let run: Run
        let tone: TextTone
        let isStreamingTail: Bool

        var body: some View {
            switch run {
            case let .prose(blocks):
                SelectableText(content: .markdown(blocks, tone: tone))
            case let .block(.quote(text)):
                HStack(spacing: 10) {
                    Rectangle().fill(Palette.line).frame(width: 3)
                    SelectableText(content: .markdown([.paragraph(text)], tone: TextTone(textStyle: tone.textStyle, secondary: true)))
                }
                .fixedSize(horizontal: false, vertical: true)
            case let .block(.code(language, code)):
                CodeBlockView(language: language, code: code).equatable()
            case let .block(.math(latex, closed)):
                MathBlockView(latex: latex, isPending: isStreamingTail && !closed).equatable()
            case let .block(.table(rows)):
                MarkdownTable(rows: rows).equatable()
            case .block(.rule):
                Rectangle().fill(Palette.line).frame(height: 0.5).padding(.vertical, 4)
            case .block:
                EmptyView()
            }
        }
    }

    /// 行内 Markdown。行内代码照官方：0.9 倍等宽、浅底、主题色。
    static func inline(_ text: String) -> AttributedString {
        var result = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(text)
        for run in result.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].font = .system(.callout, design: .monospaced)
            result[run.range].foregroundColor = Palette.kimi
            result[run.range].backgroundColor = Palette.fill
        }
        return result
    }
}

/// 流式输出期间对末尾未闭合的行内 Markdown 记号做轻量稳定，避免 `**` / `` ` `` / `~~` 闪烁及换行跳动。
/// 仅在 `isStreaming == true` 时用于最后一块文本，定稿后一律按原文渲染。
enum StreamingMarkdown {
    static func stabilizeTail(_ blocks: [MarkdownBlock]) -> [MarkdownBlock] {
        guard let last = blocks.last else { return blocks }
        var result = blocks
        switch last {
        case let .paragraph(text):
            result[result.count - 1] = .paragraph(stabilizeInline(text))
        case let .heading(level, text):
            result[result.count - 1] = .heading(level, stabilizeInline(text))
        case let .quote(text):
            result[result.count - 1] = .quote(stabilizeInline(text))
        case .list(var items, let ordered):
            if let lastItem = items.last {
                items[items.count - 1] = MarkdownBlock.ListItem(
                    indent: lastItem.indent,
                    text: stabilizeInline(lastItem.text)
                )
                result[result.count - 1] = .list(items, ordered: ordered)
            }
        case .code, .math, .table, .rule:
            break
        }
        return result
    }

    private enum InlineMarker {
        case bold(index: Int)
        case strike(index: Int)

        var delimiter: String {
            switch self {
            case .bold: "**"
            case .strike: "~~"
            }
        }

        var singleChar: Character {
            switch self {
            case .bold: "*"
            case .strike: "~"
            }
        }

        var openIndex: Int {
            switch self {
            case let .bold(i), let .strike(i): i
            }
        }
    }

    static func stabilizeInline(_ text: String) -> String {
        guard text.contains("`") || text.contains("*") || text.contains("~") else { return text }
        let chars = Array(text)
        var inCodeFence: Int? = nil
        var codeOpenIndex = 0
        var stack: [InlineMarker] = []
        var index = 0

        while index < chars.count {
            let char = chars[index]
            if char == "\\", inCodeFence == nil {
                index += 2
                continue
            }
            if char == "`" {
                var run = 0
                while index + run < chars.count, chars[index + run] == "`" { run += 1 }
                if let openRun = inCodeFence {
                    if run == openRun { inCodeFence = nil }
                } else {
                    inCodeFence = run
                    codeOpenIndex = index
                }
                index += run
                continue
            }
            if inCodeFence != nil {
                index += 1
                continue
            }
            // 仅跳过真正闭合的行内公式，避免把「$5 和 **粗体**」里的美元符号误当成未闭合公式。
            if char == "$" {
                if index + 1 < chars.count, chars[index + 1] == "$" {
                    if let close = findClosedDoubleDollar(in: chars, from: index + 2) {
                        index = close + 2
                        continue
                    }
                    index += 2
                    continue
                }
                if let close = findClosedSingleDollar(in: chars, from: index) {
                    index = close + 1
                    continue
                }
                index += 1
                continue
            }
            if char == "*", index + 1 < chars.count, chars[index + 1] == "*" {
                if let pos = stack.lastIndex(where: { if case .bold = $0 { true } else { false } }) {
                    stack.removeSubrange(pos...)
                } else if index + 2 == chars.count || !chars[index + 2].isWhitespace {
                    stack.append(.bold(index: index))
                }
                index += 2
                continue
            }
            if char == "~", index + 1 < chars.count, chars[index + 1] == "~" {
                if let pos = stack.lastIndex(where: { if case .strike = $0 { true } else { false } }) {
                    stack.removeSubrange(pos...)
                } else if index + 2 == chars.count || !chars[index + 2].isWhitespace {
                    stack.append(.strike(index: index))
                }
                index += 2
                continue
            }
            index += 1
        }

        if let openRun = inCodeFence {
            if codeOpenIndex + openRun == chars.count {
                return String(chars[..<codeOpenIndex])
            }
            return text + String(repeating: "`", count: openRun)
        }

        guard !stack.isEmpty else { return text }

        // 末尾刚吐出孤立的 `**` / `~~`（后面尚无内容）：先藏起裸记号。
        var trimEnd = chars.count
        while let last = stack.last, last.openIndex + 2 == trimEnd {
            trimEnd = last.openIndex
            stack.removeLast()
        }
        var result = trimEnd == chars.count ? text : String(chars[..<trimEnd])
        guard !stack.isEmpty else { return result }

        // CommonMark 不允许闭合的 `**`/`~~` 紧跟在空白后面：先把尾部空格挪到闭合记号之后。
        var trailingSpaces = ""
        while let last = result.last, last == " " || last == "\t" {
            trailingSpaces.insert(last, at: trailingSpaces.startIndex)
            result.removeLast()
        }
        guard !result.isEmpty else { return text }

        // 按 LIFO 栈逆序闭合嵌套记号；若已吐出半个闭合符（如 `**text*`）则只补后半个。
        for marker in stack.reversed() {
            if result.last == marker.singleChar {
                result.append(marker.singleChar)
            } else {
                result.append(marker.delimiter)
            }
        }
        return result + trailingSpaces
    }

    private static func findClosedDoubleDollar(in chars: [Character], from start: Int) -> Int? {
        var i = start
        while i + 1 < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "$", chars[i + 1] == "$" { return i }
            i += 1
        }
        return nil
    }

    private static func findClosedSingleDollar(in chars: [Character], from open: Int) -> Int? {
        let start = open + 1
        guard start < chars.count, !chars[start].isWhitespace else { return nil }
        var i = start
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "\n", i + 1 < chars.count, chars[i + 1] == "\n" { return nil }
            if chars[i] == "$" {
                guard !chars[i - 1].isWhitespace else { return nil }
                if i + 1 < chars.count, chars[i + 1].isNumber { return nil }
                return i
            }
            i += 1
        }
        return nil
    }
}

enum MarkdownBlock: Equatable {
    struct ListItem: Equatable {
        let indent: Int
        let text: String
    }

    case paragraph(String)
    case heading(Int, String)
    case list([ListItem], ordered: Bool)
    case quote(String)
    case code(language: String?, code: String)
    /// 独占几行的公式（`$$…$$` / `\[…\]`），里面是 LaTeX；`closed` 标明是否已收到收尾定界符。
    case math(String, closed: Bool = true)
    case table([[String]])
    case rule

    static func parse(_ source: String) -> [MarkdownBlock] {
        guard !source.isEmpty else { return [] }
        var blocks: [MarkdownBlock] = []
        var paragraph: [Substring] = []
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.count == 1 ? String(paragraph[0]) : paragraph.joined(separator: "\n")
            let text = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.paragraph(text)) }
            paragraph.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = trimSpaces(line)

            // 代码块：``` 或 ~~~，未闭合（流式中）就吃到结尾。
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = trimmed.prefix(3)
                let language = trimSpaces(trimmed.dropFirst(3))
                var code: [Substring] = []
                index += 1
                while index < lines.count, !trimSpaces(lines[index]).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(
                    language: language.isEmpty ? nil : String(language),
                    code: code.joined(separator: "\n")
                ))
                continue
            }

            // 块级公式：`$$` / `\[` 开头。同一行收尾且后面没别的字才算块，否则留给行内；
            // 跨行的吃到收尾那行，未闭合（流式中）就吃到结尾并标记 `closed: false`。
            if trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[") {
                let close = trimmed.hasPrefix("$$") ? "$$" : "\\]"
                let rest = trimmed.dropFirst(2)
                if let end = rest.range(of: close) {
                    if trimSpaces(rest[end.upperBound...]).isEmpty {
                        flushParagraph()
                        blocks.append(.math(String(trimSpaces(rest[..<end.lowerBound])), closed: true))
                        index += 1
                        continue
                    }
                } else {
                    flushParagraph()
                    var body: [Substring] = [rest]
                    var closed = false
                    index += 1
                    while index < lines.count {
                        let nextLine = lines[index]
                        index += 1
                        if let end = nextLine.range(of: close) {
                            body.append(nextLine[..<end.lowerBound])
                            closed = true
                            break
                        }
                        body.append(nextLine)
                    }
                    blocks.append(.math(
                        body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                        closed: closed
                    ))
                    continue
                }
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(.heading(heading.level, String(heading.text)))
                index += 1
                continue
            }

            if isHorizontalRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                index += 1
                continue
            }

            // 表格：| a | b | 下一行是 |---|---|
            if trimmed.first == "|", index + 1 < lines.count,
               isTableSeparator(trimSpaces(lines[index + 1])) {
                flushParagraph()
                var rows: [[String]] = [cells(trimmed)]
                index += 2
                while index < lines.count {
                    let rowTrimmed = trimSpaces(lines[index])
                    guard rowTrimmed.first == "|" else { break }
                    rows.append(cells(rowTrimmed))
                    index += 1
                }
                blocks.append(.table(rows))
                continue
            }

            if trimmed.first == ">" {
                flushParagraph()
                var quote: [Substring] = []
                while index < lines.count {
                    let qTrimmed = trimSpaces(lines[index])
                    guard qTrimmed.first == ">" else { break }
                    quote.append(trimSpaces(qTrimmed.dropFirst()))
                    index += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }

            if let item = listItem(line, trimmed: trimmed) {
                flushParagraph()
                var items: [ListItem] = [item.item]
                let ordered = item.ordered
                index += 1
                while index < lines.count {
                    let nextLine = lines[index]
                    let nextTrimmed = trimSpaces(nextLine)
                    if let next = listItem(nextLine, trimmed: nextTrimmed) {
                        items.append(next.item)
                        index += 1
                    } else if !nextTrimmed.isEmpty, nextLine.hasPrefix("  "), let last = items.popLast() {
                        // 续行：挂到上一项。
                        items.append(ListItem(indent: last.indent, text: last.text + "\n" + nextTrimmed))
                        index += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(items, ordered: ordered))
                continue
            }

            paragraph.append(line)
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func trimSpaces(_ text: Substring) -> Substring {
        var start = text.startIndex
        var end = text.endIndex
        while start < end, text[start] == " " || text[start] == "\t" || text[start] == "\r" {
            start = text.index(after: start)
        }
        while end > start {
            let prev = text.index(before: end)
            if text[prev] == " " || text[prev] == "\t" || text[prev] == "\r" {
                end = prev
            } else {
                break
            }
        }
        return text[start..<end]
    }

    private static func parseHeading(_ trimmed: Substring) -> (level: Int, text: Substring)? {
        guard trimmed.first == "#" else { return nil }
        var cursor = trimmed.startIndex
        var level = 0
        while cursor < trimmed.endIndex, trimmed[cursor] == "#" {
            level += 1
            if level > 6 { return nil }
            cursor = trimmed.index(after: cursor)
        }
        guard cursor < trimmed.endIndex, trimmed[cursor] == " " || trimmed[cursor] == "\t" else { return nil }
        while cursor < trimmed.endIndex, trimmed[cursor] == " " || trimmed[cursor] == "\t" {
            cursor = trimmed.index(after: cursor)
        }
        return (level, trimmed[cursor...])
    }

    private static func isHorizontalRule(_ trimmed: Substring) -> Bool {
        guard let marker = trimmed.first, marker == "*" || marker == "-" || marker == "_" else { return false }
        var count = 0
        for char in trimmed {
            if char == marker {
                count += 1
            } else if char != " " && char != "\t" {
                return false
            }
        }
        return count >= 3
    }

    private static func isTableSeparator(_ trimmed: Substring) -> Bool {
        guard !trimmed.isEmpty else { return false }
        var body = trimmed
        if body.first == "|" { body = body.dropFirst() }
        if body.last == "|" { body = body.dropLast() }
        guard !body.isEmpty else { return false }
        var sawCell = false
        for rawCell in body.split(separator: "|", omittingEmptySubsequences: false) {
            let cell = trimSpaces(rawCell)
            var slice = cell
            if slice.first == ":" { slice = slice.dropFirst() }
            if slice.last == ":" { slice = slice.dropLast() }
            guard slice.count >= 2, slice.allSatisfy({ $0 == "-" }) else { return false }
            sawCell = true
        }
        return sawCell
    }

    private static func listItem(_ line: Substring, trimmed: Substring) -> (item: ListItem, ordered: Bool)? {
        guard let first = trimmed.first else { return nil }
        let indent = line.prefix { $0 == " " }.count / 2
        if first == "-" || first == "*" || first == "+" {
            let rest = trimmed.dropFirst()
            guard let after = rest.first, after == " " || after == "\t" else { return nil }
            return (ListItem(indent: indent, text: String(trimSpaces(rest))), false)
        }
        if first.isASCII && first.isNumber {
            var cursor = trimmed.startIndex
            while cursor < trimmed.endIndex, trimmed[cursor].isASCII && trimmed[cursor].isNumber {
                cursor = trimmed.index(after: cursor)
            }
            guard cursor < trimmed.endIndex, trimmed[cursor] == "." || trimmed[cursor] == ")" else { return nil }
            let afterPunct = trimmed.index(after: cursor)
            guard afterPunct < trimmed.endIndex, trimmed[afterPunct] == " " || trimmed[afterPunct] == "\t" else { return nil }
            return (ListItem(indent: indent, text: String(trimSpaces(trimmed[afterPunct...]))), true)
        }
        return nil
    }

    private static func cells(_ row: Substring) -> [String] {
        var text = row
        if text.first == "|" { text = text.dropFirst() }
        if text.last == "|" { text = text.dropLast() }
        return text.split(separator: "|", omittingEmptySubsequences: false).map { String(trimSpaces($0)) }
    }
}

/// 代码块：顶部语言 + 复制，正文等宽、横向滚动。
struct CodeBlockView: View, Equatable {
    let language: String?
    let code: String

    @State private var copied = false

    nonisolated static func == (lhs: CodeBlockView, rhs: CodeBlockView) -> Bool {
        lhs.language == rhs.language && lhs.code == rhs.code
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: code, copied: $copied)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.footnote.monospaced())
                    .lineSpacing(3)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .background(Palette.fill, in: .rect(cornerRadius: 8))
    }
}

private struct MarkdownTable: View, Equatable {
    let rows: [[String]]

    @Environment(\.colorScheme) private var colorScheme

    nonisolated static func == (lhs: MarkdownTable, rhs: MarkdownTable) -> Bool {
        lhs.rows == rhs.rows
    }

    /// 按每列最长的内容估一个列宽（60…240pt），超出的在格子里换行。
    private var widths: [CGFloat] {
        let columns = rows.map(\.count).max() ?? 0
        return (0 ..< columns).map { column in
            let longest = rows.compactMap { $0.indices.contains(column) ? $0[column] : nil }
                .map { $0.reduce(0) { $0 + ($1.isASCII ? 1 : 2) } }
                .max() ?? 0
            return min(240, max(60, CGFloat(longest) * 8 + 20))
        }
    }

    var body: some View {
        let widths = widths
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(widths.enumerated()), id: \.offset) { column, width in
                            MarkdownText.inlineText(
                                row.indices.contains(column) ? row[column] : "",
                                fontSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
                                colorScheme: colorScheme
                            )
                                .font(rowIndex == 0 ? .subheadline.weight(.semibold) : .subheadline)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(width: width, alignment: .leading)
                        }
                    }
                    if rowIndex < rows.count - 1 {
                        Rectangle().fill(Palette.line).frame(height: 0.5)
                    }
                }
            }
            // 长按菜单的预览要有底色，不然浮在变暗的背景上发灰。
            .background(Color(.systemBackground), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 0.5))
            .padding(0.5)
        }
        .contentShape(.contextMenuPreview, .rect(cornerRadius: 8))
        // 表格不进正文的连续选区，长按弹系统菜单整张拷贝（制表符分列，粘到表格软件里也能对上）。
        .contextMenu {
            Button {
                UIPasteboard.general.string = rows.map { row in
                    row.map { String(MarkdownText.inline($0).characters) }.joined(separator: "\t")
                }.joined(separator: "\n")
            } label: {
                Label("拷贝", image: "mc-copy")
            }
        }
    }
}

// MARK: - 共用

/// 官方网页端的配色 token（浅色 / 深色两套），对话流里统一从这里取。
enum Palette {
    static let userBubble = dynamic(light: 0xF5F5F5, dark: 0x292929)
    /// `--color-fill-1`：工具面板、代码块底色。
    static let fill = Color(uiFill)
    static let uiFill = UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.05) : UIColor(white: 0, alpha: 0.03) }
    static let line = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.12) : UIColor(white: 0, alpha: 0.13) })
    static let danger = dynamic(light: 0xC0392B, dark: 0xF85149)
    static let dangerSoft = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 248 / 255, green: 81 / 255, blue: 73 / 255, alpha: 0.14)
        : UIColor(red: 0xFB / 255, green: 0xEA / 255, blue: 0xEA / 255, alpha: 1) })
    static let diffAdd = dynamic(light: 0x16C456, dark: 0x16C456)
    static let diffDel = dynamic(light: 0xFF4756, dark: 0xFF4756)
    static let kimi = Color("AccentColor")
    static let uiKimi = UIColor(named: "AccentColor") ?? .tintColor

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// 复制按钮：点了变对勾 1.5 秒。
struct CopyButton: View {
    let text: String
    @Binding var copied: Bool

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            MoonIcon(copied ? "mc-check" : "mc-copy", size: 15)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "已复制" : "复制")
    }
}
