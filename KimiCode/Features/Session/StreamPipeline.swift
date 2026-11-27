import Foundation
import Observation
#if canImport(UIKit)
import QuartzCore
import UIKit
#endif

// MARK: - 实时流式正文槽位

/// 正在流式输出的单个正文/思考块的独立可观察状态。
///
/// 高频 delta 只改这里的 `text`，不触碰 `ChatModel.entries`：
/// 整条对话列表和所有历史消息都不参与 SwiftUI diff，只有当前活跃的单个叶视图会重绘。
@MainActor
@Observable
final class LiveStreamStore {
    enum Kind: Equatable, Sendable {
        case text
        case thinking
    }

    private(set) var activeBlockID: String?
    private(set) var kind: Kind?
    private(set) var text: String = ""

    func update(blockID: String, kind: Kind, text: String) {
        if activeBlockID != blockID { activeBlockID = blockID }
        if self.kind != kind { self.kind = kind }
        if self.text != text { self.text = text }
    }

    func clear() {
        if activeBlockID != nil { activeBlockID = nil }
        if kind != nil { kind = nil }
        if !text.isEmpty { text = "" }
    }
}

/// 绑定在 `LiveStreamStore` 上的活跃帧锚点，用于把 WS delta 直接路由到当前流式块。
struct LiveStreamAnchor: Equatable, Sendable {
    let turnID: String
    let stepID: String
    let frameID: String
    let blockID: String
    let kind: LiveStreamStore.Kind
    /// 同一助手消息里相邻块合并后的前缀（含换行）；未合并时为空串。
    let prefix: String
    /// 该帧在绑定瞬间已经落地的文本（不含 prefix）。
    let frameText: String

    func matches(turnID: String, stepID: String?, frameID: String) -> Bool {
        self.turnID == turnID && self.frameID == frameID && (stepID == nil || self.stepID == stepID)
    }
}

// MARK: - 显示同步平滑节拍器

/// 流式输出平滑节拍与合帧器：
/// - 在 iOS 上通过 `CADisplayLink`（`.common` 模式，滑动列表时不暂停）按屏幕刷新节拍推进；
/// - 吸收网络抖动导致的突发团块，按自适应追赶曲线按字形簇（grapheme cluster）平滑吐出；
/// - 减弱动态效果时跳过逐字缓出，仅做显示同步合帧；
/// - 遇到结构变化（块结束 / 轮次结束 / 重拉 / 退后台）立即全量落盘，绝不拖尾。
@MainActor
final class StreamPacer {
    let liveStream: LiveStreamStore

    private var anchor: LiveStreamAnchor?
    private var revealedText = ""
    private var pendingText = ""
    private var pendingCursor: String.Index
    private var pendingCharacterCount = 0

    private var needsStructuralRebuild = false
    var onStructuralFlush: (() -> Void)?
    var onTextAdvance: (() -> Void)?

    private var lastFrameTimestamp: CFTimeInterval?
    private var lastCommitTimestamp: CFTimeInterval = 0
    private var lastStructuralTimestamp: CFTimeInterval = 0
    private var isStopped = false

    /// 供单测覆盖是否开启减弱动态效果；nil 时读取系统设置。
    var reduceMotionOverride: Bool?

    #if canImport(UIKit)
    private var displayLink: CADisplayLink?
    private var displayLinkTarget: DisplayLinkProxy?
    #else
    private var fallbackTask: Task<Void, Never>?
    #endif

    init(
        liveStream: LiveStreamStore,
        onStructuralFlush: (() -> Void)? = nil,
        onTextAdvance: (() -> Void)? = nil
    ) {
        self.liveStream = liveStream
        self.onStructuralFlush = onStructuralFlush
        self.onTextAdvance = onTextAdvance
        self.pendingCursor = pendingText.startIndex
    }

    var currentAnchor: LiveStreamAnchor? { anchor }
    var hasPendingWork: Bool { pendingCharacterCount > 0 || needsStructuralRebuild }

