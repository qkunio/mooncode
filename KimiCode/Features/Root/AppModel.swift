import Foundation
import Observation

/// App 级状态：账号、当前设备、侧栏数据（文件夹/会话/用量）、主页正在看的对话。
@MainActor
@Observable
final class AppModel {
    let auth = AuthStore()

    // 设备
    private(set) var devices: [RemoteDevice] = []
    private(set) var endpoint: Endpoint?
    private(set) var hasLoadedDevices = false
    var isLoadingDevices = false

    // 侧栏
    private(set) var workspaces: [Workspace] = []
    private(set) var sessions: [SessionSummary] = []
    @ObservationIgnored private var sessionPool = SessionListPool()
    private(set) var user: KimiUser?
    /// 订阅剩余用量，打开会话右上角 ⋯ 时刷新。
    private(set) var usage: PlanUsage?

    // composer 用
    private(set) var models: [ModelInfo] = []
    private(set) var defaultModelID: String?
    private(set) var defaultThinking: ServerConfigDefaults.ThinkingConfig?
    private(set) var defaultPermissionMode: PermissionMode?

    /// 主页正在看的对话。
    private(set) var chat: ChatModel?

    /// 输入框里还没发出去的字，按对话记着：切到别的对话再回来还在。
    /// 只在内存里（不落盘），退出登录清掉。打字时每个字都写，不参与观察，免得整页跟着重绘。
    @ObservationIgnored private var composerDrafts: [String: String] = [:]

    /// 体验模式（App Store 审核用）：不登录、不连任何设备，数据全来自本地演示后端 `DemoClient`。
    private(set) var isDemoMode = false

    /// 欢迎页的开场动效每次启动只放一次（退出登录回到欢迎页不再放）。
    var hasPlayedSplash = false

    var errorMessage: String?
    /// 最近一次错误是否疑似上游 Kimi Code 新版协议不兼容（弹窗与空态提供「使用网页版」兜底）。
    var isCompatibilityError = false

    /// 当前设备（或第一台在线设备）对应的官方网页版地址；体验模式下不提供。
    var webFallbackURL: URL? {
        guard !isDemoMode else { return nil }
        if let endpoint {
            return endpoint.webURL(sessionID: chat?.sessionID)
        }
        guard let device = onlineDevices.first else { return nil }
        return Endpoint.remote(deviceID: device.deviceID, name: device.shortName).webURL()
    }

    private static let lastDeviceKey = "kimi.lastDeviceID"

    // MARK: 客户端

    /// 每次请求都重新取 token：refresh 之后旧的那份就作废了。
    /// `AuthStore` 是 `@MainActor` 隔离的类，所以隐式 Sendable，可以直接捕获。
    private var tokenProvider: @Sendable () async -> String? {
        let auth = auth
        return { @Sendable in
            await auth.refreshIfNeeded()
            return await auth.bearerToken
        }
    }

    var client: (any KapServicing)? {
        guard let endpoint else { return nil }
        if isDemoMode { return DemoClient(deviceID: endpoint.deviceID) }
        return KapClient(endpoint: endpoint, tokenProvider: tokenProvider)
    }

    private var relay: RelayClient {
        RelayClient(origin: KimiConfig.relayOrigin, tokenProvider: tokenProvider)
    }

    var currentDevice: RemoteDevice? {
        devices.first { $0.deviceID == endpoint?.deviceID }
    }

    private var reachability = DeviceReachability()

    var onlineDevices: [RemoteDevice] { devices.filter(reachability.isOnline) }

    func isDeviceOnline(_ device: RemoteDevice) -> Bool {
        reachability.isOnline(device)
    }

    // MARK: 启动

    /// 从启动页「暂不登录，体验功能」进入体验模式。
    /// **已登录时忽略**：登录状态下绝不使用演示后端。
    func startDemo() {
        guard !auth.isSignedIn, !isDemoMode else { return }
        isDemoMode = true
    }

    /// 登录后调用：拉设备 → 选上次那台（还在线的话）或第一台在线的 → 拉它的数据 → 打开一个新对话。
    func bootstrap() async {
        await refreshDevices()
        guard endpoint == nil else { return }
        let last = UserDefaults.standard.string(forKey: Self.lastDeviceKey)
        let pick = onlineDevices.first { $0.deviceID == last } ?? onlineDevices.first
        if let pick { await select(pick) }
    }

