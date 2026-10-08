// SPDX-License-Identifier: MIT

import Compression
import CoreText
import ImageIO
import Foundation
import Testing
@testable import MacShun

/// 在内存里拼一个 zip（docx、xlsx、pptx 的外壳）。deflate 为 false 时用“存储”方式。
private func makeZip(_ files: [(name: String, content: String)], deflate: Bool = true) -> Data {
    func le16(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)]) }
    func le32(_ v: Int) -> Data { le16(v & 0xFFFF) + le16(v >> 16 & 0xFFFF) }
    var body = Data(), directory = Data()
    for file in files {
        let raw = Data(file.content.utf8), name = Data(file.name.utf8)
        var payload = raw, method = 0
        if deflate {
            var buffer = [UInt8](repeating: 0, count: raw.count + 1024)
            let size = raw.withUnsafeBytes {
                compression_encode_buffer(&buffer, buffer.count, $0.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
            }
            payload = Data(buffer.prefix(size))
            method = 8
        }
        let offset = body.count
        let local: [Data] = [le32(0x0403_4B50), le16(20), le16(0), le16(method), le16(0), le16(0), le32(0),
                             le32(payload.count), le32(raw.count), le16(name.count), le16(0), name, payload]
        let central: [Data] = [le32(0x0201_4B50), le16(20), le16(20), le16(0), le16(method), le16(0), le16(0), le32(0),
                               le32(payload.count), le32(raw.count), le16(name.count), le16(0), le16(0), le16(0), le16(0),
                               le32(0), le32(offset), name]
        local.forEach { body.append($0) }
        central.forEach { directory.append($0) }
    }
    let end: [Data] = [le32(0x0605_4B50), le16(0), le16(0), le16(files.count), le16(files.count),
                       le32(directory.count), le32(body.count), le16(0)]
    var zip = body
    zip.append(directory)
    end.forEach { zip.append($0) }
    return zip
}

