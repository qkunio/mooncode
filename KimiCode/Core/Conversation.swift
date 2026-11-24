import Foundation

struct ConversationPage: Decodable, Sendable {
    var turns: [ConversationTurn]
    var hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case turns
        case hasMore = "has_more"
    }

    init(turns: [ConversationTurn], hasMore: Bool) {
        self.turns = turns
        self.hasMore = hasMore
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        turns = try c.decodeIfPresent([ConversationTurn].self, forKey: .turns) ?? []
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
    }
}

struct ConversationError: Decodable, Sendable {
    let code: String
    let message: String
    var name: String?
    var statusCode: Int?
    var requestID: String?
    var retryable: Bool?

    enum CodingKeys: String, CodingKey {
        case code, message, name, retryable
        case statusCode = "status_code"
        case requestID = "request_id"
    }
}

struct ConversationRetry: Decodable, Sendable {
    let attempt: Int
    let nextAttempt: Int
    let maxAttempts: Int
    let delayMs: Double
    let error: Error

    struct Error: Decodable, Sendable {
        let name: String
        let message: String
        var statusCode: Int?

        enum CodingKeys: String, CodingKey {
            case name, message
            case statusCode = "status_code"
        }
    }

    enum CodingKeys: String, CodingKey {
        case attempt
        case nextAttempt = "next_attempt"
        case maxAttempts = "max_attempts"
        case delayMs = "delay_ms"
        case error
    }

    var transcriptRetry: TranscriptRetry {
        TranscriptRetry(
            failedAttempt: attempt,
            nextAttempt: nextAttempt,
            maxAttempts: maxAttempts,
            delayMs: delayMs,
            errorName: error.name,
            errorMessage: error.message,
            statusCode: error.statusCode
        )
    }
}

struct ConversationUsage: Decodable, Sendable {
    let inputOther: Double
    let output: Double
    let inputCacheRead: Double
    let inputCacheCreation: Double

    enum CodingKeys: String, CodingKey {
        case inputOther = "input_other"
        case output
        case inputCacheRead = "input_cache_read"
        case inputCacheCreation = "input_cache_creation"
    }

    var transcriptUsage: TranscriptTokenUsage {
        TranscriptTokenUsage(
            inputOther: inputOther,
            output: output,
            inputCacheRead: inputCacheRead,
            inputCacheCreation: inputCacheCreation
        )
    }

    var transcriptTurnUsage: TranscriptTurnUsage {
        TranscriptTurnUsage(inputTokens: inputOther, outputTokens: output, cachedTokens: inputCacheRead)
    }
}

struct ConversationStep: Decodable, Sendable {
    let index: Int
    var outcome: String?
    var startedAt: String
    var endedAt: String?
    var finishReason: String?
    var usage: ConversationUsage?

    enum CodingKeys: String, CodingKey {
        case index, outcome, usage
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case finishReason = "finish_reason"
    }
}

struct ConversationAttachment: Decodable, Sendable {
    let kind: String
    var fileID: String?
    var url: String?
    var name: String?
    var mediaType: String?
    var size: Int?
    let ordinal: Int

    enum CodingKeys: String, CodingKey {
        case kind, url, name, size, ordinal
        case fileID = "file_id"
        case mediaType = "media_type"
    }

    func transcriptAttachment(itemID: String) -> TranscriptAttachment {
        let source: JSONValue?
        if kind == "file", let fileID {
            source = .object(["kind": .string("file"), "fileId": .string(fileID)])
        } else if let url {
            source = .object(["kind": .string("url"), "url": .string(url)])
        } else if let fileID {
            source = .object(["kind": .string("session_media"), "fileId": .string(fileID)])
        } else {
            source = nil
        }
        return TranscriptAttachment(
            attachmentId: "\(itemID):attachment:\(ordinal)",
            mediaType: mediaType ?? (kind == "image" ? "image/*" : nil),
            name: name,
            size: size,
            source: source
        )
    }
}

struct ConversationItem: Decodable, Sendable {
    let itemID: String
    let type: String
    var stepIndex: Int?
    var status: String
    var outcome: String?
    var createdAt: String
    var promptIDs: [String]?
    var placement: String?
    var origin: JSONValue?
    var text: String?
    var attachments: [ConversationAttachment]?
    var startedAt: String?
    var endedAt: String?
    var durationMs: Double?
    var name: String?
    var stage: String?
    var input: JSONValue?
    var inputText: String?
    var display: JSONValue?
    var output: JSONValue?
    var error: String?
    var taskID: String?
    var interactionID: String?
    var agentRefs: JSONValue?
    var kind: String?
    var trigger: String?
    var tokensBefore: Double?
    var tokensAfter: Double?
    var summary: String?
    var title: String?
    var body: String?
    var severity: String?

