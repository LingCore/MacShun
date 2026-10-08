// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import Testing
@testable import MacShun

@Suite("F1 连按两下 Ctrl")
struct DoubleTapDetectorTests {
    private func run(_ steps: [(DoubleTapDetector.Input, Double)]) -> [Bool] {
        var detector = DoubleTapDetector()
        return steps.map { detector.feed($0.0, at: $0.1) }
    }

    private let down = DoubleTapDetector.Input.control(down: true, flags: .maskControl)
    private let up = DoubleTapDetector.Input.control(down: false, flags: [])

    @Test func firesWhenSecondPressIsReleased() {
        #expect(run([(down, 0), (up, 0.1), (down, 0.3), (up, 0.4)]) == [false, false, false, true])
    }

    @Test func tooSlowBetweenTaps() {
        #expect(run([(down, 0), (up, 0.1), (down, 0.6), (up, 0.7)]) == [false, false, false, false])
    }

    @Test func heldTooLong() {
        #expect(run([(down, 0), (up, 0.5), (down, 0.6), (up, 0.7)]) == [false, false, false, false])
        // 第二下按太久也不算
        #expect(run([(down, 0), (up, 0.1), (down, 0.2), (up, 0.8)]) == [false, false, false, false])
    }

    @Test func ctrlShortcutInBetweenResets() {
        // Ctrl+C 之后马上再按 Ctrl，不算连按
        #expect(run([(down, 0), (.other, 0.05), (up, 0.1), (down, 0.2), (up, 0.3)]) == [false, false, false, false, false])
    }

    @Test func tapThenCtrlShortcutDoesNotFire() {
        // 按一下 Ctrl，接着按 Ctrl+V：第二下中间按了 V，不算（搜索框开着时要能粘贴）
        #expect(run([(down, 0), (up, 0.1), (down, 0.2), (.other, 0.25), (up, 0.3)]) == [false, false, false, false, false])
    }

    @Test func otherModifierHeldDoesNotCount() {
        let shiftDown = DoubleTapDetector.Input.control(down: true, flags: [.maskControl, .maskShift])
        let shiftUp = DoubleTapDetector.Input.control(down: false, flags: .maskShift)
        #expect(run([(shiftDown, 0), (shiftUp, 0.1), (shiftDown, 0.2), (shiftUp, 0.3)]) == [false, false, false, false])
    }

    @Test func thirdPressStartsOver() {
        // 触发后接着按，要再连按两下才会再触发
        #expect(run([(down, 0), (up, 0.1), (down, 0.2), (up, 0.3), (down, 0.4), (up, 0.5), (down, 0.6), (up, 0.7)])
            == [false, false, false, true, false, false, false, true])
    }
}

@Suite("F1 文件名匹配")
struct FileMatcherTests {
    private func score(_ query: String, _ name: String, directory: Bool = false, package: Bool = false, depth: Int = 3) -> Double {
        FileMatcher.score(query: FileMatcher.terms(of: query),
                          entry: FileEntry(name: name, isDirectory: directory, isPackage: package), depth: depth)
    }

    @Test func ranksExactThenPrefixThenWordThenContains() {
        let exact = score("report", "report")
        let prefix = score("report", "report-2026.pdf")
        let word = score("report", "q3 report.pdf")
        let inside = score("port", "report.pdf")
        #expect(exact > prefix)
        #expect(prefix > word)
        #expect(word > inside)
        #expect(inside > 0)
    }

    @Test func caseInsensitive() {
        #expect(score("README", "readme.md") > 0)
    }

    @Test func decomposedNamesMatchTypedQueries() {
        // 文件名按分解形式存（HFS+、有的程序这样建），输入法打出来的是合成形式
        let decomposed = "データ.txt".decomposedStringWithCanonicalMapping
        #expect(decomposed.utf8.count != "データ.txt".utf8.count)
        #expect(score("データ", decomposed) > 0)
        #expect(score("cafe\u{301}", "café.md") > 0)
    }

