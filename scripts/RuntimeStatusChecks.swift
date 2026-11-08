import Foundation

// swiftc KimiCode/Core/{Models,JSONValue,Endpoint}.swift scripts/RuntimeStatusChecks.swift -o /tmp/runtime-status-checks
@main struct RuntimeStatusChecks {
    static func decode(_ json: String) throws -> SessionRuntimeStatus {
        try JSONDecoder().decode(SessionRuntimeStatus.self, from: Data(json.utf8))
    }

    static func main() throws {
        let old = try decode(#"{"busy":false,"model":"kimi","thinking_level":"high","permission":"auto","context_tokens":100,"max_context_tokens":1000,"context_usage":0.1}"#)
        precondition(old.model == "kimi" && old.thinkingLevel == "high")
        precondition(old.permission == .auto && old.contextUsage == 0.1)

        // Kimi Code 2.5.2: state fields are at the top level, not in payload.
        let agent = try decode(#"{"type":"agent","session_id":"s1","agent_id":"main","status":"idle","model":"kimi","thinking":"off","permission_mode":"yolo","plan_mode":false,"swarm_mode":false,"tower_mode":false}"#)
        precondition(agent.model == "kimi" && agent.thinkingLevel == "off")
        precondition(agent.permission == .yolo && agent.contextTokens == nil)

        let usage = try decode(#"{"type":"usage","session_id":"s1","agent_id":"main","context_tokens":250,"max_context_tokens":1000}"#)
        precondition(usage.contextUsage == 0.25 && usage.model == nil && usage.permission == nil)
        let empty = try decode(#"{"context_tokens":0,"max_context_tokens":1000}"#)
        precondition(empty.contextUsage == 0)
        let unknownLimit = try decode(#"{"context_tokens":250}"#)
        precondition(unknownLimit.contextUsage == nil)
        let invalidLimit = try decode(#"{"context_tokens":250,"max_context_tokens":0}"#)
        precondition(invalidLimit.contextUsage == nil)
        print("PASS: legacy status, flat agent/usage frames, off thinking, zero usage and missing/zero limits")
    }
}
