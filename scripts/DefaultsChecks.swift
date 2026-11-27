import Foundation

private actor MockDefaultsBackend: KapServicing {
    private(set) var createdAgentConfigs: [AgentConfigPatch] = []
    private(set) var sentPrompts: [PromptBody] = []

    func workspaces() async throws -> [Workspace] { [] }
    func addWorkspace(root _: String) async throws -> Workspace { fatalError("unused") }
    func browseFs(_: String) async throws -> FsBrowse { fatalError("unused") }
    func fsHome() async throws -> FsHome { fatalError("unused") }
    func listFiles(_: String, path _: String) async throws -> FsList { fatalError("unused") }
    func readFile(_: String, path _: String) async throws -> FsContent { fatalError("unused") }
    func downloadFile(_: String, path _: String) async throws -> URL { fatalError("unused") }
    func sessions(pageSize _: Int) async throws -> SessionList { SessionList(items: [], hasMore: false) }
    func models() async throws -> [ModelInfo] { [] }
    func configDefaults() async throws -> ServerConfigDefaults { fatalError("unused") }
    func updateConfig(_: ServerConfigPatch) async throws -> ServerConfigDefaults { fatalError("unused") }
    func providers() async throws -> [ProviderItem] { [] }
    func provider(_: String) async throws -> ProviderItem { fatalError("unused") }
    func configModels() async throws -> [ConfigModelEntry] { [] }
    func createProvider(_: ProviderWriteBody) async throws {}
    func replaceProvider(_: String, body _: ProviderWriteBody) async throws {}
    func deleteProvider(_: String) async throws {}
    func refreshProvider(_: String) async throws {}
    func catalogProviders() async throws -> [CatalogProvider] { [] }
    func importCatalogProvider(catalogID _: String, id _: String?, apiKey _: String, baseURL _: String?) async throws {}
    func usage() async throws -> PlanUsage { fatalError("unused") }
    func userInfo() async throws -> KimiUser? { nil }
    func status(_: String) async throws -> SessionRuntimeStatus {
        throw KapError.http(status: 404, body: "")
    }
    func updateProfile(_: String, agentConfig _: AgentConfigPatch) async throws -> SessionSummary {
        try decode(#"{"id":"s1","workspace_id":"w1","busy":false,"pending_interaction":"none"}"#)
    }
    func renameSession(_: String, title _: String) async throws -> SessionSummary { fatalError("unused") }
    func deleteSession(_: String) async throws {}
    func transcript(_: String, pageSize _: Int, beforeTurn _: String?) async throws -> TranscriptPage {
        try decode(#"{"items":[],"has_more":false}"#)
    }
    func undo(_: String, count _: Int) async throws {}
    func createSession(in workspace: Workspace, agentConfig: AgentConfigPatch) async throws -> SessionSummary {
        createdAgentConfigs.append(agentConfig)
        return try decode(#"{"id":"s-new","workspace_id":"\#(workspace.id)","cwd":"\#(workspace.root)","activity":"idle"}"#)
    }
    func sendPrompt(_ body: PromptBody, to _: String) async throws -> PromptAccepted {
        sentPrompts.append(body)
        return try decode(#"{"prompt_id":"p1","user_message_id":"u1","status":"accepted"}"#)
    }
    func uploadFile(_: Data, name _: String, mediaType _: String) async throws -> UploadedFile { fatalError("unused") }
    func abort(_: String) async throws {}
    func pendingApprovals(_: String) async throws -> ApprovalList { ApprovalList(items: []) }
    func resolve(approval _: String, in _: String, with _: ApprovalDecisionBody) async throws -> Bool { true }
    func pendingQuestions(_: String) async throws -> QuestionList { QuestionList(items: []) }
    func answer(question _: String, in _: String, with _: QuestionAnswerBody) async throws -> Bool { true }
    func dismiss(question _: String, in _: String) async throws {}
}

private func decode<T: Decodable>(_ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

@main
@MainActor
struct DefaultsChecks {
    static func main() async throws {
        let k3: ModelInfo = try decode(
            #"{"provider":"managed:kimi-code","model":"kimi-code/k3","display_name":"K3","capabilities":["thinking","always_thinking"],"support_efforts":["low","medium","high","max"],"default_effort":"low"}"#
        )
        let alt: ModelInfo = try decode(
            #"{"provider":"custom","model":"custom/alt","display_name":"Alt","capabilities":["thinking"],"support_efforts":["low","high"],"default_effort":"low"}"#
        )
        let toggleOnly: ModelInfo = try decode(
            #"{"provider":"custom","model":"custom/toggle","display_name":"Toggle","capabilities":["thinking"]}"#
        )
        let models = [k3, alt, toggleOnly]
        let workspace: Workspace = try decode(#"{"id":"w1","root":"/tmp/demo","name":"Demo"}"#)
        let endpoint = Endpoint.remote(deviceID: "dev-1", name: "Mac")

        // 0. ServerConfigDefaults decoding (empty default_model, effort-only thinking, disabled with stale effort)
        let effortOnlyConfig: ServerConfigDefaults = try decode(
            #"{"default_model":"","default_permission_mode":"auto","thinking":{"effort":"high"}}"#
        )
        precondition(effortOnlyConfig.defaultModel == nil && effortOnlyConfig.defaultPermissionMode == .auto)
        precondition(effortOnlyConfig.thinking?.enabled == nil && effortOnlyConfig.thinking?.effort == "high")
        precondition(effortOnlyConfig.thinkingOption(for: k3) == "high")
        precondition(effortOnlyConfig.thinkingOption(for: toggleOnly) == "on")

        let disabledWithStaleEffort: ServerConfigDefaults = try decode(
            #"{"default_model":"kimi-code/k3","thinking":{"enabled":false,"effort":"high"}}"#
        )
        precondition(disabledWithStaleEffort.thinkingOption(for: alt) == "off")
        precondition(disabledWithStaleEffort.thinkingOption(for: k3) == "low")
        precondition(disabledWithStaleEffort.thinkingOption(for: toggleOnly) == "off")

        // 1. ComposerConfig.resolved respects all 3 server defaults (model, thinking, permission)
        let resolvedAll = ComposerConfig.resolved(
            models: models,
            defaultModelID: alt.model,
            defaultThinking: .init(enabled: true, effort: "high"),
            defaultPermissionMode: .yolo
        )
        precondition(resolvedAll == ComposerConfig(permission: .yolo, modelID: alt.model, effort: "high"))

        // 2. Omitted permission defaults to .manual; effort-only thinking works; missing model falls back to first
        let fallback = ComposerConfig.resolved(
            models: models,
            defaultModelID: "missing/model",
            defaultThinking: .init(enabled: nil, effort: "max"),
            defaultPermissionMode: nil
        )
        precondition(fallback == ComposerConfig(permission: .manual, modelID: k3.model, effort: "max"))

        // 3. Disabled thinking with stale effort never leaks stale effort onto always_thinking models
        let disabledOnAlways = ComposerConfig.resolved(
            models: models,
            defaultModelID: k3.model,
            defaultThinking: .init(enabled: false, effort: "max"),
            defaultPermissionMode: .auto
        )
        precondition(disabledOnAlways == ComposerConfig(permission: .auto, modelID: k3.model, effort: "low"))

        let disabledOnToggle = ComposerConfig.resolved(
            models: models,
            defaultModelID: alt.model,
            defaultThinking: .init(enabled: false, effort: "high"),
            defaultPermissionMode: .auto
        )
        precondition(disabledOnToggle == ComposerConfig(permission: .auto, modelID: alt.model, effort: "off"))

        // 4. Untouched draft syncs when server defaults change
        let backend = MockDefaultsBackend()
        let draft = ChatModel(
            session: nil,
            workspace: workspace,
            config: ComposerConfig.resolved(
                models: models,
                defaultModelID: k3.model,
                defaultThinking: .init(option: "low"),
                defaultPermissionMode: .manual
            ),
            client: backend,
            endpoint: endpoint,
            tokenProvider: { nil },
            liveUpdates: false,
            onSessionCreated: { _ in }
        )
        let updatedThinking = ServerConfigDefaults.ThinkingConfig(option: "high")
        let updatedDefaults = ComposerConfig.resolved(
            models: models,
            defaultModelID: alt.model,
            defaultThinking: updatedThinking,
            defaultPermissionMode: .auto
        )
        draft.applyDefaults(updatedDefaults, defaultThinking: updatedThinking, models: models)
        precondition(draft.config == ComposerConfig(permission: .auto, modelID: alt.model, effort: "high"))

        // 5. Draft sending first message carries the resolved defaults in createSession + sendPrompt
        await draft.send("hello")
        let createdPatches = await backend.createdAgentConfigs
        let sentPrompts = await backend.sentPrompts
        precondition(createdPatches.count == 1)
        precondition(createdPatches[0].model == alt.model)
        precondition(createdPatches[0].thinking == "high")
        precondition(createdPatches[0].permissionMode == .auto)
        precondition(sentPrompts.count == 1)
        precondition(sentPrompts[0].model == alt.model)
        precondition(sentPrompts[0].thinking == "high")
        precondition(sentPrompts[0].permissionMode == .auto)

        // 6. After becoming an existing session, applyDefaults does NOT overwrite current session config
        let afterSessionDefaults = ComposerConfig.resolved(
            models: models,
            defaultModelID: k3.model,
            defaultThinking: .init(option: "max"),
            defaultPermissionMode: .manual
        )
        draft.applyDefaults(afterSessionDefaults, defaultThinking: .init(option: "max"), models: models)
        precondition(draft.config == ComposerConfig(permission: .auto, modelID: alt.model, effort: "high"))

        // 7. Manual per-field override on a draft is preserved while unedited fields still follow defaults
        let partialDraft = ChatModel(
            session: nil,
            workspace: workspace,
            config: ComposerConfig(permission: .manual, modelID: k3.model, effort: "low"),
            client: backend,
            endpoint: endpoint,
            tokenProvider: { nil },
            liveUpdates: false,
            onSessionCreated: { _ in }
        )
        await partialDraft.setPermission(.yolo)
        partialDraft.applyDefaults(
            ComposerConfig.resolved(
                models: models,
                defaultModelID: alt.model,
                defaultThinking: .init(option: "high"),
                defaultPermissionMode: .auto
            ),
            defaultThinking: .init(option: "high"),
            models: models
        )
        precondition(partialDraft.config == ComposerConfig(permission: .yolo, modelID: alt.model, effort: "high"))

        // 8. Manual effort override normalizes if default model switches to one that lacks that effort
        let effortDraft = ChatModel(
            session: nil,
            workspace: workspace,
            config: ComposerConfig(permission: .manual, modelID: k3.model, effort: "low"),
            client: backend,
            endpoint: endpoint,
            tokenProvider: { nil },
            liveUpdates: false,
            onSessionCreated: { _ in }
        )
        await effortDraft.setModel(k3, effort: "max")
        effortDraft.applyDefaults(
            ComposerConfig.resolved(
                models: models,
                defaultModelID: toggleOnly.model,
                defaultThinking: .init(option: "off"),
                defaultPermissionMode: .auto
            ),
            defaultThinking: .init(option: "off"),
            models: models
        )
        precondition(effortDraft.config == ComposerConfig(permission: .auto, modelID: toggleOnly.model, effort: "on"))

        print("PASS: default model, effort, and permission resolution & draft sync checks")
    }
}
