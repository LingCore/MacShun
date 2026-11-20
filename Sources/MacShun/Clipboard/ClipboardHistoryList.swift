// SPDX-License-Identifier: MIT

import AppKit
import Combine
import SwiftUI

/// 剪贴板历史虚拟滚动列表。
///
/// 使用原生 AppKit `NSScrollView` 搭配按需复用的 `NSHostingView` 行单元，精确维护每行高度与累计偏移：
/// 向上展开（搜索栏在底部）时，最新记录始终紧贴列表底端，反复换向滚动或快速滑到底部都不会出现行高重估导致的异常空白或卡顿。
struct ClipboardHistoryList: NSViewRepresentable {
    @ObservedObject var model: ClipboardPanelModel
    let isDisabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> ClipboardHistoryScrollView {
        let scrollView = ClipboardHistoryScrollView()
        let documentView = ClipboardHistoryDocumentView()
        scrollView.documentView = documentView
        context.coordinator.attach(scrollView: scrollView, documentView: documentView)
        return scrollView
    }

    func updateNSView(_ scrollView: ClipboardHistoryScrollView, context: Context) {
        let env = CellEnvironment(from: context.environment, isEnabled: !isDisabled)
        scrollView.isInteractionDisabled = isDisabled
        context.coordinator.update(model: model, environment: env, isDisabled: isDisabled)
    }

    static func dismantleNSView(_ scrollView: ClipboardHistoryScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }
}

// MARK: - 环境与单元容器

private struct CellEnvironment: Equatable {
    let dynamicTypeSize: DynamicTypeSize
    let controlActiveState: ControlActiveState
    let layoutDirection: LayoutDirection
    let locale: Locale
    let colorScheme: ColorScheme
    let isEnabled: Bool

    init(from env: EnvironmentValues, isEnabled: Bool) {
        self.dynamicTypeSize = env.dynamicTypeSize
        self.controlActiveState = env.controlActiveState
        self.layoutDirection = env.layoutDirection
        self.locale = env.locale
        self.colorScheme = env.colorScheme
        self.isEnabled = isEnabled
    }
}

private struct RowDescriptor {
    let logicalIndex: Int
    let item: ClipboardItem
    let groupTitle: String?
    let previewText: String
    let matchedImageLine: String?
}

private struct RowHeightKey: Hashable {
    let id: UUID
    let fingerprint: String
    let note: String?
    let groupTitle: String?
    let isFirstRow: Bool
    let matchedImageLine: String?
    let widthTenths: Int
    let dynamicTypeSize: DynamicTypeSize
}

private struct CellPayload: Equatable {
    let item: ClipboardItem
    let previewText: String
    let matchedImageLine: String?
    let groupTitle: String?
    let isFirstRow: Bool
    let opensAbove: Bool
    let isSelected: Bool
    let isHovered: Bool
    let badgeNumber: Int?
    let badgeIsQuickPaste: Bool
    let isBatchSelected: Bool
    let rowWidth: CGFloat
    let environment: CellEnvironment
    let timeEpoch: Int
}

private struct ClipboardCellContainer: View {
    let model: ClipboardPanelModel
    let payload: CellPayload?

    var body: some View {
        if let payload {
            VStack(alignment: .leading, spacing: 1) {
                if !payload.opensAbove, let title = payload.groupTitle {
                    groupHeading(title, isFirst: payload.isFirstRow, opensAbove: false)
                }
                ClipboardRow(
                    model: model,
                    item: payload.item,
                    previewText: payload.previewText,
                    matchedImageLine: payload.matchedImageLine,
                    isSelected: payload.isSelected,
                    isHovered: payload.isHovered,
                    badgeNumber: payload.badgeNumber,
                    badgeIsQuickPaste: payload.badgeIsQuickPaste,
                    isBatchSelected: payload.isBatchSelected
                )
                if payload.opensAbove, let title = payload.groupTitle {
                    groupHeading(title, isFirst: payload.isFirstRow, opensAbove: true)
                }
            }
            .frame(width: payload.rowWidth, alignment: .leading)
            .id(payload.item.id)
            .environment(\.dynamicTypeSize, payload.environment.dynamicTypeSize)
            .environment(\.controlActiveState, payload.environment.controlActiveState)
            .environment(\.layoutDirection, payload.environment.layoutDirection)
            .environment(\.locale, payload.environment.locale)
            .environment(\.colorScheme, payload.environment.colorScheme)
            .environment(\.isEnabled, payload.environment.isEnabled)
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private func groupHeading(_ title: String, isFirst: Bool, opensAbove: Bool) -> some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(opensAbove ? .bottom : .top, isFirst ? 2 : 10)
            .padding(opensAbove ? .top : .bottom, 4)
    }
}

// MARK: - AppKit 滚动与文档视图

private final class HiddenScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 0 }
    override func draw(_ dirtyRect: NSRect) {}
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class ClipboardHistoryScrollView: NSScrollView {
    var onLayout: (() -> Void)?
    var onScrollWheel: (() -> Void)?
    var isInteractionDisabled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        drawsBackground = false
        borderType = .noBorder
        // 保留垂直滚动器（透明零宽）以确保 AppKit 完整接收按行步进的离散鼠标滚轮事件，
        // 同时保持无滚动条视觉且不挤占内容宽度。
        verticalScroller = HiddenScroller()
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        verticalLineScroll = 10
        verticalPageScroll = 0
        verticalScrollElasticity = .automatic
        horizontalScrollElasticity = .none
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        contentView.postsBoundsChangedNotifications = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        if scrollerStyle != .overlay { scrollerStyle = .overlay }
        super.layout()
        onLayout?()
    }

    override func scrollWheel(with event: NSEvent) {
        guard !isInteractionDisabled else { return }
        onScrollWheel?()
        super.scrollWheel(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isInteractionDisabled ? nil : super.hitTest(point)
    }
}

