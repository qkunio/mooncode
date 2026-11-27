import SwiftUI

/// 全屏个人入口：账号、默认模型 / 强度 / 权限、设备显示偏好和退出登录。
struct AccountSheet: View {
    @Binding var showsDevicesInSidebar: Bool

    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var isSavingDefault = false
    @State private var actionError: String?
    @State private var isConfirmingSignOut = false
    @State private var showsOfflineDevices = false

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        profile
                        defaultSettings
                        devicesCard

                        if !app.isDemoMode {
                            webFallbackCard
                        }

                        Spacer(minLength: 8)

                        signOutButton
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
                }
                .refreshable {
                    await app.reloadModels()
                    if !showsDevicesInSidebar {
                        await app.refreshDevices()
                    }
                }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton()
                }
            }
        }
        .task { await app.reloadModels() }
        .task(id: showsDevicesInSidebar) {
            guard !showsDevicesInSidebar else {
                showsOfflineDevices = false
                return
            }
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

    private var signOutButton: some View {
        Button(role: .destructive) { isConfirmingSignOut = true } label: {
            Text(app.isDemoMode ? "退出体验模式" : "退出登录")
                .font(.body.weight(.medium))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
        }
        .buttonStyle(.plain)
    }

    private var showsDevicesBinding: Binding<Bool> {
        Binding(
            get: { showsDevicesInSidebar },
            set: { value in
                withAnimation(.snappy(duration: 0.28)) {
                    showsDevicesInSidebar = value
                }
            }
        )
    }

    private var webFallbackCard: some View {
        card {
            Button {
                if let url = app.webFallbackURL {
                    openURL(url)
                }
            } label: {
                HStack(spacing: 12) {
                    Text("打开Kimi Code网页版")
                        .font(.body)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        MoonIcon("mc-globe", size: 18)
                            .foregroundStyle(.secondary)
                        MoonIcon("mc-arrow-up-right", size: 13)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(minHeight: 32)
                .contentShape(.rect)
                .opacity(app.webFallbackURL == nil ? 0.4 : 1)
            }
            .buttonStyle(.plain)
            .disabled(app.webFallbackURL == nil)
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
                            MoonIcon(mode.symbolName, size: 17)
                            Text(mode.title)
                            if isSavingDefault {
                                ProgressView().controlSize(.small)
                            } else {
                                MoonIcon("mc-chevron-up-down", size: 13)
                            }
                        }
                        .font(.body)
                        .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 32)
                    .contentShape(.rect)
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
            HStack(spacing: 6) {
                Text(value)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if isSavingDefault {
                    ProgressView().controlSize(.small)
                } else {
                    MoonIcon("mc-chevron-right", size: 12)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(minHeight: 32)
        .contentShape(.rect)
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

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(.rect(cornerRadius: 22))
    }

    private var devicesCard: some View {
        card {
            VStack(spacing: 0) {
                Toggle("在会话栏中显示设备列表", isOn: showsDevicesBinding)
                    .frame(minHeight: 32)

                if !showsDevicesInSidebar {
                    VStack(spacing: 0) {
                        Divider().padding(.vertical, 6)
                        devicesContent
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    private var onlineDevices: [RemoteDevice] {
        app.devices.filter { app.isDeviceOnline($0) }
    }

    private var offlineDevices: [RemoteDevice] {
        app.devices.filter { !app.isDeviceOnline($0) }
    }

    /// 有在线设备、离线设备多于 1 台且当前设备未离线时默认折叠离线设备，
    /// 避免历史离线设备过多时把底部入口挤出屏幕。
    private var collapsesOfflineDevices: Bool {
        !onlineDevices.isEmpty
            && offlineDevices.count > 1
            && !offlineDevices.contains { $0.deviceID == app.endpoint?.deviceID }
    }

    @ViewBuilder
    private var devicesContent: some View {
        if app.devices.isEmpty {
            if app.isLoadingDevices {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取设备…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 32)
            } else {
                Text("暂无设备")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                Divider().padding(.vertical, 6)
                refreshDevicesRow
            }
        } else if collapsesOfflineDevices {
            deviceList(onlineDevices)
            Divider().padding(.vertical, 6)
            offlineDevicesToggleRow
            if showsOfflineDevices {
                VStack(spacing: 0) {
                    Divider().padding(.vertical, 6)
                    deviceList(offlineDevices)
                }
                .transition(.opacity)
            }
            Divider().padding(.vertical, 6)
            refreshDevicesRow
        } else {
            deviceList(app.devices)
            Divider().padding(.vertical, 6)
            refreshDevicesRow
        }
    }

    private func deviceList(_ list: [RemoteDevice]) -> some View {
        ForEach(Array(list.enumerated()), id: \.element.id) { index, device in
            deviceRow(device)
            if index + 1 < list.count {
                Divider()
                    .padding(.leading, 20)
                    .padding(.vertical, 6)
            }
        }
    }

    private var offlineDevicesToggleRow: some View {
        Button {
            withAnimation(.snappy(duration: 0.25)) {
                showsOfflineDevices.toggle()
            }
        } label: {
            HStack(spacing: 12) {
                Text("离线设备")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Text("\(offlineDevices.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    MoonIcon("mc-chevron-down", size: 12)
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(showsOfflineDevices ? 180 : 0))
                }
            }
            .frame(minHeight: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("离线设备，共 \(offlineDevices.count) 台")
        .accessibilityHint(showsOfflineDevices ? "收起离线设备" : "展开离线设备")
    }

    private func deviceRow(_ device: RemoteDevice) -> some View {
        let isOnline = app.isDeviceOnline(device)
        let isCurrent = device.deviceID == app.endpoint?.deviceID
        return Button {
            Task { await app.select(device) }
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(isOnline ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(device.shortName)
                    .font(.body)
                    .lineLimit(1)
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    if !isOnline {
                        Text("离线")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if isCurrent {
                        MoonIcon("mc-check", size: 16)
                            .foregroundStyle(isOnline ? Palette.kimi : .secondary)
                    }
                }
            }
            .foregroundStyle(isOnline ? .primary : .secondary)
            .frame(minHeight: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isOnline)
        .accessibilityLabel("\(device.shortName)，\(isOnline ? "在线" : "离线")")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private var refreshDevicesRow: some View {
        Button {
            Task { await app.refreshDevices() }
        } label: {
            HStack(spacing: 8) {
                if app.isLoadingDevices {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在刷新设备…")
                        .foregroundStyle(.secondary)
                } else {
                    MoonIcon("mc-refresh", size: 16)
                    Text("刷新设备")
                }
                Spacer(minLength: 0)
            }
            .font(.body)
            .foregroundStyle(Palette.kimi)
            .frame(minHeight: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(app.isLoadingDevices)
        .accessibilityLabel("刷新设备")
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
                            MoonIcon("mc-check", size: 16)
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
