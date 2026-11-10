import Foundation

struct TokenUsageTimeRange: Hashable, Sendable {
    var start: Date
    var end: Date

    func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }
}

struct TokenUsageTotals: Sendable, Hashable {
    private(set) var input = 0
    private(set) var output = 0
    private(set) var cacheRead = 0
    private(set) var cacheCreation = 0

    var total: Int { input + output + cacheRead + cacheCreation }
    var cacheHitRatio: Double? {
        let inputTotal = input + cacheRead + cacheCreation
        guard inputTotal > 0 else { return nil }
        return Double(cacheRead) / Double(inputTotal)
    }

    mutating func add(_ usage: TranscriptTokenUsage) {
        input += Int(usage.inputOther.rounded())
        output += Int(usage.output.rounded())
        cacheRead += Int((usage.inputCacheRead ?? 0).rounded())
        cacheCreation += Int(usage.inputCacheCreation.rounded())
    }

    mutating func add(_ usage: TranscriptTurnUsage) {
        input += Int((usage.inputTokens ?? 0).rounded())
        output += Int((usage.outputTokens ?? 0).rounded())
        cacheRead += Int((usage.cachedTokens ?? 0).rounded())
    }

    mutating func merge(_ other: Self) {
        input += other.input
        output += other.output
        cacheRead += other.cacheRead
        cacheCreation += other.cacheCreation
    }
}

struct DailyTokenUsage: Identifiable, Sendable {
    let date: Date
    let totals: TokenUsageTotals

    var id: Date { date }
}

struct ModelTokenUsage: Identifiable, Sendable {
    let model: String
    let totals: TokenUsageTotals

    var id: String { model }
}

struct DeviceTokenUsageReport: Sendable {
    let totals: TokenUsageTotals
    let days: [DailyTokenUsage]
    let models: [ModelTokenUsage]
    let scannedSessionCount: Int
    let sessionCount: Int
    let turnCount: Int
    let subagentCount: Int
}

struct DeviceUsageProgress: Sendable {
    let completedSessions: Int
    let totalSessions: Int

    var fraction: Double {
        totalSessions > 0 ? Double(completedSessions) / Double(totalSessions) : 1
    }
}

struct DeviceUsageLoader: Sendable {
    static let unknownModel = "unknown"

    let client: any KapServicing

    struct SessionUsage: Sendable {
        var totals = TokenUsageTotals()
        var days: [Date: TokenUsageTotals] = [:]
        var models: [String: TokenUsageTotals] = [:]
        var turnCount = 0
        var subagentCount = 0

        var hasUsage: Bool { turnCount > 0 || subagentCount > 0 }
    }

    private struct MutableReport: Sendable {
        var totals = TokenUsageTotals()
        var days: [Date: TokenUsageTotals] = [:]
        var models: [String: TokenUsageTotals] = [:]
        var sessionCount = 0
        var turnCount = 0
        var subagentCount = 0

        mutating func merge(_ session: SessionUsage) {
            totals.merge(session.totals)
            turnCount += session.turnCount
            subagentCount += session.subagentCount
            if session.hasUsage { sessionCount += 1 }
            for (date, value) in session.days {
                days[date, default: TokenUsageTotals()].merge(value)
            }
            for (model, value) in session.models {
                models[model, default: TokenUsageTotals()].merge(value)
            }
        }
    }

    func tokenUsage(
        in range: TokenUsageTimeRange,
        progress: (@Sendable (DeviceUsageProgress) async -> Void)? = nil
    ) async throws -> DeviceTokenUsageReport {
        guard range.start < range.end else {
            throw KapError.api(code: -1, message: "开始时间需要早于结束时间。")
        }
        let sessions = try await allSessions()
        await progress?(DeviceUsageProgress(completedSessions: 0, totalSessions: sessions.count))
        var report = MutableReport()
        var index = 0
        while index < sessions.count {
            try Task.checkCancellation()
            let end = min(index + 4, sessions.count)
            let batch = try await withThrowingTaskGroup(of: SessionUsage.self) { group in
                for session in sessions[index ..< end] {
                    group.addTask { try await sessionUsage(session.id, in: range) }
                }
                var values: [SessionUsage] = []
                for try await value in group { values.append(value) }
                return values
            }
            for value in batch { report.merge(value) }
            index = end
            await progress?(DeviceUsageProgress(completedSessions: index, totalSessions: sessions.count))
        }
        let models = report.models.map { ModelTokenUsage(model: $0.key, totals: $0.value) }.sorted {
            if $0.totals.total != $1.totals.total { return $0.totals.total > $1.totals.total }
            if ($0.model == Self.unknownModel) != ($1.model == Self.unknownModel) {
                return $0.model != Self.unknownModel
            }
            return $0.model < $1.model
        }
        return DeviceTokenUsageReport(
            totals: report.totals,
            days: report.days.map { DailyTokenUsage(date: $0.key, totals: $0.value) }.sorted { $0.date > $1.date },
            models: models,
            scannedSessionCount: sessions.count,
            sessionCount: report.sessionCount,
            turnCount: report.turnCount,
            subagentCount: report.subagentCount
        )
    }

