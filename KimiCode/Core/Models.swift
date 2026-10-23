import Foundation

// MARK: - 时间

/// 服务端的时间字段有三种形态，同一个 JSON 里混着用：
///   - ISO8601 带小数秒：`"2026-09-18T12:02:07.203Z"`（session.created_at）
///   - epoch 毫秒数字：`1789732947977`（history 里的 timestamp）
///   - 空字符串：`""`（device.last_remote_access_at 没访问过时）
/// 所以统一用这个包装解码，别直接上 `.iso8601` 策略。
struct FlexibleDate: Decodable, Hashable, Sendable {
    let date: Date?

    init(date: Date?) { self.date = date }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let millis = try? container.decode(Double.self) {
            // 秒还是毫秒：2001 年之后的秒级时间戳都 < 1e11，毫秒级 > 1e11。
            date = Date(timeIntervalSince1970: millis > 1e11 ? millis / 1000 : millis)
            return
        }
        if let text = try? container.decode(String.self) {
            date = text.isEmpty ? nil : Self.parse(text)
            return
        }
        date = nil
    }

    /// `ISO8601DateFormatter` 不是 Sendable，用 Sendable 的 `ISO8601FormatStyle` 解析。
    /// 带小数秒和不带两种都要试 —— 服务端两种都发。
    private static func parse(_ text: String) -> Date? {
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = try? withFraction.parse(text) { return date }
        return try? Date.ISO8601FormatStyle().parse(text)
    }
}

// MARK: - Relay

/// `GET {relay}/v1/remote/devices` 的一项。
struct RemoteDevice: Decodable, Identifiable, Hashable, Sendable {
    let deviceID: String
    let alias: String
    let platform: String
    let status: String
    let clientVersion: String?
    let localBaseURL: String?
    let createdAt: FlexibleDate?
    let updatedAt: FlexibleDate?
    let lastRemoteAccessAt: FlexibleDate?

    var id: String { deviceID }
    var isOnline: Bool { status == "online" }

    /// 平台 → SF Symbol。
    var symbolName: String {
        switch platform {
        case "darwin": "laptopcomputer"
        case "win32": "pc"
        case "linux": "server.rack"
        default: "desktopcomputer"
        }
    }

    enum CodingKeys: String, CodingKey {
        case alias, platform, status
        case deviceID = "device_id"
        case clientVersion = "client_version"
        case localBaseURL = "local_base_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastRemoteAccessAt = "last_remote_access_at"
    }
}

struct RemoteDeviceList: Decodable, Sendable {
    let devices: [RemoteDevice]
    let maxDevices: Int?

    enum CodingKeys: String, CodingKey {
        case devices
        case maxDevices = "max_devices"
    }
}

// MARK: - 本地服务元信息

struct ServerMeta: Decodable, Sendable {
    let serverVersion: String
    let serverID: String?
    let backend: String?
    let dangerousBypassAuth: Bool?
    let capabilities: Capabilities?

    struct Capabilities: Decodable, Sendable {
        var websocket = false
        var fileUpload = false
        var fsQuery = false
        var mcp = false
        var tasks = false
        var terminal = false

        enum CodingKeys: String, CodingKey {
            case websocket, mcp, tasks, terminal
            case fileUpload = "file_upload"
            case fsQuery = "fs_query"
        }
    }

    enum CodingKeys: String, CodingKey {
        case backend, capabilities
        case serverVersion = "server_version"
        case serverID = "server_id"
        case dangerousBypassAuth = "dangerous_bypass_auth"
    }
}

// MARK: - 会话

struct SessionSummary: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let workspaceID: String?
    let title: String?
    let createdAt: FlexibleDate?
    let updatedAt: FlexibleDate?
    let busy: Bool
    let mainTurnActive: Bool?
    let pendingInteraction: PendingInteraction
    let lastTurnReason: String?
    let archived: Bool?
    let lastPrompt: String?
    let metadata: Metadata?
    let usage: Usage?

    enum PendingInteraction: String, Decodable, Sendable {
        case none, approval, question

        /// 未知取值不该让整个列表解码失败。
        init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = PendingInteraction(rawValue: raw) ?? .none
        }
    }

    struct Metadata: Decodable, Hashable, Sendable {
        let cwd: String
    }

    struct Usage: Decodable, Hashable, Sendable {
        let inputTokens: Int?
        let outputTokens: Int?
        let contextTokens: Int?
        let contextLimit: Int?
        let totalCostUSD: Double?
        let turnCount: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case contextTokens = "context_tokens"
            case contextLimit = "context_limit"
            case totalCostUSD = "total_cost_usd"
            case turnCount = "turn_count"
        }
    }

    /// 列表里显示的标题：没有标题就退回最后一条 prompt，再退回 cwd 的目录名。
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        if let lastPrompt, !lastPrompt.isEmpty { return lastPrompt }
        if let cwd = metadata?.cwd { return (cwd as NSString).lastPathComponent }
        return "未命名会话"
    }

    var folderName: String? {
        guard let cwd = metadata?.cwd else { return nil }
        return (cwd as NSString).lastPathComponent
    }

    enum CodingKeys: String, CodingKey {
        case id, title, busy, archived, metadata, usage
        case workspaceID = "workspace_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case mainTurnActive = "main_turn_active"
        case pendingInteraction = "pending_interaction"
        case lastTurnReason = "last_turn_reason"
        case lastPrompt = "last_prompt"
    }
}

