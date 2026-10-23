import Foundation

/// kap-server 把所有 JSON 响应包在统一信封里：`{ code, msg, data, request_id }`。
/// `code == 0` 为成功；其余是业务错误码（见 `KapErrorCode`）。
struct Envelope<Payload: Decodable>: Decodable {
    let code: Int
    let msg: String
    let data: Payload?
    let requestID: String?

    enum CodingKeys: String, CodingKey {
        case code, msg, data
        case requestID = "request_id"
    }
}

/// 错误信封里 `data` 是 null，用它解码失败响应。
struct ErrorEnvelope: Decodable {
    let code: Int
    let msg: String
    let requestID: String?
    let details: [Detail]?

    struct Detail: Decodable {
        let path: String
        let message: String
    }

    enum CodingKeys: String, CodingKey {
        case code, msg, details
        case requestID = "request_id"
    }
}

/// 用得上的业务错误码，来自 `packages/kap-server/src/protocol/error-codes.ts`。
enum KapErrorCode {
    static let ok = 0
    static let validationFailed = 40001
    static let unauthorized = 40101
    /// 电脑上这个模型的 provider 没配凭证（第三方没填 API Key，或 Kimi 没登录）。
    static let modelCredentialMissing = 40111
    /// 电脑上这个模型的凭证被上游拒了（Key 无效 / 过期）。
    static let modelCredentialRejected = 40112
    /// 模型解析不到已配置的 provider（电脑上删了这个模型）。
    static let modelNotResolved = 40113
    static let notFound = 40401
    static let fileNotFound = 40409
    static let fileTooLarge = 41302
    static let approvalNotFound = 40404
    static let approvalAlreadyResolved = 40902
    static let remoteControlAlreadyRunning = 40903
    static let internalError = 50000
}

enum KapError: LocalizedError {
    /// HTTP 层失败（含 relay 的 401）。
    case http(status: Int, body: String)
    /// 信封里的业务错误码。
    case api(code: Int, message: String)
    case decoding(underlying: any Error, context: String)
    case notConnected
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .http(status, body):
            if status == 401 { return "鉴权失败（401）。登录可能已过期，请重新登录。" }
            if status == 404 { return "找不到该设备或接口（404）。设备可能已下线。" }
            if status == 502 { return "请求转发失败（502）。请重试；若持续出现，请检查电脑上的 `kimi rc` 连接。" }
            return "HTTP \(status)\(body.isEmpty ? "" : "：\(body.prefix(200))")"
        case let .api(code, message):
            // 这三个都是电脑那边的模型配置问题，不是手机登录过期：别引导重新登录。
            switch code {
            case KapErrorCode.modelCredentialMissing:
                return "电脑上这个模型还没配置凭证（API Key 或登录）。请在电脑上配好，或换一个模型。\n\(message)"
            case KapErrorCode.modelCredentialRejected:
                return "电脑上这个模型的凭证无效或已过期。请在电脑上更新，或换一个模型。\n\(message)"
            case KapErrorCode.modelNotResolved:
                return "电脑上找不到这个模型的配置，可能已被删除。请换一个模型。\n\(message)"
            default:
                return "\(message)（code \(code)）"
            }
        case let .decoding(underlying, context):
            return "解析 \(context) 失败：\(underlying)"
        case .notConnected:
            return "尚未连接到任何设备。"
        case .cancelled:
            return "已取消。"
        }
    }

    /// 需要重新走登录流程的错误。
    var requiresReauth: Bool {
        switch self {
        case let .http(status, _): status == 401
        case let .api(code, _): code == KapErrorCode.unauthorized
        default: false
        }
    }
}
