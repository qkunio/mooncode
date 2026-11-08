import Photos
import QuickLook
import SwiftUI
import UIKit

/// 点开一个文件直接加载预览；右上角 ⋯ 菜单：下载（系统分享面板）、保存到相册（图片）、添加到会话。
struct FilePreviewView: View {
    let client: any KapServicing
    let sessionID: String
    let entry: FsEntry
    /// 把这个文件加到输入框（并收起文件栏）。从对话里点开时不给，菜单里就没有这一项。
    var addToChat: (() -> Void)?

    @State private var phase: Phase = .loading
    @State private var showsMarkdownSource = false
    /// 进页面就是 1（立刻加载）；每点一次「重试」加一，驱动 `.task(id:)`，离开页面时随视图一起取消。
    @State private var previewRequest = 1
    /// 菜单里点下载 / 保存到相册：记下动作、计数加一，驱动 `.task(id:)`。
    @State private var pendingAction: FileAction?
    @State private var actionRequest = 0
    @State private var isWorking = false
    @State private var shareFile: SharedFile?
    @State private var actionError: ActionError?
    @State private var toast: String?
    /// 这一页落到沙盒里的所有临时文件，离开时一起删。
    @State private var downloadedFiles: [URL] = []

    /// `fs:read` 对超过 10 MiB 的文件整体拒绝（41302，与 offset 无关），而下载接口又用不了（见 `KapClient.downloadFile`）。
    private static let transferLimit = 10 * 1024 * 1024

    private enum Phase {
        case loading
        case tooLarge
        case text(FsContent)
        case quickLook(URL)
        case unsupported
        case failed(String)
    }

    private enum FileAction {
        case download, saveToPhotos
    }

    private struct ActionError {
        let title: String
        let message: String
    }

    private struct SharedFile: Identifiable {
        let url: URL
        var id: URL { url }
    }

