// SPDX-License-Identifier: MIT

import AppKit
import ApplicationServices

/// 取 AX 窗口对应的 CGWindowID（与 WindowElement 保持一致）。
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// 冻结时记录的一个可见顶层窗口或系统浮层目标。
struct CaptureWindowTarget: Equatable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let bundleID: String?
    let ownerName: String?
    let layer: Int
    /// 全局 AX 坐标（主屏左上原点，y 向下）。
    let axFrame: CGRect
    /// 当前屏幕内的 AppKit 坐标（该屏左下原点，y 向上），已裁到屏幕内。
    let localRect: CGRect
    let isChromium: Bool
    let isDock: Bool
    let supportsAXProbe: Bool

    /// 供测试或仅提供局部矩形的调用方构造纯矩形目标。
    static func synthetic(_ localRect: CGRect, id: CGWindowID = 0) -> CaptureWindowTarget {
        CaptureWindowTarget(
            windowID: id,
            ownerPID: 0,
            bundleID: nil,
            ownerName: nil,
            layer: 0,
            axFrame: localRect,
            localRect: localRect,
            isChromium: false,
            isDock: false,
            supportsAXProbe: false
        )
    }
}

/// 原始 WindowServer 窗口描述，便于纯函数过滤与单元测试。
struct CaptureRawWindow: Equatable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let bundleID: String?
    let ownerName: String?
    let name: String?
    let layer: Int
    let alpha: Double
    let bounds: CGRect
    let isChromium: Bool
}

/// 悬停自动选区的候选链计算与控件矩形清洗（参考 WinShun Geometry::hitChain 与 CaptureTools::uiaControls）。
enum CaptureHitChain {
    static let minimumControlSide: CGFloat = 8
    private static let duplicateTolerance: CGFloat = 0.5

    static func rectsNearlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= duplicateTolerance
            && abs(a.minY - b.minY) <= duplicateTolerance
            && abs(a.width - b.width) <= duplicateTolerance
            && abs(a.height - b.height) <= duplicateTolerance
    }

    /// 两个矩形在视觉上几乎重合（1-3pt 描边/内边距包装层，或交并比 >= 0.90），滚轮切换层级时应折叠避免原地打转。
    static func isRedundantLevel(_ a: CGRect, _ b: CGRect, edgeTolerance: CGFloat = 3, iouThreshold: CGFloat = 0.90) -> Bool {
        if abs(a.minX - b.minX) <= edgeTolerance
            && abs(a.minY - b.minY) <= edgeTolerance
            && abs(a.maxX - b.maxX) <= edgeTolerance
            && abs(a.maxY - b.maxY) <= edgeTolerance {
            return true
        }
        let inter = a.intersection(b)
        guard !inter.isNull, !inter.isEmpty else { return false }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        return unionArea > 0 && (interArea / unionArea) >= iouThreshold
    }

    /// 裁切到所属窗口内，过滤过小或与窗口同尺寸的矩形，并去重。
    static func sanitizeControls(_ controls: [CGRect], within window: CGRect) -> [CGRect] {
        var result: [CGRect] = []
        for raw in controls {
            let clipped = raw.intersection(window)
            guard !clipped.isNull, !clipped.isEmpty,
                  clipped.width >= minimumControlSide,
                  clipped.height >= minimumControlSide,
                  !rectsNearlyEqual(clipped, window) else { continue }
            if !result.contains(where: { rectsNearlyEqual($0, clipped) }) {
                result.append(clipped)
            }
        }
        return result
    }

    /// 重叠 AX 分支比较：优先选链中最小有效控件面积，面积相同时更深的一支胜出。
    static func preferChain(_ candidate: [CGRect], over current: [CGRect]) -> Bool {
        func smallestArea(_ chain: [CGRect]) -> CGFloat {
            chain.reduce(CGFloat.greatestFiniteMagnitude) { best, rect in
                guard rect.width >= minimumControlSide, rect.height >= minimumControlSide else { return best }
                return min(best, rect.width * rect.height)
            }
        }
        let next = smallestArea(candidate)
        let previous = smallestArea(current)
        return next < previous || (next == previous && candidate.count > current.count)
    }

    /// 构造某一点下从小到大的候选矩形链：`[最小控件, ..., 容器, 最顶层窗口, 当前整屏]`。
    /// 空白桌面处返回 `[screenBounds]`，保证视觉高亮与点击结果一致。
    static func hitChain(
        windows: [CGRect],
        controlsForWindow: (Int) -> [CGRect],
        at point: CGPoint,
        screenBounds: CGRect,
        windowsOnly: Bool
    ) -> (chain: [CGRect], windowIndex: Int?) {
        guard screenBounds.contains(point) else { return ([], nil) }
        var chain: [CGRect] = []
        func appendUnique(_ rect: CGRect) {
            guard !rect.isEmpty else { return }
            if let last = chain.last, rectsNearlyEqual(last, rect) { return }
            if chain.contains(where: { rectsNearlyEqual($0, rect) }) { return }
            chain.append(rect)
        }

        var matchedIndex: Int?
        for (index, rawWindow) in windows.enumerated() {
            let window = rawWindow.intersection(screenBounds)
            guard !window.isNull, !window.isEmpty, window.contains(point) else { continue }
            matchedIndex = index
            if !windowsOnly {
                var inside: [CGRect] = []
                for control in controlsForWindow(index) {
                    let cut = control.intersection(window)
                    guard !cut.isNull, !cut.isEmpty,
                          cut.width >= minimumControlSide,
                          cut.height >= minimumControlSide,
                          cut.contains(point),
                          !rectsNearlyEqual(cut, window) else { continue }
                    inside.append(cut)
                }
                // Swift 的 Array.sort 是稳定的 Timsort；按 0.1 pt² 量化后的面积从小到大排，
                // 避免交集计算 1e-14 浮点误差把近似重复项排到原始项前面。
                inside.sort {
                    Int(($0.width * $0.height * 10).rounded()) < Int(($1.width * $1.height * 10).rounded())
                }
                for rect in inside {
                    if let last = chain.last, isRedundantLevel(last, rect) { continue }
                    appendUnique(rect)
                }
                while let last = chain.last, isRedundantLevel(last, window, edgeTolerance: 4, iouThreshold: 0.92) {
                    chain.removeLast()
                }
            }
            appendUnique(window)
            break // 最顶层窗口遮住了下层窗口
        }
        appendUnique(screenBounds)
        return (chain, matchedIndex)
    }
}