struct SessionList: Decodable, Sendable {
    let items: [SessionSummary]
    let hasMore: Bool?

    enum CodingKeys: String, CodingKey {
        case items
        case hasMore = "has_more"
    }
}

// MARK: - 权限确认

struct ApprovalRequest: Decodable, Identifiable, Sendable {
    let approvalID: String
    let sessionID: String
    let turnID: Int?
    let toolCallID: String
    let toolName: String
    let action: String
    let toolInputDisplay: JSONValue?
    let createdAt: FlexibleDate?
    let expiresAt: FlexibleDate?

    var id: String { approvalID }

    /// 按 `kind` 分的展示结构（command / diff / file_io …），卡片里再按官方规则归并。
    enum CodingKeys: String, CodingKey {
        case action
        case approvalID = "approval_id"
        case sessionID = "session_id"
        case turnID = "turn_id"
        case toolCallID = "tool_call_id"
        case toolName = "tool_name"
        case toolInputDisplay = "tool_input_display"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
}

struct ApprovalList: Decodable, Sendable {
    let items: [ApprovalRequest]
}

// MARK: - 提问（AskUserQuestion）

struct QuestionRequest: Decodable, Identifiable, Sendable {
    let questionID: String
    let sessionID: String?
    let toolCallID: String?
    let questions: [Question]

    var id: String { questionID }

    struct Question: Decodable, Identifiable, Sendable {
        let id: String
        let question: String
        let header: String?
        let body: String?
        let options: [Option]
        let multiSelect: Bool
        let allowOther: Bool
        let otherLabel: String?

        enum CodingKeys: String, CodingKey {
            case id, question, header, body, options
            case multiSelect = "multi_select"
            case allowOther = "allow_other"
            case otherLabel = "other_label"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            question = (try? c.decode(String.self, forKey: .question)) ?? ""
            header = try? c.decodeIfPresent(String.self, forKey: .header)
            body = try? c.decodeIfPresent(String.self, forKey: .body)
            options = (try? c.decodeIfPresent([Option].self, forKey: .options)) ?? []
            multiSelect = (try? c.decodeIfPresent(Bool.self, forKey: .multiSelect)) ?? false
            allowOther = (try? c.decodeIfPresent(Bool.self, forKey: .allowOther)) ?? false
            otherLabel = try? c.decodeIfPresent(String.self, forKey: .otherLabel)
        }
    }

    struct Option: Decodable, Identifiable, Sendable {
        let id: String
        let label: String
        let description: String?
        let recommended: Bool

        enum CodingKeys: String, CodingKey {
            case id, label, description, recommended
            case isRecommended = "is_recommended"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            label = (try? c.decode(String.self, forKey: .label)) ?? ""
            description = try? c.decodeIfPresent(String.self, forKey: .description)
            let flagged = (try? c.decodeIfPresent(Bool.self, forKey: .recommended)) == true
                || (try? c.decodeIfPresent(Bool.self, forKey: .isRecommended)) == true
            // 官方：显式标记，或文案里带「推荐 / recommended」都算推荐项。
            let text = "\(label) \(description ?? "")".lowercased()
            recommended = flagged || text.contains("推荐") || text.contains("recommended") || text.contains("recommend")
        }
    }

    enum CodingKeys: String, CodingKey {
        case questions
        case questionID = "question_id"
        case sessionID = "session_id"
        case toolCallID = "tool_call_id"
    }
}

struct QuestionList: Decodable, Sendable {
    let items: [QuestionRequest]
}

/// 每道题的答案，与网页端 `E5e` 同形。
enum QuestionAnswer: Encodable, Sendable, Equatable {
    case single(String)
    case multi([String])
    case other(String)
    case multiWithOther([String], String)

