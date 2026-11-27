import Foundation
import Synchronization

// MARK: - 视图模型
//
// 照官方网页端的管线搬过来：
//   transcript 的 turn → 用户消息 / 助手消息（RE + C6）
//   助手消息的 blocks → 连续的「思考 + 工具」合成一组（$At 的 activity-run）
//   → 最后一段正文之前的全部折叠成「已工作 X」（FAt 的 TurnFold）

struct ChatEntry: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case user(UserEntry)
        case assistant(AssistantEntry)
        case compaction(CompactionEntry)
    }

    let id: String
    let kind: Kind

    var isAssistant: Bool {
        if case .assistant = kind { return true }
        return false
    }
}

struct UserEntry: Sendable, Equatable {
    let id: String
    let text: String
    let attachments: [AttachmentRef]
    let createdAt: Date?
    /// 可撤销的条数（官方 `zIe`：从末尾往前数用户消息，遇到压缩分隔就停）。
    var undoCount: Int?
    /// 2.6+ 撤销接口使用的 opener turn id。
    var undoTurnID: String? = nil
}

struct AttachmentRef: Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let isImage: Bool
    let source: AttachmentSource?
    /// 正文里拆出来的文件提及才有：会话目录里的相对路径（文件夹以 `/` 结尾），点它打开预览。
    var mentionPath: String? = nil

    /// 能打开预览的文件提及（文件夹不行）。
    var previewEntry: FsEntry? {
        guard let mentionPath, !mentionPath.hasSuffix("/") else { return nil }
        return FsEntry(path: mentionPath, name: name)
    }
}

struct CompactionEntry: Sendable, Equatable {
    let id: String
    let auto: Bool
    let tokensBefore: Int?
    let tokensAfter: Int?
    let summary: String?
}

struct AssistantEntry: Sendable, Equatable {
    let id: String
    var blocks: [ChatBlock] {
        didSet { recomputeDerived() }
    }
    var createdAt: Date?
    var endedAt: Date?
    var durationMs: Double?
    /// 所属 turn 的序号与状态（`daemonTurnId` / `daemonTurnState`）。
    var turnOrdinal: Int
    var turnState: String

    // 预计算的展示拆分与标志，避免每次 SwiftUI body 评估重复切分和裁剪字符串。
    private(set) var displayItems: [DisplayItem] = []
    private(set) var foldedItems: [DisplayItem] = []
    private(set) var visibleItems: [DisplayItem] = []
    private(set) var hasContent = false
    private(set) var earliestThinkingStart: Date?

    init(
        id: String,
        blocks: [ChatBlock],
        createdAt: Date? = nil,
        endedAt: Date? = nil,
        durationMs: Double? = nil,
        turnOrdinal: Int,
        turnState: String
    ) {
        self.id = id
        self.blocks = blocks
        self.createdAt = createdAt
        self.endedAt = endedAt
        self.durationMs = durationMs
        self.turnOrdinal = turnOrdinal
        self.turnState = turnState
        recomputeDerived()
    }

    static func == (lhs: AssistantEntry, rhs: AssistantEntry) -> Bool {
        lhs.id == rhs.id
            && lhs.blocks == rhs.blocks
            && lhs.createdAt == rhs.createdAt
            && lhs.endedAt == rhs.endedAt
            && lhs.durationMs == rhs.durationMs
            && lhs.turnOrdinal == rhs.turnOrdinal
            && lhs.turnState == rhs.turnState
    }

    private mutating func recomputeDerived() {
        let items = Self.computeDisplayItems(from: blocks)
        displayItems = items
        let split = Self.computeFoldSplit(from: items)
        foldedItems = split.folded
        visibleItems = split.visible
        hasContent = blocks.contains {
            switch $0 {
            case let .thinking(item): !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case let .text(_, text): !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .tool, .notification: true
            }
        }
        earliestThinkingStart = blocks.compactMap {
            if case let .thinking(item) = $0 { item.startedAt } else { nil }
        }.min()
    }
}

enum ChatBlock: Sendable, Identifiable, Equatable {
    case thinking(ThinkingItem)
    case text(id: String, text: String)
    case tool(ToolItem)
    case notification(id: String, title: String, body: String, failed: Bool)

    var id: String {
        switch self {
        case let .thinking(item): item.id
        case let .text(id, _): id
        case let .tool(tool): tool.id
        case let .notification(id, _, _, _): id
        }
    }
}

struct ThinkingItem: Sendable, Identifiable, Equatable {
    let id: String
    var text: String
    var startedAt: Date?
    var durationMs: Double?
}

struct ToolItem: Sendable, Identifiable, Equatable {
    enum Status: String, Sendable, Equatable { case running, ok, error, cancelled }

    let id: String
    let name: String
    /// `Sr`：预计算的工具名归一化结果，避免每次渲染跑正则。
    let kind: String
    let input: JSONValue?
    var output: [String]
    var status: Status
    var display: JSONValue?

    init(
        id: String,
        name: String,
        input: JSONValue?,
        output: [String],
        status: Status,
        display: JSONValue? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = ToolNames.normalize(name)
        self.input = input
        self.output = output
        self.status = status
        self.display = display
    }
}

struct IndexedBlock: Sendable, Identifiable, Equatable {
    let block: ChatBlock
    let index: Int

    var id: String { block.id }
}

/// 助手消息里要画的一项：单个块，或者一组「思考 + 工具」。
enum DisplayItem: Identifiable, Sendable, Equatable {
    case block(ChatBlock, index: Int)
    case activityRun([IndexedBlock])