private func temporaryFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacShunTests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let docxXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
    <w:p><w:r><w:t>合同金额</w:t></w:r><w:r><w:tab/><w:t xml:space="preserve">1000 元</w:t></w:r></w:p>
    <w:p><w:r><w:t>第二段 &amp; more</w:t></w:r></w:p>
    </w:body></w:document>
    """

@Suite("F2 读出文件里的文字")
struct ContentExtractorTests {
    @Test func zipStoredAndDeflated() {
        for deflate in [false, true] {
            let zip = ZipReader(data: makeZip([("a.txt", "hello"), ("dir/b.xml", String(repeating: "合同", count: 500))], deflate: deflate))
            #expect(zip?.names == ["a.txt", "dir/b.xml"])
            #expect(zip?.read("a.txt").map { String(decoding: $0, as: UTF8.self) } == "hello")
            #expect(zip?.read("dir/b.xml")?.count == 3000)
            #expect(zip?.read("missing") == nil)
        }
    }

    @Test func notAZip() {
        #expect(ZipReader(data: Data("just text".utf8)) == nil)
        #expect(ZipReader(data: Data()) == nil)
    }

    @Test func docx() throws {
        let folder = temporaryFolder()
        let file = folder.appendingPathComponent("合同.docx")
        try makeZip([("[Content_Types].xml", "<Types/>"), ("word/document.xml", docxXML)]).write(to: file)
        let text = try #require(ContentExtractor.extract(path: file.path, kind: .docx))
        #expect(text.contains("合同金额 1000 元"))
        #expect(text.contains("第二段 & more"))
        #expect(text.split(separator: "\n").count == 2)
    }

    @Test func xlsxSharedAndInlineStrings() throws {
        let folder = temporaryFolder()
        let file = folder.appendingPathComponent("客户.xlsx")
        let shared = "<sst><si><t>客户名称</t></si><si><r><t>张</t></r><r><t>三</t></r><rPh><t>ちょう</t></rPh></si></sst>"
        let sheet = "<worksheet><sheetData><row><c t=\"inlineStr\"><is><t>直接写的字</t></is></c><c><v>42</v></c></row></sheetData></worksheet>"
        try makeZip([("xl/sharedStrings.xml", shared), ("xl/worksheets/sheet1.xml", sheet)]).write(to: file)
        let text = try #require(ContentExtractor.extract(path: file.path, kind: .xlsx))
        #expect(text.contains("客户名称"))
        #expect(text.contains("张三"))
        #expect(!text.contains("ちょう"))   // 注音不要
        #expect(text.contains("直接写的字"))
        #expect(!text.contains("42"))       // 数字格子不读
    }

    @Test func pptxSlidesInPageOrder() throws {
        let folder = temporaryFolder()
        let file = folder.appendingPathComponent("汇报.pptx")
        func slide(_ text: String) -> String { "<p:sld xmlns:a=\"a\" xmlns:p=\"p\"><a:p><a:r><a:t>\(text)</a:t></a:r></a:p></p:sld>" }
        try makeZip([("ppt/slides/slide10.xml", slide("第十页")), ("ppt/slides/slide2.xml", slide("第二页")),
                     ("ppt/notesSlides/notesSlide2.xml", slide("备注"))]).write(to: file)
        let text = try #require(ContentExtractor.extract(path: file.path, kind: .pptx))
        #expect(text == "第二页\n第十页\n备注\n" || text == "第二页\n\n第十页\n\n备注\n")
    }

    @Test func textEncodings() {
        #expect(ContentExtractor.decodeText(Data("合同 abc".utf8)) == "合同 abc")
        #expect(ContentExtractor.decodeText(Data([0xEF, 0xBB, 0xBF]) + Data("合同".utf8)) == "合同")
        #expect(ContentExtractor.decodeText(Data([0xFF, 0xFE, 0x08, 0x54, 0x0C, 0x54])) == "合同")   // UTF-16LE
        #expect(ContentExtractor.decodeText(Data([0xBA, 0xCF, 0xCD, 0xAC])) == "合同")              // GBK
        #expect(ContentExtractor.decodeText(Data([0x50, 0x4B, 0x03, 0x04, 0x00, 0x00])) == nil)    // 二进制
    }

    @Test func textCutInTheMiddleOfACharacter() {
        let utf8 = Data("合同".utf8) + Data([0xE9, 0x87])          // “金”的前两个字节
        #expect(ContentExtractor.decodeText(utf8, truncated: true) == "合同")
        let gbk = Data([0xBA, 0xCF, 0xCD, 0xAC, 0xBD])              // GBK “合同” 加半个字
        #expect(ContentExtractor.decodeText(gbk, truncated: true) == "合同")
    }

    @Test func jsonUnicodeEscapes() {
        #expect(ContentExtractor.unescapeJSON(#"{"a": "合同"}"#) == #"{"a": "合同"}"#)
        #expect(ContentExtractor.unescapeJSON(#"{"a": "\\u0041"}"#) == #"{"a": "\\u0041"}"#)
        #expect(ContentExtractor.unescapeJSON(#""😀""#) == "\"😀\"")
    }

    @Test func truncatesOnCharacterBoundary() {
        #expect(ContentExtractor.truncated("合同abc", maxBytes: 4) == "合")
        #expect(ContentExtractor.truncated("合同abc", maxBytes: 7) == "合同a")
        #expect(ContentExtractor.truncated("abc", maxBytes: 10) == "abc")
    }

    @Test func whichFiles() {
        #expect(ContentExtractor.kind(ofFileNamed: "报告.DOCX") == .docx)
        #expect(ContentExtractor.kind(ofFileNamed: "data.csv") == .text)
        #expect(ContentExtractor.kind(ofFileNamed: "~$报告.docx") == nil)   // Office 的临时文件
        #expect(ContentExtractor.kind(ofFileNamed: "movie.mp4") == nil)
        #expect(ContentExtractor.kind(ofFileNamed: "README") == nil)
    }
}

@Suite("F2 内容索引")
struct ContentIndexTests {
    @Test func cjkCharactersBecomeWords() {
        #expect(ContentIndex.ftsText("合同abc") == " 合  同 abc")
    }

    @Test func queryLength() {
        #expect(!ContentIndex.qualifies("的"))
        #expect(ContentIndex.qualifies("合同"))
        #expect(!ContentIndex.qualifies("ab"))
        #expect(ContentIndex.qualifies("abc"))
        #expect(ContentIndex.qualifies("表a"))
        #expect(!ContentIndex.qualifies("..."))
    }

    @Test func matchExpressions() {
        #expect(ContentIndex.matchExpression(for: "合同") == "\" 合  同 \"")
        #expect(ContentIndex.matchExpression(for: "inv") == "\"inv\" *")
        #expect(ContentIndex.matchExpression(for: "合同 2026") == "\" 合  同 \" AND \"2026\" *")
        #expect(ContentIndex.matchExpression(for: "a\"bc") == "\"a\"\"bc\" *")
        #expect(ContentIndex.matchExpression(for: "的") == nil)
        // 单个字母不参与（以它开头的词太多）；结尾只有一个字母时不按前缀
        #expect(ContentIndex.matchExpression(for: "合同 a") == "\" 合  同 \"")
        #expect(ContentIndex.matchExpression(for: "a b c") == nil)
        #expect(ContentIndex.matchExpression(for: "合同a") == "\" 合  同 a\"")
    }

    @Test func phrasesDoNotSpanPunctuation() {
        let b = String(ContentIndex.boundary)
        #expect(ContentIndex.ftsText("符合。同时") == " 符  合 。 \(b)  同  时 ")
        #expect(ContentIndex.ftsText("合\n同") == " 合 \n 同 ")          // 换行不隔开
        #expect(ContentIndex.ftsText("annual report") == "annual report")   // 空格不隔开
        #expect(ContentIndex.ftsText("合同。") == " 合  同 。")             // 末尾的标点不加
        #expect(ContentIndex.ftsText("e-mail") == "e-mail")                 // 英文不加
        #expect(ContentIndex.ftsText("合同, Contract") == " 合  同 , Contract")
    }

    @Test func codeAndSubtitleFilesAreRead() {
        #expect(ContentExtractor.kind(ofFileNamed: "auth.ts") == .text)
        #expect(ContentExtractor.kind(ofFileNamed: "main.py") == .text)
        #expect(ContentExtractor.kind(ofFileNamed: "电影.srt") == .text)
        #expect(ContentExtractor.kind(ofFileNamed: "app.min.js") == nil)          // 压缩过的
        #expect(ContentExtractor.kind(ofFileNamed: "package-lock.json") == nil)   // 锁文件
        #expect(ContentExtractor.kind(ofFileNamed: "server.log") == nil)          // 日志一直在写，不读
    }

    @Test func htmlKeepsOnlyText() {
        let html = """
            <html><head><title>报价单</title><style>p { color: red }</style><script>var a = "<b>";</script></head>
            <body><p>合同金额&nbsp;128&#44;000 元</p><!-- 备注 --><div>&#x4e2d;文 &amp; English</div></body></html>
            """
        let text = ContentExtractor.htmlText(html)
        #expect(text.contains("报价单"))
        #expect(text.contains("合同金额 128,000 元"))
        #expect(text.contains("中文 & English"))
        #expect(!text.contains("color"))
        #expect(!text.contains("var a"))
        #expect(!text.contains("备注"))
        // 脚本、样式、注释几乎都占好几行
        let multiline = ContentExtractor.htmlText("""
            <p>正文</p>
            <script>
              const secret = 1
            </script>
            <style>
              .a { color: red }
            </style>
            <!--
              说明
            -->
            """)
        #expect(multiline.contains("正文"))
        #expect(!multiline.contains("secret") && !multiline.contains("color") && !multiline.contains("说明"))
    }

    @Test func nulCharactersDoNotCutText() throws {
        let file = temporaryFolder().appendingPathComponent("a.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"a": "前面\u0000后面的合同"}"#.utf8).write(to: file)
        let text = ContentExtractor.extract(path: file.path, kind: .text)
        #expect(text?.contains("后面的合同") == true)
        #expect(text?.contains("\u{0}") == false)
    }

    @Test func snippetAroundFirstMatch() {
        #expect(ContentIndex.snippet(in: "第一行\n这里是合同金额一百万元", terms: ["合同"]) == "这里是合同金额一百万元")
        let long = String(repeating: "前", count: 40) + "Invoice 2026"
        #expect(ContentIndex.snippet(in: long, terms: ["invoice"]) == "…" + String(repeating: "前", count: 14) + "Invoice 2026")
        #expect(ContentIndex.snippet(in: "a\n\n  b\tc", terms: ["zzz"]) == "a b c")
    }

    @Test func indexSearchUpdateAndDelete() throws {
        let folder = temporaryFolder()
        let indexFolder = folder.appendingPathComponent("index")
        let files = folder.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let note = files.appendingPathComponent("笔记.txt")
        let table = files.appendingPathComponent("客户.csv")
        let word = files.appendingPathComponent("协议.docx")
        try "第一行\n这份合同下周签".write(to: note, atomically: true, encoding: .utf8)
        try Data([0xBF, 0xCD, 0xBB, 0xA7, 0x2C, 0x41, 0x63, 0x6D, 0x65]).write(to: table)   // GBK：客户,Acme
        try makeZip([("word/document.xml", docxXML)]).write(to: word)
        let all = [note.path, table.path, word.path]
        let scope = [ContentIndex.Scope(folder: files.path, recursive: true)]

        let index = ContentIndex(directory: indexFolder)
        index.start()
        index.sync(files: all, scopes: scope)
        index.waitUntilIdle()
        #expect(index.documentCountNow == 3)
        #expect(Set(index.searchNow("合同").map(\.path)) == [note.path, word.path])
        #expect(index.searchNow("合作").isEmpty)
        #expect(index.searchNow("客户").map(\.path) == [table.path])
        #expect(index.searchNow("acm").map(\.path) == [table.path])        // 英文按前缀
        #expect(index.searchNow("合同 下周").map(\.path) == [note.path])  // 几个词都要有
        #expect(index.searchNow("合同 下周").first?.snippet == "这份合同下周签")

        // 改了内容：旧的字搜不到，新的搜得到
        try "改成了报价单".write(to: note, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: note.path)
        index.sync(files: all, scopes: scope)
        index.waitUntilIdle()
        #expect(index.searchNow("合同").map(\.path) == [word.path])
        #expect(index.searchNow("报价").map(\.path) == [note.path])

        // 删掉的文件从索引里去掉
        try FileManager.default.removeItem(at: word)
        index.sync(files: [note.path, table.path], scopes: scope)
        index.waitUntilIdle()
        #expect(index.searchNow("合同").isEmpty)
        #expect(index.documentCountNow == 2)

        // 重新打开：读过的不再读，照样搜得到
        let reopened = ContentIndex(directory: indexFolder)
        reopened.start()
        reopened.sync(files: [note.path, table.path], scopes: scope)
        reopened.waitUntilIdle()
        #expect(reopened.documentCountNow == 2)
        #expect(reopened.searchNow("报价").map(\.path) == [note.path])

        // 关掉后索引文件删除
        reopened.stop(deleteData: true)
        reopened.waitUntilIdle()
        #expect(!FileManager.default.fileExists(atPath: indexFolder.path))
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func skipsFileThatCrashedLastTime() throws {
        let folder = temporaryFolder()
        let indexFolder = folder.appendingPathComponent("index")
        let bad = folder.appendingPathComponent("坏文件.txt")
        let good = folder.appendingPathComponent("好文件.txt")
        try "合同一".write(to: bad, atomically: true, encoding: .utf8)
        try "合同二".write(to: good, atomically: true, encoding: .utf8)
        // 假装上次读 bad 的时候程序崩了
        try FileManager.default.createDirectory(at: indexFolder, withIntermediateDirectories: true)
        try Data(bad.path.utf8).write(to: indexFolder.appendingPathComponent("reading"))
        let index = ContentIndex(directory: indexFolder)
        index.start()
        index.sync(files: [bad.path, good.path], scopes: [ContentIndex.Scope(folder: folder.path, recursive: true)])
        index.waitUntilIdle()
        #expect(index.searchNow("合同").map(\.path) == [good.path])
        #expect(!FileManager.default.fileExists(atPath: indexFolder.appendingPathComponent("reading").path))
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func batchThatWasInterruptedIsReadAgainOneByOne() throws {
        let folder = temporaryFolder()
        let indexFolder = folder.appendingPathComponent("index")
        let first = folder.appendingPathComponent("一.txt")
        let second = folder.appendingPathComponent("二\n换行.txt")   // 名字里有换行
        try "合同一".write(to: first, atomically: true, encoding: .utf8)
        try "合同二".write(to: second, atomically: true, encoding: .utf8)
        // 假装上次读这一批（两个文件）的时候程序退出了：不知道是哪个，这次单独读，都能搜到
        try FileManager.default.createDirectory(at: indexFolder, withIntermediateDirectories: true)
        try Data([first.path, second.path].joined(separator: "\0").utf8).write(to: indexFolder.appendingPathComponent("reading"))
        let index = ContentIndex(directory: indexFolder)
        index.start()
        index.sync(files: [first.path, second.path], scopes: [ContentIndex.Scope(folder: folder.path, recursive: true)])
        index.waitUntilIdle()
        #expect(Set(index.searchNow("合同").map(\.path)) == [first.path, second.path])
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func manyScopesMatchLikeOne() {
        let scopes = (0 ..< 20).map { ContentIndex.Scope(folder: "/x/\($0)", recursive: $0 % 2 == 0) }
        let set = ContentIndex.ScopeSet(scopes)
        for path in ["/x/2/a.txt", "/x/2/d/a.txt", "/x/3/a.txt", "/x/3/d/a.txt", "/x/30/a.txt", "/y/a.txt", "/x/a.txt"] {
            #expect(set.contains(path) == scopes.contains { $0.contains(path) }, "\(path)")
        }
    }

    @Test func scopes() {
        let flat = ContentIndex.Scope(folder: "/a/b", recursive: false)
        let deep = ContentIndex.Scope(folder: "/a/b", recursive: true)
        #expect(flat.contains("/a/b/c.txt"))
        #expect(!flat.contains("/a/b/d/c.txt"))
        #expect(deep.contains("/a/b/d/c.txt"))
        #expect(!deep.contains("/a/bc/c.txt"))
    }
}

@Suite("F2 搜索范围")
struct FileSearchScopeTests {
    private func makeModel() -> FileSearchModel {
        let index = ContentIndex(directory: temporaryFolder().appendingPathComponent("index"))
        return FileSearchModel(index: FileIndex.shared, contentIndex: index)
    }

    @Test func defaultsToFilesAndTabCycles() {
        let model = makeModel()
        model.searchesContent = true
        model.prepareForShow()
        #expect(model.scope == .files)
        model.cycleScope(reverse: false)
        #expect(model.scope == .contents)
        model.cycleScope(reverse: false)
        #expect(model.scope == .all)
        model.cycleScope(reverse: true)
        #expect(model.scope == .contents)
        // 每次打开都回到“文件”
        model.prepareForShow()
        #expect(model.scope == .files)
    }

    @Test func contentSearchOffMeansFilesOnly() {
        let model = makeModel()
        model.searchesContent = false
        model.scope = .contents
        #expect(model.effectiveScope == .files)
        model.cycleScope(reverse: false)
        #expect(model.scope == .contents)   // 关着时 Tab 不起作用
    }

    @Test func shortQueryInContentsScopeAsksForMore() {
        let model = makeModel()
        model.searchesContent = true
        model.scope = .contents
        model.query = "合"
        #expect(model.needsLongerQuery)
        model.query = "合同"
        #expect(!model.needsLongerQuery)
        model.scope = .files
        model.query = "合"
        #expect(!model.needsLongerQuery)
    }

    /// 结果右边的“删除”：点两下才删，双击的第二下不算，点别的、打字就取消
    @Test func deleteButtonNeedsTwoClicks() {
        let model = makeModel()
        var done: [String] = []
        model.onAction = { result, action in
            switch action {
            case .trash: done.append("删 " + result.name)
            case .copy: done.append("复制 " + result.name)
            default: done.append("其他")
            }
        }
        let a = FileSearchResult(path: "/x/a.txt", name: "a.txt", isDirectory: false, score: 1)
        let b = FileSearchResult(path: "/x/b.txt", name: "b.txt", isDirectory: false, score: 1)

        model.tapped(.delete, on: a)
        #expect(model.confirmingDelete == a.path && done.isEmpty)
        model.tapped(.delete, on: a, clickCount: 2)
        #expect(model.confirmingDelete == a.path && done.isEmpty)
        // 点了另一条的删除：改成等那一条确认
        model.tapped(.delete, on: b)
        #expect(model.confirmingDelete == b.path)
        model.tapped(.delete, on: a)
        model.tapped(.delete, on: a)
        #expect(model.confirmingDelete == nil && done == ["删 a.txt"])

        model.tapped(.delete, on: b)
        model.query = "b"
        #expect(model.confirmingDelete == nil)
        model.tapped(.delete, on: b)
        model.tapped(.copy, on: b)
        #expect(model.confirmingDelete == nil && done == ["删 a.txt", "复制 b.txt"])
    }
}

@Suite("F2 图片文字和常用排序")
struct ImageTextAndHistoryTests {
    /// 画一张白底黑字的图
    private func textImage(_ text: String) -> CGImage {
        let width = 1200, height = 300
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("PingFang SC" as CFString, 96, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]))
        context.textPosition = CGPoint(x: 60, y: 110)
        CTLineDraw(line, context)
        return context.makeImage()!
    }

    @Test func imagesAreReadUnlessTurnedOff() {
        #expect(ContentExtractor.kind(ofFileNamed: "截图 2026-10-03.png") == .image)
        #expect(ContentExtractor.kind(ofFileNamed: "照片.HEIC") == .image)
        ContentExtractor.readsImages.set(false)
        defer { ContentExtractor.readsImages.set(true) }
        #expect(ContentExtractor.kind(ofFileNamed: "截图.png") == nil)
    }

    @Test func recognizesTextInScreenshotsAndScannedPDFs() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacShunOCR-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = textImage("合同金额 Invoice")

        // 截图
        let png = folder.appendingPathComponent("截图.png")
        let destination = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let fromImage = ContentExtractor.extract(path: png.path, kind: .image)
        #expect(fromImage?.contains("合同") == true, "\(fromImage ?? "nil")")
        #expect(fromImage?.contains("Invoice") == true)

        // 扫描版 PDF：页面上只有一张图，没有文字层
        let pdf = folder.appendingPathComponent("扫描件.pdf")
        var box = CGRect(x: 0, y: 0, width: 600, height: 150)
        let pdfContext = CGContext(pdf as CFURL, mediaBox: &box, nil)!
        pdfContext.beginPDFPage(nil)
        pdfContext.draw(image, in: box)
        pdfContext.endPDFPage()
        pdfContext.closePDF()
        let fromPDF = ContentExtractor.extract(path: pdf.path, kind: .pdf)
        #expect(fromPDF?.contains("合同") == true, "\(fromPDF ?? "nil")")
        // 关掉“认图片里的文字”时扫描版 PDF 也不认
        #expect(ContentExtractor.pdfTextInProcess(pdf, ocr: false)?.contains("合同") != true)

        // 手机竖着拍的照片：像素是横着存的，靠照片里记的方向转正
        let rotated: CGImage = {
            let context = CGContext(data: nil, width: image.height, height: image.width, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.translateBy(x: CGFloat(image.height), y: 0)
            context.rotate(by: .pi / 2)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return context.makeImage()!
        }()
        let photo = folder.appendingPathComponent("竖拍.jpg")
        let photoDestination = CGImageDestinationCreateWithURL(photo as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(photoDestination, rotated, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(photoDestination))
        let fromPhoto = ContentExtractor.extract(path: photo.path, kind: .image)
        #expect(fromPhoto?.contains("合同") == true, "\(fromPhoto ?? "nil")")

        // 图标这种小图不认
        let icon = folder.appendingPathComponent("icon.png")
        let small = textImage("合同").cropping(to: CGRect(x: 0, y: 0, width: 64, height: 64))!
        let iconDestination = CGImageDestinationCreateWithURL(icon as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(iconDestination, small, nil)
        CGImageDestinationFinalize(iconDestination)
        #expect(ContentExtractor.extract(path: icon.path, kind: .image) == nil)
    }

    @Test func openedFilesRankHigher() {
        let defaults = UserDefaults(suiteName: "MacShunTests-\(UUID().uuidString)")!
        let history = OpenHistory(defaults: defaults)
        let now = Date()
        history.record("/a.txt", at: now)
        history.record("/a.txt", at: now)
        history.record("/old.txt", at: now.addingTimeInterval(-30 * 86400))
        let boosts = history.boosts(now: now)
        #expect(boosts["/a.txt"] == 12)      // 两次 + 一周内打开过
        #expect(boosts["/old.txt"] == 3)     // 一次，很久以前
        #expect(boosts["/never.txt"] == nil)
        // 存下来了，重新打开还在
        #expect(OpenHistory(defaults: defaults).boosts(now: now)["/a.txt"] == 12)
        // 加满也排不过“包含”和“开头一样”之间的差距
        for _ in 0 ..< 20 { history.record("/a.txt", at: now) }
        #expect(history.boosts(now: now)["/a.txt"] == 24)
        history.clear()
        #expect(OpenHistory(defaults: defaults).boosts(now: now).isEmpty)
    }
}