    private enum Keys: String, CodingKey {
        case kind, text
        case optionID = "option_id"
        case optionIDs = "option_ids"
        case otherText = "other_text"
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .single(id):
            try c.encode("single", forKey: .kind)
            try c.encode(id, forKey: .optionID)
        case let .multi(ids):
            try c.encode("multi", forKey: .kind)
            try c.encode(ids, forKey: .optionIDs)
        case let .other(text):
            try c.encode("other", forKey: .kind)
            try c.encode(text, forKey: .text)
        case let .multiWithOther(ids, text):
            try c.encode("multi_with_other", forKey: .kind)
            try c.encode(ids, forKey: .optionIDs)
            try c.encode(text, forKey: .otherText)
        }
    }

    /// 是否已作答（官方 `k(J)`）。
    var isAnswered: Bool {
        switch self {
        case .single: true
        case let .multi(ids): !ids.isEmpty
        case let .other(text): !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let .multiWithOther(ids, text): !ids.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

struct QuestionAnswerBody: Encodable, Sendable {
    let answers: [String: QuestionAnswer]
    var method = "click"
}

struct ApprovalDecisionBody: Encodable, Sendable {
    let decision: String
    var scope: String?
    var feedback: String?
    var selectedLabel: String?

    static func approved(forSession: Bool = false) -> Self {
        .init(decision: "approved", scope: forSession ? "session" : nil)
    }

    static func rejected(feedback: String? = nil) -> Self {
        .init(decision: "rejected", feedback: feedback)
    }

    enum CodingKeys: String, CodingKey {
        case decision, scope, feedback
        case selectedLabel = "selected_label"
    }
}

struct ApprovalResolveResult: Decodable, Sendable {
    let resolved: Bool
}

// MARK: - 发任务

struct PromptBody: Encodable, Sendable {
    let content: [Part]
    /// 与网页端 `submitPrompt` 一致：每条消息都带上当前的模型 / 思考强度 / 权限模式。
    var model: String?
    var thinking: String?
    var permissionMode: PermissionMode?

    enum CodingKeys: String, CodingKey {
        case content, model, thinking
        case permissionMode = "permission_mode"
    }

    enum Part: Encodable, Sendable {
        case text(String)
        /// 图片先上传，但仍用 image part 引用，保留模型的识图语义。
        case image(UploadedFile)
        /// 先 `POST /files` 上传拿到 id，再以 file part 引用（与网页端一致）。
        case file(UploadedFile)

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            switch self {
            case let .text(text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case let .image(file):
                try container.encode("image", forKey: .type)
                try container.encode(
                    ["kind": "file", "file_id": file.id],
                    forKey: .source
                )
                try container.encode(file.name, forKey: .name)
            case let .file(file):
                try container.encode("file", forKey: .type)
                try container.encode(file.id, forKey: .fileID)
                try container.encode(file.name, forKey: .name)
                try container.encode(file.mediaType, forKey: .mediaType)
                try container.encode(file.size, forKey: .size)
            }
        }

        private enum Keys: String, CodingKey {
            case type, text, source, name, size
            case fileID = "file_id"
            case mediaType = "media_type"
        }
    }

    /// 附件在前、文字在后，与网页端一致。
    static func make(text: String, images: [UploadedFile], files: [UploadedFile], config: AgentConfigPatch) -> Self {
        var parts = images.map(Part.image) + files.map(Part.file)
        if !text.isEmpty { parts.append(.text(text)) }
        // 空串服务端会拒（`thinking: Too small`），没选就不带。
        return .init(
            content: parts,
            model: config.model?.isEmpty == false ? config.model : nil,
            thinking: config.thinking?.isEmpty == false ? config.thinking : nil,
            permissionMode: config.permissionMode
        )
    }
}

struct PromptAccepted: Decodable, Sendable {
    let promptID: String?
    let userMessageID: String?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case status
        case promptID = "prompt_id"
        case userMessageID = "user_message_id"
    }
}

// MARK: - 会话运行态（composer 上的模式 / 模型 / 上下文圈）

/// 权限模式。标签与官方网页端 i18n 一致（注意 yolo 叫「必要时询问」、auto 才是「完全自动」）。
enum PermissionMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case manual, yolo, auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: "始终询问"
        case .yolo: "必要时询问"
        case .auto: "完全自动"
        }
    }

    var subtitle: String {
        switch self {
        case .manual: "仅自动读取，其余操作逐一向你确认"
        case .yolo: "常规操作自动完成，有风险时才问你"
        case .auto: "完全不打断，所有操作和判断自动完成"
        }
    }

    var symbolName: String {
        switch self {
        case .manual: "hand.raised"
        case .yolo: "checkmark.shield"
        case .auto: "bolt.shield"
        }
    }
}

