// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation

/// 从冻结截图的像素画面中自动识别窗口内部可见的 UI 分区与控件区域（侧栏、工具栏、卡片、按钮、输入框、气泡、图片等）。
/// 用于补齐 Electron / Chromium / Qt（微信）/ Flutter / 本进程窗口缺失的 AX 树，并与原生 AX 结果互补。
enum CaptureVisualRegions {
    private struct PixelBox {
        let x0: Int
        let y0: Int
        let x1: Int
        let y1: Int
        let priority: Int // 1 = 结构分割面板（XY-Cut），0 = 闭合矩形框

        var width: Int { x1 - x0 }
        var height: Int { y1 - y0 }
        var area: Int { width * height }
    }

    private struct EdgeRun {
        let coord: Int
        let start: Int
        let end: Int

        var length: Int { end - start }
    }

    /// 检测给定窗口局部区域（AppKit 坐标，左下原点）内的视觉子区域，返回按局部坐标换算并去重后的矩形数组。
    /// 纯计算函数，可安全在后台队列调用。
    static func detect(in photo: CaptureImage, windowLocalRect: CGRect) -> [CGRect] {
        let clippedWindow = windowLocalRect.intersection(photo.bounds)
        guard !clippedWindow.isNull, !clippedWindow.isEmpty,
              clippedWindow.width >= 44, clippedWindow.height >= 44 else { return [] }

        let pixelCrop = photo.pixelRect(clippedWindow)
        guard !pixelCrop.isEmpty, let cropped = photo.image.cropping(to: pixelCrop) else { return [] }

        // 按 1x 逻辑点分辨率采样并封顶 1280px：小窗更快，大窗保持清晰，且 1pt 边框刚好落到 1px。
        let maxDim = 1280.0
        let targetScale = min(1.0, maxDim / Double(max(clippedWindow.width, clippedWindow.height)))
        let w = min(cropped.width, max(1, Int((Double(clippedWindow.width) * targetScale).rounded())))
        let h = min(cropped.height, max(1, Int((Double(clippedWindow.height) * targetScale).rounded())))
        guard w >= 36, h >= 36 else { return [] }

        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: colorSpace, bitmapInfo: bitmapInfo) else {
                return false
            }
            ctx.interpolationQuality = .low
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return [] }

        let pxPerPt = Double(w) / Double(clippedWindow.width)
        let boxes = detectPixelBoxes(rgba: rgba, width: w, height: h, pxPerPt: pxPerPt)
        guard !boxes.isEmpty else { return [] }

        let scaleX = pixelCrop.width / CGFloat(w)
        let scaleY = pixelCrop.height / CGFloat(h)
        var localRects: [CGRect] = []
        localRects.reserveCapacity(boxes.count)
        for box in boxes {
            let pxRect = CGRect(
                x: pixelCrop.minX + CGFloat(box.x0) * scaleX,
                y: pixelCrop.minY + CGFloat(box.y0) * scaleY,
                width: CGFloat(box.width) * scaleX,
                height: CGFloat(box.height) * scaleY
            )
            let local = photo.pointRect(pxRect).intersection(clippedWindow)
            guard !local.isNull, !local.isEmpty,
                  local.width >= 18, local.height >= 16 else { continue }
            localRects.append(local)
        }
        return CaptureHitChain.sanitizeControls(localRects, within: clippedWindow)
    }

    private static func detectPixelBoxes(rgba: [UInt8], width w: Int, height h: Int, pxPerPt: Double) -> [PixelBox] {
        let softThresh = 7   // Pass 1：捕获深色/浅色模式下的细微面板背景色差
        let strongThresh = 10 // Pass 2：捕获卡片、按钮、输入框、图片、气泡边框

        // 构建水平边缘（行间色差）与垂直边缘（列间色差）的前缀和。
        // horizSoftPref / horizStrongPref：按行存放，维度 h × (w + 1)
        // vertSoftPref / vertStrongPref：按列存放，维度 w × (h + 1)，查垂直段覆盖率缓存友好
        var horizSoftPref = [Int32](repeating: 0, count: h * (w + 1))
        var horizStrongPref = [Int32](repeating: 0, count: h * (w + 1))
        var vertSoftPref = [Int32](repeating: 0, count: w * (h + 1))
        var vertStrongPref = [Int32](repeating: 0, count: w * (h + 1))
        var horizStrong = [UInt8](repeating: 0, count: w * h)
        var vertStrong = [UInt8](repeating: 0, count: w * h)

        rgba.withUnsafeBufferPointer { px in
            horizSoftPref.withUnsafeMutableBufferPointer { hsP in
                horizStrongPref.withUnsafeMutableBufferPointer { hP in
                    vertSoftPref.withUnsafeMutableBufferPointer { vsP in
                        vertStrongPref.withUnsafeMutableBufferPointer { vP in
                            horizStrong.withUnsafeMutableBufferPointer { hEdge in
                                vertStrong.withUnsafeMutableBufferPointer { vEdge in
                                    let rowStride = w * 4
                                    let hpStride = w + 1
                                    let vpStride = h + 1

                                    for y in 0 ..< h {
                                        let rowBase = y * rowStride
                                        let prevRowBase = (y - 1) * rowStride
                                        let hpRow = y * hpStride
                                        let edgeRow = y * w
                                        var hsAcc: Int32 = 0
                                        var hAcc: Int32 = 0

                                        for x in 0 ..< w {
                                            let i = rowBase + x * 4
                                            let r = Int(px[i])
                                            let g = Int(px[i + 1])
                                            let b = Int(px[i + 2])

                                            if y > 0 {
                                                let u = prevRowBase + x * 4
                                                let diff = max(abs(r - Int(px[u])),
                                                               max(abs(g - Int(px[u + 1])), abs(b - Int(px[u + 2]))))
                                                if diff >= softThresh {
                                                    hsAcc += 1
                                                    if diff >= strongThresh {
                                                        hAcc += 1
                                                        hEdge[edgeRow + x] = 1
                                                    }
                                                }
                                            }
                                            hsP[hpRow + x + 1] = hsAcc
                                            hP[hpRow + x + 1] = hAcc

                                            if x > 0 {
                                                let l = i - 4
                                                let diff = max(abs(r - Int(px[l])),
                                                               max(abs(g - Int(px[l + 1])), abs(b - Int(px[l + 2]))))
                                                if diff >= softThresh {
                                                    vsP[x * vpStride + y + 1] = 1
                                                    if diff >= strongThresh {
                                                        vP[x * vpStride + y + 1] = 1
                                                        vEdge[edgeRow + x] = 1
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    // 完成列方向前缀和累加
                                    for x in 1 ..< w {
                                        let colBase = x * vpStride
                                        var vsAcc: Int32 = 0
                                        var vAcc: Int32 = 0
                                        for y in 1 ... h {
                                            vsAcc += vsP[colBase + y]
                                            vsP[colBase + y] = vsAcc
                                            vAcc += vP[colBase + y]
                                            vP[colBase + y] = vAcc
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        @inline(__always)
        func hSoftCov(_ y: Int, _ x0: Int, _ x1: Int) -> Double {
            guard y > 0, y < h, x1 > x0 else { return 0 }
            let row = y * (w + 1)
            return Double(horizSoftPref[row + x1] - horizSoftPref[row + x0]) / Double(x1 - x0)
        }

        @inline(__always)
        func vSoftCov(_ x: Int, _ y0: Int, _ y1: Int) -> Double {
            guard x > 0, x < w, y1 > y0 else { return 0 }
            let col = x * (h + 1)
            return Double(vertSoftPref[col + y1] - vertSoftPref[col + y0]) / Double(y1 - y0)
        }

        @inline(__always)
        func hStrongCov(_ y: Int, _ x0: Int, _ x1: Int) -> Double {
            guard y > 0, y < h, x1 > x0 else { return 0 }
            let row = y * (w + 1)
            return Double(horizStrongPref[row + x1] - horizStrongPref[row + x0]) / Double(x1 - x0)
        }

        @inline(__always)
        func vStrongCov(_ x: Int, _ y0: Int, _ y1: Int) -> Double {
            guard x > 0, x < w, y1 > y0 else { return 0 }
            let col = x * (h + 1)
            return Double(vertStrongPref[col + y1] - vertStrongPref[col + y0]) / Double(y1 - y0)
        }

        let minPane = max(14, Int((20.0 * pxPerPt).rounded()))
        let minBoxW = max(14, Int((20.0 * pxPerPt).rounded()))
        let minBoxH = max(12, Int((18.0 * pxPerPt).rounded()))
        let windowArea = Double(w * h)
        var rawBoxes: [PixelBox] = []
        rawBoxes.reserveCapacity(192)

        // MARK: Pass 1 — 递归 XY-Cut 面板分割（侧栏、顶栏、标签栏、编辑区、输入栏、状态栏等）

        func findSplits(in rangeStart: Int, end rangeEnd: Int, minGap: Int, coverage: (Int) -> Double) -> [(pos: Int, cov: Double)] {
            guard rangeEnd - rangeStart >= minGap * 2 else { return [] }
            var candidates: [(pos: Int, cov: Double)] = []
            for p in (rangeStart + minGap) ... (rangeEnd - minGap) {
                let c = coverage(p)
                if c >= 0.80 {
                    candidates.append((p, c))
                }
            }
            guard !candidates.isEmpty else { return [] }

            // 合并 3px 内的相邻双边（例如 1px 分割线会产生上下两条梯度）
            var clustered: [(pos: Int, cov: Double)] = []
            var best = candidates[0]
            var lastPos = candidates[0].pos
            for item in candidates.dropFirst() {
                if item.pos - lastPos <= 3 {
                    if item.cov > best.cov { best = item }
                } else {
                    clustered.append(best)
                    best = item
                }
                lastPos = item.pos
            }
            clustered.append(best)

            // 过滤彼此间距过小的分割线，保留覆盖率更高者
            var filtered: [(pos: Int, cov: Double)] = []
            for item in clustered {
                if let prev = filtered.last, item.pos - prev.pos < minGap {
                    if item.cov > prev.cov {
                        filtered[filtered.count - 1] = item
                    }
                } else {
                    filtered.append(item)
                }
            }
            // 同轴分割过多（如斑马纹表格/密集分隔线）则跳过该轴，避免切碎列表。
            return filtered.count <= 9 ? filtered : []
        }

        var leafPanes: [PixelBox] = []
        leafPanes.reserveCapacity(16)

        func xyCut(x0: Int, y0: Int, x1: Int, y1: Int, depth: Int) {
            guard depth < 5, x1 - x0 >= minPane * 2 || y1 - y0 >= minPane * 2 else {
                leafPanes.append(PixelBox(x0: x0, y0: y0, x1: x1, y1: y1, priority: 1))
                return
            }
            let insetX = min(6, (x1 - x0) / 10)
            let insetY = min(6, (y1 - y0) / 10)
            let hSplits = findSplits(in: y0, end: y1, minGap: minPane) { y in
                hSoftCov(y, x0 + insetX, x1 - insetX)
            }
            let vSplits = findSplits(in: x0, end: x1, minGap: minPane) { x in
                vSoftCov(x, y0 + insetY, y1 - insetY)
            }
            if hSplits.isEmpty && vSplits.isEmpty {
                leafPanes.append(PixelBox(x0: x0, y0: y0, x1: x1, y1: y1, priority: 1))
                return
            }

            let hPeak = hSplits.map(\.cov).max() ?? 0
            let vPeak = vSplits.map(\.cov).max() ?? 0
            let splitHorizontal: Bool
            if hSplits.isEmpty {
                splitHorizontal = false
            } else if vSplits.isEmpty {
                splitHorizontal = true
            } else if abs(hPeak - vPeak) > 0.03 {
                splitHorizontal = hPeak > vPeak
            } else {
                splitHorizontal = hSplits.count <= vSplits.count
            }

            if splitHorizontal {
                var cuts = [y0]
                cuts.append(contentsOf: hSplits.map(\.pos))
                cuts.append(y1)
                for idx in 0 ..< (cuts.count - 1) {
                    let cy0 = cuts[idx], cy1 = cuts[idx + 1]
                    guard cy1 - cy0 >= minPane else { continue }
                    rawBoxes.append(PixelBox(x0: x0, y0: cy0, x1: x1, y1: cy1, priority: 1))
                    xyCut(x0: x0, y0: cy0, x1: x1, y1: cy1, depth: depth + 1)
                }
            } else {
                var cuts = [x0]
                cuts.append(contentsOf: vSplits.map(\.pos))
                cuts.append(x1)
                for idx in 0 ..< (cuts.count - 1) {
                    let cx0 = cuts[idx], cx1 = cuts[idx + 1]
                    guard cx1 - cx0 >= minPane else { continue }
                    rawBoxes.append(PixelBox(x0: cx0, y0: y0, x1: cx1, y1: y1, priority: 1))
                    xyCut(x0: cx0, y0: y0, x1: cx1, y1: y1, depth: depth + 1)
                }
            }
        }

        xyCut(x0: 0, y0: 0, x1: w, y1: h, depth: 0)

        // MARK: Pass 2 — 闭合矩形 / 圆角矩形 / 胶囊按钮检测

        let minRun = max(12, Int((16.0 * pxPerPt).rounded()))
        let maxBridge = 1
        let collapseDist = max(2, Int((2.5 * pxPerPt).rounded()))
        let collapseEndTol = max(3, Int((4.0 * pxPerPt).rounded()))

        func extractHorizontalRuns() -> [EdgeRun] {
            var runs: [EdgeRun] = []
            runs.reserveCapacity(512)
            for y in 1 ..< h {
                let row = y * w
                var x = 0
                while x < w {
                    if horizStrong[row + x] == 0 {
                        x += 1
                        continue
                    }
                    let start = x
                    var end = x + 1
                    var gap = 0
                    var cursor = x + 1
                    while cursor < w {
                        if horizStrong[row + cursor] != 0 {
                            end = cursor + 1
                            gap = 0
                        } else {
                            gap += 1
                            if gap > maxBridge { break }
                        }
                        cursor += 1
                    }
                    if end - start >= minRun {
                        runs.append(EdgeRun(coord: y, start: start, end: end))
                    }
                    x = cursor
                }
            }
            return collapseParallelRuns(runs, maxCoordGap: collapseDist, endTol: collapseEndTol)
        }

        func extractVerticalRuns() -> [EdgeRun] {
            var runs: [EdgeRun] = []
            runs.reserveCapacity(512)
            for x in 1 ..< w {
                var y = 0
                while y < h {
                    if vertStrong[y * w + x] == 0 {
                        y += 1
                        continue
                    }
                    let start = y
                    var end = y + 1
                    var gap = 0
                    var cursor = y + 1
                    while cursor < h {
                        if vertStrong[cursor * w + x] != 0 {
                            end = cursor + 1
                            gap = 0
                        } else {
                            gap += 1
                            if gap > maxBridge { break }
                        }
                        cursor += 1
                    }
                    if end - start >= minRun {
                        runs.append(EdgeRun(coord: x, start: start, end: end))
                    }
                    y = cursor
                }
            }
            return collapseParallelRuns(runs, maxCoordGap: collapseDist, endTol: collapseEndTol)
        }

        var hRuns = extractHorizontalRuns()
        var vRuns = extractVerticalRuns()
        if hRuns.count > 900 {
            hRuns = Array(hRuns.sorted { $0.length > $1.length }.prefix(900))
        }
        if vRuns.count > 900 {
            vRuns = Array(vRuns.sorted { $0.length > $1.length }.prefix(900))
        }

        let pairEndTol = max(4, Int((8.0 * pxPerPt).rounded()))
        let maxCornerR = max(6, Int((22.0 * pxPerPt).rounded()))

        func findHorizontalCap(near edgeY: Int, outwardStep: Int, x0: Int, x1: Int, maxRadius: Int) -> Int? {
            var fallback: Int?
            // 先允许 2px 向内误差，再向外扩展扫描圆角半径，优先命中第一条清晰顶/底边避免跳到上方无关分隔线。
            for delta in -2 ... maxRadius {
                let y = edgeY + outwardStep * delta
                guard y > 0, y < h else { continue }
                let inset = max(0, delta)
                let sx0 = x0 + inset
                let sx1 = x1 - inset
                guard sx1 - sx0 >= 6 else { break }
                let cov = hStrongCov(y, sx0, sx1)
                if cov >= 0.78 {
                    let nextY = y + outwardStep
                    if nextY > 0, nextY < h, hStrongCov(nextY, sx0, sx1) > cov {
                        return nextY
                    }
                    return y
                }
                if fallback == nil, cov >= 0.68 {
                    fallback = y
                }
            }
            return fallback
        }

        func findVerticalCap(near edgeX: Int, outwardStep: Int, y0: Int, y1: Int, maxRadius: Int) -> Int? {
            var fallback: Int?
            for delta in -2 ... maxRadius {
                let x = edgeX + outwardStep * delta
                guard x > 0, x < w else { continue }
                let inset = max(0, delta)
                let sy0 = y0 + inset
                let sy1 = y1 - inset
                guard sy1 - sy0 >= 6 else { break }
                let cov = vStrongCov(x, sy0, sy1)
                if cov >= 0.78 {
                    let nextX = x + outwardStep
                    if nextX > 0, nextX < w, vStrongCov(nextX, sy0, sy1) > cov {
                        return nextX
                    }
                    return x
                }
                if fallback == nil, cov >= 0.68 {
                    fallback = x
                }
            }
            return fallback
        }

        func hasPillArc(capX: Int, y0: Int, y1: Int, outwardSign: Int) -> Bool {
            let bh = y1 - y0
            let r = Double(bh) / 2.0
            let centerY = Double(y0) + r
            let centerX = Double(capX) - Double(outwardSign) * r
            var hits = 0
            var outMinR = 255, outMaxR = 0
            var outMinG = 255, outMaxG = 0
            var outMinB = 255, outMaxB = 0
            var samples = 0
            // 沿半圆弧取 5 个采样角：要求弧内外存在稳定色差，且弧外背景颜色一致（排除两行文字误触）。
            let angles: [Double] = [-1.05, -0.55, 0.0, 0.55, 1.05]
            for angle in angles {
                let ax = centerX + Double(outwardSign) * cos(angle) * r
                let ay = centerY + sin(angle) * r
                let inX = Int((ax - Double(outwardSign) * 2.0).rounded())
                let outX = Int((ax + Double(outwardSign) * 2.0).rounded())
                let py = Int(ay.rounded())
                guard inX >= 0, inX < w, outX >= 0, outX < w, py >= 0, py < h else { continue }
                let i1 = (py * w + inX) * 4
                let i2 = (py * w + outX) * 4
                let oR = Int(rgba[i2]), oG = Int(rgba[i2 + 1]), oB = Int(rgba[i2 + 2])
                outMinR = min(outMinR, oR); outMaxR = max(outMaxR, oR)
                outMinG = min(outMinG, oG); outMaxG = max(outMaxG, oG)
                outMinB = min(outMinB, oB); outMaxB = max(outMaxB, oB)
                samples += 1
                let diff = max(abs(Int(rgba[i1]) - oR),
                               max(abs(Int(rgba[i1 + 1]) - oG),
                                   abs(Int(rgba[i1 + 2]) - oB)))
                if diff >= strongThresh { hits += 1 }
            }
            guard samples >= 4, hits >= 4 else { return false }
            let outSpread = max(outMaxR - outMinR, max(outMaxG - outMinG, outMaxB - outMinB))
            return outSpread <= 22
        }

        func appendCandidateBox(x0: Int, y0: Int, x1: Int, y1: Int) {
            let bw = x1 - x0
            let bh = y1 - y0
            guard bw >= minBoxW, bh >= minBoxH else { return }
            if Double(bw * bh) >= windowArea * 0.94 { return }
            let ratio = Double(max(bw, bh)) / Double(min(bw, bh))
            if ratio > 32.0 { return }
            rawBoxes.append(PixelBox(x0: x0, y0: y0, x1: x1, y1: y1, priority: 0))
        }

        // 2a. 成对竖边 -> 查找上下横边（覆盖卡片、侧栏、聊天窗、图片、代码块、弹窗）
        vRuns.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        for i in 0 ..< vRuns.count {
            let a = vRuns[i]
            var j = i + 1
            while j < vRuns.count {
                let b = vRuns[j]
                if b.start - a.start > pairEndTol { break }
                if abs(a.end - b.end) <= pairEndTol {
                    let x0 = min(a.coord, b.coord)
                    let x1 = max(a.coord, b.coord)
                    let bw = x1 - x0
                    if bw >= minBoxW {
                        let yTop = min(a.start, b.start)
                        let yBot = max(a.end, b.end)
                        let maxR = min(maxCornerR, bw / 3)
                        if let topY = findHorizontalCap(near: yTop, outwardStep: -1, x0: x0, x1: x1, maxRadius: maxR),
                           let botY = findHorizontalCap(near: yBot, outwardStep: 1, x0: x0, x1: x1, maxRadius: maxR) {
                            appendCandidateBox(x0: x0, y0: topY, x1: x1, y1: botY)
                        }
                    }
                }
                j += 1
            }
        }

        // 2b. 成对横边 -> 查找左右竖边（或胶囊半圆端帽，覆盖搜索框、地址栏、按钮、聊天气泡、横幅）
        let maxPillHeight = max(20, Int((56.0 * pxPerPt).rounded()))
        hRuns.sort { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        for i in 0 ..< hRuns.count {
            let a = hRuns[i]
            var j = i + 1
            while j < hRuns.count {
                let b = hRuns[j]
                if b.start - a.start > pairEndTol { break }
                if abs(a.end - b.end) <= pairEndTol {
                    let y0 = min(a.coord, b.coord)
                    let y1 = max(a.coord, b.coord)
                    let bh = y1 - y0
                    if bh >= minBoxH {
                        let xLeft = min(a.start, b.start)
                        let xRight = max(a.end, b.end)
                        let maxR = min(maxCornerR, bh / 2)
                        if let leftX = findVerticalCap(near: xLeft, outwardStep: -1, y0: y0, y1: y1, maxRadius: maxR),
                           let rightX = findVerticalCap(near: xRight, outwardStep: 1, y0: y0, y1: y1, maxRadius: maxR) {
                            appendCandidateBox(x0: leftX, y0: y0, x1: rightX, y1: y1)
                        } else if bh <= maxPillHeight,
                                  hStrongCov(y0, xLeft, xRight) >= 0.86,
                                  hStrongCov(y1, xLeft, xRight) >= 0.86 {
                            let r = bh / 2
                            let leftX = xLeft - r
                            let rightX = xRight + r
                            if leftX >= 0, rightX <= w,
                               hasPillArc(capX: leftX, y0: y0, y1: y1, outwardSign: -1),
                               hasPillArc(capX: rightX, y0: y0, y1: y1, outwardSign: 1) {
                                appendCandidateBox(x0: leftX, y0: y0, x1: rightX, y1: y1)
                            }
                        }
                    }
                }
                j += 1
            }
        }

        // MARK: Pass 3 — 纯色背景叶面板内的无边框内容块补检（无边框图片、二维码、图表、独立段落）
        detectBorderlessIslands(
            rgba: rgba,
            width: w,
            height: h,
            pxPerPt: pxPerPt,
            leafPanes: leafPanes,
            into: &rawBoxes
        )

        return deduplicateBoxes(rawBoxes, width: w, height: h, pxPerPt: pxPerPt)
    }

    /// 在具有明显统一底色的叶面板中，按 8pt 粗网格连通块检出无边框图片、图表、二维码和独立内容块，并精确收缩到像素边界。
    private static func detectBorderlessIslands(
        rgba: [UInt8],
        width w: Int,
        height h: Int,
        pxPerPt: Double,
        leafPanes: [PixelBox],
        into rawBoxes: inout [PixelBox]
    ) {
        let minPaneW = max(80, Int((120.0 * pxPerPt).rounded()))
        let minPaneH = max(60, Int((90.0 * pxPerPt).rounded()))
        let minIslandW = max(36, Int((52.0 * pxPerPt).rounded()))
        let minIslandH = max(32, Int((44.0 * pxPerPt).rounded()))
        let cell = max(5, Int((7.5 * pxPerPt).rounded()))
        let bgDiffThresh = 15
        let edgeTightThresh = 12
        let padPx = max(1, Int((2.0 * pxPerPt).rounded()))

        rgba.withUnsafeBufferPointer { px in
            @inline(__always)
            func differsFromBG(_ x: Int, _ y: Int, _ bgR: Int, _ bgG: Int, _ bgB: Int, _ thresh: Int) -> Bool {
                let i = (y * w + x) * 4
                let dr = abs(Int(px[i]) - bgR)
                if dr >= thresh { return true }
                let dg = abs(Int(px[i + 1]) - bgG)
                if dg >= thresh { return true }
                return abs(Int(px[i + 2]) - bgB) >= thresh
            }

            for pane in leafPanes {
                guard pane.width >= minPaneW, pane.height >= minPaneH else { continue }
                let inset = max(3, Int((4.0 * pxPerPt).rounded()))
                let px0 = pane.x0 + inset
                let py0 = pane.y0 + inset
                let px1 = pane.x1 - inset
                let py1 = pane.y1 - inset
                guard px1 - px0 >= minPaneW / 2, py1 - py0 >= minPaneH / 2 else { continue }

                // 8×8 网格采样，判断该面板是否存在明确的纯色底色（主色桶占比 >= 44%）
                var buckets: [Int: (count: Int, sumR: Int, sumG: Int, sumB: Int)] = [:]
                buckets.reserveCapacity(32)
                for sy in 0 ..< 8 {
                    let y = py0 + (sy * (py1 - py0 - 1)) / 7
                    for sx in 0 ..< 8 {
                        let x = px0 + (sx * (px1 - px0 - 1)) / 7
                        let i = (y * w + x) * 4
                        let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
                        let key = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3)
                        if var entry = buckets[key] {
                            entry.count += 1
                            entry.sumR += r; entry.sumG += g; entry.sumB += b
                            buckets[key] = entry
                        } else {
                            buckets[key] = (1, r, g, b)
                        }
                    }
                }
                guard let modal = buckets.values.max(by: { $0.count < $1.count }), modal.count >= 28 else { continue }
                let bgR = modal.sumR / modal.count
                let bgG = modal.sumG / modal.count
                let bgB = modal.sumB / modal.count

                let pw = px1 - px0
                let ph = py1 - py0
                let gxCount = (pw + cell - 1) / cell
                let gyCount = (ph + cell - 1) / cell
                guard gxCount >= 4, gyCount >= 4, gxCount * gyCount <= 40_000 else { continue }

                var occ = [UInt8](repeating: 0, count: gxCount * gyCount)
                for gy in 0 ..< gyCount {
                    let cy0 = py0 + gy * cell
                    let cy1 = min(py1, cy0 + cell)
                    for gx in 0 ..< gxCount {
                        let cx0 = px0 + gx * cell
                        let cx1 = min(px1, cx0 + cell)
                        var hits = 0
                        var total = 0
                        var y = cy0
                        while y < cy1 {
                            var x = cx0
                            while x < cx1 {
                                total += 1
                                if differsFromBG(x, y, bgR, bgG, bgB, bgDiffThresh) { hits += 1 }
                                x += 2
                            }
                            y += 2
                        }
                        if total > 0 && hits * 8 >= total {
                            occ[gy * gxCount + gx] = 1
                        }
                    }
                }

                // 8 连通分量聚类：同一块图片/卡片/段落的紧邻行自动合并，留白 >= 8pt 的独立块自然分离
                var visited = [UInt8](repeating: 0, count: gxCount * gyCount)
                var queue: [Int] = []
                queue.reserveCapacity(256)
                let paneArea = Double(pane.area)

                for startIdx in 0 ..< occ.count {
                    guard occ[startIdx] != 0, visited[startIdx] == 0 else { continue }
                    visited[startIdx] = 1
                    queue.removeAll(keepingCapacity: true)
                    queue.append(startIdx)
                    var head = 0
                    var minGX = startIdx % gxCount, maxGX = minGX
                    var minGY = startIdx / gxCount, maxGY = minGY

                    while head < queue.count {
                        let cur = queue[head]
                        head += 1
                        let gx = cur % gxCount
                        let gy = cur / gxCount
                        if gx < minGX { minGX = gx }
                        if gx > maxGX { maxGX = gx }
                        if gy < minGY { minGY = gy }
                        if gy > maxGY { maxGY = gy }

                        let ny0 = max(0, gy - 1), ny1 = min(gyCount - 1, gy + 1)
                        let nx0 = max(0, gx - 1), nx1 = min(gxCount - 1, gx + 1)
                        for ny in ny0 ... ny1 {
                            let rowOff = ny * gxCount
                            for nx in nx0 ... nx1 {
                                let nIdx = rowOff + nx
                                if occ[nIdx] != 0 && visited[nIdx] == 0 {
                                    visited[nIdx] = 1
                                    queue.append(nIdx)
                                }
                            }
                        }
                    }

                    let gridW = maxGX - minGX + 1
                    let gridH = maxGY - minGY + 1
                    // 过滤太稀疏的零散正文片段（如零星文字行），保留实体图片/图表/卡片/二维码
                    guard Double(queue.count) / Double(gridW * gridH) >= 0.42 else { continue }

                    var bx0 = px0 + minGX * cell
                    var by0 = py0 + minGY * cell
                    var bx1 = min(px1, px0 + (maxGX + 1) * cell)
                    var by1 = min(py1, py0 + (maxGY + 1) * cell)
                    let coarseW = bx1 - bx0
                    let coarseH = by1 - by0
                    guard coarseW >= minIslandW, coarseH >= minIslandH,
                          Double(coarseW * coarseH) < paneArea * 0.85 else { continue }

                    // 精确收缩四边到实际前景像素边界
                    let maxShrink = cell + 2
                    var shrunk = 0
                    while bx0 < bx1 - minIslandW && shrunk < maxShrink {
                        var found = false
                        for y in by0 ..< by1 {
                            if differsFromBG(bx0, y, bgR, bgG, bgB, edgeTightThresh) { found = true; break }
                        }
                        if found { break }
                        bx0 += 1; shrunk += 1
                    }
                    shrunk = 0
                    while bx1 > bx0 + minIslandW && shrunk < maxShrink {
                        var found = false
                        for y in by0 ..< by1 {
                            if differsFromBG(bx1 - 1, y, bgR, bgG, bgB, edgeTightThresh) { found = true; break }
                        }
                        if found { break }
                        bx1 -= 1; shrunk += 1
                    }
                    shrunk = 0
                    while by0 < by1 - minIslandH && shrunk < maxShrink {
                        var found = false
                        for x in bx0 ..< bx1 {
                            if differsFromBG(x, by0, bgR, bgG, bgB, edgeTightThresh) { found = true; break }
                        }
                        if found { break }
                        by0 += 1; shrunk += 1
                    }
                    shrunk = 0
                    while by1 > by0 + minIslandH && shrunk < maxShrink {
                        var found = false
                        for x in bx0 ..< bx1 {
                            if differsFromBG(x, by1 - 1, bgR, bgG, bgB, edgeTightThresh) { found = true; break }
                        }
                        if found { break }
                        by1 -= 1; shrunk += 1
                    }

                    bx0 = max(pane.x0, bx0 - padPx)
                    by0 = max(pane.y0, by0 - padPx)
                    bx1 = min(pane.x1, bx1 + padPx)
                    by1 = min(pane.y1, by1 + padPx)
                    let fw = bx1 - bx0, fh = by1 - by0
                    guard fw >= minIslandW, fh >= minIslandH,
                          Double(fw * fh) < paneArea * 0.85 else { continue }
                    let aspect = Double(max(fw, fh)) / Double(min(fw, fh))
                    guard aspect <= 20.0 else { continue }
                    rawBoxes.append(PixelBox(x0: bx0, y0: by0, x1: bx1, y1: by1, priority: 0))
                }
            }
        }
    }

    /// 线性时间合并相邻行/列上的平行重复边缘段。
    private static func collapseParallelRuns(_ runs: [EdgeRun], maxCoordGap: Int, endTol: Int) -> [EdgeRun] {
        guard !runs.isEmpty else { return [] }
        var kept: [EdgeRun] = []
        kept.reserveCapacity(runs.count / 2 + 1)
        var windowStart = 0

        for run in runs {
            while windowStart < kept.count && run.coord - kept[windowStart].coord > maxCoordGap {
                windowStart += 1
            }
            var merged = false
            for idx in windowStart ..< kept.count {
                let existing = kept[idx]
                if abs(existing.start - run.start) <= endTol && abs(existing.end - run.end) <= endTol {
                    if run.length > existing.length {
                        kept[idx] = run
                    }
                    merged = true
                    break
                }
            }
            if !merged {
                kept.append(run)
            }
        }
        return kept
    }

    /// 过滤几乎等同于整窗的框，并按优先级与面积合并近似重复的边框包装层。
    private static func deduplicateBoxes(_ raw: [PixelBox], width w: Int, height h: Int, pxPerPt: Double) -> [PixelBox] {
        let edgeMargin = max(3, Int((4.0 * pxPerPt).rounded()))
        let mergeTol = max(3, Int((4.0 * pxPerPt).rounded()))
        let windowArea = Double(w * h)

        let valid = raw.filter { box in
            let nearFull = box.x0 <= edgeMargin && box.y0 <= edgeMargin
                && box.x1 >= w - edgeMargin && box.y1 >= h - edgeMargin
            if nearFull { return false }
            if Double(box.area) >= windowArea * 0.95 { return false }
            return true
        }

        // 先保留结构分割面板（priority = 1），再按面积从大到小去重，避免内层 1-2px 描边覆盖外框。
        let sorted = valid.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.area > rhs.area
        }

        var result: [PixelBox] = []
        result.reserveCapacity(min(sorted.count, 400))
        for box in sorted {
            var duplicate = false
            for existing in result {
                if abs(existing.x0 - box.x0) <= mergeTol
                    && abs(existing.y0 - box.y0) <= mergeTol
                    && abs(existing.x1 - box.x1) <= mergeTol
                    && abs(existing.y1 - box.y1) <= mergeTol {
                    duplicate = true
                    break
                }
                let ix0 = max(existing.x0, box.x0)
                let iy0 = max(existing.y0, box.y0)
                let ix1 = min(existing.x1, box.x1)
                let iy1 = min(existing.y1, box.y1)
                if ix1 > ix0 && iy1 > iy0 {
                    let inter = Double((ix1 - ix0) * (iy1 - iy0))
                    let union = Double(existing.area + box.area) - inter
                    if union > 0 && (inter / union) >= 0.88 {
                        duplicate = true
                        break
                    }
                }
            }
            if !duplicate {
                result.append(box)
                if result.count >= 400 { break }
            }
        }
        return result
    }
}
