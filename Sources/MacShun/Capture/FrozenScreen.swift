// SPDX-License-Identifier: MIT

import AppKit
import ScreenCaptureKit

struct FrozenScreen {
    let frame: CGRect
    let photo: CaptureImage
    let windowRects: [CGRect]
    var displayID: CGDirectDisplayID = 0

    /// 首次主动截图时系统请求权限。所有屏幕并行取图，选区面板在最后一张完成后才出现。
    @MainActor static func captureAll() async throws -> [FrozenScreen] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let windows = visibleWindowRects()
        let screens = ScreenGeometry.screens()
        guard !screens.isEmpty else { throw CaptureError.noDisplay }
        return try await withThrowingTaskGroup(of: FrozenScreen.self) { group in
            for screen in screens {
                guard let display = content.displays.first(where: { $0.displayID == screen.id }) else {
                    throw CaptureError.noDisplay
                }
                let frame = ScreenGeometry.appKitRect(screen.frame)
                let rects = CaptureImage.localWindows(windows, in: screen.frame)
                let filter = SCContentFilter(display: display, excludingWindows: [])
                if #available(macOS 14.2, *) { filter.includeMenuBar = true }
                let config = SCStreamConfiguration()
                config.width = Int((frame.width * CGFloat(filter.pointPixelScale)).rounded())
                config.height = Int((frame.height * CGFloat(filter.pointPixelScale)).rounded())
                config.showsCursor = false
                group.addTask {
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    return FrozenScreen(frame: frame, photo: CaptureImage(image: image, size: frame.size), windowRects: rects, displayID: screen.id)
                }
            }
            var result: [FrozenScreen] = []
            for try await screen in group { result.append(screen) }
            return result
        }
    }

    private enum CaptureError: LocalizedError {
        case noDisplay
        var errorDescription: String? { L("显示器已更改，请重新截图。") }
    }

    private static func visibleWindowRects() -> [CGRect] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        return (info ?? []).compactMap {
            guard $0[kCGWindowLayer as String] as? Int == 0,
                  ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let dict = $0[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: dict)
        }
    }
}