/// AX 探测门控（镜像 WinShun UiaGate）：单次超时或连续多次空结果的窗口在本轮截图内拉黑，避免卡顿。
struct CaptureAXProbeGate {
    static let budgetMs = 150
    static let emptyLimit = 6

    private struct State {
        var slow = false
        var emptyCount = 0
    }

    private var states: [CGWindowID: State] = [:]

    func allowed(_ windowID: CGWindowID) -> Bool {
        guard let state = states[windowID] else { return true }
        return !state.slow && state.emptyCount < Self.emptyLimit
    }

    func isSlow(_ windowID: CGWindowID) -> Bool {
        states[windowID]?.slow == true
    }

    mutating func record(_ windowID: CGWindowID, elapsedMs: Int, controlCount: Int) {
        var state = states[windowID] ?? State()
        if elapsedMs > Self.budgetMs { state.slow = true }
        state.emptyCount = controlCount > 0 ? 0 : state.emptyCount + 1
        states[windowID] = state
    }

    mutating func reset() {
        states.removeAll()
    }
}

/// 采集冻结时刻的可见窗口与系统浮层，并处理 Chromium/Electron 识别与坐标换算。
enum CaptureWindowSnapshot {
    static let dockBundleID = "com.apple.dock"
    static let notificationCenterBundleID = "com.apple.notificationcenterui"
    static let windowServerOwner = "Window Server"

    private static let chromiumBundlePrefixes: [String] = [
        "com.google.Chrome",
        "org.chromium.",
        "com.microsoft.edgemac",
        "com.brave.Browser",
        "company.thebrowser.",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.",
        "com.microsoft.VSCode",
        "com.visualstudio.code",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.google.antigravity",
        "com.exafunction.windsurf",
        "com.electron.",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "notion.id",
        "com.figma.Desktop",
        "md.obsidian",
        "com.openai.codex",
    ]

    /// 进程路径级别缓存，避免每次截图重复访问文件系统检查 Electron/CEF framework。
    private static let chromiumPathCache = Locked([String: Bool]())

