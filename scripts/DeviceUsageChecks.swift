import Foundation

@main
struct DeviceUsageChecks {
    static func main() async throws {
        let loader = DeviceUsageLoader(client: DemoClient(deviceID: "demo-macbook-pro"))
        let now = Date()
        let range = TokenUsageTimeRange(start: now.addingTimeInterval(-200), end: now.addingTimeInterval(10))

        let oldTurn: TranscriptTurn = try decode("""
            {"kind":"turn","turnId":"t_1","ordinal":1,"state":"completed",\
            "startedAt":"\(iso(now.addingTimeInterval(-310)))","endedAt":"\(iso(now.addingTimeInterval(-90)))",\
            "steps":[\
            {"stepId":"t_1.s1","turnId":"t_1","ordinal":1,"state":"completed","frames":[],\
            "startedAt":"\(iso(now.addingTimeInterval(-110)))","endedAt":"\(iso(now.addingTimeInterval(-100)))",\
            "usage":{"inputOther":100,"output":20,"inputCacheRead":40,"inputCacheCreation":5}},\
            {"stepId":"t_1.s2","turnId":"t_1","ordinal":2,"state":"completed","frames":[],\
            "startedAt":"\(iso(now.addingTimeInterval(-310)))","endedAt":"\(iso(now.addingTimeInterval(-300)))",\
            "usage":{"inputOther":900,"output":90,"inputCacheRead":90,"inputCacheCreation":9}}]}
            """)
        var oldResult = DeviceUsageLoader.SessionUsage()
        loader.accumulate(oldTurn, into: &oldResult, range: range)
        precondition(oldResult.totals.input == 100)
        precondition(oldResult.totals.output == 20)
        precondition(oldResult.totals.cacheRead == 40)
        precondition(oldResult.totals.cacheCreation == 5)
        precondition(oldResult.totals.total == 165)
        precondition(oldResult.turnCount == 1)

        let newTurn: TranscriptTurn = try decode("""
            {"kind":"turn","turnId":"t_2","ordinal":2,"state":"completed",\
            "startedAt":"\(iso(now.addingTimeInterval(-110)))","endedAt":"\(iso(now.addingTimeInterval(-100)))",\
            "usage":{"inputTokens":110,"outputTokens":25,"cachedTokens":40},"steps":[]}
            """)
        var newResult = DeviceUsageLoader.SessionUsage()
        loader.accumulate(newTurn, into: &newResult, range: range)
        precondition(newResult.totals.input == 110)
        precondition(newResult.totals.output == 25)
        precondition(newResult.totals.cacheRead == 40)
        precondition(newResult.totals.cacheCreation == 0)
        precondition(newResult.totals.total == 175)
        precondition(newResult.turnCount == 1)

        let optionalCacheTurn: TranscriptTurn = try decode("""
            {"kind":"turn","turnId":"t_3","ordinal":3,"state":"completed",\
            "startedAt":"\(iso(now.addingTimeInterval(-110)))","endedAt":"\(iso(now.addingTimeInterval(-100)))",\
            "steps":[{"stepId":"t_3.s1","turnId":"t_3","ordinal":1,"state":"completed","frames":[],\
            "startedAt":"\(iso(now.addingTimeInterval(-110)))","endedAt":"\(iso(now.addingTimeInterval(-100)))",\
            "usage":{"inputOther":8,"output":2,"inputCacheCreation":1}}]}
            """)
        var optionalCacheResult = DeviceUsageLoader.SessionUsage()
        loader.accumulate(optionalCacheTurn, into: &optionalCacheResult, range: range)
        precondition(optionalCacheResult.totals.total == 11)
        precondition(optionalCacheResult.totals.cacheRead == 0)

        let client = DemoClient(deviceID: "demo-macbook-pro")
        let firstPage = try await client.sessionPage(pageSize: 2, beforeID: nil, includeArchive: true)
        precondition(firstPage.items.count == 2 && firstPage.hasMore == true)
        let secondPage = try await client.sessionPage(
            pageSize: 2, beforeID: firstPage.items.last?.id, includeArchive: true
        )
        precondition(secondPage.items.count == 1 && secondPage.hasMore == false)

        let demoLoader = DeviceUsageLoader(client: client)
        let report = try await demoLoader.tokenUsage(in: TokenUsageTimeRange(
            start: now.addingTimeInterval(-10_000), end: now.addingTimeInterval(60)
        ))
        precondition(report.scannedSessionCount == 3)
        precondition(report.sessionCount == 3)
        precondition(report.turnCount == 3)
        precondition(report.totals.input == 3_600)
        precondition(report.totals.output == 900)
        precondition(report.totals.cacheRead == 1_800)
        precondition(report.totals.cacheCreation == 300)
        precondition(report.totals.total == 6_600)

        let empty = try await demoLoader.tokenUsage(in: TokenUsageTimeRange(
            start: now.addingTimeInterval(-60), end: now.addingTimeInterval(-50)
        ))
        precondition(empty.totals.total == 0 && empty.sessionCount == 0)
        let success: JSONValue = try KapClient.decodeEnvelope(
            Data(#"{"code":0,"msg":"success","data":{"ok":true}}"#.utf8), status: 200, path: "check"
        )
        precondition(success["ok"]?.boolValue == true)
        do {
            let _: JSONValue = try KapClient.decodeEnvelope(
                Data(#"{"code":0,"msg":"success","data":null}"#.utf8), status: 200, path: "check"
            )
            preconditionFailure("Missing data must not become a code-0 API error")
        } catch KapError.decoding(_, _) {
        } catch KapError.api(let code, _) {
            preconditionFailure("Unexpected API code \(code)")
        }
        do {
            let _: UploadedFile = try KapClient.decodeEnvelope(
                Data(#"{"code":0,"msg":"success","data":{"id":1}}"#.utf8), status: 200, path: "check"
            )
            preconditionFailure("Malformed success data must fail decoding")
        } catch KapError.decoding(_, _) {
        } catch KapError.api(let code, _) {
            preconditionFailure("Unexpected API code \(code)")
        }
        do {
            let _: UploadedFile = try KapClient.decodeEnvelope(
                Data(#"{"code":50000,"msg":"failed","data":null}"#.utf8), status: 200, path: "check"
            )
            preconditionFailure("Expected a business error")
        } catch KapError.api(let code, _) {
            precondition(code == 50000)
        }

        print("PASS: usage, pagination, demo aggregation and envelope code-0 handling")
    }

    private static func iso(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    private static func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}
