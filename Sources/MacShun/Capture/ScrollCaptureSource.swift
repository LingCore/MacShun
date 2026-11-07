// SPDX-License-Identifier: MIT

import AppKit
import ScreenCaptureKit

/// 长截图只取一块屏幕内的选区。输出尺寸和第一个冻结选区使用同一套像素换算。
struct ScrollCaptureRegion {
    let display: CGDirectDisplayID
    let screen: CGRect
    let area: CGRect            // 全局 AppKit 点，用于放置提示和选区框
    let source: CGRect          // ScreenCaptureKit 显示器内左上原点的点
    let width: Int
    let height: Int

    init(display: CGDirectDisplayID, screen: CGRect, photo: CaptureImage, selection: CGRect) {
        self.display = display
        self.screen = screen
        let pixel = photo.pixelRect(selection)
        let sx = screen.width / CGFloat(photo.image.width), sy = screen.height / CGFloat(photo.image.height)
        source = CGRect(x: pixel.minX * sx, y: pixel.minY * sy, width: pixel.width * sx, height: pixel.height * sy)
        area = CGRect(x: screen.minX + source.minX, y: screen.maxY - source.maxY, width: source.width, height: source.height)
        width = Int(pixel.width)
        height = Int(pixel.height)
    }
}

enum ScrollCaptureError: LocalizedError {
    case screenChanged, windowChanged, noImage
    var errorDescription: String? {
        switch self {
        case .screenChanged: L("显示器已更改，请重新截图。")
        case .windowChanged: L("选区里的窗口已改变。")
        case .noImage: L("无法生成图片，请重新选择区域。")
        }
    }
}

struct ScrollCaptureSource {
    typealias Reader = () async throws -> CGImage
    typealias Factory = @MainActor (ScrollCaptureRegion, Set<CGWindowID>) async throws -> Reader

    private struct Target: Equatable {
        let id: CGWindowID
        let bounds: CGRect
    }

    @MainActor static func reader(for region: ScrollCaptureRegion, excluding ids: Set<CGWindowID>) async throws -> Reader {
        let center = ScreenGeometry.axPoint(CGPoint(x: region.area.midX, y: region.area.midY))
        let target = window(at: center)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == region.display }) else { throw ScrollCaptureError.screenChanged }
        // 排除本程序的取景窗和操作条；本程序里其他正在截图的窗口仍可见。
        guard let app = content.applications.first(where: { $0.processID == getpid() }) else { throw ScrollCaptureError.noImage }
        let retained = content.windows.filter { $0.owningApplication?.processID == app.processID && !ids.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingApplications: [app], exceptingWindows: retained)
        if #available(macOS 14.2, *) { filter.includeMenuBar = true }
        let config = SCStreamConfiguration()
        config.sourceRect = region.source
        config.width = region.width
        config.height = region.height
        config.showsCursor = false
        return {
            guard Self.window(at: center) == target else { throw ScrollCaptureError.windowChanged }
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard image.width == region.width, image.height == region.height else { throw ScrollCaptureError.screenChanged }
            guard Self.window(at: center) == target else { throw ScrollCaptureError.windowChanged }
            return image
        }
    }

    private static func window(at point: CGPoint) -> Target? {
        let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        for row in rows ?? [] {
            guard row[kCGWindowLayer as String] as? Int == 0,
                  (row[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let id = row[kCGWindowNumber as String] as? CGWindowID,
                  let dict = row[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict), rect.contains(point) else { continue }
            return Target(id: id, bounds: rect)
        }
        return nil
    }
}
