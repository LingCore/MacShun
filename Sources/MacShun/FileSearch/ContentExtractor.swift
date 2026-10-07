// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import ImageIO
import PDFKit
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

    /// 网页里的文字：去掉脚本、样式、注释和标签，段落处换行，换回常见的字符实体。
    static func htmlText(_ html: String) -> String {
        var text = html
        // (?s)：. 也匹配换行，脚本、样式、注释几乎都占好几行
        for pattern in ["(?s)<script\\b[^>]*>.*?</script\\s*>", "(?s)<style\\b[^>]*>.*?</style\\s*>", "(?s)<!--.*?-->"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<(br|/p|/div|/li|/tr|/h[1-6]|/title)\\b[^>]*>", with: "\n",
                                         options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        // &#20013; &#x4e2d; 这类写法的字
        if text.contains("&#") {
            let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);")
            let ns = text as NSString
            var out = ""
            var last = 0
            for match in regex?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [] {
                out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let code = ns.substring(with: match.range(at: 1))
                let value = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
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

    // MARK: - PDF 和图片（子进程）

    static let helperArguments: [Kind: String] = [.pdf: "--extract-pdf-text", .image: "--extract-image-text"]

    /// 扫描版 PDF 要不要认字（跟着“认图片里的文字”）
    static let ocrArgument = "--ocr"

    /// 是读 PDF 或认图片文字的子进程时，返回要读的种类和文件
    static func helperRequest(in arguments: [String]) -> (kind: Kind, path: String, ocr: Bool)? {
        for (kind, argument) in helperArguments {
            if let index = arguments.firstIndex(of: argument), index + 1 < arguments.count {
                return (kind, arguments[index + 1], arguments.contains(ocrArgument))
            }
        }
        return nil
    }

    /// 子进程：把文字写到标准输出后退出。
    static func runHelper(kind: Kind, path: String, ocr: Bool) -> Never {
        // 主程序一分钟就会结束卡住的子进程；主程序退出或崩了没人管时，自己最多活一分半
        alarm(90)
        let url = URL(fileURLWithPath: path)
        guard let text = kind == .pdf ? pdfTextInProcess(url, ocr: ocr) : imageTextInProcess(url) else { exit(1) }
        FileHandle.standardOutput.write(Data(text.utf8))
        exit(0)
    }

    /// 打包好的 Mac顺 用子进程读；测试和截图工具里没有 Mac顺 程序可启动，直接读。
    private static let helperExecutable: URL? =
        Bundle.main.bundleIdentifier == "io.github.lingcore.winshun" ? Bundle.main.executableURL : nil

    private static func helperText(_ kind: Kind, _ url: URL) -> Outcome {
        let ocr = readsImages.get()
        guard let executable = helperExecutable, let argument = helperArguments[kind] else {
            let text = kind == .pdf ? pdfTextInProcess(url, ocr: ocr) : imageTextInProcess(url)
            return text.map { .text($0) } ?? .empty
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [argument, url.path] + (ocr ? [ocrArgument] : [])
        // 建索引不急（扫描版 PDF、图片还要认字），让给前台的程序
        process.qualityOfService = .background
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return .retryLater }
        // 卡住的文件最多等一分钟（扫描版 PDF 要认好几页）；不理 SIGTERM 时再过 3 秒强制结束
        let pid = process.processIdentifier
        let timedOut = Locked(false)
        let timeout = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.set(true)
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        // 超时多半是电脑太忙（子进程优先级最低），下次再读；子进程崩了是文件的问题，记下来不再读
        if timedOut.get() { return .retryLater }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            Log.app.notice("内容索引：读不了 \(url.path, privacy: .public)")
            return .empty
        }
        return .text(String(decoding: data, as: UTF8.self))
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

    private static func imageTextInProcess(_ url: URL) -> String? {
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
            return recognizeText(in: image)
        }
    }

    /// 系统的文字识别：简体、繁体中文和英文，一行一段
    static func recognizeText(in image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