    enum CodingKeys: String, CodingKey {
        case type, status, outcome, placement, origin, text, attachments, name, stage, input, display, output, error, kind, trigger, summary, title, body, severity
        case itemID = "item_id"
        case stepIndex = "step_index"
        case createdAt = "created_at"
        case promptIDs = "prompt_ids"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationMs = "duration_ms"
        case inputText = "input_text"
        case taskID = "task_id"
        case interactionID = "interaction_id"
        case agentRefs = "agent_refs"
        case tokensBefore = "tokens_before"
        case tokensAfter = "tokens_after"
    }

    mutating func apply(_ patch: ConversationItemPatch) {
        if let status = patch.status { self.status = status }
        if let outcome = patch.outcome { self.outcome = outcome }
        if let stepIndex = patch.stepIndex { self.stepIndex = stepIndex }
        if let stage = patch.stage { self.stage = stage }
        if let input = patch.input { self.input = input }
        if let inputText = patch.inputText { self.inputText = inputText }
        if let display = patch.display { self.display = display }
        if let output = patch.output { self.output = output }
        if let error = patch.error { self.error = error }
        if let taskID = patch.taskID { self.taskID = taskID }
        if let interactionID = patch.interactionID { self.interactionID = interactionID }
        if let agentRefs = patch.agentRefs { self.agentRefs = agentRefs }
        if let startedAt = patch.startedAt { self.startedAt = startedAt }
        if let endedAt = patch.endedAt { self.endedAt = endedAt }
    }

    mutating func append(_ delta: String, to field: ConversationDeltaField) {
        switch field {
        case .text: text = (text ?? "") + delta
        case .inputText: inputText = (inputText ?? "") + delta
        case .output: output = .string((output?.stringValue ?? "") + delta)
        }
    }
}

struct ConversationItemPatch: Decodable, Sendable {
    var stepIndex: Int?
    var status: String?
    var outcome: String?
    var stage: String?
    var input: JSONValue?
    var inputText: String?
    var display: JSONValue?
    var output: JSONValue?
    var error: String?
    var taskID: String?
    var interactionID: String?
    var agentRefs: JSONValue?
    var startedAt: String?
    var endedAt: String?

    enum CodingKeys: String, CodingKey {
        case status, outcome, stage, input, display, output, error
        case stepIndex = "step_index"
        case inputText = "input_text"
        case taskID = "task_id"
        case interactionID = "interaction_id"
        case agentRefs = "agent_refs"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }
}

struct ConversationTurn: Decodable, Sendable {
    let turnID: String
    var ordinal: Int
    var kind: String
    var status: String
    var outcome: String?
    var endReason: String?
    var error: ConversationError?
    var retry: ConversationRetry?
    var turnNumber: Int?
    var startedAt: String
    var endedAt: String?
    var durationMs: Double?
    var usage: ConversationUsage?
    var steps: [ConversationStep]
    var items: [ConversationItem]?

    enum CodingKeys: String, CodingKey {
        case ordinal, kind, status, outcome, error, retry, usage, steps, items
        case turnID = "turn_id"
        case endReason = "end_reason"
        case turnNumber = "turn_number"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationMs = "duration_ms"
    }

    init(skeleton turnID: String) {
        self.turnID = turnID
        ordinal = TranscriptTurn.ordinal(of: turnID)
        kind = "agent"
        status = "running"
        startedAt = ""
        steps = []
        items = []
    }
}

enum ConversationDeltaField: String, Decodable, Sendable {
    case text
    case inputText = "input_text"
    case output
}

enum ConversationWireEvent: Decodable, Sendable {
    case turns(ConversationPage)
    case turnStarted(ConversationTurn)
    case turnEnded(ConversationTurn)
    case turnUpdated(turnID: String, step: ConversationStep?, retry: ConversationRetry?)
    case itemStarted(turnID: String, item: ConversationItem)
    case itemEnded(turnID: String, item: ConversationItem)
    case itemUpdated(turnID: String, itemID: String, patch: ConversationItemPatch)
    case itemDelta(turnID: String, itemID: String, field: ConversationDeltaField, delta: String)
    case itemRemoved(turnID: String, itemID: String)
    case turnsRemoved([String])
    case failed(code: Int, message: String)
    case notice(level: String, title: String, detail: String?)

