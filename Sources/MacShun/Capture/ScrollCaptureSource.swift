// SPDX-License-Identifier: MIT

import AppKit
import CoreImage
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
    typealias Frames = AsyncThrowingStream<CGImage, Error>
    typealias Factory = @MainActor (ScrollCaptureRegion, Set<CGWindowID>) async throws -> ScrollCaptureSource

    let frames: Frames
    let stop: @MainActor () -> Void

    static func buffer(width: Int, height: Int) -> (stream: Frames, continuation: Frames.Continuation) {
        // 保留最近的中间帧。大选区按内存预算缩短队列，仍可留下一帧等待拼接。
        let capacity = max(1, min(12, (64 * 1024 * 1024) / (width * height * 4)))
        return Frames.makeStream(bufferingPolicy: .bufferingNewest(capacity))
    }

    private struct Target: Equatable {
        let id: CGWindowID
        let bounds: CGRect
    }

    @MainActor static func stream(for region: ScrollCaptureRegion, excluding ids: Set<CGWindowID>) async throws -> Self {
        guard region.width >= ScrollStitcher.minimumSide, region.height >= ScrollStitcher.minimumSide,
              region.height <= ScrollStitcher.heightLimit,
              region.width <= ScrollStitcher.pixelLimit / region.height else { throw ScrollCaptureError.noImage }
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
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        let buffer = buffer(width: region.width, height: region.height)
        let receiver = ScrollFrameReceiver(width: region.width, height: region.height, frames: buffer.continuation) {
            Self.window(at: center) == target
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: receiver)
        try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: receiver.queue)
        do {
            try await stream.startCapture()
            try Task.checkCancellation()
        } catch {
            buffer.continuation.finish()
            try? stream.removeStreamOutput(receiver, type: .screen)
            try? await stream.stopCapture()
            throw error
        }
        // 等待首帧时显示器可能休眠或拒绝输出，避免控制条一直停在准备中。
        receiver.queue.asyncAfter(deadline: .now() + 3) {
            if !receiver.hasFrame { buffer.continuation.finish(throwing: ScrollCaptureError.noImage) }
        }
        return Self(frames: buffer.stream) {
            buffer.continuation.finish()
            try? stream.removeStreamOutput(receiver, type: .screen)
            Task { try? await stream.stopCapture() }
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

// 可变状态只在 sampleHandlerQueue 上访问。停止回调只结束线程安全的 continuation。
private final class ScrollFrameReceiver: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "MacShun.ScrollCapture.Frames", qos: .userInitiated)
    private let width: Int
    private let height: Int
    private let frames: ScrollCaptureSource.Frames.Continuation
    private let targetIsUnchanged: @Sendable () -> Bool
    private let context = CIContext(options: [.cacheIntermediates: false])
    private(set) var hasFrame = false  // 只在 queue 上访问
    private var lastTargetCheck: Double = 0  // 只在 queue 上访问

    init(width: Int, height: Int, frames: ScrollCaptureSource.Frames.Continuation,
         targetIsUnchanged: @escaping @Sendable () -> Bool) {
        self.width = width
        self.height = height
        self.frames = frames
        self.targetIsUnchanged = targetIsUnchanged
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        autoreleasepool {
            guard type == .screen, sampleBuffer.isValid, let pixels = sampleBuffer.imageBuffer,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[.status] as? Int,
                  let status = SCFrameStatus(rawValue: rawStatus),
                  status == .complete || status == .started else { return }
            // 每秒核对 4 次目标窗口，避免 30Hz 频繁向 WindowServer 拉取全系统窗口列表。
            let now = ProcessInfo.processInfo.systemUptime
            if lastTargetCheck == 0 || now - lastTargetCheck >= 0.25 {
                lastTargetCheck = now
                guard targetIsUnchanged() else { frames.finish(throwing: ScrollCaptureError.windowChanged); return }
            }
            guard CVPixelBufferGetWidth(pixels) == width, CVPixelBufferGetHeight(pixels) == height else {
                frames.finish(throwing: ScrollCaptureError.screenChanged)
                return
            }
            let input = CIImage(cvPixelBuffer: pixels)
            guard let image = context.createCGImage(input, from: input.extent) else {
                frames.finish(throwing: ScrollCaptureError.noImage)
                return
            }
            hasFrame = true
            frames.yield(image)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        frames.finish(throwing: error)
    }
}
