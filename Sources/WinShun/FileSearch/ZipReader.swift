// SPDX-License-Identifier: GPL-3.0-or-later

import Compression
import Foundation

/// 读 zip 里的文件。docx、xlsx、pptx 都是 zip，里面是 XML。
///
/// 只支持 Office 存出来的普通 zip：不加密、不是 zip64，压缩方式是“存储”或 deflate。不认识的直接返回 nil，不会崩。
/// 用系统的 libcompression 解压，不用另外启动 unzip 进程（每个文件省几十毫秒）。
struct ZipReader {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let localHeaderOffset: Int
        let isEncrypted: Bool
    }

    private let data: Data
    let entries: [Entry]

    /// 单个文件解压后最大多少，防止“zip 炸弹”
    static let maxEntrySize = 64 << 20

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        self.init(data: data)
    }

    init?(data: Data) {
        self.data = data
        guard let entries = Self.readCentralDirectory(data) else { return nil }
        self.entries = entries
    }

    var names: [String] { entries.map(\.name) }

    /// 解压一个文件，没有或者读不了时返回 nil。
    func read(_ name: String) -> Data? {
        guard let entry = entries.first(where: { $0.name == name }) else { return nil }
        return read(entry)
    }

    func read(_ entry: Entry) -> Data? {
        guard !entry.isEncrypted, entry.size <= Self.maxEntrySize,
              data.u32(at: entry.localHeaderOffset) == 0x0403_4B50,
              let nameLength = data.u16(at: entry.localHeaderOffset + 26),
              let extraLength = data.u16(at: entry.localHeaderOffset + 28)
        else { return nil }
        let start = entry.localHeaderOffset + 30 + Int(nameLength) + Int(extraLength)
        guard start >= 0, start + entry.compressedSize <= data.count else { return nil }
        let compressed = data[data.startIndex + start ..< data.startIndex + start + entry.compressedSize]
        switch entry.method {
        case 0:
            return Data(compressed)
        case 8:
            guard entry.size > 0 else { return Data() }
            var output = Data(count: entry.size)
            let written = output.withUnsafeMutableBytes { dst in
                compressed.withUnsafeBytes { src in
                    // COMPRESSION_ZLIB 就是 zip 用的原始 deflate（不带 zlib 头）
                    compression_decode_buffer(
                        dst.bindMemory(to: UInt8.self).baseAddress!, entry.size,
                        src.bindMemory(to: UInt8.self).baseAddress!, entry.compressedSize,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
            return written == entry.size ? output : nil
        default:
            return nil
        }
    }

    /// 从文件末尾找到“中央目录”，读出所有文件的名字、大小和位置。
    private static func readCentralDirectory(_ data: Data) -> [Entry]? {
        // 目录结束记录至少 22 字节，后面可能跟最长 65535 字节的注释
        let minEnd = 22
        guard data.count >= minEnd else { return nil }
        var end = data.count - minEnd
        let lowest = max(0, data.count - minEnd - 0xFFFF)
        while end >= lowest && data.u32(at: end) != 0x0605_4B50 { end -= 1 }
        guard end >= lowest,
              let count = data.u16(at: end + 10),
              let directoryOffset = data.u32(at: end + 16),
              directoryOffset != 0xFFFF_FFFF   // zip64
        else { return nil }

        var entries: [Entry] = []
        entries.reserveCapacity(Int(count))
        var offset = Int(directoryOffset)
        for _ in 0..<count {
            guard data.u32(at: offset) == 0x0201_4B50,
                  let flags = data.u16(at: offset + 8),
                  let method = data.u16(at: offset + 10),
                  let compressedSize = data.u32(at: offset + 20),
                  let size = data.u32(at: offset + 24),
                  let nameLength = data.u16(at: offset + 28),
                  let extraLength = data.u16(at: offset + 30),
                  let commentLength = data.u16(at: offset + 32),
                  let localOffset = data.u32(at: offset + 42),
                  offset + 46 + Int(nameLength) <= data.count
            else { return nil }
            let nameStart = data.startIndex + offset + 46
            let name = String(decoding: data[nameStart ..< nameStart + Int(nameLength)], as: UTF8.self)
            entries.append(Entry(
                name: name, method: method,
                compressedSize: Int(compressedSize), size: Int(size),
                localHeaderOffset: Int(localOffset), isEncrypted: flags & 1 != 0
            ))
            offset += 46 + Int(nameLength) + Int(extraLength) + Int(commentLength)
        }
        return entries
    }
}

private extension Data {
    /// 小端整数，越界时返回 nil
    func u16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func u32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
