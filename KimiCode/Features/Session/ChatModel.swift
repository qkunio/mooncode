import Foundation
import Observation
import UIKit

/// composer 上那一排的选择：权限模式 / 模型 / 思考。新会话会继承上一次的选择。
struct ComposerConfig: Codable, Equatable, Sendable {
    var permission: PermissionMode
    var modelID: String?
    /// 请求里的 `thinking`：强度名（`low`…）或 `on` / `off`。字段名沿用旧的，免得丢掉已存的选择。
    var effort: String?

    var patch: AgentConfigPatch {
        AgentConfigPatch(model: modelID, thinking: effort, permissionMode: permission)
    }
}

/// 主页正在看的那条对话。
///
/// 两种形态：
///   - 已有会话：`session != nil`
///   - 新对话草稿：只知道在哪个文件夹（工作区），第一条消息发出时才 `POST /sessions`
///
/// 运行时与官方网页端一致：
///   - 正文：`GET /transcript` 首屏 + WS `subscribe_v2` 逐字增量，本地按 apply.ts 应用
///   - 是否在跑 / 重试 / 中断 / 失败：transcript 的 `meta.activity` 与 `meta.agent.phase`
///   - 权限确认、提问：REST 拉 pending 列表，WS 有相关事件时重拉
///   - 只做「发送」和「停止」：忙时不发（不排队），停止走 `:abort`
@MainActor
@Observable
final class ChatModel {
    private(set) var session: SessionSummary?
    let workspace: Workspace?

    private(set) var transcript = TranscriptState()
    /// 由 transcript 派生的对话流（用户气泡 / 助手消息 / 压缩分隔）。
    private(set) var entries: [ChatEntry] = []
    /// 正文每变一次加一，给「停在底部就跟随」用。
    private(set) var contentVersion = 0
    private(set) var pendingApprovals: [ApprovalRequest] = []
    private(set) var pendingQuestions: [QuestionRequest] = []
    private(set) var isLoading = false
    /// 在后台待超过 30 秒回来：这段时间连接多半断过，屏幕上的正文不再可信，先换成骨架屏，重拉完再显示。
    private(set) var isRefreshingStale = false
    private(set) var isLoadingOlder = false
    private(set) var isSending = false
    /// `POST /prompts` 已经返回、但正文里这一轮还没开始跑：接住这段空档，「请求中…」不中途消失。
    private var awaitingTurn = false
    private var awaitingTurnTimeout: Task<Void, Never>?
    private(set) var connectionState: ConnectionState = .idle
    var errorMessage: String?
    /// 撤销后放回输入框的原文（官方：「已撤销，原文已放回输入框」）。
    var restoredDraft: String?

    // composer
    private(set) var config: ComposerConfig
    private(set) var contextTokens: Int?
    private(set) var maxContextTokens: Int?
    private(set) var contextUsage: Double?
    var attachments: [Attachment] = []

    /// 正在发送但还没出现在正文里的用户消息，先乐观显示。
    private(set) var optimisticPrompts: [OptimisticPrompt] = []

    enum ConnectionState: Sendable, Equatable {
        case idle
        case connecting
        case live
        case offline(String)
    }

    struct OptimisticPrompt: Identifiable, Sendable {
        let id = UUID()
        let text: String
        let attachmentCount: Int
        var failed = false
    }

    private let client: any KapServicing
    private let endpoint: Endpoint
    private let tokenProvider: @Sendable () async -> String?
    /// 是否开 WS 事件流。体验模式的内存后端没有事件流，一轮还在跑时改成轮询。
    private let liveUpdates: Bool
    private let onSessionCreated: (SessionSummary) -> Void
    private let onConfigChanged: (ComposerConfig) -> Void

    /// 草稿刚建成会话、第一条消息还没发出：服务端此时还是默认配置（建会话时不采纳 agent_config），
    /// 别让它覆盖 composer 上选好的值 —— 第一条消息会把模型 / 思考强度 / 权限一起带上。
    private var holdsLocalConfig = false
    /// 现场量到的思考时长（官方 `thinkingTiming`），只在本次打开期间有效。
    private var thinkingTiming: [String: ThinkingTiming] = [:]