/// `GET /sessions/{id}/status`。官方网页端 composer 的模型标签、思考强度、权限、上下文圈都读它。
struct SessionRuntimeStatus: Decodable, Sendable {
    let busy: Bool?
    let model: String?
    let thinkingLevel: String?
    let permission: PermissionMode?
    let planMode: Bool?
    let contextTokens: Int?
    let maxContextTokens: Int?
    let contextUsage: Double?

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        busy = try container.decodeIfPresent(Bool.self, forKey: .busy)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        thinkingLevel = try container.decodeIfPresent(String.self, forKey: .thinkingLevel)
        permission = (try? container.decodeIfPresent(String.self, forKey: .permission)).flatMap(PermissionMode.init)
        planMode = try container.decodeIfPresent(Bool.self, forKey: .planMode)
        contextTokens = try container.decodeIfPresent(Int.self, forKey: .contextTokens)
        maxContextTokens = try container.decodeIfPresent(Int.self, forKey: .maxContextTokens)
        contextUsage = try container.decodeIfPresent(Double.self, forKey: .contextUsage)
    }

    enum CodingKeys: String, CodingKey {
        case busy, model, permission
        case thinkingLevel = "thinking_level"
        case planMode = "plan_mode"
        case contextTokens = "context_tokens"
        case maxContextTokens = "max_context_tokens"
        case contextUsage = "context_usage"
    }
}

/// 写回会话配置：`POST /sessions/{id}/profile { agent_config: {...} }`，只带改动的字段。
/// 新建会话时也用同一个结构放进 `POST /sessions` 的 `agent_config`。
struct AgentConfigPatch: Encodable, Sendable {
    var model: String?
    var thinking: String?
    var permissionMode: PermissionMode?

    enum CodingKeys: String, CodingKey {
        case model, thinking
        case permissionMode = "permission_mode"
    }
}

// MARK: - 工作区（侧栏的文件夹）

/// `GET /workspaces`。侧栏按它分组，会话用 `workspace_id` 挂进来。
struct Workspace: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let root: String
    let name: String?
    let createdAt: FlexibleDate?
    let lastOpenedAt: FlexibleDate?
    let sessionCount: Int?

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return (root as NSString).lastPathComponent
    }

    enum CodingKeys: String, CodingKey {
        case id, root, name
        case createdAt = "created_at"
        case lastOpenedAt = "last_opened_at"
        case sessionCount = "session_count"
    }
}

struct WorkspaceList: Decodable, Sendable {
    let items: [Workspace]
}

/// `GET /fs:browse?path=`：某个目录下的条目（添加工作区时逐级浏览）。
struct FsBrowse: Decodable, Sendable {
    let path: String
    let parent: String?
    let entries: [Entry]

    struct Entry: Decodable, Identifiable, Hashable, Sendable {
        let name: String
        let path: String
        let isDir: Bool

        var id: String { path }

        enum CodingKeys: String, CodingKey {
            case name, path
            case isDir = "is_dir"
        }
    }

    enum CodingKeys: String, CodingKey { case path, parent, entries }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = (try? c.decode(String.self, forKey: .path)) ?? ""
        parent = try? c.decodeIfPresent(String.self, forKey: .parent)
        entries = (try? c.decodeIfPresent([Entry].self, forKey: .entries)) ?? []
    }
}

/// `POST /sessions/{id}/fs:list`：会话目录（workDir）里某一层的文件和文件夹。
/// `path` 都是相对 workDir 的，`"."` 是根目录；服务端已按 `.gitignore` 过滤、文件夹在前排好序。
struct FsList: Decodable, Sendable {
    let items: [FsEntry]
    let truncated: Bool

    enum CodingKeys: String, CodingKey { case items, truncated }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? c.decodeIfPresent([FsEntry].self, forKey: .items)) ?? []
        truncated = (try? c.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false
    }
}

struct FsEntry: Decodable, Identifiable, Hashable, Sendable {
    enum Kind: String, Decodable, Sendable { case file, directory, symlink }

    let path: String
    let name: String
    let kind: Kind
    let size: Int?
    let childCount: Int?
    let mime: String?
    let isBinary: Bool?

    var id: String { path }
    var isDirectory: Bool { kind == .directory }

    enum CodingKeys: String, CodingKey {
        case path, name, kind, size, mime
        case childCount = "child_count"
        case isBinary = "is_binary"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decode(String.self, forKey: .name)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .file
        size = try? c.decodeIfPresent(Int.self, forKey: .size)
        childCount = try? c.decodeIfPresent(Int.self, forKey: .childCount)
        mime = try? c.decodeIfPresent(String.self, forKey: .mime)
        isBinary = try? c.decodeIfPresent(Bool.self, forKey: .isBinary)
    }
}