    /// 绑定新的活跃流式块。
    /// 若首包本身是一大段突发文本，可先展示开头一小段、剩余部分平滑缓出，避免首帧突兀整段跳出。
    func attach(_ newAnchor: LiveStreamAnchor, initialBurst: String? = nil) {
        anchor = newAnchor
        clearPendingBuffer()

        if let initialBurst,
           !isReduceMotionEnabled,
           initialBurst.count > 4,
           newAnchor.frameText.hasSuffix(initialBurst) {
            let committedFramePrefix = String(newAnchor.frameText.dropLast(initialBurst.count))
            // 首帧至少露出开头非空白字符，确保布局与「工作中」状态立刻就位。
            let firstCut = initialBurst.index(after: initialBurst.startIndex)
            let head = String(initialBurst[..<firstCut])
            let tail = String(initialBurst[firstCut...])
            revealedText = newAnchor.prefix + committedFramePrefix + head
            liveStream.update(blockID: newAnchor.blockID, kind: newAnchor.kind, text: revealedText)
            enqueuePending(tail)
            startDriverIfNeeded()
        } else {
            revealedText = newAnchor.prefix + newAnchor.frameText
            liveStream.update(blockID: newAnchor.blockID, kind: newAnchor.kind, text: revealedText)
            stopDriverIfIdle()
        }
    }

    /// 尝试把一条 delta 直接送入当前活跃流式块；不匹配时返回 false，由调用方走结构更新。
    func acceptDelta(turnID: String, stepID: String?, frameID: String, delta: String) -> Bool {
        guard let anchor, anchor.matches(turnID: turnID, stepID: stepID, frameID: frameID) else {
            return false
        }
        guard !delta.isEmpty else { return true }
        enqueuePending(delta)
        startDriverIfNeeded()
        return true
    }

    /// 合并高频的非正文结构变更（如工具 stdout 流式输出），按 ~30Hz 节拍刷新。
    func scheduleStructuralRebuild() {
        needsStructuralRebuild = true
        startDriverIfNeeded()
    }

    /// 立刻冲刷所有缓冲（不清空 liveStream，用于退后台等需要状态一致的时机）。
    func flushPendingText() {
        guard pendingCharacterCount > 0, let anchor else { return }
        revealedText.append(contentsOf: pendingText[pendingCursor...])
        clearPendingBuffer()
        liveStream.update(blockID: anchor.blockID, kind: anchor.kind, text: revealedText)
        onTextAdvance?()
        stopDriverIfIdle()
    }

    /// 重置节拍器（结构变更、轮次结束、重拉、切换会话时调用）。
    func reset(clearLiveStream: Bool = true) {
        anchor = nil
        revealedText.removeAll(keepingCapacity: true)
        clearPendingBuffer()
        needsStructuralRebuild = false
        stopDriver()
        if clearLiveStream {
            liveStream.clear()
        }
    }

    func stop() {
        isStopped = true
        onStructuralFlush = nil
        onTextAdvance = nil
        reset(clearLiveStream: true)
    }

    /// 推进一帧（供 `CADisplayLink` 和单测复用）。
    func tick(timestamp: CFTimeInterval) {
        guard !isStopped else {
            stopDriver()
            return
        }

        let rawDT = lastFrameTimestamp.map { timestamp - $0 } ?? (1.0 / 60.0)
        lastFrameTimestamp = timestamp
        let dt = min(max(rawDT, 1.0 / 120.0), 0.05)

        if needsStructuralRebuild, timestamp - lastStructuralTimestamp >= 1.0 / 30.0 {
            needsStructuralRebuild = false
            lastStructuralTimestamp = timestamp
            onStructuralFlush?()
        }

        if pendingCharacterCount > 0, let anchor {
            // 长段落单块超过 1800 字节时自动降频到 ~30Hz，控制 TextKit 2 重排开销；常规长度保持 60Hz 丝滑输出。
            let minInterval: CFTimeInterval = revealedText.utf8.count > 1_800 ? (1.0 / 30.0) : (1.0 / 62.0)
            let elapsed = lastCommitTimestamp > 0 ? (timestamp - lastCommitTimestamp) : minInterval
            if elapsed >= minInterval {
                let step = Self.revealStep(
                    backlog: pendingCharacterCount,
                    dt: min(max(elapsed, dt), 0.05),
                    reduceMotion: isReduceMotionEnabled
                )
                advancePending(by: step)
                lastCommitTimestamp = timestamp
                liveStream.update(blockID: anchor.blockID, kind: anchor.kind, text: revealedText)
                onTextAdvance?()
            }
        }

        stopDriverIfIdle()
    }

