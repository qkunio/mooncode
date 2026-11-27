import SwiftUI

/// 会话右上角 ⋯ 左边的文件夹按钮：从底部拉起当前文件夹的文件浏览。
struct FilesButton: View {
    let client: (any KapServicing)?
    /// 用来调 `fs:list` 的会话。草稿还没有会话时，借同一文件夹里的已有会话（workDir 相同）。
    let sessionID: String?
    let title: String
    /// 文件预览里点「添加到会话」：把文件交给输入框当附件。
    let addToChat: (FsEntry) -> Void

    @State private var isPresented = false
    /// 默认半屏，想看更多再往上拉。
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label("文件", image: "mc-workspace")
        }
        .sheet(isPresented: $isPresented) {
            FilesSheet(client: client, sessionID: sessionID, title: title) { entry in
                isPresented = false
                addToChat(entry)
            }
                .presentationDetents([.medium, .large], selection: $detent)
                .presentationDragIndicator(.visible)
                .presentationBackground(Color(.systemGroupedBackground))
        }
    }
}

/// 根目录一页，点文件夹逐级往里推。
private struct FilesSheet: View {
    let client: (any KapServicing)?
    let sessionID: String?
    let title: String
    let addToChat: (FsEntry) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if let client, let sessionID {
                    FolderListView(client: client, sessionID: sessionID, path: ".")
                } else {
                    ContentUnavailableView {
                        Label {
                            Text("还没有可浏览的文件")
                        } icon: {
                            MoonIcon("mc-workspace", size: 42)
                        }
                    } description: {
                        Text("发出第一条消息后，就能在这里查看这个文件夹里的文件。")
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: FsEntry.self) { entry in
                if let client, let sessionID {
                    if entry.isDirectory {
                        FolderListView(client: client, sessionID: sessionID, path: entry.path)
                            .navigationTitle(entry.name)
                            .navigationBarTitleDisplayMode(.inline)
                    } else {
                        FilePreviewView(client: client, sessionID: sessionID, entry: entry) {
                            addToChat(entry)
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton()
                }
            }
        }
    }
}

/// 上拉栏左上角的 ✕。
struct SheetCloseButton: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button(role: .close) { dismiss() }
    }
}

/// 某一层的文件夹和文件（服务端已按 `.gitignore` 过滤、文件夹在前）。
private struct FolderListView: View {
    let client: any KapServicing
    let sessionID: String
    let path: String

    @State private var list: FsList?
    @State private var failed = false

    var body: some View {
        Group {
            if let list {
                if list.items.isEmpty {
                    ContentUnavailableView {
                        Label {
                            Text("空文件夹")
                        } icon: {
                            MoonIcon("mc-workspace", size: 42)
                        }
                    }
                } else {
                    List {
                        Section {
                            ForEach(list.items) { entry in
                                NavigationLink(value: entry) { FileRow(entry: entry) }
                            }
                        } footer: {
                            if list.truncated {
                                Text("文件太多，只显示了前 \(list.items.count) 项。")
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            } else if failed {
                ContentUnavailableView {
                    Label {
                        Text("无法读取此文件夹")
                    } icon: {
                        MoonIcon("mc-folder-unknown", size: 42)
                    }
                } description: {
                    Text("请确认电脑上的 Kimi Code 仍在运行。")
                } actions: {
                    Button("重试") { Task { await load() } }
                        .buttonStyle(.glass)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            list = try await client.listFiles(sessionID, path: path)
            failed = false
        } catch {
            guard !Task.isCancelled, !KapError.isCancellation(error) else { return }
            if list == nil { failed = true }
        }
    }
}

private struct FileRow: View {
    let entry: FsEntry

    var body: some View {
        HStack(spacing: 12) {
            MoonIcon(entry.symbolName, size: 19)
                .foregroundStyle(entry.isDirectory ? AnyShapeStyle(Palette.kimi) : AnyShapeStyle(.secondary))
                .frame(width: 24)
            Text(entry.name)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var detail: String? {
        if entry.isDirectory {
            return entry.childCount.map { "\($0) 项" }
        }
        return entry.size.map { Int64($0).formatted(.byteCount(style: .file)) }
    }
}

extension FsEntry {
    /// 文件列表行的图标。
    var symbolName: String {
        switch kind {
        case .directory: return "mc-workspace"
        case .symlink: return "mc-symlink"
        case .file: break
        }
        switch (name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "ico":
            return "mc-photo"
        case "mp4", "mov", "m4v", "webm":
            return "mc-video"
        case "mp3", "wav", "m4a", "aac", "flac":
            return "mc-audio"
        case "zip", "gz", "tar", "tgz", "rar", "7z":
            return "mc-file-zip"
        case "pdf":
            return "mc-file-rich"
        case "md", "txt", "rtf", "log":
            return "mc-file-preview"
        case "json", "yaml", "yml", "toml", "xml", "plist", "ini", "lock":
            return "mc-config-braces"
        case "swift", "ts", "tsx", "js", "jsx", "mjs", "vue", "py", "rb", "go", "rs", "java", "kt",
             "c", "h", "cc", "cpp", "hpp", "m", "mm", "cs", "php", "sh", "zsh", "bash", "css", "scss",
             "html", "sql":
            return "mc-code-brackets"
        default:
            return "mc-file-preview"
        }
    }
}
