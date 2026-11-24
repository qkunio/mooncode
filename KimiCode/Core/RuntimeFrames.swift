import Foundation

/// Kimi Code 2.5+ 的全量 agent 状态。缺省字段表示服务端当前没有该值，不是“保持原值”。
struct SessionAgentState: Decodable, Sendable {
    let status: String
    let compacting: Bool
    let model: String?
    let thinkingLevel: String?
    let permission: PermissionMode?
    let planMode: Bool
    let swarmMode: Bool
    let towerMode: Bool

    /// 2.7+ 的 status 为 `idle | running | ended`，同时用独立布尔 `compacting` 表达压缩中；
    /// 2.5–2.6 则用 `status == "compacting"`。`idle` 和 `ended` 都属于非运行态。
    var isWorking: Bool {
        compacting || (status != "idle" && status != "ended")
    }

    var isCompacting: Bool {
        compacting || status == "compacting"
    }

    enum CodingKeys: String, CodingKey {
        case status, compacting, model
        case thinkingLevel = "thinking"
        case permission = "permission_mode"
        case planMode = "plan_mode"
        case swarmMode = "swarm_mode"
        case towerMode = "tower_mode"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status)
        compacting = (try? c.decodeIfPresent(Bool.self, forKey: .compacting)) ?? false
        model = try c.decodeIfPresent(String.self, forKey: .model)
        thinkingLevel = try c.decodeIfPresent(String.self, forKey: .thinkingLevel)
        permission = try? c.decodeIfPresent(PermissionMode.self, forKey: .permission)
        planMode = try c.decode(Bool.self, forKey: .planMode)
        swarmMode = try c.decode(Bool.self, forKey: .swarmMode)
        towerMode = try c.decode(Bool.self, forKey: .towerMode)
    }
}

/// Kimi Code 2.5+ 的全量上下文用量。
struct SessionContextUsage: Decodable, Sendable {
    let contextTokens: Int
    let maxContextTokens: Int?

    var ratio: Double? {
        guard let maxContextTokens, maxContextTokens > 0 else { return nil }
        return Double(contextTokens) / Double(maxContextTokens)
    }

    enum CodingKeys: String, CodingKey {
        case contextTokens = "context_tokens"
        case maxContextTokens = "max_context_tokens"
    }
}

struct InteractionFrame: Decodable, Sendable {
    enum Kind: String, Decodable, Sendable { case approval, question }
    enum Status: String, Decodable, Sendable { case pending, ended }

    struct ApprovalPayload: Decodable, Sendable {
        let toolName: String
        let action: String
        let toolInputDisplay: JSONValue?
        let expiresAt: FlexibleDate

        enum CodingKeys: String, CodingKey {
            case action
            case toolName = "tool_name"
            case toolInputDisplay = "tool_input_display"
            case expiresAt = "expires_at"
        }
    }

    struct QuestionPayload: Decodable, Sendable {
        let questions: [QuestionRequest.Question]
    }

    let sessionID: String
    let agentID: String
    let eventCreatedAt: FlexibleDate
    let interactionID: String
    let kind: Kind
    let status: Status
    let outcome: String?
    let endedAt: FlexibleDate?
    let toolCallID: String?
    let approval: ApprovalPayload?
    let questions: [QuestionRequest.Question]?

    enum CodingKeys: String, CodingKey {
        case type, kind, status, outcome, request
        case sessionID = "session_id"
        case agentID = "agent_id"
        case eventCreatedAt = "event_created_at"
        case interactionID = "interaction_id"
        case endedAt = "ended_at"
        case toolCallID = "tool_call_id"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(String.self, forKey: .type) == "interaction" else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Expected interaction frame")
        }
        sessionID = try c.decode(String.self, forKey: .sessionID)
        agentID = try c.decode(String.self, forKey: .agentID)
        eventCreatedAt = try c.decode(FlexibleDate.self, forKey: .eventCreatedAt)
        interactionID = try c.decode(String.self, forKey: .interactionID)
        kind = try c.decode(Kind.self, forKey: .kind)
        status = try c.decode(Status.self, forKey: .status)
        outcome = try c.decodeIfPresent(String.self, forKey: .outcome)
        endedAt = try c.decodeIfPresent(FlexibleDate.self, forKey: .endedAt)
        toolCallID = try c.decodeIfPresent(String.self, forKey: .toolCallID)
        switch kind {
        case .approval:
            approval = try c.decode(ApprovalPayload.self, forKey: .request)
            questions = nil
        case .question:
            approval = nil
            questions = try c.decode(QuestionPayload.self, forKey: .request).questions
        }
    }

    var approvalRequest: ApprovalRequest? {
        guard kind == .approval, let approval else { return nil }
        return ApprovalRequest(
            approvalID: interactionID,
            sessionID: sessionID,
            turnID: nil,
            toolCallID: toolCallID ?? "",
            toolName: approval.toolName,
            action: approval.action,
            toolInputDisplay: approval.toolInputDisplay,
            createdAt: eventCreatedAt,
            expiresAt: approval.expiresAt
        )
    }

    var questionRequest: QuestionRequest? {
        guard kind == .question, let questions else { return nil }
        return QuestionRequest(
            questionID: interactionID,
            sessionID: sessionID,
            toolCallID: toolCallID,
            questions: questions
        )
    }
}