    /// 判断应用是否为 Chromium / Electron（绝不对其发起 AX 树探测，避免触发 VS Code 等进入屏幕阅读器模式；
    /// 仅嵌入 CEF WebView 的原生壳应用如钉钉仍允许走原生 AX 探测）。
    static func isChromiumApp(bundleID: String?, bundleURL: URL? = nil) -> Bool {
        if let bundleID, chromiumBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) {
            return true
        }
        guard let bundleURL else { return false }
        let path = bundleURL.path
        if let cached = chromiumPathCache.withLock({ $0[path] }) { return cached }
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let fm = FileManager.default
        let detected = fm.fileExists(atPath: frameworks.appendingPathComponent("Electron Framework.framework").path)
        chromiumPathCache.update { cache in
            if cache.count > 256 { cache.removeAll() }
            cache[path] = detected
        }
        return detected
    }

    /// 枚举当前屏幕上的原始可见窗口。
    @MainActor static func rawWindows() -> (windows: [CaptureRawWindow], dockPID: pid_t?) {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var appCache: [pid_t: (bundleID: String?, isChromium: Bool)] = [:]
        var dockPID: pid_t?
        var result: [CaptureRawWindow] = []
        result.reserveCapacity(info.count)

        for entry in info {
            guard let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let dict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { continue }
            let alpha = entry[kCGWindowAlpha as String] as? Double ?? 1
            let ownerName = entry[kCGWindowOwnerName as String] as? String
            let name = entry[kCGWindowName as String] as? String

            let appInfo: (bundleID: String?, isChromium: Bool)
            if let cached = appCache[pid] {
                appInfo = cached
            } else {
                let app = NSRunningApplication(processIdentifier: pid)
                let bid = app?.bundleIdentifier
                let computed = (bid, isChromiumApp(bundleID: bid, bundleURL: app?.bundleURL))
                appCache[pid] = computed
                appInfo = computed
            }
            if appInfo.bundleID == dockBundleID, dockPID == nil { dockPID = pid }

            result.append(CaptureRawWindow(
                windowID: id,
                ownerPID: pid,
                bundleID: appInfo.bundleID,
                ownerName: ownerName,
                name: name,
                layer: layer,
                alpha: alpha,
                bounds: bounds,
                isChromium: appInfo.isChromium
            ))
        }
        return (result, dockPID)
    }

    /// 在后台查询程序坞实际可见图标栏（AXList）的全局 AX 矩形；无辅助功能权限或超时返回 nil。
    static func fetchDockBarRect(pid: pid_t) -> CGRect? {
        guard AXIsProcessTrusted(), pid > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        for child in app.axElements(kAXChildrenAttribute) {
            AXUIElementSetMessagingTimeout(child, 0.05)
            guard child.string(kAXRoleAttribute) == kAXListRole as String,
                  let frame = axFrame(of: child),
                  frame.width >= CaptureHitChain.minimumControlSide,
                  frame.height >= CaptureHitChain.minimumControlSide else { continue }
            return frame
        }
        return nil
    }

    /// 将原始窗口列表按屏幕过滤并换算为每块屏幕内的 `CaptureWindowTarget`（保持从前到后的 Z 序）。
    static func targets(
        from raw: [CaptureRawWindow],
        in screenAXFrame: CGRect,
        allScreens: [CGRect],
        excludedWindowIDs: Set<CGWindowID>,
        ownPID: pid_t = getpid(),
        dockBarRect: CGRect? = nil
    ) -> [CaptureWindowTarget] {
        let normalLevel = Int(CGWindowLevelForKey(.normalWindow))
        let dockLevel = Int(CGWindowLevelForKey(.dockWindow))
        let menuBarLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
        let popUpMenuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        let desktopIconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))

        var targets: [CaptureWindowTarget] = []
        var insertedDock = false

        func coversNearlyWholeScreen(_ rect: CGRect) -> Bool {
            allScreens.contains { screen in
                let overlap = rect.intersection(screen)
                guard !overlap.isNull, screen.width > 0, screen.height > 0 else { return false }
                return (overlap.width * overlap.height) >= (screen.width * screen.height) * 0.9
            }
        }

        for window in raw {
            guard !excludedWindowIDs.contains(window.windowID),
                  window.alpha > 0.01,
                  window.bounds.width >= CaptureHitChain.minimumControlSide,
                  window.bounds.height >= CaptureHitChain.minimumControlSide else { continue }

            // 程序坞的 layer 20 窗口在 macOS 上常覆盖整块屏幕，会挡住下层所有普通窗口；
            // 用其实际可见的 AXList 栏矩形替代，放到相同 Z 序位置。
            if window.bundleID == dockBundleID, window.layer == dockLevel {
                if !insertedDock, let dockRect = dockBarRect,
                   let local = localRect(for: dockRect, in: screenAXFrame) {
                    insertedDock = true
                    targets.append(CaptureWindowTarget(
                        windowID: window.windowID,
                        ownerPID: window.ownerPID,
                        bundleID: window.bundleID,
                        ownerName: window.ownerName,
                        layer: window.layer,
                        axFrame: dockRect,
                        localRect: local,
                        isChromium: false,
                        isDock: true,
                        supportsAXProbe: window.ownerPID > 0
                    ))
                }
                // 若程序坞窗口本身不是铺满屏的透明底板，仍按常规窗口保留。
                guard !coversNearlyWholeScreen(window.bounds), !insertedDock else { continue }
            }

            guard isSelectableLayer(
                window,
                normalLevel: normalLevel,
                dockLevel: dockLevel,
                menuBarLevel: menuBarLevel,
                statusLevel: statusLevel,
                popUpMenuLevel: popUpMenuLevel,
                desktopIconLevel: desktopIconLevel,
                coversScreen: { coversNearlyWholeScreen(window.bounds) }
            ) else { continue }

            guard let local = localRect(for: window.bounds, in: screenAXFrame) else { continue }
            let canProbe = !window.isChromium
                && window.ownerPID > 0
                && window.ownerPID != ownPID
                && window.ownerName != windowServerOwner
            targets.append(CaptureWindowTarget(
                windowID: window.windowID,
                ownerPID: window.ownerPID,
                bundleID: window.bundleID,
                ownerName: window.ownerName,
                layer: window.layer,
                axFrame: window.bounds,
                localRect: local,
                isChromium: window.isChromium,
                isDock: window.bundleID == dockBundleID,
                supportsAXProbe: canProbe
            ))
        }
        return targets
    }

    private static func isSelectableLayer(
        _ window: CaptureRawWindow,
        normalLevel: Int,
        dockLevel: Int,
        menuBarLevel: Int,
        statusLevel: Int,
        popUpMenuLevel: Int,
        desktopIconLevel: Int,
        coversScreen: () -> Bool
    ) -> Bool {
        if window.ownerName == windowServerOwner {
            return window.layer == menuBarLevel && (window.name == "Menubar" || window.bounds.height <= 60)
        }
        if window.layer == normalLevel { return true }
        if window.layer > normalLevel && window.layer < dockLevel {
            // 浮窗、模态面板、工具面板等；跳过无名的全屏透明覆盖层。
            return !coversScreen() || window.name?.isEmpty == false
        }
        if window.layer == menuBarLevel {
            return window.bounds.height <= 60
        }
        if window.layer == statusLevel {
            // 控制中心、通知横幅、Spotlight、菜单栏弹出面板；跳过菜单栏里极小的状态图标占位窗。
            return window.bounds.height > 44 && !coversScreen()
        }
        if window.layer == popUpMenuLevel {
            return !coversScreen()
        }
        if window.layer < normalLevel && window.layer >= desktopIconLevel - 10 {
            // 桌面小组件位于桌面图标层，低于所有普通窗口，不会遮挡应用窗口。
            return window.bundleID == notificationCenterBundleID && !coversScreen()
        }
        return false
    }

    static func localRect(for axRect: CGRect, in screenAXFrame: CGRect) -> CGRect? {
        let area = axRect.intersection(screenAXFrame)
        guard !area.isNull, !area.isEmpty else { return nil }
        return CGRect(
            x: area.minX - screenAXFrame.minX,
            y: screenAXFrame.maxY - area.maxY,
            width: area.width,
            height: area.height
        )
    }

    static func axPoint(for localPoint: CGPoint, in screenAXFrame: CGRect) -> CGPoint {
        CGPoint(x: screenAXFrame.minX + localPoint.x, y: screenAXFrame.maxY - localPoint.y)
    }

    fileprivate static func axFrame(of element: AXUIElement) -> CGRect? {
        if let rect: CGRect = element.axValue("AXFrame", type: .cgRect),
           !rect.isNull, rect.width > 0, rect.height > 0 {
            return rect
        }
        if let pos: CGPoint = element.axValue(kAXPositionAttribute, type: .cgPoint),
           let size: CGSize = element.axValue(kAXSizeAttribute, type: .cgSize),
           size.width > 0, size.height > 0 {
            return CGRect(origin: pos, size: size)
        }
        return nil
    }
}

