import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// composer 上那一排的选择：权限模式 / 模型 / 思考。新会话默认跟随电脑端 `/config` 配置。
struct ComposerConfig: Codable, Equatable, Sendable {
    var permission: PermissionMode
    var modelID: String?
    /// 请求里的 `thinking`：强度名（`low`…）或 `on` / `off`。字段名沿用旧的，免得丢掉已存的选择。
    var effort: String?

    var patch: AgentConfigPatch {
        AgentConfigPatch(model: modelID, thinking: effort, permissionMode: permission)
    }

    /// 由服务端默认配置解析新会话的初始 composer 配置（未设默认权限时与网页端一致按 `.manual`）。
    static func resolved(
        models: [ModelInfo],
        defaultModelID: String?,
        defaultThinking: ServerConfigDefaults.ThinkingConfig?,
        defaultPermissionMode: PermissionMode?
    ) -> ComposerConfig {
        let model = defaultModelID.flatMap { id in models.first { $0.model == id } } ?? models.first
        return ComposerConfig(
            permission: defaultPermissionMode ?? .manual,
            modelID: model?.model,
            effort: model.map { ServerConfigDefaults.thinkingOption(defaultThinking, for: $0) }
        )
    }
}

/// 主页正在看的那条对话。
///
/// 两种形态：
///   - 已有会话：`session != nil`
///   - 新对话草稿：只知道在哪个文件夹（工作区），第一条消息发出时才 `POST /sessions`
///
/// 运行时与官方网页端一致：
///   - 正文：2.6+ 用 turns REST + turns/items WS；旧版用 transcript REST + subscribe_v2 增量
///   - 是否在跑：新版读全量 agent.status / agent.compacting；旧版用 transcript meta / turn，重试读 step.retry 或旧 phase
///   - 配置与用量：新版读全量 agent / context（2.5–2.6 为 usage）；旧版回退到 REST status 与 transcript meta
///   - 权限确认、提问：2.7+ 支持 `GET /interactions` + `interaction` 帧与统一回写；2.4–2.6 用 `interaction` 帧；旧版用 REST pending 列表与旧回写
///   - 只做「发送」和「停止」：忙时不发（不排队），停止走 2.7+ `:cancel`（旧版回退 `:abort`）
@MainActor
@Observable
final class ChatModel {
    private(set) var session: SessionSummary?
    let workspace: Workspace?

    /// 权威正文状态机（仅内部同步维护，不直接触发全页观察；UI 读 `entries`、`liveStream` 与细粒度派生状态）。
    @ObservationIgnored private(set) var transcript = TranscriptState()
    /// 2.6+ 保留原始 turns 状态，增量同步到 `transcript`。
    @ObservationIgnored private var conversation: ConversationState?
    /// 按轮次缓存视图模型，结构重建时只重算变化的轮次。
    @ObservationIgnored private var projectionCache = ConversationProjectionCache()
    /// 由 transcript 派生的对话流（用户气泡 / 助手消息 / 压缩分隔）。
    private(set) var entries: [ChatEntry] = []
    /// 当前活跃流式块的独立状态槽：高频 delta 只更新这里，不触发整条对话列表 diff。
    let liveStream = LiveStreamStore()
    @ObservationIgnored private let pacer: StreamPacer

    // 细粒度派生状态：仅值真正变化时写回，避免流式输出期间无效触发 composer / 列表头部重绘。
    private(set) var hasMoreOlder = false
    private(set) var isWorking = false
    private(set) var isCompacting = false
    private(set) var retry: RetryState?
    private(set) var lastTurnEnd: TurnEnd?

    var pendingApprovals: [ApprovalRequest] { interactions.approvals }
    var pendingQuestions: [QuestionRequest] { interactions.questions }
    private(set) var isLoading = false
    /// 在后台待超过 30 秒回来：这段时间连接多半断过，屏幕上的正文不再可信，先换成骨架屏，重拉完再显示。
    private(set) var isRefreshingStale = false
    private(set) var isLoadingOlder = false
    private(set) var isSending = false
    /// `POST /prompts` 已经返回、但正文里这一轮还没开始跑：接住这段空档，「请求中…」不中途消失。
    @ObservationIgnored private var awaitingTurn = false
    @ObservationIgnored private var awaitingTurnTimeout: Task<Void, Never>?
    private(set) var connectionState: ConnectionState = .idle
    var errorMessage: String?
    /// 最近一次错误是否疑似上游 Kimi Code 协议不兼容（弹窗附带「使用网页版」按钮）。
    var isCompatibilityError = false
    /// 撤销后放回输入框的原文（官方：「已撤销，原文已放回输入框」）。
    var restoredDraft: String?

