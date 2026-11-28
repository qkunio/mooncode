import SwiftUI

/// 紧凑宽度使用左侧抽屉；规则宽度同时显示侧栏和聊天。
///
/// 紧凑宽度下侧栏从左边推进来，主页被推到右边、露出一截；点露出的主页或往左滑收起。
/// 窄规则宽度使用固定双栏，宽规则宽度使用系统分栏；两种布局都可以收起或恢复侧栏。
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var isSidebarOpen = false
    @State private var dragTranslation: CGFloat = 0
    @State private var isDraggingSidebar = false
    /// 两种 regular 布局共享的侧栏可见性，横竖屏跨越 720pt 阈值时保持用户选择不跳变。
    @State private var isRegularSidebarVisible = true
    @State private var isShowingUpdateNotice = false

    /// 仅在双维度均为 regular 时（如 iPhone Duo 展开内屏、iPad）启用双栏/分栏；
    /// iPhone Plus / Pro Max 横屏高度紧凑（verticalSizeClass == .compact）继续保持抽屉。
    private var usesRegularLayout: Bool {
        horizontalSizeClass == .regular && verticalSizeClass == .regular
    }

    private var isSidebarCurrentlyVisible: Bool {
        usesRegularLayout ? isRegularSidebarVisible : isSidebarOpen
    }

    private var splitColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { isRegularSidebarVisible ? .doubleColumn : .detailOnly },
            set: { isRegularSidebarVisible = ($0 != .detailOnly) }
        )
    }

    var body: some View {
        Group {
            if usesRegularLayout {
                regularLayout
            } else {
                compactLayout
            }
        }
        .onChange(of: usesRegularLayout) { _, regular in
            isSidebarOpen = false
            dragTranslation = 0
            isDraggingSidebar = false
            if regular {
                isRegularSidebarVisible = true
            }
        }
        .onChange(of: isSidebarCurrentlyVisible) { _, visible in
            if visible { Task { await model.refreshSidebar() } }
        }
        .task {
            guard !model.isDemoMode, AppUpdateNotice.shouldPresent() else { return }
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, !model.isDemoMode, AppUpdateNotice.shouldPresent() else { return }
            isShowingUpdateNotice = true
        }
        .sheet(isPresented: $isShowingUpdateNotice, onDismiss: {
            AppUpdateNotice.markPresented()
        }) {
            UpdateNoticeSheet {
                AppUpdateNotice.markPresented()
                isShowingUpdateNotice = false
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private var regularLayout: some View {
        GeometryReader { geometry in
            Group {
                if geometry.size.width < 720 {
                    narrowRegularLayout(width: geometry.size.width)
                } else {
                    splitRegularLayout
                }
            }
        }
    }

    private func narrowRegularLayout(width: CGFloat) -> some View {
        let sidebarWidth = min(min(max(width * 0.36, 220), 260), width)
        let detailWidth = max(0, isRegularSidebarVisible ? width - sidebarWidth : width)
        return HStack(spacing: 0) {
            if isRegularSidebarVisible {
                SidebarView(close: {}, isVisible: true, showsCloseButton: false, isPersistent: true)
                    .frame(width: sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: .trailing) { Divider() }
                    .transition(.move(edge: .leading))
            }

            chatNavigation(
                showsSidebarToggle: true,
                isSidebarVisible: isRegularSidebarVisible,
                isAccessibilityHidden: false,
                toggleSidebar: toggleNarrowSidebar
            )
            .frame(width: detailWidth)
            .frame(maxHeight: .infinity)
            .clipped()
        }
    }

    private var splitRegularLayout: some View {
        NavigationSplitView(columnVisibility: splitColumnVisibility) {
            SidebarView(close: {}, isVisible: isRegularSidebarVisible, showsCloseButton: false, isPersistent: true)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            chatNavigation(
                showsSidebarToggle: false,
                isSidebarVisible: isRegularSidebarVisible,
                isAccessibilityHidden: false,
                toggleSidebar: {}
            )
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var compactLayout: some View {
        GeometryReader { geometry in
            let sidebarWidth = min(geometry.size.width * 0.84, 380)
            // 坐标从安全区左边算起。横屏时刘海 / 灵动岛在左边，安全区左边有一截（约 60pt）：
            // 收起的侧栏只挪开自身宽度的话，最右边那截会停在这里露出来，所以还得再多挪这么多。
            let leadingInset = geometry.safeAreaInsets.leading
            let progress = openProgress(sidebarWidth: sidebarWidth)

            ZStack(alignment: .leading) {
                chatNavigation(
                    showsSidebarToggle: true,
                    isSidebarVisible: false,
                    isAccessibilityHidden: isSidebarOpen,
                    toggleSidebar: { setSidebar(open: true, feedback: true) }
                )
                .offset(x: progress * sidebarWidth)
                // NavigationStack 底层是 UIKit，`.offset` 只挪了画面，触摸仍按原位置命中 ——
                // 抽屉开着时它底部的 composer 会抢走侧栏底部那一行的点击。所以开着时整页不接收触摸。
                .allowsHitTesting(!isSidebarOpen)

                // 露出的那截主页：变暗 + 点一下收起。
                // 常驻而不是 `if` 插入：条件插入的视图在过渡中会被画到后面兄弟视图之上，
                // 结果侧栏自己的按钮（退出登录等）点下去全落到这层，侧栏被收起。
                Color.black
                    .opacity(0.18 * progress)
                    .ignoresSafeArea()
                    .contentShape(.rect)
                    .onTapGesture { setSidebar(open: false, feedback: true) }
                    .allowsHitTesting(isSidebarOpen)
                    .accessibilityElement()
                    .accessibilityLabel("关闭侧栏")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHidden(!isSidebarOpen)
                    .zIndex(1)

                SidebarView(
                    close: { setSidebar(open: false) },
                    isVisible: isSidebarOpen,
                    showsCloseButton: true,
                    isPersistent: false
                )
                .frame(width: sidebarWidth)
                .offset(x: (progress - 1) * (sidebarWidth + leadingInset))
                .allowsHitTesting(isSidebarOpen)
                .accessibilityAddTraits(isSidebarOpen ? .isModal : [])
                .accessibilityHidden(!isSidebarOpen)
                .zIndex(2)
            }
            .scrollDisabled(isDraggingSidebar)
            .gesture(SidebarPanGesture(
                isOpen: isSidebarOpen,
                onChanged: { translation in
                    isDraggingSidebar = true
                    dragTranslation = translation
                },
                onEnded: { translation, velocity in
                    let projectedOffset = (isSidebarOpen ? sidebarWidth : 0)
                        + translation + velocity * 0.2
                    setSidebar(open: projectedOffset > sidebarWidth / 2, feedback: true)
                },
                onCancelled: { setSidebar(open: isSidebarOpen) }
            ))
        }
    }

    private func chatNavigation(
        showsSidebarToggle: Bool,
        isSidebarVisible: Bool,
        isAccessibilityHidden: Bool,
        toggleSidebar: @escaping () -> Void
    ) -> some View {
        NavigationStack {
            ChatScreen(
                showsSidebarToggle: showsSidebarToggle,
                isSidebarVisible: isSidebarVisible,
                isAccessibilityHidden: isAccessibilityHidden,
                toggleSidebar: toggleSidebar
            )
        }
    }

    private func toggleNarrowSidebar() {
        withAnimation(.smooth(duration: 0.25)) {
            isRegularSidebarVisible.toggle()
        }
    }

    private func openProgress(sidebarWidth: CGFloat) -> CGFloat {
        let base: CGFloat = isSidebarOpen ? 1 : 0
        return min(max(base + dragTranslation / sidebarWidth, 0), 1)
    }

    private func setSidebar(open: Bool, feedback: Bool = false) {
        if feedback { UIImpactFeedbackGenerator(style: .soft).impactOccurred() }
        if open { hideKeyboard() }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
            isSidebarOpen = open
            dragTranslation = 0
            isDraggingSidebar = false
        }
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

/// 在识别开始前决定方向；一旦横向手势胜出，就独占本次触摸直到抬手。
private struct SidebarPanGesture: UIGestureRecognizerRepresentable {
    var isOpen: Bool
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat, CGFloat) -> Void
    var onCancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(isOpen: isOpen)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = true
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.isOpen = isOpen
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        // 使用固定的 window 坐标，避免侧栏跟手移动影响位移计算。
        let translation = recognizer.translation(in: recognizer.view?.window).x
        switch recognizer.state {
        case .began, .changed:
            onChanged(translation)
        case .ended:
            onEnded(translation, recognizer.velocity(in: recognizer.view?.window).x)
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isOpen: Bool
        /// 本次触摸落在的视图，用来判断手指下面有没有能横向滚动的内容（代码块、表格、diff）。
        private weak var touchedView: UIView?

        init(isOpen: Bool) { self.isOpen = isOpen }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var current = touch.view
            while let view = current {
                if view.accessibilityIdentifier == DeviceStrip.scrollAccessibilityIdentifier {
                    touchedView = nil
                    return false
                }
                current = view.superview
            }
            touchedView = touch.view
            return true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view?.window)
            // 只在开始时判一次方向，后续手指上下偏移不会切回滚动。
            guard abs(velocity.x) > abs(velocity.y) * 1.5, isOpen || velocity.x > 0 else { return false }
            // 正文里正在选字：横着拖多半是在拖选区手柄，不开侧栏。
            if SelectableTextView.isSelecting { return false }
            // 横向可滚的内容优先自己滚；已经滚到最左还往右滑，才交给侧栏。
            if let scrollView = horizontalScrollView(from: touchedView) {
                let atLeadingEdge = scrollView.contentOffset.x <= -scrollView.adjustedContentInset.left + 1
                return velocity.x > 0 && atLeadingEdge
            }
            return true
        }

        private func horizontalScrollView(from view: UIView?) -> UIScrollView? {
            var current = view
            while let candidate = current {
                if let scrollView = candidate as? UIScrollView, scrollView.isScrollEnabled {
                    let insets = scrollView.adjustedContentInset
                    if scrollView.contentSize.width + insets.left + insets.right > scrollView.bounds.width + 1 {
                        return scrollView
                    }
                }
                current = candidate.superview
            }
            return nil
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            false
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // 列表滚动先等方向判断；纵向会立即失败放行，横向则取消列表滚动。
            otherGestureRecognizer is UIPanGestureRecognizer
        }
    }
}
