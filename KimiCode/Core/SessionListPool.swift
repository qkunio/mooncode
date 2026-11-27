import Foundation

extension SessionSummary {
    init(
        id: String,
        workspaceID: String?,
        cwd: String?,
        title: String?,
        createdAt: FlexibleDate?,
        updatedAt: FlexibleDate?,
        activity: String?,
        busy: Bool,
        mainTurnActive: Bool?,
        pendingInteraction: PendingInteraction,
        lastTurnReason: String?,
        archived: Bool?,
        lastPrompt: String?,
        metadata: Metadata?,
        usage: Usage?
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.cwd = cwd
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.activity = activity
        self.busy = busy
        self.mainTurnActive = mainTurnActive
        self.pendingInteraction = pendingInteraction
        self.lastTurnReason = lastTurnReason
        self.archived = archived
        self.lastPrompt = lastPrompt
        self.metadata = metadata
        self.usage = usage
    }

    /// 按需覆盖部分字段，用于本地新建会话补齐工作区 / 首条消息预览或合并服务端快照。
    func updating(
        workspaceID: String?? = nil,
        title: String?? = nil,
        updatedAt: FlexibleDate?? = nil,
        activity: String?? = nil,
        busy: Bool? = nil,
        mainTurnActive: Bool?? = nil,
        archived: Bool?? = nil,
        lastPrompt: String?? = nil
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            workspaceID: workspaceID ?? self.workspaceID,
            cwd: cwd,
            title: title ?? self.title,
            createdAt: createdAt,
            updatedAt: updatedAt ?? self.updatedAt,
            activity: activity ?? self.activity,
            busy: busy ?? self.busy,
            mainTurnActive: mainTurnActive ?? self.mainTurnActive,
            pendingInteraction: pendingInteraction,
            lastTurnReason: lastTurnReason,
            archived: archived ?? self.archived,
            lastPrompt: lastPrompt ?? self.lastPrompt,
            metadata: metadata,
            usage: usage
        )
    }

    var hasNonEmptyTitle: Bool {
        guard let title else { return false }
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasNonEmptyLastPrompt: Bool {
        guard let lastPrompt else { return false }
        return !lastPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 侧栏会话列表状态机：对齐官方网页端 `notePoolInsert` 机制，避免服务端读模型短暂滞后
/// （例如 Kimi Code 2.8 的 30 秒降级扫描缓存或 60 秒索引对账窗口）把刚新建的会话冲掉。
struct SessionListPool: Sendable {
    /// 覆盖上游 30s `SHARED_SCAN_REUSE_MS` 与 60s `RECONCILE_INTERVAL_MS` 窗口。
    static let defaultRetentionWindow: TimeInterval = 90
    private static let maxPinnedEntries = 64

    struct PinnedEntry: Sendable {
        var session: SessionSummary
        var pinnedAt: Date
        var preferLocalTitle = false
    }

    private(set) var sessions: [SessionSummary] = []
    private var pinned: [String: PinnedEntry] = [:]
    private var removedIDs: Set<String> = []
    private let retentionWindow: TimeInterval

    init(retentionWindow: TimeInterval = defaultRetentionWindow) {
        self.retentionWindow = retentionWindow
    }

    mutating func reset() {
        sessions = []
        pinned = [:]
        removedIDs = []
    }

    /// 本地 `POST /sessions` 建好新会话，或收到 WS `session.created` / `session.restored`。
    mutating func recordCreated(_ session: SessionSummary, now: Date = Date()) {
        guard session.archived != true else {
            recordRemoved(session.id)
            return
        }
        removedIDs.remove(session.id)
        let merged = merge(existing: existingSession(for: session.id), incoming: session)
        pin(merged, now: now)
        upsertInSessions(merged)
    }

    /// 发送消息后本地乐观更新 `lastPrompt` / `updatedAt` / `busy`，
    /// 让侧栏立即显示消息摘要并置顶，同时续期保护窗口，防止随后刷新被旧快照覆盖。
    mutating func recordPromptSent(sessionID: String, text: String, now: Date = Date()) {
        guard !removedIDs.contains(sessionID),
              let existing = existingSession(for: sessionID) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextUpdated = maxDate(existing.updatedAt?.date, now)
        let updated = existing.updating(
            updatedAt: .some(FlexibleDate(date: nextUpdated)),
            activity: .some("turn"),
            busy: true,
            mainTurnActive: .some(true),
            lastPrompt: trimmed.isEmpty ? nil : .some(trimmed)
        )
        pin(updated, now: now)
        upsertInSessions(updated)
    }

    /// 收到 WS 全局 `type == "session"` 事件（来自服务端实时内存元数据，非陈旧磁盘扫描）。
    mutating func applyLiveEvent(change: String, session: SessionSummary, now: Date = Date()) {
        switch change {
        case "deleted", "archived":
            recordRemoved(session.id)
        case "created", "restored":
            recordCreated(session, now: now)
        case "updated":
            if session.archived == true {
                recordRemoved(session.id)
                return
            }
            guard !removedIDs.contains(session.id) else { return }
            let merged = merge(
                existing: existingSession(for: session.id),
                incoming: session,
                trustIncomingMetadata: true
            )
            // 已在保护期内的会话一并续期，避免紧接着被陈旧列表冲掉。
            if pinned[session.id] != nil {
                pin(merged, now: now, preferLocalTitle: false)
            }
            upsertInSessions(merged)
        default:
            break
        }
    }

    /// 侧栏手动重命名后立即同步（服务端 `setTitle` 不推进 `updatedAt`，保护期内优先保留新标题）。
    mutating func recordRenamed(_ updated: SessionSummary, now: Date = Date()) {
        guard !removedIDs.contains(updated.id) else { return }
        let merged = merge(
            existing: existingSession(for: updated.id),
            incoming: updated,
            trustIncomingMetadata: true
        )
        pin(merged, now: now, preferLocalTitle: updated.hasNonEmptyTitle)
        upsertInSessions(merged)
    }

    /// 本地删除或远端归档/删除：记墓碑，防止陈旧的 `GET /sessions` 响应把已删会话复活。
    mutating func recordRemoved(_ sessionID: String) {
        pinned.removeValue(forKey: sessionID)
        removedIDs.insert(sessionID)
        sessions.removeAll { $0.id == sessionID }
    }

    /// 用 `GET /sessions` 返回结果对账，同时保留保护窗口内服务端暂未索引到的新建会话。
    mutating func reconcile(fetched: [SessionSummary], now: Date = Date()) {
        let fetchedIDs = Set(fetched.map(\.id))

        // 服务端已经不再返回被删/归档的会话：清理已收敛的墓碑。
        removedIDs = removedIDs.filter { fetchedIDs.contains($0) }

        // 清理超过保护期的固定项（避免远端已删除/归档的旧会话长期滞留成僵尸项）。
        pinned = pinned.filter { _, entry in
            now.timeIntervalSince(entry.pinnedAt) < retentionWindow
        }

        var result: [SessionSummary] = []
        result.reserveCapacity(fetched.count + pinned.count)
        var seen = Set<String>()

        for item in fetched {
            guard !removedIDs.contains(item.id), seen.insert(item.id).inserted else { continue }
            if let pinnedEntry = pinned[item.id] {
                let keepTitle = pinnedEntry.preferLocalTitle && item.title != pinnedEntry.session.title
                let merged = merge(
                    existing: pinnedEntry.session,
                    incoming: item,
                    trustIncomingMetadata: false,
                    preferExistingTitle: keepTitle
                )
                // 即使本次 GET /sessions 看到了（例如 2.8 在 +50ms 从 pendingMap 读到），
                // 也不提前解除保护，避免 +150ms mirror flush 后下一次刷新把它丢掉。
                pinned[item.id] = PinnedEntry(
                    session: merged,
                    pinnedAt: pinnedEntry.pinnedAt,
                    preferLocalTitle: keepTitle
                )
                result.append(merged)
            } else {
                result.append(item)
            }
        }

        // 服务端列表里缺失但仍在保护期内的会话，合并保留下来。
        for (id, entry) in pinned {
            guard !seen.contains(id), !removedIDs.contains(id), entry.session.archived != true else { continue }
            seen.insert(id)
            result.append(entry.session)
        }

        sessions = sortByRecency(result)
    }

    // MARK: 内部辅助

    private func existingSession(for id: String) -> SessionSummary? {
        pinned[id]?.session ?? sessions.first { $0.id == id }
    }

    private mutating func pin(_ session: SessionSummary, now: Date, preferLocalTitle: Bool? = nil) {
        let keepTitle = preferLocalTitle ?? pinned[session.id]?.preferLocalTitle ?? false
        pinned[session.id] = PinnedEntry(session: session, pinnedAt: now, preferLocalTitle: keepTitle)
        if pinned.count > Self.maxPinnedEntries {
            let overflow = pinned.count - Self.maxPinnedEntries
            let oldest = pinned.sorted { $0.value.pinnedAt < $1.value.pinnedAt }.prefix(overflow)
            for (key, _) in oldest { pinned.removeValue(forKey: key) }
        }
    }

    private mutating func upsertInSessions(_ session: SessionSummary) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
        sessions = sortByRecency(sessions)
    }

    /// 合并同一会话的本地最新状态与新到快照：避免较旧的服务端扫描抹掉刚发出的 prompt、标题或更新时间戳；
    /// WS 实时推送（`trustIncomingMetadata == true`）则不受设备与电脑时钟偏差影响，直接采纳非空新值。
    private func merge(
        existing: SessionSummary?,
        incoming: SessionSummary,
        trustIncomingMetadata: Bool = false,
        preferExistingTitle: Bool = false
    ) -> SessionSummary {
        guard let existing else { return incoming }
        let existingDate = existing.updatedAt?.date ?? .distantPast
        let incomingDate = incoming.updatedAt?.date ?? .distantPast
        let incomingIsOlder = incomingDate < existingDate

        let resolvedWorkspaceID = incoming.workspaceID ?? existing.workspaceID
        let resolvedTitle: String? = if preferExistingTitle, existing.hasNonEmptyTitle {
            existing.title
        } else if !trustIncomingMetadata, incomingIsOlder, existing.hasNonEmptyTitle {
            existing.title
        } else if incoming.hasNonEmptyTitle {
            incoming.title
        } else if existing.hasNonEmptyTitle {
            existing.title
        } else {
            incoming.title ?? existing.title
        }
        let resolvedLastPrompt: String? = if !trustIncomingMetadata, incomingIsOlder, existing.hasNonEmptyLastPrompt {
            existing.lastPrompt
        } else if incoming.hasNonEmptyLastPrompt {
            incoming.lastPrompt
        } else if existing.hasNonEmptyLastPrompt {
            existing.lastPrompt
        } else {
            incoming.lastPrompt ?? existing.lastPrompt
        }
        let resolvedUpdatedAt: FlexibleDate? = incomingIsOlder ? existing.updatedAt : (incoming.updatedAt ?? existing.updatedAt)

        return incoming.updating(
            workspaceID: .some(resolvedWorkspaceID),
            title: .some(resolvedTitle),
            updatedAt: .some(resolvedUpdatedAt),
            lastPrompt: .some(resolvedLastPrompt)
        )
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return max(lhs, rhs)
    }

    private func sortByRecency(_ list: [SessionSummary]) -> [SessionSummary] {
        list.enumerated()
            .sorted { lhs, rhs in
                let lDate = lhs.element.updatedAt?.date ?? .distantPast
                let rDate = rhs.element.updatedAt?.date ?? .distantPast
                if lDate != rDate { return lDate > rDate }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