    var id: String {
        switch self {
        case let .block(block, _): block.id
        case let .activityRun(items): "run:\(items.first?.block.id ?? "")"
        }
    }

    /// 在 `blocks` 里的起始下标（`sourceIndex`）。
    var sourceIndex: Int {
        switch self {
        case let .block(_, index): index
        case let .activityRun(items): items.first?.index ?? -1
        }
    }

    var lastSourceIndex: Int {
        switch self {
        case let .block(_, index): index
        case let .activityRun(items): items.last?.index ?? -1
        }
    }
}

extension AssistantEntry {
    /// `$At`：连续的思考 / 工具（≥2 个）合成一组；正文、通知打断分组。
    fileprivate static func computeDisplayItems(from blocks: [ChatBlock]) -> [DisplayItem] {
        var result: [DisplayItem] = []
        var run: [IndexedBlock] = []
        func flush() {
            if run.count == 1, let only = run.first {
                result.append(.block(only.block, index: only.index))
            } else if run.count > 1 {
                result.append(.activityRun(run))
            }
            run = []
        }
        for (index, block) in blocks.enumerated() {
            switch block {
            case .thinking, .tool:
                run.append(IndexedBlock(block: block, index: index))
            case let .text(_, text) where text.isEmpty:
                continue
            case .text, .notification:
                flush()
                result.append(.block(block, index: index))
            }
        }
        flush()
        return result
    }

    /// `FAt`：最后一段正文之前的都折叠；没有正文就全部折叠。通知总在外面。
    var foldSplit: (folded: [DisplayItem], visible: [DisplayItem]) {
        (foldedItems, visibleItems)
    }

    fileprivate static func computeFoldSplit(
        from items: [DisplayItem]
    ) -> (folded: [DisplayItem], visible: [DisplayItem]) {
        var split = -1
        for (index, item) in items.enumerated().reversed() {
            if case let .block(.text(_, text), _) = item, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                split = index
                break
            }
        }
        if split == -1 {
            split = items.firstIndex { if case .block(.notification, _) = $0 { true } else { false } } ?? -1
            if split == -1 { return (items, []) }
        }
        let head = Array(items[..<split])
        let tail = Array(items[split...])
        let notices = head.filter { if case .block(.notification, _) = $0 { true } else { false } }
        guard !notices.isEmpty else { return (head, tail) }
        return (head.filter { if case .block(.notification, _) = $0 { false } else { true } }, notices + tail)
    }

    /// 复制按钮拷的内容：可见部分的正文。
    var visibleText: String {
        visibleItems.compactMap {
            if case let .block(.text(_, text), _) = $0 { text } else { nil }
        }.joined(separator: "\n\n")
    }
}

// MARK: - 构建

/// 客户端对思考的计时（官方 `thinkingTiming`）：现场看到的思考用本地时钟量，
/// 等你确认 / 回答的时间不算进去；没现场看到的退回 step 的起止时间。
struct ThinkingTiming: Sendable, Equatable {
    var startedAt: Date
    var settledAt: Date?
}

enum ConversationBuilder {
    /// 官方 `DJ`：step 在跑、这段思考是最后一帧、且没有卡在待确认上 —— 就是正在流式输出。
    static func isStreamingThinking(
        _ step: TranscriptStep, frameIndex: Int, pendingStepID: String?
    ) -> Bool {
        step.state == "running" && frameIndex == step.frames.count - 1 && step.stepId != pendingStepID
    }

    /// 有待处理的确认 / 提问时，最后一个在跑的 step 视为「停住了」。
    static func pendingStepID(_ state: TranscriptState) -> String? {
        guard state.interactions.values.contains(where: { $0.state == "pending" }) else { return nil }
        for item in state.items.reversed() {
            if case let .turn(turn) = item, turn.state == "running" {
                return turn.steps.last(where: { $0.state == "running" })?.stepId
            }
        }
        return nil
    }

    /// 每次重建前更新计时：新出现的流式思考记开始，不再流式的记结束（官方 `v_e` / `y_e`）。
    static func updateTiming(_ timing: inout [String: ThinkingTiming], state: TranscriptState, now: Date = .now) {
        let pending = pendingStepID(state)
        var seen = Set<String>()
        for item in state.items {
            guard case let .turn(turn) = item else { continue }
            for step in turn.steps {
                for (index, frame) in step.frames.enumerated() where frame.kind == "thinking" {
                    seen.insert(frame.frameId)
                    let streaming = isStreamingThinking(step, frameIndex: index, pendingStepID: pending)
                    if streaming, timing[frame.frameId] == nil {
                        timing[frame.frameId] = ThinkingTiming(startedAt: now)
                    } else if !streaming, timing[frame.frameId]?.settledAt == nil, timing[frame.frameId] != nil {
                        timing[frame.frameId]?.settledAt = now
                    }
                }
            }
        }
        if timing.count > seen.count {
            timing = timing.filter { seen.contains($0.key) }
        }
    }

    static func build(_ state: TranscriptState, timing: [String: ThinkingTiming] = [:]) -> [ChatEntry] {
        let pendingStepID = pendingStepID(state)
        let isTurnActive = state.isTurnActive
        var entries: [ChatEntry] = []
        for (position, item) in state.items.enumerated() {
            entries.append(contentsOf: buildItem(
                item,
                at: position,
                in: state,
                timing: timing,
                pendingStepID: pendingStepID,
                isTurnActive: isTurnActive
            ))
        }
        markUndo(&entries)
        return entries
    }