extension FsEntry {
    /// 从对话里的文件提及还原：只知道路径和名字，大小等留空（太大时由 `fs:read` 的 41302 兜底）。
    init(path: String, name: String) {
        self.path = path
        self.name = name
        kind = .file
        size = nil
        childCount = nil
        mime = nil
        isBinary = nil
    }

    /// 网页端「提及」文件的写法（`rv`）：`[名字](相对路径)`。名字转义 `% & < > [ ] \` 和换行（`a6`），
    /// 路径逐段把 ASCII 里非 unreserved 的字符百分号编码，中文等原样保留（`i9e` / `ug`）。
    var mentionMarkdown: String {
        let label = name
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "&", with: "%26")
            .replacingOccurrences(of: "<", with: "%3C")
            .replacingOccurrences(of: ">", with: "%3E")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: "%0A")
            .replacingOccurrences(of: "\r", with: "%0D")
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func encode(_ segment: Substring) -> String {
            segment.unicodeScalars.map { scalar in
                scalar.value > 127 || unreserved.contains(scalar)
                    ? String(scalar)
                    : String(format: "%%%02X", scalar.value)
            }.joined()
        }
        var target = (isDirectory && !path.hasSuffix("/") ? path + "/" : path)
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(encode)
            .joined(separator: "/")
        if target.hasPrefix("//") { target = "/%2F" + target.dropFirst(2) }
        return "[\(label)](\(target))"
    }

}

/// `POST /sessions/{id}/fs:read`：文件开头的一段文本或 base64。
struct FsContent: Decodable, Sendable {
    let path: String
    let content: String
    let encoding: String
    let size: Int
    let truncated: Bool
    let mime: String?
    let isBinary: Bool

    enum CodingKeys: String, CodingKey {
        case path, content, encoding, size, truncated, mime
        case isBinary = "is_binary"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        content = try c.decode(String.self, forKey: .content)
        encoding = try c.decode(String.self, forKey: .encoding)
        size = try c.decode(Int.self, forKey: .size)
        truncated = (try? c.decodeIfPresent(Bool.self, forKey: .truncated)) ?? false
        mime = try? c.decodeIfPresent(String.self, forKey: .mime)
        isBinary = (try? c.decodeIfPresent(Bool.self, forKey: .isBinary)) ?? false
    }
}

/// `GET /fs:home`：那台电脑的主目录。
struct FsHome: Decodable, Sendable {
    let home: String
    let recentRoots: [String]?

    enum CodingKeys: String, CodingKey {
        case home
        case recentRoots = "recent_roots"
    }
}

// MARK: - 模型

/// `GET /models` 的一项。
struct ModelInfo: Decodable, Identifiable, Hashable, Sendable {
    let provider: String
    let model: String
    let displayName: String?
    let maxContextSize: Int?
    let capabilities: [String]?
    let supportEfforts: [String]?
    let defaultEffort: String?

    var id: String { model }
    var name: String { displayName ?? (model as NSString).lastPathComponent }
    var acceptsImages: Bool { capabilities?.contains("image_in") ?? false }
    var efforts: [String] { supportEfforts ?? [] }
    /// 属于「Kimi 订阅」组（排在最前、组名显示「Kimi 订阅」）。
    var isKimiSubscription: Bool { provider == KimiConfig.kimiSubscriptionProvider }
    /// 分组名：Kimi 订阅组用中文名，其他 provider 照原样显示（与网页端 `Bl` 一致）。
    var providerLabel: String { isKimiSubscription ? "Kimi 订阅" : provider }

    /// 思考方式，照网页端 `ov`：`always_thinking` 恒开；有 `thinking` 可开关；都没有则不思考。
    enum ThinkingKind { case alwaysOn, toggle, unsupported }

    var thinkingKind: ThinkingKind {
        let caps = capabilities ?? []
        if caps.contains("always_thinking") { return .alwaysOn }
        return caps.contains("thinking") ? .toggle : .unsupported
    }

    /// 可选的 `thinking` 取值，照网页端 `sv`：有强度时是强度（可关的模型前面加 `off`），
    /// 没强度时是 `on` / `off`。
    var thinkingOptions: [String] {
        switch (thinkingKind, efforts.isEmpty) {
        case (.alwaysOn, false): efforts
        case (_, false): ["off"] + efforts
        case (.alwaysOn, true): ["on"]
        case (.toggle, true): ["on", "off"]
        case (.unsupported, true): ["off"]
        }
    }

