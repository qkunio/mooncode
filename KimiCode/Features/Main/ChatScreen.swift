import SwiftUI

/// 主页：左上角开侧栏，中间是对话，底部 composer。
struct ChatScreen: View {
    let openSidebar: () -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var isAddingWorkspace = false
    @State private var confirmedEmptyDeviceID: String?
    /// 加载中的小脸与对话页欢迎语里的小脸是同一个：数据到了就从这里滑到对话页的位置。
    @Namespace private var face
    @State private var isBootFaceShown = false

    /// 还在拉设备 / 设备数据：中间只放 Kimi 小脸，其他界面等数据到了再出来。
    private var isBooting: Bool {
        if !app.hasLoadedDevices || app.isLoadingDevices { return true }
        return !app.onlineDevices.isEmpty && app.chat == nil && confirmedEmptyDeviceID == nil && !app.isCompatibilityError
    }

    private var emptyWorkspaceDeviceID: String? {
        guard app.hasLoadedDevices, !app.isLoadingDevices,
              !app.onlineDevices.isEmpty, app.chat == nil,
              app.workspaces.isEmpty else { return nil }
        return app.endpoint?.deviceID
    }

    var body: some View {
        Group {
            if let chat = app.chat {
                ChatContent(chat: chat, face: face, initialDraft: app.composerDraft(for: chat))
                    .id(chat.sessionID ?? "draft:\(chat.workspace?.id ?? "")")
                    .transition(.opacity)
            } else {
                placeholder
            }
        }
        .animation(.smooth(duration: 0.5), value: app.chat == nil)
        // 顶部不显示会话标题。
        .navigationBarTitleDisplayMode(.inline)
        .attachmentImageGallery()
        .task(id: emptyWorkspaceDeviceID) {
            confirmedEmptyDeviceID = nil
            guard let deviceID = emptyWorkspaceDeviceID else { return }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard !Task.isCancelled, emptyWorkspaceDeviceID == deviceID else { return }
            confirmedEmptyDeviceID = deviceID
        }
        .sheet(isPresented: $isAddingWorkspace) {
            if let client = app.client {
                AddWorkspaceSheet(client: client) { root in
                    try await app.addWorkspace(root: root)
                }
                .presentationDetents([.large])
            }
        }
        .alert(
            app.isCompatibilityError ? "版本暂未兼容" : "出错了",
            isPresented: .init(
                get: { app.errorMessage != nil },
                set: { if !$0 { app.clearError() } }
            )
        ) {
            if app.isCompatibilityError, let url = app.webFallbackURL {
                Button("使用网页版") {
                    app.clearError()
                    openURL(url)
                }
                Button("好", role: .cancel) { app.clearError() }
            } else {
                Button("好") { app.clearError() }
            }
        } message: {
            Text(app.errorMessage ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: openSidebar) {
                    Label("打开侧栏", systemImage: "line.3.horizontal")
                }
            }
            if let chat = app.chat {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    SessionInfoButton(chat: chat)
                    FilesButton(
                        client: app.client,
                        sessionID: chat.sessionID ?? chat.workspace.flatMap { app.sessions(in: $0).first?.id },
                        title: chat.workspace?.displayName ?? "文件"
                    ) { entry in
                        chat.addMention(entry)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if isBooting {
            // 欢迎语的位置先空着；底部让出大约一个输入框的高度，小脸和对话页里的落点基本一致。
            WelcomeHero(face: face) { Text(verbatim: " ") }
                .safeAreaPadding(.bottom, 96)
                .scaleEffect(isBootFaceShown ? 1 : 0.6)
                .opacity(isBootFaceShown ? 1 : 0)
                .onAppear {
                    withAnimation(.spring(duration: 0.6, bounce: 0.3)) { isBootFaceShown = true }
                }
                .allowsHitTesting(false)
        } else if app.isCompatibilityError {
            ContentUnavailableView {
                Label("版本暂未兼容", systemImage: "exclamationmark.triangle")
            } description: {
                Text(KapError.protocolMismatchMessage)
            } actions: {
                HStack(spacing: 12) {
                    if let url = app.webFallbackURL {
                        Button("使用网页版") {
                            openURL(url)
                        }
                        .buttonStyle(.glassProminent)
                    }
                    Button("重试") {
                        Task { await app.refreshDeviceData() }
                    }
                    .buttonStyle(.glass)
                }
            }
        } else if app.onlineDevices.isEmpty {
            ContentUnavailableView {
                Label("没有在线的设备", systemImage: "laptopcomputer.slash")
            } description: {
                Text("在电脑上运行 `kimi rc`，它就会出现在这里。")
            } actions: {
                Button("刷新") {
                    Task { await app.bootstrap() }
                }
                .buttonStyle(.glass)
            }
        } else if let deviceID = emptyWorkspaceDeviceID, confirmedEmptyDeviceID == deviceID {
            // 电脑上一个文件夹都没有：先引导添加，加完 AppModel 会自动开一个新对话。
            WelcomeHero {
                HStack(spacing: 0) {
                    Button {
                        isAddingWorkspace = true
                    } label: {
                        // 系统下划线贴字太紧，自己画一条往下挪 4pt。
                        Text("打开文件夹")
                            .overlay(alignment: .bottom) {
                                Rectangle().frame(height: 1.5).offset(y: 4)
                            }
                    }
                    .buttonStyle(.plain)
                    Text("，我们开始创造吧")
                }
            }
            // 这一页没有输入框，按整块屏幕居中，不算顶部栏。
            .ignoresSafeArea()
        } else {
            Color.clear
        }
    }
}

/// 空白对话中间的欢迎：会动的 Kimi 小脸 + 一句话。
struct WelcomeHero<Message: View>: View {
    /// 传入时小脸和加载中的那个做位置衔接。
    var face: Namespace.ID? = nil
    @ViewBuilder var message: Message

    @Namespace private var ownFace

    var body: some View {
        VStack(spacing: 28) {
            KimiFace(animating: true)
                .scaleEffect(3)
                .frame(width: 72, height: 48)
                .matchedGeometryEffect(id: "kimiFace", in: face ?? ownFace)
            message
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                // 按屏幕宽度排版（overlay 里给的宽度不可靠，会被挤成一列）。
                .containerRelativeFrame(.horizontal) { width, _ in width - 48 }
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 一条对话的正文 + composer。
private struct ChatContent: View {
    let chat: ChatModel
    let face: Namespace.ID

    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 输入框的字。切对话时这个视图整个重建，所以每次改动都存进 `AppModel`，回来时从那里取。
    @State private var draft: String
    /// 点了对话里的文件提及，正在预览的文件。
    @State private var previewingFile: FsEntry?
    @State private var ui = TranscriptUIState()
    @State private var undoTarget: UserEntry?
    /// 停在底部时新内容自动跟随（官方 isFollowing）；往上翻了就不打扰。
    @State private var isFollowing = true
    @State private var isUserInteracting = false
    /// 首屏历史到了才显示正文，并且只淡入透明度：布局先一次排好，文字不会跟着滑。
    @State private var isRevealed: Bool
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var lastAutoScrollAt: CFTimeInterval = 0
    @State private var pendingScrollTask: Task<Void, Never>?

    private struct ScrollFollowMetrics: Equatable {
        let contentHeight: CGFloat
        let bottomInset: CGFloat
        let isScrollable: Bool
    }

    init(chat: ChatModel, face: Namespace.ID, initialDraft: String) {
        self.chat = chat
        self.face = face
        _draft = State(initialValue: initialDraft)
        _isRevealed = State(initialValue: !Self.isAwaitingHistory(chat))
    }

    /// 已有会话、正文还是空的：首屏历史还没到（ChatModel 刚建好时 isLoading 还没置上，不能靠它）。
    private static func isAwaitingHistory(_ chat: ChatModel) -> Bool {
        !chat.isDraft && chat.entries.isEmpty && chat.optimisticPrompts.isEmpty
    }

    var body: some View {
        Group {
            ScrollView {
                // 不用 LazyVStack：高度差异大时它估不准，滚到底会落在空白里。
                // 一页只有 30 轮、折叠的部分本来就不渲染，普通 VStack 足够。
                VStack(alignment: .leading, spacing: 0) {
                    if chat.isRefreshingStale || (chat.isLoading && chat.entries.isEmpty) {
                        ChatSkeleton()
                    }

                    // 后台久了回来重拉期间整个撤掉旧正文：内容只剩骨架那么高，视口自然落在顶部看得见它。
                    if !chat.isRefreshingStale {
                        ConversationList(chat: chat, ui: ui) { entry in
                            undoTarget = entry
                        }
                        .opacity(isRevealed ? 1 : 0)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .overlay {
                // 新对话还没发任何东西：中间放欢迎语。
                if chat.isDraft, chat.entries.isEmpty, chat.optimisticPrompts.isEmpty {
                    WelcomeHero(face: face) {
                        Text("你来啦，在\(chat.workspace?.displayName ?? "这里")里开始创造吧")
                    }
                    .allowsHitTesting(false)
                }
            }
            .scrollPosition($scrollPosition)
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            // 由真实排版后的内容高度与底部 inset 驱动自动跟随：
            // 仅在折出新行、新块出现或键盘弹出时触发，彻底消除按 token 排队的双倍 GCD 滚动风暴。
            .onScrollGeometryChange(for: ScrollFollowMetrics.self) { geometry in
                let contentHeight = ceil(geometry.contentSize.height)
                let bottomInset = ceil(geometry.contentInsets.bottom)
                let scrollable = contentHeight + geometry.contentInsets.top + bottomInset > geometry.containerSize.height + 1
                return ScrollFollowMetrics(contentHeight: contentHeight, bottomInset: bottomInset, isScrollable: scrollable)
            } action: { old, new in
                guard isFollowing, !isUserInteracting, new.isScrollable else { return }
                if new.bottomInset > old.bottomInset {
                    // 键盘或确认卡片弹出：同一布局事务内同步贴底，和键盘动画齐步走。
                    scrollPosition.scrollTo(edge: .bottom)
                } else if new.contentHeight > old.contentHeight {
                    followContentGrowth(delta: new.contentHeight - old.contentHeight)
                }
            }
            .onScrollPhaseChange { _, phase, context in
                switch phase {
                case .interacting:
                    // 手指一放上去就停止跟随并取消待执行的滚底，绝不和用户抢手势。
                    isUserInteracting = true
                    isFollowing = false
                    pendingScrollTask?.cancel()
                    pendingScrollTask = nil
                case .idle:
                    isUserInteracting = false
                    // 滑完停在底部附近才恢复跟随。visibleRect 是整个视口、含 composer 盖住的那截，
                    // 贴底时 maxY = 内容高 + 底部 inset；不减掉 inset，往上翻 200 多点松手也会被拽回去。
                    let geometry = context.geometry
                    let bottom = geometry.contentSize.height + geometry.contentInsets.bottom
                    isFollowing = geometry.visibleRect.maxY >= bottom - 80
                default:
                    break
                }
            }
            .contentShape(.rect)
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .global).onEnded { tap in
                    guard !SelectableTextView.ownsTap(atGlobal: tap.location) else { return }
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil, from: nil, for: nil
                    )
                }
            )
            .onChange(of: Self.isAwaitingHistory(chat)) { _, waiting in
                guard !waiting, !isRevealed else { return }
                scrollToBottom(animated: false)
                withAnimation(.easeOut(duration: 0.3)) { isRevealed = true }
            }
            // 后台久了回来：骨架期间藏起正文，重拉完贴底、淡入，和打开会话首屏一样。
            .onChange(of: chat.isRefreshingStale) { _, stale in
                if stale {
                    isRevealed = false
                } else {
                    isFollowing = true
                    scrollToBottom(animated: false)
                    withAnimation(.easeOut(duration: 0.3)) { isRevealed = true }
                }
            }
            // 一轮结束时「工作中」那行换成页脚，高度会变，再贴一次底。
            .onChange(of: chat.isWorking) {
                if isFollowing { scrollToBottom(animated: true) }
            }
            .onChange(of: chat.optimisticPrompts.count) { old, new in
                // 自己刚发出一条：不管停在哪都回到底部看它。
                guard new > old else { return }
                isFollowing = true
                scrollToBottom(animated: true)
            }
            .onDisappear {
                pendingScrollTask?.cancel()
                pendingScrollTask = nil
            }
        }
        // 用 safeAreaBar 而不是 safeAreaInset：只有前者参与 iOS 26 的滚动边缘效果，
        // 正文滚到 composer 后面时会像导航栏那样渐隐模糊。
        .safeAreaBar(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                ForEach(chat.pendingQuestions) { question in
                    QuestionCard(request: question) { answers in
                        Task { await chat.answer(question, answers: answers) }
                    } dismiss: {
                        Task { await chat.dismiss(question) }
                    }
                }
                ForEach(chat.pendingApprovals) { approval in
                    ApprovalCard(approval: approval) { decision in
                        Task { await chat.resolve(approval, decision: decision) }
                    }
                }
                // 等你确认 / 回答时只留卡片，输入框先收起来（草稿还在）。
                if !isAwaitingInteraction {
                    ComposerView(chat: chat, draft: $draft)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .onChange(of: draft) { _, text in app.setComposerDraft(text, for: chat) }
        }
        .alert(
            chat.isCompatibilityError ? "版本暂未兼容" : "出错了",
            isPresented: .init(
                get: { chat.errorMessage != nil },
                set: { if !$0 { chat.clearError() } }
            )
        ) {
            if chat.isCompatibilityError, let url = app.webFallbackURL {
                Button("使用网页版") {
                    chat.clearError()
                    openURL(url)
                }
                Button("好", role: .cancel) { chat.clearError() }
            } else {
                Button("好") { chat.clearError() }
            }
        } message: {
            Text(chat.errorMessage ?? "")
        }
        // 官方撤销前的确认框。
        .alert(
            "撤销",
            isPresented: .init(get: { undoTarget != nil }, set: { if !$0 { undoTarget = nil } }),
            presenting: undoTarget
        ) { entry in
            Button("取消", role: .cancel) {}
            Button("撤销") { Task { await chat.undo(entry) } }
        } message: { _ in
            Text("撤销后，这条消息及之后的会话内容会从上下文中移除，这条消息的原文会放回输入框；已修改的文件和代码不受影响。")
        }
        .onChange(of: isAwaitingInteraction) { _, awaiting in
            guard awaiting else { return }
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
        .onChange(of: chat.restoredDraft) { _, text in
            guard let text else { return }
            draft = text
            chat.restoredDraft = nil
        }
        .refreshable { await chat.reload() }
        .environment(\.addToComposer) { text in
            draft += text + " "
        }
        .environment(\.openFilePreview) { entry in
            if fileSessionID != nil { previewingFile = entry }
        }
        .sheet(item: $previewingFile) { entry in
            if let client = app.client, let sessionID = fileSessionID {
                FilePreviewSheet(client: client, sessionID: sessionID, entry: entry)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    /// 读文件用的会话：和右上角 📁 一样，草稿借同文件夹里最近的会话。没有客户端或会话就是 nil。
    private var fileSessionID: String? {
        guard app.client != nil else { return nil }
        return chat.sessionID ?? chat.workspace.flatMap { app.sessions(in: $0).first?.id }
    }

    private var isAwaitingInteraction: Bool {
        !chat.pendingApprovals.isEmpty || !chat.pendingQuestions.isEmpty
    }

    /// 内容因流式输出长高时顺滑跟随：
    /// 正常阅读节奏（单次增高 1~4 行且间隔 ≥ 140ms）用短缓动轻柔滑动；
    /// 高速突发或首屏尚未显现时直接贴底，避免动画频繁重置导致顿挫。
    private func followContentGrowth(delta: CGFloat) {
        let now = ProcessInfo.processInfo.systemUptime
        let shouldAnimate = isRevealed && !reduceMotion && delta <= 160 && (now - lastAutoScrollAt) >= 0.14
        lastAutoScrollAt = now
        if shouldAnimate {
            withAnimation(.easeOut(duration: 0.16)) {
                scrollPosition.scrollTo(edge: .bottom)
            }
        } else {
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    /// 显式滚底（发送新消息、轮次结束、重拉完成）：可取消单任务，避免堆积过期回调。
    private func scrollToBottom(animated: Bool = true) {
        pendingScrollTask?.cancel()
        pendingScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, isFollowing, !isUserInteracting else { return }
            if animated && !reduceMotion {
                withAnimation(.easeOut(duration: 0.2)) { scrollPosition.scrollTo(edge: .bottom) }
            } else {
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
    }
}

/// 打开已有会话首屏加载时的骨架屏：一条右对齐的用户气泡 + 几行助手正文，灰色占位条轻轻呼吸。
private struct ChatSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 用户气泡（胶囊）。
            SkeletonBar(height: 36)
                .containerRelativeFrame(.horizontal) { width, _ in min(width * 0.275, 110) }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.vertical, 10)
            // 助手正文三行。
            VStack(alignment: .leading, spacing: 12) {
                SkeletonBar(height: 15, fill: Color(.systemGray6))
                SkeletonBar(height: 15, fill: Color(.systemGray6))
                    .containerRelativeFrame(.horizontal) { width, _ in width * 0.8 }
                SkeletonBar(height: 15, fill: Color(.systemGray6))
                    .containerRelativeFrame(.horizontal) { width, _ in width * 0.45 }
            }
            .padding(.vertical, 10)
        }
        .phaseAnimator([1.0, 0.45]) { content, opacity in
            content.opacity(opacity)
        } animation: { _ in
            .easeInOut(duration: 0.8)
        }
        .accessibilityHidden(true)
    }
}

/// 一根灰色圆角占位条，默认铺满给它的宽度。
private struct SkeletonBar: View {
    var height: CGFloat
    var fill: Color = Color(.systemGray5)

    var body: some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(fill)
            .frame(maxWidth: .infinity)
            .frame(height: height)
    }
}