    private func allSessions() async throws -> [SessionSummary] {
        var result: [SessionSummary] = []
        var identifiers: Set<String> = []
        var cursors: Set<String> = []
        var beforeID: String?
        while true {
            try Task.checkCancellation()
            let page = try await client.sessionPage(pageSize: 100, beforeID: beforeID, includeArchive: true)
            for session in page.items where identifiers.insert(session.id).inserted {
                result.append(session)
            }
            guard page.hasMore == true, let next = page.items.last?.id, !next.isEmpty else { return result }
            guard next != beforeID, cursors.insert(next).inserted else {
                throw KapError.api(code: -1, message: "会话分页游标重复，无法完成 Token 统计。")
            }
            beforeID = next
        }
    }

    private func sessionUsage(_ sessionID: String, in range: TokenUsageTimeRange) async throws -> SessionUsage {
        var result = SessionUsage()
        var turnIDs: Set<String> = []
        var taskIDs: Set<String> = []
        var cursors: Set<String> = []
        var beforeTurn: String?
        while true {
            try Task.checkCancellation()
            let page = try await client.transcript(sessionID, pageSize: 100, beforeTurn: beforeTurn)
            let turns = page.items.compactMap { item -> TranscriptTurn? in
                guard case let .turn(turn) = item else { return nil }
                return turn
            }
            let pageModel = Self.singleModel(in: page.meta)
            for turn in turns where turnIDs.insert(turn.turnId).inserted {
                accumulate(turn, into: &result, range: range, model: pageModel)
            }
            for task in page.tasks where task.kind == "subagent" && taskIDs.insert(task.taskId).inserted {
                guard let usage = task.usage,
                      let date = Self.date(task.endedAt ?? task.startedAt), range.contains(date)
                else { continue }
                add(usage, at: date, model: task.model, to: &result)
                result.subagentCount += 1
            }
            let reachedOlderTurns = !turns.isEmpty && turns.allSatisfy { turn in
                guard let date = Self.date(turn.endedAt ?? turn.startedAt) else { return false }
                return date < range.start
            }
            guard page.hasMore, !reachedOlderTurns, let next = turns.first?.turnId, !next.isEmpty else {
                return result
            }
            guard next != beforeTurn, cursors.insert(next).inserted else {
                throw KapError.api(code: -1, message: "对话分页游标重复，无法完成 Token 统计。")
            }
            beforeTurn = next
        }
    }

    func accumulate(
        _ turn: TranscriptTurn,
        into result: inout SessionUsage,
        range: TokenUsageTimeRange,
        model: String? = nil
    ) {
        let hasStepUsage = turn.steps.contains { $0.usage != nil }
        var included = false
        if hasStepUsage {
            for step in turn.steps {
                guard let usage = step.usage,
                      let date = Self.date(step.endedAt ?? step.startedAt ?? turn.endedAt ?? turn.startedAt),
                      range.contains(date)
                else { continue }
                add(usage, at: date, model: step.model ?? turn.model ?? model, to: &result)
                included = true
            }
        } else if let usage = turn.usage,
                  let date = Self.date(turn.endedAt ?? turn.startedAt), range.contains(date) {
            add(usage, at: date, model: turn.model ?? model, to: &result)
            included = true
        }
        if included { result.turnCount += 1 }
    }

    private func add(_ usage: TranscriptTokenUsage, at date: Date, model: String?, to result: inout SessionUsage) {
        result.totals.add(usage)
        result.days[Calendar.current.startOfDay(for: date), default: TokenUsageTotals()].add(usage)
        result.models[model ?? Self.unknownModel, default: TokenUsageTotals()].add(usage)
    }

    private func add(_ usage: TranscriptTurnUsage, at date: Date, model: String?, to result: inout SessionUsage) {
        result.totals.add(usage)
        result.days[Calendar.current.startOfDay(for: date), default: TokenUsageTotals()].add(usage)
        result.models[model ?? Self.unknownModel, default: TokenUsageTotals()].add(usage)
    }

    private static func singleModel(in meta: JSONValue?) -> String? {
        guard let models = meta?["agent"]?["usage"]?["byModel"]?.objectValue, models.count == 1 else { return nil }
        return models.first?.key
    }

    private static func date(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
        return try? Date.ISO8601FormatStyle().parse(text)
    }
}