    /// 默认 `thinking`，照网页端 `z1`：不支持思考为 `off`；有强度取默认强度（没有就取中间那档）；否则 `on`。
    var defaultThinking: String {
        if thinkingKind == .unsupported { return "off" }
        guard !efforts.isEmpty else { return "on" }
        if let defaultEffort, efforts.contains(defaultEffort) { return defaultEffort }
        return efforts[efforts.count / 2]
    }

    /// 把任意取值落到这个模型支持的选项上（切模型时沿用原选择，不支持就回默认）。
    func normalizedThinking(_ value: String?) -> String {
        guard let value, thinkingOptions.contains(value) else { return defaultThinking }
        return value
    }

    enum CodingKeys: String, CodingKey {
        case provider, model, capabilities
        case displayName = "display_name"
        case maxContextSize = "max_context_size"
        case supportEfforts = "support_efforts"
        case defaultEffort = "default_effort"
    }
}

struct ModelList: Decodable, Sendable {
    let items: [ModelInfo]
}

/// `GET /config` 里只取默认模型。整个 config 含 provider 配置，别整体解码/打日志。
struct ServerConfigDefaults: Decodable, Sendable {
    let defaultModel: String?
    /// 新会话默认权限；没设时网页端按「始终询问」（manual）显示。
    let defaultPermissionMode: PermissionMode?
    /// 新会话默认思考：`{enabled}` 或 `{enabled, effort}`。
    let thinking: ThinkingConfig?

    struct ThinkingConfig: Codable, Sendable, Equatable {
        let enabled: Bool
        var effort: String?

        /// 网页端 `bpe`：off → 关、on → 开（不带强度）、其余是强度名。
        init(option: String) {
            enabled = option != "off"
            effort = option == "off" || option == "on" ? nil : option
        }
    }

    enum CodingKeys: String, CodingKey {
        case defaultModel = "default_model"
        case defaultPermissionMode = "default_permission_mode"
        case thinking
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultModel = try? c.decodeIfPresent(String.self, forKey: .defaultModel)
        defaultPermissionMode = try? c.decodeIfPresent(PermissionMode.self, forKey: .defaultPermissionMode)
        thinking = try? c.decodeIfPresent(ThinkingConfig.self, forKey: .thinking)
    }

    /// 网页端 `yT(...) ?? z1(model)`：配置里的思考在这个模型上可用就用它，否则用模型默认。
    func thinkingOption(for model: ModelInfo) -> String {
        if let thinking {
            if !thinking.enabled, model.thinkingOptions.contains("off") { return "off" }
            if let effort = thinking.effort, model.thinkingOptions.contains(effort) { return effort }
        }
        return model.defaultThinking
    }
}

/// `POST /config` 只带要改的字段（网页端 `setConfig`）。
struct ServerConfigPatch: Encodable, Sendable {
    var defaultModel: String?
    var defaultPermissionMode: PermissionMode?
    var thinking: ServerConfigDefaults.ThinkingConfig?

    enum CodingKeys: String, CodingKey {
        case defaultModel = "default_model"
        case defaultPermissionMode = "default_permission_mode"
        case thinking
    }
}

// MARK: - 模型供应商（照网页端「供应商管理」）

/// `GET /providers` 的一项。`GET /providers/{id}` 额外带 `api_key`（编辑表单预填用）。
struct ProviderItem: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let type: String
    let baseURL: String?
    let defaultModel: String?
    let hasAPIKey: Bool
    let status: Status
    let models: [String]
    let apiKey: String?

    enum Status: String, Decodable, Sendable {
        case connected, error, unconfigured
    }

    /// Kimi 订阅：OAuth 托管，不能在这里改（网页端 `oZ`）。
    var isManaged: Bool { id == KimiConfig.kimiSubscriptionProvider && type == "kimi" }
    var title: String { isManaged ? "Kimi 订阅" : id }

    enum CodingKeys: String, CodingKey {
        case id, type, status, models
        case baseURL = "base_url"
        case defaultModel = "default_model"
        case hasAPIKey = "has_api_key"
        case apiKey = "api_key"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        baseURL = try? c.decodeIfPresent(String.self, forKey: .baseURL)
        defaultModel = try? c.decodeIfPresent(String.self, forKey: .defaultModel)
        hasAPIKey = (try? c.decode(Bool.self, forKey: .hasAPIKey)) ?? false
        status = (try? c.decode(Status.self, forKey: .status)) ?? .unconfigured
        models = (try? c.decodeIfPresent([String].self, forKey: .models)) ?? []
        apiKey = try? c.decodeIfPresent(String.self, forKey: .apiKey)
    }
}