    /// 自适应追赶步长：
    /// - 正常积压在 ~110ms 内平滑吐完，完全抹平网络抖动又无肉眼滞后；
    /// - 大段突发（代码/断线补发）缩短追赶窗口，迅速跟上最新进度；
    /// - 减弱动态效果直接整批吐出。
    static func revealStep(backlog: Int, dt: CFTimeInterval, reduceMotion: Bool) -> Int {
        guard backlog > 0 else { return 0 }
        if reduceMotion { return backlog }
        let drainWindow: CFTimeInterval = if backlog > 500 {
            0.05
        } else if backlog > 120 {
            0.08
        } else {
            0.11
        }
        let target = Int(ceil(Double(backlog) * dt / drainWindow))
        return min(backlog, max(1, target))
    }

    // MARK: 内部缓冲

    private var isReduceMotionEnabled: Bool {
        if let override = reduceMotionOverride { return override }
        #if canImport(UIKit)
        return UIAccessibility.isReduceMotionEnabled
        #else
        return false
        #endif
    }

    private func enqueuePending(_ delta: String) {
        let addedCount = delta.count
        guard addedCount > 0 else { return }
        if pendingCharacterCount == 0 {
            pendingText = delta
            pendingCursor = pendingText.startIndex
            pendingCharacterCount = addedCount
            return
        }
        let consumedUTF8 = pendingText.utf8.distance(from: pendingText.startIndex, to: pendingCursor)
        if consumedUTF8 > 128 {
            pendingText.removeSubrange(..<pendingCursor)
            pendingText.append(delta)
            pendingCursor = pendingText.startIndex
        } else {
            pendingText.append(delta)
            pendingCursor = pendingText.utf8.index(pendingText.startIndex, offsetBy: consumedUTF8)
        }
        pendingCharacterCount += addedCount
    }

    private func advancePending(by count: Int) {
        let take = min(count, pendingCharacterCount)
        guard take > 0 else { return }
        if take >= pendingCharacterCount {
            revealedText.append(contentsOf: pendingText[pendingCursor...])
            clearPendingBuffer()
            return
        }
        var end = pendingCursor
        var moved = 0
        while moved < take, end < pendingText.endIndex {
            end = pendingText.index(after: end)
            moved += 1
        }
        revealedText.append(contentsOf: pendingText[pendingCursor..<end])
        pendingCursor = end
        pendingCharacterCount -= moved
        if pendingCharacterCount == 0 || pendingCursor == pendingText.endIndex {
            clearPendingBuffer()
        }
    }

    private func clearPendingBuffer() {
        pendingText.removeAll(keepingCapacity: true)
        pendingCursor = pendingText.startIndex
        pendingCharacterCount = 0
    }

    // MARK: 驱动器

    private func startDriverIfNeeded() {
        guard !isStopped, hasPendingWork else { return }
        #if canImport(UIKit)
        guard displayLink == nil else { return }
        let proxy = DisplayLinkProxy { [weak self] timestamp in
            self?.tick(timestamp: timestamp)
        }
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLinkTarget = proxy
        displayLink = link
        lastFrameTimestamp = nil
        #else
        guard fallbackTask == nil else { return }
        lastFrameTimestamp = nil
        fallbackTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled, let self else { return }
                self.tick(timestamp: ProcessInfo.processInfo.systemUptime)
            }
        }
        #endif
    }

    private func stopDriverIfIdle() {
        guard !hasPendingWork else { return }
        stopDriver()
    }

    private func stopDriver() {
        lastFrameTimestamp = nil
        lastCommitTimestamp = 0
        #if canImport(UIKit)
        displayLink?.invalidate()
        displayLink = nil
        displayLinkTarget = nil
        #else
        fallbackTask?.cancel()
        fallbackTask = nil
        #endif
    }
}

#if canImport(UIKit)
/// 避免 `CADisplayLink` 强持有 `StreamPacer` 造成循环引用。
@MainActor
private final class DisplayLinkProxy: NSObject {
    let onStep: @MainActor (CFTimeInterval) -> Void

    init(onStep: @escaping @MainActor (CFTimeInterval) -> Void) {
        self.onStep = onStep
    }