struct CaptureAXProbeCell: Hashable, Sendable {
    let windowID: CGWindowID
    let cellX: Int
    let cellY: Int
}

/// 后台按需 AX 元素探测器：悬停进窗口时在独立队列查询指针下控件链，合并最新请求并严格遵守 150ms / 400 节点预算。
final class CaptureAXProbe: @unchecked Sendable {
    struct Request {
        let displayID: CGDirectDisplayID
        let screenAXFrame: CGRect
        let target: CaptureWindowTarget
        let axPoint: CGPoint
        let cell: CaptureAXProbeCell
    }

    struct Answer {
        let displayID: CGDirectDisplayID
        let windowID: CGWindowID
        let cell: CaptureAXProbeCell
        let localControls: [CGRect]
        let elapsedMs: Int
        let ok: Bool
    }

    private struct SharedState {
        var pending: Request?
        var running = false
        var stopped = false
    }

    private static let maxDepth = 32
    private static let maxElements = 400
    private static let clippingRoles: Set<String> = [
        "AXWindow", "AXScrollArea", "AXSplitGroup", "AXWebArea",
        "AXList", "AXTable", "AXOutline", "AXBrowser", "AXSheet", "AXDrawer",
    ]

    private let queue = DispatchQueue(label: "MacShun.CaptureAXProbe", qos: .userInteractive)
    private let state = Locked(SharedState())
    private var windowCache: [CGWindowID: AXUIElement] = [:]
    private let deliver: @MainActor (Answer) -> Void