struct ProviderList: Decodable, Sendable {
    let items: [ProviderItem]
}

/// API 协议（`providerWireTypeSchema`），顺序同网页端下拉。
enum ProviderWireType: String, CaseIterable, Identifiable, Sendable {
    case kimi, openai
    case openaiResponses = "openai_responses"
    case anthropic
    case googleGenAI = "google-genai"
    case vertexAI = "vertexai"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .kimi: "Kimi"
        case .openai: "OpenAI"
        case .openaiResponses: "OpenAI Responses"
        case .anthropic: "Anthropic"
        case .googleGenAI: "Google GenAI"
        case .vertexAI: "Vertex AI"
        }
    }

    static func title(for raw: String?) -> String {
        raw.flatMap(ProviderWireType.init(rawValue:))?.title ?? raw ?? "未知协议"
    }
}

/// `GET /config` 里 `models` 段的一项（键名是驼峰）。编辑供应商时用它还原模型表（网页端 `Tx`）。
struct ConfigModelEntry: Decodable, Sendable {
    let provider: String
    let model: String
    let maxContextSize: Int?
    let displayName: String?
    let capabilities: [String]?
    let supportEfforts: [String]?
    let adaptiveThinking: Bool?
}

/// 只解码 `GET /config` 的 `models` 段；单项坏了跳过，不影响其他。
struct ServerConfigModels: Decodable, Sendable {
    let items: [ConfigModelEntry]

    private struct Lenient: Decodable {
        let value: ConfigModelEntry?
        init(from decoder: any Decoder) throws { value = try? ConfigModelEntry(from: decoder) }
    }

    enum CodingKeys: String, CodingKey { case models }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = (try? c.decodeIfPresent([String: Lenient].self, forKey: .models)) ?? [:]
        items = raw.values.compactMap(\.value)
    }
}

/// 新建 / 整体替换供应商时的一个模型（`createProviderModelSchema`）。
struct ProviderModelInput: Encodable, Sendable {
    let model: String
    let maxContextSize: Int
    let displayName: String?
    let capabilities: [String]?
    let supportEfforts: [String]?
    let adaptiveThinking: Bool?

    enum CodingKeys: String, CodingKey {
        case model
        case maxContextSize = "max_context_size"
        case displayName = "display_name"
        case capabilities
        case supportEfforts = "support_efforts"
        case adaptiveThinking = "adaptive_thinking"
    }
}

/// `POST /providers`（带 `id`）与 `PUT /providers/{id}`（改名时带 `new_id`）的请求体。
/// `api_key`：不带 = 保留原值，`""` = 清空，其他 = 替换。
struct ProviderWriteBody: Encodable, Sendable {
    var id: String?
    var newID: String?
    let type: String
    var apiKey: String?
    var baseURL: String?
    var defaultModel: String?
    let models: [ProviderModelInput]

    enum CodingKeys: String, CodingKey {
        case id, type, models
        case newID = "new_id"
        case apiKey = "api_key"
        case baseURL = "base_url"
        case defaultModel = "default_model"
    }
}

/// `GET /catalog/providers`：models.dev 目录里的供应商。
struct CatalogProvider: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let wireType: String?
    let baseURL: String?
    let needsBaseURL: Bool
    let rejected: Bool
    let rejectReason: String?
    let modelCount: Int

    enum CodingKeys: String, CodingKey {
        case id, name, rejected, models
        case wireType = "wire_type"
        case baseURL = "base_url"
        case needsBaseURL = "needs_base_url"
        case rejectReason = "reject_reason"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? id
        wireType = try? c.decodeIfPresent(String.self, forKey: .wireType)
        baseURL = try? c.decodeIfPresent(String.self, forKey: .baseURL)
        needsBaseURL = (try? c.decode(Bool.self, forKey: .needsBaseURL)) ?? false
        rejected = (try? c.decode(Bool.self, forKey: .rejected)) ?? false
        rejectReason = try? c.decodeIfPresent(String.self, forKey: .rejectReason)
        modelCount = (try? c.decodeIfPresent([JSONValue].self, forKey: .models))?.count ?? 0
    }

    /// 不能导入的原因（网页端 `catalog.rejectReason`）。
    var rejectText: String {
        switch rejectReason {
        case "unknown-explicit-type": "协议不受支持"
        case "proprietary-sdk": "私有协议，无法导入"
        case "empty-base-url": "Base URL 为空"
        case "placeholder-base-url": "端点包含环境变量占位符"
        default: "不可导入"
        }
    }
}

struct CatalogProviderList: Decodable, Sendable {
    let items: [CatalogProvider]
}