    private enum CodingKeys: String, CodingKey {
        case type, turns, turn, step, retry, item, set, field, delta, code, msg, level, title, detail
        case hasMore = "has_more"
        case turnID = "turn_id"
        case itemID = "item_id"
        case turnIDs = "turn_ids"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "turns":
            self = .turns(try ConversationPage(from: decoder))
        case "turn.started":
            self = .turnStarted(try c.decode(ConversationTurn.self, forKey: .turn))
        case "turn.ended":
            self = .turnEnded(try c.decode(ConversationTurn.self, forKey: .turn))
        case "turn.updated":
            self = .turnUpdated(
                turnID: try c.decode(String.self, forKey: .turnID),
                step: try c.decodeIfPresent(ConversationStep.self, forKey: .step),
                retry: try c.decodeIfPresent(ConversationRetry.self, forKey: .retry)
            )
        case "item.started":
            self = .itemStarted(
                turnID: try c.decode(String.self, forKey: .turnID),
                item: try c.decode(ConversationItem.self, forKey: .item)
            )
        case "item.ended":
            self = .itemEnded(
                turnID: try c.decode(String.self, forKey: .turnID),
                item: try c.decode(ConversationItem.self, forKey: .item)
            )
        case "item.updated":
            self = .itemUpdated(
                turnID: try c.decode(String.self, forKey: .turnID),
                itemID: try c.decode(String.self, forKey: .itemID),
                patch: try c.decode(ConversationItemPatch.self, forKey: .set)
            )
        case "item.delta":
            self = .itemDelta(
                turnID: try c.decode(String.self, forKey: .turnID),
                itemID: try c.decode(String.self, forKey: .itemID),
                field: try c.decode(ConversationDeltaField.self, forKey: .field),
                delta: try c.decode(String.self, forKey: .delta)
            )
        case "item.removed":
            self = .itemRemoved(
                turnID: try c.decode(String.self, forKey: .turnID),
                itemID: try c.decode(String.self, forKey: .itemID)
            )
        case "turns.removed":
            self = .turnsRemoved(try c.decode([String].self, forKey: .turnIDs))
        case "turns.failed":
            self = .failed(
                code: try c.decode(Int.self, forKey: .code),
                message: try c.decode(String.self, forKey: .msg)
            )
        case "notice":
            self = .notice(
                level: try c.decode(String.self, forKey: .level),
                title: try c.decode(String.self, forKey: .title),
                detail: try c.decodeIfPresent(String.self, forKey: .detail)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "Unknown conversation event: \(type)"
            )
        }
    }
}

struct ConversationState: Sendable {
    private(set) var turns: [ConversationTurn] = []
    private(set) var hasMore = false

    init() {}

    init(page: ConversationPage) {
        turns = page.turns
        hasMore = page.hasMore
    }

    var page: ConversationPage {
        ConversationPage(turns: turns, hasMore: hasMore)
    }

    mutating func replaceLatest(_ page: ConversationPage) {
        guard let first = page.turns.first,
              let index = turns.firstIndex(where: { $0.turnID == first.turnID }) else {
            turns = page.turns
            hasMore = page.hasMore
            return
        }
        turns.replaceSubrange(index..., with: page.turns)
    }

    mutating func prepend(older page: ConversationPage) {
        turns = page.turns + turns
        hasMore = page.hasMore
    }

    mutating func apply(_ event: ConversationWireEvent) {
        switch event {
        case let .turns(page):
            replaceLatest(page)
        case let .turnStarted(turn), let .turnEnded(turn):
            upsert(turn)
        case let .turnUpdated(turnID, step, retry):
            updateTurn(turnID) { turn in
                if let step {
                    if let index = turn.steps.firstIndex(where: { $0.index == step.index }) {
                        turn.steps[index] = step
                    } else {
                        turn.steps.append(step)
                        turn.steps.sort { $0.index < $1.index }
                    }
                }
                turn.retry = retry
            }
        case let .itemStarted(turnID, item), let .itemEnded(turnID, item):
            upsertItem(turnID: turnID, item: item)
        case let .itemUpdated(turnID, itemID, patch):
            updateItem(turnID: turnID, itemID: itemID) { $0.apply(patch) }
        case let .itemDelta(turnID, itemID, field, delta):
            updateItem(turnID: turnID, itemID: itemID) { $0.append(delta, to: field) }
        case let .itemRemoved(turnID, itemID):
            updateTurn(turnID) { turn in
                turn.items?.removeAll { $0.itemID == itemID }
            }
        case let .turnsRemoved(ids):
            let removed = Set(ids)
            turns.removeAll { removed.contains($0.turnID) }
        case .failed, .notice:
            break
        }
    }

