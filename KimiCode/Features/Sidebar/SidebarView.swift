import SwiftUI

/// 侧栏：Moon Code（可显示横排设备）、添加文件夹、会话列表，底部是个人入口。
/// 个人面板里管理默认模型 / 强度 / 权限、设备显示偏好和退出登录。

struct SidebarView: View {
    let close: () -> Void
    let isVisible: Bool

    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("kimi.showsDevicesInSidebar") private var showsDevicesInSidebar = true
    @State private var collapsed: Set<String> = []
    @State private var isAddingWorkspace = false
    @State private var isShowingAccount = false
    @State private var renaming: SessionSummary?
    @State private var renameText = ""
    @State private var deleting: SessionSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 8)

            if showsDevicesInSidebar {
                DeviceStrip()
                    .padding(.top, 14)
            }

            addFolderRow
                .padding(.horizontal, 20)
                .padding(.top, 14)

            folderList
                // 和主页 composer 一样用 safeAreaBar：列表滚到卡片后面时渐隐模糊。
                .safeAreaBar(edge: .bottom, spacing: 0) {
                    accountCard
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
        }
        .background(
            Color(colorScheme == .dark ? .secondarySystemBackground : .systemGroupedBackground)
        )
        .sheet(isPresented: $isAddingWorkspace) {
            if let client = app.client {
                AddWorkspaceSheet(client: client) { root in
                    try await app.addWorkspace(root: root)
                    // 已在新项目里开好新对话，收起侧栏直接进去。
                    close()
                }
                .presentationDetents([.large])
            }
        }
        // 长按会话：重命名 / 删除对话。
        .alert("重命名", isPresented: .init(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { session in
            TextField("会话名称", text: $renameText)
            Button("取消", role: .cancel) {}
            Button("确定") { Task { await app.rename(session, to: renameText) } }
        }
        .alert("删除会话", isPresented: .init(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { session in
            Button("取消", role: .cancel) {}
            Button("永久删除", role: .destructive) { Task { await app.delete(session) } }
        } message: { session in
            Text("将永久删除「\(session.displayTitle)」的全部对话记录，无法恢复。工作区里的文件和代码改动不受影响。")
        }
        .sheet(isPresented: $isShowingAccount) {
            AccountSheet(showsDevicesInSidebar: $showsDevicesInSidebar)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .task(id: isVisible && showsDevicesInSidebar) {
            guard isVisible && showsDevicesInSidebar else { return }
            await app.refreshDevices(silent: true)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                await app.refreshDevices(silent: true)
            }
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 10) {
            KimiFace(animating: false)
                .scaleEffect(1.25)
                .frame(width: 30, height: 20)
            (Text("Moon").foregroundStyle(Palette.kimi) + Text(" Code"))
                .font(.system(.title2, weight: .black))
        }
        .frame(height: 44)
    }

    // MARK: 底部账号

    private var accountCard: some View {
        Button { isShowingAccount = true } label: {
            HStack(spacing: 12) {
                Avatar(url: app.user?.avatarURL)
                Text(app.user?.displayName ?? "Kimi 用户")
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("账号")
        .glassEffect(in: .capsule)
    }

    /// 选一个电脑上的文件夹加成工作区（官方网页端「添加工作区」）。样式与下面的文件夹行一致。
    private var addFolderRow: some View {
        Button {
            isAddingWorkspace = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 20, weight: .regular))
                    .frame(width: 24)
                Text("添加文件夹")
                    .font(.body)
                Spacer(minLength: 4)
            }
            .foregroundStyle(.primary)
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(app.client == nil)
    }

    // MARK: 文件夹 / 会话

    private var folderList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(app.workspaces) { workspace in
                    folderRow(workspace)
                    if !collapsed.contains(workspace.id) {
                        ForEach(app.sessions(in: workspace)) { session in
                            sessionRow(session)
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 16)
        }
        .refreshable {
            if !showsDevicesInSidebar { await app.refreshDevices() }
            await app.refreshSidebar()
        }
    }

    private func toggle(_ id: String) {
        withAnimation(.snappy) {
            if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
        }
    }

    private func folderRow(_ workspace: Workspace) -> some View {
        HStack(spacing: 8) {
            Button {
                toggle(workspace.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 20, weight: .regular))
                        .frame(width: 24)
                    Text(workspace.displayName)
                        .font(.body)
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(collapsed.contains(workspace.id) ? "展开会话" : "收起会话")

            Button {
                app.newChat(in: workspace)
                close()
            } label: {
                Image(systemName: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("在 \(workspace.displayName) 新建会话")
        }
        .padding(.leading, 14)
        .padding(.top, 12)
        .frame(minHeight: 52)
    }

    private func sessionRow(_ session: SessionSummary) -> some View {
        let isCurrent = session.id == app.chat?.sessionID
        return Button {
            app.open(session)
            close()
        } label: {
            HStack(spacing: 8) {
                Text(session.displayTitle)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if session.pendingInteraction != .none || session.busy {
                    SessionStateDot(session: session)
                }
            }
            .padding(.leading, 50)
            .padding(.trailing, 14)
            .frame(minHeight: 48)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(isCurrent ? Color(.tertiarySystemFill) : .clear)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .contextMenu {
            Button {
                renameText = session.displayTitle
                renaming = session
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button(role: .destructive) {
                deleting = session
            } label: {
                Label("删除对话", systemImage: "trash")
            }
        }
    }

}

/// 会话尾部的活动状态：执行中转圈，待确认/回答时显示橙色标记。
private struct SessionStateDot: View {
    let session: SessionSummary

    var body: some View {
        Group {
            if session.pendingInteraction != .none {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            } else if session.busy {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .frame(width: 16)
    }
}

// MARK: - 头像

struct Avatar: View {
    let url: URL?
    var size: CGFloat = 36

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .accessibilityHidden(true)
    }
}
