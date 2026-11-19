// SPDX-License-Identifier: MIT

import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

enum ClipboardImage {
    static func size(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, width > 0,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, height > 0 else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation) ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// 原生 TIFF 可以立即显示和粘贴。后台归档和用户立即请求 PNG 时共用同一个无损编码器。
    static func png(fromTIFF data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var properties: [CFString: Any] = [:]
        if let orientation = metadata?[kCGImagePropertyOrientation] as? Int, orientation != 1 {
            properties[kCGImagePropertyOrientation] = orientation
        }
        for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let dpi = metadata?[key] as? Double, dpi > 0, dpi != 72 { properties[key] = dpi }
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return output as Data
    }
}

@MainActor
final class ClipboardImageCache {
    enum Size: Int { case row = 400, preview = 1024 }

    private let cache = NSCache<NSURL, NSImage>()
    private let queue: OperationQueue
    let size: Size
    private var opening: (key: URL, task: Task<CGImage?, Never>)?

    init(size: Size) {
        cache.totalCostLimit = size == .row ? 16 * 1024 * 1024 : 8 * 1024 * 1024
        queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = size == .row ? 2 : 1
        self.size = size
    }

    /// 面板排版时并行准备选中的图片。每次打开至多提前解码一张，之后由该行接收。
    func prepareForOpening(_ url: URL?) {
        let key = url?.deletingPathExtension()
        guard opening?.key != key else { return }
        opening?.task.cancel()
        opening = nil
        guard let url, let key, cache.object(forKey: key as NSURL) == nil else { return }
        let pixels = size.rawValue
        opening = (key, Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return nil }
            return Self.thumbnail(url, pixels: pixels)
        })
    }

    func load(_ url: URL) async -> NSImage? {
        // TIFF 归档后路径会变，条目 UUID 和图像内容相同。
        let key = url.deletingPathExtension()
        if let image = cache.object(forKey: key as NSURL) { return image }
        var decoded: CGImage?
        if let request = opening, request.key == key {
            decoded = await request.task.value
            if opening?.task == request.task { opening = nil }
        }
        if decoded == nil, !Task.isCancelled { decoded = await decode(url) }
        guard !Task.isCancelled, let cg = decoded else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key as NSURL, cost: cg.bytesPerRow * cg.height)
        return image
    }

    private func decode(_ url: URL) async -> CGImage? {
        let operation = BlockOperation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let result = Locked<CGImage?>(nil)
                let pixels = size.rawValue
                operation.addExecutionBlock {
                    result.set(Self.thumbnail(url, pixels: pixels))
                }
                // 滚出屏幕时即使任务尚未开始，也必须唤醒等待者。
                operation.completionBlock = { continuation.resume(returning: result.get()) }
                queue.addOperation(operation)
            }
        } onCancel: { operation.cancel() }
    }

    private nonisolated static func thumbnail(_ url: URL, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

private final class ClipboardImageState: ObservableObject {
    @Published var image: NSImage?
    @Published var failed = false
}

/// 列表预留最终尺寸；解码完成后只更新当前图片。
struct ClipboardImageView: View {
    let url: URL?
    let cache: ClipboardImageCache
    private var preview: Bool { cache.size == .preview }
    @StateObject private var state = ClipboardImageState()

    var body: some View {
        ZStack {
            if let image = state.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: preview ? .fit : .fill)
                    .accessibilityLabel(L("图片"))
            } else if state.failed {
                Text(preview ? L("图片不可用") : L("图片")).foregroundStyle(.secondary)
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .task(id: url) {
            state.failed = false
            guard let url else {
                state.image = nil
                state.failed = true
                return
            }
            let image = await cache.load(url)
            guard !Task.isCancelled else { return }
            state.image = image
            state.failed = image == nil
        }
        .onDisappear { state.image = nil }
    }
}