    func refreshDevices(silent: Bool = false) async {
        if isDemoMode {
            devices = DemoClient.devices
            isLoadingDevices = false
            hasLoadedDevices = true
            return
        }
        guard auth.isSignedIn else { return }
        if !silent { isLoadingDevices = true }
        defer {
            if !silent { isLoadingDevices = false }
            hasLoadedDevices = true
        }
        do {
            let list = try await relay.devices()
            devices = list.devices.sorted { lhs, rhs in
                if lhs.isOnline != rhs.isOnline { return lhs.isOnline }
                return lhs.alias.localizedCaseInsensitiveCompare(rhs.alias) == .orderedAscending
            }
            clearError()
        } catch {
            guard !Task.isCancelled, !KapError.isCancellation(error) else { return }
            if silent {
                if let kapError = error as? KapError, kapError.requiresReauth { signOut() }
                return
            }
            handle(error)
        }
    }

    func select(_ device: RemoteDevice) async {
        guard device.deviceID != endpoint?.deviceID else { return }
        chat?.stop()
        chat = nil
        workspaces = []
        sessionPool.reset()
        syncSessions()
        models = []
        defaultModelID = nil
        defaultThinking = nil
        defaultPermissionMode = nil
        usage = nil
        endpoint = .remote(deviceID: device.deviceID, name: device.shortName)
        reachability = DeviceReachability()
        // 体验模式不覆盖记住的设备：退出体验、真正登录后还要回到上次那台。
        if !isDemoMode {
            UserDefaults.standard.set(device.deviceID, forKey: Self.lastDeviceKey)
        }

        await refreshDeviceData()
        if chat == nil, let workspace = workspaces.first {
            newChat(in: workspace)
        }
    }

    /// 一次拉齐侧栏和 composer 需要的东西。
    func refreshDeviceData() async {
        guard let client, let expectedDeviceID = endpoint?.deviceID else { return }
        async let workspaces = client.workspaces()
        async let sessions = client.sessions()
        async let models = client.models()
        async let config = client.configDefaults()
        async let user = client.userInfo()

        do {
            let loadedWorkspaces = try await workspaces
            let loadedSessions = try await sessions.items
            guard endpoint?.deviceID == expectedDeviceID else { return }
            self.workspaces = loadedWorkspaces.sorted {
                ($0.lastOpenedAt?.date ?? .distantPast) > ($1.lastOpenedAt?.date ?? .distantPast)
            }
            sessionPool.reconcile(fetched: loadedSessions)
            syncSessions()
            clearError()
        } catch {
            handle(error)
        }
        // 下面几项失败不影响主流程。
        // 电脑上配好的模型全都列出（含第三方 provider）；「Kimi 订阅」组排最前，组内顺序沿用服务端返回的。
        let all = (try? await models) ?? []
        guard endpoint?.deviceID == expectedDeviceID else { return }
        self.models = all.filter(\.isKimiSubscription) + all.filter { !$0.isKimiSubscription }
        if let defaults = try? await config, endpoint?.deviceID == expectedDeviceID {
            apply(defaults)
        } else if endpoint?.deviceID == expectedDeviceID {
            syncDraftDefaults()
        }
        guard endpoint?.deviceID == expectedDeviceID else { return }
        if let value = try? await user, endpoint?.deviceID == expectedDeviceID { self.user = value }
        reconcileDraft()
    }

    /// 供应商改完后重拉模型列表和默认配置（composer / 模型面板跟着变）。
    func reloadModels() async {
        guard let client, let expectedDeviceID = endpoint?.deviceID else { return }
        async let models = client.models()
        async let config = client.configDefaults()
        if let all = try? await models, endpoint?.deviceID == expectedDeviceID {
            self.models = all.filter(\.isKimiSubscription) + all.filter { !$0.isKimiSubscription }
        }
        if let defaults = try? await config, endpoint?.deviceID == expectedDeviceID {
            apply(defaults)
        } else if endpoint?.deviceID == expectedDeviceID {
            syncDraftDefaults()
        }
        guard endpoint?.deviceID == expectedDeviceID else { return }
        reconcileDraft()
    }

    /// 个人面板只改新会话的默认模型 / 强度 / 权限，不改当前会话的配置（未手动修改的空白草稿同步跟随）。
    func updateDefaultModel(_ id: String) async throws {
        guard let client, let expectedDeviceID = endpoint?.deviceID else { return }
        let updated = try await client.updateConfig(ServerConfigPatch(defaultModel: id))
        guard endpoint?.deviceID == expectedDeviceID else { return }
        apply(updated)
    }