    private mutating func upsert(_ header: ConversationTurn) {
        if let index = turns.firstIndex(where: { $0.turnID == header.turnID }) {
            var next = header
            next.items = turns[index].items
            turns[index] = next
            return
        }
        var next = header
        next.items = []
        let index = turns.firstIndex { $0.ordinal > header.ordinal } ?? turns.endIndex
        turns.insert(next, at: index)
    }

    private mutating func updateTurn(_ turnID: String, change: (inout ConversationTurn) -> Void) {
        guard let index = turns.lastIndex(where: { $0.turnID == turnID }) else { return }
        change(&turns[index])
    }

    private mutating func upsertItem(turnID: String, item: ConversationItem) {
        updateTurn(turnID) { turn in
            var items = turn.items ?? []
            if let index = items.firstIndex(where: { $0.itemID == item.itemID }) {
                items[index] = item
            } else {
                items.append(item)
            }
            turn.items = items
        }
    }

    private mutating func updateItem(
        turnID: String, itemID: String, change: (inout ConversationItem) -> Void
    ) {
        updateTurn(turnID) { turn in
            guard var items = turn.items,
                  let index = items.firstIndex(where: { $0.itemID == itemID }) else { return }
            change(&items[index])
            turn.items = items
        }
    }

    var transcriptState: TranscriptState {
        TranscriptState(page: transcriptPage)
    }

    var transcriptPage: TranscriptPage {
        var page = TranscriptPage()
        page.hasMore = hasMore
        page.wireProtocol = .conversation
        page.conversation = self.page
        for turn in turns {
            let converted = Self.transcriptItems(for: turn)
            page.items.append(contentsOf: converted.items)
            page.attachments.append(contentsOf: converted.attachments)
            page.prompts.append(contentsOf: converted.prompts)
        }
        return page
    }

