import Foundation
import OSLog

/// kap-server REST 客户端。
///
/// 所有响应都过统一信封（`{code,msg,data,request_id}`），`code != 0` 转成 `KapError.api`。
/// 鉴权是一个闭包而不是固定字符串：relay 用的 refresh token 会被刷新替换，
/// 每次请求都重新取，避免握着过期的那份。
struct KapClient: Sendable {
    let endpoint: Endpoint
    let tokenProvider: @Sendable () async -> String?

    private static let logger = Logger(subsystem: "com.qinkun.kimicode", category: "rest")

    private var session: URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }

    // MARK: 元信息

    func meta() async throws -> ServerMeta {
        try await get("meta")
    }

    // MARK: 会话

    func sessions(pageSize: Int = 100) async throws -> SessionList {
        try await get("sessions", query: ["page_size": String(pageSize)])
    }

    func workspaces() async throws -> [Workspace] {
        let list: WorkspaceList = try await get("workspaces")
        return list.items
    }

    /// 添加工作区（网页端 `addWorkspace`）：`POST /workspaces {root}`。
    func addWorkspace(root: String) async throws -> Workspace {
        struct Body: Encodable { let root: String }
        return try await post("workspaces", body: Body(root: root))
    }

    func browseFs(_ path: String) async throws -> FsBrowse {
        try await get("fs:browse", query: ["path": path])
    }

    func fsHome() async throws -> FsHome {
        try await get("fs:home")
    }

    /// 会话目录里某一层的文件和文件夹（网页端 `listDirectory`）：`POST /sessions/{id}/fs:list`。
    func listFiles(_ sessionID: String, path: String) async throws -> FsList {
        struct Body: Encodable { let path: String; let limit: Int }
        return try await post("sessions/\(sessionID)/fs:list", body: Body(path: path, limit: 1000))
    }

    func readFile(_ sessionID: String, path: String) async throws -> FsContent {
        try await readFile(sessionID, path: path, offset: 0, length: 1024 * 1024, encoding: "auto")
    }

    /// 把会话目录里的文件整个拉到沙盒临时目录。
    ///
    /// 不走 `GET fs/{path}:download`：kap-server 2.0.1 把文件名原样写进 `content-disposition`，
    /// 名字带中文就 500（`ERR_INVALID_CHAR`）。改用 `fs:read` 按块读 base64：每块 3 MiB
    /// （编码后约 4 MiB，整读 10 MiB 编码后会超隧道单请求上限），边读边写盘。
    /// `fs:read` 本身拒绝超过 10 MiB 的文件（41302），所以这里也只能拿 10 MiB 以内的。
    func downloadFile(_ sessionID: String, path: String) async throws -> URL {
        let chunkLength = 3 * 1024 * 1024
        let destination = try PreviewStorage.makeDestination(for: path)
        do {
            FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            var offset = 0
            while true {
                try Task.checkCancellation()
                let chunk = try await readFile(
                    sessionID, path: path, offset: offset, length: chunkLength, encoding: "base64"
                )
                let data: Data
                if chunk.encoding == "base64" {
                    guard let decoded = Data(base64Encoded: chunk.content) else {
                        throw KapError.http(status: 0, body: "文件内容解码失败")
                    }
                    data = decoded
                } else {
                    data = Data(chunk.content.utf8)
                }
                try handle.write(contentsOf: data)
                offset += data.count
                if data.isEmpty || offset >= chunk.size { break }
            }
            return destination
        } catch {
            PreviewStorage.remove(destination)
            throw error
        }
    }

    private func readFile(
        _ sessionID: String, path: String, offset: Int, length: Int, encoding: String
    ) async throws -> FsContent {
        struct Body: Encodable {
            let path: String
            let offset: Int
            let length: Int
            let encoding: String
        }
        return try await post(
            "sessions/\(sessionID)/fs:read",
            body: Body(path: path, offset: offset, length: length, encoding: encoding)
        )
    }

    func models() async throws -> [ModelInfo] {
        let list: ModelList = try await get("models")
        return list.items
    }

    func configDefaults() async throws -> ServerConfigDefaults {
        try await get("config")
    }

    func updateConfig(_ patch: ServerConfigPatch) async throws -> ServerConfigDefaults {
        try await post("config", body: patch)
    }

    // MARK: 模型供应商（与网页端 `listProviders` / `addProvider` / `updateProvider` … 同形）

    func providers() async throws -> [ProviderItem] {
        let list: ProviderList = try await get("providers")
        return list.items
    }

    /// 单个供应商，带已存的 `api_key`（编辑表单预填）。
    func provider(_ id: String) async throws -> ProviderItem {
        try await get("providers/\(id)")
    }

    /// `/config` 里的模型别名（只解码 `models` 段，别的配置不碰）。
    func configModels() async throws -> [ConfigModelEntry] {
        let config: ServerConfigModels = try await get("config")
        return config.items
    }

    func createProvider(_ body: ProviderWriteBody) async throws {
        let _: JSONValue = try await post("providers", body: body)
    }

    func replaceProvider(_ id: String, body: ProviderWriteBody) async throws {
        let _: JSONValue = try await send(method: "PUT", path: "providers/\(id)", query: [:], body: body)
    }

    /// 成功是 204 无正文；业务错误照常是 200 + 错误信封。
    func deleteProvider(_ id: String) async throws {
        var request = URLRequest(url: endpoint.apiBaseURL.appending(path: "providers/\(id)"))
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = await tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw KapError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        if !data.isEmpty, let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
           envelope.code != KapErrorCode.ok {
            throw KapError.api(code: envelope.code, message: envelope.msg)
        }
    }

    /// 重新拉这个供应商的模型元数据；失败项当错误抛出来。
    func refreshProvider(_ id: String) async throws {
        struct Empty: Encodable {}
        let result: ProviderRefreshResult = try await post("providers/\(id):refresh", body: Empty())
        if let failure = result.failed?.first {
            throw KapError.api(code: -1, message: failure.reason)
        }
    }

    func catalogProviders() async throws -> [CatalogProvider] {
        let list: CatalogProviderList = try await get("catalog/providers")
        return list.items
    }

    func importCatalogProvider(catalogID: String, id: String?, apiKey: String, baseURL: String?) async throws {
        struct Body: Encodable {
            let catalogID: String
            let id: String?
            let apiKey: String
            let baseURL: String?

            enum CodingKeys: String, CodingKey {
                case id
                case catalogID = "catalog_id"
                case apiKey = "api_key"
                case baseURL = "base_url"
            }
        }
        let _: JSONValue = try await post(
            "providers:import_catalog",
            body: Body(catalogID: catalogID, id: id, apiKey: apiKey, baseURL: baseURL)
        )
    }

    /// 订阅用量。是那台电脑上登录的账号的用量（与本 App 同账号）。
    func usage() async throws -> PlanUsage {
        try await get("oauth/usage")
    }

    /// 那台电脑上登录的 Kimi 账号（与本 App 同账号）的昵称和头像。
    func userInfo() async throws -> KimiUser? {
        let response: UserInfoResponse = try await get("oauth/userinfo")
        return response.userInfo
    }

    func session(_ id: String) async throws -> SessionSummary {
        try await get("sessions/\(id)")
    }

    func status(_ sessionID: String) async throws -> SessionRuntimeStatus {
        try await get("sessions/\(sessionID)/status")
    }

    /// 改会话的模型 / 思考强度 / 权限模式。
    @discardableResult
    func updateProfile(_ sessionID: String, agentConfig: AgentConfigPatch) async throws -> SessionSummary {
        struct Body: Encodable {
            let agentConfig: AgentConfigPatch
            enum CodingKeys: String, CodingKey { case agentConfig = "agent_config" }
        }
        return try await post("sessions/\(sessionID)/profile", body: Body(agentConfig: agentConfig))
    }

    /// 重命名（网页端 `updateSession({title})`：`POST /sessions/{id}/profile {title}`）。
    func renameSession(_ sessionID: String, title: String) async throws -> SessionSummary {
        struct Body: Encodable { let title: String }
        return try await post("sessions/\(sessionID)/profile", body: Body(title: title))
    }

    /// 永久删除会话（网页端 `deleteSession`：`POST /sessions/{id}:delete`）。
    func deleteSession(_ sessionID: String) async throws {
        struct Empty: Encodable {}
        let _: JSONValue = try await post("sessions/\(sessionID):delete", body: Empty())
    }

    /// 对话正文（与网页端 `getSessionTranscript` 一致，按轮分页，`page_size` 上限 100）。
    func transcript(_ sessionID: String, pageSize: Int = 30, beforeTurn: String? = nil) async throws -> TranscriptPage {
        var query = ["agent_id": "main", "page_size": String(pageSize)]
        if let beforeTurn { query["before_turn"] = beforeTurn }
        return try await get("sessions/\(sessionID)/transcript", query: query)
    }

    /// 撤销最近 `count` 条用户消息及其后的内容（网页端 `undoSession`）。
    func undo(_ sessionID: String, count: Int) async throws {
        struct Body: Encodable { let count: Int }
        let _: JSONValue = try await post("sessions/\(sessionID):undo", body: Body(count: count))
    }

    /// 在某个工作区里新建会话。与网页端 `createSession` 同形：`{ metadata:{cwd}, workspace_id, agent_config }`。
    func createSession(in workspace: Workspace, agentConfig: AgentConfigPatch) async throws -> SessionSummary {
        struct Body: Encodable {
            let metadata: Metadata
            let workspaceID: String
            let agentConfig: AgentConfigPatch
            struct Metadata: Encodable { let cwd: String }
            enum CodingKeys: String, CodingKey {
                case metadata
                case workspaceID = "workspace_id"
                case agentConfig = "agent_config"
            }
        }
        return try await post(
            "sessions",
            body: Body(metadata: .init(cwd: workspace.root), workspaceID: workspace.id, agentConfig: agentConfig)
        )
    }

    // MARK: 发任务 / 打断

    /// 发任务。App 不做排队：只在空闲时发（忙时 composer 只给「停止」）。
    func sendPrompt(_ body: PromptBody, to sessionID: String) async throws -> PromptAccepted {
        try await post("sessions/\(sessionID)/prompts", body: body)
    }

    /// 上传附件：multipart `file` + `name`，与网页端 `uploadFile` 一致。
    /// 走隧道的 HTTP 单请求上限 10 MiB，调用方先挡掉过大的文件。
    func uploadFile(_ data: Data, name: String, mediaType: String) async throws -> UploadedFile {
        guard data.count <= Attachment.maxUploadBytes else {
            throw KapError.api(code: -1, message: "「\(name)」超过 9 MB，远程控制传不了这么大的附件。")
        }
        let boundary = "kimi-\(UUID().uuidString)"
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\n")
        append("Content-Type: \(mediaType)\r\n\r\n")
        body.append(data)
        append("\r\n--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"name\"\r\n\r\n\(name)\r\n")
        append("--\(boundary)--\r\n")

        var request = URLRequest(url: endpoint.apiBaseURL.appending(path: "files"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = await tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 60
        let (responseData, response) = try await session.upload(for: request, from: body)
        return try decodeEnvelope(responseData, status: (response as? HTTPURLResponse)?.statusCode ?? 0, path: "files")
    }

    /// 读取图片；会话媒体和上传文件需要当前登录凭证。
    func attachmentData(_ source: AttachmentSource, sessionID: String) async throws -> Data {
        let url: URL
        let authenticated: Bool
        switch source {
        case let .file(id):
            url = endpoint.apiBaseURL.appending(path: "files").appendingPathComponent(id)
            authenticated = true
        case let .sessionMedia(id):
            url = endpoint.apiBaseURL.appending(path: "sessions").appendingPathComponent(sessionID)
                .appending(path: "media").appendingPathComponent(id)
            authenticated = true
        case let .url(value):
            if value.scheme == "data" {
                let parts = value.absoluteString.split(separator: ",", maxSplits: 1)
                guard parts.count == 2, parts[0].hasPrefix("data:image/"), parts[0].hasSuffix(";base64"),
                      parts[1].utf8.count <= ((Attachment.maxUploadBytes + 2) / 3) * 4,
                      let data = Data(base64Encoded: String(parts[1])), data.count <= Attachment.maxUploadBytes
                else { throw KapError.api(code: -1, message: "图片格式不可预览。") }
                return data
            }
            guard value.scheme == "https" || value.scheme == "http" else {
                throw KapError.api(code: -1, message: "图片地址不可预览。")
            }
            url = value
            // 外部图片地址不携带 Kimi 登录凭证。
            authenticated = value.scheme == endpoint.baseURL.scheme && value.host == endpoint.baseURL.host
                && value.port == endpoint.baseURL.port && value.path.hasPrefix(endpoint.apiBaseURL.path + "/")
        }
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        if authenticated, let token = await tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (bytes, response) = try await session.bytes(for: request)
        // 提前拒绝已知长度的大图；无长度响应也不能先完整下载再检查。
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw KapError.api(code: -1, message: "图片加载失败，请重试。")
        }
        guard response.expectedContentLength <= Attachment.maxUploadBytes else {
            throw KapError.api(code: -1, message: "图片过大，无法预览。")
        }
        var data = Data()
        data.reserveCapacity(Int(max(0, response.expectedContentLength)))
        for try await byte in bytes {
            guard data.count < Attachment.maxUploadBytes else {
                throw KapError.api(code: -1, message: "图片过大，无法预览。")
            }
            data.append(byte)
        }
        return data
    }

    /// 停止当前 turn（网页端的停止按钮走的就是它）。
    func abort(_ sessionID: String) async throws {
        struct Empty: Encodable {}
        let _: JSONValue = try await post("sessions/\(sessionID):abort", body: Empty())
    }

    // MARK: 权限确认

    func pendingApprovals(_ sessionID: String) async throws -> ApprovalList {
        try await get("sessions/\(sessionID)/approvals", query: ["status": "pending"])
    }

    /// 返回 false 表示这条已被别处（比如电脑上的 TUI）处理过了。
    func resolve(
        approval approvalID: String,
        in sessionID: String,
        with decision: ApprovalDecisionBody
    ) async throws -> Bool {
        do {
            let result: ApprovalResolveResult = try await post(
                "sessions/\(sessionID)/approvals/\(approvalID)",
                body: decision
            )
            return result.resolved
        } catch let KapError.api(code, _) where code == KapErrorCode.approvalAlreadyResolved {
            return false
        }
    }

    // MARK: 提问（AskUserQuestion）

    func pendingQuestions(_ sessionID: String) async throws -> QuestionList {
        try await get("sessions/\(sessionID)/questions", query: ["status": "pending"])
    }

    /// 返回 false 表示已在别处答过。
    func answer(question questionID: String, in sessionID: String, with body: QuestionAnswerBody) async throws -> Bool {
        let result: ApprovalResolveResult = try await post("sessions/\(sessionID)/questions/\(questionID)", body: body)
        return result.resolved
    }

    func dismiss(question questionID: String, in sessionID: String) async throws {
        struct Empty: Encodable {}
        do {
            let _: JSONValue = try await post("sessions/\(sessionID)/questions/\(questionID):dismiss", body: Empty())
        } catch let KapError.api(code, _) where code == 40909 {
            // 已被处理：与网页端 `allowCodes:[40909]` 一致，当成功。
        }
    }

    // MARK: 底层

    func get<Response: Decodable>(
        _ path: String,
        query: [String: String] = [:]
    ) async throws -> Response {
        try await send(method: "GET", path: path, query: query, body: Optional<Never>.none)
    }

    func post<Response: Decodable, Body: Encodable>(
        _ path: String,
        body: Body
    ) async throws -> Response {
        try await send(method: "POST", path: path, query: [:], body: body)
    }

    private func send<Response: Decodable, Body: Encodable>(
        method: String,
        path: String,
        query: [String: String],
        body: Body?
    ) async throws -> Response {
        var components = URLComponents(
            url: endpoint.apiBaseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else {
            throw KapError.http(status: 0, body: "无法构造 URL：\(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = await tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await session.data(for: request)
        return try decodeEnvelope(data, status: (response as? HTTPURLResponse)?.statusCode ?? 0, path: path)
    }

    private func decodeEnvelope<Response: Decodable>(_ data: Data, status: Int, path: String) throws -> Response {
        guard (200 ..< 300).contains(status) else {
            // relay 的错误不是信封格式（`{"error":{"message":…}}`），原样带上去。
            throw KapError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }

        let envelope: Envelope<Response>
        do {
            envelope = try JSONDecoder().decode(Envelope<Response>.self, from: data)
        } catch {
            if let error = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
                throw KapError.api(code: error.code, message: error.msg)
            }
            Self.logger.error("解码 \(path) 失败：\(error)")
            throw KapError.decoding(underlying: error, context: path)
        }

        guard envelope.code == KapErrorCode.ok, let payload = envelope.data else {
            throw KapError.api(code: envelope.code, message: envelope.msg)
        }
        return payload
    }
}

// MARK: - Relay

/// relay 自身的接口（不经隧道）：目前只有设备列表。
struct RelayClient: Sendable {
    let origin: URL
    let tokenProvider: @Sendable () async -> String?

    func devices() async throws -> RemoteDeviceList {
        var request = URLRequest(url: origin.appending(path: "v1/remote/devices"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = await tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw KapError.http(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
        do {
            return try JSONDecoder().decode(RemoteDeviceList.self, from: data)
        } catch {
            throw KapError.decoding(underlying: error, context: "设备列表")
        }
    }
}
