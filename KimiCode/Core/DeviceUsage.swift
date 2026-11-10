import Foundation

struct TokenUsageTimeRange: Codable, Hashable, Sendable {
    var start: Date
    var end: Date

    func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }
}

struct TokenUsageTotals: Codable, Sendable, Hashable {
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
    let cacheKey: String?

    init(client: any KapServicing, cacheKey: String? = nil) {
        self.client = client
        self.cacheKey = cacheKey
    }

    struct SessionUsage: Sendable {
        var totals = TokenUsageTotals()
        var days: [Date: TokenUsageTotals] = [:]
        var models: [String: TokenUsageTotals] = [:]
        var turnCount = 0
        var subagentCount = 0

        var hasUsage: Bool { turnCount > 0 || subagentCount > 0 }
    }

    private struct SessionScan: Sendable {
        let sessionID: String
        let usages: [SessionUsage]
        let cache: DeviceUsageSessionCache
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
        try await tokenUsage(in: [range], progress: progress)[0]
    }

    func tokenUsage(
        in ranges: [TokenUsageTimeRange],
        progress: (@Sendable (DeviceUsageProgress) async -> Void)? = nil
    ) async throws -> [DeviceTokenUsageReport] {
        guard !ranges.isEmpty, ranges.allSatisfy({ $0.start < $0.end }) else {
            throw KapError.api(code: -1, message: "统计时间段无效。")
        }
        guard let earliestStart = ranges.map(\.start).min(), let latestEnd = ranges.map(\.end).max() else {
            throw KapError.api(code: -1, message: "统计时间段无效。")
        }
        let coverage = TokenUsageTimeRange(start: earliestStart, end: latestEnd)
        let sessions = try await allSessions(in: coverage)
        await progress?(DeviceUsageProgress(completedSessions: 0, totalSessions: sessions.count))
        var cache = cacheKey.map { DeviceUsageCacheStore.load(deviceID: $0) } ?? [:]
        var reports = Array(repeating: MutableReport(), count: ranges.count)
        var index = 0
        while index < sessions.count {
            try Task.checkCancellation()
            let end = min(index + 2, sessions.count)
            let cacheSnapshot = cache
            let batch = try await withThrowingTaskGroup(of: SessionScan.self) { group in
                for session in sessions[index ..< end] {
                    group.addTask {
                        try await sessionUsage(
                            session,
                            ranges: ranges,
                            coverage: coverage,
                            cached: cacheSnapshot[session.id]
                        )
                    }
                }
                var values: [SessionScan] = []
                for try await value in group { values.append(value) }
                return values
            }
            for value in batch {
                cache[value.sessionID] = value.cache
                for reportIndex in reports.indices {
                    reports[reportIndex].merge(value.usages[reportIndex])
                }
            }
            if let cacheKey { DeviceUsageCacheStore.save(deviceID: cacheKey, sessions: cache) }
            index = end
            await progress?(DeviceUsageProgress(completedSessions: index, totalSessions: sessions.count))
        }
        return reports.map { makeReport($0, scannedSessionCount: sessions.count) }
    }

    private func allSessions(in coverage: TokenUsageTimeRange) async throws -> [SessionSummary] {
        var result: [SessionSummary] = []
        var identifiers: Set<String> = []
        var cursors: Set<String> = []
        var beforeID: String?
        while true {
            try Task.checkCancellation()
            let page = try await client.sessionPage(pageSize: 100, beforeID: beforeID, includeArchive: true)
            for session in page.items where identifiers.insert(session.id).inserted {
                let createdInRange = session.createdAt?.date.map { $0 < coverage.end } ?? true
                let updatedInRange = session.updatedAt?.date.map { $0 >= coverage.start } ?? true
                if createdInRange && updatedInRange { result.append(session) }
            }
            guard page.hasMore == true, let next = page.items.last?.id, !next.isEmpty else { return result }
            guard next != beforeID, cursors.insert(next).inserted else {
                throw KapError.api(code: -1, message: "会话分页游标重复，无法完成 Token 统计。")
            }
            beforeID = next
        }
    }

    private func sessionUsage(
        _ session: SessionSummary,
        ranges: [TokenUsageTimeRange],
        coverage: TokenUsageTimeRange,
        cached: DeviceUsageSessionCache?
    ) async throws -> SessionScan {
        let sessionModel = session.agentConfig?.model.flatMap { $0.isEmpty ? nil : $0 }
        if let cached,
           let updatedAt = session.updatedAt?.date,
           cached.sessionUpdatedAt == updatedAt,
           cached.coverage.start <= coverage.start {
            let records = cached.records.map { record in
                guard record.kind != .subagent, record.model == nil, let sessionModel else { return record }
                return TokenUsageRecord(
                    id: record.id,
                    kind: record.kind,
                    turnID: record.turnID,
                    date: record.date,
                    model: sessionModel,
                    totals: record.totals
                )
            }
            let entry = DeviceUsageSessionCache(
                sessionUpdatedAt: cached.sessionUpdatedAt,
                coverage: cached.coverage,
                records: records
            )
            return SessionScan(
                sessionID: session.id,
                usages: usages(for: records, ranges: ranges),
                cache: entry
            )
        }
        let records = try await downloadRecords(session, coverage: coverage, fallbackModel: sessionModel)
        let entry = DeviceUsageSessionCache(
            sessionUpdatedAt: session.updatedAt?.date,
            coverage: coverage,
            records: records
        )
        return SessionScan(sessionID: session.id, usages: usages(for: records, ranges: ranges), cache: entry)
    }

