// SPDX-License-Identifier: MIT

import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// 从文件里读出纯文本，给内容索引（F2）用。哪个线程都可以调用。
///
/// - txt、md、csv、json、代码、配置、字幕：直接读，依次试 UTF-8、UTF-16（有 BOM 时）、GB18030（Windows 上存的中文文件多半是 GBK）；
///   网页去掉标签、脚本和样式，只留文字；
/// - docx、xlsx、pptx：自己解 zip，读里面 XML 的文字；xlsx 只读文字格子，不读数字；
/// - pdf：系统的 PDFKit，只读前面若干页。扫描件没有文字层，改用系统的文字识别（Vision）认前面几页；
/// - 图片（截图、照片）：系统的文字识别，认简体、繁体中文和英文，跟聚焦一样。太小的图（图标）不认。
///   PDF 和图片放在子进程里读：图片多的 PDF 解析时会占几百 MB 内存，文字识别要加载模型，损坏的文件还可能让系统框架崩溃，
///   子进程退出后内存就还回去了，崩了也只是这个文件读不出来，不会连累键盘映射。
enum ContentExtractor {
    enum Kind: Int, Comparable {
        // 按读取的快慢排，建索引时先读快的
        case text, docx, pptx, xlsx, pdf, image

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        /// 超过这个大小的文件不读。文本文件只读开头一段，可以大一些
        var maxFileSize: Int {
            switch self {
            case .text: 64 << 20
            case .docx, .pptx, .xlsx: 32 << 20
            case .pdf: 64 << 20
            case .image: 50 << 20
            }
        }
    }

    /// 按文本读的扩展名：文档、代码、配置、字幕。日志不读：一直在写，会反复重读
    static let textExtensions: Set<String> = [
        // 文档和数据
        "txt", "text", "md", "markdown", "csv", "tsv", "json", "rst", "tex", "org", "adoc",
        // 代码
        "ts", "tsx", "mts", "cts", "js", "jsx", "mjs", "cjs", "vue", "svelte", "py", "pyi", "swift", "m", "mm",
        "c", "h", "cpp", "cc", "cxx", "hpp", "hh", "cs", "java", "kt", "kts", "scala", "groovy", "gradle", "go", "rs",
        "rb", "php", "lua", "pl", "r", "dart", "sql", "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd",
        // 网页和样式
        "html", "htm", "css", "scss", "sass", "less",
        // 配置
        "xml", "yaml", "yml", "toml", "ini", "cfg", "conf", "properties", "plist",
        // 字幕和歌词
        "srt", "vtt", "ass", "ssa", "lrc", "sub",
    ]