/// 新版 interaction 帧在订阅确认后重发当前 pending 全量，因此 reset 后只应用帧，不再读旧列表。
struct PendingInteractions: Sendable {
    private(set) var approvals: [ApprovalRequest] = []
    private(set) var questions: [QuestionRequest] = []

    mutating func reset() {
        approvals = []
        questions = []
    }

    mutating func replaceLegacy(approvals: [ApprovalRequest], questions: [QuestionRequest]) {
        self.approvals = approvals
        self.questions = questions
    }

    mutating func apply(_ frame: InteractionFrame) {
        switch frame.kind {
        case .approval:
            questions.removeAll { $0.questionID == frame.interactionID }
            approvals.removeAll { $0.approvalID == frame.interactionID }
            if frame.status == .pending, let request = frame.approvalRequest {
                approvals.append(request)
            }
        case .question:
            approvals.removeAll { $0.approvalID == frame.interactionID }
            questions.removeAll { $0.questionID == frame.interactionID }
            if frame.status == .pending, let request = frame.questionRequest {
                questions.append(request)
            }
        }
    }
}

enum InteractionResponseBody: Encodable, Sendable {
    case approval(ApprovalDecisionBody)
    case question(QuestionAnswerBody)
    case dismissQuestion

    enum CodingKeys: String, CodingKey {
        case kind, decision, scope, feedback, answers, method, dismissed
        case selectedLabel = "selected_label"
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .approval(body):
            try c.encode("approval", forKey: .kind)
            try c.encode(body.decision, forKey: .decision)
            try c.encodeIfPresent(body.scope, forKey: .scope)
            try c.encodeIfPresent(body.feedback, forKey: .feedback)
            try c.encodeIfPresent(body.selectedLabel, forKey: .selectedLabel)
        case let .question(body):
            try c.encode("question", forKey: .kind)
            try c.encode(body.answers, forKey: .answers)
            try c.encode(body.method, forKey: .method)
        case .dismissQuestion:
            try c.encode("question", forKey: .kind)
            try c.encode(true, forKey: .dismissed)
        }
    }
}

struct InteractionOutcome: Decodable, Sendable {
    let outcome: String
    let endedAt: FlexibleDate?

    enum CodingKeys: String, CodingKey {
        case outcome
        case endedAt = "ended_at"
    }
}

/// 2.7+ `GET /sessions/{id}/interactions` 的单项：结构同 pending 的 `InteractionFrame`，但时间键为 `created_at` 且无 `type` / `status`。
struct PendingInteractionItem: Decodable, Sendable {
    let interactionID: String
    let sessionID: String
    let agentID: String
    let createdAt: FlexibleDate
    let toolCallID: String?
    let kind: InteractionFrame.Kind
    let approval: InteractionFrame.ApprovalPayload?
    let questions: [QuestionRequest.Question]?

    enum CodingKeys: String, CodingKey {
        case kind, request
        case interactionID = "interaction_id"
        case sessionID = "session_id"
        case agentID = "agent_id"
        case createdAt = "created_at"
        case toolCallID = "tool_call_id"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        interactionID = try c.decode(String.self, forKey: .interactionID)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        agentID = try c.decode(String.self, forKey: .agentID)
        createdAt = try c.decode(FlexibleDate.self, forKey: .createdAt)
        toolCallID = try c.decodeIfPresent(String.self, forKey: .toolCallID)
        kind = try c.decode(InteractionFrame.Kind.self, forKey: .kind)
        switch kind {
        case .approval:
            approval = try c.decode(InteractionFrame.ApprovalPayload.self, forKey: .request)
            questions = nil
        case .question:
            approval = nil
            questions = try c.decode(InteractionFrame.QuestionPayload.self, forKey: .request).questions
        }
    }

    var approvalRequest: ApprovalRequest? {
        guard kind == .approval, let approval else { return nil }
        return ApprovalRequest(
            approvalID: interactionID,
            sessionID: sessionID,
            turnID: nil,
            toolCallID: toolCallID ?? "",
            toolName: approval.toolName,
            action: approval.action,
            toolInputDisplay: approval.toolInputDisplay,
            createdAt: createdAt,
            expiresAt: approval.expiresAt
        )
    }

    var questionRequest: QuestionRequest? {
        guard kind == .question, let questions else { return nil }
        return QuestionRequest(
            questionID: interactionID,
            sessionID: sessionID,
            toolCallID: toolCallID,
            questions: questions
        )
    }
}

struct PendingInteractionList: Decodable, Sendable {
    let items: [PendingInteractionItem]

    var approvals: [ApprovalRequest] { items.compactMap(\.approvalRequest) }
    var questions: [QuestionRequest] { items.compactMap(\.questionRequest) }
}
