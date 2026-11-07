// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// 纵向滚动拼接。只保留已经确定的前缀和最后一帧，两帧的接缝选在移动内容的重叠区内。
struct ScrollStitcher {
    enum Progress: Equatable { case appended, unchanged, backtracked, noOverlap, limit }
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    static let pixelLimit = 32_000_000
    static let heightLimit = 30_000
    static let minimumSide = 32

    private struct Frame {
        let width: Int
        let height: Int
        let pixels: Data
        /// 每行拆成 12 段，每段采 8 个亮度样本。固定侧栏与滚动正文可以分别参与匹配。
        let rows: [UInt8]
        static let bands = 12, samples = 8
        static let stride = bands * samples

        init?(_ image: CGImage) {
            let w = image.width, h = image.height
            guard w >= minimumSide, h >= minimumSide, w <= pixelLimit / h, h <= heightLimit else { return nil }
            var data = Data(count: w * h * 4)
            var signature = [UInt8](repeating: 0, count: h * Self.stride)
            let ok = data.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.setBlendMode(.copy)
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                let px = raw.bindMemory(to: UInt8.self)
                for y in 0..<h {
                    for s in 0..<Self.stride {
                        // 忽略最外缘的滚动条；保留靠左排版的文件名或聊天文字。
                        let x = min(w - 1, (2 * s + 1) * w / (2 * Self.stride))
                        let i = (y * w + x) * 4
                        signature[y * Self.stride + s] = UInt8((Int(px[i]) * 3 + Int(px[i + 1]) * 6 + Int(px[i + 2])) / 10)
                    }
                }
                return true
            }
            guard ok else { return nil }
            width = w
            height = h
            pixels = data
            rows = signature
        }
    }

    private struct Anchor {
        let row: Int, column: Int
    }

    private var previous: Frame
    private var prefix = Data()
    private var start = 0
    private let maximumHeight: Int
    let width: Int
    private(set) var height: Int

    init?(_ image: CGImage, maximumHeight: Int = heightLimit) {
        guard let frame = Frame(image) else { return nil }
        previous = frame
        width = frame.width
        height = frame.height
        self.maximumHeight = min(maximumHeight, Self.heightLimit, Self.pixelLimit / width)
        guard height <= self.maximumHeight else { return nil }
    }

    private func distance(_ a: [UInt8], _ ai: Int, _ b: [UInt8], _ bi: Int) -> Int {
        var total = 0
        for i in 0..<Frame.samples { total += abs(Int(a[ai + i]) - Int(b[bi + i])) }
        return total
    }

    /// 只在相邻帧发生变化且纵向有细节的区域找特征，静止的表头、页脚和大片空白不投票。
    private func anchors(in frame: Frame) -> [Anchor] {
        var result: [Anchor] = []
        let step = max(2, frame.height / 48)
        for top in stride(from: 1, to: frame.height - 1, by: step) {
            var best = 0, winner: Anchor?
            for y in top..<min(top + step, frame.height - 1) {
                for band in 0..<Frame.bands {
                    let col = band * Frame.samples, i = y * Frame.stride + col
                    let change = distance(frame.rows, i, previous.rows, i)
                    guard change > 24 else { continue }
                    let edge = max(distance(frame.rows, i, frame.rows, i - Frame.stride),
                                   distance(frame.rows, i, frame.rows, i + Frame.stride))
                    let score = min(change, edge * 3)
                    if score > max(best, 16) {
                        best = score
                        winner = Anchor(row: y, column: col)
                    }
                }
            }
            if let winner { result.append(winner) }
        }
        return result
    }

    /// 在正反两个方向一起找位移。同样可信的多个周期（如重复表格）宁可等下一帧。
    private func alignment(_ frame: Frame, _ anchors: [Anchor]) -> (shift: Int, seam: Int)? {
        let h = frame.height, maxShift = h - max(16, h / 4)
        var candidates: [(shift: Int, quality: Double)] = []
        for shift in -maxShift...maxShift where shift != 0 {
            var total = 0, matches = 0, agreement = 0, first = h, last = 0
            for a in anchors {
                let old = a.row + shift
                guard old >= 0, old < h else { continue }
                total += 1
                let delta = distance(frame.rows, a.row * Frame.stride + a.column,
                                     previous.rows, old * Frame.stride + a.column)
                if delta <= 48 {
                    matches += 1
                    agreement += 64 - delta
                    first = min(first, a.row)
                    last = max(last, a.row)
                }
            }
            guard matches >= 4, matches * 5 >= total * 4, last - first >= min(28, h / 5) else { continue }
            candidates.append((shift, Double(agreement) / Double(total * 64)))
        }
        guard let strongest = candidates.map(\.quality).max() else { return nil }
        let plausible = candidates.filter { $0.quality > strongest - 0.12 }
        guard !plausible.isEmpty, plausible.count < 100 else { return nil }
        let shift: Int
        if plausible.count == 1 {
            shift = plausible[0].shift
        } else {
            // 等高的文件行可能只有末尾几位数字不同。用原尺寸的变化像素区分候选位移。
            guard let verified = verify(plausible.map(\.shift), frame: frame, anchors: anchors) else { return nil }
            shift = verified
        }

        let matchingRows = anchors.compactMap { a -> Int? in
            let old = a.row + shift
            guard old >= start, old < h,
                  distance(frame.rows, a.row * Frame.stride + a.column,
                           previous.rows, old * Frame.stride + a.column) <= 48 else { return nil }
            return a.row
        }
        if shift < 0 { return (shift, 0) }
        guard !matchingRows.isEmpty else { return nil }
        return (shift, matchingRows[matchingRows.count / 2])
    }

    private func verify(_ shifts: [Int], frame: Frame, anchors: [Anchor]) -> Int? {
        let first = max(0, anchors[0].row - frame.height / 48)
        let last = min(frame.height, anchors[anchors.count - 1].row + frame.height / 48 + 1)
        return previous.pixels.withUnsafeBytes { oldRaw in
            frame.pixels.withUnsafeBytes { newRaw in
                let old = oldRaw.bindMemory(to: UInt8.self), new = newRaw.bindMemory(to: UInt8.self)
                let rowBytes = width * 4
                func difference(_ a: Int, _ b: Int) -> Int {
                    abs(Int(old[a]) - Int(new[b])) + abs(Int(old[a + 1]) - Int(new[b + 1]))
                        + abs(Int(old[a + 2]) - Int(new[b + 2]))
                }
                var changed: [Int] = []
                for y in stride(from: first, to: last, by: max(1, (last - first) / 192)) {
                    for x in stride(from: 1, to: width - 1, by: max(1, width / 384)) {
                        let i = y * rowBytes + x * 4
                        if difference(i, i) > 36 { changed.append(i) }
                    }
                }
                var scores: [(shift: Int, error: Double)] = []
                for shift in shifts {
                    let lower = max(first, first - shift) * rowBytes, upper = min(last, last - shift) * rowBytes
                    var count = 0, error = 0
                    for i in changed where i >= lower && i < upper {
                        error += min(120, difference(i + shift * rowBytes, i))
                        count += 1
                    }
                    if count >= 12 { scores.append((shift, Double(error) / Double(count))) }
                }
                guard let best = scores.min(by: { $0.error < $1.error }), best.error <= 22,
                      !scores.contains(where: { $0.shift != best.shift && $0.error <= best.error * 1.5 + 0.4 })
                else { return nil }
                return best.shift
            }
        }
    }

    mutating func append(_ image: CGImage) -> Progress {
        guard image.width == width, image.height == previous.height, let frame = Frame(image) else { return .noOverlap }
        if frame.rows == previous.rows { return .unchanged }
        let points = anchors(in: frame)
        guard points.count >= 4, let match = alignment(frame, points) else { return .noOverlap }
        guard match.shift > 0 else { return .backtracked }
        guard height + match.shift <= maximumHeight else { return .limit }
        let cut = match.seam + match.shift, bytesPerRow = width * 4
        prefix.append(previous.pixels[start * bytesPerRow..<cut * bytesPerRow])
        height += match.shift
        previous = frame
        start = match.seam
        return .appended
    }

    func result() -> CGImage? {
        var data = prefix
        data.append(previous.pixels[(start * width * 4)...])
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: Self.colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