    /// 认里面文字的图片
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "webp", "tiff", "tif", "bmp"]

    static let kinds: [String: Kind] = Dictionary(uniqueKeysWithValues: textExtensions.map { ($0, Kind.text) })
        .merging(Dictionary(uniqueKeysWithValues: imageExtensions.map { ($0, Kind.image) })) { _, new in new }
        .merging(["docx": .docx, "pptx": .pptx, "xlsx": .xlsx, "pdf": .pdf]) { _, new in new }

    /// 认不认图片里的文字（设置里可以关掉，省电）。哪个线程都可以读
    static let readsImages = Locked(true)

    /// 程序生成的文件：压缩过的脚本、依赖的锁文件，内容对人没用
    private static let generatedNames: Set<String> = [
        "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "npm-shrinkwrap.json", "composer.lock", "Podfile.lock",
        "Cargo.lock", "Gemfile.lock", "poetry.lock", "Package.resolved",
    ]

    /// 每个文件最多收录多少文字（UTF-8 字节）。再长的部分搜不到，换来索引不至于太大
    static let maxTextBytes = 512 << 10
    /// PDF 最多读多少页
    static let maxPDFPages = 100
    /// 扫描版 PDF 最多认前面几页
    static let maxOCRPages = 20
    /// 比这还小的图片（图标、缩略图）不认字
    static let minImageSide = 200
    /// Office 文件里所有部分加起来最多解压多少，防止由大量页面组成的“zip 炸弹”
    static let maxUnzippedBytes = 256 << 20

    /// 这个文件要不要读内容。Office 打开文件时生成的 “~$xxx.docx” 临时文件、压缩过的 xxx.min.js、锁文件不读。
    static func kind(ofFileNamed name: String) -> Kind? {
        guard let dot = name.lastIndex(of: "."), !name.hasPrefix("~$"), !name.contains(".min."),
              !generatedNames.contains(name), let kind = kinds[name[name.index(after: dot)...].lowercased()] else { return nil }
        return kind == .image && !readsImages.get() ? nil : kind
    }

    /// 读的结果
    enum Outcome: Equatable {
        case text(String)
        /// 读不了或没有文字
        case empty
        /// 这次没读成，但不是文件的问题（子进程起不来、电脑太忙超时了），不记下来，下次再读
        case retryLater
    }

    /// 读出文字。读不了、没有文字时返回 nil。
    static func extract(path: String, kind: Kind) -> String? {
        if case .text(let text) = read(path: path, kind: kind) { return text }
        return nil
    }

    static func read(path: String, kind: Kind) -> Outcome {
        let url = URL(fileURLWithPath: path)
        let isJSON = path.lowercased().hasSuffix(".json")
        let limit = maxTextBytes
        let text: String?
        switch kind {
        case .text:
            // 只读开头够用的一段：GBK 两个字节一个汉字，转成 UTF-8 是三个字节，读两倍足够
            guard let handle = try? FileHandle(forReadingFrom: url),
                  let data = try? handle.read(upToCount: limit * 2) else { return .empty }
            try? handle.close()
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? data.count
            let ext = (path as NSString).pathExtension.lowercased()
            text = decodeText(data, truncated: data.count < size)
                .map { ext == "html" || ext == "htm" ? htmlText($0) : $0 }
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
        case .pdf, .image:
            guard kind == .pdf || hasTextSizedPixels(url) else { return .empty }
            switch helperText(kind, url) {
            case .text(let read): text = read
            case let other: return other
            }
        }
        guard var text, text.contains(where: { !$0.isWhitespace }) else { return .empty }
        // SQLite 按 C 字符串收文字，遇到 0 就停了，后面的搜不到（JSON 里的 \u0000、文本文件后面夹的 0）
        if text.contains("\u{0}") { text = text.replacingOccurrences(of: "\u{0}", with: " ") }
        return .text(truncated(text, maxBytes: limit))
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
                    } else {
                        pendingHigh = nil
                        if let scalar = Unicode.Scalar(value) { out.append(scalar) }
                    }
                    i += 6
                    continue
                }
                pendingHigh = nil
                // 其他转义（\" \\ \n）原样保留，跳过两个字符，免得 \\u 被当成转义
                out.append(scalars[i])
                out.append(scalars[i + 1])
                i += 2
                continue
            }
            pendingHigh = nil
            out.append(scalars[i])
            i += 1
        }
        return String(out)
    }

    /// 网页里的文字：去掉脚本、样式、注释和标签，段落处换行，换回常见的字符实体。
    static func htmlText(_ html: String) -> String {
        var text = html
        // (?s)：. 也匹配换行，脚本、样式、注释几乎都占好几行；同时兜底因读取上限截断而缺闭合标签的尾部。
        for pattern in [
            "(?s)<script\\b[^>]*>.*?(?:</script\\s*>|$)",
            "(?s)<style\\b[^>]*>.*?(?:</style\\s*>|$)",
            "(?s)<!--.*?(?:-->|$)",
        ] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<(br|/p|/div|/li|/tr|/h[1-6]|/title)\\b[^>]*>", with: "\n",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        // &#20013; &#x4e2d; &#X4E2D; 这类写法的字
        if text.contains("&#") {
            let regex = try? NSRegularExpression(pattern: "&#([xX][0-9a-fA-F]+|[0-9]+);")
            let ns = text as NSString
            var out = ""
            var last = 0
            for match in regex?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [] {
                out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let code = ns.substring(with: match.range(at: 1))
                let isHex = code.first == "x" || code.first == "X"
                let value = isHex ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
                out += value.flatMap(Unicode.Scalar.init).map { String($0) } ?? ns.substring(with: match.range)
                last = match.range.location + match.range.length
            }
            text = out + ns.substring(from: last)
        }
        return text.replacingOccurrences(of: "&amp;", with: "&")
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
    private static func collect(_ zip: ZipReader, _ names: [String], budget: Int = maxTextBytes,
                                _ extract: (Data) -> String?) -> [String] {
        var parts: [String] = []
        var textBytes = 0
        var unzipped = 0
        for name in names {
            guard textBytes < budget, unzipped < maxUnzippedBytes else { break }
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
        var usedBytes = 0
        // 文字格子都存在 sharedStrings 里；rPh 是日文注音，不要
        if let shared = zip.read("xl/sharedStrings.xml"),
           let text = xmlText(shared, text: ["t"], breaks: ["si"], skip: ["rPh"]) {
            usedBytes = text.utf8.count
            parts.append(text)
        }
        // sharedStrings 已经达到全文上限时不再解压可能高达上百 MB 的纯数字工作表 XML。
        if usedBytes < maxTextBytes {
            let marker = Data("inlineStr".utf8)
            let sheets = zip.names.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            parts += collect(zip, sheets, budget: maxTextBytes - usedBytes) { sheet in
                sheet.range(of: marker) == nil ? nil : xmlText(sheet, text: ["t"], breaks: ["c"], skip: ["rPh"])
            }
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

    // MARK: - PDF 和图片（可复用短命子进程）

    static let helperArguments: [Kind: String] = [.pdf: "--extract-pdf-text", .image: "--extract-image-text"]
    static let workerArgument = "--extract-worker"

    /// 扫描版 PDF 要不要认字（跟着“认图片里的文字”）
    static let ocrArgument = "--ocr"

    /// 是读 PDF 或认图片文字的单次子进程时，返回要读的种类和文件（保留兼容）。
    static func helperRequest(in arguments: [String]) -> (kind: Kind, path: String, ocr: Bool)? {
        for (kind, argument) in helperArguments {
            if let index = arguments.firstIndex(of: argument), index + 1 < arguments.count {
                return (kind, arguments[index + 1], arguments.contains(ocrArgument))
            }
        }
        return nil
    }

    /// 单次子进程（保留兼容）：把文字写到标准输出后退出。
    static func runHelper(kind: Kind, path: String, ocr: Bool) -> Never {
        alarm(90)
        let url = URL(fileURLWithPath: path)
        guard let text = kind == .pdf ? pdfTextInProcess(url, ocr: ocr) : imageText(at: url) else { exit(1) }
        let limited = truncated(text, maxBytes: maxTextBytes)
        try? FileHandle.standardOutput.write(contentsOf: Data(limited.utf8))
        exit(0)
    }

    struct WorkerRequest: Codable {
        enum Op: String, Codable { case pdf, image, redact }
        let op: Op
        let path: String
        let ocr: Bool
    }

    struct WorkerResponse: Codable {
        let ok: Bool
        let text: String?
        let rects: [[Double]]?
    }

    /// 供子进程与单测共用：执行一次单文件请求。
    static func executeWorkerRequest(_ request: WorkerRequest) -> WorkerResponse {
        autoreleasepool {
            let url = URL(fileURLWithPath: request.path)
            switch request.op {
            case .pdf:
                guard let text = pdfTextInProcess(url, ocr: request.ocr) else {
                    return WorkerResponse(ok: false, text: nil, rects: nil)
                }
                return WorkerResponse(ok: true, text: truncated(text, maxBytes: maxTextBytes), rects: nil)
            case .image:
                guard let text = imageText(at: url) else {
                    return WorkerResponse(ok: false, text: nil, rects: nil)
                }
                return WorkerResponse(ok: true, text: truncated(text, maxBytes: maxTextBytes), rects: nil)
            case .redact:
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
                      let boxes = try? CaptureRedaction.recognizeInProcess(in: cgImage)
                else {
                    return WorkerResponse(ok: false, text: nil, rects: nil)
                }
                let encoded = boxes.map { [Double($0.origin.x), Double($0.origin.y), Double($0.width), Double($0.height)] }
                return WorkerResponse(ok: true, text: nil, rects: encoded)
            }
        }
    }

    /// 可复用短命提取子进程：按行接收 JSON 请求并返回一行 JSON；
    /// 空闲 15 秒或累计处理 64 次后自动退出，把 Vision/CoreML/PDFKit 模型内存全部还给系统。
    static func runWorker() -> Never {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let decoder = JSONDecoder()
        var buffer = Data()
        var handled = 0
        let maxRequestsPerWorker = 64
        let idleTimeoutMs: Int32 = 15_000

        while handled < maxRequestsPerWorker {
            guard let line = readLinePoll(fd: STDIN_FILENO, buffer: &buffer, timeoutMs: idleTimeoutMs) else {
                Darwin.close(STDIN_FILENO)
                Darwin.close(STDOUT_FILENO)
                _exit(0)
            }
            if line.isEmpty { continue }
            guard let request = try? decoder.decode(WorkerRequest.self, from: line) else {
                let err = WorkerResponse(ok: false, text: nil, rects: nil)
                if !writeLine(fd: STDOUT_FILENO, data: (try? encoder.encode(err)) ?? Data("{\"ok\":false}".utf8)) {
                    _exit(0)
                }
                continue
            }
            alarm(90)
            let response = executeWorkerRequest(request)
            alarm(0)
            handled += 1
            if request.op == .pdf || handled.isMultiple(of: 8) {
                malloc_zone_pressure_relief(nil, 0)
            }
            guard let payload = try? encoder.encode(response),
                  writeLine(fd: STDOUT_FILENO, data: payload) else {
                _exit(0)
            }
        }
        Darwin.close(STDIN_FILENO)
        Darwin.close(STDOUT_FILENO)
        _exit(0)
    }

    private static func readLinePoll(fd: Int32, buffer: inout Data, timeoutMs: Int32) -> Data? {
        var chunk = [UInt8](repeating: 0, count: 16_384)
        let deadline = ProcessInfo.processInfo.systemUptime + Double(timeoutMs) / 1000.0
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex ..< newline])
                buffer.removeSubrange(buffer.startIndex ... newline)
                return line
            }
            let remainingMs = Int32(max(0, ((deadline - ProcessInfo.processInfo.systemUptime) * 1000).rounded(.up)))
            if remainingMs <= 0 { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let ready = poll(&pfd, 1, remainingMs)
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if ready == 0 { return nil }
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0 ..< count])
            } else if count == 0 {
                guard !buffer.isEmpty else { return nil }
                let line = buffer
                buffer.removeAll(keepingCapacity: false)
                return line
            } else if errno != EINTR {
                return nil
            }
        }
    }

    private static func writeLine(fd: Int32, data: Data) -> Bool {
        var line = data
        line.append(0x0A)
        return line.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            var written = 0
            while written < line.count {
                let n = Darwin.write(fd, base.advanced(by: written), line.count - written)
                if n > 0 {
                    written += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    /// 打包好的 Mac顺 用子进程读；测试和截图工具里没有 Mac顺 程序可启动，直接读。
    private static let helperExecutable: URL? =
        Bundle.main.bundleIdentifier == "io.github.lingcore.winshun" ? Bundle.main.executableURL : nil

    /// 正在运行或空闲复用的提取子进程：停止索引或退出程序时立即终止；
    /// 绝不从其他线程关闭 readHandle，避免与读线程发生 FD 复用竞争。
    private final class WorkerClient: @unchecked Sendable {
        let process: Process
        let stdinHandle: FileHandle
        let stdoutHandle: FileHandle
        let backgroundQoS: Bool
        var readBuffer = Data()
        var handled = 0
        private let exited = DispatchSemaphore(value: 0)
        private let state = Locked((finished: false, cancelled: false))

        init?(executable: URL, backgroundQoS: Bool) {
            let process = Process()
            process.executableURL = executable
            process.arguments = [ContentExtractor.workerArgument]
            process.qualityOfService = backgroundQoS ? .background : .userInitiated
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            let exited = self.exited
            process.terminationHandler = { _ in exited.signal() }
            do { try process.run() } catch { return nil }
            self.process = process
            self.stdinHandle = input.fileHandleForWriting
            self.stdoutHandle = output.fileHandleForReading
            self.backgroundQoS = backgroundQoS
            _ = fcntl(stdinHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
        }

        var isCancelled: Bool { state.withLock { $0.cancelled } }

        var isReusable: Bool {
            guard !isCancelled, process.isRunning, handled < 60 else { return false }
            var pfd = pollfd(fd: stdoutHandle.fileDescriptor, events: Int16(POLLHUP | POLLERR), revents: 0)
            _ = poll(&pfd, 1, 0)
            return (pfd.revents & Int16(POLLHUP | POLLERR)) == 0
        }

        /// 可由任意线程安全调用：只设取消标记并发 SIGTERM/SIGKILL，不碰文件句柄。
        func cancel() {
            let pid: pid_t? = state.update { s in
                guard !s.finished else { return nil }
                s.cancelled = true
                return process.processIdentifier
            }
            guard let pid, pid > 0 else { return }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                let stillAlive = self.state.withLock { !$0.finished } && self.process.isRunning
                if stillAlive { kill(pid, SIGKILL) }
            }
        }

        /// 只在独占该 WorkerClient 的工作线程上调用，安全关闭管道并回收子进程。
        /// 用 terminationHandler + 信号量有界等待，规避 GCD 线程上 NSConcreteTask.waitUntilExit 偶发永久挂死。
        func shutdown(forceKill: Bool) {
            if forceKill { cancel() }
            state.update { $0.finished = true }
            try? stdinHandle.close()
            try? stdoutHandle.close()
            if process.isRunning {
                if !forceKill { process.terminate() }
                if exited.wait(timeout: .now() + 1.0) == .timedOut, process.isRunning {
                    let pid = process.processIdentifier
                    if pid > 0 { kill(pid, SIGKILL) }
                    _ = exited.wait(timeout: .now() + 1.0)
                }
            }
        }

        enum CallResult {
            case response(WorkerResponse)
            case pipeBroken
            case crashed
            case cancelled
        }

        func send(_ request: WorkerRequest, reused: Bool, timeout: TimeInterval, isCancelled externalCancel: () -> Bool) -> CallResult {
            guard let encoded = try? JSONEncoder().encode(request) else { return .crashed }
            guard ContentExtractor.writeLine(fd: stdinHandle.fileDescriptor, data: encoded) else {
                return .pipeBroken
            }
            let fd = stdoutHandle.fileDescriptor
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            // JSON 对控制字符最多按 \u00XX 展开 6 倍，预留足额行长上限避免误判合法大文本响应崩溃。
            let maxLineBytes = ContentExtractor.maxTextBytes * 6 + 65_536
            var chunk = [UInt8](repeating: 0, count: 16_384)
            while true {
                if let newline = readBuffer.firstIndex(of: 0x0A) {
                    let line = Data(readBuffer[readBuffer.startIndex ..< newline])
                    readBuffer.removeSubrange(readBuffer.startIndex ... newline)
                    handled += 1
                    if let response = try? JSONDecoder().decode(WorkerResponse.self, from: line) {
                        return .response(response)
                    }
                    return .crashed
                }
                if readBuffer.count > maxLineBytes { return .crashed }
                if self.isCancelled || externalCancel() || ProcessInfo.processInfo.systemUptime >= deadline {
                    return .cancelled
                }
                var pfd = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
                let ready = poll(&pfd, 1, 250)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return .crashed
                }
                if ready == 0 { continue }
                let count = Darwin.read(fd, &chunk, chunk.count)
                if count > 0 {
                    readBuffer.append(contentsOf: chunk[0 ..< count])
                } else if count == 0 {
                    if self.isCancelled || externalCancel() { return .cancelled }
                    // 复用的空闲子进程恰好在空闲超时退出时关闭 stdout，按断管透明重试，不误判为坏文件。
                    if readBuffer.isEmpty && (reused || (!process.isRunning && process.terminationReason == .exit && process.terminationStatus == 0)) {
                        return .pipeBroken
                    }
                    return .crashed
                } else if errno != EINTR {
                    return .crashed
                }
            }
        }
    }

    private struct WorkerPoolState {
        var active: [ObjectIdentifier: (worker: WorkerClient, forIndexing: Bool)] = [:]
        var idleBackground: [WorkerClient] = []
        var idleInteractive: [WorkerClient] = []
        var indexEpoch = 0
        var globalEpoch = 0
    }

    private static let pool = Locked(WorkerPoolState())
    private static let maxIdleWorkers = 2

    /// 停止全文索引时仅终止索引子进程与后台空闲池，不打断正在进行的截图取字、辅助打码或剪贴板 OCR。
    static func terminateIndexingHelpers() {
        let (active, idle) = pool.update { state -> ([WorkerClient], [WorkerClient]) in
            state.indexEpoch &+= 1
            let active = state.active.values.filter(\.forIndexing).map(\.worker)
            let idle = state.idleBackground
            state.idleBackground.removeAll()
            return (active, idle)
        }
        active.forEach { $0.cancel() }
        if !idle.isEmpty {
            DispatchQueue.global(qos: .utility).async {
                idle.forEach { $0.shutdown(forceKill: false) }
            }
        }
    }

    static func terminateAllHelpers() {
        let (active, idle) = pool.update { state -> ([WorkerClient], [WorkerClient]) in
            state.indexEpoch &+= 1
            state.globalEpoch &+= 1
            let active = state.active.values.map(\.worker)
            let idle = state.idleBackground + state.idleInteractive
            state.idleBackground.removeAll()
            state.idleInteractive.removeAll()
            return (active, idle)
        }
        active.forEach { $0.cancel() }
        if !idle.isEmpty {
            DispatchQueue.global(qos: .utility).async {
                idle.forEach { $0.shutdown(forceKill: false) }
            }
        }
    }

    private static func acquireWorker(
        executable: URL,
        backgroundQoS: Bool,
        forIndexing: Bool
    ) -> (worker: WorkerClient, reused: Bool, indexEpoch: Int, globalEpoch: Int)? {
        while true {
            enum Pick {
                case borrowed(WorkerClient, Int, Int)
                case stale(WorkerClient)
                case needNew(Int, Int)
            }
            let pick: Pick = pool.update { state in
                let candidate = backgroundQoS ? state.idleBackground.popLast() : state.idleInteractive.popLast()
                if let candidate {
                    if candidate.isReusable {
                        state.active[ObjectIdentifier(candidate)] = (candidate, forIndexing)
                        return .borrowed(candidate, state.indexEpoch, state.globalEpoch)
                    }
                    return .stale(candidate)
                }
                return .needNew(state.indexEpoch, state.globalEpoch)
            }
            switch pick {
            case .borrowed(let worker, let indexEpoch, let globalEpoch):
                return (worker, true, indexEpoch, globalEpoch)
            case .stale(let stale):
                stale.shutdown(forceKill: false)
            case .needNew(let startIndexEpoch, let startGlobalEpoch):
                guard let fresh = WorkerClient(executable: executable, backgroundQoS: backgroundQoS) else { return nil }
                let registered: Bool = pool.update { state in
                    if state.globalEpoch != startGlobalEpoch || (forIndexing && state.indexEpoch != startIndexEpoch) {
                        return false
                    }
                    state.active[ObjectIdentifier(fresh)] = (fresh, forIndexing)
                    return true
                }
                if registered {
                    return (fresh, false, startIndexEpoch, startGlobalEpoch)
                }
                fresh.shutdown(forceKill: true)
                return nil
            }
        }
    }

    private static func releaseWorker(
        _ worker: WorkerClient,
        reusable: Bool,
        forIndexing: Bool,
        indexEpoch: Int,
        globalEpoch: Int
    ) {
        let shouldShutdown: WorkerClient? = pool.update { state in
            state.active.removeValue(forKey: ObjectIdentifier(worker))
            let epochValid = state.globalEpoch == globalEpoch && (!forIndexing || state.indexEpoch == indexEpoch)
            guard reusable, epochValid, worker.isReusable else { return worker }
            if worker.backgroundQoS {
                if state.idleBackground.count < maxIdleWorkers {
                    state.idleBackground.append(worker)
                    return nil
                }
            } else {
                if state.idleInteractive.count < maxIdleWorkers {
                    state.idleInteractive.append(worker)
                    return nil
                }
            }
            return worker
        }
        shouldShutdown?.shutdown(forceKill: !reusable)
    }

    private enum WorkerOutcome {
        case response(WorkerResponse)
        case failed
        case cancelledOrRetry
    }

    private static func runViaWorker(
        _ request: WorkerRequest,
        timeout: TimeInterval,
        backgroundQoS: Bool,
        forIndexing: Bool = false,
        isCancelled: () -> Bool = { false }
    ) -> WorkerOutcome {
        guard let executable = helperExecutable else {
            return .response(executeWorkerRequest(request))
        }
        // 若复用的空闲子进程恰好刚超时退出（EPIPE/EOF），自动透明重试一次新子进程。
        for attempt in 0 ..< 2 {
            guard !isCancelled() else { return .cancelledOrRetry }
            guard let lease = acquireWorker(executable: executable, backgroundQoS: backgroundQoS, forIndexing: forIndexing) else {
                return .cancelledOrRetry
            }
            let result = lease.worker.send(request, reused: lease.reused, timeout: timeout, isCancelled: isCancelled)
            switch result {
            case .response(let response):
                releaseWorker(lease.worker, reusable: true, forIndexing: forIndexing, indexEpoch: lease.indexEpoch, globalEpoch: lease.globalEpoch)
                return .response(response)
            case .pipeBroken:
                releaseWorker(lease.worker, reusable: false, forIndexing: forIndexing, indexEpoch: lease.indexEpoch, globalEpoch: lease.globalEpoch)
                if attempt == 0 { continue }
                return .cancelledOrRetry
            case .cancelled:
                releaseWorker(lease.worker, reusable: false, forIndexing: forIndexing, indexEpoch: lease.indexEpoch, globalEpoch: lease.globalEpoch)
                return .cancelledOrRetry
            case .crashed:
                releaseWorker(lease.worker, reusable: false, forIndexing: forIndexing, indexEpoch: lease.indexEpoch, globalEpoch: lease.globalEpoch)
                return .failed
            }
        }
        return .cancelledOrRetry
    }

    private static func helperText(_ kind: Kind, _ url: URL) -> Outcome {
        let ocr = readsImages.get()
        let request = WorkerRequest(op: kind == .pdf ? .pdf : .image, path: url.path, ocr: ocr)
        switch runViaWorker(request, timeout: 60, backgroundQoS: true, forIndexing: true) {
        case .response(let response):
            guard response.ok, let text = response.text else { return .empty }
            return .text(text)
        case .failed:
            Log.app.notice("内容索引：读不了 \(url.path, privacy: .public)")
            return .empty
        case .cancelledOrRetry:
            return .retryLater
        }
    }

    /// 供剪贴板等非全文索引模块复用子进程 OCR：隔离崩溃并避免主进程常驻百兆 Vision 模型内存。
    static func extractImageText(at url: URL, requireTextSize: Bool = false, timeout: TimeInterval = 30) -> String? {
        if requireTextSize && !hasTextSizedPixels(url) { return "" }
        let request = WorkerRequest(op: .image, path: url.path, ocr: true)
        switch runViaWorker(request, timeout: timeout, backgroundQoS: true) {
        case .response(let response):
            return response.ok ? response.text : nil
        case .failed, .cancelledOrRetry:
            return nil
        }
    }

    /// 把内存里的截图临时落盘为私密 PNG，交给短命子进程做 Vision OCR，用完立即删除。
    private static func withTemporaryPNG(_ image: CGImage, _ body: (URL) throws -> Void) rethrows {
        let dir = FileManager.default.temporaryDirectory
        let file = dir.appendingPathComponent("MacShun-ocr-\(UUID().uuidString).png")
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return }
        guard FileManager.default.createFile(atPath: file.path, contents: data as Data, attributes: [.posixPermissions: 0o600]) else { return }
        defer { try? FileManager.default.removeItem(at: file) }
        try body(file)
    }

    /// 供截图取字使用：打包版走短命子进程，避免主进程常驻 Vision 模型并支持取消。
    static func recognizeTextInSubprocess(
        in image: CGImage,
        timeout: TimeInterval = 30,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) -> String {
        guard helperExecutable != nil else { return recognizeText(in: image) }
        var output = ""
        withTemporaryPNG(image) { url in
            let request = WorkerRequest(op: .image, path: url.path, ocr: true)
            if case .response(let response) = runViaWorker(request, timeout: timeout, backgroundQoS: false, isCancelled: isCancelled),
               response.ok, let text = response.text {
                output = text
            }
        }
        return output
    }

    /// 供截图辅助打码使用：打包版走短命子进程，支持取消并释放 Vision 模型内存。
    static func recognizeRedactionInSubprocess(
        in image: CGImage,
        timeout: TimeInterval = 15,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> [CGRect] {
        guard helperExecutable != nil else { return try CaptureRedaction.recognizeInProcess(in: image) }
        var result: [CGRect]?
        withTemporaryPNG(image) { url in
            let request = WorkerRequest(op: .redact, path: url.path, ocr: true)
            if case .response(let response) = runViaWorker(request, timeout: timeout, backgroundQoS: false, isCancelled: isCancelled),
               response.ok, let rects = response.rects {
                result = rects.compactMap { row in
                    guard row.count == 4 else { return nil }
                    return CGRect(x: row[0], y: row[1], width: row[2], height: row[3])
                }
            }
        }
        guard let result else { throw CancellationError() }
        return result
    }

    static func pdfTextInProcess(_ url: URL, ocr: Bool) -> String? {
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
            text = text.replacingOccurrences(of: "\u{FFFC}", with: "")
            guard ocr, !text.contains(where: { !$0.isWhitespace }) else { return text }
            // 没有文字层：扫描件，把前面几页画出来认字
            var recognized = ""
            for index in 0 ..< min(document.pageCount, maxOCRPages) {
                autoreleasepool {
                    guard let page = document.page(at: index), let image = render(page) else { return }
                    recognized += recognizeText(in: image) + "\n"
                }
                if recognized.utf8.count > maxTextBytes { break }
            }
            return recognized
        }
    }

    /// 把一页画成图片，长边大约 2000 像素（字够清楚，又不会太慢）
    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = min(2000 / max(bounds.width, bounds.height), 4)
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    /// 图片够大才可能有能认的字。只读文件头，很快
    private static func hasTextSizedPixels(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return min(width, height) >= minImageSide / 2 && max(width, height) >= minImageSide
    }

    /// 认字时图片最多这么多像素：全景照片、超大扫描图缩小再认，免得解出来占几 GB 内存
    static let maxOCRPixels = 30_000_000

    static func imageText(at url: URL) -> String? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
            else { return nil }
            // 按照片里记的方向转正（手机竖着拍的照片存的是横的），太大的按比例缩小
            let scale = min(1, (Double(maxOCRPixels) / (Double(width) * Double(height))).squareRoot())
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, Int(Double(max(width, height)) * scale)),
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return try? recognizedLines(in: image)
        }
    }

    /// 系统的文字识别：简体、繁体中文和英文，一行一段
    static func recognizeText(in image: CGImage) -> String {
        (try? recognizedLines(in: image)) ?? ""
    }

    private static func recognizedLines(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