final class ClipboardHistoryDocumentView: NSView {
    var onHoverPoint: ((CGPoint?) -> Void)?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverPoint?(convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        onHoverPoint?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        // 弹出“更多操作”菜单期间系统进入 eventTracking 模式；保留当前悬停行，避免菜单宿主按钮被移除。
        if RunLoop.current.currentMode == .eventTracking { return }
        onHoverPoint?(nil)
    }
}

// MARK: - 行高估算器

@MainActor
private enum ClipboardRowHeightEstimator {
    private static let bodyFont = NSFont.systemFont(ofSize: 13)
    private static let noteFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let layoutManager = NSLayoutManager()
    private static let bodyLineHeight = ceil(layoutManager.defaultLineHeight(for: bodyFont))
    private static let noteLineHeight = ceil(layoutManager.defaultLineHeight(for: noteFont))

    static func captionLineHeight(for size: DynamicTypeSize) -> CGFloat {
        let base = ceil(layoutManager.defaultLineHeight(for: NSFont.preferredFont(forTextStyle: .caption1)))
        let scale: CGFloat
        switch size {
        case .xSmall: scale = 0.85
        case .small: scale = 0.92
        case .medium, .large: scale = 1.0
        case .xLarge: scale = 1.1
        case .xxLarge: scale = 1.2
        case .xxxLarge: scale = 1.25
        case .accessibility1: scale = 1.35
        case .accessibility2: scale = 1.45
        case .accessibility3: scale = 1.55
        case .accessibility4: scale = 1.65
        case .accessibility5: scale = 1.75
        @unknown default: scale = 1.0
        }
        return ceil(base * scale)
    }

    static func estimateHeight(
        descriptor: RowDescriptor,
        rowWidth: CGFloat,
        dynamicTypeSize: DynamicTypeSize
    ) -> CGFloat {
        let textWidth = max(rowWidth - 56, 40)
        let captionHeight = captionLineHeight(for: dynamicTypeSize)
        var innerHeight: CGFloat = 0
        if descriptor.item.note != nil {
            innerHeight += noteLineHeight + 4
        }
        switch descriptor.item.kind {
        case .image:
            innerHeight += ClipboardRow.thumbnailSize(for: descriptor.item).height
            if descriptor.matchedImageLine != nil {
                innerHeight += 4 + captionHeight
            }
        case .text, .files:
            innerHeight += textBlockHeight(descriptor.previewText, maxWidth: textWidth)
        }
        innerHeight += 4 + 24
        var total = ceil(innerHeight + 16)
        if descriptor.groupTitle != nil {
            let edgePad: CGFloat = descriptor.logicalIndex == 0 ? 2 : 10
            total += 1 + captionHeight + edgePad + 4
        }
        return total
    }

    private static func textBlockHeight(_ text: String, maxWidth: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return bodyLineHeight }
        let ns = text as NSString
        let singleWidth = ns.size(withAttributes: [.font: bodyFont]).width
        if singleWidth <= maxWidth - 2 {
            return bodyLineHeight
        }
        return bodyLineHeight * 2
    }
}

// MARK: - 协调器

extension ClipboardHistoryList {
    @MainActor
    final class Coordinator {
        private static let margin: CGFloat = 8
        private static let rowSpacing: CGFloat = 1
        private static let overscan: CGFloat = 240
        private static let maxReusePool = 12

        private(set) var model: ClipboardPanelModel
        private weak var scrollView: ClipboardHistoryScrollView?
        private weak var documentView: ClipboardHistoryDocumentView?
        private var boundsObserver: NSObjectProtocol?
        private var hoverSubscription: AnyCancellable?

        private var environment: CellEnvironment?
        private var isDisabled = false
        private var opensAbove = false
        private var filter: ClipboardFilter = .all
        private var sourceApp: String?
        private var query = ""
        private var showToken = -1
        private var selection = 0
        private var selectedItemID: UUID?
        private var selectedItemPinned: Bool?
        private var batchIDs: [UUID] = []
        private var showsQuickPasteNumbers = false
        private var hoveredID: UUID?

        private var descriptors: [RowDescriptor] = []
        private var heights: [CGFloat] = []
        private var yOrigins: [CGFloat] = []
        private var topOffset: CGFloat = margin
        private var totalContentHeight: CGFloat = 0
        private var documentHeight: CGFloat = 0
        private var lastLayoutWidth: CGFloat = 0
        private var lastLayoutHeight: CGFloat = 0

        private var previewCache: [UUID: (fingerprint: String, text: String)] = [:]
        private var measuredHeights: [RowHeightKey: CGFloat] = [:]
        private var estimatedHeights: [RowHeightKey: CGFloat] = [:]

        private var activeCells: [Int: CellSlot] = [:]
        private var reusePool: [NSHostingView<ClipboardCellContainer>] = []
        private var visibleIDs: Set<UUID> = []
        private var quickPasteMap: [UUID: Int] = [:]