    @Test func chinesePunctuationStartsAWord() {
        #expect(score("报告", "会议纪要、报告.docx") > score("报告", "会议纪要报告.docx") + 15)
        #expect(score("报告", "会议（报告）.docx") > score("报告", "会议纪要报告.docx") + 15)
    }

    @Test func fullwidthLettersDoNotStartAWord() {
        // 全角字母后面不算词的开头
        #expect(score("b", "Ａb.txt") < score("b", "Ａ b.txt"))
    }

    @Test func pinyinInitialsAndFullPinyin() {
        #expect(score("bg", "年度报告.docx") > 0)
        #expect(score("baogao", "年度报告.docx") > 0)
        #expect(score("ndbg", "年度报告.docx") > 0)
        #expect(score("xyz", "年度报告.docx") == 0)
    }

    @Test func chineseQueryMatchesDirectly() {
        #expect(score("报告", "年度报告.docx") > 0)
    }

    @Test func allTermsMustMatch() {
        #expect(score("报告 2026", "2026 年度报告.docx") > 0)
        #expect(score("报告 2025", "2026 年度报告.docx") == 0)
    }

    @Test func appsComeFirst() {
        #expect(score("notes", "Notes.app", directory: true, package: true) > score("notes", "notes", directory: true))
    }

    @Test func shallowerAndShorterWin() {
        #expect(score("todo", "todo.txt", depth: 2) > score("todo", "todo.txt", depth: 8))
        #expect(score("todo", "todo.txt") > score("todo", "todo-old-backup-copy.txt"))
    }

    @Test func appMatchesByDisplayName() {
        let notes = FileEntry(name: "Notes.app", isDirectory: true, isPackage: true, displayName: "备忘录")
        let terms = { FileMatcher.terms(of: $0) }
        #expect(FileMatcher.score(query: terms("bwl"), entry: notes, depth: 2) > 0)
        #expect(FileMatcher.score(query: terms("备忘"), entry: notes, depth: 2) > 0)
        #expect(FileMatcher.score(query: terms("notes"), entry: notes, depth: 2) > 0)
    }

    @Test func findsSubstring() {
        #expect(FileMatcher.find(Array("lo".utf8), in: Array("hello".utf8)) == 3)
        #expect(FileMatcher.find(Array("xyz".utf8), in: Array("hello".utf8)) == nil)
    }
}

@Suite("F1 紧凑存放的文件名")
struct FolderEntriesTests {
    @Test func namesAndFlagsRoundTrip() {
        let folder = FolderEntries([
            FileEntry(name: "Report.PDF", isDirectory: false, isPackage: false),
            FileEntry(name: "Notes.app", isDirectory: true, isPackage: true, displayName: "备忘录"),
            FileEntry(name: "年度报告", isDirectory: true, isPackage: false),
        ])
        #expect(folder.count == 3)
        #expect(folder.indices.map { folder.name(at: $0) } == ["Report.PDF", "Notes.app", "年度报告"])
        #expect(folder.indices.map { folder.displayName(at: $0) } == [nil, "备忘录", nil])
        #expect(folder.indices.map { folder.isDirectory(at: $0) } == [false, true, true])
        // 只认不是“包”的文件夹
        #expect(folder.containsFolder(named: "年度报告"))
        #expect(!folder.containsFolder(named: "Notes.app"))
        #expect(!folder.containsFolder(named: "Report.PDF"))
        #expect(!folder.containsFolder(named: "备忘录"))
    }

    @Test func compactReleasesSpareCapacity() {
        var folder = FolderEntries()
        for i in 0 ..< 3000 { folder.append(FileEntry(name: "文件\(i).txt", isDirectory: false, isPackage: false)) }
        folder.compact()
        // 系统分配内存按档位取整，会多一点，但不会像按两倍增长那样多出一大截
        #expect(Double(folder.bytes.capacity) <= Double(folder.bytes.count) * 1.15 + 64)
        #expect(Double(folder.items.capacity) <= Double(folder.items.count) * 1.15 + 4)
    }

