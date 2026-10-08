// SPDX-License-Identifier: MIT
//
// 把 SVG 渲染成指定像素的透明 PNG（用系统 NSImage 自带的 SVG 支持），供 scripts/make-icon.py 调用。
// 用法：svg2png <输入.svg> <像素> <输出.png>

import AppKit

let args = CommandLine.arguments
guard args.count == 4, let px = Int(args[2]), let image = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("用法：svg2png <输入.svg> <像素> <输出.png>\n".data(using: .utf8)!)
    exit(1)
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: px, height: px)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