    init(deliver: @escaping @MainActor (Answer) -> Void) {
        self.deliver = deliver
    }

    deinit {
        stop()
    }

    func stop() {
        state.update {
            $0.stopped = true
            $0.pending = nil
        }
    }

    /// 请求探测指定窗口内某点下的控件；若前一次请求尚未开始则直接替换为最新位置。
    func ask(_ request: Request) {
        let shouldLaunch = state.update { s -> Bool in
            guard !s.stopped else { return false }
            s.pending = request
            if s.running { return false }
            s.running = true
            return true
        }
        guard shouldLaunch else { return }
        queue.async { [weak self] in self?.drain() }
    }

    private func drain() {
        while true {
            let next: Request? = state.update { s in
                if s.stopped {
                    s.running = false
                    s.pending = nil
                    return nil
                }
                guard let req = s.pending else {
                    s.running = false
                    return nil
                }
                s.pending = nil
                return req
            }
            guard let request = next else {
                windowCache.removeAll()
                return
            }
            let answer = performProbe(request)
            let stopped = state.withLock { $0.stopped }
            if stopped {
                windowCache.removeAll()
                return
            }
            let deliver = self.deliver
            DispatchQueue.main.async { deliver(answer) }
        }
    }

    private func performProbe(_ request: Request) -> Answer {
        let began = CFAbsoluteTimeGetCurrent()
        let deadline = began + Double(CaptureAXProbeGate.budgetMs) / 1000.0
        guard AXIsProcessTrusted() else {
            return Answer(displayID: request.displayID, windowID: request.target.windowID, cell: request.cell, localControls: [], elapsedMs: 0, ok: false)
        }

        let axChain: [CGRect]
        let ok: Bool
        if let fastChain = probeViaHitTest(request, deadline: deadline) {
            axChain = fastChain
            ok = true
        } else if CFAbsoluteTimeGetCurrent() + 0.025 < deadline,
                  let walkChain = probeViaTopDownWalk(request, deadline: deadline) {
            axChain = walkChain
            ok = true
        } else {
            axChain = []
            ok = false
        }

        let elapsedMs = Int(((CFAbsoluteTimeGetCurrent() - began) * 1000).rounded())
        let localRects = axChain.compactMap { CaptureWindowSnapshot.localRect(for: $0, in: request.screenAXFrame) }
        let sanitized = CaptureHitChain.sanitizeControls(localRects, within: request.target.localRect)
        return Answer(
            displayID: request.displayID,
            windowID: request.target.windowID,
            cell: request.cell,
            localControls: sanitized,
            elapsedMs: elapsedMs,
            ok: ok
        )
    }