    /// 构建单条 `TranscriptItem` 对应的 `ChatEntry` 切片（供按轮增量缓存复用）。
    static func buildItem(
        _ item: TranscriptItem,
        at position: Int,
        in state: TranscriptState,
        timing: [String: ThinkingTiming],
        pendingStepID: String?,
        isTurnActive: Bool
    ) -> [ChatEntry] {
        switch item {
        case let .marker(marker):
            guard marker.marker == "compaction", marker.payload?["phase"]?.stringValue == "completed" else {
                return []
            }
            let result = marker.payload?["result"]
            return [ChatEntry(id: marker.markerId, kind: .compaction(CompactionEntry(
                id: marker.markerId,
                auto: compactionTrigger(before: position, in: state.items) != "manual",
                tokensBefore: result?["tokensBefore"]?.intValue,
                tokensAfter: result?["tokensAfter"]?.intValue,
                summary: result?["summary"]?.stringValue
            )))]

        case .taskref:
            return []

        case let .turn(turn):
            var accumulator = Accumulator(
                state: state,
                timing: timing,
                pendingStepID: pendingStepID,
                isTurnActive: isTurnActive
            )
            accumulator.append(turn)
            accumulator.flush()
            return accumulator.entries
        }
    }

    /// 解析当前是否存在可走 `LiveStreamStore` 零重建快路径的活跃正文/思考尾块。
    static func liveAnchor(
        state: TranscriptState,
        entries: [ChatEntry],
        isWorking: Bool
    ) -> LiveStreamAnchor? {
        guard isWorking,
              let turn = state.lastTurn,
              case let .assistant(assistant)? = entries.last?.kind,
              assistant.turnOrdinal == turn.ordinal,
              let lastStep = turn.steps.last(where: { !$0.frames.isEmpty }),
              let lastFrame = lastStep.frames.last else { return nil }

        let frameText = lastFrame.text ?? ""
        guard !frameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        switch lastFrame.kind {
        case "text" where lastFrame.role != "user":
            guard case let .text(blockID, fullText)? = assistant.blocks.last,
                  fullText.hasSuffix(frameText) else { return nil }
            let prefix = String(fullText.dropLast(frameText.count))
            return LiveStreamAnchor(
                turnID: turn.turnId,
                stepID: lastStep.stepId,
                frameID: lastFrame.frameId,
                blockID: blockID,
                kind: .text,
                prefix: prefix,
                frameText: frameText
            )

        case "thinking":
            guard case let .thinking(item)? = assistant.blocks.last,
                  item.durationMs == nil,
                  item.text.hasSuffix(frameText) else { return nil }
            let prefix = String(item.text.dropLast(frameText.count))
            return LiveStreamAnchor(
                turnID: turn.turnId,
                stepID: lastStep.stepId,
                frameID: lastFrame.frameId,
                blockID: item.id,
                kind: .thinking,
                prefix: prefix,
                frameText: frameText
            )

        default:
            return nil
        }
    }

    private struct DraftAssistant {
        let id: String
        var blocks: [ChatBlock]
        var createdAt: Date?
        var endedAt: Date?
        var durationMs: Double?
        var turnOrdinal: Int
        var turnState: String
    }

    private struct Accumulator {
        let state: TranscriptState
        let timing: [String: ThinkingTiming]
        let pendingStepID: String?
        let isTurnActive: Bool
        var entries: [ChatEntry] = []
        var current: DraftAssistant?

        init(
            state: TranscriptState,
            timing: [String: ThinkingTiming],
            pendingStepID: String?,
            isTurnActive: Bool
        ) {
            self.state = state
            self.timing = timing
            self.pendingStepID = pendingStepID
            self.isTurnActive = isTurnActive
        }

        mutating func flush() {
            guard var draft = current else { return }
            current = nil
            guard !draft.blocks.isEmpty else { return }
            // 轮次已结束（或不是最后一条）时，仍标着 running 的工具按完成画（C6 的 f()）。
            if !(isTurnActive && draft.turnState == "running") {
                for index in draft.blocks.indices {
                    if case var .tool(tool) = draft.blocks[index], tool.status == .running {
                        tool.status = .ok
                        draft.blocks[index] = .tool(tool)
                    }
                }
            }
            let entry = AssistantEntry(
                id: draft.id,
                blocks: draft.blocks,
                createdAt: draft.createdAt,
                endedAt: draft.endedAt,
                durationMs: draft.durationMs,
                turnOrdinal: draft.turnOrdinal,
                turnState: draft.turnState
            )
            entries.append(ChatEntry(id: entry.id, kind: .assistant(entry)))
        }

        private mutating func replaceLast(_ block: ChatBlock) {
            guard var entry = current, !entry.blocks.isEmpty else { return }
            entry.blocks[entry.blocks.count - 1] = block
            current = entry
        }

        private mutating func ensureAssistant(_ id: String, turn: TranscriptTurn, createdAt: Date?) {
            if current == nil {
                current = DraftAssistant(
                    id: id, blocks: [], createdAt: createdAt, turnOrdinal: turn.ordinal, turnState: turn.state
                )
            }
        }

