import SwiftUI
import ImageIO

/// 从当前会话的媒体接口加载，支持重开会话后的图片预览。
struct RemoteAttachmentImage: View {
    let attachment: AttachmentRef
    let number: Int
    let load: @MainActor (AttachmentRef) async throws -> Data
    @State private var thumbnail: UIImage?
    @State private var failed = false
    @State private var attempt = 0
    @State private var showsPreview = false

    var body: some View {
        Button {
            if thumbnail != nil { showsPreview = true }
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
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
        .sheet(isPresented: $showsPreview) {
            AttachmentImagePreview(load: { try await load(attachment) })
        }
    }
}

/// 乐观发送和失败重试也展示图片，而不是只有一个附件数量标签。
struct LocalAttachmentPreviews: View {
    let attachments: [Attachment]
    @State private var selected: Preview?
    private struct Preview: Identifiable { let id: UUID; let data: Data }

    var body: some View {
        let images = attachments.compactMap { attachment -> (UUID, Data, Data)? in
            if case let .image(id, jpeg, thumbnail) = attachment { return (id, jpeg, thumbnail) }
            return nil
        }
        if !images.isEmpty {
            AttachmentThumbnailLayout {
                ForEach(Array(images.enumerated()), id: \.element.0) { index, image in
                    Button { selected = Preview(id: image.0, data: image.1) } label: {
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
        Color.clear.frame(height: 0)
            .sheet(item: $selected) { AttachmentImagePreview(data: $0.data) }
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

private struct AttachmentImagePreview: View {
    private let data: Data?
    private let load: (@MainActor () async throws -> Data)?
    @State private var loadedData: Data?
    @State private var errorMessage: String?
    @State private var attempt = 0
    @Environment(\.dismiss) private var dismiss

    init(data: Data) { self.data = data; load = nil }
    init(load: @escaping @MainActor () async throws -> Data) { data = nil; self.load = load }

    var body: some View {
        NavigationStack {
            Group {
                if let bytes = data ?? loadedData {
                    if let image = UIImage(data: bytes) {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else { ContentUnavailableView("图片不可预览", systemImage: "photo") }
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("图片加载失败", systemImage: "photo.badge.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("重试") { attempt += 1 }
                    }
                } else { ProgressView("正在加载图片") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .navigationTitle("图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("关闭") { dismiss() }.accessibilityLabel("关闭图片预览")
            } }
            .task(id: attempt) {
                guard let load else { return }
                errorMessage = nil
                do {
                    let bytes = try await load()
                    try Task.checkCancellation()
                    loadedData = bytes
                } catch {
                    if !Task.isCancelled { errorMessage = error.localizedDescription }
                }
            }
        }
    }
}