    func updateDefaultThinking(_ option: String) async throws {
        guard let client, let expectedDeviceID = endpoint?.deviceID else { return }
        let updated = try await client.updateConfig(ServerConfigPatch(
            thinking: ServerConfigDefaults.ThinkingConfig(option: option)
        ))
        guard endpoint?.deviceID == expectedDeviceID else { return }
        apply(updated)
    }

    func updateDefaultPermission(_ mode: PermissionMode) async throws {
        guard let client, let expectedDeviceID = endpoint?.deviceID else { return }
        let updated = try await client.updateConfig(ServerConfigPatch(defaultPermissionMode: mode))
        guard endpoint?.deviceID == expectedDeviceID else { return }
        apply(updated)
    }

    private func apply(_ defaults: ServerConfigDefaults) {
        defaultModelID = defaults.defaultModel
        defaultThinking = defaults.thinking
        defaultPermissionMode = defaults.defaultPermissionMode
        syncDraftDefaults()
    }

    private func syncDraftDefaults() {
        chat?.applyDefaults(defaultComposerConfig, defaultThinking: defaultThinking, models: models)
    }

    /// 打开侧栏时刷新：会话状态（忙/待确认）变化最快。
    func refreshSidebar() async {
        guard let client, let expectedDeviceID = endpoint?.deviceID else { return }
        async let sessions = client.sessions()
        async let workspaces = client.workspaces()
        if let items = try? await sessions.items, endpoint?.deviceID == expectedDeviceID {
            sessionPool.reconcile(fetched: items)
            syncSessions()
        }
        if let items = try? await workspaces, endpoint?.deviceID == expectedDeviceID {
            self.workspaces = items.sorted {
                ($0.lastOpenedAt?.date ?? .distantPast) > ($1.lastOpenedAt?.date ?? .distantPast)
            }
            reconcileDraft()
        }
    }

    private func syncSessions() {
        if sessions != sessionPool.sessions {
            sessions = sessionPool.sessions
        }
    }

    /// 草稿所在的文件夹被删了（比如在电脑上移除了工作区）：换到还在的第一个文件夹；
    /// 一个都不剩就清空，让主页显示「打开文件夹」引导。
    private func reconcileDraft() {
        guard let chat, chat.isDraft else {
            if chat == nil, let first = workspaces.first { newChat(in: first) }
            return
        }
        guard let workspace = chat.workspace, !workspaces.contains(where: { $0.id == workspace.id }) else { return }
        if let first = workspaces.first {
            newChat(in: first)
        } else {
            replaceChat(with: nil)
        }
    }

    func refreshUsage() async {
        guard let client else { return }
        if let value = try? await client.usage() { usage = value }
    }

    // MARK: 侧栏分组

    /// 某个文件夹下的会话，最近活动的在前。
    func sessions(in workspace: Workspace) -> [SessionSummary] {
        sessions
            .filter { $0.workspaceID == workspace.id && $0.archived != true }
            .sorted { ($0.updatedAt?.date ?? .distantPast) > ($1.updatedAt?.date ?? .distantPast) }
    }

    func model(withID id: String?) -> ModelInfo? {
        guard let id else { return nil }
        return models.first { $0.model == id }
    }

    // MARK: 打开对话

    func open(_ session: SessionSummary) {
        guard session.id != chat?.sessionID else { return }
        let workspace = workspaces.first { $0.id == session.workspaceID }
        replaceChat(with: makeChat(session: session, workspace: workspace))
    }

    /// 添加一个项目文件夹：建成工作区后刷新侧栏，并在里面开一个新对话草稿（与网页端一致）。
    func addWorkspace(root: String) async throws {
        guard let client else { return }
        let workspace = try await client.addWorkspace(root: root)
        await refreshSidebar()
        newChat(in: workspaces.first { $0.id == workspace.id } ?? workspace)
    }