    @Test func byteSyllableMatchAgreesWithCharacterVersion() {
        let names = ["年度报告.docx", "剪贴板", "绿色", "Mac顺 设置", "（草稿）合同"]
        let queries = ["bg", "baogao", "ndbg", "jiantb", "jtb", "lv", "lu", "ls", "macs", "sz", "cght", "xyz", "nd"]
        for name in names {
            let chars = Array(name).filter { !$0.isWhitespace }
            let syllables = Pinyin.syllables(of: chars).map { Array($0) }
            let encoded = FolderEntries.encodePinyin(name)
            for query in queries {
                let expected = PinyinIndex.syllableMatch(Array(query), syllables)
                let actual = encoded.withUnsafeBufferPointer { PinyinIndex.syllableMatch(Array(query.utf8), encoded: $0) }
                #expect(actual == expected, "\(name) / \(query)")
            }
        }
    }

    @Test func searchFindsByNameAndPinyin() {
        let folder = FolderEntries([
            FileEntry(name: "年度报告.docx", isDirectory: false, isPackage: false),
            FileEntry(name: "readme.md", isDirectory: false, isPackage: false),
        ])
        var found: [String] = []
        folder.forEachMatch(FileMatcher.terms(of: "ndbg"), depth: 2) { index, _ in found.append(folder.name(at: index)) }
        #expect(found == ["年度报告.docx"])
        found = []
        folder.forEachMatch(FileMatcher.terms(of: "README"), depth: 2) { index, _ in found.append(folder.name(at: index)) }
        #expect(found == ["readme.md"])
    }
}


@Suite("F1 按路径搜")
struct FilePathQueryTests {
    private func folders(_ query: String) -> [String] {
        FileMatcher.Query(query).folders.map { forms in forms.sorted().joined(separator: "|") }
    }

    private func names(_ query: String) -> [String] {
        FileMatcher.Query(query).terms.map { String(decoding: $0.bytes, as: UTF8.self) }
    }

    @Test func splitsFolderAndName() {
        #expect(folders("art/gpt/style_reference.png") == ["art", "gpt"])
        #expect(names("art/gpt/style_reference.png") == ["style_reference.png"])
        #expect(FileMatcher.Query("art/gpt/style_reference.png").absolutePath == nil)
    }

    @Test func plainQueryHasNoFolder() {
        let query = FileMatcher.Query("q3 report")
        #expect(query.folders.isEmpty && query.absolutePath == nil)
        #expect(names("q3 report") == ["q3", "report"])
    }

    @Test func finderAndWindowsFolderNames() {
        // 访达里显示的“桌面”、Windows 上的“文档”“视频”都对得上真正的文件夹
        #expect(folders("桌面/塔防游戏/art/gpt/style_reference.png") == ["desktop|桌面", "塔防游戏", "art", "gpt"])
        #expect(folders("文档/a.docx") == ["documents|文档"])
        #expect(folders("视频/a.mp4") == ["movies|视频"])
    }

    @Test func windowsPathsQuotesAndSpaces() {
        #expect(folders(#"D:\资料\合同\2026.docx"#) == ["资料", "合同"])
        #expect(names(#"D:\资料\合同\2026.docx"#) == ["2026.docx"])
        // Windows“复制为路径”带引号
        #expect(FileMatcher.Query(#""C:\Users\me\Desktop\a.txt""#).absolutePath == "/Users/me/Desktop/a.txt")
        #expect(folders("桌面 / 塔防游戏 / a.png") == ["desktop|桌面", "塔防游戏"])
        #expect(names("桌面 / 塔防游戏 / a.png") == ["a.png"])
        // 最后带 / 的是文件夹本身
        #expect(folders("art/gpt/") == ["art"])
        #expect(names("art/gpt/") == ["gpt"])
        #expect(folders("./src/Main.swift") == ["src"])
        // 名字里有空格：名字照样按空格分开匹配
        #expect(folders("My Docs/Q3 report.pdf") == ["my docs"])
        #expect(names("My Docs/Q3 report.pdf") == ["q3", "report.pdf"])
    }

