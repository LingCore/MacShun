// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import PDFKit

/// 从文件里读出纯文本，给内容索引（F2）用。哪个线程都可以调用。
///
/// - txt、md、csv、json：直接读，依次试 UTF-8、UTF-16（有 BOM 时）、GB18030（Windows 上存的中文文件多半是 GBK）；
/// - docx、xlsx、pptx：自己解 zip，读里面 XML 的文字；xlsx 只读文字格子，不读数字；
/// - pdf：系统的 PDFKit，只读前面若干页。扫描件没有文字层，读不出东西。
///   放在子进程里读：图片多的 PDF 解析时会占几百 MB 内存，损坏的 PDF 还可能让 PDFKit 崩溃，
///   子进程退出后内存就还回去了，崩了也只是这个文件读不出来，不会连累键盘映射。
enum ContentExtractor {
    enum Kind: Int, Comparable {
        // 按读取的快慢排，建索引时先读快的
        case text, docx, pptx, xlsx, pdf

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        /// 超过这个大小的文件不读。文本文件只读开头一段，可以大一些
        var maxFileSize: Int {
            switch self {
            case .text: 64 << 20
            case .docx, .pptx, .xlsx: 32 << 20
            case .pdf: 64 << 20
            }
        }
    }

    static let kinds: [String: Kind] = [
        "txt": .text, "text": .text, "md": .text, "markdown": .text, "csv": .text, "tsv": .text, "json": .text,
        "docx": .docx, "pptx": .pptx, "xlsx": .xlsx, "pdf": .pdf,
    ]

    /// 每个文件最多收录多少文字（UTF-8 字节）。再长的部分搜不到，换来索引不至于太大
    static let maxTextBytes = 512 << 10
    /// 大的 json 多半是程序的数据和配置，收录得少一些（实测软件盘上 json 占了索引的一大半）
    static let maxJSONTextBytes = 128 << 10
    /// PDF 最多读多少页
    static let maxPDFPages = 100
    /// Office 文件里所有部分加起来最多解压多少，防止由大量页面组成的“zip 炸弹”
    static let maxUnzippedBytes = 256 << 20

    /// 这个文件要不要读内容。Office 打开文件时生成的 “~$xxx.docx” 临时文件不读。
    static func kind(ofFileNamed name: String) -> Kind? {
        guard let dot = name.lastIndex(of: "."), !name.hasPrefix("~$") else { return nil }
        return kinds[name[name.index(after: dot)...].lowercased()]
    }

    /// 读出文字。读不了、没有文字时返回 nil。
    static func extract(path: String, kind: Kind) -> String? {
        let url = URL(fileURLWithPath: path)
        let isJSON = path.lowercased().hasSuffix(".json")
        let limit = isJSON ? maxJSONTextBytes : maxTextBytes
        let text: String?
        switch kind {
        case .text:
            // 只读开头够用的一段：GBK 两个字节一个汉字，转成 UTF-8 是三个字节，读两倍足够
            guard let handle = try? FileHandle(forReadingFrom: url),
                  let data = try? handle.read(upToCount: limit * 2) else { return nil }
            try? handle.close()
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? data.count
            text = decodeText(data, truncated: data.count < size)
                .map { truncated($0, maxBytes: limit) }
                .map { isJSON ? unescapeJSON($0) : $0 }
        case .docx:
            text = ZipReader(url: url).flatMap { zip in
                zip.read("word/document.xml").flatMap { xmlText($0, text: ["w:t"], breaks: ["w:p"], tabs: ["w:tab"]) }
            }
        case .pptx:
            text = ZipReader(url: url).flatMap(pptxText)
        case .xlsx:
            text = ZipReader(url: url).flatMap(xlsxText)
        case .pdf:
            text = pdfText(url)
        }
        guard var text, text.contains(where: { !$0.isWhitespace }) else { return nil }
        // SQLite 按 C 字符串收文字，遇到 0 就停了，后面的搜不到（JSON 里的 \u0000、文本文件后面夹的 0）
        if text.contains("\u{0}") { text = text.replacingOccurrences(of: "\u{0}", with: " ") }
        return truncated(text, maxBytes: limit)
    }

    // MARK: - 纯文本

