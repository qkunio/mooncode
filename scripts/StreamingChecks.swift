import Foundation

@main
struct StreamingChecks {
    static func decode<T: Decodable>(_ type: T.Type = T.self, from json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    static func quoted(_ text: String) -> String {
        let data = try! JSONEncoder().encode(text)
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor
    static func main() async throws {
        try checkUTF16Append()
        try checkConversationIncrementalSyncParity()
        try checkProjectionCacheParity()
        checkStreamPacerSmoothRevealAndFlush()
        try checkBenchmark()
        print("PASS: UTF-16 append, incremental conversation sync parity, projection cache parity, stream pacer grapheme/burst/flush behavior, and streaming performance benchmark")
    }

    // MARK: - 1. UTF-16 appendInPlace 边界用例

    static func checkUTF16Append() throws {
        // 常规尾部快路径（ASCII + 中文 + 复合 Emoji）
        var text = "你好"
        precondition(TranscriptState.appendInPlace(&text, offset: 2, chunk: "世界🚀"))
        precondition(text == "你好世界🚀")
        precondition(text.utf16.count == 6) // 4 BMP + 2 surrogate units

        // 完全重叠回放（重连重复帧）
        precondition(TranscriptState.appendInPlace(&text, offset: 2, chunk: "世界"))
        precondition(text == "你好世界🚀")

        // 部分重叠回放（含尾部新增）
        precondition(TranscriptState.appendInPlace(&text, offset: 4, chunk: "🚀完成"))
        precondition(text == "你好世界🚀完成")

        // 含复合 Emoji（ZWJ 序列，多个 UTF-16 码元）的精确偏移拼接与重叠
        var family = "a👨‍👩‍👧‍👦"
        let familyOffset = family.utf16.count
        precondition(TranscriptState.appendInPlace(&family, offset: familyOffset, chunk: "结束"))
        precondition(family == "a👨‍👩‍👧‍👦结束")
        precondition(TranscriptState.appendInPlace(&family, offset: 1, chunk: "👨‍👩‍👧‍👦结束!"))
        precondition(family == "a👨‍👩‍👧‍👦结束!")

        // 内容冲突与断档必须返回 false
        var mismatch = "abcdef"
        precondition(!TranscriptState.appendInPlace(&mismatch, offset: 3, chunk: "XYZ"))
        precondition(!TranscriptState.appendInPlace(&mismatch, offset: 7, chunk: "g"))
        precondition(!TranscriptState.appendInPlace(&mismatch, offset: -1, chunk: "a"))
    }

    // MARK: - 2. ConversationState 增量同步与全量投影完全一致

    static func checkConversationIncrementalSyncParity() throws {
        // 先造 20 轮历史对话作为基准
        let historyTurns = (1...20).map { i in
            """
            {"turn_id":"turn-\(i)","ordinal":\(i),"kind":"agent","status":"ended","outcome":"completed",\
            "started_at":"2026-11-27T01:00:00Z","ended_at":"2026-11-27T01:00:05Z","duration_ms":5000,\
            "steps":[{"index":1,"outcome":"completed","started_at":"2026-11-27T01:00:00Z","ended_at":"2026-11-27T01:00:05Z"}],\
            "items":[\
              {"type":"user_message","item_id":"u-\(i)","status":"ended","outcome":"completed","created_at":"2026-11-27T01:00:00Z","prompt_ids":["p-\(i)"],"placement":"opener","origin":{"kind":"user"},"text":"历史问题 \(i)"},\
              {"type":"assistant_message","item_id":"a-\(i)","step_index":1,"status":"ended","outcome":"completed","created_at":"2026-11-27T01:00:01Z","text":"历史回答 **\(i)**"}\
            ]}
            """
        }.joined(separator: ",")
        let page = try decode(ConversationPage.self, from: #"{"turns":[\#(historyTurns)],"has_more":true}"#)
        var conversation = ConversationState(page: page)
        var incremental = conversation.transcriptState
        precondition(incremental == conversation.transcriptState)

        let events: [String] = [
            // 开启第 21 轮
            #"{"type":"turn.started","turn":{"turn_id":"turn-21","ordinal":21,"kind":"agent","status":"running","started_at":"2026-11-27T02:00:00Z","steps":[]}}"#,
            #"{"type":"item.started","turn_id":"turn-21","item":{"type":"user_message","item_id":"u-21","status":"ended","outcome":"completed","created_at":"2026-11-27T02:00:00Z","prompt_ids":["p-21"],"placement":"opener","origin":{"kind":"user"},"text":"优化流式输出"}}"#,
            // 思考流式输出
            #"{"type":"item.started","turn_id":"turn-21","item":{"type":"reasoning","item_id":"r-21","step_index":1,"status":"running","created_at":"2026-11-27T02:00:01Z","text":""}}"#,
            #"{"type":"item.delta","turn_id":"turn-21","item_id":"r-21","field":"text","delta":"先分析瓶颈，\n"}"#,
            #"{"type":"item.delta","turn_id":"turn-21","item_id":"r-21","field":"text","delta":"再整理管线。🚀"}"#,
            #"{"type":"item.ended","turn_id":"turn-21","item":{"type":"reasoning","item_id":"r-21","step_index":1,"status":"ended","outcome":"completed","created_at":"2026-11-27T02:00:01Z","text":"先分析瓶颈，\n再整理管线。🚀"}}"#,
            // 工具调用流式入参 + 输出
            #"{"type":"item.started","turn_id":"turn-21","item":{"type":"tool_call","item_id":"c-21","step_index":1,"status":"running","created_at":"2026-11-27T02:00:02Z","name":"Bash","stage":"input","input_text":""}}"#,
            #"{"type":"item.delta","turn_id":"turn-21","item_id":"c-21","field":"input_text","delta":"{\"command\":\"ls\"}"}"#,
            #"{"type":"item.updated","turn_id":"turn-21","item_id":"c-21","set":{"stage":"executing","input":{"command":"ls"}}}"#,
            #"{"type":"item.delta","turn_id":"turn-21","item_id":"c-21","field":"output","delta":"line 1\n"}"#,
            #"{"type":"item.delta","turn_id":"turn-21","item_id":"c-21","field":"output","delta":"line 2\n"}"#,
            #"{"type":"item.ended","turn_id":"turn-21","item":{"type":"tool_call","item_id":"c-21","step_index":1,"status":"ended","outcome":"completed","created_at":"2026-11-27T02:00:02Z","name":"Bash","input":{"command":"ls"},"output":"line 1\nline 2\n"}}"#,
            // 正文流式输出（含 retry 与清除）
            #"{"type":"turn.updated","turn_id":"turn-21","retry":{"attempt":1,"next_attempt":2,"max_attempts":3,"delay_ms":200,"error":{"name":"Net","message":"jitter"}}}"#,
            #"{"type":"turn.updated","turn_id":"turn-21","step":{"index":2,"outcome":"running","started_at":"2026-11-27T02:00:03Z"}}"#,
            #"{"type":"item.started","turn_id":"turn-21","item":{"type":"assistant_message","item_id":"a-21","step_index":2,"status":"running","created_at":"2026-11-27T02:00:03Z","text":""}}"#,
            #"{"type":"item.delta","turn_id":"turn-21","item_id":"a-21","field":"text","delta":"这是**第一段**。"}"#,
            #"{"type":"item.delta","turn_id":"turn-21","item_id":"a-21","field":"text","delta":"\n\n第二段包含公式 $x^2$。"}"#,
            #"{"type":"item.started","turn_id":"turn-21","item":{"type":"system","item_id":"sys-21","status":"ended","created_at":"2026-11-27T02:00:04Z","kind":"compaction","trigger":"auto","tokens_before":20000,"tokens_after":8000,"summary":"ok"}}"#,
            #"{"type":"item.ended","turn_id":"turn-21","item":{"type":"assistant_message","item_id":"a-21","step_index":2,"status":"ended","outcome":"completed","created_at":"2026-11-27T02:00:03Z","text":"这是**第一段**。\n\n第二段包含公式 $x^2$。"}}"#,
            #"{"type":"turn.ended","turn":{"turn_id":"turn-21","ordinal":21,"kind":"agent","status":"ended","outcome":"completed","started_at":"2026-11-27T02:00:00Z","ended_at":"2026-11-27T02:00:05Z","duration_ms":5000,"steps":[{"index":1,"outcome":"completed","started_at":"2026-11-27T02:00:00Z","ended_at":"2026-11-27T02:00:03Z"},{"index":2,"outcome":"completed","started_at":"2026-11-27T02:00:03Z","ended_at":"2026-11-27T02:00:05Z"}]}}"#,
            #"{"type":"item.removed","turn_id":"turn-21","item_id":"sys-21"}"#,
            #"{"type":"turns.removed","turn_ids":["turn-21"]}"#,
        ]

        var sawTextDeltaFastPath = 0
        for raw in events {
            let event = try decode(ConversationWireEvent.self, from: raw)
            let change = conversation.apply(event)
            let result = conversation.sync(to: &incremental, change: change)
            if case .textDelta = result { sawTextDeltaFastPath += 1 }
            precondition(
                incremental == conversation.transcriptState,
                "Incremental TranscriptState diverged from full projection on event: \(raw)"
            )
        }
        precondition(sawTextDeltaFastPath == 4, "Expected 4 O(1) textDelta fast-path syncs, got \(sawTextDeltaFastPath)")
    }

    // MARK: - 3. ConversationProjectionCache 与全量 ConversationBuilder.build 完全一致

    @MainActor
    static func checkProjectionCacheParity() throws {
        var cache = ConversationProjectionCache()
        var timing: [String: ThinkingTiming] = [:]
        let pageJSON = """
        {"turns":[
          {"turn_id":"turn-1","ordinal":1,"kind":"agent","status":"ended","outcome":"completed","started_at":"2026-11-27T01:00:00Z","ended_at":"2026-11-27T01:00:02Z","steps":[{"index":1,"outcome":"completed","started_at":"2026-11-27T01:00:00Z"}],"items":[
            {"type":"user_message","item_id":"u1","status":"ended","outcome":"completed","created_at":"2026-11-27T01:00:00Z","placement":"opener","origin":{"kind":"user"},"text":"第一轮"},
            {"type":"assistant_message","item_id":"a1","step_index":1,"status":"ended","outcome":"completed","created_at":"2026-11-27T01:00:01Z","text":"回复 1"}
          ]},
          {"turn_id":"turn-2","ordinal":2,"kind":"agent","status":"running","started_at":"2026-11-27T01:01:00Z","steps":[{"index":1,"started_at":"2026-11-27T01:01:00Z"}],"items":[
            {"type":"user_message","item_id":"u2","status":"ended","outcome":"completed","created_at":"2026-11-27T01:01:00Z","placement":"opener","origin":{"kind":"user"},"text":"第二轮"},
            {"type":"reasoning","item_id":"r2","step_index":1,"status":"running","created_at":"2026-11-27T01:01:01Z","text":"思考中"},
            {"type":"assistant_message","item_id":"a2","step_index":1,"status":"running","created_at":"2026-11-27T01:01:02Z","text":"流式"}
          ]}
        ],"has_more":false}
        """
        var conversation = ConversationState(page: try decode(ConversationPage.self, from: pageJSON))
        var transcript = conversation.transcriptState
        ConversationBuilder.updateTiming(&timing, state: transcript)

        let cached1 = cache.build(from: transcript, timing: timing)
        let full1 = ConversationBuilder.build(transcript, timing: timing)
        precondition(cached1 == full1)

        // 验证 liveAnchor 可准确锚定当前流式文本块
        let anchor = ConversationBuilder.liveAnchor(state: transcript, entries: cached1, isWorking: true)
        precondition(anchor?.turnID == "turn-2" && anchor?.frameID == "a2" && anchor?.blockID == "a2" && anchor?.kind == .text)

        // 追加文本、结束轮次，再次校验缓存一致性
        let delta = try decode(ConversationWireEvent.self, from: #"{"type":"item.delta","turn_id":"turn-2","item_id":"a2","field":"text","delta":"内容继续"}"#)
        let c1 = conversation.apply(delta)
        _ = conversation.sync(to: &transcript, change: c1)
        ConversationBuilder.updateTiming(&timing, state: transcript)
        precondition(cache.build(from: transcript, timing: timing) == ConversationBuilder.build(transcript, timing: timing))

        let ended = try decode(ConversationWireEvent.self, from: #"{"type":"turn.ended","turn":{"turn_id":"turn-2","ordinal":2,"kind":"agent","status":"ended","outcome":"completed","started_at":"2026-11-27T01:01:00Z","ended_at":"2026-11-27T01:01:05Z","steps":[{"index":1,"outcome":"completed","started_at":"2026-11-27T01:01:00Z","ended_at":"2026-11-27T01:01:05Z"}]}}"#)
        let c2 = conversation.apply(ended)
        _ = conversation.sync(to: &transcript, change: c2)
        ConversationBuilder.updateTiming(&timing, state: transcript)
        precondition(cache.build(from: transcript, timing: timing) == ConversationBuilder.build(transcript, timing: timing))
    }

    // MARK: - 4. StreamPacer 字形簇安全、平滑缓出、Reduce Motion 与结构合帧

    @MainActor
    static func checkStreamPacerSmoothRevealAndFlush() {
        let store = LiveStreamStore()
        var structuralFlushes = 0
        let pacer = StreamPacer(liveStream: store, onStructuralFlush: { structuralFlushes += 1 })
        pacer.reduceMotionOverride = false
        defer { pacer.stop() }

        let anchor = LiveStreamAnchor(
            turnID: "t1", stepID: "s1", frameID: "f1", blockID: "b1",
            kind: .text, prefix: "前段\n", frameText: "开头"
        )
        pacer.attach(anchor)
        precondition(store.activeBlockID == "b1" && store.text == "前段\n开头")

        // 突发一大段含复合 Emoji 与组合变音符的文本
        let burst = "👨‍👩‍👧‍👦你好世界e\u{0301}测试平滑流式输出效果！"
        precondition(pacer.acceptDelta(turnID: "t1", stepID: "s1", frameID: "f1", delta: burst))
        precondition(pacer.hasPendingWork)

        var timestamp: CFTimeInterval = 1.0
        var steps = 0
        var previousLen = store.text.count
        while pacer.hasPendingWork && steps < 40 {
            timestamp += 1.0 / 60.0
            pacer.tick(timestamp: timestamp)
            steps += 1
            precondition(store.text.count >= previousLen)
            previousLen = store.text.count
        }
        precondition(!pacer.hasPendingWork, "Pacer should drain burst smoothly within < 40 frames")
        precondition(steps > 1, "Pacer should reveal burst across multiple frames rather than popping in 1 frame")
        precondition(store.text == "前段\n开头" + burst)

        // 减弱动态效果：一帧直接全部吐出
        pacer.reduceMotionOverride = true
        precondition(pacer.acceptDelta(turnID: "t1", stepID: "s1", frameID: "f1", delta: "全部立现1234567890"))
        timestamp += 1.0 / 60.0
        pacer.tick(timestamp: timestamp)
        precondition(!pacer.hasPendingWork && store.text.hasSuffix("全部立现1234567890"))

        // 密集结构更新（如工具日志流）合并成单次刷新
        pacer.reduceMotionOverride = false
        for _ in 0..<50 { pacer.scheduleStructuralRebuild() }
        timestamp += 0.05
        pacer.tick(timestamp: timestamp)
        precondition(structuralFlushes == 1, "50 rapid structural updates should coalesce to 1 flush, got \(structuralFlushes)")

        // reset 立即清空
        pacer.reset(clearLiveStream: true)
        precondition(store.activeBlockID == nil && store.text.isEmpty && !pacer.hasPendingWork)
    }

    // MARK: - 5. 高频流式性能基准（2000 个 delta + 30 轮历史）

    static func checkBenchmark() throws {
        let turnsJSON = (1...30).map { i in
            """
            {"turn_id":"turn-\(i)","ordinal":\(i),"kind":"agent","status":"ended","outcome":"completed",\
            "started_at":"2026-11-27T01:00:00Z","ended_at":"2026-11-27T01:00:05Z","duration_ms":5000,\
            "steps":[{"index":1,"outcome":"completed","started_at":"2026-11-27T01:00:00Z","ended_at":"2026-11-27T01:00:05Z"}],\
            "items":[\
              {"type":"user_message","item_id":"u-\(i)","status":"ended","outcome":"completed","created_at":"2026-11-27T01:00:00Z","placement":"opener","origin":{"kind":"user"},"text":"问题 \(i)"},\
              {"type":"assistant_message","item_id":"a-\(i)","step_index":1,"status":"ended","outcome":"completed","created_at":"2026-11-27T01:00:01Z","text":"这是一段中等长度的历史回答，用来验证流式追加的复杂度与历史轮数无关。(\(i))"}\
            ]}
            """
        }.joined(separator: ",")
        var conversation = ConversationState(page: try decode(ConversationPage.self, from: #"{"turns":[\#(turnsJSON)],"has_more":false}"#))
        var transcript = conversation.transcriptState
        _ = conversation.sync(to: &transcript, change: conversation.apply(
            try decode(ConversationWireEvent.self, from: #"{"type":"turn.started","turn":{"turn_id":"turn-31","ordinal":31,"kind":"agent","status":"running","started_at":"2026-11-27T02:00:00Z","steps":[{"index":1,"started_at":"2026-11-27T02:00:00Z"}]}}"#)
        ))
        _ = conversation.sync(to: &transcript, change: conversation.apply(
            try decode(ConversationWireEvent.self, from: #"{"type":"item.started","turn_id":"turn-31","item":{"type":"assistant_message","item_id":"a-31","step_index":1,"status":"running","created_at":"2026-11-27T02:00:00Z","text":"A"}}"#)
        ))

        let clock = ContinuousClock()
        let deltaEvent = ConversationWireEvent.itemDelta(turnID: "turn-31", itemID: "a-31", field: .text, delta: "流式文字chunk ")
        let elapsed = clock.measure {
            for _ in 0..<2_000 {
                let change = conversation.apply(deltaEvent)
                _ = conversation.sync(to: &transcript, change: change)
            }
        }
        precondition(transcript.lastTurn?.steps.last?.frames.last?.text?.count == 1 + 2_000 * 10)
        precondition(elapsed < .milliseconds(150), "2,000 incremental deltas took too long: \(elapsed)")

        var legacyState = TranscriptState()
        _ = legacyState.apply(.frameUpsert(
            turnId: "t_1",
            stepId: "t_1:s1",
            frame: TranscriptFrame(kind: "text", frameId: "f_1", role: "assistant", text: "")
        ))
        var legacyOffset = 0
        let chunk = "流式文字chunk "
        let chunkUTF16 = chunk.utf16.count
        let legacyElapsed = clock.measure {
            for _ in 0..<2_000 {
                let ok = legacyState.apply(.append(
                    target: .frame(turnId: "t_1", stepId: "t_1:s1", frameId: "f_1"),
                    offset: legacyOffset,
                    text: chunk
                ))
                precondition(ok)
                legacyOffset += chunkUTF16
            }
        }
        precondition(legacyState.lastTurn?.steps.last?.frames.last?.text?.count == 2_000 * 10)
        precondition(legacyElapsed < .milliseconds(50), "2,000 legacy UTF-16 appends took too long: \(legacyElapsed)")
        print("BENCH: 2,000 2.6+ deltas=\(elapsed), 2,000 legacy UTF-16 appends=\(legacyElapsed)")
    }
}