    @Test func copiedPathsWithNewlinesEscapesAndShares() {
        // 从终端、聊天里复制的路径后面常带换行
        #expect(FileMatcher.Query("/Users/me/a.txt\n").absolutePath == "/Users/me/a.txt")
        #expect(FileMatcher.Query("\"C:\\Users\\me\\a.txt\"\n").absolutePath == "/Users/me/a.txt")
        #expect(names("\"C:\\Users\\me\\a.txt\"\n") == ["a.txt"])
        // 拖进终端的路径：空格前面有 \
        #expect(FileMatcher.Query(#"/Users/me/My\ Project/a\ b.txt"#).absolutePath == "/Users/me/My Project/a b.txt")
        #expect(folders(#"My\ Project/a\ b.txt"#) == ["my project"])
        // Windows 网络共享：接上以后在 /Volumes 里
        #expect(FileMatcher.Query(#"\\NAS\资料\a.docx"#).absolutePath == "/Volumes/资料/a.docx")
        // .. 回到上一层
        #expect(FileMatcher.Query("/Users/me/Desktop/../a.txt").absolutePath == "/Users/me/a.txt")
        #expect(folders("../shared/util.ts") == ["shared"])
    }

    @Test func slashInsideAFinderName() {
        // 访达里显示“AC/DC”的文件，存的名字是“AC:DC”
        let query = FileMatcher.Query("AC/DC")
        let nameTerms = try! #require(query.nameTerms)
        let entry = FileEntry(name: "AC:DC.mp3", isDirectory: false, isPackage: false)
        #expect(FileMatcher.score(query: nameTerms, entry: entry, depth: 3) > FileMatcher.score(query: query.terms, entry: entry, depth: 3))
        // 完整路径、Windows 路径不会是名字
        #expect(FileMatcher.Query("/Users/me/a.txt").nameTerms == nil)
        #expect(FileMatcher.Query(#"D:\a\b.txt"#).nameTerms == nil)
    }

    @Test func absoluteHomeAndFileURLs() {
        #expect(FileMatcher.Query("/Users/me/a.txt").absolutePath == "/Users/me/a.txt")
        #expect(FileMatcher.Query("~/Desktop/a.txt").absolutePath == NSHomeDirectory() + "/Desktop/a.txt")
        #expect(FileMatcher.Query("file:///Users/me/My%20Docs/a.txt").absolutePath == "/Users/me/My Docs/a.txt")
        #expect(names("file:///Users/me/My%20Docs/a.txt") == ["a.txt"])
    }

    @Test func folderBonusRanksCloserPathsHigher() {
        let query = FileMatcher.Query("桌面/塔防游戏/art/gpt/style_reference.png")
        let exact = query.folderBonus("/Users/me/Desktop/塔防游戏/Art/GPT")
        let deeper = query.folderBonus("/Users/me/Desktop/塔防游戏/art/gpt/old")
        let partly = query.folderBonus("/Users/me/Desktop/塔防游戏/art/gpt_old")
        let elsewhere = query.folderBonus("/Users/me/Downloads")
        #expect(exact == 40 && deeper == 30)
        #expect(partly > 0 && partly < deeper)
        #expect(elsewhere == 0)
        #expect(FileMatcher.Query("style_reference").folderBonus("/anywhere") == 0)
    }

    @Test func existingAbsolutePathComesFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macshun-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Note.txt").path
        FileManager.default.createFile(atPath: file, contents: Data())
        // 索引里搜到的，用索引里的写法，不重复
        var matches = [FileSearchResult(path: file, name: "Note.txt", isDirectory: false, score: 120)]
        let hit = FileIndex.existingFile(file.replacingOccurrences(of: "Note.txt", with: "note.txt"), among: &matches)
        #expect(hit?.path == file && hit?.score == 1000)
        #expect(matches.isEmpty)
        var none: [FileSearchResult] = []
        #expect(FileIndex.existingFile(dir.appendingPathComponent("missing.txt").path, among: &none) == nil)
    }
}