        mutating func append(_ turn: TranscriptTurn) {
            let turnStart = ConversationBuilder.earliest([turn.startedAt] + turn.steps.map(\.startedAt))
            let prompt = turn.prompt ?? ""
            let attachments = (turn.attachmentIds ?? []).compactMap { state.attachments[$0] }
                .map(ConversationBuilder.attachmentRef)

            if !prompt.isEmpty || !attachments.isEmpty {
                if turn.originKind == "task", prompt.contains("<notification") {
                    // 后台任务通知：不当用户气泡，塞进助手消息的通知块。
                    ensureAssistant("\(turn.turnId):notice", turn: turn, createdAt: turnStart)
                    current?.blocks.append(ConversationBuilder.notification(id: "\(turn.turnId):input", text: prompt, task: nil))
                } else if ConversationBuilder.isUserVisible(turn.originKind) {
                    let split = ConversationBuilder.splitMentions(ConversationBuilder.stripInjected(
                        prompt, attachmentCount: attachments.count
                    ))
                    entries.append(ChatEntry(id: "\(turn.turnId):input", kind: .user(UserEntry(
                        id: "\(turn.turnId):input",
                        text: split.text,
                        attachments: split.mentions + attachments,
                        createdAt: turnStart,
                        undoTurnID: turn.turnId
                    ))))
                }
            }

            for step in turn.steps {
                let stepStart = ConversationBuilder.parse(step.startedAt) ?? turnStart
                for (frameIndex, frame) in step.frames.enumerated() {
                    switch frame.kind {
                    case "text":
                        appendText(frame, turn: turn, stepStart: stepStart)

                    case "thinking":
                        let text = frame.text ?? ""
                        guard !text.isEmpty else { continue }
                        ensureAssistant(frame.frameId, turn: turn, createdAt: stepStart)
                        let streaming = ConversationBuilder.isStreamingThinking(step, frameIndex: frameIndex, pendingStepID: pendingStepID)
                        var startedAt = stepStart
                        var duration: Double? = streaming ? nil : ConversationBuilder.interval(step.startedAt, step.endedAt)
                        if let measured = timing[frame.frameId] {
                            startedAt = measured.startedAt
                            duration = measured.settledAt.map { $0.timeIntervalSince(measured.startedAt) * 1000 }
                        }
                        if case var .thinking(previous)? = current?.blocks.last {
                            // 相邻思考合并，时间相加（任一段仍在进行就算进行中）。
                            previous.text += "\n" + text
                            if let a = previous.durationMs, let b = duration {
                                previous.durationMs = a + b
                            } else {
                                previous.durationMs = nil
                            }
                            replaceLast(.thinking(previous))
                        } else {
                            current?.blocks.append(.thinking(ThinkingItem(
                                id: frame.frameId, text: text, startedAt: startedAt, durationMs: duration
                            )))
                        }

                    case "tool":
                        guard let toolCallId = frame.toolCallId else { continue }
                        ensureAssistant("\(frame.frameId):call", turn: turn, createdAt: stepStart)
                        let status: ToolItem.Status = switch frame.state {
                        case "error": .error
                        case "running": .running
                        case "cancelled": .cancelled
                        default: .ok
                        }
                        let rawOutput = frame.state == "error" ? (frame.output ?? frame.error.map(JSONValue.string)) : frame.output
                        current?.blocks.append(.tool(ToolItem(
                            id: toolCallId,
                            name: frame.name ?? "tool",
                            input: frame.input ?? frame.display,
                            output: ConversationBuilder.outputLines(rawOutput),
                            status: status,
                            display: frame.display
                        )))

                    case "notice":
                        ensureAssistant(frame.frameId, turn: turn, createdAt: stepStart)
                        current?.blocks.append(.notification(
                            id: frame.frameId,
                            title: frame.name ?? "",
                            body: frame.message ?? frame.text ?? "",
                            failed: frame.level == "error"
                        ))

                    default:
                        continue
                    }
                }
            }

            if var entry = current {
                entry.durationMs = turn.durationMs
                    ?? ConversationBuilder.interval(turn.startedAt ?? turn.steps.first?.startedAt, turn.endedAt)
                entry.endedAt = ConversationBuilder.parse(turn.endedAt) ?? entry.endedAt
                entry.turnState = turn.state
                current = entry
            }
        }

        private mutating func appendText(_ frame: TranscriptFrame, turn: TranscriptTurn, stepStart: Date?) {
            let text = frame.text ?? ""
            if frame.role == "user" {
                if let taskId = frame.taskId {
                    guard !text.isEmpty else { return }
                    ensureAssistant(frame.frameId, turn: turn, createdAt: stepStart)
                    let block = ConversationBuilder.notification(id: frame.frameId, text: text, task: state.tasks[taskId])
                    current?.blocks.append(block)
                    return
                }
                let frameAttachments = (frame.attachmentIds ?? []).compactMap { state.attachments[$0] }
                    .map(ConversationBuilder.attachmentRef)
                guard !text.isEmpty || !frameAttachments.isEmpty else { return }
                flush()
                let split = ConversationBuilder.splitMentions(ConversationBuilder.stripInjected(
                    text, attachmentCount: frameAttachments.count
                ))
                entries.append(ChatEntry(id: frame.frameId, kind: .user(UserEntry(
                    id: frame.frameId,
                    text: split.text,
                    attachments: split.mentions + frameAttachments,
                    createdAt: stepStart
                ))))
                return
            }
            guard !text.isEmpty else { return }
            ensureAssistant(frame.frameId, turn: turn, createdAt: stepStart)
            // 相邻正文合并成一个块（C6 的 textParts 拼接）。
            if case let .text(id, previous)? = current?.blocks.last {
                replaceLast(.text(id: id, text: previous + "\n" + text))
            } else {
                current?.blocks.append(.text(id: frame.frameId, text: text))
            }
        }
    }

    /// 官方 `d_e`：只有用户本人发的（或斜杠触发的技能）才画成用户气泡。
    static func isUserVisible(_ kind: String?) -> Bool {
        switch kind {
        case nil, "user", "skill", "skill_activation", "plugin_command": true
        default: false
        }
    }

