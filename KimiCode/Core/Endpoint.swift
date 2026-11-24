import Foundation

/// 一台经 relay 可达的电脑：`https://code-rc.kimi.com/devices/<id>`。
/// Bearer 统一用 Kimi refresh token（见 CLAUDE.md §5）。
struct Endpoint: Codable, Hashable, Sendable, Identifiable {
    /// 不带尾斜杠的基址，已包含 `/devices/<id>` 前缀。
    let baseURL: URL
    let deviceID: String
    /// 界面上显示的名字（设备别名，通常是主机名）。
    var displayName: String

    var id: String { baseURL.absoluteString }

    /// REST 基址：`{base}/api/v1`
    var apiBaseURL: URL { baseURL.appending(path: "api/v1") }

    /// WS 地址：`{base}/api/v1/ws?client_id=…`（http→ws，https→wss）
    func webSocketURL(clientID: String) -> URL? {
        var components = URLComponents(url: apiBaseURL.appending(path: "ws"), resolvingAgainstBaseURL: false)
        components?.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components?.queryItems = [URLQueryItem(name: "client_id", value: clientID)]
        return components?.url
    }

    /// 官方远程控制网页版地址（与 `kimi rc` 终端输出的链接格式一致）。
    func webURL(sessionID: String? = nil) -> URL? {
        let target: URL
        if let sessionID, !sessionID.isEmpty {
            target = baseURL.appending(path: "sessions/\(sessionID)")
        } else {
            target = baseURL
        }
        var components = URLComponents(url: target, resolvingAgainstBaseURL: false)
        if sessionID == nil || sessionID?.isEmpty == true,
           let path = components?.path, !path.hasSuffix("/") {
            components?.path = path + "/"
        }
        components?.queryItems = [
            URLQueryItem(name: "rc", value: "1"),
            URLQueryItem(name: "from", value: "kimi_code_cli"),
        ]
        return components?.url
    }

    static func remote(deviceID: String, relayOrigin: URL = KimiConfig.relayOrigin, name: String) -> Endpoint {
        Endpoint(
            baseURL: relayOrigin.appending(path: "devices/\(deviceID)"),
            deviceID: deviceID,
            displayName: name
        )
    }
}

enum KimiConfig {
    /// 与 `REMOTE_CONTROL_RELAY_ORIGIN` 一致。
    static let relayOrigin = URL(string: "https://code-rc.kimi.com")!
    /// 与 `DEFAULT_KIMI_CODE_OAUTH_HOST` 一致。
    static let oauthHost = URL(string: "https://auth.kimi.com")!
    /// 与 `KIMI_CODE_FLOW_CONFIG.clientId` 一致（公开的 device-code 客户端）。
    static let oauthClientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    /// 「Kimi 订阅」这组模型的 provider id（网页端常量 `gT`）。模型菜单里这组排最前。
    static let kimiSubscriptionProvider = "managed:kimi-code"
    /// 当前版本已验证适配的 Kimi Code 截止日期（每次发版更新此处，用于更新通知弹窗）。
    static let supportedKimiCodeDate = "2026年11月24日"
}