    var body: some View {
        content
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if isWorking {
                        ProgressView()
                    } else {
                        menu
                    }
                }
            }
            .task(id: previewRequest) {
                await loadPreview()
            }
            .task(id: actionRequest) {
                guard let action = pendingAction else { return }
                pendingAction = nil
                await perform(action)
            }
            .sheet(item: $shareFile) { file in
                ShareSheet(url: file.url)
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
            }
            .alert(
                actionError?.title ?? "",
                isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
            ) {
                Button("好", role: .cancel) {}
            } message: {
                Text(actionError?.message ?? "")
            }
            .overlay(alignment: .bottom) {
                if let toast {
                    Label(toast, systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .glassEffect()
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: toast)
            .task(id: toast) {
                guard toast != nil else { return }
                try? await Task.sleep(for: .seconds(1.5))
                toast = nil
            }
            .onDisappear {
                downloadedFiles.forEach(PreviewStorage.remove)
                downloadedFiles = []
            }
    }

    private var menu: some View {
        Menu {
            if case let .text(file) = phase, isMarkdown(file) {
                Button(
                    showsMarkdownSource ? "查看渲染结果" : "查看源码",
                    systemImage: showsMarkdownSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right"
                ) {
                    showsMarkdownSource.toggle()
                }
            }
            Button("下载", systemImage: "arrow.down.circle") { run(.download) }
                .disabled(isTooLarge)
            if isImage {
                Button("保存到相册", systemImage: "photo.badge.arrow.down") { run(.saveToPhotos) }
                    .disabled(isTooLarge)
            }
            if let addToChat {
                Button("添加到会话", systemImage: "plus.bubble", action: addToChat)
            }
        } label: {
            Label("更多", systemImage: "ellipsis")
        }
    }

    private func run(_ action: FileAction) {
        pendingAction = action
        actionRequest += 1
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .tooLarge:
            ContentUnavailableView(
                "无法预览此文件",
                systemImage: "exclamationmark.triangle",
                description: Text(Self.tooLargeMessage)
            )
        case let .text(file):
            if file.content.isEmpty, !file.truncated {
                ContentUnavailableView("空文件", systemImage: "doc")
            } else {
                textView(file)
            }
        case let .quickLook(url):
            QuickLookFile(url: url)
        case .unsupported:
            ContentUnavailableView(
                "暂不支持预览此类型",
                systemImage: "doc",
                description: Text("可以从右上角菜单下载，用其他 App 打开。")
            )
        case let .failed(message):
            ContentUnavailableView {
                Label("无法预览此文件", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { previewRequest += 1 }
                    .buttonStyle(.glass)
            }
        }
    }

    private var isTooLarge: Bool {
        (entry.size ?? 0) > Self.transferLimit
    }

    // MARK: 预览

    private func isMarkdown(_ file: FsContent) -> Bool {
        let extensions = ["md", "markdown", "mdown", "mkd", "mkdn"]
        if extensions.contains((entry.name as NSString).pathExtension.lowercased()) { return true }
        return [entry.mime, file.mime].compactMap { $0 }.contains { mime in
            let type = mime.split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return type == "text/markdown" || type == "text/x-markdown"
        }
    }

    private func textView(_ file: FsContent) -> some View {
        VStack(spacing: 0) {
            if file.truncated {
                Label(
                    "仅显示开头部分，完整文件共 \(Int64(file.size).formatted(.byteCount(style: .file)))",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.fill)
            }
            if isMarkdown(file), !showsMarkdownSource {
                ScrollView {
                    MarkdownText(text: file.content)
                        .padding(16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CodeTextView(text: file.content)
            }
        }
    }

    private func loadPreview() async {
        guard !isTooLarge else {
            phase = .tooLarge
            return
        }
        phase = .loading
        do {
            if shouldDownloadDirectly {
                try await showDownloadedFile()
                return
            }
            let file = try await client.readFile(sessionID, path: entry.path)
            try Task.checkCancellation()
            if shouldDownload(file) {
                try await showDownloadedFile()
            } else {
                phase = .text(file)
            }
        } catch let KapError.api(code, _) where code == KapErrorCode.fileTooLarge {
            // 列表没给大小时，靠服务端拒绝才知道太大。
            phase = .tooLarge
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(Self.message(for: error))
        }
    }

    private var shouldDownloadDirectly: Bool {
        entry.isBinary == true || isMedia(entry.mime)
    }

    private func shouldDownload(_ file: FsContent) -> Bool {
        file.isBinary || file.encoding == "base64" || isMedia(file.mime)
    }

    private func isMedia(_ mime: String?) -> Bool {
        guard let mime else { return false }
        return mime == "application/pdf"
            || mime.hasPrefix("image/")
            || mime.hasPrefix("video/")
            || mime.hasPrefix("audio/")
    }

    private func showDownloadedFile() async throws {
        let url = try await fetchFile()
        guard QLPreviewController.canPreview(url as NSURL) else {
            phase = .unsupported
            return
        }
        phase = .quickLook(url)
    }

    // MARK: 下载 / 保存到相册

    /// 相册认的图片格式（SVG 等矢量图存不进去）。
    private var isImage: Bool {
        if let mime = entry.mime, mime.hasPrefix("image/"), mime != "image/svg+xml" { return true }
        let ext = (entry.name as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff"].contains(ext)
    }

    private func perform(_ action: FileAction) async {
        isWorking = true
        defer { isWorking = false }
        do {
            // 预览时已经下过就直接用。
            let url: URL
            if case let .quickLook(existing) = phase {
                url = existing
            } else {
                url = try await fetchFile()
            }
            switch action {
            case .download:
                shareFile = SharedFile(url: url)
            case .saveToPhotos:
                try await saveToPhotos(url)
                toast = "已保存到相册"
            }
        } catch {
            guard !Task.isCancelled else { return }
            switch action {
            case .download:
                actionError = ActionError(title: "下载失败", message: Self.message(for: error))
            case .saveToPhotos:
                actionError = ActionError(title: "保存失败", message: Self.message(for: error))
            }
        }
    }

    private func saveToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw PhotosAccessDenied()
        }
        try await Self.addImageToLibrary(url)
    }

    /// 必须 nonisolated：写在视图里的闭包会被推断成主线程隔离，而 Photos 在自己的后台队列执行它，
    /// Swift 6 运行时检查到隔离不符会直接崩（`dispatch_assert_queue`）。
    private nonisolated static func addImageToLibrary(_ url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: url)
        }
    }

    private struct PhotosAccessDenied: LocalizedError {
        var errorDescription: String? { "没有相册权限。请在「设置」里允许 Moon Code 添加照片。" }
    }

    private static let tooLargeMessage = "因 Kimi 官方限制，无法预览或下载 10MB 以上文件"

    private static func message(for error: any Error) -> String {
        if case let KapError.api(code, _) = error, code == KapErrorCode.fileTooLarge {
            return tooLargeMessage
        }
        return error.localizedDescription
    }

    /// 下载到沙盒并登记，离开页面时统一清理；下载途中页面没了就立刻删掉。
    private func fetchFile() async throws -> URL {
        let url = try await client.downloadFile(sessionID, path: entry.path)
        if Task.isCancelled {
            PreviewStorage.remove(url)
            throw CancellationError()
        }
        downloadedFiles.append(url)
        return url
    }
}

extension EnvironmentValues {
    /// 对话里点文件提及（输入框里的卡片 / 气泡上的标签）：打开这个文件的预览。
    @Entry var openFilePreview: ((FsEntry) -> Void)?
}

/// 从对话里打开的文件预览：单独一个上拉栏，左上角 ✕。
struct FilePreviewSheet: View {
    let client: any KapServicing
    let sessionID: String
    let entry: FsEntry

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FilePreviewView(client: client, sessionID: sessionID, entry: entry)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭", systemImage: "xmark") { dismiss() }
                    }
                }
        }
    }
}

/// 文本预览：只读、可自由选择的 UITextView（SwiftUI `Text` 排 1 MiB 会卡，而且长按只能整段拷贝）。
private struct CodeTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = true
        view.backgroundColor = .clear
        view.adjustsFontForContentSizeCategory = true
        view.font = UIFontMetrics(forTextStyle: .callout)
            .scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular))
        view.textColor = .label
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        view.alwaysBounceVertical = true
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}

private struct QuickLookFile: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            url as NSURL
        }
    }
}

/// 系统分享面板，里面有「存储到文件」「隔空投送」「用其他 App 打开」。
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context: Context) {}
}
