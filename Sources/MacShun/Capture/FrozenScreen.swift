// SPDX-License-Identifier: MIT

import AppKit
import ScreenCaptureKit

struct FrozenScreen {
    let frame: CGRect
    let photo: CaptureImage
    let windowRects: [CGRect]
    let windowTargets: [CaptureWindowTarget]
    let axFrame: CGRect
    var displayID: CGDirectDisplayID = 0

    init(
        frame: CGRect,
        photo: CaptureImage,
        windowRects: [CGRect],
        windowTargets: [CaptureWindowTarget] = [],
        axFrame: CGRect? = nil,
        displayID: CGDirectDisplayID = 0
    ) {
        self.frame = frame
        self.photo = photo
        self.windowRects = windowRects
        self.windowTargets = windowTargets.isEmpty
            ? windowRects.enumerated().map { CaptureWindowTarget.synthetic($0.element, id: CGWindowID($0.offset + 1)) }
            : windowTargets
        self.axFrame = axFrame ?? frame
        self.displayID = displayID
    }

    /// 首次主动截图时系统请求权限。所有屏幕并行取图，选区面板在最后一张完成后才出现。
    @MainActor static func captureAll(excludingWindowIDs: Set<CGWindowID> = []) async throws -> [FrozenScreen] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let (rawWindows, dockPID) = CaptureWindowSnapshot.rawWindows()
        let screens = ScreenGeometry.screens()
        guard !screens.isEmpty else { throw CaptureError.noDisplay }
        let allScreenAXFrames = screens.map(\.frame)

        // 与屏幕取图并行读取程序坞真实栏矩形（40ms 上限），不增加截图启动延迟。
        let dockBarTask = Task.detached(priority: .userInitiated) { () -> CGRect? in
            guard let dockPID else { return nil }
            return CaptureWindowSnapshot.fetchDockBarRect(pid: dockPID)
        }

        let captured: [(ScreenGeometry.Screen, CGRect, CaptureImage)] = try await withThrowingTaskGroup(
            of: (ScreenGeometry.Screen, CGRect, CaptureImage).self
        ) { group in
            for screen in screens {
                guard let display = content.displays.first(where: { $0.displayID == screen.id }) else {
                    throw CaptureError.noDisplay
                }
                let frame = ScreenGeometry.appKitRect(screen.frame)
                let filter = SCContentFilter(display: display, excludingWindows: [])
                if #available(macOS 14.2, *) { filter.includeMenuBar = true }
                let config = SCStreamConfiguration()
                config.width = Int((frame.width * CGFloat(filter.pointPixelScale)).rounded())
                config.height = Int((frame.height * CGFloat(filter.pointPixelScale)).rounded())
                config.showsCursor = false
                group.addTask {
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    return (screen, frame, CaptureImage(image: image, size: frame.size))
                }
            }
            var result: [(ScreenGeometry.Screen, CGRect, CaptureImage)] = []
            for try await item in group { result.append(item) }
            return result
        }

        let dockBarRect = await dockBarTask.value
        let ownPID = getpid()
        return captured.map { screen, frame, photo in
            let targets = CaptureWindowSnapshot.targets(
                from: rawWindows,
                in: screen.frame,
                allScreens: allScreenAXFrames,
                excludedWindowIDs: excludingWindowIDs,
                ownPID: ownPID,
                dockBarRect: dockBarRect
            )
            return FrozenScreen(
                frame: frame,
                photo: photo,
                windowRects: targets.map(\.localRect),
                windowTargets: targets,
                axFrame: screen.frame,
                displayID: screen.id
            )
        }
    }

    private enum CaptureError: LocalizedError {
        case noDisplay
        var errorDescription: String? { L("显示器已更改，请重新截图。") }
    }
}