    /// 重命名会话。名字为空或没变就什么都不做（与网页端一致）。
    func rename(_ session: SessionSummary, to title: String) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client, !trimmed.isEmpty, trimmed != session.displayTitle else { return }
        do {
            let updated = try await client.renameSession(session.id, title: trimmed)
            sessionPool.recordRenamed(updated)
            syncSessions()
            chat?.replaceSession(updated)
        } catch {
            handle(error)
        }
    }

    /// 永久删除会话。删的正是当前这条时，回到同一文件夹的新对话。
    func delete(_ session: SessionSummary) async {
        guard let client else { return }
        do {
            try await client.deleteSession(session.id)
            sessionPool.recordRemoved(session.id)
            syncSessions()
            if chat?.sessionID == session.id {
                let workspace = workspaces.first { $0.id == session.workspaceID }
                replaceChat(with: makeChat(session: nil, workspace: workspace))
            }
        } catch {
            handle(error)
        }
    }

    func newChat(in workspace: Workspace) {
        replaceChat(with: makeChat(session: nil, workspace: workspace))
    }

    private func replaceChat(with next: ChatModel?) {
        chat?.stop()
        chat = next
        if let next { Task { await next.start() } }
    }

    private func makeChat(session: SessionSummary?, workspace: Workspace?) -> ChatModel? {
        guard let client, let endpoint else { return nil }
        let deviceID = endpoint.deviceID
        return ChatModel(
            session: session,
            workspace: workspace,
            config: defaultComposerConfig,
            client: client,
            endpoint: endpoint,
            tokenProvider: tokenProvider,
            liveUpdates: !isDemoMode,
            onSessionCreated: { [weak self] created in
                guard let self, self.endpoint?.deviceID == deviceID else { return }
                self.sessionPool.recordCreated(created)
                self.syncSessions()
            },
            onSessionEvent: { [weak self] change, summary in
                guard let self, self.endpoint?.deviceID == deviceID else { return }
                self.sessionPool.applyLiveEvent(change: change, session: summary)
                self.syncSessions()
            },
            onPromptSent: { [weak self] sessionID, text in
                guard let self, self.endpoint?.deviceID == deviceID else { return }
                self.sessionPool.recordPromptSent(sessionID: sessionID, text: text)
                self.syncSessions()
            }
        )
    }

    /// 新对话默认配置：跟随电脑端 `/config` 的默认模型、默认思考强度与默认权限（权限未设时为「始终询问」）。
    /// 若服务端默认模型已不在可用列表里，退回列表第一个（Kimi 订阅组优先）。
    private var defaultComposerConfig: ComposerConfig {
        ComposerConfig.resolved(
            models: models,
            defaultModelID: defaultModelID,
            defaultThinking: defaultThinking,
            defaultPermissionMode: defaultPermissionMode
        )
    }

    // MARK: 输入框草稿

    func composerDraft(for chat: ChatModel) -> String {
        composerDrafts[draftKey(chat)] ?? ""
    }

    func setComposerDraft(_ text: String, for chat: ChatModel) {
        composerDrafts[draftKey(chat)] = text.isEmpty ? nil : text
    }

    /// 设备 + 会话；还没建会话的新对话按文件夹记。
    private func draftKey(_ chat: ChatModel) -> String {
        "\(endpoint?.deviceID ?? "")/" + (chat.sessionID ?? "draft:\(chat.workspace?.id ?? "")")
    }

    // MARK: 账号

    func signOut() {
        composerDrafts = [:]
        chat?.stop()
        chat = nil
        endpoint = nil
        reachability = DeviceReachability()
        devices = []
        workspaces = []
        sessionPool.reset()
        syncSessions()
        user = nil
        usage = nil
        models = []
        defaultModelID = nil
        defaultThinking = nil
        defaultPermissionMode = nil
        hasLoadedDevices = false
        isDemoMode = false
        clearError()
        auth.signOut()
    }

    func clearError() {
        errorMessage = nil
        isCompatibilityError = false
    }

    private func handle(_ error: any Error) {
        guard !Task.isCancelled, !KapError.isCancellation(error) else { return }
        if let kapError = error as? KapError, kapError.requiresReauth {
            signOut()
            return
        }
        if KapError.isProtocolMismatch(error) {
            isCompatibilityError = true
            errorMessage = KapError.protocolMismatchMessage
        } else {
            isCompatibilityError = false
            errorMessage = error.localizedDescription
        }
    }
}

extension RemoteDevice {
    /// 「MacBook-Air.local」→「MacBook-Air」
    var shortName: String {
        alias.hasSuffix(".local") ? String(alias.dropLast(6)) : alias
    }
}
