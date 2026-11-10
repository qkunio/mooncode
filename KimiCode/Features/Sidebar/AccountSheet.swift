import SwiftUI

/// 全屏个人入口：账号、默认模型 / 强度 / 权限、设备显示偏好和退出登录。
struct AccountSheet: View {
    @Binding var showsDevicesInSidebar: Bool

    @Environment(AppModel.self) private var app
    @State private var isSavingDefault = false
    @State private var actionError: String?
    @State private var isConfirmingSignOut = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    profile
                    defaultSettings

                    card {
                        Toggle("在会话栏中显示设备列表", isOn: $showsDevicesInSidebar)
                    }

                    if !showsDevicesInSidebar {
                        devicesSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .safeAreaBar(edge: .bottom, spacing: 0) {
                Button(role: .destructive) { isConfirmingSignOut = true } label: {
                    Text(app.isDemoMode ? "退出体验模式" : "退出登录")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 18))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
            }
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton()
                }
            }
        }
        .task { await app.reloadModels() }
        .task(id: showsDevicesInSidebar) {
            guard !showsDevicesInSidebar else { return }
            await app.refreshDevices()
        }
        .alert(
            "操作失败",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .alert(app.isDemoMode ? "退出体验模式？" : "是否退出登录？", isPresented: $isConfirmingSignOut) {
            Button("取消", role: .cancel) {}
            Button("退出", role: .destructive) { app.signOut() }
        }
    }

    private var profile: some View {
        card {
            HStack(spacing: 14) {
                Avatar(url: app.user?.avatarURL, size: 48)
                Text(app.user?.displayName ?? "Kimi 用户")
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
    }

    private var defaultSettings: some View {
        card {
            VStack(spacing: 0) {
                NavigationLink {
                    DefaultModelList(models: app.models, selected: app.defaultModelID, select: saveDefaultModel)
                } label: {
                    settingRow(title: "默认模型", value: defaultModelLabel)
                }
                .buttonStyle(.plain)
                .disabled(app.client == nil || app.models.isEmpty || isSavingDefault)

                Divider().padding(.vertical, 6)

                NavigationLink {
                    if let defaultModel {
                        DefaultThinkingList(
                            model: defaultModel,
                            selected: thinkingOption(for: defaultModel),
                            select: saveDefaultThinking
                        )
                    }
                } label: {
                    settingRow(title: "默认强度", value: defaultThinkingLabel)
                }
                .buttonStyle(.plain)
                .disabled(
                    app.client == nil || defaultModel == nil
                        || (defaultModel?.thinkingOptions.count ?? 0) <= 1 || isSavingDefault
                )

                Divider().padding(.vertical, 6)

                Menu {
                    DefaultPermissionOptions(
                        mode: app.defaultPermissionMode ?? .manual,
                        select: saveDefaultPermission
                    )
                } label: {
                    HStack(spacing: 12) {
                        Text("默认权限")
                            .font(.body)
                            .foregroundStyle(.primary)
                            .fixedSize()
                        Spacer(minLength: 8)
                        HStack(spacing: 6) {
                            let mode = app.defaultPermissionMode ?? .manual
                            Image(systemName: mode.symbolName)
                            Text(mode.title)
                            if isSavingDefault {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.footnote.weight(.semibold))
                            }
                        }
                        .font(.body)
                        .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 32)
                }
                .disabled(app.client == nil || isSavingDefault)
            }
            .foregroundStyle(.primary)
        }
    }

    private var defaultModel: ModelInfo? { app.model(withID: app.defaultModelID) }

    private var defaultModelLabel: String {
        if let defaultModel { return defaultModel.name }
        if let raw = app.defaultModelID, !raw.isEmpty {
            return "\((raw as NSString).lastPathComponent)（不可用）"
        }
        return "未设置"
    }

    private var defaultThinkingLabel: String {
        guard let defaultModel else { return "未设置" }
        guard defaultModel.thinkingKind != .unsupported else { return "不支持" }
        return thinkingOption(for: defaultModel).thinkingOptionLabel
    }

    private func thinkingOption(for model: ModelInfo) -> String {
        if let thinking = app.defaultThinking {
            if !thinking.enabled, model.thinkingOptions.contains("off") { return "off" }
            if let effort = thinking.effort, model.thinkingOptions.contains(effort) { return effort }
        }
        return model.defaultThinking
    }

    private func settingRow(title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize()
            Spacer(minLength: 8)
            Text(value)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if isSavingDefault {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "chevron.forward")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 32)
    }

    private func saveDefaultModel(_ id: String) {
        Task {
            isSavingDefault = true
            defer { isSavingDefault = false }
            do {
                try await app.updateDefaultModel(id)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func saveDefaultThinking(_ option: String) {
        guard let defaultModel else { return }
        Task {
            isSavingDefault = true
            defer { isSavingDefault = false }
            do {
                let value = option == "on" ? defaultModel.defaultThinking : option
                try await app.updateDefaultThinking(value)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func saveDefaultPermission(_ mode: PermissionMode) {
        Task {
            isSavingDefault = true
            defer { isSavingDefault = false }
            do {
                try await app.updateDefaultPermission(mode)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("设备")
                Spacer()
                Button {
                    Task { await app.refreshDevices() }
                } label: {
                    Group {
                        if app.isLoadingDevices {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .frame(width: 32, height: 32)
                    .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .disabled(app.isLoadingDevices)
                .accessibilityLabel("刷新设备")
            }

            card {
                if app.devices.isEmpty {
                    Text(app.isLoadingDevices ? "正在读取设备…" : "暂无设备")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(app.devices.enumerated()), id: \.element.id) { index, device in
                            let isOnline = app.isDeviceOnline(device)
                            Button {
                                Task { await app.select(device) }
                            } label: {
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(isOnline ? Color.green : Color.red)
                                        .frame(width: 8, height: 8)
                                    Text(device.shortName)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    if device.deviceID == app.endpoint?.deviceID {
                                        Image(systemName: "checkmark")
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(Palette.kimi)
                                    } else if !isOnline {
                                        Text("离线")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .foregroundStyle(isOnline ? .primary : .secondary)
                                .frame(minHeight: 44)
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .disabled(!isOnline)
                            if index + 1 < app.devices.count {
                                Divider().padding(.leading, 20)
                            }
                        }
                    }
                }
            }
        }
    }
}


private struct DefaultThinkingList: View {
    let model: ModelInfo
    let selected: String
    let select: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private var options: [String] {
        model.thinkingOptions.filter { $0 == "off" } + model.thinkingOptions.filter { $0 != "off" }
    }

    var body: some View {
        List {
            ForEach(options, id: \.self) { option in
                Button {
                    if option != selected { select(option) }
                    dismiss()
                } label: {
                    HStack {
                        Text(option.thinkingOptionLabel)
                            .foregroundStyle(.primary)
                        Spacer()
                        if option == selected {
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
        .listStyle(.insetGrouped)
        .navigationTitle("默认强度")
        .navigationBarTitleDisplayMode(.inline)
    }
}
