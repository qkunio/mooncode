import Foundation

@main
struct SessionListChecks {
    static func main() throws {
        try testPreservesNewSessionAcrossStaleAndFlappingFetches()
        try testPromptMetadataSurvivesStaleFetchAndUpdatesFromWS()
        try testRenameSurvivesStaleScanUntilServerConverges()
        try testDeletionTombstoneSuppressesStaleResurrection()
        try testRetentionExpiresSoRemoteDeletionConverges()
        try testResetClearsStateOnDeviceSwitch()
        try testDecodesSessionEventFrameFrom28()
        print("PASS: session pool preservation, flapping 2.8 index survival, prompt/title merge, deletion tombstones, retention expiry, and 2.8 WS session event decoding")
    }

    private static func makeSession(
        id: String,
        workspaceID: String? = "wm_1",
        title: String? = "",
        lastPrompt: String? = nil,
        updatedAt: Date,
        activity: String = "idle",
        busy: Bool = false,
        archived: Bool = false
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            workspaceID: workspaceID,
            cwd: "/Users/test/repo",
            title: title,
            createdAt: FlexibleDate(date: updatedAt),
            updatedAt: FlexibleDate(date: updatedAt),
            activity: activity,
            busy: busy,
            mainTurnActive: activity == "turn",
            pendingInteraction: .none,
            lastTurnReason: nil,
            archived: archived,
            lastPrompt: lastPrompt,
            metadata: nil,
            usage: nil
        )
    }

    /// 复现 Kimi Code 2.8 实测场景：+50ms 命中 pendingMap，+200ms mirror flush 后从 GET /sessions 消失。
    private static func testPreservesNewSessionAcrossStaleAndFlappingFetches() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var pool = SessionListPool(retentionWindow: 90)
        let old = makeSession(id: "s-old", title: "旧对话", updatedAt: t0.addingTimeInterval(-300))
        let created = makeSession(id: "s-new", title: "", updatedAt: t0)

        pool.reconcile(fetched: [old], now: t0)
        precondition(pool.sessions.map(\.id) == ["s-old"])

        pool.recordCreated(created, now: t0)
        precondition(pool.sessions.map(\.id) == ["s-new", "s-old"])

        // +50ms：服务端临时包含 s-new（pendingMap 尚未 flush）
        pool.reconcile(fetched: [created, old], now: t0.addingTimeInterval(0.05))
        precondition(pool.sessions.map(\.id) == ["s-new", "s-old"])

        // +200ms：服务端 flush 后退回 30s 旧扫描，不再包含 s-new -> 客户端仍须保活
        pool.reconcile(fetched: [old], now: t0.addingTimeInterval(0.2))
        precondition(pool.sessions.map(\.id) == ["s-new", "s-old"])

        // +25s：仍在保护窗口内，继续保活
        pool.reconcile(fetched: [old], now: t0.addingTimeInterval(25))
        precondition(pool.sessions.map(\.id) == ["s-new", "s-old"])
    }

    private static func testPromptMetadataSurvivesStaleFetchAndUpdatesFromWS() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var pool = SessionListPool(retentionWindow: 90)
        let created = makeSession(id: "s-new", title: "", lastPrompt: nil, updatedAt: t0)
        pool.recordCreated(created, now: t0)
        precondition(pool.sessions[0].displayTitle == "repo")

        // 发第一条消息：侧栏立刻显示消息摘要并标忙
        pool.recordPromptSent(sessionID: "s-new", text: "帮我检查 2.8 新建对话延迟", now: t0.addingTimeInterval(1))
        precondition(pool.sessions[0].displayTitle == "帮我检查 2.8 新建对话延迟")
        precondition(pool.sessions[0].busy == true)

        // 服务端返回陈旧的空标题快照（updatedAt 更早）：不得抹掉已显示的 lastPrompt
        let stale = makeSession(id: "s-new", title: "", lastPrompt: nil, updatedAt: t0, activity: "turn", busy: true)
        pool.reconcile(fetched: [stale], now: t0.addingTimeInterval(2))
        precondition(pool.sessions[0].displayTitle == "帮我检查 2.8 新建对话延迟")

        // WS 实时推来自动生成的标题（即便电脑时钟比手机慢 3 秒也应采纳）
        let wsTitled = makeSession(
            id: "s-new",
            title: "排查 2.8 新建会话延迟",
            lastPrompt: "帮我检查 2.8 新建对话延迟",
            updatedAt: t0.addingTimeInterval(-2),
            activity: "idle",
            busy: false
        )
        pool.applyLiveEvent(change: "updated", session: wsTitled, now: t0.addingTimeInterval(5))
        precondition(pool.sessions[0].displayTitle == "排查 2.8 新建会话延迟")
        precondition(pool.sessions[0].busy == false)
    }

    private static func testRenameSurvivesStaleScanUntilServerConverges() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var pool = SessionListPool(retentionWindow: 90)
        let original = makeSession(id: "s-1", title: "原标题", updatedAt: t0)
        pool.reconcile(fetched: [original], now: t0)

        let renamed = makeSession(id: "s-1", title: "新标题", updatedAt: t0)
        pool.recordRenamed(renamed, now: t0.addingTimeInterval(1))
        precondition(pool.sessions[0].displayTitle == "新标题")

        // 服务端 30s 扫描缓存仍返回原标题（updatedAt 相同）：不回退
        pool.reconcile(fetched: [original], now: t0.addingTimeInterval(5))
        precondition(pool.sessions[0].displayTitle == "新标题")

        // 服务端收敛后返回新标题
        pool.reconcile(fetched: [renamed], now: t0.addingTimeInterval(35))
        precondition(pool.sessions[0].displayTitle == "新标题")
    }

    private static func testDeletionTombstoneSuppressesStaleResurrection() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var pool = SessionListPool(retentionWindow: 90)
        let target = makeSession(id: "s-del", title: "要删的会话", updatedAt: t0)
        pool.recordCreated(target, now: t0)
        pool.recordRemoved("s-del")
        precondition(pool.sessions.isEmpty)

        // 服务端陈旧快照仍含 s-del：不应复活
        pool.reconcile(fetched: [target], now: t0.addingTimeInterval(2))
        precondition(pool.sessions.isEmpty)

        // 服务端已不再返回 s-del：墓碑自动收敛清理
        pool.reconcile(fetched: [], now: t0.addingTimeInterval(35))
        precondition(pool.sessions.isEmpty)

        // 如果随后通过 WS restore 恢复，应重新出现
        pool.applyLiveEvent(change: "restored", session: target, now: t0.addingTimeInterval(40))
        precondition(pool.sessions.map(\.id) == ["s-del"])
    }

    private static func testRetentionExpiresSoRemoteDeletionConverges() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var pool = SessionListPool(retentionWindow: 90)
        let created = makeSession(id: "s-temp", title: "临时会话", updatedAt: t0)
        pool.recordCreated(created, now: t0)

        // 89s 内仍受保护
        pool.reconcile(fetched: [], now: t0.addingTimeInterval(89))
        precondition(pool.sessions.map(\.id) == ["s-temp"])

        // 90s 后保护过期，若远端已删除则干净消失，不残留僵尸项
        pool.reconcile(fetched: [], now: t0.addingTimeInterval(91))
        precondition(pool.sessions.isEmpty)
    }

    private static func testResetClearsStateOnDeviceSwitch() throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var pool = SessionListPool(retentionWindow: 90)
        pool.recordCreated(makeSession(id: "s-a", updatedAt: t0), now: t0)
        pool.recordRemoved("s-del")
        pool.reset()
        precondition(pool.sessions.isEmpty)
        let otherDevice = makeSession(id: "s-del", updatedAt: t0)
        pool.reconcile(fetched: [otherDevice], now: t0)
        precondition(pool.sessions.map(\.id) == ["s-del"])
    }

    private static func testDecodesSessionEventFrameFrom28() throws {
        let json = """
        {
          "type": "session",
          "change": "created",
          "session": {
            "id": "session_abc",
            "workspace_id": "wm_123",
            "workspace_root": "/Users/test/repo",
            "cwd": "/Users/test/repo",
            "title": "新对话标题",
            "created_at": "2026-11-27T08:43:32.719Z",
            "updated_at": "2026-11-27T08:43:35.000Z",
            "activity": "turn",
            "pending_interaction": "none",
            "archived": false,
            "last_prompt": "你好"
          },
          "event_created_at": "2026-11-27T08:43:35.010Z"
        }
        """
        let frame = try JSONDecoder().decode(SessionEventFrame.self, from: Data(json.utf8))
        precondition(frame.type == "session")
        precondition(frame.change == "created")
        precondition(frame.sessionID == "session_abc")
        precondition(frame.session?.id == "session_abc")
        precondition(frame.session?.workspaceID == "wm_123")
        precondition(frame.session?.displayTitle == "新对话标题")
        precondition(frame.session?.busy == true)
    }
}
