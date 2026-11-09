import Foundation

// swiftc KimiCode/Core/{Models,JSONValue,Endpoint,RuntimeFrames,Transcript}.swift scripts/RuntimeStatusChecks.swift -o /tmp/runtime-status-checks
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

        print("PASS: legacy status, strict agent/usage, running state, interaction frames and response bodies")
    }
}