/// `POST /providers/{id}:refresh` 的结果里只关心失败项。
struct ProviderRefreshResult: Decodable, Sendable {
    struct Failure: Decodable, Sendable {
        let provider: String
        let reason: String
    }

    let failed: [Failure]?
}

extension String {
    /// `low` → `Low`，composer 上的「K3·Low」。
    var effortLabel: String {
        prefix(1).uppercased() + dropFirst()
    }

    /// 模型面板「思考」菜单里的选项名：`on` / `off` 用中文，强度沿用 `Low` / `High` / `Max`。
    var thinkingOptionLabel: String {
        switch self {
        case "on": "开启"
        case "off": "关闭"
        default: effortLabel
        }
    }
}

// MARK: - 账号（侧栏底部的头像 + 名字）

/// `GET /oauth/userinfo` → `{ kind, userInfo: { nickname, avatar, … } }`。
/// 里面还有手机号等个人信息，**只解码要显示的两个字段**。
struct UserInfoResponse: Decodable, Sendable {
    let userInfo: KimiUser?
}

struct KimiUser: Decodable, Sendable {
    let nickname: String?
    let avatar: String?

    var displayName: String {
        if let nickname, !nickname.isEmpty { return nickname }
        return "Kimi 用户"
    }

    var avatarURL: URL? { avatar.flatMap(URL.init(string:)) }
}

// MARK: - 订阅剩余用量（会话右上角 ⋯）

/// `GET /oauth/usage` → `{ kind, quota: { usages: { limit5h?, limit7d?, monthTotal?, monthCode? } } }`。
/// 与官方网页端一致，按 limit5h → limit7d → monthTotal 的顺序展示存在的那几项。
/// 界面显示的是**剩余**（1 - usedRatio）。
struct PlanUsage: Decodable, Sendable {
    let quota: Quota?

    struct Quota: Decodable, Sendable {
        let usages: [String: Entry]?
    }

    struct Entry: Decodable, Sendable {
        let usedRatio: Double
        let resetAt: FlexibleDate?
    }

    struct Row: Identifiable, Sendable {
        let id: String
        let title: String
        let remainingRatio: Double
        let resetAt: Date?
    }

    var rows: [Row] {
        let order: [(key: String, title: String)] = [
            ("limit5h", "5 小时"),
            ("limit7d", "每周"),
            ("monthTotal", "每月"),
        ]
        return order.compactMap { item in
            guard let entry = quota?.usages?[item.key] else { return nil }
            return Row(
                id: item.key,
                title: item.title,
                remainingRatio: 1 - min(max(entry.usedRatio, 0), 1),
                resetAt: entry.resetAt?.date
            )
        }
    }
}

// MARK: - 附件

/// transcript 的图片来源；历史图片通过会话媒体接口读取。
enum AttachmentSource: Hashable, Sendable {
    case file(String)
    case sessionMedia(String)
    case url(URL)

    init?(_ value: JSONValue?) {
        switch value?["kind"]?.stringValue {
        case "file":
            guard let id = value?["fileId"]?.stringValue else { return nil }
            self = .file(id)
        case "session_media":
            guard let id = value?["fileId"]?.stringValue else { return nil }
            self = .sessionMedia(id)
        case "url":
            guard let raw = value?["url"]?.stringValue, let url = URL(string: raw) else { return nil }
            self = .url(url)
        default: return nil
        }
    }

    var cacheKey: String {
        switch self {
        case let .file(id): "file:\(id)"
        case let .sessionMedia(id): "media:\(id)"
        case let .url(url): "url:\(url.absoluteString)"
        }
    }
}

/// composer 里待发送的附件。图片和文件均在发送时先上传。
enum Attachment: Identifiable, Sendable {
    /// 给 multipart 与隧道 HTTP 头留出余量（隧道单请求上限 10 MiB）。
    static let maxUploadBytes = 9 * 1024 * 1024

    case image(id: UUID = UUID(), jpeg: Data, thumbnail: Data)
    case file(id: UUID = UUID(), name: String, mediaType: String, data: Data)
    /// 电脑上会话目录里的文件（文件预览「添加到会话」）：不上传，发送时以 `[名字](路径)` 提及写进正文。
    case mention(id: UUID = UUID(), entry: FsEntry)

    var id: UUID {
        switch self {
        case let .image(id, _, _): id
        case let .file(id, _, _, _): id
        case let .mention(id, _): id
        }
    }
}

/// `POST /files` 的返回。
struct UploadedFile: Decodable, Sendable {
    let id: String
    let name: String
    let mediaType: String
    let size: Int

    enum CodingKeys: String, CodingKey {
        case id, name, size
        case mediaType = "media_type"
    }
}
