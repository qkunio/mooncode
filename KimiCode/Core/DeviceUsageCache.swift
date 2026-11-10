import Foundation

struct TokenUsageRecord: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case mainStep
        case mainTurn
        case subagent
    }

    let id: String
    let kind: Kind
    let turnID: String?
    let date: Date
    let model: String?
    let totals: TokenUsageTotals
}

struct DeviceUsageSessionCache: Codable, Sendable {
    let sessionUpdatedAt: Date?
    let coverage: TokenUsageTimeRange
    let records: [TokenUsageRecord]
}

private struct DeviceUsageCacheFile: Codable {
    var version = 1
    var sessions: [String: DeviceUsageSessionCache]
}

enum DeviceUsageCacheStore {
    static func load(deviceID: String) -> [String: DeviceUsageSessionCache] {
        guard let data = try? Data(contentsOf: fileURL(deviceID: deviceID)),
              let cache = try? JSONDecoder().decode(DeviceUsageCacheFile.self, from: data),
              cache.version == 1
        else { return [:] }
        return cache.sessions
    }

    static func save(deviceID: String, sessions: [String: DeviceUsageSessionCache]) {
        do {
            let url = fileURL(deviceID: deviceID)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(DeviceUsageCacheFile(sessions: sessions))
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
    }

    private static func fileURL(deviceID: String) -> URL {
        let safeID = String(deviceID.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "-"
        })
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appending(path: "MoonCode/UsageCache/\(safeID).json")
    }
}
