import SwiftUI

/// 模型列表：点模型立刻写入会话（自动保存），右上角 ⚙︎ 管理模型供应商。
/// 作为 `ModelPanel` 的子页时左上角是返回（`onBack`），单独弹出时是 ✕。
struct ModelSelectionPanel: View {
    let models: [ModelInfo]
    let apply: (ModelInfo, String?) -> Void
    var onHeight: ((CGFloat) -> Void)?
    /// 有它才显示 ⚙︎：读写电脑上的供应商配置。
    var client: (any KapServicing)?
    /// 供应商改完后重拉模型列表。
    var onProvidersChanged: () async -> Void = {}
    /// 有它时左上角是返回箭头，没有时是 ✕ 关闭。
    var onBack: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var showsSettings = false

    @State private var selectedID: String?
    @State private var selectedEffort: String?
    @State private var listHeight: CGFloat = 0

    init(
        models: [ModelInfo],
        config: ComposerConfig,
        apply: @escaping (ModelInfo, String?) -> Void,
        onHeight: ((CGFloat) -> Void)? = nil,
        client: (any KapServicing)? = nil,
        onProvidersChanged: @escaping () async -> Void = {},
        onBack: (() -> Void)? = nil
    ) {
        self.onBack = onBack
        self.models = models
        self.apply = apply
        self.onHeight = onHeight
        self.client = client
        self.onProvidersChanged = onProvidersChanged
        _selectedID = State(initialValue: config.modelID)
        _selectedEffort = State(initialValue: config.effort)
    }

    private var selectedModel: ModelInfo? {
        models.first { $0.model == selectedID }
    }

    /// 按 provider 分组，组的顺序沿用列表顺序（Kimi 订阅组已排在最前）。
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

    /// 模型多了（第三方 provider）列表会很长：超过这个高度就在面板里滚动。
    private static let maxListHeight: CGFloat = 440

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Text("模型")
                    .font(.headline)
                HStack {
                    Button(action: { if let onBack { onBack() } else { dismiss() } }) {
                        MoonIcon(onBack == nil ? "mc-close" : "mc-chevron-left", size: 18)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel(onBack == nil ? "关闭" : "返回")
                    Spacer()
                    if client != nil {
                        Button(action: { showsSettings = true }) {
                            MoonIcon("mc-settings", size: 18)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel("管理模型供应商")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)

            ScrollViewReader { proxy in
                ScrollView {
                    modelList
                        .padding(.horizontal, 24)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(listHeight, Self.maxListHeight))
                .onAppear {
                    guard let selectedID else { return }
                    proxy.scrollTo(selectedID, anchor: .center)
                }
            }


        }
        .padding(.bottom, 28)
        // 面板高度按内容算（交给外面设 detent），不留大片空白。
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight?($0) }
        .background(Color(.systemGroupedBackground))
        .sheet(isPresented: $showsSettings) {
            if let client {
                ProviderSettingsSheet(client: client, onChange: onProvidersChanged)
                    .presentationDetents([.large])
            }
        }
    }

    /// 自动保存：每次改动直接写入会话。
    private func applySelection() {
        guard let model = selectedModel else { return }
        apply(model, model.normalizedThinking(selectedEffort))
    }

    @ViewBuilder
    private var modelList: some View {
        if models.isEmpty {
            Text("暂无可用模型")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        } else {
            let groups = groups
            VStack(alignment: .leading, spacing: 16) {
                ForEach(groups, id: \.label) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        // 来源分组名是一级标题（同用量面板卡片上方的灰色小标题）。只有一组时不显示。
                        if groups.count > 1 {
                            sectionTitle(group.label)
                        }
                        VStack(spacing: 0) {
                            ForEach(group.models) { model in
                                if model.id != group.models.first?.id {
                                    Divider().padding(.horizontal, 20)
                                }
                                choiceRow(model.name, selected: selectedID == model.model) {
                                    guard selectedID != model.model else { return }
                                    selectedID = model.model
                                    selectedEffort = model.normalizedThinking(selectedEffort)
                                    applySelection()
                                }
                                .id(model.model)
                            }
                        }
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
                    }
                }
            }
        }
    }

    /// 一级标题：同用量面板卡片上方的灰色小标题。
    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    private func choiceRow(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.body.weight(.medium))
                Spacer(minLength: 12)
                MoonIcon("mc-check", size: 16)
                    .opacity(selected ? 1 : 0)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 20)
            .frame(minHeight: 56)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
