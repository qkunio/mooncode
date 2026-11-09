import SwiftUI

/// 模型面板右上角 ⚙︎：「模型配置」。默认模型在侧栏个人面板，这里保留默认权限 / 思考；
/// 下面是模型供应商（照网页端「供应商管理」）：编辑 / 手动添加 / 从目录（models.dev）添加。改动直接写进电脑上的配置。
struct ProviderSettingsSheet: View {
    let client: any KapServicing
    /// 供应商有增删改后调用，外面据此重拉模型列表。
    let onChange: () async -> Void

    @State private var providers: [ProviderItem]?
    @State private var configModels: [ConfigModelEntry] = []
    @State private var defaults: ServerConfigDefaults?
    @State private var models: [ModelInfo] = []
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var refreshingID: String?
    @State private var pendingDelete: ProviderItem?
    @State private var path: [Route] = []

    enum Route: Hashable {
        case defaults
        case edit(ProviderItem)
        case add
        case catalog
        case catalogImport(CatalogProvider)
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("模型配置")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        SheetCloseButton()
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("从目录添加", systemImage: "books.vertical") { path.append(.catalog) }
                            Button("手动添加", systemImage: "square.and.pencil") { path.append(.add) }
                        } label: {
                            Label("添加供应商", systemImage: "plus")
                        }
                    }
                }
                .navigationDestination(for: Route.self, destination: destination)
        }
        .task { await load() }
        .alert(
            "删除供应商",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { provider in
            Button("取消", role: .cancel) {}
            Button("确认删除", role: .destructive) {
                Task { await delete(provider) }
            }
        } message: { provider in
            Text("确认删除 \(provider.title) 及其 \(provider.models.count) 个模型？")
        }
        .alert(
            "操作失败",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let providers {
            List {
                let managed = providers.filter(\.isManaged)
                let others = providers.filter { !$0.isManaged }
                Section {
                    NavigationLink(value: Route.defaults) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("默认配置")
                                .font(.body.weight(.medium))
                            Text(defaultsSummary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                    }
                }
                if !managed.isEmpty {
                    Section("模型供应商") {
                        ForEach(managed) { row($0) }
                    }
                }
                Section {
                    if others.isEmpty {
                        Text("还没有其他供应商。点右上角 + 添加。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(others) { row($0) }
                } header: {
                    Text(managed.isEmpty ? "模型供应商" : "其他供应商")
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await load() }
        } else if let loadError {
            ContentUnavailableView {
                Label("无法读取供应商", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            } actions: {
                Button("重试") { Task { await load() } }
                    .buttonStyle(.glass)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ provider: ProviderItem) -> some View {
        NavigationLink(value: Route.edit(provider)) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.title)
                        .font(.body.weight(.medium))
                    Text(subtitle(for: provider))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if refreshingID == provider.id {
                    ProgressView()
                } else {
                    StatusBadge(status: provider.status)
                }
            }
            .padding(.vertical, 2)
        }
        .swipeActions(edge: .trailing) {
            if !provider.isManaged {
                Button("删除", systemImage: "trash", role: .destructive) { pendingDelete = provider }
            }
            Button("刷新", systemImage: "arrow.clockwise") { Task { await refresh(provider) } }
                .tint(.blue)
        }
    }

    /// 「K3 · 始终询问 · Max」。
    private var defaultsSummary: String {
        guard let defaults else { return "读取中…" }
        let model = models.first { $0.model == defaults.defaultModel }
        var parts = [model?.name ?? defaults.defaultModel.map { ($0 as NSString).lastPathComponent } ?? "未设置默认模型"]
        parts.append((defaults.defaultPermissionMode ?? .manual).title)
        if let model, model.thinkingOptions.count > 1 {
            parts.append(defaults.thinkingOption(for: model).thinkingOptionLabel)
        }
        return parts.joined(separator: " · ")
    }

    private func subtitle(for provider: ProviderItem) -> String {
        let kind = provider.isManaged ? "OAuth 托管" : ProviderWireType.title(for: provider.type)
        var parts = [kind, "\(provider.models.count) 个模型"]
        if !provider.isManaged, !provider.hasAPIKey { parts.append("未设置 key") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func destination(_ route: Route) -> some View {
        switch route {
        case .defaults:
            DefaultsSettingsView(client: client, models: models, initial: defaults) { updated in
                defaults = updated
                await onChange()
            }
        case let .edit(provider):
            ProviderEditView(
                client: client,
                mode: .edit(provider),
                existingIDs: providers?.map(\.id) ?? [],
                configModels: configModels
            ) { await finish() }
        case .add:
            ProviderEditView(
                client: client,
                mode: .add,
                existingIDs: providers?.map(\.id) ?? [],
                configModels: configModels
            ) { await finish() }
        case .catalog:
            CatalogListView(client: client) { path.append(.catalogImport($0)) }
        case let .catalogImport(entry):
            CatalogImportView(client: client, entry: entry, existingIDs: providers?.map(\.id) ?? []) {
                await finish()
            }
        }
    }

    // MARK: 动作

    private func load() async {
        do {
            async let items = client.providers()
            async let entries = client.configModels()
            async let config = client.configDefaults()
            async let list = client.models()
            providers = try await items
            configModels = (try? await entries) ?? []
            defaults = try? await config
            let all = (try? await list) ?? []
            models = all.filter(\.isKimiSubscription) + all.filter { !$0.isKimiSubscription }
            loadError = nil
        } catch is CancellationError {
        } catch {
            if providers == nil { loadError = error.localizedDescription }
        }
    }

    /// 保存 / 删除 / 导入成功：回到列表、重拉列表和外面的模型。
    private func finish() async {
        path.removeAll()
        await load()
        await onChange()
    }

    private func refresh(_ provider: ProviderItem) async {
        refreshingID = provider.id
        defer { refreshingID = nil }
        do {
            try await client.refreshProvider(provider.id)
            await load()
            await onChange()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func delete(_ provider: ProviderItem) async {
        do {
            try await client.deleteProvider(provider.id)
            await load()
            await onChange()
        } catch {
            actionError = error.localizedDescription
        }
    }
}

/// 状态点 + 文字（网页端 `status`）。
private struct StatusBadge: View {
    let status: ProviderItem.Status

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch status {
        case .connected: "已连接"
        case .error: "错误"
        case .unconfigured: "未配置"
        }
    }

    private var color: Color {
        switch status {
        case .connected: .green
        case .error: .red
        case .unconfigured: Color(.tertiaryLabel)
        }
    }
}

// MARK: - 默认配置

/// 新会话的默认权限 / 思考。默认模型已挪到侧栏个人面板；每项仍单独 `POST /config`。
private struct DefaultsSettingsView: View {
    let client: any KapServicing
    let models: [ModelInfo]
    let onSaved: (ServerConfigDefaults) async -> Void

    @State private var config: ServerConfigDefaults?
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(client: any KapServicing, models: [ModelInfo], initial: ServerConfigDefaults?,
         onSaved: @escaping (ServerConfigDefaults) async -> Void) {
        self.client = client
        self.models = models
        self.onSaved = onSaved
        _config = State(initialValue: initial)
    }

    private var defaultModel: ModelInfo? { models.first { $0.model == config?.defaultModel } }

    var body: some View {
        Form {
            Section {
                let mode = config?.defaultPermissionMode ?? .manual
                LabeledContent("默认权限") {
                    // 自己画右侧的值：系统菜单 Picker 的图标和字贴得太紧。点开仍是系统菜单（带图标和说明）。
                    Menu {
                        Picker("默认权限", selection: Binding(
                            get: { mode },
                            set: { save(ServerConfigPatch(defaultPermissionMode: $0)) }
                        )) {
                            ForEach(PermissionMode.allCases) { option in
                                Label {
                                    Text(option.title)
                                    Text(option.subtitle)
                                } icon: {
                                    Image(systemName: option.symbolName)
                                }
                                .tag(option)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: mode.symbolName)
                            Text(mode.title)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.footnote.weight(.semibold))
                        }
                        .foregroundStyle(Color(.secondaryLabel))
                    }
                }
            } footer: {
                Text("只影响之后新建的会话。")
            }

            Section {
                if let model = defaultModel, let config {
                    if model.thinkingOptions.count > 1 {
                        Picker(model.efforts.isEmpty ? "默认思考" : "默认思考强度", selection: Binding(
                            get: { config.thinkingOption(for: model) },
                            set: { option in
                                // 网页端 `q8`：选「开启」时落到模型的默认强度。
                                let value = option == "on" ? model.defaultThinking : option
                                save(ServerConfigPatch(thinking: .init(option: value)))
                            }
                        )) {
                            let options = model.thinkingOptions.filter { $0 == "off" } + model.thinkingOptions.filter { $0 != "off" }
                            ForEach(options, id: \.self) { Text($0.thinkingOptionLabel).tag($0) }
                        }
                    } else {
                        LabeledContent("默认思考", value: model.thinkingKind == .unsupported ? "不支持" : model.defaultThinking.thinkingOptionLabel)
                    }
                } else {
                    LabeledContent("默认思考", value: "先选默认模型")
                }
            } footer: {
                Text("跟随默认模型可选的档位。")
            }
        }
        .navigationTitle("默认配置")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isSaving {
                ToolbarItem(placement: .primaryAction) { ProgressView() }
            }
        }
        .task {
            if config == nil { config = try? await client.configDefaults() }
        }
        .alert(
            "保存失败",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save(_ patch: ServerConfigPatch) {
        Task {
            isSaving = true
            defer { isSaving = false }
            do {
                let updated = try await client.updateConfig(patch)
                config = updated
                await onSaved(updated)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// 默认模型列表：按来源分组（组名是分组标题），勾选当前默认，点一下保存并返回。
struct DefaultModelList: View {
    let models: [ModelInfo]
    let selected: String?
    let select: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private var groups: [(label: String, models: [ModelInfo])] {
        var result: [(label: String, models: [ModelInfo])] = []
        for model in models {
            if let index = result.firstIndex(where: { $0.label == model.providerLabel }) {
                result[index].models.append(model)
            } else {
                result.append((model.providerLabel, [model]))
            }
        }
        return result
    }

    var body: some View {
        List {
            ForEach(groups, id: \.label) { group in
                Section(group.label) {
                    ForEach(group.models) { model in
                        Button {
                            if model.model != selected { select(model.model) }
                            dismiss()
                        } label: {
                            HStack {
                                Text(model.name)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if model.model == selected {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(Palette.kimi)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("默认模型")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 编辑 / 手动添加

/// 表单里的一个模型（网页端 `R4` / `Tx` 的形状）。能力、强度这些表单不展示的字段原样带回去，免得保存时丢。
private struct ModelDraft: Identifiable, Equatable {
    let id = UUID()
    var model = ""
    var contextSize = ""
    var displayName = ""
    var capabilities = ["tool_use", "thinking"]
    var supportEfforts: [String] = []
    var adaptiveThinking: Bool? = true

    init() {}

    init(_ entry: ConfigModelEntry) {
        model = entry.model
        contextSize = entry.maxContextSize.map(String.init) ?? ""
        displayName = entry.displayName ?? ""
        capabilities = entry.capabilities ?? []
        supportEfforts = entry.supportEfforts ?? []
        adaptiveThinking = entry.adaptiveThinking
    }

    var title: String {
        let name = displayName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty { return name }
        let id = model.trimmingCharacters(in: .whitespaces)
        return id.isEmpty ? "未填写模型 ID" : id
    }

    /// 网页端 `iZ`：空的可选字段不带。
    var input: ProviderModelInput {
        let name = displayName.trimmingCharacters(in: .whitespaces)
        return ProviderModelInput(
            model: model.trimmingCharacters(in: .whitespaces),
            maxContextSize: Int(contextSize.trimmingCharacters(in: .whitespaces)) ?? 0,
            displayName: name.isEmpty ? nil : name,
            capabilities: capabilities.isEmpty ? nil : capabilities,
            supportEfforts: supportEfforts.isEmpty ? nil : supportEfforts,
            adaptiveThinking: adaptiveThinking
        )
    }
}

/// 表单里能改的部分，用来判断有没有未保存的修改。
private struct ProviderForm: Equatable {
    var name = ""
    var type = ProviderWireType.openai
    var baseURL = ""
    var apiKey = ""
    var models = [ModelDraft()]
}

private struct ProviderEditView: View {
    enum Mode {
        case add
        case edit(ProviderItem)
    }

    let client: any KapServicing
    let mode: Mode
    let existingIDs: [String]
    let configModels: [ConfigModelEntry]
    let onDone: () async -> Void

    @Environment(\.dismiss) private var dismiss
    // 两份必须来自同一个实例：ModelDraft 的 id 每次新建都不同，分别 new 出来永远不相等。
    @State private var form: ProviderForm
    @State private var original: ProviderForm
    @State private var didPrefill = false
    /// 编辑时 key 是从服务端预填的：清空它就是要删掉 key（网页端 `includeBlankApiKey`）。
    @State private var keyPrefilled = false
    @State private var showsKey = false
    @State private var editingModelID: UUID?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var confirmsDelete = false
    @State private var confirmsDiscard = false

    init(
        client: any KapServicing,
        mode: Mode,
        existingIDs: [String],
        configModels: [ConfigModelEntry],
        onDone: @escaping () async -> Void
    ) {
        self.client = client
        self.mode = mode
        self.existingIDs = existingIDs
        self.configModels = configModels
        self.onDone = onDone
        let initial = ProviderForm()
        _form = State(initialValue: initial)
        _original = State(initialValue: initial)
    }

    private var provider: ProviderItem? {
        if case let .edit(provider) = mode { return provider }
        return nil
    }

    private var isAdding: Bool { provider == nil }
    private var isDirty: Bool { form != original }

    var body: some View {
        Group {
            if let provider, provider.isManaged {
                managedView(provider)
            } else {
                editor
            }
        }
        .navigationTitle(isAdding ? "添加供应商" : provider?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task { await prefill() }
    }

    // MARK: Kimi 订阅（只读）

    private func managedView(_ provider: ProviderItem) -> some View {
        Form {
            Section {
                LabeledContent("API 协议", value: ProviderWireType.title(for: provider.type))
                LabeledContent("登录方式", value: "OAuth 托管")
            } footer: {
                Text("Kimi 订阅随电脑上登录的 Kimi 账号提供，不需要在这里配置 key。")
            }
            Section("模型") {
                let drafts = models(of: provider)
                if drafts.isEmpty {
                    Text("暂无模型").foregroundStyle(.secondary)
                }
                ForEach(drafts) { draft in
                    LabeledContent(draft.title, value: contextLabel(draft.contextSize))
                }
            }
        }
    }

    // MARK: 可编辑

    private var editor: some View {
        Form {
            Section {
                LabeledContent("名称") {
                    TextField("必填", text: $form.name)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Picker("API 协议", selection: $form.type) {
                    ForEach(ProviderWireType.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Base URL") {
                    TextField(isAdding ? "必填" : "https://api.example.com/v1", text: $form.baseURL)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            Section {
                HStack {
                    Group {
                        if showsKey {
                            TextField(keyPlaceholder, text: $form.apiKey)
                        } else {
                            SecureField(keyPlaceholder, text: $form.apiKey)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    Button {
                        showsKey.toggle()
                    } label: {
                        Image(systemName: showsKey ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showsKey ? "隐藏 API Key" : "显示 API Key")
                }
            } header: {
                Text("API Key")
            }

            Section {
                ForEach(form.models) { draft in
                    Button {
                        editingModelID = draft.id
                    } label: {
                        LabeledContent {
                            Text(contextLabel(draft.contextSize))
                        } label: {
                            Text(draft.title)
                                .foregroundStyle(draft.model.isEmpty ? .secondary : .primary)
                        }
                    }
                    .tint(.primary)
                }
                .onDelete { offsets in
                    guard form.models.count - offsets.count >= 1 else { return }
                    form.models.remove(atOffsets: offsets)
                }
                Button("添加模型", systemImage: "plus") {
                    let draft = ModelDraft()
                    form.models.append(draft)
                    editingModelID = draft.id
                }
            } header: {
                Text("模型")
            } footer: {
                Text("左滑删除模型，至少保留一个。")
            }

            if !isAdding {
                Section {
                    Button("删除供应商", role: .destructive) { confirmsDelete = true }
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationDestination(item: $editingModelID) { id in
            if let index = form.models.firstIndex(where: { $0.id == id }) {
                ModelDraftEditor(draft: $form.models[index])
            }
        }
        .toolbar {
            if isDirty {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { confirmsDiscard = true }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if isSaving {
                    ProgressView()
                } else {
                    Button(isAdding ? "添加" : "保存") { Task { await save() } }
                        .disabled(!isDirty)
                }
            }
        }
        // 有未保存的修改时不能直接返回 / 下滑关掉，走「取消」确认。
        .navigationBarBackButtonHidden(isDirty)
        .interactiveDismissDisabled(isDirty)
        .confirmationDialog("有未保存的修改。", isPresented: $confirmsDiscard, titleVisibility: .visible) {
            Button("丢弃", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
        .alert("删除供应商", isPresented: $confirmsDelete) {
            Button("取消", role: .cancel) {}
            Button("确认删除", role: .destructive) { Task { await delete() } }
        } message: {
            Text("确认删除 \(provider?.title ?? "") 及其 \(form.models.count) 个模型？")
        }
        .alert(
            isAdding ? "添加失败" : "保存失败",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var keyPlaceholder: String {
        if isAdding { return "必填" }
        return provider?.hasAPIKey == true ? "已设置，输入以更换" : "sk-…"
    }

    private func contextLabel(_ raw: String) -> String {
        guard let value = Int(raw.trimmingCharacters(in: .whitespaces)), value > 0 else { return "—" }
        if value >= 1_000_000, value % 1_000_000 == 0 { return "\(value / 1_000_000)M" }
        if value >= 1024 { return "\(value / 1024)K" }
        return "\(value)"
    }

    private func models(of provider: ProviderItem) -> [ModelDraft] {
        configModels.filter { $0.provider == provider.id }.map(ModelDraft.init)
    }

    // MARK: 读 / 写

    private func prefill() async {
        guard let provider, !provider.isManaged, !didPrefill else { return }
        didPrefill = true
        var initial = ProviderForm()
        initial.name = provider.id
        initial.type = ProviderWireType(rawValue: provider.type) ?? .openai
        initial.baseURL = provider.baseURL ?? ""
        let drafts = models(of: provider)
        initial.models = drafts.isEmpty ? [ModelDraft()] : drafts
        form = initial
        original = initial
        // 列表不带 key，单独拿一次预填（网页端同样只在有 key 时取）。
        guard provider.hasAPIKey, let detail = try? await client.provider(provider.id),
              let key = detail.apiKey, !key.isEmpty else { return }
        keyPrefilled = true
        if form.apiKey.isEmpty { form.apiKey = key }
        original.apiKey = key
    }

    /// 网页端 `$1e` 的校验。
    private func validate() -> String? {
        let name = form.name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "名称不能为空" }
        if name.wholeMatch(of: /[\p{L}\p{N}][\p{L}\p{N}\-_ ]*/) == nil {
            return #"名称需以字母或数字开头，只能包含字母、数字、"-"、"_" 和空格"#
        }
        if isAdding, form.apiKey.trimmingCharacters(in: .whitespaces).isEmpty { return "API Key 不能为空" }
        if isAdding, form.baseURL.trimmingCharacters(in: .whitespaces).isEmpty { return "Base URL 不能为空" }
        if name != provider?.id, existingIDs.contains(name) { return "已有同名供应商" }
        var seen = Set<String>()
        for draft in form.models {
            let id = draft.model.trimmingCharacters(in: .whitespaces)
            if id.isEmpty { return "模型 ID 不能为空" }
            let context = draft.contextSize.trimmingCharacters(in: .whitespaces)
            if context.isEmpty { return "\(id) 的上下文长度不能为空" }
            guard let value = Int(context), value >= 1 else { return "\(id) 的上下文长度需为正整数" }
            if !seen.insert(id).inserted { return "模型 \(id) 重复了" }
        }
        return nil
    }

    private func save() async {
        if let problem = validate() {
            errorMessage = problem
            return
        }
        isSaving = true
        defer { isSaving = false }
        let name = form.name.trimmingCharacters(in: .whitespaces)
        let key = form.apiKey.trimmingCharacters(in: .whitespaces)
        let baseURL = form.baseURL.trimmingCharacters(in: .whitespaces)
        let models = form.models.map(\.input)
        do {
            if let provider {
                // 网页端 `B1e`：改名带 new_id；key 留空且不是预填的就不动；默认模型还在列表里就保留。
                let defaultModel = provider.defaultModel.map { value in
                    value.firstIndex(of: "/").map { String(value[value.index(after: $0)...]) } ?? value
                }
                var body = ProviderWriteBody(type: form.type.rawValue, models: models)
                body.newID = name == provider.id ? nil : name
                body.apiKey = key.isEmpty && !keyPrefilled ? nil : key
                body.baseURL = baseURL.isEmpty ? nil : baseURL
                if let defaultModel, models.contains(where: { $0.model == defaultModel }) {
                    body.defaultModel = defaultModel
                }
                try await client.replaceProvider(provider.id, body: body)
            } else {
                var body = ProviderWriteBody(type: form.type.rawValue, models: models)
                body.id = name
                body.apiKey = key
                body.baseURL = baseURL
                try await client.createProvider(body)
            }
            original = form
            await onDone()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() async {
        guard let provider else { return }
        do {
            try await client.deleteProvider(provider.id)
            original = form
            await onDone()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 一个模型：模型 ID、上下文长度、显示名（网页端表格的三列）。
private struct ModelDraftEditor: View {
    @Binding var draft: ModelDraft

    var body: some View {
        Form {
            Section {
                LabeledContent("模型 ID") {
                    TextField("kimi-k3", text: $draft.model)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                LabeledContent("上下文") {
                    TextField("1048576", text: $draft.contextSize)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                }
                LabeledContent("显示名") {
                    TextField("可选", text: $draft.displayName)
                        .multilineTextAlignment(.trailing)
                }
            } footer: {
                Text("上下文是模型最多能处理的 token 数，例如 1048576。")
            }
        }
        .navigationTitle(draft.model.isEmpty ? "新模型" : draft.model)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 从目录添加

/// models.dev 目录（由电脑代理拉取）。不能导入的条目置灰并写明原因。
private struct CatalogListView: View {
    let client: any KapServicing
    let select: (CatalogProvider) -> Void

    @State private var items: [CatalogProvider]?
    @State private var loadError: String?
    @State private var query = ""

    private var filtered: [CatalogProvider] {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard let items else { return [] }
        guard !text.isEmpty else { return items }
        return items.filter { $0.name.lowercased().contains(text) || $0.id.lowercased().contains(text) }
    }

    var body: some View {
        Group {
            if items != nil {
                List {
                    ForEach(filtered) { item in
                        Button {
                            select(item)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.name)
                                        .foregroundStyle(item.rejected ? .secondary : .primary)
                                    Text(item.rejected
                                        ? item.rejectText
                                        : "\(ProviderWireType.title(for: item.wireType)) · \(item.modelCount) 个模型")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                if !item.rejected {
                                    Image(systemName: "chevron.forward")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(item.rejected)
                    }
                }
                .overlay {
                    if filtered.isEmpty { ContentUnavailableView.search(text: query) }
                }
                .searchable(text: $query, prompt: "搜索供应商")
            } else if let loadError {
                ContentUnavailableView {
                    Label("目录加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("重试") { Task { await load() } }
                        .buttonStyle(.glass)
                }
            } else {
                ProgressView("加载目录中…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("从目录添加")
        .navigationBarTitleDisplayMode(.inline)
        .task { if items == nil { await load() } }
    }

    private func load() async {
        loadError = nil
        do {
            items = try await client.catalogProviders()
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// 选中目录里的一项：填名称、API Key（必填）、Base URL（目录没给时必填），然后导入。
private struct CatalogImportView: View {
    let client: any KapServicing
    let entry: CatalogProvider
    let existingIDs: [String]
    let onDone: () async -> Void

    @State private var name: String
    @State private var apiKey = ""
    @State private var baseURL = ""
    @State private var showsKey = false
    @State private var isImporting = false
    @State private var errorMessage: String?

    init(client: any KapServicing, entry: CatalogProvider, existingIDs: [String], onDone: @escaping () async -> Void) {
        self.client = client
        self.entry = entry
        self.existingIDs = existingIDs
        self.onDone = onDone
        _name = State(initialValue: entry.id)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Form {
            Section {
                LabeledContent("名称") {
                    TextField("必填", text: $name)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                LabeledContent("API 协议", value: ProviderWireType.title(for: entry.wireType))
            } footer: {
                if existingIDs.contains(trimmedName) {
                    Text("已存在同名供应商，导入将覆盖其配置与模型。")
                        .foregroundStyle(Palette.danger)
                }
            }

            Section("API Key") {
                HStack {
                    Group {
                        if showsKey {
                            TextField("必填", text: $apiKey)
                        } else {
                            SecureField("必填", text: $apiKey)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                    Button {
                        showsKey.toggle()
                    } label: {
                        Image(systemName: showsKey ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showsKey ? "隐藏 API Key" : "显示 API Key")
                }
            }

            // 目录里已有地址的就不让填了（可选项删掉，界面更干净）；只有目录要求时才出现。
            if entry.needsBaseURL {
                Section {
                    TextField("https://api.example.com/v1", text: $baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Base URL")
                } footer: {
                    Text("这个供应商需要填写地址。")
                }
            }

            Section {
            } footer: {
                Text("将从目录导入 \(entry.modelCount) 个模型。")
            }
        }
        .navigationTitle(entry.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if isImporting {
                    ProgressView()
                } else {
                    Button("导入") { Task { await importProvider() } }
                }
            }
        }
        .alert(
            "导入失败",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func importProvider() async {
        let key = apiKey.trimmingCharacters(in: .whitespaces)
        let url = baseURL.trimmingCharacters(in: .whitespaces)
        if trimmedName.isEmpty {
            errorMessage = "名称不能为空"
            return
        }
        if trimmedName.wholeMatch(of: /[\p{L}\p{N}][\p{L}\p{N}\-_ ]*/) == nil {
            errorMessage = #"名称需以字母或数字开头，只能包含字母、数字、"-"、"_" 和空格"#
            return
        }
        if key.isEmpty {
            errorMessage = "API Key 不能为空"
            return
        }
        if entry.needsBaseURL, url.isEmpty {
            errorMessage = "Base URL 不能为空"
            return
        }
        isImporting = true
        defer { isImporting = false }
        do {
            try await client.importCatalogProvider(
                catalogID: entry.id,
                id: trimmedName == entry.id ? nil : trimmedName,
                apiKey: key,
                baseURL: url.isEmpty ? nil : url
            )
            await onDone()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