    /// 认出编码并转成文字。看起来是二进制文件时返回 nil。
    /// truncated 表示只读了文件开头一段，末尾可能断在一个字的中间，去掉最后几个字节再试。
    static func decodeText(_ data: Data, truncated: Bool = false) -> String? {
        func decode(_ data: Data, _ encoding: String.Encoding, maxTrim: Int) -> String? {
            for trim in 0...(truncated ? maxTrim : 0) where data.count > trim {
                if let text = String(data: data.dropLast(trim), encoding: encoding) { return text }
            }
            return nil
        }
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return decode(data.dropFirst(3), .utf8, maxTrim: 3) }
        if bytes.starts(with: [0xFF, 0xFE]) { return decode(data.dropFirst(2), .utf16LittleEndian, maxTrim: 3) }
        if bytes.starts(with: [0xFE, 0xFF]) { return decode(data.dropFirst(2), .utf16BigEndian, maxTrim: 3) }
        // 文本文件里不会有 0 字节
        if data.prefix(8192).contains(0) { return nil }
        return decode(data, .utf8, maxTrim: 3) ?? decode(data, gb18030, maxTrim: 3)
    }

    private static let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
        CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    /// JSON 里的中文常常写成 合同，换回汉字才搜得到。其他转义不动。
    static func unescapeJSON(_ text: String) -> String {
        guard text.contains("\\u") else { return text }
        var out = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        var i = 0
        var pendingHigh: UInt32?
        func hex(at start: Int) -> UInt32? {
            guard start + 4 <= scalars.count else { return nil }
            var value: UInt32 = 0
            for scalar in scalars[start ..< start + 4] {
                guard let digit = Character(scalar).hexDigitValue else { return nil }
                value = value << 4 | UInt32(digit)
            }
            return value
        }
        while i < scalars.count {
            if scalars[i] == "\\", i + 1 < scalars.count {
                if scalars[i + 1] == "u", let value = hex(at: i + 2) {
                    if (0xD800...0xDBFF).contains(value) {
                        pendingHigh = value
                    } else if (0xDC00...0xDFFF).contains(value), let high = pendingHigh {
                        pendingHigh = nil
                        if let scalar = Unicode.Scalar(0x10000 + (high - 0xD800) << 10 + (value - 0xDC00)) { out.append(scalar) }
                    } else if let scalar = Unicode.Scalar(value) {
                        out.append(scalar)
                    }
                    i += 6
                    continue
                }
                // 其他转义（\" \\ \n）原样保留，跳过两个字符，免得 \\u 被当成转义
                out.append(scalars[i])
                out.append(scalars[i + 1])
                i += 2
                continue
            }
            out.append(scalars[i])
            i += 1
        }
        return String(out)
    }

    /// 截到不超过 maxBytes 字节，不切断一个字符。
    static func truncated(_ text: String, maxBytes: Int) -> String {
        let utf8 = text.utf8
        guard utf8.count > maxBytes else { return text }
        var end = utf8.index(utf8.startIndex, offsetBy: maxBytes)
        while end > utf8.startIndex && UTF8.isContinuation(utf8[end]) { end = utf8.index(before: end) }
        return String(text[..<end])
    }

    // MARK: - Office

    private static func pptxText(_ zip: ZipReader) -> String? {
        // 按页码排：slide2 在 slide10 前面
        func pages(_ prefix: String) -> [String] {
            zip.names
                .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".xml") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        let parts = collect(zip, pages("ppt/slides/slide") + pages("ppt/notesSlides/notesSlide")) {
            xmlText($0, text: ["a:t"], breaks: ["a:p"])
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// 依次解压几个部分取文字，文字够多了或者解压得太多了就停。
    private static func collect(_ zip: ZipReader, _ names: [String], _ extract: (Data) -> String?) -> [String] {
        var parts: [String] = []
        var textBytes = 0
        var unzipped = 0
        for name in names {
            guard textBytes < maxTextBytes, unzipped < maxUnzippedBytes else { break }
            guard let data = zip.read(name) else { continue }
            unzipped += data.count
            guard let text = extract(data) else { continue }
            textBytes += text.utf8.count
            parts.append(text)
        }
        return parts
    }

    private static func xlsxText(_ zip: ZipReader) -> String? {
        var parts: [String] = []
        // 文字格子都存在 sharedStrings 里；rPh 是日文注音，不要
        if let shared = zip.read("xl/sharedStrings.xml"),
           let text = xmlText(shared, text: ["t"], breaks: ["si"], skip: ["rPh"]) {
            parts.append(text)
        }
        // 有的程序把文字直接写在表格里（inlineStr），只有这时才去读表格，表格本身可能很大
        let marker = Data("inlineStr".utf8)
        let sheets = zip.names.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
        parts += collect(zip, sheets) { sheet in
            sheet.range(of: marker) == nil ? nil : xmlText(sheet, text: ["t"], breaks: ["c"], skip: ["rPh"])
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// 取出 XML 里某些元素的文字。breaks 结束时换行，tabs 处加空格，skip 里面的文字不要。
    static func xmlText(_ xml: Data, text: Set<String>, breaks: Set<String>, tabs: Set<String> = [], skip: Set<String> = []) -> String? {
        let collector = XMLTextCollector(text: text, breaks: breaks, tabs: tabs, skip: skip)
        let parser = XMLParser(data: xml)
        parser.delegate = collector
        parser.shouldResolveExternalEntities = false
        parser.parse()
        return collector.output.isEmpty ? nil : collector.output
    }

    private final class XMLTextCollector: NSObject, XMLParserDelegate {
        let text: Set<String>, breaks: Set<String>, tabs: Set<String>, skip: Set<String>
        var output = ""
        private var inText = 0
        private var skipping = 0

        init(text: Set<String>, breaks: Set<String>, tabs: Set<String>, skip: Set<String>) {
            self.text = text
            self.breaks = breaks
            self.tabs = tabs
            self.skip = skip
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            if skip.contains(name) { skipping += 1 }
            if text.contains(name) { inText += 1 }
            if tabs.contains(name) { output += " " }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if skip.contains(name) { skipping -= 1 }
            if text.contains(name) { inText -= 1 }
            if breaks.contains(name), !output.isEmpty, output.last != "\n" { output += "\n" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inText > 0, skipping == 0 else { return }
            output += string
            // 够长了就不往下读
            if output.utf8.count > ContentExtractor.maxTextBytes { parser.abortParsing() }
        }
    }

    // MARK: - PDF

    static let pdfHelperArgument = "--extract-pdf-text"

    /// 是读 PDF 的子进程时，返回要读的文件
    static func pdfHelperPath(in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: pdfHelperArgument), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// 子进程：把文字写到标准输出后退出。
    static func runPDFHelper(path: String) -> Never {
        guard let text = pdfTextInProcess(URL(fileURLWithPath: path)) else { exit(1) }
        FileHandle.standardOutput.write(Data(text.utf8))
        exit(0)
    }

    /// 打包好的 Win顺 用子进程读；测试和截图工具里没有 Win顺 程序可启动，直接读。
    private static let helperExecutable: URL? =
        Bundle.main.bundleIdentifier == "io.github.lingcore.winshun" ? Bundle.main.executableURL : nil

    private static func pdfText(_ url: URL) -> String? {
        guard let executable = helperExecutable else { return pdfTextInProcess(url) }
        let process = Process()
        process.executableURL = executable
        process.arguments = [pdfHelperArgument, url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // 卡住的 PDF 最多等 30 秒；不理 SIGTERM 时再过 3 秒强制结束
        let pid = process.processIdentifier
        let timeout = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            Log.app.notice("内容索引：读不了 PDF \(url.path, privacy: .public)")
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func pdfTextInProcess(_ url: URL) -> String? {
        autoreleasepool {
            // 有密码的打不开，跳过
            guard let document = PDFDocument(url: url), !document.isLocked else { return nil }
            var text = ""
            for index in 0 ..< min(document.pageCount, maxPDFPages) {
                // 一页一页释放，图片多的 PDF 不然会占几百 MB
                let page: String? = autoreleasepool { document.page(at: index)?.string }
                guard let page else { continue }
                text += page
                text += "\n"
                if text.utf8.count > maxTextBytes { break }
            }
            // PDFKit 用 U+FFFC 表示图片
            return text.replacingOccurrences(of: "\u{FFFC}", with: "")
        }
    }
}