    /// 撤销计数（`zIe`）：从末尾往前，遇到压缩分隔就停。
    static func markUndo(_ entries: inout [ChatEntry]) {
        var count = 0
        for index in entries.indices.reversed() {
            switch entries[index].kind {
            case .compaction:
                return
            case var .user(user):
                count += 1
                user.undoCount = count
                entries[index] = ChatEntry(id: entries[index].id, kind: .user(user))
            case .assistant:
                continue
            }
        }
    }

    static func compactionTrigger(before position: Int, in items: [TranscriptItem]) -> String {
        for item in items[..<position].reversed() {
            if case let .marker(marker) = item, marker.marker == "compaction",
               marker.payload?["phase"]?.stringValue == "started" {
                return marker.payload?["trigger"]?.stringValue ?? "auto"
            }
        }
        return "auto"
    }

    static func notification(id: String, text: String, task: TranscriptTask?) -> ChatBlock {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let title = lines.first?.trimmingCharacters(in: .whitespaces) ?? ""
        let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let failed = task.map { $0.state != "completed" && $0.state != "running" } ?? false
        return .notification(id: id, title: title, body: body, failed: failed)
    }

    static func attachmentRef(_ attachment: TranscriptAttachment) -> AttachmentRef {
        let type = attachment.mediaType ?? ""
        return AttachmentRef(
            id: attachment.attachmentId,
            name: attachment.name ?? attachment.attachmentId,
            isImage: type.hasPrefix("image/") || type == "image/*",
            source: AttachmentSource(attachment.source)
        )
    }