    private static func transcriptItems(
        for source: ConversationTurn
    ) -> (items: [TranscriptItem], attachments: [TranscriptAttachment], prompts: [TranscriptPrompt]) {
        let sourceItems = source.items ?? []
        let opener = sourceItems.first { $0.type == "user_message" && $0.placement == "opener" }
        var attachments: [TranscriptAttachment] = []
        var prompts: [TranscriptPrompt] = []
        var steps = source.steps.map { summary in
            var step = TranscriptStep(
                stepId: "\(source.turnID):step:\(summary.index)",
                turnId: source.turnID,
                ordinal: summary.index,
                state: transcriptState(status: source.status, outcome: summary.outcome),
                frames: []
            )
            step.startedAt = summary.startedAt
            step.endedAt = summary.endedAt
            step.usage = summary.usage?.transcriptUsage
            step.endReason = summary.finishReason
            return step
        }

        func ensureStep(_ index: Int) {
            guard !steps.contains(where: { $0.ordinal == index }) else { return }
            var step = TranscriptStep(
                stepId: "\(source.turnID):step:\(index)",
                turnId: source.turnID,
                ordinal: index,
                state: transcriptState(status: source.status, outcome: source.outcome),
                frames: []
            )
            step.startedAt = source.startedAt
            steps.append(step)
        }

        if source.retry != nil || !sourceItems.isEmpty {
            ensureStep(source.steps.last?.index ?? sourceItems.last?.stepIndex ?? 1)
        }
        if let retry = source.retry, !steps.isEmpty {
            steps[steps.count - 1].retry = retry.transcriptRetry
        }
        if let endReason = source.endReason, !steps.isEmpty {
            steps[steps.count - 1].endReason = steps[steps.count - 1].endReason ?? endReason
        }
        if let error = source.error, !steps.isEmpty {
            steps[steps.count - 1].endMessage = error.message
        }

        func attachmentIDs(for item: ConversationItem) -> [String] {
            (item.attachments ?? []).map { attachment in
                let converted = attachment.transcriptAttachment(itemID: item.itemID)
                attachments.append(converted)
                return converted.attachmentId
            }
        }

        var markers: [TranscriptItem] = []
        for item in sourceItems {
            if item.itemID != opener?.itemID, item.type == "user_message" {
                for promptID in item.promptIDs ?? [] {
                    prompts.append(TranscriptPrompt(
                        promptId: promptID,
                        userMessageId: item.itemID,
                        status: "completed",
                        content: .string(item.text ?? ""),
                        createdAt: item.createdAt
                    ))
                }
            }
            if item.type == "system", item.kind == "compaction" {
                markers.append(.marker(TranscriptMarker(
                    markerId: item.itemID,
                    marker: "compaction",
                    payload: .object([
                        "phase": .string("completed"),
                        "trigger": .string(item.trigger ?? "auto"),
                        "result": .object([
                            "tokensBefore": item.tokensBefore.map(JSONValue.number) ?? .null,
                            "tokensAfter": item.tokensAfter.map(JSONValue.number) ?? .null,
                            "summary": .string(item.summary ?? ""),
                        ]),
                    ]),
                    at: item.createdAt
                )))
                continue
            }
            guard item.itemID != opener?.itemID,
                  let frame = transcriptFrame(for: item, attachmentIDs: attachmentIDs(for: item)) else { continue }
            let index = item.stepIndex ?? 1
            ensureStep(index)
            guard let stepIndex = steps.firstIndex(where: { $0.ordinal == index }) else { continue }
            steps[stepIndex].frames.append(frame)
        }
        steps.sort { $0.ordinal < $1.ordinal }

        var turn = TranscriptTurn(skeleton: source.turnID)
        turn.ordinal = source.ordinal
        turn.state = transcriptState(status: source.status, outcome: source.outcome)
        turn.origin = opener?.origin
        turn.prompt = opener.map(userText)
        turn.triggerPromptId = opener?.promptIDs?.first
        turn.startedAt = source.startedAt
        turn.endedAt = source.endedAt
        turn.durationMs = source.durationMs
        turn.usage = source.usage?.transcriptTurnUsage
        turn.error = source.error?.message
        turn.endReason = source.endReason
        turn.steps = steps
        if let opener {
            turn.attachmentIds = attachmentIDs(for: opener)
            for promptID in opener.promptIDs ?? [] {
                prompts.append(TranscriptPrompt(
                    promptId: promptID,
                    userMessageId: opener.itemID,
                    status: "completed",
                    content: .string(opener.text ?? ""),
                    createdAt: opener.createdAt
                ))
            }
        }
        return ([.turn(turn)] + markers, attachments, prompts)
    }

    private static func transcriptFrame(for item: ConversationItem, attachmentIDs: [String]) -> TranscriptFrame? {
        let kind: String
        var role: String?
        switch item.type {
        case "user_message":
            kind = "text"
            role = "user"
        case "assistant_message":
            kind = "text"
            role = "assistant"
        case "reasoning":
            kind = "thinking"
        case "tool_call":
            kind = "tool"
        case "notification":
            kind = "notice"
        default:
            return nil
        }
        let state: String? = item.type == "tool_call"
            ? transcriptState(status: item.status, outcome: item.outcome)
            : nil
        let input: JSONValue?
        if let itemInput = item.input {
            input = itemInput
        } else if item.stage == "input", let inputText = item.inputText {
            input = .string(inputText)
        } else {
            input = item.display
        }
        return TranscriptFrame(
            kind: kind,
            frameId: item.itemID,
            role: role,
            text: item.type == "user_message" ? userText(item) : item.text,
            attachmentIds: attachmentIDs,
            taskId: item.taskID,
            promptIds: item.promptIDs,
            origin: item.origin,
            toolCallId: item.type == "tool_call" ? item.itemID : nil,
            name: item.type == "notification" ? item.title : item.name,
            state: state,
            input: input,
            output: item.output,
            display: item.display,
            error: item.error,
            inputText: item.inputText,
            progress: nil,
            approvalId: item.interactionID,
            agentRefs: item.agentRefs,
            level: item.severity,
            message: item.body
        )
    }

    private static func userText(_ item: ConversationItem) -> String {
        if let kind = item.origin?["kind"]?.stringValue, kind == "skill" || kind == "plugin_command" {
            return item.origin?["args"]?.stringValue ?? ""
        }
        return item.text ?? ""
    }

    private static func transcriptState(status: String, outcome: String?) -> String {
        if status == "running" { return "running" }
        switch outcome {
        case "failed": return "failed"
        case "interrupted": return "cancelled"
        default: return "completed"
        }
    }
}
