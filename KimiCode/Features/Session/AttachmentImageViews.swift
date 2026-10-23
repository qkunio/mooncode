import SwiftUI
import ImageIO

private struct OpenAttachmentGalleryKey: EnvironmentKey {
    static let defaultValue: (@MainActor (AttachmentGallerySelection) -> Void)? = nil
}

private extension EnvironmentValues {
    var openAttachmentGallery: (@MainActor (AttachmentGallerySelection) -> Void)? {
        get { self[OpenAttachmentGalleryKey.self] }
        set { self[OpenAttachmentGalleryKey.self] = newValue }
    }
}

extension View {
    func attachmentImageGallery() -> some View { modifier(AttachmentGalleryPresenter()) }
}

/// 挂在稳定的聊天页面上：待发送气泡被正式消息替换时，预览仍然保留。
private struct AttachmentGalleryPresenter: ViewModifier {
    @State private var selection: AttachmentGallerySelection?

    func body(content: Content) -> some View {
        content
            .environment(\.openAttachmentGallery, { selection = $0 })
            .fullScreenCover(item: $selection) { AttachmentImageGallery(selection: $0) }
    }
}

/// 一条消息里的图片共用一个浏览器；点选哪张就从哪张开始。
struct RemoteAttachmentImages: View {
    let attachments: [AttachmentRef]
    let load: @MainActor (AttachmentRef) async throws -> Data
    @Environment(\.openAttachmentGallery) private var openGallery
    @State private var thumbnails: [String: UIImage] = [:]

    var body: some View {
        AttachmentThumbnailLayout {
            ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
                RemoteAttachmentImage(attachment: attachment, number: index + 1, load: load, thumbnailLoaded: {
                    thumbnails[attachment.id] = $0
                }) {
                    openGallery?(AttachmentGallerySelection(items: attachments.map { item in
                        AttachmentGalleryItem(id: item.id, thumbnail: thumbnails[item.id], load: { [load] in try await load(item) })
                    }, initialIndex: index))
                }
            }
        }
    }
}

/// 气泡只保留缩略图，原图由整组浏览器按当前页加载。
private struct RemoteAttachmentImage: View {
    let attachment: AttachmentRef
    let number: Int
    let load: @MainActor (AttachmentRef) async throws -> Data
    let thumbnailLoaded: (UIImage) -> Void
    let openPreview: () -> Void
    @State private var thumbnail: UIImage?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        Button {
            if thumbnail != nil { openPreview() }
            else if failed { attempt += 1 }
        } label: {
            ZStack {
                Palette.fill
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFit().padding(1)
                } else if failed {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.exclamationmark")
                        Text("重试").font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                } else {
                    ProgressView().accessibilityLabel("正在加载图片")
                }
            }
            .frame(width: AttachmentThumbnailLayout.side, height: AttachmentThumbnailLayout.side)
            .clipShape(.rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.1)) }
            .overlay(alignment: .bottomTrailing) { AttachmentNumberBadge(number: number) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(failed ? "重试图片 \(number)" : "预览图片 \(number)")
        .task(id: "\(attachment.id):\(attachment.source?.cacheKey ?? "none"):\(attempt)") {
            failed = false
            thumbnail = nil
            do {
                let bytes = try await load(attachment)
                try Task.checkCancellation()
                guard let image = AttachmentImageThumbnail.make(bytes) else {
                    failed = true
                    return
                }
                thumbnail = image
                thumbnailLoaded(image)
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }
}

/// 乐观发送和失败重试也展示图片，而不是只有一个附件数量标签。
struct LocalAttachmentPreviews: View {
    let attachments: [Attachment]
    @Environment(\.openAttachmentGallery) private var openGallery

    var body: some View {
        let images = attachments.compactMap { attachment -> (UUID, Data, Data)? in
            if case let .image(id, jpeg, thumbnail) = attachment { return (id, jpeg, thumbnail) }
            return nil
        }
        if !images.isEmpty {
            AttachmentThumbnailLayout {
                ForEach(Array(images.enumerated()), id: \.element.0) { index, image in
                    Button {
                        openGallery?(AttachmentGallerySelection(items: images.map { item in
                            AttachmentGalleryItem(id: item.0.uuidString, thumbnail: UIImage(data: item.2), load: { item.1 })
                        }, initialIndex: index))
                    } label: {
                        ZStack {
                            Palette.fill
                            if let thumbnail = UIImage(data: image.2) ?? AttachmentImageThumbnail.make(image.1) {
                                Image(uiImage: thumbnail).resizable().scaledToFit().padding(1)
                            } else { Image(systemName: "photo").foregroundStyle(.secondary) }
                        }
                        .frame(width: AttachmentThumbnailLayout.side, height: AttachmentThumbnailLayout.side)
                        .clipShape(.rect(cornerRadius: 12))
                        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.1)) }
                        .overlay(alignment: .bottomTrailing) { AttachmentNumberBadge(number: index + 1) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("预览待发送图片 \(index + 1)")
                }
            }
        }
        ForEach(attachments) { attachment in
            if case let .file(_, name, _, _) = attachment {
                Label(name, systemImage: "doc").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// 与手机尺寸网页的 74pt 外框接近；固定缩略图尺寸，空间不足时按顺序换行。
struct AttachmentThumbnailLayout: Layout {
    static let side: CGFloat = 74
    private static let spacing: CGFloat = 8

    private static func columns(for count: Int, in width: CGFloat) -> Int {
        guard count > 0 else { return 1 }
        guard width.isFinite else { return count }
        let capacity = (max(side, width) + spacing) / (side + spacing)
        return max(1, Int(min(CGFloat(count), capacity)))
    }

    static func contentWidth(for count: Int, in width: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        let columns = columns(for: count, in: width)
        return CGFloat(columns) * side + CGFloat(columns - 1) * spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let idealWidth = CGFloat(subviews.count) * Self.side + CGFloat(subviews.count - 1) * Self.spacing
        let width = Self.contentWidth(for: subviews.count, in: proposal.width ?? idealWidth)
        let columns = Self.columns(for: subviews.count, in: width)
        let rows = (subviews.count + columns - 1) / columns
        return CGSize(width: width, height: CGFloat(rows) * Self.side + CGFloat(rows - 1) * Self.spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let columns = Self.columns(for: subviews.count, in: bounds.width)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(
                x: bounds.minX + CGFloat(index % columns) * (Self.side + Self.spacing),
                y: bounds.minY + CGFloat(index / columns) * (Self.side + Self.spacing)
            ), anchor: .topLeading, proposal: ProposedViewSize(width: Self.side, height: Self.side))
        }
    }
}

private struct AttachmentNumberBadge: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white)
            .frame(minWidth: 20, minHeight: 20)
            .background(.black.opacity(0.65), in: .circle)
            .padding(2)
            .accessibilityHidden(true)
    }
}