        private var isUpdatingLayout = false
        private var isInSwiftUIUpdate = false
        private var needsEdgeSnap = true
        private var pendingSelectionScroll = false
        private var userHasScrolled = false
        private var pendingVisibleCommit = false

        private final class CellSlot {
            let view: NSHostingView<ClipboardCellContainer>
            var payload: CellPayload
            var heightKey: RowHeightKey

            init(view: NSHostingView<ClipboardCellContainer>, payload: CellPayload, heightKey: RowHeightKey) {
                self.view = view
                self.payload = payload
                self.heightKey = heightKey
            }
        }

        init(model: ClipboardPanelModel) {
            self.model = model
        }

        func attach(scrollView: ClipboardHistoryScrollView, documentView: ClipboardHistoryDocumentView) {
            self.scrollView = scrollView
            self.documentView = documentView

            scrollView.onLayout = { [weak self] in
                self?.handleViewportLayout()
            }
            scrollView.onScrollWheel = { [weak self] in
                self?.handleScrollWheel()
            }
            documentView.onHoverPoint = { [weak self] point in
                self?.handleHover(at: point)
            }

            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleBoundsDidChange()
                }
            }

            hoverSubscription = model.rowState.$hoveredID.sink { [weak self] newHover in
                self?.handleHoverStateChanged(newHover)
            }
        }

        func detach() {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
                self.boundsObserver = nil
            }
            hoverSubscription?.cancel()
            hoverSubscription = nil
            scrollView?.onLayout = nil
            scrollView?.onScrollWheel = nil
            documentView?.onHoverPoint = nil

            for slot in activeCells.values {
                slot.view.rootView = ClipboardCellContainer(model: model, payload: nil)
                slot.view.removeFromSuperview()
            }
            activeCells.removeAll()
            for view in reusePool {
                view.removeFromSuperview()
            }
            reusePool.removeAll()

            let model = self.model
            if model.isPreviewOpen || model.results.isEmpty {
                DispatchQueue.main.async {
                    if model.isPreviewOpen || model.results.isEmpty {
                        model.updateVisibleRows([])
                    }
                }
            }
        }

        // MARK: - SwiftUI 同步入口

        fileprivate func update(model: ClipboardPanelModel, environment: CellEnvironment, isDisabled: Bool) {
            isInSwiftUIUpdate = true
            defer { isInSwiftUIUpdate = false }

            self.model = model
            let previousEnv = self.environment
            let previousOpensAbove = self.opensAbove
            let previousShowToken = self.showToken
            let previousFilter = self.filter
            let previousSourceApp = self.sourceApp
            let previousQuery = self.query
            let previousSelectedID = self.selectedItemID
            let previousSelectedPinned = self.selectedItemPinned
            let previousBatchIDs = self.batchIDs
            let previousShowsQuick = self.showsQuickPasteNumbers
            let previousDisabled = self.isDisabled
            let previousResults = descriptors.map(\.item)

            self.environment = environment
            self.isDisabled = isDisabled
            self.opensAbove = model.opensAbove
            self.filter = model.filter
            self.sourceApp = model.sourceApp
            self.query = model.query
            self.showToken = model.showToken
            self.selection = model.selection
            self.selectedItemID = model.selectedItem?.id
            self.selectedItemPinned = model.selectedItem?.pinned
            self.batchIDs = model.batchIDs
            self.showsQuickPasteNumbers = model.showsQuickPasteNumbers
            self.hoveredID = model.hoveredID

            let contextReset = (previousShowToken != showToken)
                || (previousOpensAbove != opensAbove)
                || (previousFilter != filter)
                || (previousSourceApp != sourceApp)
                || (previousQuery != query)
            let resultsChanged = previousResults != model.results
                || previousFilter != filter
                || previousQuery != query
            let envChanged = previousEnv != environment
            let selectedItemChanged = previousSelectedID != selectedItemID
                || (previousSelectedID != nil && previousSelectedPinned != selectedItemPinned)
            let decorationChanged = previousBatchIDs != batchIDs
                || previousShowsQuick != showsQuickPasteNumbers
                || previousDisabled != isDisabled

            if envChanged, previousEnv?.dynamicTypeSize != environment.dynamicTypeSize {
                measuredHeights.removeAll(keepingCapacity: true)
                estimatedHeights.removeAll(keepingCapacity: true)
            }

            if resultsChanged {
                rebuildDescriptors(from: model.results)
            }

            if showsQuickPasteNumbers && !isDisabled {
                recomputeQuickPasteMap()
            } else if !quickPasteMap.isEmpty {
                quickPasteMap.removeAll(keepingCapacity: true)
            }

            if contextReset {
                userHasScrolled = false
                needsEdgeSnap = selection == 0
                pendingSelectionScroll = selection > 0
                if previousOpensAbove != opensAbove {
                    recycleAllCells()
                }
            } else if selectedItemChanged {
                pendingSelectionScroll = true
            }

            guard let scrollView else { return }
            let viewport = scrollView.contentView.bounds.size
            if viewport.width <= 1 || viewport.height <= 1 {
                return
            }

            let wasAtBottom = opensAbove && isAtBottom(scrollView: scrollView)
            let widthChanged = abs(viewport.width - lastLayoutWidth) > 0.5
            let heightChanged = abs(viewport.height - lastLayoutHeight) > 0.5

            if resultsChanged || contextReset || widthChanged || heightChanged || envChanged || heights.count != descriptors.count {
                recomputeGeometry(viewportSize: viewport, preserveBottom: wasAtBottom && !contextReset)
            }

            if needsEdgeSnap && selection == 0 {
                pendingSelectionScroll = false
                snapToNearestEdgeAndMeasure()
            } else if pendingSelectionScroll {
                pendingSelectionScroll = false
                scrollSelectionIntoViewAndMeasure()
            } else if resultsChanged || contextReset || envChanged || decorationChanged || widthChanged || heightChanged {
                syncVisibleCells(forceRefreshPayloads: true)
            }
        }

        // MARK: - AppKit 回调

        private func handleViewportLayout() {
            guard !isUpdatingLayout, let scrollView else { return }
            let viewport = scrollView.contentView.bounds.size
            guard viewport.width > 1, viewport.height > 1 else { return }

            let widthChanged = abs(viewport.width - lastLayoutWidth) > 0.5
            let heightChanged = abs(viewport.height - lastLayoutHeight) > 0.5
            guard widthChanged || heightChanged || needsEdgeSnap || pendingSelectionScroll || heights.count != descriptors.count else { return }

            let wasAtBottom = opensAbove && (needsEdgeSnap || !userHasScrolled || isAtBottom(scrollView: scrollView))
            recomputeGeometry(viewportSize: viewport, preserveBottom: wasAtBottom)

            if (needsEdgeSnap || !userHasScrolled) && selection == 0 {
                pendingSelectionScroll = false
                snapToNearestEdgeAndMeasure()
            } else if pendingSelectionScroll {
                pendingSelectionScroll = false
                scrollSelectionIntoViewAndMeasure()
            } else {
                syncVisibleCells(forceRefreshPayloads: widthChanged)
            }
        }

        private func handleScrollWheel() {
            userHasScrolled = true
            needsEdgeSnap = false
            if model.hoveredID != nil {
                model.hoveredID = nil
            }
        }

        private func handleBoundsDidChange() {
            guard !isUpdatingLayout, let scrollView else { return }
            let y = scrollView.contentView.bounds.origin.y
            let edgeY = nearestEdgeOriginY(viewportHeight: scrollView.contentView.bounds.height)
            if abs(y - edgeY) > 1 {
                userHasScrolled = true
                needsEdgeSnap = false
            }
            syncVisibleCells(forceRefreshPayloads: false)
        }

        private func handleHover(at point: CGPoint?) {
            if point == nil, RunLoop.current.currentMode == .eventTracking { return }
            guard !isDisabled, let scrollView, scrollView.window?.isVisible == true else {
                if model.hoveredID != nil { model.hoveredID = nil }
                return
            }
            guard let point, !descriptors.isEmpty else {
                if model.hoveredID != nil { model.hoveredID = nil }
                return
            }
            guard let displayIndex = displayIndex(containingY: point.y) else {
                if model.hoveredID != nil { model.hoveredID = nil }
                return
            }
            let id = descriptor(atDisplay: displayIndex).item.id
            if model.hoveredID != id {
                model.hoveredID = id
            }
        }

        private func handleHoverStateChanged(_ newHover: UUID?) {
            let oldHover = hoveredID
            guard oldHover != newHover else { return }
            hoveredID = newHover
            // 只刷新失去或获得悬停的那一两行，不重建其余可见行。
            for (displayIndex, slot) in activeCells {
                let id = slot.payload.item.id
                if id == oldHover || id == newHover {
                    refreshCell(slot, atDisplay: displayIndex, measureHeight: false)
                }
            }
        }

        // MARK: - 描述符与几何计算

        private func rebuildDescriptors(from results: [ClipboardItem]) {
            let hasPinnedFirst = results.first?.pinned == true
            var newDescriptors: [RowDescriptor] = []
            newDescriptors.reserveCapacity(results.count)
            var activeIDs = Set<UUID>()
            activeIDs.reserveCapacity(results.count)

            for (index, item) in results.enumerated() {
                activeIDs.insert(item.id)
                let title: String?
                if filter != .pinned, hasPinnedFirst {
                    if index == 0 {
                        title = L("已固定")
                    } else if !item.pinned && results[index - 1].pinned {
                        title = L("最近")
                    } else {
                        title = nil
                    }
                } else {
                    title = nil
                }

                let previewText: String
                switch item.kind {
                case .text:
                    if let cached = previewCache[item.id], cached.fingerprint == item.fingerprint {
                        previewText = cached.text
                    } else {
                        let collapsed = ClipboardRow.preview(item.text ?? "")
                        previewCache[item.id] = (item.fingerprint, collapsed)
                        previewText = collapsed
                    }
                case .files:
                    if let cached = previewCache[item.id], cached.fingerprint == item.fingerprint {
                        previewText = cached.text
                    } else {
                        let names = item.fileNames
                        let joined = names.count > 8
                            ? names.prefix(8).joined(separator: "、") + "…"
                            : names.joined(separator: "、")
                        previewCache[item.id] = (item.fingerprint, joined)
                        previewText = joined
                    }
                case .image:
                    previewText = ""
                }

                let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
                let matchedLine: String?
                if item.kind == .image, !trimmedQuery.isEmpty, let text = item.imageText {
                    let lines = text.split(whereSeparator: \.isNewline)
                    matchedLine = (lines.first(where: { $0.localizedCaseInsensitiveContains(trimmedQuery) }) ?? lines.first).map(String.init)
                } else {
                    matchedLine = nil
                }

                newDescriptors.append(RowDescriptor(
                    logicalIndex: index,
                    item: item,
                    groupTitle: title,
                    previewText: previewText,
                    matchedImageLine: matchedLine
                ))
            }

            if previewCache.count > activeIDs.count * 2 + 64 {
                previewCache = previewCache.filter { activeIDs.contains($0.key) }
            }
            let cacheLimit = max(400, model.store.items.count * 2 + 64)
            if measuredHeights.count > cacheLimit || estimatedHeights.count > cacheLimit {
                let liveIDs = Set(model.store.items.map(\.id)).union(activeIDs)
                measuredHeights = measuredHeights.filter { liveIDs.contains($0.key.id) }
                estimatedHeights = estimatedHeights.filter { liveIDs.contains($0.key.id) }
            }
            descriptors = newDescriptors
        }

        private func displayIndex(forLogical logicalIndex: Int) -> Int {
            opensAbove ? (descriptors.count - 1 - logicalIndex) : logicalIndex
        }

        private func logicalIndex(forDisplay displayIndex: Int) -> Int {
            opensAbove ? (descriptors.count - 1 - displayIndex) : displayIndex
        }

        private func descriptor(atDisplay displayIndex: Int) -> RowDescriptor {
            descriptors[logicalIndex(forDisplay: displayIndex)]
        }

        private func rowWidth(for viewportWidth: CGFloat) -> CGFloat {
            max(viewportWidth - Self.margin * 2, 1)
        }

        private func heightKey(for descriptor: RowDescriptor, rowWidth: CGFloat) -> RowHeightKey {
            RowHeightKey(
                id: descriptor.item.id,
                fingerprint: descriptor.item.fingerprint,
                note: descriptor.item.note,
                groupTitle: descriptor.groupTitle,
                isFirstRow: descriptor.logicalIndex == 0,
                matchedImageLine: descriptor.matchedImageLine,
                widthTenths: Int((rowWidth * 10).rounded()),
                dynamicTypeSize: environment?.dynamicTypeSize ?? .large
            )
        }

        private func recomputeGeometry(viewportSize: CGSize, preserveBottom: Bool) {
            guard let scrollView, let documentView else { return }
            isUpdatingLayout = true
            defer { isUpdatingLayout = false }

            let width = viewportSize.width
            let height = viewportSize.height
            let rWidth = rowWidth(for: width)
            let typeSize = environment?.dynamicTypeSize ?? .large
            let count = descriptors.count

            var newHeights = [CGFloat](repeating: 0, count: count)
            for d in 0..<count {
                let desc = descriptor(atDisplay: d)
                let key = heightKey(for: desc, rowWidth: rWidth)
                if let exact = measuredHeights[key] {
                    newHeights[d] = exact
                } else if let est = estimatedHeights[key] {
                    newHeights[d] = est
                } else {
                    let est = ClipboardRowHeightEstimator.estimateHeight(
                        descriptor: desc,
                        rowWidth: rWidth,
                        dynamicTypeSize: typeSize
                    )
                    estimatedHeights[key] = est
                    newHeights[d] = est
                }
            }
            heights = newHeights
            rebuildOffsets(viewportHeight: height)

            lastLayoutWidth = width
            lastLayoutHeight = height

            let clip = scrollView.contentView
            let oldOriginY = clip.bounds.origin.y
            documentView.frame = CGRect(x: 0, y: 0, width: width, height: documentHeight)

            let maxY = maxScrollOriginY(viewportHeight: height)
            let targetY: CGFloat
            if preserveBottom {
                targetY = maxY
            } else {
                targetY = min(max(oldOriginY, 0), maxY)
            }
            if abs(clip.bounds.origin.y - targetY) > 0.5 {
                clip.scroll(to: CGPoint(x: 0, y: targetY))
                scrollView.reflectScrolledClipView(clip)
            }
        }

        private func rebuildOffsets(viewportHeight: CGFloat) {
            let count = heights.count
            guard count > 0 else {
                yOrigins = []
                totalContentHeight = 0
                topOffset = Self.margin
                documentHeight = viewportHeight
                return
            }

            var sum: CGFloat = 0
            for i in 0..<count {
                sum += heights[i]
                if i + 1 < count { sum += Self.rowSpacing }
            }
            totalContentHeight = sum

            let usableHeight = max(0, viewportHeight - Self.margin * 2)
            if sum < usableHeight {
                topOffset = opensAbove ? (viewportHeight - Self.margin - sum) : Self.margin
                documentHeight = viewportHeight
            } else {
                topOffset = Self.margin
                documentHeight = sum + Self.margin * 2
            }

            var origins = [CGFloat](repeating: 0, count: count)
            var y = topOffset
            for i in 0..<count {
                origins[i] = y
                y += heights[i] + Self.rowSpacing
            }
            yOrigins = origins
        }

        private func maxScrollOriginY(viewportHeight: CGFloat) -> CGFloat {
            max(0, documentHeight - viewportHeight)
        }

        private func nearestEdgeOriginY(viewportHeight: CGFloat) -> CGFloat {
            opensAbove ? maxScrollOriginY(viewportHeight: viewportHeight) : 0
        }

        private func isAtBottom(scrollView: ClipboardHistoryScrollView) -> Bool {
            let clip = scrollView.contentView
            let maxY = maxScrollOriginY(viewportHeight: clip.bounds.height)
            return clip.bounds.origin.y >= maxY - 2
        }

        // MARK: - 滚动定位

        private func snapToNearestEdgeAndMeasure() {
            guard let scrollView else { return }
            let clip = scrollView.contentView
            let viewportHeight = clip.bounds.height
            guard viewportHeight > 1 else { return }

            isUpdatingLayout = true
            let edgeY = nearestEdgeOriginY(viewportHeight: viewportHeight)
            clip.scroll(to: CGPoint(x: 0, y: edgeY))
            scrollView.reflectScrolledClipView(clip)
            isUpdatingLayout = false

            syncVisibleCells(forceRefreshPayloads: true)

            // 首屏实测行高可能修正 1–2pt，立刻补齐贴边位置。
            let settledEdgeY = nearestEdgeOriginY(viewportHeight: clip.bounds.height)
            if abs(clip.bounds.origin.y - settledEdgeY) > 0.5 {
                isUpdatingLayout = true
                clip.scroll(to: CGPoint(x: 0, y: settledEdgeY))
                scrollView.reflectScrolledClipView(clip)
                isUpdatingLayout = false
                syncVisibleCells(forceRefreshPayloads: false)
            }
            needsEdgeSnap = false
        }

        private func scrollSelectionIntoViewAndMeasure() {
            if selection == 0 {
                snapToNearestEdgeAndMeasure()
                return
            }
            _ = scrollSelectionIntoView()
            syncVisibleCells(forceRefreshPayloads: true)
            // 首次跳到未测量的行时，若实测行高略有变化，再补齐一次最小滚动确保整行可见。
            if scrollSelectionIntoView() {
                syncVisibleCells(forceRefreshPayloads: false)
            }
        }

        private func scrollSelectionIntoView() -> Bool {
            guard let scrollView, !descriptors.isEmpty else { return false }
            let clip = scrollView.contentView
            let viewportHeight = clip.bounds.height
            guard viewportHeight > 1 else { return false }

            guard descriptors.indices.contains(selection) else { return false }
            let d = displayIndex(forLogical: selection)
            guard heights.indices.contains(d), yOrigins.indices.contains(d) else { return false }

            let rowTop = yOrigins[d]
            let rowBottom = rowTop + heights[d]
            let visibleTop = clip.bounds.minY + Self.margin
            let visibleBottom = clip.bounds.maxY - Self.margin
            let maxY = maxScrollOriginY(viewportHeight: viewportHeight)

            var targetY = clip.bounds.origin.y
            if rowTop < visibleTop {
                targetY = rowTop - Self.margin
            } else if rowBottom > visibleBottom {
                targetY = rowBottom + Self.margin - viewportHeight
            }
            targetY = min(max(targetY, 0), maxY)
            if abs(targetY - clip.bounds.origin.y) > 0.5 {
                userHasScrolled = true
                needsEdgeSnap = false
                isUpdatingLayout = true
                clip.scroll(to: CGPoint(x: 0, y: targetY))
                scrollView.reflectScrolledClipView(clip)
                isUpdatingLayout = false
                return true
            }
            return false
        }

        // MARK: - 虚拟化与实测修正

        private func syncVisibleCells(forceRefreshPayloads: Bool, pass: Int = 0) {
            guard let scrollView, let documentView else { return }
            let clip = scrollView.contentView
            let viewportSize = clip.bounds.size
            guard viewportSize.width > 1, viewportSize.height > 1 else { return }

            let count = descriptors.count
            guard count > 0, heights.count == count, yOrigins.count == count else {
                recycleAllCells()
                updateVisibleTracking(visibleRect: clip.bounds)
                return
            }

            let visibleRect = clip.bounds
            // 即使在触控板弹性越界期间，也保持边缘附近的行处于挂载状态，避免闪白或丢失锚点。
            let clampedMinY = min(max(visibleRect.minY, 0), maxScrollOriginY(viewportHeight: viewportSize.height))
            let clampedMaxY = clampedMinY + viewportSize.height
            let overscanMinY = max(0, clampedMinY - Self.overscan)
            let overscanMaxY = min(documentHeight, clampedMaxY + Self.overscan)

            let activeRange = displayIndexRange(intersectingMinY: overscanMinY, maxY: overscanMaxY)

            // 1. 回收滑出缓冲区的单元。
            for existingIndex in Array(activeCells.keys) where !activeRange.contains(existingIndex) {
                if let slot = activeCells.removeValue(forKey: existingIndex) {
                    recycle(slot.view)
                }
            }

            // 2. 挂载新进入缓冲区的单元并按需测量真实高度。
            let rWidth = rowWidth(for: viewportSize.width)
            var measuredAdjustments: [(displayIndex: Int, oldOriginY: CGFloat, oldHeight: CGFloat, delta: CGFloat)] = []

            for d in activeRange {
                let desc = descriptor(atDisplay: d)
                let key = heightKey(for: desc, rowWidth: rWidth)
                if let slot = activeCells[d] {
                    if forceRefreshPayloads || slot.payload.item != desc.item || slot.heightKey != key {
                        let needsMeasure = slot.heightKey != key && measuredHeights[key] == nil
                        refreshCell(slot, atDisplay: d, measureHeight: needsMeasure)
                        if needsMeasure, let exact = measuredHeights[key], abs(exact - heights[d]) > 0.5 {
                            measuredAdjustments.append((d, yOrigins[d], heights[d], exact - heights[d]))
                        }
                    }
                } else {
                    let payload = makePayload(for: desc, rowWidth: rWidth)
                    let view = dequeueCell(in: documentView)
                    view.rootView = ClipboardCellContainer(model: model, payload: payload)
                    let slot = CellSlot(view: view, payload: payload, heightKey: key)
                    activeCells[d] = slot

                    if measuredHeights[key] == nil {
                        view.frame = CGRect(x: Self.margin, y: yOrigins[d], width: rWidth, height: heights[d])
                        view.layoutSubtreeIfNeeded()
                        let measured = ceil(view.fittingSize.height)
                        if measured > 0, measured.isFinite {
                            measuredHeights[key] = measured
                            if abs(measured - heights[d]) > 0.5 {
                                measuredAdjustments.append((d, yOrigins[d], heights[d], measured - heights[d]))
                            }
                        }
                    }
                }
            }

            // 3. 若有实测高度偏差，一次性更新偏移并保持当前视口视觉锚点不动；若行高变矮露出了新行，补一轮挂载。
            if !measuredAdjustments.isEmpty {
                applyMeasuredAdjustments(measuredAdjustments, scrollView: scrollView, documentView: documentView)
                if pass == 0 {
                    let updatedRect = scrollView.contentView.bounds
                    let updatedMinY = min(max(updatedRect.minY, 0), maxScrollOriginY(viewportHeight: updatedRect.height))
                    let updatedRange = displayIndexRange(
                        intersectingMinY: max(0, updatedMinY - Self.overscan),
                        maxY: min(documentHeight, updatedMinY + updatedRect.height + Self.overscan)
                    )
                    if updatedRange != activeRange {
                        syncVisibleCells(forceRefreshPayloads: false, pass: 1)
                        return
                    }
                }
            }

            // 4. 对齐所有活跃单元的 frame（仅变更时赋值，避免触发重绘）。
            for (d, slot) in activeCells where d < yOrigins.count {
                let frame = CGRect(x: Self.margin, y: yOrigins[d], width: rWidth, height: heights[d])
                if slot.view.frame != frame {
                    slot.view.frame = frame
                }
            }

            // 5. 更新可见行集合与快速粘贴编号。
            updateVisibleTracking(visibleRect: scrollView.contentView.bounds)
        }

        private func applyMeasuredAdjustments(
            _ adjustments: [(displayIndex: Int, oldOriginY: CGFloat, oldHeight: CGFloat, delta: CGFloat)],
            scrollView: ClipboardHistoryScrollView,
            documentView: ClipboardHistoryDocumentView
        ) {
            let clip = scrollView.contentView
            let viewportHeight = clip.bounds.height
            let oldOriginY = clip.bounds.origin.y
            let oldMaxY = maxScrollOriginY(viewportHeight: viewportHeight)
            let wasAtBottom = opensAbove && oldOriginY >= oldMaxY - 1.5 && oldOriginY <= oldMaxY + 1.5
            let wasAtTop = oldOriginY >= -1.5 && oldOriginY <= 1.5
            let isOverscrolling = oldOriginY < -0.5 || oldOriginY > oldMaxY + 0.5

            var aboveDelta: CGFloat = 0
            for adj in adjustments {
                heights[adj.displayIndex] = adj.oldHeight + adj.delta
                if adj.oldOriginY < oldOriginY + 0.5 {
                    aboveDelta += adj.delta
                }
            }

            rebuildOffsets(viewportHeight: viewportHeight)

            isUpdatingLayout = true
            defer { isUpdatingLayout = false }

            documentView.frame = CGRect(x: 0, y: 0, width: viewportSizeWidth(scrollView), height: documentHeight)
            let newMaxY = maxScrollOriginY(viewportHeight: viewportHeight)

            if !isOverscrolling {
                let targetY: CGFloat
                if wasAtBottom {
                    targetY = newMaxY
                } else if wasAtTop {
                    targetY = 0
                } else if abs(aboveDelta) > 0.5 {
                    targetY = min(max(oldOriginY + aboveDelta, 0), newMaxY)
                } else {
                    targetY = min(max(oldOriginY, 0), newMaxY)
                }
                if abs(clip.bounds.origin.y - targetY) > 0.5 {
                    clip.scroll(to: CGPoint(x: 0, y: targetY))
                    scrollView.reflectScrolledClipView(clip)
                }
            }
        }

        private func viewportSizeWidth(_ scrollView: ClipboardHistoryScrollView) -> CGFloat {
            scrollView.contentView.bounds.width
        }

        private func updateVisibleTracking(visibleRect: CGRect) {
            let count = descriptors.count
            var newVisible = Set<UUID>()

            if count > 0, heights.count == count, yOrigins.count == count {
                let range = displayIndexRange(intersectingMinY: visibleRect.minY, maxY: visibleRect.maxY)
                var bestFallback: (id: UUID, overlap: CGFloat)?
                for d in range {
                    let rowRect = CGRect(x: 0, y: yOrigins[d], width: 1, height: heights[d])
                    let overlap = visibleRect.intersection(CGRect(x: visibleRect.minX, y: rowRect.minY, width: max(visibleRect.width, 1), height: rowRect.height)).height
                    let id = descriptor(atDisplay: d).item.id
                    if rowRect.height > 0 && overlap >= rowRect.height / 2 {
                        newVisible.insert(id)
                    }
                    if overlap > (bestFallback?.overlap ?? 0) {
                        bestFallback = (id, overlap)
                    }
                }
                if newVisible.isEmpty, let fallback = bestFallback {
                    newVisible.insert(fallback.id)
                }
            }

            if newVisible != visibleIDs {
                visibleIDs = newVisible
                commitVisibleIDs()
            }

            if showsQuickPasteNumbers && !isDisabled {
                let oldMap = quickPasteMap
                recomputeQuickPasteMap()
                if quickPasteMap != oldMap {
                    for (displayIndex, slot) in activeCells {
                        let id = slot.payload.item.id
                        if oldMap[id] != quickPasteMap[id] {
                            refreshCell(slot, atDisplay: displayIndex, measureHeight: false)
                        }
                    }
                }
            } else if !quickPasteMap.isEmpty {
                quickPasteMap.removeAll(keepingCapacity: true)
            }
        }

        private func recomputeQuickPasteMap() {
            var newMap: [UUID: Int] = [:]
            var number = 1
            for desc in descriptors where visibleIDs.contains(desc.item.id) {
                newMap[desc.item.id] = number
                number += 1
                if number > 9 { break }
            }
            quickPasteMap = newMap
        }

        private func commitVisibleIDs() {
            if isInSwiftUIUpdate {
                guard !pendingVisibleCommit else { return }
                pendingVisibleCommit = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.pendingVisibleCommit = false
                    self.model.updateVisibleRows(self.visibleIDs)
                }
            } else {
                model.updateVisibleRows(visibleIDs)
            }
        }

        // MARK: - 单元复用与更新

        private func dequeueCell(in documentView: NSView) -> NSHostingView<ClipboardCellContainer> {
            if let reused = reusePool.popLast() {
                reused.isHidden = false
                return reused
            }
            let view = NSHostingView(rootView: ClipboardCellContainer(model: model, payload: nil))
            view.sizingOptions = []
            documentView.addSubview(view)
            return view
        }

        private func recycle(_ view: NSHostingView<ClipboardCellContainer>) {
            view.rootView = ClipboardCellContainer(model: model, payload: nil)
            if reusePool.count >= Self.maxReusePool {
                view.removeFromSuperview()
            } else {
                view.isHidden = true
                reusePool.append(view)
            }
        }

        private func recycleAllCells() {
            for slot in activeCells.values {
                recycle(slot.view)
            }
            activeCells.removeAll(keepingCapacity: true)
        }

        private func makePayload(for descriptor: RowDescriptor, rowWidth: CGFloat) -> CellPayload {
            let item = descriptor.item
            let quickActive = showsQuickPasteNumbers && !isDisabled
            let batchIndex = batchIDs.firstIndex(of: item.id).map { $0 + 1 }
            let badge = quickActive ? quickPasteMap[item.id] : batchIndex
            return CellPayload(
                item: item,
                previewText: descriptor.previewText,
                matchedImageLine: descriptor.matchedImageLine,
                groupTitle: descriptor.groupTitle,
                isFirstRow: descriptor.logicalIndex == 0,
                opensAbove: opensAbove,
                isSelected: descriptor.logicalIndex == selection,
                isHovered: hoveredID == item.id,
                badgeNumber: badge,
                badgeIsQuickPaste: quickActive,
                isBatchSelected: batchIndex != nil,
                rowWidth: rowWidth,
                environment: environment ?? CellEnvironment(from: EnvironmentValues(), isEnabled: !isDisabled),
                timeEpoch: showToken
            )
        }

        private func refreshCell(_ slot: CellSlot, atDisplay displayIndex: Int, measureHeight: Bool) {
            guard let scrollView else { return }
            let rWidth = rowWidth(for: scrollView.contentView.bounds.width)
            let desc = descriptor(atDisplay: displayIndex)
            let newPayload = makePayload(for: desc, rowWidth: rWidth)
            let newKey = heightKey(for: desc, rowWidth: rWidth)
            if slot.payload != newPayload {
                slot.payload = newPayload
                slot.heightKey = newKey
                slot.view.rootView = ClipboardCellContainer(model: model, payload: newPayload)
            }
            if measureHeight, measuredHeights[newKey] == nil {
                slot.view.layoutSubtreeIfNeeded()
                let measured = ceil(slot.view.fittingSize.height)
                if measured > 0, measured.isFinite {
                    measuredHeights[newKey] = measured
                }
            }
        }

        // MARK: - 二分查找可见范围

        private func displayIndexRange(intersectingMinY minY: CGFloat, maxY: CGFloat) -> ClosedRange<Int> {
            let count = yOrigins.count
            guard count > 0 else { return 0...0 }

            // 找第一个 bottom > minY 的行。
            var lo = 0
            var hi = count - 1
            var first = count - 1
            while lo <= hi {
                let mid = (lo + hi) >> 1
                if yOrigins[mid] + heights[mid] > minY {
                    first = mid
                    hi = mid - 1
                } else {
                    lo = mid + 1
                }
            }

            // 找最后一个 top < maxY 的行。
            lo = first
            hi = count - 1
            var last = first
            while lo <= hi {
                let mid = (lo + hi) >> 1
                if yOrigins[mid] < maxY {
                    last = mid
                    lo = mid + 1
                } else {
                    hi = mid - 1
                }
            }
            return first...max(first, last)
        }

        private func displayIndex(containingY y: CGFloat) -> Int? {
            let count = yOrigins.count
            guard count > 0 else { return nil }
            var lo = 0
            var hi = count - 1
            while lo <= hi {
                let mid = (lo + hi) >> 1
                let top = yOrigins[mid]
                let bottom = top + heights[mid]
                if y < top {
                    hi = mid - 1
                } else if y > bottom {
                    lo = mid + 1
                } else {
                    return mid
                }
            }
            return nil
        }
    }
}