    struct RetryState: Equatable, Sendable {
        let next: Int
        let max: Int
    }

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
        /// 发送失败后重试需要原始附件；正文确认收到后随乐观消息一起释放。
        let attachments: [Attachment]
        var attachmentCount: Int { attachments.count }
        var promptID: String?
        var userMessageID: String?
        var failed = false
    }

    private let client: any KapServicing
    private let endpoint: Endpoint
    private let tokenProvider: @Sendable () async -> String?
    /// 是否开 WS 事件流。体验模式的内存后端没有事件流，一轮还在跑时改成轮询。
    private let liveUpdates: Bool
    private let onSessionCreated: (SessionSummary) -> Void
    private let onSessionEvent: (String, SessionSummary) -> Void
    private let onPromptSent: (String, String) -> Void
    private let onConfigChanged: (ComposerConfig) -> Void

    /// 草稿刚建成会话、第一条消息还没发出：服务端此时还是默认配置（建会话时不采纳 agent_config），
    /// 别让它覆盖 composer 上选好的值 —— 第一条消息会把模型 / 思考强度 / 权限一起带上。
    @ObservationIgnored private var holdsLocalConfig = false
    /// 当前空白草稿里由用户手动改过的配置项：同步服务端最新默认值时不覆盖这些显式选择。
    @ObservationIgnored private var draftOverrides: DraftConfigOverrides = []

    private struct DraftConfigOverrides: OptionSet {
        let rawValue: Int
        static let permission = Self(rawValue: 1 << 0)
        static let model = Self(rawValue: 1 << 1)
        static let effort = Self(rawValue: 1 << 2)
    }
    /// 只有收到严格解码的 agent 全量帧，才确认新版状态协议；usage/context 不能单独证明配置通道可用。
    @ObservationIgnored private var usesStateStream = false
    @ObservationIgnored private var legacyStatusUnavailable = false
    @ObservationIgnored private var detectedWireProtocol: TranscriptProtocol?
    @ObservationIgnored private var agentState: SessionAgentState?
    private var interactions = PendingInteractions()
    @ObservationIgnored private var interactionProtocol: InteractionProtocol = .unknown
    @ObservationIgnored private var subscriptionError: String?
    /// 现场量到的思考时长（官方 `thinkingTiming`），只在本次打开期间有效。
    @ObservationIgnored private var thinkingTiming: [String: ThinkingTiming] = [:]

    private enum InteractionProtocol {
        case unknown
        case legacyREST
        case frames
    }

    @ObservationIgnored private var stream: EventStream?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundTask: Task<Void, Never>?
    @ObservationIgnored private var backgroundTask: Task<Void, Never>?
    /// 进后台时向系统要的那段执行时间（约 30 秒）：短暂切出去时连接不断，正文照常往下收。
    #if canImport(UIKit)
    @ObservationIgnored private var backgroundTimeID: UIBackgroundTaskIdentifier = .invalid
    #endif
    @ObservationIgnored private var backgroundedAt: ContinuousClock.Instant?
    /// 后台时间用完了（系统马上要挂起 App），连接多半会被掐掉。
    @ObservationIgnored private var backgroundTimeExpired = false
    /// 在后台待了超过这么久（约等于系统给的后台时间），回来就不信任旧连接和旧正文：直接重连、骨架屏重拉。
    private static let backgroundGrace: Duration = .seconds(30)
    /// 正在全量重拉的次数。期间收到的正文增量先存着，拉完再按顺序补上（网页端 `buffered`），
    /// 否则会先应用到旧数据上、再被重拉结果整个盖掉。
    @ObservationIgnored private var activeReloads = 0
    @ObservationIgnored private var bufferedTranscript: [TranscriptWireEvent] = []
    @ObservationIgnored private var bufferedConversation: [ConversationWireEvent] = []
    /// 连续收到「空快照」的次数，用来退避重拉（网页端 `emptyResetRetries`）。
    @ObservationIgnored private var emptyResetRetries = 0
    @ObservationIgnored private let interactionRefresh = RefreshScheduler()
    @ObservationIgnored private let transcriptReload = RefreshScheduler()
    @ObservationIgnored private let seqReporter = RefreshScheduler()
    @ObservationIgnored private var pendingReportedSeq: Int?
    @ObservationIgnored private let attachmentCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    func attachmentData(_ attachment: AttachmentRef) async throws -> Data {
        guard let source = attachment.source, let sessionID else {
            throw KapError.api(code: -1, message: "这张图片没有可读取的预览。")
        }
        if let data = attachmentCache.object(forKey: source.cacheKey as NSString) { return data as Data }
        let data = try await client.attachmentData(source, sessionID: sessionID)
        attachmentCache.setObject(data as NSData, forKey: source.cacheKey as NSString, cost: data.count)
        return data
    }

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
        onSessionEvent: @escaping (String, SessionSummary) -> Void = { _, _ in },
        onPromptSent: @escaping (String, String) -> Void = { _, _ in },
        onConfigChanged: @escaping (ComposerConfig) -> Void = { _ in }
    ) {
        self.session = session
        self.workspace = workspace
        self.config = config
        self.client = client
        self.endpoint = endpoint
        self.tokenProvider = tokenProvider
        self.liveUpdates = liveUpdates
        self.onSessionCreated = onSessionCreated
        self.onSessionEvent = onSessionEvent
        self.onPromptSent = onPromptSent
        self.onConfigChanged = onConfigChanged
        self.pacer = StreamPacer(liveStream: liveStream)
        self.pacer.onStructuralFlush = { [weak self] in
            self?.rebuild()
        }
    }

    // MARK: 运行态

    /// composer 用：忙时只给「停止」。
    var isBusy: Bool { isWorking }

    /// 上一轮怎么结束的：`cancelled` 画「已手动终止」，`failed` 画失败卡片 + 继续。
    enum TurnEnd: Equatable, Sendable {
        case cancelled
        case failed(maxSteps: Bool, message: String?, meta: String?)
    }

    /// 统一收敛派生运行态，只在值实际改变时通知 SwiftUI，避免流式输出期间无关视图重绘。
    private func syncDerivedState() {
        let nextHasMore = transcript.hasMoreOlder
        if hasMoreOlder != nextHasMore { hasMoreOlder = nextHasMore }

        let serverActive = agentState?.isWorking ?? transcript.isTurnActive
        let nextWorking = serverActive || isSending || awaitingTurn
        if isWorking != nextWorking { isWorking = nextWorking }

        let nextCompacting: Bool = if let agentState {
            agentState.isCompacting
        } else {
            transcriptCompactingFlag()
        }
        if isCompacting != nextCompacting { isCompacting = nextCompacting }

        let nextRetry = computeRetry()
        if retry != nextRetry { retry = nextRetry }

        let nextTurnEnd = computeLastTurnEnd(working: nextWorking)
        if lastTurnEnd != nextTurnEnd { lastTurnEnd = nextTurnEnd }
    }

    private func transcriptCompactingFlag() -> Bool {
        for item in transcript.items.reversed() {
            guard case let .marker(marker) = item, marker.marker == "compaction" else { continue }
            return marker.payload?["phase"]?.stringValue == "started"
        }
        return false
    }

    /// 新旧 transcript 都有 step.retry；旧版再回退到 meta.agent.phase。
    private func computeRetry() -> RetryState? {
        if let retry = transcript.lastTurn?.steps.reversed().compactMap(\.retry).first {
            return RetryState(next: retry.nextAttempt, max: retry.maxAttempts)
        }
        guard let phase = transcript.phase, phase["kind"]?.stringValue == "retrying" else { return nil }
        return RetryState(
            next: phase["nextAttempt"]?.intValue ?? 0,
            max: phase["maxAttempts"]?.intValue ?? 0
        )
    }

    private func computeLastTurnEnd(working: Bool) -> TurnEnd? {
        guard !working, let last = transcript.lastTurn else { return nil }
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
            let maxSteps = last.endReason == "max_steps"
                || last.error?.contains("maxSteps") == true || last.error?.contains("max_steps") == true
            return .failed(maxSteps: maxSteps, message: last.error, meta: maxSteps ? "loop.max_steps_exceeded" : nil)
        default:
            return nil
        }
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
        let wireProtocol: TranscriptProtocol
        if let detectedWireProtocol {
            wireProtocol = detectedWireProtocol
        } else if (try? await client.serverMeta())?.usesConversationProtocol == true {
            wireProtocol = .conversation
            detectedWireProtocol = .conversation
            if conversation == nil { conversation = ConversationState() }
        } else {
            wireProtocol = .legacy
        }
        let stream = EventStream(
            endpoint: endpoint,
            wireProtocol: wireProtocol,
            tokenProvider: tokenProvider
        )
        self.stream = stream
        let signals = await stream.start()
        // 会话事件（权限确认 / 提问的通知）+ 正文增量。
        await stream.subscribe(to: sessionID)
        if wireProtocol == .legacy {
            await stream.subscribeTranscript(sessionID, since: transcript.seq)
        }
        streamTask = Task { [weak self] in
            for await signal in signals {
                await self?.handle(signal)
            }
        }
        #if canImport(UIKit)
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
        #endif
    }

    private func beginBackgroundTime() {
        pacer.flushPendingText()
        endBackgroundTime()
        backgroundedAt = .now
        backgroundTimeExpired = false
        #if canImport(UIKit)
        backgroundTimeID = UIApplication.shared.beginBackgroundTask(withName: "kimi.stream") { [weak self] in
            // 系统在时间到之前回调这里，必须马上把这段时间还回去，否则 App 会被杀掉。
            MainActor.assumeIsolated {
                self?.backgroundTimeExpired = true
                self?.endBackgroundTime()
            }
        }
        #endif
    }

    private func endBackgroundTime() {
        #if canImport(UIKit)
        guard backgroundTimeID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTimeID)
        backgroundTimeID = .invalid
        #endif
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
        pacer.stop()
        streamTask?.cancel()
        streamTask = nil
        foregroundTask?.cancel()
        foregroundTask = nil
        backgroundTask?.cancel()
        backgroundTask = nil
        awaitingTurnTimeout?.cancel()
        awaitingTurnTimeout = nil
        endBackgroundTime()
        interactionRefresh.cancel()
        transcriptReload.cancel()
        seqReporter.cancel()
        let stream = stream
        self.stream = nil
        Task { await stream?.stop() }
    }

    // MARK: 读

    func clearError() {
        errorMessage = nil
        isCompatibilityError = false
    }

    private func presentError(_ error: any Error) {
        guard !Task.isCancelled, !KapError.isCancellation(error) else { return }
        if KapError.isProtocolMismatch(error) {
            isCompatibilityError = true
            errorMessage = KapError.protocolMismatchMessage
        } else {
            isCompatibilityError = false
            errorMessage = error.localizedDescription
        }
    }

    /// 全量重拉：正文尾部一页 + 待处理的确认/提问 + composer 状态。
    func reload() async {
        guard let sessionID else { return }
        clearError()
        // 只在屏幕上什么都没有时显示骨架屏（打开已有会话的首屏）。草稿发出第一条后建会话再重拉，
        // 那条消息已经乐观显示着，不该在它上面再冒骨架。
        isLoading = isRefreshingStale || (entries.isEmpty && optimisticPrompts.isEmpty)
        activeReloads += 1
        defer {
            isLoading = false
            activeReloads -= 1
            if activeReloads == 0 {
                let pending = bufferedTranscript
                let pendingConversation = bufferedConversation
                bufferedTranscript = []
                bufferedConversation = []
                for event in pending { apply(event) }
                for event in pendingConversation { apply(event) }
            }
        }
        do {
            async let page = client.transcript(sessionID)
            async let status = legacyStatus(sessionID)
            let loaded = try await page
            detectedWireProtocol = loaded.wireProtocol
            if let page = loaded.conversation {
                if conversation == nil { conversation = ConversationState() }
                conversation?.replaceLatest(page)
                transcript = conversation?.transcriptState ?? TranscriptState()
            } else {
                conversation = nil
                transcript = TranscriptState(page: loaded)
            }
            pacer.reset(clearLiveStream: true)
            rebuild()
            // 正文一到就撤骨架：后面的 status / 确认拉取还在路上，不该挡着已到的内容。
            isLoading = false
            isRefreshingStale = false
            if let seq = transcript.seq { await stream?.noteTranscriptSeq(sessionID, seq: seq) }
            if let status = try await status, !usesStateStream { apply(status) }
            await refreshInteractions()

            // 没有事件流的后端（体验模式）不会推增量：一轮还在跑时自己轮询，直到它落完。
            if !liveUpdates, transcript.isTurnActive {
                transcriptReload.schedule(after: .milliseconds(400)) { [weak self] in
                    await self?.reload()
                }
            }
        } catch {
            // 切换会话/停止订阅取消的是读取任务，不代表出错。
            guard !Task.isCancelled, !KapError.isCancellation(error) else { return }
            // 重拉失败就把旧正文放回来，总比一直挂着骨架强。
            isRefreshingStale = false
            presentError(error)
        }
    }

    /// 「加载更早的消息」。
    func loadOlder() async {
        guard let sessionID, transcript.hasMoreOlder, !isLoadingOlder,
              let first = transcript.firstTurn else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let page = try await client.transcript(
                sessionID, pageSize: 30, beforeTurn: first.turnId, beforeOrdinal: first.ordinal
            )
            if let older = page.conversation {
                conversation?.prepend(older: older)
                transcript = conversation?.transcriptState ?? transcript
            } else {
                transcript.prepend(older: page)
            }
            pacer.reset(clearLiveStream: true)
            rebuild()
        } catch {
            guard !Task.isCancelled, !KapError.isCancellation(error) else { return }
            presentError(error)
        }
    }

    private func refreshInteractions() async {
        guard let sessionID, interactionProtocol != .frames else { return }
        if interactionProtocol == .unknown {
            do {
                let list = try await client.pendingInteractions(sessionID)
                guard interactionProtocol != .frames else { return }
                interactionProtocol = .frames
                interactions.replaceLegacy(approvals: list.approvals, questions: list.questions)
                return
            } catch KapError.http(status: 404, body: _) {
            } catch let KapError.api(code, _) where code == KapErrorCode.notFound {
            } catch {
                guard interactionProtocol != .frames else { return }
                presentError(error)
                return
            }
        }
        do {
            async let approvals = client.pendingApprovals(sessionID)
            async let questions = client.pendingQuestions(sessionID)
            let result = try await (approvals: approvals.items, questions: questions.items)
            guard interactionProtocol != .frames else { return }
            interactionProtocol = .legacyREST
            interactions.replaceLegacy(approvals: result.approvals, questions: result.questions)
        } catch KapError.http(status: 404, body: _) {
            guard interactionProtocol != .frames else { return }
            interactionProtocol = .frames
            interactions.reset()
        } catch {
            guard interactionProtocol != .frames else { return }
            presentError(error)
        }
    }

    private func scheduleInteractionRefresh() {
        interactionRefresh.schedule(after: .milliseconds(150)) { [weak self] in
            await self?.refreshInteractions()
        }
    }

    /// 仅旧 status 的 HTTP 404 可降级；正文请求、鉴权和其它错误仍正常报错。
    private func legacyStatus(_ sessionID: String) async throws -> SessionRuntimeStatus? {
        guard !usesStateStream, !legacyStatusUnavailable else { return nil }
        do {
            return try await client.status(sessionID)
        } catch KapError.http(status: 404, body: _) {
            legacyStatusUnavailable = true
            return nil
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

    private func apply(_ state: SessionAgentState) {
        let wasWorking = isWorking
        usesStateStream = true
        agentState = state
        syncDerivedState()
        // 轮次刚从运行切到空闲：立即把实时槽位落回 entries，页脚与最终文本一步到位。
        if wasWorking, !isWorking, pacer.currentAnchor != nil || pacer.hasPendingWork {
            pacer.reset(clearLiveStream: true)
            rebuild(allowLiveStream: false)
        }
        guard !holdsLocalConfig else { return }
        let nextConfig = ComposerConfig(
            permission: state.permission ?? config.permission,
            modelID: state.model,
            effort: state.thinkingLevel
        )
        if config != nextConfig { config = nextConfig }
    }

    private func apply(_ usage: SessionContextUsage) {
        if contextTokens != usage.contextTokens { contextTokens = usage.contextTokens }
        if maxContextTokens != usage.maxContextTokens { maxContextTokens = usage.maxContextTokens }
        let ratio = usage.ratio
        if contextUsage != ratio { contextUsage = ratio }
    }

    /// 旧版 `meta.agent` 里带着配置和用量；新版全量 agent / usage 帧优先，不能被旧投影覆盖。
    private func applyAgentMeta() {
        guard !usesStateStream, let agent = transcript.meta["agent"] else { return }
        if let tokens = agent["contextTokens"]?.intValue, contextTokens != tokens { contextTokens = tokens }
        if let max = agent["maxContextTokens"]?.intValue, maxContextTokens != max { maxContextTokens = max }
        if case let .number(usage)? = agent["contextUsage"], contextUsage != usage { contextUsage = usage }
        guard !holdsLocalConfig else { return }
        var next = config
        if let raw = agent["permission"]?.stringValue, let permission = PermissionMode(rawValue: raw) {
            next.permission = permission
        }
        if let model = agent["model"]?.stringValue, !model.isEmpty { next.modelID = model }
        if let effort = agent["thinkingEffort"]?.stringValue, !effort.isEmpty { next.effort = effort }
        if next != config { config = next }
    }

    private func rebuild(initialBurst: String? = nil, allowLiveStream: Bool = true) {
        ConversationBuilder.updateTiming(&thinkingTiming, state: transcript)
        let nextEntries = projectionCache.build(from: transcript, timing: thinkingTiming)
        if entries != nextEntries {
            entries = nextEntries
        }
        applyAgentMeta()
        reconcileOptimisticPrompts()
        // 这一轮已经跑起来了，或者跑得太快、回复已经落进正文（体验模式轮询时会这样）：空档结束。
        if awaitingTurn, transcript.isTurnActive || (optimisticPrompts.isEmpty && entries.last?.isAssistant == true) {
            setAwaitingTurn(false)
        }
        syncDerivedState()

        if allowLiveStream, liveUpdates, optimisticPrompts.isEmpty,
           let anchor = ConversationBuilder.liveAnchor(state: transcript, entries: entries, isWorking: isWorking) {
            pacer.attach(anchor, initialBurst: initialBurst)
        } else {
            pacer.reset(clearLiveStream: true)
        }
    }

    private func reconcileOptimisticPrompts() {
        guard !optimisticPrompts.isEmpty else { return }
        // 按服务端收据确认，不能用正文相同来判断；纯图片和重复文字也必须能对应上。
        var known = Set<String>()
        for item in transcript.items {
            if case let .turn(turn) = item, let id = turn.triggerPromptId {
                known.insert(id)
            }
        }
        for prompt in transcript.prompts.values {
            known.insert(prompt.promptId)
            if let userMessageId = prompt.userMessageId { known.insert(userMessageId) }
        }
        optimisticPrompts.removeAll { prompt in
            !prompt.failed && [prompt.promptID, prompt.userMessageID].compactMap { $0 }.contains(where: known.contains)
        }
    }

    /// 兜底 15s：服务端迟迟不报这一轮开始（排队、断线）时不让「请求中…」一直挂着。
    private func setAwaitingTurn(_ value: Bool) {
        awaitingTurn = value
        awaitingTurnTimeout?.cancel()
        awaitingTurnTimeout = nil
        syncDerivedState()
        guard value else { return }
        awaitingTurnTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.awaitingTurn = false
            self?.syncDerivedState()
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

    /// 仅在未发消息的草稿上同步电脑端最新默认配置，不改已有会话，也不覆盖当前草稿里用户手动改过的项。
    func applyDefaults(
        _ defaults: ComposerConfig,
        defaultThinking: ServerConfigDefaults.ThinkingConfig?,
        models: [ModelInfo]
    ) {
        guard isDraft else { return }
        var next = config
        if !draftOverrides.contains(.permission) {
            next.permission = defaults.permission
        }
        let modelChanged = !draftOverrides.contains(.model) && next.modelID != defaults.modelID
        if !draftOverrides.contains(.model) {
            next.modelID = defaults.modelID
        }
        let activeModel = next.modelID.flatMap { id in models.first { $0.model == id } }
        if !draftOverrides.contains(.effort) {
            if let activeModel {
                next.effort = ServerConfigDefaults.thinkingOption(defaultThinking, for: activeModel)
            } else {
                next.effort = defaults.effort
            }
        } else if modelChanged, let activeModel {
            next.effort = activeModel.normalizedThinking(next.effort)
        }
        if next != config {
            config = next
        }
    }

    private func update(_ change: (inout ComposerConfig) -> Void) async {
        let previous = config
        var next = config
        change(&next)
        guard next != previous else { return }
        if isDraft {
            if next.permission != previous.permission { draftOverrides.insert(.permission) }
            if next.modelID != previous.modelID {
                draftOverrides.insert(.model)
            } else if next.effort != previous.effort {
                draftOverrides.insert(.effort)
            }
        }
        config = next
        onConfigChanged(next)
        // 草稿还没有会话，等第一条消息时连同配置一起建。
        guard let sessionID else { return }
        do {
            try await client.updateProfile(sessionID, agentConfig: diff(from: previous, to: next))
            if let status = try? await legacyStatus(sessionID), !usesStateStream { apply(status) }
        } catch {
            config = previous
            presentError(error)
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

        let optimistic = OptimisticPrompt(text: trimmed, attachments: pending)
        optimisticPrompts.append(optimistic)
        attachments = []
        await submit(optimistic)
    }

    private func submit(_ optimistic: OptimisticPrompt) async {
        isSending = true
        syncDerivedState()
        defer {
            isSending = false
            syncDerivedState()
        }

        do {
            // 草稿：先在对应文件夹里建会话（带上 composer 里选好的配置），再发消息。
            if session == nil {
                guard let workspace else {
                    throw KapError.api(code: -1, message: "先在侧栏选一个文件夹。")
                }
                let rawCreated = try await client.createSession(in: workspace, agentConfig: config.patch)
                let created = rawCreated.workspaceID == nil
                    ? rawCreated.updating(workspaceID: .some(workspace.id))
                    : rawCreated
                holdsLocalConfig = true
                session = created
                onSessionCreated(created)
                await start()
            }
            guard let sessionID else { return }
            var images: [UploadedFile] = []
            var files: [UploadedFile] = []
            for attachment in optimistic.attachments {
                switch attachment {
                case let .image(id, jpeg, _):
                    let file = try await client.uploadFile(
                        jpeg, name: "image-\(id.uuidString).jpg", mediaType: "image/jpeg"
                    )
                    images.append(file)
                    for source in [AttachmentSource.file(file.id), .sessionMedia(file.id)] {
                        attachmentCache.setObject(jpeg as NSData, forKey: source.cacheKey as NSString, cost: jpeg.count)
                    }
                case let .file(_, name, mediaType, data):
                    files.append(try await client.uploadFile(data, name: name, mediaType: mediaType))
                case .mention:
                    break
                }
            }
            let accepted = try await client.sendPrompt(
                .make(text: optimistic.text, images: images, files: files, config: config.patch),
                to: sessionID
            )
            onPromptSent(sessionID, optimistic.text)
            if let index = optimisticPrompts.firstIndex(where: { $0.id == optimistic.id }) {
                optimisticPrompts[index].promptID = accepted.promptID
                optimisticPrompts[index].userMessageID = accepted.userMessageID
            }
            holdsLocalConfig = false
            setAwaitingTurn(true)
            // 回显可能先于 HTTP 响应到达；拿到服务端 id 后立即再核对一次。
            rebuild()
            scheduleOfflineReload()
        } catch {
            presentError(error)
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
        guard !isWorking,
              let index = optimisticPrompts.firstIndex(where: { $0.id == prompt.id && $0.failed }) else { return }
        optimisticPrompts[index].failed = false
        await submit(optimisticPrompts[index])
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
            presentError(error)
        }
        scheduleOfflineReload()
    }

    /// 撤销这条用户消息及其后的内容，原文放回输入框。
    func undo(_ entry: UserEntry) async {
        guard let sessionID, entry.undoCount != nil, !isWorking else { return }
        do {
            if conversation != nil, let turnID = entry.undoTurnID {
                try await client.undo(sessionID, turnID: turnID)
            } else if let count = entry.undoCount {
                try await client.undo(sessionID, count: count)
            }
            restoredDraft = entry.text
        } catch {
            presentError(error)
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
        let snapshot = interactions
        interactions.replaceLegacy(
            approvals: snapshot.approvals.filter { $0.approvalID != approval.approvalID },
            questions: snapshot.questions
        )
        do {
            let resolved = if interactionProtocol == .frames {
                try await client.resolveInteraction(approval: approval.approvalID, in: sessionID, with: decision)
            } else {
                try await client.resolve(approval: approval.approvalID, in: sessionID, with: decision)
            }
            if !resolved { errorMessage = "这条确认已经在别处处理过了。" }
        } catch {
            presentError(error)
            interactions = snapshot
        }
    }

    func answer(_ question: QuestionRequest, answers: [String: QuestionAnswer]) async {
        guard let sessionID else { return }
        let snapshot = interactions
        interactions.replaceLegacy(
            approvals: snapshot.approvals,
            questions: snapshot.questions.filter { $0.questionID != question.questionID }
        )
        let body = QuestionAnswerBody(answers: answers)
        do {
            let resolved = if interactionProtocol == .frames {
                try await client.answerInteraction(question: question.questionID, in: sessionID, with: body)
            } else {
                try await client.answer(question: question.questionID, in: sessionID, with: body)
            }
            if !resolved { errorMessage = "这个问题已经在别处回答过了。" }
        } catch {
            presentError(error)
            interactions = snapshot
        }
    }

    func dismiss(_ question: QuestionRequest) async {
        guard let sessionID else { return }
        let snapshot = interactions
        interactions.replaceLegacy(
            approvals: snapshot.approvals,
            questions: snapshot.questions.filter { $0.questionID != question.questionID }
        )
        do {
            if interactionProtocol == .frames {
                try await client.dismissInteraction(question: question.questionID, in: sessionID)
            } else {
                try await client.dismiss(question: question.questionID, in: sessionID)
            }
        } catch {
            presentError(error)
            interactions = snapshot
        }
    }

    // MARK: 事件

    private func handle(_ signal: StreamSignal) async {
        switch signal {
        case .connected:
            connectionState = .live
            legacyStatusUnavailable = false
            await refreshInteractions()

        case let .disconnected(reason):
            connectionState = .offline(reason)

        case let .resyncRequired(sessions):
            if sessions.isEmpty || sessions.contains(sessionID ?? "") {
                scheduleTranscriptReload()
            }

        case let .agentState(eventSession, state):
            guard eventSession == sessionID else { return }
            apply(state)

        case let .agentUsage(eventSession, usage):
            guard eventSession == sessionID else { return }
            apply(usage)

        case let .interaction(frame):
            guard frame.sessionID == sessionID else { return }
            if interactionProtocol != .frames {
                interactionProtocol = .frames
                interactions.reset()
            }
            interactions.apply(frame)
            if pacer.hasPendingWork {
                pacer.flushPendingText()
            }

        case let .interactionsReset(eventSession):
            guard eventSession == sessionID else { return }
            if errorMessage == subscriptionError { errorMessage = nil }
            subscriptionError = nil
            interactions.reset()
            if interactionProtocol != .frames {
                await refreshInteractions()
            }

        case let .subscriptionFailed(eventSession, message):
            guard eventSession == sessionID else { return }
            let text = "会话订阅暂时失败：\(message)。正在重试。"
            subscriptionError = text
            errorMessage = text

        case let .transcript(eventSession, event):
            guard eventSession == sessionID else { return }
            if activeReloads > 0 {
                bufferedTranscript.append(event)
            } else {
                apply(event)
            }

        case let .conversation(eventSession, event):
            guard eventSession == sessionID else { return }
            if activeReloads > 0 {
                bufferedConversation.append(event)
            } else {
                apply(event)
            }

        case let .event(event):
            if event.type == "session", let change = event.change, let summary = event.session {
                if summary.id == sessionID, change == "updated" || change == "created" || change == "restored" {
                    session = summary
                }
                onSessionEvent(change, summary)
            }
            guard event.sessionID == nil || event.sessionID == sessionID else { return }
            if event.type == "session" || event.type.contains("approval") || event.type.contains("question")
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
            pacer.reset(clearLiveStream: true)
            transcript = TranscriptState(snapshot: snapshot, hasMoreOlder: hasMoreOlder, seq: seq)
            rebuild()
            scheduleInteractionRefresh()
            if let seq { reportTranscriptSeq(seq, immediate: true) }

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
            let activeAnchor = pacer.currentAnchor
            var pureAnchorDelta: String? = activeAnchor != nil ? "" : nil
            var singleAppendBurst: String? = nil

            for op in ops {
                if case .interactionUpsert = op { scheduleInteractionRefresh() }
                if let activeAnchor, pureAnchorDelta != nil,
                   case let .append(.frame(turnId, stepId, frameId), _, _) = op,
                   activeAnchor.matches(turnID: turnId, stepID: stepId, frameID: frameId),
                   let oldUTF8 = transcript.frameTextUTF8Count(turnID: turnId, stepID: stepId, frameID: frameId) {
                    guard transcript.apply(op) else {
                        scheduleTranscriptReload()
                        return
                    }
                    let added = transcript.frameTextSuffix(
                        turnID: turnId, stepID: stepId, frameID: frameId, fromUTF8Offset: oldUTF8
                    )
                    if !added.isEmpty { pureAnchorDelta?.append(added) }
                } else {
                    pureAnchorDelta = nil
                    if ops.count == 1, case let .append(.frame(_, _, _), _, text) = op {
                        singleAppendBurst = text
                    }
                    guard transcript.apply(op) else {
                        // offset 对不上 = 丢了增量：全量重拉。
                        scheduleTranscriptReload()
                        return
                    }
                }
            }
            if let seq {
                transcript.seq = seq
                reportTranscriptSeq(seq, immediate: pureAnchorDelta == nil)
            }
            if let activeAnchor, let delta = pureAnchorDelta {
                // 整批 ops 都只追加到当前已绑定的活跃流式块：直接喂给节拍器，跳过整页重建。
                _ = pacer.acceptDelta(
                    turnID: activeAnchor.turnID,
                    stepID: activeAnchor.stepID,
                    frameID: activeAnchor.frameID,
                    delta: delta
                )
                return
            }
            pacer.reset(clearLiveStream: true)
            rebuild(initialBurst: singleAppendBurst)
            if wasActive, !transcript.isTurnActive, let sessionID {
                // 一轮结束：刷新 composer 状态（上下文圈）和确认列表。
                Task { [weak self] in
                    guard let self else { return }
                    if let status = try? await self.legacyStatus(sessionID), !self.usesStateStream {
                        self.apply(status)
                    }
                }
                scheduleInteractionRefresh()
            }
        }
    }

    private func apply(_ event: ConversationWireEvent) {
        if conversation == nil, detectedWireProtocol == .conversation {
            conversation = ConversationState()
        }
        guard conversation != nil else { return }
        switch event {
        case let .failed(code, message):
            errorMessage = "对话加载失败（\(code)）：\(message)"
        case let .notice(level, title, detail) where level == "error":
            errorMessage = detail.map { "\(title)：\($0)" } ?? title
        default:
            break
        }
        let change = conversation!.apply(event)
        let sync = conversation!.sync(to: &transcript, change: change)

        switch sync {
        case .unchanged:
            return

        case let .textDelta(turnID, stepID, frameID, _, delta):
            // 99% 的流式 token 命中这里：不触发任何投影、不重建 entries、直接交给节拍器平滑推进。
            if pacer.acceptDelta(turnID: turnID, stepID: stepID, frameID: frameID, delta: delta) {
                return
            }
            // 新块首次出现非空白内容（或切换了活跃帧）：做一次增量重建并绑定新锚点。
            pacer.reset(clearLiveStream: true)
            rebuild(initialBurst: delta)

        case .structural:
            if case .itemDelta = change {
                // 工具入参 / 输出的流式增量：合并到 ~30Hz 节拍刷新，避免高频工具日志拖垮主线程。
                if pacer.currentAnchor != nil {
                    pacer.reset(clearLiveStream: true)
                }
                pacer.scheduleStructuralRebuild()
                return
            }
            pacer.reset(clearLiveStream: true)
            rebuild()
        }
    }

    /// 合并回报已应用的 legacy `seq`，避免每个 delta 都新建 Task 跳一次 actor。
    private func reportTranscriptSeq(_ seq: Int, immediate: Bool) {
        pendingReportedSeq = seq
        let delay: Duration = immediate ? .zero : .milliseconds(250)
        seqReporter.schedule(after: delay) { [weak self] in
            guard let self, let sessionID = self.sessionID, let latest = self.pendingReportedSeq else { return }
            await self.stream?.noteTranscriptSeq(sessionID, seq: latest)
        }
    }

    private func scheduleTranscriptReload(after delay: Duration = .milliseconds(300)) {
        transcriptReload.schedule(after: delay) { [weak self] in
            await self?.reload()
            guard let self, let sessionID = self.sessionID else { return }
            if self.conversation == nil {
                await self.stream?.subscribeTranscript(sessionID, since: self.transcript.seq)
            } else {
                await self.stream?.subscribe(to: sessionID)
            }
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