    /// 快速路径：向目标应用 PID 发单次 AXUIElementCopyElementAtPosition（直接绕过顶层遮罩），再沿父链回溯并按容器裁切。
    private func probeViaHitTest(_ request: Request, deadline: CFAbsoluteTime) -> [CGRect]? {
        let app = AXUIElementCreateApplication(request.target.ownerPID)
        let remaining = max(0.03, Float(deadline - CFAbsoluteTimeGetCurrent()))
        AXUIElementSetMessagingTimeout(app, min(0.12, remaining))

        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(app, Float(request.axPoint.x), Float(request.axPoint.y), &hit)
        guard error == .success, var current = hit else { return nil }

        var nodes: [(frame: CGRect, role: String?)] = []
        var matchedWindowID: CGWindowID = 0
        for _ in 0 ..< Self.maxDepth {
            guard CFAbsoluteTimeGetCurrent() < deadline else { break }
            AXUIElementSetMessagingTimeout(current, 0.05)
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(current, &wid) == .success, wid != 0 { matchedWindowID = wid }
            let role = current.string(kAXRoleAttribute)
            if let frame = CaptureWindowSnapshot.axFrame(of: current) {
                nodes.append((frame, role))
            }
            if role == (kAXWindowRole as String) || role == (kAXApplicationRole as String) { break }
            if request.target.isDock, role == (kAXListRole as String) { break }
            guard let parent = current.axElement(kAXParentAttribute) else { break }
            current = parent
        }

        // 若该应用有多个重叠窗口且命中到另一个窗口，则放弃快速路径改走精确 windowID 下探。
        if !request.target.isDock, matchedWindowID != 0, matchedWindowID != request.target.windowID {
            return nil
        }
        guard !nodes.isEmpty else { return nil }

        // 从外向内裁切，防止滚动视图内部的超大虚拟内容区（如 AXOutline）越出其 AXScrollArea 与窗口边界。
        var clipRect = request.target.axFrame
        var clippedChain: [CGRect] = []
        for node in nodes.reversed() {
            let visible = node.frame.intersection(clipRect)
            guard !visible.isNull, !visible.isEmpty else { continue }
            if let role = node.role, Self.clippingRoles.contains(role), visible.contains(request.axPoint) {
                clipRect = visible
            }
            if visible.contains(request.axPoint) {
                clippedChain.append(visible)
            }
        }
        return clippedChain
    }

    /// 兜底路径：按 windowID 找到窗口根 AXUIElement 后自顶向下遍历子节点（与 WinShun UiaProbe::dive 相同预算与择优策略）。
    private func probeViaTopDownWalk(_ request: Request, deadline: CFAbsoluteTime) -> [CGRect]? {
        guard !request.target.isDock else { return nil }
        guard let root = cachedWindowElement(for: request.target, deadline: deadline) else { return nil }

        var budget = Self.maxElements
        var currentChain: [CGRect] = []
        var bestChain: [CGRect] = []

        func dive(_ element: AXUIElement, clip: CGRect, depth: Int) {
            guard depth < Self.maxDepth, budget > 0, CFAbsoluteTimeGetCurrent() < deadline else { return }
            AXUIElementSetMessagingTimeout(element, 0.06)
            let children = element.axElements(kAXChildrenAttribute)
            var holding: [(AXUIElement, CGRect)] = []
            for child in children.reversed() {
                guard budget > 0, CFAbsoluteTimeGetCurrent() < deadline else { break }
                budget -= 1
                AXUIElementSetMessagingTimeout(child, 0.04)
                guard let rawFrame = CaptureWindowSnapshot.axFrame(of: child) else { continue }
                let visible = rawFrame.intersection(clip)
                guard !visible.isNull, !visible.isEmpty, visible.contains(request.axPoint) else { continue }
                holding.append((child, visible))
            }
            for (child, frame) in holding {
                currentChain.append(frame)
                if CaptureHitChain.preferChain(currentChain, over: bestChain) {
                    bestChain = currentChain
                }
                dive(child, clip: frame, depth: depth + 1)
                currentChain.removeLast()
            }
        }

        dive(root, clip: request.target.axFrame, depth: 0)
        return bestChain
    }

    private func cachedWindowElement(for target: CaptureWindowTarget, deadline: CFAbsoluteTime) -> AXUIElement? {
        if let cached = windowCache[target.windowID] { return cached }
        guard CFAbsoluteTimeGetCurrent() < deadline else { return nil }
        let app = AXUIElementCreateApplication(target.ownerPID)
        AXUIElementSetMessagingTimeout(app, 0.08)
        for window in app.axElements(kAXWindowsAttribute) {
            guard CFAbsoluteTimeGetCurrent() < deadline else { break }
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(window, &wid) == .success, wid == target.windowID {
                windowCache[target.windowID] = window
                return window
            }
        }
        return nil
    }
}
