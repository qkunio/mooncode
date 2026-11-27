import Foundation
import OSLog

/// 服务端推来的事件信封。`payload` 是刻意不定型的联合体，保留原始 JSON。
struct SessionEventFrame: Decodable, Sendable {
    let type: String
    let change: String?
    let seq: Int?
    let epoch: String?
    let volatile: Bool?
    let sessionID: String?
    let payload: JSONValue?

    enum CodingKeys: String, CodingKey {
        case type, change, seq, epoch, volatile, payload, session
        case sessionID = "session_id"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        change = try? c.decodeIfPresent(String.self, forKey: .change)
        seq = try? c.decodeIfPresent(Int.self, forKey: .seq)
        epoch = try? c.decodeIfPresent(String.self, forKey: .epoch)
        volatile = try? c.decodeIfPresent(Bool.self, forKey: .volatile)
        let sessionObj = try? c.decodeIfPresent(JSONValue.self, forKey: .session)
        sessionID = (try? c.decodeIfPresent(String.self, forKey: .sessionID))
            ?? sessionObj?["id"]?.stringValue
        payload = try? c.decodeIfPresent(JSONValue.self, forKey: .payload)
    }
}

/// WS 连接对外发出的信号。
enum StreamSignal: Sendable {
    case connected(heartbeatMS: Int?)
    case disconnected(reason: String)
    /// 一条会话事件。
    case event(SessionEventFrame)
    /// 这些会话的增量续不上了（服务端 `resync_required`，多半是历史被压缩过），必须全量重拉。
    case resyncRequired([String])
    /// 对话正文的增量（`subscribe_v2` 订阅的 `transcript.reset` / `transcript.ops`）。
    case transcript(sessionID: String, TranscriptWireEvent)
    /// 2.6+ 的 turns / items 正文帧。
    case conversation(sessionID: String, ConversationWireEvent)
    case agentState(sessionID: String, SessionAgentState)
    case agentUsage(sessionID: String, SessionContextUsage)
    case interaction(InteractionFrame)
    /// 服务端在订阅确认后重发当前 pending 全量；先清空，再应用随后的 interaction 帧。
    case interactionsReset(sessionID: String)
    case subscriptionFailed(sessionID: String, message: String)
}

