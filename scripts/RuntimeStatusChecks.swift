import Foundation

// swiftc KimiCode/Core/{Models,JSONValue,Endpoint,RuntimeFrames,Transcript,Conversation}.swift scripts/RuntimeStatusChecks.swift -o /tmp/runtime-status-checks
@main struct RuntimeStatusChecks {
    static func decode<T: Decodable>(_ type: T.Type = T.self, from json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    static func object(_ body: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(body)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            preconditionFailure("Expected a JSON object")
        }
        return object
    }

    static func main() throws {
        let old = try decode(SessionRuntimeStatus.self, from: #"{"busy":false,"model":"kimi","thinking_level":"high","permission":"auto","context_tokens":100,"max_context_tokens":1000,"context_usage":0.1}"#)
        precondition(old.busy == false && old.model == "kimi" && old.thinkingLevel == "high")
        precondition(old.permission == .auto && old.contextUsage == 0.1)

        let agent = try decode(SessionAgentState.self, from: #"{"type":"agent","session_id":"s1","agent_id":"main","status":"running","thinking":"off","permission_mode":"yolo","plan_mode":false,"swarm_mode":false,"tower_mode":false}"#)
        precondition(agent.status == "running" && agent.model == nil && agent.thinkingLevel == "off")
        precondition(agent.permission == .yolo && !agent.planMode)
        do {
            _ = try decode(SessionAgentState.self, from: #"{"model":"kimi","plan_mode":false,"swarm_mode":false,"tower_mode":false}"#)
            preconditionFailure("Agent status must be required")
        } catch {}

        let usage = try decode(SessionContextUsage.self, from: #"{"context_tokens":250,"max_context_tokens":1000}"#)
        precondition(usage.contextTokens == 250 && usage.ratio == 0.25)
        let empty = try decode(SessionContextUsage.self, from: #"{"context_tokens":0,"max_context_tokens":1000}"#)
        precondition(empty.ratio == 0)
        let unknownLimit = try decode(SessionContextUsage.self, from: #"{"context_tokens":250}"#)
        precondition(unknownLimit.maxContextTokens == nil && unknownLimit.ratio == nil)

        let approvalJSON = #"{"type":"interaction","session_id":"s1","agent_id":"main","event_created_at":"2026-11-09T06:00:00Z","interaction_id":"a1","kind":"approval","status":"pending","tool_call_id":"call1","request":{"tool_name":"Bash","action":"command","tool_input_display":{"command":"pwd"},"expires_at":"2026-11-10T06:00:00Z"}}"#
        let approval = try decode(InteractionFrame.self, from: approvalJSON)
        var pending = PendingInteractions()
        pending.apply(approval)
        precondition(pending.approvals.count == 1 && pending.questions.isEmpty)
        precondition(pending.approvals[0].approvalID == "a1" && pending.approvals[0].toolCallID == "call1")
        precondition(pending.approvals[0].toolName == "Bash" && pending.approvals[0].action == "command")
        let endedApproval = try decode(InteractionFrame.self, from: approvalJSON.replacingOccurrences(of: "\"status\":\"pending\"", with: "\"status\":\"ended\",\"outcome\":\"approved\""))
        pending.apply(endedApproval)
        precondition(pending.approvals.isEmpty)

        let questionJSON = #"{"type":"interaction","session_id":"s1","agent_id":"main","event_created_at":"2026-11-09T06:00:00Z","interaction_id":"q1","kind":"question","status":"pending","tool_call_id":"call2","request":{"questions":[{"id":"q1","question":"Continue?","header":"Next","options":[{"id":"yes","label":"Yes","is_recommended":true},{"id":"no","label":"No"}],"multi_select":false,"allow_other":true}]}}"#
        pending.apply(try decode(InteractionFrame.self, from: questionJSON))
        precondition(pending.questions.count == 1 && pending.questions[0].questionID == "q1")
        precondition(pending.questions[0].questions[0].options[0].recommended)
        let endedQuestion = try decode(InteractionFrame.self, from: questionJSON.replacingOccurrences(of: "\"status\":\"pending\"", with: "\"status\":\"ended\",\"outcome\":\"answered\""))
        pending.apply(endedQuestion)
        precondition(pending.questions.isEmpty)
        pending.apply(try decode(InteractionFrame.self, from: questionJSON))
        pending.reset()
        precondition(pending.approvals.isEmpty && pending.questions.isEmpty)

        let approvalBody = try object(InteractionResponseBody.approval(.approved(forSession: true)))
        precondition(approvalBody["kind"] as? String == "approval" && approvalBody["decision"] as? String == "approved")
        precondition(approvalBody["scope"] as? String == "session")
        let answerBody = try object(InteractionResponseBody.question(QuestionAnswerBody(answers: ["q1": .single("yes")])))
        precondition(answerBody["kind"] as? String == "question" && answerBody["method"] as? String == "click")
        let answers = answerBody["answers"] as? [String: Any]
        let answer = answers?["q1"] as? [String: Any]
        precondition(answer?["kind"] as? String == "single" && answer?["option_id"] as? String == "yes")
        let dismissBody = try object(InteractionResponseBody.dismissQuestion)
        precondition(dismissBody["kind"] as? String == "question" && dismissBody["dismissed"] as? Bool == true)

        let runningPage = #"{"items":[{"kind":"turn","turnId":"t1","ordinal":1,"state":"running","steps":[{"stepId":"s1","turnId":"t1","ordinal":1,"state":"running","frames":[],"retry":{"failedAttempt":1,"nextAttempt":2,"maxAttempts":3,"delayMs":250,"errorName":"Network","errorMessage":"offline","statusCode":503}}]}],"has_more":false}"#
        let running = try TranscriptState(page: decode(TranscriptPage.self, from: runningPage))
        precondition(running.meta.isEmpty && running.isTurnActive)
        let retry = running.turns.last?.steps.last?.retry
        precondition(retry?.nextAttempt == 2 && retry?.maxAttempts == 3)
        let completedPage = runningPage.replacingOccurrences(of: "\"state\":\"running\"", with: "\"state\":\"completed\"")
        let completed = try TranscriptState(page: decode(TranscriptPage.self, from: completedPage))
        precondition(!completed.isTurnActive)

        let device = try decode(RemoteDevice.self, from: #"{"device_id":"mac","alias":"Mac","platform":"darwin","status":"online"}"#)
        let offlineDevice = try decode(RemoteDevice.self, from: #"{"device_id":"old","alias":"Old","platform":"darwin","status":"offline"}"#)
        var reachability = DeviceReachability()
        precondition(reachability.isOnline(device) && !reachability.isOnline(offlineDevice))
        reachability.update(deviceID: "mac", isReachable: false)
        precondition(!reachability.isOnline(device))
        reachability.update(deviceID: "other", isReachable: false)
        precondition(reachability.isOnline(device))
        reachability.update(deviceID: "other", isReachable: true)
        precondition(reachability.isOnline(device) && !reachability.isOnline(offlineDevice))

        let modelPatch = try object(ServerConfigPatch(defaultModel: "kimi-code/k3"))
        precondition(modelPatch.count == 1 && modelPatch["default_model"] as? String == "kimi-code/k3")
        let thinkingPatch = try object(ServerConfigPatch(
            thinking: ServerConfigDefaults.ThinkingConfig(option: "high")
        ))
        precondition(thinkingPatch.count == 1)
        let thinking = thinkingPatch["thinking"] as? [String: Any]
        precondition(thinking?["enabled"] as? Bool == true && thinking?["effort"] as? String == "high")
        let permissionPatch = try object(ServerConfigPatch(defaultPermissionMode: .yolo))
        precondition(permissionPatch.count == 1 && permissionPatch["default_permission_mode"] as? String == "yolo")

        let conversationJSON = #"{"turns":[{"turn_id":"turn-1","ordinal":1,"kind":"agent","status":"running","started_at":"2026-11-13T01:00:00Z","steps":[{"index":1,"outcome":"completed","started_at":"2026-11-13T01:00:00Z","ended_at":"2026-11-13T01:00:01Z","usage":{"input_other":10,"output":4,"input_cache_read":6,"input_cache_creation":2}}],"items":[{"type":"user_message","item_id":"u1","status":"ended","outcome":"completed","created_at":"2026-11-13T01:00:00Z","prompt_ids":["p1"],"placement":"opener","origin":{"kind":"user"},"text":"Hello","attachments":[{"kind":"image","file_id":"f1","name":"photo.jpg","media_type":"image/jpeg","ordinal":1}],"skills":[]},{"type":"reasoning","item_id":"r1","step_index":1,"status":"ended","outcome":"completed","created_at":"2026-11-13T01:00:00Z","text":"Think","started_at":"2026-11-13T01:00:00Z"},{"type":"tool_call","item_id":"call1","step_index":1,"status":"running","created_at":"2026-11-13T01:00:00Z","name":"Bash","stage":"executing","input":{"command":"pwd"},"started_at":"2026-11-13T01:00:00Z"},{"type":"assistant_message","item_id":"a1","step_index":1,"status":"running","created_at":"2026-11-13T01:00:00Z","text":"Hel"}]}],"has_more":true}"#
        let conversationPage = try decode(ConversationPage.self, from: conversationJSON)
        let unified = TranscriptPage(conversation: conversationPage)
        precondition(unified.wireProtocol == .conversation && unified.hasMore && unified.conversation != nil)
        guard case let .turn(unifiedTurn)? = unified.items.first else {
            preconditionFailure("Expected a projected turn")
        }
        precondition(unifiedTurn.prompt == "Hello" && unifiedTurn.triggerPromptId == "p1")
        precondition(unifiedTurn.attachmentIds?.count == 1 && unified.attachments.count == 1)
        precondition(unified.attachments[0].source?["kind"]?.stringValue == "session_media")
        precondition(unifiedTurn.steps[0].usage?.output == 4)
        precondition(unifiedTurn.steps[0].frames.count == 3)
        precondition(unified.prompts[0].promptId == "p1" && unified.prompts[0].userMessageId == "u1")

        var conversation = ConversationState(page: conversationPage)
        let delta = try decode(ConversationWireEvent.self, from: #"{"type":"item.delta","session_id":"s1","agent_id":"main","event_created_at":"2026-11-13T01:00:02Z","turn_id":"turn-1","item_id":"a1","field":"text","delta":"lo"}"#)
        conversation.apply(delta)
        let deltaTurn = conversation.transcriptState.turns[0]
        precondition(deltaTurn.steps[0].frames.last?.text == "Hello")
        precondition(deltaTurn.prompt == "Hello")

        let toolUpdate = try decode(ConversationWireEvent.self, from: #"{"type":"item.updated","session_id":"s1","agent_id":"main","event_created_at":"2026-11-13T01:00:03Z","turn_id":"turn-1","item_id":"call1","set":{"status":"ended","outcome":"completed","output":"done","ended_at":"2026-11-13T01:00:03Z"}}"#)
        conversation.apply(toolUpdate)
        let updatedTool = conversation.transcriptState.turns[0].steps[0].frames.first { $0.frameId == "call1" }
        precondition(updatedTool?.state == "completed" && updatedTool?.output?.stringValue == "done")

        let retryEvent = try decode(ConversationWireEvent.self, from: #"{"type":"turn.updated","session_id":"s1","agent_id":"main","event_created_at":"2026-11-13T01:00:04Z","turn_id":"turn-1","retry":{"attempt":1,"next_attempt":2,"max_attempts":3,"delay_ms":250,"error":{"name":"Network","message":"offline","status_code":503}}}"#)
        conversation.apply(retryEvent)
        precondition(conversation.transcriptState.turns[0].steps.last?.retry?.nextAttempt == 2)
        let retryCleared = try decode(ConversationWireEvent.self, from: #"{"type":"turn.updated","session_id":"s1","agent_id":"main","event_created_at":"2026-11-13T01:00:05Z","turn_id":"turn-1"}"#)
        conversation.apply(retryCleared)
        precondition(conversation.transcriptState.turns[0].steps.last?.retry == nil)

        let ended = try decode(ConversationWireEvent.self, from: #"{"type":"turn.ended","session_id":"s1","agent_id":"main","event_created_at":"2026-11-13T01:00:06Z","turn":{"turn_id":"turn-1","ordinal":1,"kind":"agent","status":"ended","outcome":"completed","started_at":"2026-11-13T01:00:00Z","ended_at":"2026-11-13T01:00:06Z","duration_ms":6000,"steps":[]}}"#)
        conversation.apply(ended)
        let endedState = conversation.transcriptState
        precondition(endedState.turns[0].state == "completed" && !endedState.isTurnActive)
        precondition(endedState.turns[0].steps[0].frames.last?.text == "Hello")
        conversation.apply(try decode(ConversationWireEvent.self, from: #"{"type":"turns.removed","session_id":"s1","agent_id":"main","event_created_at":"2026-11-13T01:00:07Z","turn_ids":["turn-1"]}"#))
        precondition(conversation.transcriptState.turns.isEmpty)

        let notification = try decode(ConversationItem.self, from: #"{"type":"notification","item_id":"n1","status":"ended","outcome":"completed","created_at":"2026-11-13T01:00:08Z","notification_id":"notice1","title":"Background task","body":"Finished","severity":"info","notification_type":"task","source":{"kind":"task","id":"task1"},"output":{"file":"result.txt","preview":"done","bytes":4,"truncated":false}}"#)
        precondition(notification.output?["file"]?.stringValue == "result.txt")
        precondition(notification.output?["bytes"]?.intValue == 4)
        let objectOutputUpdate = try decode(ConversationItemPatch.self, from: #"{"output":{"preview":"updated"}}"#)
        precondition(objectOutputUpdate.output?["preview"]?.stringValue == "updated")

        // 2.7 / KAP 1.0.0 checks
        let meta27 = try decode(ServerMeta.self, from: #"{"kimi_agent_protocol_version":"1.0.0","server_version":"2.7.2","product":"kimi-code-desktop","server_id":"srv1","dangerous_bypass_auth":false,"capabilities":{"websocket":true,"file_upload":true,"fs_query":true,"mcp":true,"tasks":true,"interactions_list":true,"session_wait":true}}"#)
        precondition(meta27.usesConversationProtocol && meta27.capabilities?.interactionsList == true && meta27.capabilities?.terminal == false)
        let meta25 = try decode(ServerMeta.self, from: #"{"server_version":"2.5.2","capabilities":{"websocket":true,"terminal":true}}"#)
        precondition(!meta25.usesConversationProtocol && meta25.capabilities?.terminal == true)

        let session27Turn = try decode(SessionSummary.self, from: #"{"id":"s27","workspace_id":"wm_1","cwd":"/tmp/my-repo","title":"","created_at":"2026-11-20T01:00:00Z","updated_at":"2026-11-20T01:05:00Z","activity":"turn","last_turn_outcome":"interrupted","metadata":{"custom":true}}"#)
        precondition(session27Turn.busy && session27Turn.mainTurnActive == true)
        precondition(session27Turn.pendingInteraction == .none)
        precondition(session27Turn.resolvedCWD == "/tmp/my-repo" && session27Turn.folderName == "my-repo" && session27Turn.displayTitle == "my-repo")
        precondition(session27Turn.lastTurnReason == "interrupted")

        let session27Idle = try decode(SessionSummary.self, from: #"{"id":"s27-idle","workspace_id":"wm_1","cwd":"/tmp/idle","title":"Done","created_at":"2026-11-20T01:00:00Z","updated_at":"2026-11-20T01:05:00Z","activity":"idle"}"#)
        precondition(!session27Idle.busy && session27Idle.mainTurnActive == false && session27Idle.displayTitle == "Done")

        let session27Bg = try decode(SessionSummary.self, from: #"{"id":"s27-bg","workspace_id":"wm_1","cwd":"/tmp/bg","title":"Bg","created_at":"2026-11-20T01:00:00Z","updated_at":"2026-11-20T01:05:00Z","activity":"background","pending_interaction":"approval"}"#)
        precondition(session27Bg.busy && session27Bg.mainTurnActive == false && session27Bg.pendingInteraction == .approval)

        let wrappedProfile = try decode(SessionProfileResponse.self, from: #"{"session":{"id":"s27","workspace_id":"wm_1","cwd":"/tmp/my-repo","title":"Renamed","created_at":"2026-11-20T01:00:00Z","updated_at":"2026-11-20T01:05:00Z","activity":"idle"},"agent":{"status":"idle","compacting":false,"model":"kimi-code/k3","thinking":"high","permission_mode":"auto","plan_mode":false,"swarm_mode":false,"tower_mode":false}}"#)
        precondition(wrappedProfile.session.title == "Renamed" && wrappedProfile.agent?.model == "kimi-code/k3")

        let legacyProfile = try decode(SessionProfileResponse.self, from: #"{"id":"s25","workspace_id":"w1","title":"Legacy","busy":false,"pending_interaction":"none","metadata":{"cwd":"/tmp/legacy"}}"#)
        precondition(legacyProfile.session.title == "Legacy" && legacyProfile.session.folderName == "legacy" && legacyProfile.agent == nil)

        let endedAgent = try decode(SessionAgentState.self, from: #"{"type":"agent","session_id":"s1","agent_id":"main","status":"ended","compacting":false,"plan_mode":false,"swarm_mode":false,"tower_mode":false}"#)
        precondition(!endedAgent.isWorking && !endedAgent.isCompacting)
        let compactingAgent27 = try decode(SessionAgentState.self, from: #"{"type":"agent","session_id":"s1","agent_id":"main","status":"idle","compacting":true,"plan_mode":false,"swarm_mode":false,"tower_mode":false}"#)
        precondition(compactingAgent27.isWorking && compactingAgent27.isCompacting)
        let compactingAgent25 = try decode(SessionAgentState.self, from: #"{"type":"agent","session_id":"s1","agent_id":"main","status":"compacting","plan_mode":false,"swarm_mode":false,"tower_mode":false}"#)
        precondition(compactingAgent25.isWorking && compactingAgent25.isCompacting)

        let pendingList = try decode(PendingInteractionList.self, from: #"{"items":[{"interaction_id":"a27","session_id":"s27","agent_id":"main","created_at":"2026-11-20T01:00:00Z","tool_call_id":"call1","kind":"approval","request":{"tool_name":"Bash","action":"command","tool_input_display":{"command":"ls"},"expires_at":"2026-11-21T01:00:00Z"}},{"interaction_id":"q27","session_id":"s27","agent_id":"main","created_at":"2026-11-20T01:00:00Z","kind":"question","request":{"questions":[{"id":"q0","question":"Proceed?","options":[{"id":"y","label":"Yes"},{"id":"n","label":"No"}]}]}}]}"#)
        precondition(pendingList.approvals.count == 1 && pendingList.approvals[0].approvalID == "a27")
        precondition(pendingList.questions.count == 1 && pendingList.questions[0].questionID == "q27")
        precondition(ProviderWireType(rawValue: "bedrock") == .bedrock)

        let endpoint = Endpoint.remote(deviceID: "dev-123", name: "Mac")
        precondition(endpoint.webURL()?.absoluteString == "https://code-rc.kimi.com/devices/dev-123/?rc=1&from=kimi_code_cli")
        precondition(endpoint.webURL(sessionID: "sess-9")?.absoluteString == "https://code-rc.kimi.com/devices/dev-123/sessions/sess-9?rc=1&from=kimi_code_cli")
        precondition(KapError.http(status: 404, body: "").isLikelyProtocolMismatch)
        precondition(KapError.api(code: KapErrorCode.validationFailed, message: "bad").isLikelyProtocolMismatch)
        precondition(!KapError.http(status: 502, body: "").isLikelyProtocolMismatch)
        precondition(!KapError.http(status: 401, body: "").isLikelyProtocolMismatch)

        print("PASS: legacy status, 2.6 pages/streaming/attachments/object outputs, 2.7/KAP 1.0.0, web fallback, interactions and config patches")
    }
}