private enum AttachmentImageThumbnail {
    static func make(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

private struct AttachmentGalleryItem: Identifiable {
    let id: String
    let thumbnail: UIImage?
    let load: @MainActor () async throws -> Data
}

/// 打开时固定这条消息的图片及顺序，避免后台 transcript 更新改变正在浏览的一组。
private struct AttachmentGallerySelection: Identifiable {
    let id = UUID()
    let items: [AttachmentGalleryItem]
    let initialIndex: Int
}

private struct AttachmentImageGallery: View {
    let selection: AttachmentGallerySelection
    @State private var index: Int
    @GestureState(resetTransaction: Transaction(animation: .snappy(duration: 0.22))) private var dismissOffset: CGFloat = 0
    @Environment(\.dismiss) private var dismiss

    init(selection: AttachmentGallerySelection) {
        self.selection = selection
        _index = State(initialValue: selection.initialIndex)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(selection.items.enumerated()), id: \.element.id) { page, item in
                    AttachmentImagePage(item: item, isSelected: page == index)
                        .tag(page)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .offset(y: dismissOffset)
        }
        .contentShape(.rect)
        .simultaneousGesture(dismissGesture)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Color.clear.frame(width: 44, height: 44).accessibilityHidden(true)
                Spacer()
                Text("\(index + 1) / \(selection.items.count)")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.white)
                    .accessibilityLabel("图片 \(index + 1)，共 \(selection.items.count) 张")
                Spacer()
                Button("关闭", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
                    .buttonStyle(.glass)
                    .accessibilityLabel("关闭图片预览")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.black)
        }
        .preferredColorScheme(.dark)
        .accessibilityAction(.escape) { dismiss() }
    }

    /// 横向翻页与下拉退出同时识别，只接受明显朝下的拖动；取消或不足阈值时自动归位。
    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .updating($dismissOffset) { value, offset, transaction in
                transaction.animation = nil
                let translation = value.translation
                offset = translation.height > abs(translation.width) * 1.5 ? max(0, translation.height) : 0
            }
            .onEnded { value in
                let translation = value.translation
                guard translation.height > abs(translation.width) * 1.5 else { return }
                if translation.height > 120 || (translation.height > 60 && value.predictedEndTranslation.height > 240) {
                    dismiss()
                }
            }
    }
}

private struct AttachmentImagePage: View {
    let item: AttachmentGalleryItem
    let isSelected: Bool
    @State private var image: UIImage?
    @State private var errorMessage: String?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .accessibilityLabel("图片")
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("图片加载失败", systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("重试") { attempt += 1 }
                }
            } else if let thumbnail = item.thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFit()
                    .overlay {
                        if isSelected {
                            ProgressView("正在加载图片")
                                .padding()
                                .background(.black.opacity(0.65), in: .rect(cornerRadius: 12))
                        }
                    }
            } else if isSelected {
                ProgressView("正在加载图片")
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .task(id: "\(isSelected):\(attempt)") {
            image = nil
            errorMessage = nil
            guard isSelected else { return }
            do {
                let bytes = try await item.load()
                try Task.checkCancellation()
                if let decoded = UIImage(data: bytes) {
                    image = decoded
                } else {
                    errorMessage = "图片不可预览"
                }
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
        .onDisappear { image = nil }
    }
}