    /// 把正文里的文件提及 `[名字](相对路径)` 拆出来当附件显示（网页端渲染成药丸）。
    /// 路径带协议头、`#` / `?` / `//` 开头的是普通链接，不动（官方 `WT`）。名字按 `yC` 反转义。
    static func splitMentions(_ text: String) -> (text: String, mentions: [AttachmentRef]) {
        var mentions: [AttachmentRef] = []
        let pattern = /\[((?:\\.|[^\]\\\n])+)\]\(([^)\s]+)\)/
        let stripped = text.replacing(pattern) { match -> String in
            let target = String(match.output.2)
            let isLink = target.hasPrefix("#") || target.hasPrefix("?") || target.hasPrefix("//")
                || (target.firstMatch(of: /^[a-zA-Z][a-zA-Z0-9+.\-]*:/) != nil
                    && target.firstMatch(of: /^[a-zA-Z]:(?:[\\\/]|%5[cC])/) == nil)
            guard !isLink else { return String(match.output.0) }
            let name = String(match.output.1)
                .replacing(/\\([\\\[\]])/) { String($0.output.1) }
                .replacingOccurrences(of: "%0A", with: "\n")
                .replacingOccurrences(of: "%0D", with: "\r")
                .replacingOccurrences(of: "%26", with: "&")
                .replacingOccurrences(of: "%3C", with: "<")
                .replacingOccurrences(of: "%3E", with: ">")
                .replacingOccurrences(of: "%25", with: "%")
            mentions.append(AttachmentRef(
                id: "mention:\(mentions.count):\(target)", name: name, isImage: false,
                source: nil, mentionPath: target.removingPercentEncoding ?? target
            ))
            return ""
        }
        guard !mentions.isEmpty else { return (text, []) }
        let collapsed = stripped.replacing(/[ \t]{2,}/, with: " ")
        return (collapsed.trimmingCharacters(in: .whitespacesAndNewlines), mentions)
    }

    /// 去掉系统注入的 `<system-reminder>` 之类标签块；被 `<prompt>` 包着的只取里面（官方 `LE`）。
    /// 附件的 `Attached file` 说明给模型看路径，不作为用户正文显示；最多清理实际附件数，避免误删用户自己写的文字。
    static func stripInjected(_ text: String, attachmentCount: Int = 0) -> String {
        var result = text
        if let open = result.range(of: "<prompt>\n"), let close = result.range(of: "\n</prompt>", options: .backwards),
           open.upperBound <= close.lowerBound {
            result = String(result[open.upperBound ..< close.lowerBound])
        }
        for tag in ["system-reminder", "system"] {
            while let open = result.range(of: "<\(tag)>"),
                  let close = result.range(of: "</\(tag)>", range: open.upperBound ..< result.endIndex) {
                result.removeSubrange(open.lowerBound ..< close.upperBound)
            }
        }
        var remainingNotices = attachmentCount
        let lines = result.components(separatedBy: "\n").filter { line in
            let candidate = line.hasSuffix("\r") ? String(line.dropLast()) : line
            let notice = /^Attached file ".+" \([^()\r\n]+, [0-9]+ bytes\): .+ — open it with the Read tool$/
            guard remainingNotices > 0, candidate.wholeMatch(of: notice) != nil else { return true }
            remainingNotices -= 1
            return false
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `EE`：工具输出统一成若干行。
    static func outputLines(_ value: JSONValue?) -> [String] {
        guard let value, !value.isNull else { return [] }
        let text: String
        switch value {
        case let .string(string):
            text = string
        case let .array(parts):
            text = parts.compactMap { part -> String? in
                if let string = part.stringValue { return string }
                if let inner = part["text"]?.stringValue { return inner }
                return part.isNull ? nil : part.compactDescription
            }.joined(separator: "\n")
        case let .object(object):
            if let inner = object["text"]?.stringValue ?? object["output"]?.stringValue ?? object["content"]?.stringValue {
                text = inner
            } else {
                text = value.prettyDescription
            }
        default:
            text = value.compactDescription
        }
        var lines = text.components(separatedBy: "\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    // MARK: 时间

    private static let isoWithFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoPlain = Date.ISO8601FormatStyle()
    private static let dateCache = Mutex<[String: Date]>([:])

    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        if let hit = dateCache.withLock({ $0[text] }) { return hit }
        let parsed = (try? isoWithFraction.parse(text)) ?? (try? isoPlain.parse(text))
        if let parsed {
            dateCache.withLock { cache in
                if cache.count > 1024 { cache.removeAll(keepingCapacity: true) }
                cache[text] = parsed
            }
        }
        return parsed
    }

    static func earliest(_ values: [String?]) -> Date? {
        values.compactMap(parse).min()
    }

    static func interval(_ start: String?, _ end: String?) -> Double? {
        guard let s = parse(start), let e = parse(end) else { return nil }
        let ms = e.timeIntervalSince(s) * 1000
        return ms >= 0 ? ms : nil
    }
}

// MARK: - 工具名 / 图标 / 文案（官方 `Sr` / `eSt` / `tools.label.*`）

enum ToolNames {
    private static let aliases: [String: String] = [
        "multiedit": "multi_edit", "multiedits": "multi_edit", "shell": "bash", "run": "bash", "exec": "bash",
        "ripgrep": "grep", "rg": "grep", "find": "glob", "fetch": "web_fetch", "webfetch": "web_fetch",
        "url_fetch": "web_fetch", "urlfetch": "web_fetch", "list": "ls", "listdir": "ls", "list_dir": "ls",
        "todowrite": "todo", "todo_write": "todo", "todoread": "todo", "todolist": "todo", "todo_list": "todo",
        "agent": "task", "subagent": "task", "websearch": "search", "web_search": "search",
        "create_goal": "creategoal", "get_goal": "getgoal", "set_goal_budget": "setgoalbudget",
        "update_goal": "updategoal", "wait_for": "waitfor", "task_list": "tasklist",
        "task_output": "taskoutput", "task_stop": "taskstop",
    ]

    static func normalize(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces).lowercased()
        var key = ""
        key.reserveCapacity(trimmed.utf8.count)
        var lastWasSeparator = false
        for char in trimmed {
            if char == "-" || char.isWhitespace {
                if !lastWasSeparator {
                    key.append("_")
                    lastWasSeparator = true
                }
            } else {
                key.append(char)
                lastWasSeparator = false
            }
        }
        return aliases[key] ?? key
    }

    /// 官方图标名 → MoonCode SVG 图标名。
    static func symbol(_ name: String) -> String {
        switch normalize(name) {
        case "read", "exitplanmode", "taskoutput": "mc-file-preview"
        case "bash": "mc-terminal"
        case "edit", "multi_edit": "mc-edit"
        case "write": "mc-file-plus"
        case "grep", "search": "mc-search"
        case "glob": "mc-file-search"
        case "ls": "mc-workspace"
        case "web_fetch": "mc-globe"
        case "todo": "mc-checklist"
        case "task", "agentswarm": "mc-thinking"
        case "askuserquestion": "mc-question-circle"
        case "creategoal", "getgoal", "setgoalbudget", "updategoal": "mc-goal-target"
        case "waitfor": "mc-clock"
        case "tasklist": "mc-list-bullet"
        case "taskstop": "mc-stop-circle"
        case "croncreate", "cronlist", "crondelete": "mc-calendar"
        case let other where other.contains("skill"): "mc-skill-bolt"
        default: "mc-tool-wrench"
        }
    }

    static func label(_ name: String) -> String {
        switch normalize(name) {
        case "read": "读取"
        case "bash": "运行"
        case "edit", "multi_edit": "编辑"
        case "write": "写入"
        case "grep", "search": "搜索"
        case "glob": "查找"
        case "ls": "列目录"
        case "web_fetch": "抓取"
        case "todo": "待办"
        case "task": "任务"
        case "agentswarm": "Swarm"
        case "askuserquestion": "提问"
        case "exitplanmode": "计划"
        case "creategoal": "启动目标"
        case "getgoal": "读取目标"
        case "setgoalbudget": "设置目标预算"
        case "updategoal": "更新目标"
        case "waitfor": "等待"
        case "tasklist": "列出任务"
        case "taskoutput": "读取任务输出"
        case "taskstop": "停止任务"
        default: name
        }
    }

    /// `pT`：工具行上的一句话摘要。
    static func summary(_ tool: ToolItem, full: Bool = false) -> String {
        let limit = full ? Int.max : 80
        func clip(_ text: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.count > limit ? String(trimmed.prefix(limit - 1)) + "…" : trimmed
        }
        guard let input = tool.input, let object = input.objectValue else {
            if let text = tool.input?.stringValue { return clip(text) }
            return ""
        }
        if object.isEmpty { return "" }
        func string(_ keys: String...) -> String? {
            for key in keys { if let value = object[key]?.stringValue, !value.isEmpty { return value } }
            return nil
        }
        let fallback = clip(input.compactDescription)
        switch tool.kind {
        case "read":
            guard let path = string("path", "file_path", "filePath", "filename") else { return fallback }
            let start = object["offset"]?.intValue ?? object["line_start"]?.intValue ?? object["start_line"]?.intValue
            let count = object["limit"]?.intValue ?? object["length"]?.intValue
            let end = object["line_end"]?.intValue ?? object["end_line"]?.intValue
                ?? (start != nil && count != nil ? start! + count! : nil)
            if let start, let end { return clip("\(path):\(start)-\(end)") }
            if let start { return clip("\(path):\(start)") }
            return clip(path)
        case "write", "edit", "multi_edit":
            return string("path", "file_path", "filePath", "filename").map(clip) ?? fallback
        case "bash":
            return string("command", "cmd", "script")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallback
        case "grep", "search":
            let pattern = string("pattern", "query", "regex")
            let scope = string("path", "glob", "include")
            if let pattern, let scope { return clip("\(pattern) 在 \(scope) 中") }
            return pattern.map(clip) ?? fallback
        case "glob":
            let pattern = string("pattern", "glob", "query")
            let scope = string("path", "cwd")
            if let pattern, let scope { return clip("\(pattern) 在 \(scope) 中") }
            return (pattern ?? scope).map(clip) ?? fallback
        case "ls":
            return string("path", "dir", "directory", "cwd").map(clip) ?? fallback
        case "web_fetch":
            guard let url = string("url", "uri") else { return fallback }
            if let parsed = URL(string: url), let host = parsed.host() {
                let first = parsed.pathComponents.dropFirst().first
                return clip(first.map { "\(host)/\($0)" } ?? host)
            }
            return clip(url)
        case "todo", "task":
            if let text = string("description", "title", "prompt", "name", "subagent_type") { return clip(text) }
            if let list = object["todos"]?.arrayValue ?? object["items"]?.arrayValue { return "\(list.count) 项" }
            return fallback
        default:
            return fallback
        }
    }

    /// 读取工具的文件名 / 目录 / 行号范围。
    static func readParts(_ tool: ToolItem) -> (name: String?, dir: String?, range: String?) {
        let object = tool.input?.objectValue ?? [:]
        guard let path = ["path", "file_path", "filePath", "filename"].lazy
            .compactMap({ object[$0]?.stringValue }).first(where: { !$0.isEmpty })
        else { return (nil, nil, nil) }
        let name = (path as NSString).lastPathComponent
        let dir = (path as NSString).deletingLastPathComponent
        let start = object["offset"]?.intValue ?? object["line_start"]?.intValue ?? object["start_line"]?.intValue
        let count = object["limit"]?.intValue ?? object["length"]?.intValue
        let end = object["line_end"]?.intValue ?? object["end_line"]?.intValue
            ?? (start != nil && count != nil ? start! + count! : nil)
        let range: String? = if let start, let end { ":\(start)-\(end)" } else if let start { ":\(start)" } else { nil }
        return (name, dir.isEmpty ? nil : dir, range)
    }

    /// `Khe`：工具行尾巴上的小标签（行数 / 结果数 / +N −M）。
    static func chip(_ tool: ToolItem) -> String? {
        switch tool.kind {
        case "read":
            return tool.output.isEmpty || tool.status != .ok ? nil : "\(tool.output.count) 行"
        case "grep", "search":
            let count = tool.output.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            return count > 0 ? "\(count) 结果" : nil
        case "edit", "multi_edit", "write":
            let stats = diffStats(tool)
            if stats.added > 0 || stats.removed > 0 { return nil }
            if tool.kind == "write", tool.status == .ok { return "已创建" }
            return nil
        default:
            return nil
        }
    }

    /// 编辑类工具的 +N / −M。优先从 display 里的 diff 算，退回输出文本里的 `+N -M`。
    static func diffStats(_ tool: ToolItem) -> (added: Int, removed: Int) {
        guard tool.status != .error else { return (0, 0) }
        let lines = diffLines(tool)
        if !lines.isEmpty {
            return (lines.filter { $0.kind == .add }.count, lines.filter { $0.kind == .del }.count)
        }
        for line in tool.output {
            if let plus = line.firstMatch(of: /\+(\d+)/), let minus = line.firstMatch(of: /[-−](\d+)/) {
                return (Int(plus.1) ?? 0, Int(minus.1) ?? 0)
            }
        }
        return (0, 0)
    }

    struct DiffLine: Sendable, Hashable {
        enum Kind: Sendable { case add, del, context, hunk }
        let kind: Kind
        let text: String
    }

    /// 从编辑工具的入参（old_string/new_string）或 display 里的 unified diff 还原出行级 diff。
    static func diffLines(_ tool: ToolItem) -> [DiffLine] {
        if let diff = tool.display?["diff"]?.stringValue ?? tool.display?["patch"]?.stringValue {
            return parseUnified(diff)
        }
        guard let input = tool.input else { return [] }
        if tool.kind == "write" {
            if let content = input["content"]?.stringValue {
                return content.components(separatedBy: "\n").map { DiffLine(kind: .add, text: $0) }
            }
            return []
        }
        var edits: [(String, String)] = []
        if let old = input["old_string"]?.stringValue ?? input["old_str"]?.stringValue,
           let new = input["new_string"]?.stringValue ?? input["new_str"]?.stringValue {
            edits.append((old, new))
        }
        for edit in input["edits"]?.arrayValue ?? [] {
            if let old = edit["old_string"]?.stringValue ?? edit["old_str"]?.stringValue,
               let new = edit["new_string"]?.stringValue ?? edit["new_str"]?.stringValue {
                edits.append((old, new))
            }
        }
        var result: [DiffLine] = []
        for (old, new) in edits {
            if !result.isEmpty { result.append(DiffLine(kind: .hunk, text: "…")) }
            let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
            let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")
            let diff = newLines.difference(from: oldLines)
            var removed = Set<Int>(), inserted = Set<Int>()
            for change in diff {
                switch change {
                case let .remove(offset, _, _): removed.insert(offset)
                case let .insert(offset, _, _): inserted.insert(offset)
                }
            }
            var i = 0, j = 0
            while i < oldLines.count || j < newLines.count {
                if i < oldLines.count, removed.contains(i) {
                    result.append(DiffLine(kind: .del, text: oldLines[i])); i += 1
                } else if j < newLines.count, inserted.contains(j) {
                    result.append(DiffLine(kind: .add, text: newLines[j])); j += 1
                } else {
                    if j < newLines.count { result.append(DiffLine(kind: .context, text: newLines[j])) }
                    i += 1; j += 1
                }
            }
        }
        return result
    }

    private static func parseUnified(_ diff: String) -> [DiffLine] {
        diff.components(separatedBy: "\n").compactMap { line in
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") {
                return nil
            }
            if line.hasPrefix("@@") { return DiffLine(kind: .hunk, text: line) }
            if line.hasPrefix("+") { return DiffLine(kind: .add, text: String(line.dropFirst())) }
            if line.hasPrefix("-") { return DiffLine(kind: .del, text: String(line.dropFirst())) }
            return DiffLine(kind: .context, text: line.hasPrefix(" ") ? String(line.dropFirst()) : line)
        }
    }

    // MARK: 组摘要（`Zhe` / `Qhe`）

    private static let typed: Set<String> = ["read", "bash", "grep", "search", "glob", "ls", "web_fetch", "edit", "write"]

    private static func groupKind(_ tool: ToolItem) -> String {
        tool.kind == "multi_edit" ? "edit" : tool.kind
    }

    private static func doneClause(_ kind: String, _ count: Int) -> String {
        switch kind {
        case "read": "读取了 \(count) 个文件"
        case "bash": "运行了 \(count) 条命令"
        case "grep": "搜索了 \(count) 个模式"
        case "search": "网络搜索了 \(count) 次"
        case "glob": "找了 \(count) 次文件"
        case "ls": "列出了 \(count) 个目录"
        case "web_fetch": "抓取了 \(count) 个页面"
        case "edit": "编辑了 \(count) 处"
        case "write": "写入了 \(count) 个文件"
        default: "执行了 \(count) 次工具调用"
        }
    }

    private static func counts(_ tools: [ToolItem]) -> [(kind: String, count: Int, errors: Int)] {
        var order: [String] = []
        var map: [String: (Int, Int)] = [:]
        for tool in tools {
            let kind = typed.contains(groupKind(tool)) ? groupKind(tool) : "other"
            if map[kind] == nil { order.append(kind); map[kind] = (0, 0) }
            map[kind]!.0 += 1
            if tool.status == .error { map[kind]!.1 += 1 }
        }
        return order.map { ($0, map[$0]!.0, map[$0]!.1) }
    }

    struct Clause: Sendable {
        var text: String
        var faint: Bool
    }

    /// 已结束的一组：「读取了 2 个文件 · 运行了 1 条命令 · 12s」。
    static func settledSummary(_ tools: [ToolItem], durationMs: Double?) -> [Clause] {
        var clauses = counts(tools).map { item in
            Clause(text: doneClause(item.kind, item.count) + (item.errors > 0 ? "（\(item.errors) 失败）" : ""), faint: false)
        }
        if let durationMs, let text = Durations.format(durationMs), !text.isEmpty {
            clauses.append(Clause(text: text, faint: true))
        }
        return clauses
    }

    /// 进行中的一组：「正在读取 a.swift · 已运行了 1 条命令」。
    static func liveSummary(current: ChatBlock?, done: [ToolItem]) -> [Clause] {
        var clauses: [Clause] = []
        if let current {
            switch current {
            case .thinking:
                clauses.append(Clause(text: "思考中…", faint: false))
            case let .tool(tool):
                var subject = summary(tool)
                if tool.kind == "write", subject.hasSuffix("已创建") {
                    subject = String(subject.dropLast(3)).trimmingCharacters(in: .whitespaces)
                }
                let kind = groupKind(tool)
                if !subject.isEmpty, typed.contains(kind) {
                    clauses.append(Clause(text: doingClause(kind, subject), faint: false))
                } else {
                    clauses.append(Clause(text: "正在执行…", faint: false))
                }
            default:
                break
            }
        }
        clauses += counts(done).map { item in
            Clause(text: "已" + doneClause(item.kind, item.count) + (item.errors > 0 ? "（\(item.errors) 失败）" : ""), faint: true)
        }
        return clauses
    }

    private static func doingClause(_ kind: String, _ subject: String) -> String {
        switch kind {
        case "read": "正在读取 \(subject)"
        case "bash": "正在运行 \(subject)"
        case "grep", "search": "正在搜索 \(subject)"
        case "glob": "正在匹配 \(subject)"
        case "ls": "正在列出 \(subject)"
        case "web_fetch": "正在抓取 \(subject)"
        case "edit": "正在编辑 \(subject)"
        case "write": "正在写入 \(subject)"
        default: "正在执行…"
        }
    }
}

// MARK: - 时长（官方 `Md`：0 秒显示为空，1m5s / 2h3m）

enum Durations {
    static func format(_ ms: Double) -> String? {
        let seconds = max(0, Int(ms / 1000))
        if seconds < 60 { return seconds == 0 ? "" : "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 {
            let rest = seconds % 60
            return rest == 0 ? "\(minutes)m" : "\(minutes)m\(rest)s"
        }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h\(rest)m"
    }
}