/// kap-server 的 WebSocket 事件通道。
///
/// 2.0–2.5 使用 client_hello + subscribe_v2，正文按 transcript_since 续传。
/// 2.6+ 连接后直接发送带 request_id 的 subscribe，由 response 确认，正文改为 turns / items 全量与增量帧。
/// 两版都接收全量 agent / usage 与 interaction；订阅失败会退避重试。
actor EventStream {
    private let endpoint: Endpoint
    private let tokenProvider: @Sendable () async -> String?
    private let clientID: String
    private let wireProtocol: TranscriptProtocol
    private let logger = Logger(subsystem: "com.qinkun.kimicode", category: "ws")
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    /// 轻量帧头：先只解出分发所需的 3 个字段，避免高频流式帧反复在 JSONValue 树上编解码。
    private struct FrameHeader: Decodable {
        let type: String
        let sessionID: String?
        let agentID: String?

        enum CodingKeys: String, CodingKey {
            case type
            case sessionID = "session_id"
            case agentID = "agent_id"
        }
    }

    private struct TranscriptEnvelope: Decodable {
        let payload: TranscriptWireEvent
    }

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var pumpTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var continuation: AsyncStream<StreamSignal>.Continuation?

    /// session_id → 最后看到的 seq/epoch。
    private var cursors: [String: Cursor] = [:]
    private var subscribedSessions: Set<String> = []
    /// session_id → 已应用到的 transcript 批次序号（`transcript_since`）。nil = 还没拿到过。
    private var transcriptSubscriptions: [String: Int?] = [:]
    private var pendingSubscriptionAcks: [String: PendingSubscription] = [:]
    private var subscriptionRetries: [String: Task<Void, Never>] = [:]
    private var subscriptionRetryAttempts: [String: Int] = [:]
    private var messageSeq = 0
    private var reconnectAttempt = 0
    private var isStopped = false
    /// 只有 client_hello 已发出后才允许主动订阅，避免握手途中重复发送。
    private var canSendSubscriptions = false
    /// 最后一次收到任何帧（含 pong）的时间，判断连接是不是已经悄悄断了。
    private var lastActivity: ContinuousClock.Instant?
    private var heartbeatMS = 10_000
    /// 退避等待中；`reconnectIfStale` 取消它就能立刻重连。
    private var backoffTask: Task<Void, Never>?
    private var skipBackoff = false

    private struct Cursor: Encodable {
        let seq: Int
        var epoch: String?
    }

    private enum SubscriptionKind: String, Sendable {
        case session
        case transcript
    }

    private struct PendingSubscription: Sendable {
        let kind: SubscriptionKind
        let sessionID: String
    }

    init(
        endpoint: Endpoint,
        clientID: String = "ios_\(UUID().uuidString.prefix(8))",
        wireProtocol: TranscriptProtocol = .legacy,
        tokenProvider: @escaping @Sendable () async -> String?
    ) {
        self.endpoint = endpoint
        self.clientID = clientID
        self.wireProtocol = wireProtocol
        self.tokenProvider = tokenProvider
    }

    /// 开始连接，返回信号流。重连由内部自动处理，流不会因为断线而结束。
    func start() -> AsyncStream<StreamSignal> {
        // 不能丢：重连时服务端一次补发的批次可能上千条，丢了任何一批正文都会缺一块。
        let (stream, continuation) = AsyncStream<StreamSignal>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = continuation
        isStopped = false
        pumpTask = Task { await runLoop() }
        return stream
    }

    func stop() {
        isStopped = true
        canSendSubscriptions = false
        pumpTask?.cancel()
        backoffTask?.cancel()
        keepAliveTask?.cancel()
        cancelSubscriptionRetries()
        pendingSubscriptionAcks.removeAll()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        continuation?.finish()
        continuation = nil
    }

    /// 旧版另发 subscribe_v2 订阅 transcript；2.6+ 这个 subscribe 同时覆盖正文与状态。
    func subscribe(to sessionID: String) async {
        subscribedSessions.insert(sessionID)
        clearSubscriptionRetry(kind: .session, sessionID: sessionID)
        guard canSendSubscriptions else { return }
        await sendSessionSubscription(sessionID)
    }

    /// 订阅对话正文的逐字增量（与网页端 `sendTranscriptSubscribe` 一致：`main` 走 `delta` 级别）。
    /// `since` 是已经拿到的批次序号：服务端据此补发缺的 ops，补不上就发一个 `transcript.reset`。
    func subscribeTranscript(_ sessionID: String, since: Int?) async {
        guard wireProtocol == .legacy else { return }
        transcriptSubscriptions[sessionID] = since
        clearSubscriptionRetry(kind: .transcript, sessionID: sessionID)
        guard canSendSubscriptions else { return }
        await sendTranscriptSubscribe(sessionID)
    }

    /// 上层应用完一批 ops 后回报序号，重连时用。
    func noteTranscriptSeq(_ sessionID: String, seq: Int) {
        guard transcriptSubscriptions[sessionID] != nil else { return }
        transcriptSubscriptions[sessionID] = seq
    }

    private func sendTranscriptSubscribe(_ sessionID: String) async {
        var payload: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "transcript": .object(["main": .string("delta")]),
        ]
        if let since = transcriptSubscriptions[sessionID] ?? nil {
            payload["transcript_since"] = .object(["main": .number(Double(since))])
        }
        let id = nextMessageID()
        pendingSubscriptionAcks[id] = PendingSubscription(kind: .transcript, sessionID: sessionID)
        await send([
            "type": .string("subscribe_v2"),
            "id": .string(id),
            "payload": .object(payload),
        ])
    }

    func unsubscribe(from sessionID: String) async {
        subscribedSessions.remove(sessionID)
        transcriptSubscriptions.removeValue(forKey: sessionID)
        clearSubscriptionRetry(kind: .session, sessionID: sessionID)
        clearSubscriptionRetry(kind: .transcript, sessionID: sessionID)
        guard canSendSubscriptions else { return }
        if wireProtocol == .conversation {
            await send([
                "type": .string("unsubscribe"),
                "request_id": .string(nextMessageID()),
                "session_id": .string(sessionID),
                "agent_ids": .array([.string("main")]),
            ])
            return
        }
        await send([
            "type": .string("unsubscribe"),
            "id": .string(nextMessageID()),
            "payload": .object(["session_ids": .array([.string(sessionID)])]),
        ])
        await send([
            "type": .string("unsubscribe_v2"),
            "id": .string(nextMessageID()),
            "payload": .object(["session_id": .string(sessionID)]),
        ])
    }

    /// App 回到前台时调用（对照网页端 focus / visibilitychange 时的 stale 检查）：
    /// 超过两个心跳周期没收到任何帧，说明连接在后台已经断了，立刻重连，不等系统报错和退避。
    func reconnectIfStale() {
        guard !isStopped else { return }
        if task != nil {
            let limit = Duration.milliseconds(max(heartbeatMS * 2, 10_000))
            guard let lastActivity, ContinuousClock.now - lastActivity > limit else { return }
            logger.info("ws 回到前台时已失联，重连")
        }
        reconnectNow()
    }

    /// 不管连接看起来活没活着，立刻断开重连（跳过退避）。在后台被挂起过一段时间后用：
    /// 这时连接多半已经被系统掐掉，只是还没报错，不必等心跳超时才发现。重连带着游标，缺的正文由服务端补发。
    func reconnectNow() {
        guard !isStopped else { return }
        if let task {
            skipBackoff = true
            task.cancel(with: .goingAway, reason: nil)
        } else {
            // 正在退避等待：跳过剩下的等待。
            reconnectAttempt = 0
            backoffTask?.cancel()
        }
    }

    // MARK: 连接循环

    private func runLoop() async {
        while !isStopped, !Task.isCancelled {
            do {
                try await connectOnce()
                reconnectAttempt = 0
                // connectOnce 正常返回 = 对端关了连接。
                continuation?.yield(.disconnected(reason: "连接关闭"))
            } catch is CancellationError {
                return
            } catch {
                logger.error("ws 断开：\(error.localizedDescription)")
                continuation?.yield(.disconnected(reason: error.localizedDescription))
            }
            if isStopped || Task.isCancelled { return }
            if skipBackoff {
                skipBackoff = false
                reconnectAttempt = 0
                continue
            }
            reconnectAttempt += 1
            // 指数退避，上限 30s —— 与桌面端隧道的退避一致。
            let delay = min(30.0, pow(2.0, Double(min(reconnectAttempt - 1, 5))))
            let backoff = Task { _ = try? await Task.sleep(for: .seconds(delay)) }
            backoffTask = backoff
            await backoff.value
            backoffTask = nil
        }
    }

    private func connectOnce() async throws {
        pendingSubscriptionAcks.removeAll()
        cancelSubscriptionRetries()
        guard let url = endpoint.webSocketURL(clientID: clientID) else {
            throw KapError.http(status: 0, body: "无法构造 WS 地址")
        }
        var request = URLRequest(url: url)
        // relay 接受 Authorization 头（已实测）。浏览器因为不能设 WS 请求头才必须用
        // `kimi-code.bearer.<token>` subprotocol，原生端不需要。
        let token = await tokenProvider()
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        // 新连接从现在起算，别拿上一条连接的时间误判它失联。
        lastActivity = .now
        task.resume()

        defer {
            canSendSubscriptions = false
            keepAliveTask?.cancel()
            keepAliveTask = nil
            task.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
            if self.task === task { self.task = nil }
        }

        if wireProtocol == .conversation {
            // 2.6 连接打开后直接订阅；没有 server_hello / client_hello。
            canSendSubscriptions = true
            for sessionID in subscribedSessions {
                await sendSessionSubscription(sessionID)
            }
            continuation?.yield(.connected(heartbeatMS: nil))
        } else {
            // 第一帧必须是 server_hello。
            let helloData = try await receiveFrameData(on: task)
            let hello = decodeJSONObject(from: helloData)
            guard hello["type"]?.stringValue == "server_hello" else {
                throw KapError.http(status: 0, body: "期待 server_hello，收到 \(hello["type"]?.stringValue ?? "?")")
            }
            lastActivity = .now
            let heartbeatMS = hello["payload"]?["heartbeat_ms"]?.intValue
            if let heartbeatMS { self.heartbeatMS = heartbeatMS }
            logger.info("server_hello protocol=\(hello["payload"]?["protocol_version"]?.intValue ?? -1)")

            // client_hello：把已订阅的会话和游标一起带上，服务端会回 ack。
            await send([
                "type": .string("client_hello"),
                "id": .string(nextMessageID()),
                "payload": .object([
                    "client_id": .string(clientID),
                    "subscriptions": .array(subscribedSessions.map { .string($0) }),
                    "cursors": cursorPayload(for: subscribedSessions),
                ]),
            ])
            canSendSubscriptions = true

            for sessionID in transcriptSubscriptions.keys {
                await sendTranscriptSubscribe(sessionID)
            }

            continuation?.yield(.connected(heartbeatMS: heartbeatMS))
            startKeepAlive(intervalMS: heartbeatMS ?? 10_000)
        }

        while !isStopped, !Task.isCancelled {
            let data = try await receiveFrameData(on: task)
            lastActivity = .now
            handle(data)
        }
    }

    private func startKeepAlive(intervalMS: Int) {
        keepAliveTask?.cancel()
        // 服务端实测 heartbeat_ms=10000，按它的一半发 ping，别硬编码 30s。
        let interval = Duration.milliseconds(max(2000, intervalMS / 2))
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.sendPing()
            }
        }
    }

    private func sendPing() async {
        await send([
            "type": .string("ping"),
            "id": .string(nextMessageID()),
            "payload": .object([:]),
        ])
    }

    // MARK: 收发

    private func receiveFrameData(on task: URLSessionWebSocketTask) async throws -> Data {
        let message = try await task.receive()
        switch message {
        case let .data(payload): return payload
        case let .string(text): return Data(text.utf8)
        @unknown default: return Data()
        }
    }

    private func decodeJSONObject(from data: Data) -> [String: JSONValue] {
        guard !data.isEmpty else { return [:] }
        do {
            return try decoder.decode([String: JSONValue].self, from: data)
        } catch {
            logger.error("ws 帧解析失败：\(String(data: data.prefix(200), encoding: .utf8) ?? "")")
            return [:]
        }
    }

    private func handle(_ data: Data) {
        guard !data.isEmpty else { return }
        let header: FrameHeader
        do {
            header = try decoder.decode(FrameHeader.self, from: data)
        } catch {
            logger.error("ws 帧头解析失败：\(String(data: data.prefix(200), encoding: .utf8) ?? "")")
            return
        }

        switch header.type {
        case "pong":
            return

        case "ping":
            if wireProtocol == .conversation {
                Task { [weak self] in
                    await self?.sendRaw(#"{"type":"pong"}"#)
                }
            }
            return

        case "turns", "turns.removed", "turns.failed", "turn.started", "turn.updated", "turn.ended",
             "item.started", "item.updated", "item.ended", "item.delta", "item.removed", "notice":
            guard wireProtocol == .conversation,
                  header.agentID == "main",
                  let sessionID = header.sessionID else { return }
            do {
                let event = try decoder.decode(ConversationWireEvent.self, from: data)
                continuation?.yield(.conversation(sessionID: sessionID, event))
            } catch {
                logger.error("conversation 帧解析失败：\(error.localizedDescription)")
                continuation?.yield(.resyncRequired([sessionID]))
            }
            return

        case "agent":
            guard header.agentID == "main", let sessionID = header.sessionID else { return }
            do {
                let state = try decoder.decode(SessionAgentState.self, from: data)
                continuation?.yield(.agentState(sessionID: sessionID, state))
            } catch {
                logger.error("agent 状态帧解析失败：\(error.localizedDescription)")
            }
            return

        case "context", "usage":
            guard header.agentID == "main", let sessionID = header.sessionID else { return }
            do {
                let usage = try decoder.decode(SessionContextUsage.self, from: data)
                continuation?.yield(.agentUsage(sessionID: sessionID, usage))
            } catch {
                logger.error("\(header.type) 状态帧解析失败：\(error.localizedDescription)")
            }
            return

        case "interaction":
            do {
                let interaction = try decoder.decode(InteractionFrame.self, from: data)
                continuation?.yield(.interaction(interaction))
            } catch {
                logger.error("interaction 帧解析失败：\(error.localizedDescription)")
            }
            return

        case "transcript.reset", "transcript.ops":
            // 正文增量走专门的解码：直接从原始帧解出 payload，省去二次序列化。
            guard let sessionID = header.sessionID else { return }
            do {
                let envelope = try decoder.decode(TranscriptEnvelope.self, from: data)
                continuation?.yield(.transcript(sessionID: sessionID, envelope.payload))
            } catch {
                logger.error("transcript 帧解析失败：\(error.localizedDescription)")
                // 解不开就当接不上：让上层全量重拉。
                continuation?.yield(.resyncRequired([sessionID]))
            }
            return

        case "response", "ack", "resync_required", "error":
            handleControlFrame(type: header.type, frame: decodeJSONObject(from: data))
            return

        default:
            break
        }

        // 其余都当会话事件。`volatile` 的帧（打字机增量那种）不推进游标。
        guard let event = try? decoder.decode(SessionEventFrame.self, from: data) else { return }

        if let sessionID = event.sessionID, let seq = event.seq, event.volatile != true {
            let existing = cursors[sessionID]?.seq ?? -1
            if seq > existing {
                cursors[sessionID] = Cursor(seq: seq, epoch: event.epoch ?? cursors[sessionID]?.epoch)
            }
        }
        continuation?.yield(.event(event))
    }

    private func handleControlFrame(type: String, frame: [String: JSONValue]) {
        switch type {
        case "response":
            guard wireProtocol == .conversation,
                  let id = frame["request_id"]?.stringValue,
                  let pending = pendingSubscriptionAcks.removeValue(forKey: id) else { return }
            let code = frame["code"]?.intValue ?? -1
            if code == 0 {
                clearSubscriptionRetry(kind: pending.kind, sessionID: pending.sessionID)
                continuation?.yield(.interactionsReset(sessionID: pending.sessionID))
            } else {
                scheduleSubscriptionRetry(kind: pending.kind, sessionID: pending.sessionID)
                let message = frame["msg"]?.stringValue ?? "订阅失败（code \(code)）"
                continuation?.yield(.subscriptionFailed(sessionID: pending.sessionID, message: message))
            }

        case "ack":
            let payload = frame["payload"]
            // 旧版 subscribe / client_hello 的游标恢复仍保留；2.5+ 的 transcript_since 在 subscribe_v2 中处理。
            if let sessions = payload?["resync_required"]?.arrayValue?.compactMap(\.stringValue),
               !sessions.isEmpty {
                logger.info("需要重新拉取历史：\(sessions.joined(separator: ","))")
                continuation?.yield(.resyncRequired(sessions))
            }
            if let cursors = payload?["cursors"]?.objectValue {
                for (sessionID, cursor) in cursors {
                    if let seq = cursor["seq"]?.intValue {
                        self.cursors[sessionID] = Cursor(seq: seq, epoch: cursor["epoch"]?.stringValue)
                    }
                }
            }
            if let id = frame["id"]?.stringValue,
               let pending = pendingSubscriptionAcks.removeValue(forKey: id) {
                let code = frame["code"]?.intValue ?? 0
                let accepted = payload?["accepted"]?.arrayValue?.compactMap(\.stringValue)
                    ?? payload?["accepted_subscriptions"]?.arrayValue?.compactMap(\.stringValue)
                    ?? []
                let notFound = payload?["not_found"]?.arrayValue?.compactMap(\.stringValue) ?? []
                if code == 0 {
                    for sessionID in accepted {
                        clearSubscriptionRetry(kind: pending.kind, sessionID: sessionID)
                        continuation?.yield(.interactionsReset(sessionID: sessionID))
                    }
                }
                let failed = code == 0 ? notFound : [pending.sessionID]
                for sessionID in failed {
                    scheduleSubscriptionRetry(kind: pending.kind, sessionID: sessionID)
                    let message = frame["msg"]?.stringValue
                        ?? payload?["msg"]?.stringValue
                        ?? (code == 0 ? "会话尚未就绪" : "订阅失败（code \(code)）")
                    continuation?.yield(.subscriptionFailed(sessionID: sessionID, message: message))
                }
            }

        case "resync_required":
            let sessions = frame["payload"]?["session_ids"]?.arrayValue?.compactMap(\.stringValue)
                ?? frame["session_id"]?.stringValue.map { [$0] }
                ?? []
            continuation?.yield(.resyncRequired(sessions))

        case "error":
            let message = frame["payload"]?["message"]?.stringValue
                ?? frame["msg"]?.stringValue
                ?? "未知错误"
            logger.error("ws error：\(message)")

        default:
            break
        }
    }

    private func scheduleSubscriptionRetry(kind: SubscriptionKind, sessionID: String) {
        let key = retryKey(kind: kind, sessionID: sessionID)
        guard !isStopped, subscriptionRetries[key] == nil else { return }
        let attempt = subscriptionRetryAttempts[key] ?? 0
        let delayMS = attempt >= 8 ? 30_000 : min(4_000, 250 * (1 << min(attempt, 4)))
        subscriptionRetries[key] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(delayMS)) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.fireSubscriptionRetry(kind: kind, sessionID: sessionID)
        }
    }

    private func fireSubscriptionRetry(kind: SubscriptionKind, sessionID: String) async {
        let key = retryKey(kind: kind, sessionID: sessionID)
        subscriptionRetries[key] = nil
        guard !isStopped, canSendSubscriptions else { return }
        subscriptionRetryAttempts[key, default: 0] += 1
        switch kind {
        case .session:
            guard subscribedSessions.contains(sessionID) else { return }
            await sendSessionSubscription(sessionID)
        case .transcript:
            guard transcriptSubscriptions[sessionID] != nil else { return }
            await sendTranscriptSubscribe(sessionID)
        }
    }

    private func sendSessionSubscription(_ sessionID: String) async {
        let id = nextMessageID()
        pendingSubscriptionAcks[id] = PendingSubscription(kind: .session, sessionID: sessionID)
        if wireProtocol == .conversation {
            await send([
                "type": .string("subscribe"),
                "request_id": .string(id),
                "session_id": .string(sessionID),
                "agent_ids": .array([.string("main")]),
            ])
            return
        }
        await send([
            "type": .string("subscribe"),
            "id": .string(id),
            "payload": .object([
                "session_ids": .array([.string(sessionID)]),
                "cursors": cursorPayload(for: [sessionID]),
            ]),
        ])
    }

    private func clearSubscriptionRetry(kind: SubscriptionKind, sessionID: String) {
        let key = retryKey(kind: kind, sessionID: sessionID)
        subscriptionRetries[key]?.cancel()
        subscriptionRetries[key] = nil
        subscriptionRetryAttempts[key] = nil
    }

    private func cancelSubscriptionRetries() {
        for task in subscriptionRetries.values { task.cancel() }
        subscriptionRetries.removeAll()
        subscriptionRetryAttempts.removeAll()
    }

    private func retryKey(kind: SubscriptionKind, sessionID: String) -> String {
        "\(kind.rawValue):\(sessionID)"
    }

    private func send(_ payload: [String: JSONValue]) async {
        guard
            let data = try? encoder.encode(payload),
            let text = String(data: data, encoding: .utf8)
        else { return }
        await sendRaw(text)
    }

    private func sendRaw(_ text: String) async {
        guard let task else { return }
        do {
            try await task.send(.string(text))
        } catch {
            logger.error("ws 发送失败：\(error.localizedDescription)")
        }
    }

    private func cursorPayload(for sessions: some Collection<String>) -> JSONValue {
        var result: [String: JSONValue] = [:]
        for sessionID in sessions {
            guard let cursor = cursors[sessionID] else { continue }
            var entry: [String: JSONValue] = ["seq": .number(Double(cursor.seq))]
            if let epoch = cursor.epoch { entry["epoch"] = .string(epoch) }
            result[sessionID] = .object(entry)
        }
        return .object(result)
    }

    private func nextMessageID() -> String {
        messageSeq += 1
        return "\(clientID)-\(messageSeq)"
    }
}