    private func downloadRecords(
        _ session: SessionSummary,
        coverage: TokenUsageTimeRange,
        fallbackModel: String?
    ) async throws -> [TokenUsageRecord] {
        var records: [String: TokenUsageRecord] = [:]
        var cursors: Set<String> = []
        var beforeTurn: String?
        while true {
            try Task.checkCancellation()
            let page = try await client.transcript(session.id, pageSize: 30, beforeTurn: beforeTurn)
            let turns = page.items.compactMap { item -> TranscriptTurn? in
                guard case let .turn(turn) = item else { return nil }
                return turn
            }
            let pageModel = Self.singleModel(in: page.meta) ?? fallbackModel
            for turn in turns {
                for record in Self.records(for: turn, model: pageModel) where coverage.contains(record.date) {
                    records[record.id] = record
                }
            }
            for task in page.tasks where task.kind == "subagent" {
                guard let record = Self.record(for: task), coverage.contains(record.date) else { continue }
                records[record.id] = record
            }
            let reachedOlderTurns = !turns.isEmpty && turns.allSatisfy { turn in
                guard let date = Self.date(turn.endedAt ?? turn.startedAt) else { return false }
                return date < coverage.start
            }
            guard page.hasMore, !reachedOlderTurns, let next = turns.first?.turnId, !next.isEmpty else {
                return records.values.sorted { $0.date < $1.date }
            }
            guard next != beforeTurn, cursors.insert(next).inserted else {
                throw KapError.api(code: -1, message: "对话分页游标重复，无法完成 Token 统计。")
            }
            beforeTurn = next
        }
    }

    private func usages(for records: [TokenUsageRecord], ranges: [TokenUsageTimeRange]) -> [SessionUsage] {
        ranges.map { range in
            var result = SessionUsage()
            var turnIDs: Set<String> = []
            var taskIDs: Set<String> = []
            for record in records where range.contains(record.date) {
                result.totals.merge(record.totals)
                result.days[Calendar.current.startOfDay(for: record.date), default: TokenUsageTotals()].merge(record.totals)
                result.models[record.model ?? Self.unknownModel, default: TokenUsageTotals()].merge(record.totals)
                switch record.kind {
                case .mainStep, .mainTurn:
                    if let turnID = record.turnID { turnIDs.insert(turnID) }
                case .subagent:
                    taskIDs.insert(record.id)
                }
            }
            result.turnCount = turnIDs.count
            result.subagentCount = taskIDs.count
            return result
        }
    }

    func accumulate(
        _ turn: TranscriptTurn,
        into result: inout SessionUsage,
        range: TokenUsageTimeRange,
        model: String? = nil
    ) {
        result = usages(for: Self.records(for: turn, model: model), ranges: [range])[0]
    }

    private static func records(for turn: TranscriptTurn, model: String?) -> [TokenUsageRecord] {
        let hasStepUsage = turn.steps.contains { $0.usage != nil }
        if hasStepUsage {
            return turn.steps.compactMap { step in
                guard let usage = step.usage,
                      let date = date(step.endedAt ?? step.startedAt ?? turn.endedAt ?? turn.startedAt)
                else { return nil }
                return TokenUsageRecord(
                    id: "mainStep:\(step.stepId)",
                    kind: .mainStep,
                    turnID: turn.turnId,
                    date: date,
                    model: step.model ?? turn.model ?? model,
                    totals: totals(for: usage)
                )
            }
        }
        guard let usage = turn.usage, let date = date(turn.endedAt ?? turn.startedAt) else { return [] }
        return [TokenUsageRecord(
            id: "mainTurn:\(turn.turnId)",
            kind: .mainTurn,
            turnID: turn.turnId,
            date: date,
            model: turn.model ?? model,
            totals: totals(for: usage)
        )]
    }

    private static func record(for task: TranscriptTask) -> TokenUsageRecord? {
        guard let usage = task.usage, let date = date(task.endedAt ?? task.startedAt) else { return nil }
        return TokenUsageRecord(
            id: "subagent:\(task.taskId)",
            kind: .subagent,
            turnID: nil,
            date: date,
            model: task.model,
            totals: totals(for: usage)
        )
    }

    private static func totals(for usage: TranscriptTokenUsage) -> TokenUsageTotals {
        var result = TokenUsageTotals()
        result.add(usage)
        return result
    }

    private static func totals(for usage: TranscriptTurnUsage) -> TokenUsageTotals {
        var result = TokenUsageTotals()
        result.add(usage)
        return result
    }

    private func makeReport(_ report: MutableReport, scannedSessionCount: Int) -> DeviceTokenUsageReport {
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
            scannedSessionCount: scannedSessionCount,
            sessionCount: report.sessionCount,
            turnCount: report.turnCount,
            subagentCount: report.subagentCount
        )
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