    @objc func step(_ link: CADisplayLink) {
        onStep(link.timestamp)
    }
}
#endif

// MARK: - 按轮次增量视图缓存

/// 缓存每一项 `TranscriptItem` 转换成的 `[ChatEntry]`。
/// 结构重建时只重算发生变化的轮次（通常只有正在运行的最后一轮），已定稿的历史轮次直接复用。
struct ConversationProjectionCache {
    private struct CachedItem {
        let source: TranscriptItem
        let entries: [ChatEntry]
        let isTurnActive: Bool
        let pendingStepID: String?
        let timings: [String: ThinkingTiming]
        let compactionTrigger: String?
        let attachmentsCount: Int
        let tasksCount: Int
    }

    private var cache: [String: CachedItem] = [:]
    private var lastAttachments: [String: TranscriptAttachment] = [:]
    private var lastTasks: [String: TranscriptTask] = [:]
    private var attachmentsRevision = 0
    private var tasksRevision = 0

    mutating func reset() {
        cache.removeAll(keepingCapacity: true)
        lastAttachments = [:]
        lastTasks = [:]
        attachmentsRevision = 0
        tasksRevision = 0
    }

    mutating func build(
        from state: TranscriptState,
        timing: [String: ThinkingTiming]
    ) -> [ChatEntry] {
        if state.attachments != lastAttachments {
            lastAttachments = state.attachments
            attachmentsRevision &+= 1
        }
        if state.tasks != lastTasks {
            lastTasks = state.tasks
            tasksRevision &+= 1
        }

        let isTurnActive = state.isTurnActive
        let pendingStepID = ConversationBuilder.pendingStepID(state)
        var result: [ChatEntry] = []
        result.reserveCapacity(state.items.count * 2)
        var activeIDs = Set<String>(minimumCapacity: state.items.count)

        for (position, item) in state.items.enumerated() {
            let id = item.id
            activeIDs.insert(id)

            let itemTimings = Self.timings(for: item, from: timing)
            let trigger: String? = if case let .marker(marker) = item,
                                      marker.marker == "compaction",
                                      marker.payload?["phase"]?.stringValue == "completed" {
                ConversationBuilder.compactionTrigger(before: position, in: state.items)
            } else {
                nil
            }
            let turnPendingStep: String? = if case let .turn(turn) = item,
                                              let pendingStepID,
                                              turn.steps.contains(where: { $0.stepId == pendingStepID }) {
                pendingStepID
            } else {
                nil
            }
            let turnIsActive: Bool = if case let .turn(turn) = item {
                isTurnActive && turn.state == "running"
            } else {
                false
            }

            if let hit = cache[id],
               hit.source == item,
               hit.isTurnActive == turnIsActive,
               hit.pendingStepID == turnPendingStep,
               hit.timings == itemTimings,
               hit.compactionTrigger == trigger,
               hit.attachmentsCount == attachmentsRevision,
               hit.tasksCount == tasksRevision {
                result.append(contentsOf: hit.entries)
                continue
            }

            let built = ConversationBuilder.buildItem(
                item,
                at: position,
                in: state,
                timing: timing,
                pendingStepID: pendingStepID,
                isTurnActive: isTurnActive
            )
            cache[id] = CachedItem(
                source: item,
                entries: built,
                isTurnActive: turnIsActive,
                pendingStepID: turnPendingStep,
                timings: itemTimings,
                compactionTrigger: trigger,
                attachmentsCount: attachmentsRevision,
                tasksCount: tasksRevision
            )
            result.append(contentsOf: built)
        }

        if cache.count > activeIDs.count {
            cache = cache.filter { activeIDs.contains($0.key) }
        }
        ConversationBuilder.markUndo(&result)
        return result
    }

    private static func timings(
        for item: TranscriptItem,
        from all: [String: ThinkingTiming]
    ) -> [String: ThinkingTiming] {
        guard !all.isEmpty, case let .turn(turn) = item else { return [:] }
        var slice: [String: ThinkingTiming] = [:]
        for step in turn.steps {
            for frame in step.frames where frame.kind == "thinking" {
                if let value = all[frame.frameId] {
                    slice[frame.frameId] = value
                }
            }
        }
        return slice
    }
}