    private var stream: EventStream?
    private var streamTask: Task<Void, Never>?
    private var foregroundTask: Task<Void, Never>?
    private var backgroundTask: Task<Void, Never>?
    /// 进后台时向系统要的那段执行时间（约 30 秒）：短暂切出去时连接不断，正文照常往下收。
    private var backgroundTimeID: UIBackgroundTaskIdentifier = .invalid
    private var backgroundedAt: ContinuousClock.Instant?
    /// 后台时间用完了（系统马上要挂起 App），连接多半会被掐掉。
    private var backgroundTimeExpired = false
    /// 在后台待了超过这么久（约等于系统给的后台时间），回来就不信任旧连接和旧正文：直接重连、骨架屏重拉。
    private static let backgroundGrace: Duration = .seconds(30)
    /// 正在全量重拉的次数。期间收到的正文增量先存着，拉完再按顺序补上（网页端 `buffered`），
    /// 否则会先应用到旧数据上、再被重拉结果整个盖掉。
    private var activeReloads = 0
    private var bufferedTranscript: [TranscriptWireEvent] = []
    /// 连续收到「空快照」的次数，用来退避重拉（网页端 `emptyResetRetries`）。
    private var emptyResetRetries = 0
    private let interactionRefresh = RefreshScheduler()
    private let transcriptReload = RefreshScheduler()

    var isDraft: Bool { session == nil }
    var sessionID: String? { session?.id }

    var title: String {
        if let session { return session.displayTitle }
        return workspace?.displayName ?? "新对话"
    }

    init(
        session: SessionSummary?,
        workspace: Workspace?,
        config: ComposerConfig,
        client: any KapServicing,
        endpoint: Endpoint,
        tokenProvider: @escaping @Sendable () async -> String?,
        liveUpdates: Bool,
        onSessionCreated: @escaping (SessionSummary) -> Void,
        onConfigChanged: @escaping (ComposerConfig) -> Void
    ) {
        self.session = session
        self.workspace = workspace
        self.config = config
        self.client = client
        self.endpoint = endpoint
        self.tokenProvider = tokenProvider
        self.liveUpdates = liveUpdates
        self.onSessionCreated = onSessionCreated
        self.onConfigChanged = onConfigChanged
    }

    // MARK: 运行态（全部从 transcript 派生）

    /// 本轮在跑（`meta.activity == "turn"`），或刚发出去还没回显。
    var isWorking: Bool { transcript.isTurnActive || isSending || awaitingTurn }

    /// composer 用：忙时只给「停止」。
    var isBusy: Bool { isWorking }

    /// `phase.kind == "retrying"`：「模型请求失败，正在重试（第 n/max 次）…」
    var retry: (next: Int, max: Int)? {
        guard let phase = transcript.phase, phase["kind"]?.stringValue == "retrying" else { return nil }
        return (phase["nextAttempt"]?.intValue ?? 0, phase["maxAttempts"]?.intValue ?? 0)
    }

    /// 上一轮怎么结束的：`cancelled` 画「已手动终止」，`failed` 画失败卡片 + 继续。
    enum TurnEnd: Equatable {
        case cancelled
        case failed(maxSteps: Bool, message: String?, meta: String?)
    }

    var lastTurnEnd: TurnEnd? {
        guard !isWorking, let last = transcript.turns.last else { return nil }
        let phase = transcript.phase
        let phaseKind = phase?["kind"]?.stringValue
        let reason = phase?["reason"]?.stringValue
        let matchesLast = phase?["turnId"]?.intValue == nil || phase?["turnId"]?.intValue == last.ordinal
        if phaseKind == "interrupted", matchesLast {
            switch reason {
            case "aborted": return .cancelled
            case "max_steps": return .failed(maxSteps: true, message: phase?["message"]?.stringValue, meta: "loop.max_steps_exceeded")
            default: return .failed(maxSteps: false, message: phase?["message"]?.stringValue ?? last.error, meta: nil)
            }
        }
        switch last.state {
        case "cancelled":
            return .cancelled
        case "failed":
            let maxSteps = last.error?.contains("maxSteps") == true || last.error?.contains("max_steps") == true
            return .failed(maxSteps: maxSteps, message: last.error, meta: maxSteps ? "loop.max_steps_exceeded" : nil)
        default:
            return nil
        }
    }

