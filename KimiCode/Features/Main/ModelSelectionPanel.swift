import SwiftUI

/// 选择暂存在面板内，只有点完成才写入会话；下滑关闭即放弃修改。
struct ModelSelectionPanel: View {
    let models: [ModelInfo]
    let confirm: (ModelInfo, String?) -> Void
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedID: String?
    @State private var selectedEffort: String?
    @State private var query = ""
    @State private var providerID: String?

    init(
        models: [ModelInfo],
        config: ComposerConfig,
        confirm: @escaping (ModelInfo, String?) -> Void
    ) {
        self.models = models
        self.confirm = confirm
        _selectedID = State(initialValue: config.modelID)
        _selectedEffort = State(initialValue: config.effort)
    }

    private var selectedModel: ModelInfo? {
        models.first { $0.model == selectedID }
    }

    private var catalog: ModelCatalog { ModelCatalog(models: models) }
    private var visibleGroups: [ModelCatalog.Group] {
        catalog.groups(matching: query, providerID: providerID)
    }
    private var scrollsEntirePanel: Bool {
        verticalSizeClass == .compact || dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        VStack(spacing: 16) {
            if scrollsEntirePanel {
                // 横屏或辅助功能字号时一起滚动，避免固定控件把模型列表挤到零高度。
                ScrollView {
                    VStack(spacing: 16) {
                        header
                        modelList
                        effortControl
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            } else {
                header
                ScrollView { modelList }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollDismissesKeyboard(.interactively)
                effortControl
            }

            confirmButton
        }
        .frame(maxHeight: .infinity)
        .onChange(of: models.map(\.provider)) {
            if let providerID, !models.contains(where: { $0.provider == providerID }) {
                self.providerID = nil
            }
        }
        .background(Color(.systemBackground))
    }

    private var header: some View {
        VStack(spacing: 16) {
            Text("模型")
                .font(.headline)
                .padding(.top, scrollsEntirePanel ? 8 : 28)
            searchField
                .padding(.horizontal, 24)
            if catalog.groups.count > 1 { providerFilters }
        }
    }

    private var modelList: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            if visibleGroups.isEmpty {
                Text(models.isEmpty ? "暂无可用模型" : "没有匹配的模型")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            }
            ForEach(visibleGroups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                    VStack(spacing: 0) {
                        ForEach(Array(group.models.enumerated()), id: \.element.id) { index, model in
                            if index > 0 { Divider().padding(.horizontal, 20) }
                            choiceRow(model, selected: selectedID == model.model) {
                                selectedID = model.model
                                selectedEffort = model.resolvedEffort(selectedEffort)
                            }
                        }
                    }
                    .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 24))
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var effortControl: some View {
        if let model = selectedModel, !model.efforts.isEmpty {
            effortMenu(for: model)
                .padding(.horizontal, 24)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var confirmButton: some View {
        Button {
            guard let model = selectedModel else { return }
            confirm(model, effectiveEffort(for: model))
        } label: {
            Text("完成")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(minHeight: 50)
                .foregroundStyle(.white)
                .background(Palette.kimi, in: .capsule)
        }
        .buttonStyle(.plain)
        .opacity(selectedModel == nil ? 0.4 : 1)
        .disabled(selectedModel == nil)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
    }

    private func effectiveEffort(for model: ModelInfo) -> String? {
        model.resolvedEffort(selectedEffort)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索模型或来源", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
    }

    private var providerFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                providerFilter("全部", id: nil)
                ForEach(catalog.groups) { group in
                    providerFilter(group.name, id: group.id)
                }
            }
            .padding(.horizontal, 24)
        }
    }

    private func providerFilter(_ title: String, id: String?) -> some View {
        let selected = providerID == id
        return Button { providerID = id } label: {
            Text(title)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Palette.kimi : .primary)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(
                    selected ? Palette.kimi.opacity(0.12) : Color(.secondarySystemBackground),
                    in: .capsule
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("模型来源：\(title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 点击整行弹出原生单选菜单；普通字号竖屏时固定在模型列表下方。
    private func effortMenu(for model: ModelInfo) -> some View {
        Menu {
            Picker("思考强度", selection: Binding(
                get: { effectiveEffort(for: model) ?? "" },
                set: { selectedEffort = $0 }
            )) {
                ForEach(model.efforts, id: \.self) { effort in
                    Text(effort.effortLabel).tag(effort)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 12) {
                Text("思考强度")
                    .foregroundStyle(.primary)
                Spacer(minLength: 12)
                Text(effectiveEffort(for: model)?.effortLabel ?? "")
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.body.weight(.medium))
            .padding(.horizontal, 20)
            .frame(minHeight: 52)
            .background(Color(.secondarySystemBackground), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("思考强度")
        .accessibilityValue(effectiveEffort(for: model)?.effortLabel ?? "")
    }

    private func choiceRow(_ model: ModelInfo, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name)
                        .font(.body.weight(.medium))
                    Text(model.model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 12)
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .opacity(selected ? 1 : 0)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(minHeight: 56)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