    /// 最近一次压缩开始了、还没完成：「正在压缩上下文…」
    var isCompacting: Bool {
        for item in transcript.items.reversed() {
            guard case let .marker(marker) = item, marker.marker == "compaction" else { continue }
            return marker.payload?["phase"]?.stringValue == "started"
        }
        return false
    }

    // MARK: 生命周期

    func start() async {
        guard let sessionID else { return }
        await reload()
        // 没有事件流的后端（体验模式）：reload 拿到的就是全部，不用再连 WS。
        guard liveUpdates else {
            connectionState = .live
            return
        }
        guard streamTask == nil else { return }
        connectionState = .connecting
        let stream = EventStream(endpoint: endpoint, tokenProvider: tokenProvider)
        self.stream = stream
        let signals = await stream.start()
        // 会话事件（权限确认 / 提问的通知）+ 正文增量。
        await stream.subscribe(to: sessionID)
        await stream.subscribeTranscript(sessionID, since: transcript.seq)
        streamTask = Task { [weak self] in
            for await signal in signals {
                await self?.handle(signal)
            }
        }
        // 进后台：先要一段执行时间，期间连接不断。
        backgroundTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didEnterBackgroundNotification) {
                self?.beginBackgroundTime()
            }
        }
        // 回到前台：在后台待超了（或后台时间用完被挂起过）就直接重连；否则检查一下连接，断了才重连（网页端 focus 时同样处理）。
        // 从控制中心、通知栏回来也会走到这里，那时没进过后台，只做检查。
        foregroundTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                await self?.returnToForeground()
            }
        }
    }

    private func beginBackgroundTime() {
        endBackgroundTime()
        backgroundedAt = .now
        backgroundTimeExpired = false
        backgroundTimeID = UIApplication.shared.beginBackgroundTask(withName: "kimi.stream") { [weak self] in
            // 系统在时间到之前回调这里，必须马上把这段时间还回去，否则 App 会被杀掉。
            MainActor.assumeIsolated {
                self?.backgroundTimeExpired = true
                self?.endBackgroundTime()
            }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTimeID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTimeID)
        backgroundTimeID = .invalid
    }

    private func returnToForeground() async {
        let away = backgroundedAt.map { ContinuousClock.now - $0 }
        let expired = backgroundTimeExpired
        backgroundedAt = nil
        backgroundTimeExpired = false
        endBackgroundTime()
        if expired || (away ?? .zero) > Self.backgroundGrace {
            await stream?.reconnectNow()
            // 体验模式没有连接可断，正文一直是对的，不用重拉。
            guard liveUpdates, sessionID != nil else { return }
            isRefreshingStale = true
            scheduleTranscriptReload(after: .zero)
        } else {
            await stream?.reconnectIfStale()
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        foregroundTask?.cancel()
        foregroundTask = nil
        backgroundTask?.cancel()
        backgroundTask = nil
        endBackgroundTime()
        interactionRefresh.cancel()
        transcriptReload.cancel()
        let stream = stream
        self.stream = nil
        Task { await stream?.stop() }
    }

    // MARK: 读

    /// 全量重拉：正文尾部一页 + 待处理的确认/提问 + composer 状态。
    func reload() async {
        guard let sessionID else { return }
        // 只在屏幕上什么都没有时显示骨架屏（打开已有会话的首屏）。草稿发出第一条后建会话再重拉，
        // 那条消息已经乐观显示着，不该在它上面再冒骨架。
        isLoading = isRefreshingStale || (entries.isEmpty && optimisticPrompts.isEmpty)
        activeReloads += 1
        defer {
            isLoading = false
            activeReloads -= 1
            if activeReloads == 0 {
                let pending = bufferedTranscript
                bufferedTranscript = []
                for event in pending { apply(event) }
            }
        }
        do {
            async let page = client.transcript(sessionID)
            async let status = client.status(sessionID)
            transcript = TranscriptState(page: try await page)
            rebuild()
            // 正文一到就撤骨架：后面的 status / 确认拉取还在路上，不该挡着已到的内容。
            isLoading = false
            isRefreshingStale = false
            if let seq = transcript.seq { await stream?.noteTranscriptSeq(sessionID, seq: seq) }
            apply(try await status)
            await refreshInteractions()
            errorMessage = nil

            // 没有事件流的后端（体验模式）不会推增量：一轮还在跑时自己轮询，直到它落完。
            if !liveUpdates, transcript.isTurnActive {
                transcriptReload.schedule(after: .milliseconds(400)) { [weak self] in
                    await self?.reload()
                }
            }
        } catch {
            // 切换会话/停止订阅取消的是读取任务，不代表出错。
            guard !Task.isCancelled, !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled else { return }
            // 重拉失败就把旧正文放回来，总比一直挂着骨架强。
            isRefreshingStale = false
            errorMessage = error.localizedDescription
        }
    }

    /// 「加载更早的消息」。
    func loadOlder() async {
        guard let sessionID, transcript.hasMoreOlder, !isLoadingOlder,
              let first = transcript.turns.first else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let page = try await client.transcript(sessionID, beforeTurn: first.turnId)
            transcript.prepend(older: page)
            rebuild()
        } catch {
            guard !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func refreshInteractions() async {
        guard let sessionID else { return }
        async let approvals = client.pendingApprovals(sessionID)
        async let questions = client.pendingQuestions(sessionID)
        if let approvals = try? await approvals { pendingApprovals = approvals.items }
        if let questions = try? await questions { pendingQuestions = questions.items }
    }

    private func scheduleInteractionRefresh() {
        interactionRefresh.schedule(after: .milliseconds(150)) { [weak self] in
            await self?.refreshInteractions()
        }
    }

    private func apply(_ status: SessionRuntimeStatus) {
        contextTokens = status.contextTokens
        maxContextTokens = status.maxContextTokens
        contextUsage = status.contextUsage
        guard !holdsLocalConfig else { return }
        config = ComposerConfig(
            permission: status.permission ?? config.permission,
            modelID: status.model.nonEmpty ?? config.modelID,
            effort: status.thinkingLevel.nonEmpty ?? config.effort
        )
    }

    /// `meta.agent` 里带着模型、思考强度、权限和上下文用量，随正文一起推过来。
    private func applyAgentMeta() {
        guard let agent = transcript.meta["agent"] else { return }
        if let tokens = agent["contextTokens"]?.intValue { contextTokens = tokens }
        if let max = agent["maxContextTokens"]?.intValue { maxContextTokens = max }
        if case let .number(usage)? = agent["contextUsage"] { contextUsage = usage }
        guard !holdsLocalConfig else { return }
        var next = config
        if let raw = agent["permission"]?.stringValue, let permission = PermissionMode(rawValue: raw) {
            next.permission = permission
        }
        if let model = agent["model"]?.stringValue, !model.isEmpty { next.modelID = model }
        if let effort = agent["thinkingEffort"]?.stringValue, !effort.isEmpty { next.effort = effort }
        if next != config { config = next }
    }

    private func rebuild() {
        ConversationBuilder.updateTiming(&thinkingTiming, state: transcript)
        entries = ConversationBuilder.build(transcript, timing: thinkingTiming)
        contentVersion &+= 1
        applyAgentMeta()
        // 已经出现在正文里的 prompt 就不用再乐观显示了。
        let known = Set(entries.compactMap { entry -> String? in
            if case let .user(user) = entry.kind { return user.text }
            return nil
        })
        // 正文里的文件提及被拆成了附件，比对前乐观那条也要同样拆掉。
        optimisticPrompts.removeAll {
            !$0.failed && known.contains(ConversationBuilder.splitMentions($0.text).text)
        }
        // 这一轮已经跑起来了，或者跑得太快、回复已经落进正文（体验模式轮询时会这样）：空档结束。
        if awaitingTurn, transcript.isTurnActive || (optimisticPrompts.isEmpty && entries.last?.isAssistant == true) {
            setAwaitingTurn(false)
        }
    }

    /// 兜底 15s：服务端迟迟不报这一轮开始（排队、断线）时不让「请求中…」一直挂着。
    private func setAwaitingTurn(_ value: Bool) {
        awaitingTurn = value
        awaitingTurnTimeout?.cancel()
        awaitingTurnTimeout = nil
        guard value else { return }
        awaitingTurnTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.awaitingTurn = false
        }
    }

    /// 侧栏改了名：换上服务端回来的会话摘要（导航栏标题跟着变）。
    func replaceSession(_ updated: SessionSummary) {
        guard updated.id == session?.id else { return }
        session = updated
    }

    // MARK: composer 配置

    func setPermission(_ permission: PermissionMode) async {
        await update { $0.permission = permission }
    }

    func setModel(_ model: ModelInfo, effort: String?) async {
        await update {
            $0.modelID = model.model
            $0.effort = effort
        }
    }

    private func update(_ change: (inout ComposerConfig) -> Void) async {
        let previous = config
        var next = config
        change(&next)
        guard next != previous else { return }
        config = next
        onConfigChanged(next)
        // 草稿还没有会话，等第一条消息时连同配置一起建。
        guard let sessionID else { return }
        do {
            try await client.updateProfile(sessionID, agentConfig: diff(from: previous, to: next))
            if let status = try? await client.status(sessionID) { apply(status) }
        } catch {
            config = previous
            errorMessage = error.localizedDescription
        }
    }

    private func diff(from old: ComposerConfig, to new: ComposerConfig) -> AgentConfigPatch {
        AgentConfigPatch(
            model: new.modelID != old.modelID ? new.modelID : nil,
            thinking: new.effort != old.effort || new.modelID != old.modelID ? new.effort : nil,
            permissionMode: new.permission != old.permission ? new.permission : nil
        )
    }

    // MARK: 写

    /// 文件预览「添加到会话」：同一个文件只加一次。
    func addMention(_ entry: FsEntry) {
        let exists = attachments.contains {
            if case let .mention(_, existing) = $0 { return existing.path == entry.path }
            return false
        }
        if !exists { attachments.append(.mention(entry: entry)) }
    }

    /// 发送。不做排队：本轮还在跑时直接忽略（composer 此时只显示「停止」）。
    func send(_ text: String) async {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var pending = attachments
        guard !trimmed.isEmpty || !pending.isEmpty, !isWorking else { return }

        // 文件提及不上传，照网页端写进正文开头。
        let mentions = pending.compactMap { attachment -> String? in
            if case let .mention(_, entry) = attachment { return entry.mentionMarkdown }
            return nil
        }
        if !mentions.isEmpty {
            trimmed = (mentions + (trimmed.isEmpty ? [] : [trimmed])).joined(separator: " ")
            pending.removeAll { if case .mention = $0 { true } else { false } }
        }

        let optimistic = OptimisticPrompt(text: trimmed, attachmentCount: pending.count)
        optimisticPrompts.append(optimistic)
        attachments = []
        isSending = true
        defer { isSending = false }

        do {
            // 草稿：先在对应文件夹里建会话（带上 composer 里选好的配置），再发消息。
            if session == nil {
                guard let workspace else {
                    throw KapError.api(code: -1, message: "先在侧栏选一个文件夹。")
                }
                let created = try await client.createSession(in: workspace, agentConfig: config.patch)
                holdsLocalConfig = true
                session = created
                onSessionCreated(created)
                await start()
            }
            guard let sessionID else { return }
            var images: [Data] = []
            var files: [UploadedFile] = []
            for attachment in pending {
                switch attachment {
                case let .image(_, jpeg, _):
                    images.append(jpeg)
                case let .file(_, name, mediaType, data):
                    files.append(try await client.uploadFile(data, name: name, mediaType: mediaType))
                case .mention:
                    break
                }
            }
            _ = try await client.sendPrompt(
                .make(text: trimmed, images: images, files: files, config: config.patch),
                to: sessionID
            )
            holdsLocalConfig = false
            setAwaitingTurn(true)
            scheduleOfflineReload()
        } catch {
            errorMessage = error.localizedDescription
            if let index = optimisticPrompts.firstIndex(where: { $0.id == optimistic.id }) {
                optimisticPrompts[index].failed = true
            }
        }
    }

    /// 失败卡片上的「继续」：发一条「继续」（官方 `turnFailedResumeText`）。
    func resume() async {
        await send("继续")
    }

    func retry(_ prompt: OptimisticPrompt) async {
        optimisticPrompts.removeAll { $0.id == prompt.id }
        await send(prompt.text)
    }

    func discard(_ prompt: OptimisticPrompt) {
        optimisticPrompts.removeAll { $0.id == prompt.id }
    }

    func abort() async {
        guard let sessionID else { return }
        setAwaitingTurn(false)
        do {
            try await client.abort(sessionID)
        } catch {
            errorMessage = error.localizedDescription
        }
        scheduleOfflineReload()
    }

    /// 撤销这条用户消息及其后的内容，原文放回输入框。
    func undo(_ entry: UserEntry) async {
        guard let sessionID, let count = entry.undoCount, !isWorking else { return }
        do {
            try await client.undo(sessionID, count: count)
            restoredDraft = entry.text
        } catch {
            errorMessage = error.localizedDescription
        }
        scheduleOfflineReload()
    }

    /// 没有事件流的后端（体验模式）：写操作后没有 WS 推送，手动补一次重拉（忙时会自动续轮询）。
    private func scheduleOfflineReload() {
        guard !liveUpdates else { return }
        transcriptReload.schedule(after: .milliseconds(200)) { [weak self] in
            await self?.reload()
        }
    }

    func resolve(_ approval: ApprovalRequest, decision: ApprovalDecisionBody) async {
        guard let sessionID else { return }
        // 先乐观移除，失败再放回去。
        let snapshot = pendingApprovals
        pendingApprovals.removeAll { $0.approvalID == approval.approvalID }
        do {
            let resolved = try await client.resolve(approval: approval.approvalID, in: sessionID, with: decision)
            if !resolved { errorMessage = "这条确认已经在别处处理过了。" }
        } catch {
            errorMessage = error.localizedDescription
            pendingApprovals = snapshot
        }
    }

    func answer(_ question: QuestionRequest, answers: [String: QuestionAnswer]) async {
        guard let sessionID else { return }
        let snapshot = pendingQuestions
        pendingQuestions.removeAll { $0.questionID == question.questionID }
        do {
            let resolved = try await client.answer(
                question: question.questionID,
                in: sessionID,
                with: QuestionAnswerBody(answers: answers)
            )
            if !resolved { errorMessage = "这个问题已经在别处回答过了。" }
        } catch {
            errorMessage = error.localizedDescription
            pendingQuestions = snapshot
        }
    }

    func dismiss(_ question: QuestionRequest) async {
        guard let sessionID else { return }
        let snapshot = pendingQuestions
        pendingQuestions.removeAll { $0.questionID == question.questionID }
        do {
            try await client.dismiss(question: question.questionID, in: sessionID)
        } catch {
            errorMessage = error.localizedDescription
            pendingQuestions = snapshot
        }
    }

    // MARK: 事件

    private func handle(_ signal: StreamSignal) async {
        switch signal {
        case .connected:
            connectionState = .live
            await refreshInteractions()

        case let .disconnected(reason):
            connectionState = .offline(reason)

        case let .resyncRequired(sessions):
            if sessions.isEmpty || sessions.contains(sessionID ?? "") {
                scheduleTranscriptReload()
            }

        case let .transcript(eventSession, event):
            guard eventSession == sessionID else { return }
            if activeReloads > 0 {
                bufferedTranscript.append(event)
            } else {
                apply(event)
            }

        case let .event(event):
            guard event.sessionID == nil || event.sessionID == sessionID else { return }
            // 权限确认 / 提问的出现与消失：重拉 pending 列表。正文与状态全靠 transcript。
            if event.type.contains("approval") || event.type.contains("question")
                || event.type.contains("interaction") || event.type == "event.session.work_changed" {
                scheduleInteractionRefresh()
            }
        }
    }

    private func apply(_ event: TranscriptWireEvent) {
        switch event {
        case let .reset(agentId, snapshot, hasMoreOlder, seq):
            guard agentId == "main" else { return }
            // 服务端推的 reset 快照一轮都不带（`TRANSCRIPT_RESET_TAIL_TURNS = 0`），只是「请重拉」的信号。
            // 冷会话首屏 REST 没有 seq，订阅时就会收到它 —— 照单全收会把已经显示的正文清空，
            // 只剩一行「加载更早的消息」。照网页端：不替换，退避后走 REST 重拉。
            let hasTurns = snapshot.items.contains { if case .turn = $0 { true } else { false } }
            if !hasTurns, snapshot.hasMoreOlder ?? hasMoreOlder {
                emptyResetRetries += 1
                scheduleTranscriptReload(after: .seconds(min(emptyResetRetries * 2, 15)))
                return
            }
            emptyResetRetries = 0
            transcript = TranscriptState(snapshot: snapshot, hasMoreOlder: hasMoreOlder, seq: seq)
            rebuild()
            scheduleInteractionRefresh()
            if let seq, let sessionID { Task { await stream?.noteTranscriptSeq(sessionID, seq: seq) } }

        case let .ops(agentId, ops, seq):
            guard agentId == "main" else { return }
            if let seq, let current = transcript.seq {
                // 已经应用过的批次（重连补发时会重叠）跳过。
                if seq <= current { return }
                // 批次序号是逐批 +1 的：跳号 = 中间漏了，全量重拉（网页端 onGap）。
                // 不能硬接着应用：漏掉的可能正是这一轮的开头，后面的增量会凭空建出一个没有用户消息的空壳。
                guard seq == current + 1 else {
                    scheduleTranscriptReload()
                    return
                }
            }
            let wasActive = transcript.isTurnActive
            for op in ops {
                if case .interactionUpsert = op { scheduleInteractionRefresh() }
                guard transcript.apply(op) else {
                    // offset 对不上 = 丢了增量：全量重拉。
                    scheduleTranscriptReload()
                    return
                }
            }
            if let seq {
                transcript.seq = seq
                if let sessionID { Task { await stream?.noteTranscriptSeq(sessionID, seq: seq) } }
            }
            rebuild()
            if wasActive, !transcript.isTurnActive, let sessionID {
                // 一轮结束：刷新 composer 状态（上下文圈）和确认列表。
                Task { [weak self] in
                    if let status = try? await self?.client.status(sessionID) { self?.apply(status) }
                }
                scheduleInteractionRefresh()
            }
        }
    }

    private func scheduleTranscriptReload(after delay: Duration = .milliseconds(300)) {
        transcriptReload.schedule(after: delay) { [weak self] in
            await self?.reload()
            guard let self, let sessionID = self.sessionID else { return }
            await self.stream?.subscribeTranscript(sessionID, since: self.transcript.seq)
        }
    }
}

private extension Optional where Wrapped == String {
    /// 服务端对「没设置」有时给 nil、有时给空串，统一当 nil。
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
