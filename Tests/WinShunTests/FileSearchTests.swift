// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Testing
@testable import WinShun

@Suite("F1 连按两下 Ctrl")
struct DoubleTapDetectorTests {
    private func run(_ steps: [(DoubleTapDetector.Input, Double)]) -> [Bool] {
        var detector = DoubleTapDetector()
        return steps.map { detector.feed($0.0, at: $0.1) }
    }

    private let down = DoubleTapDetector.Input.control(down: true, flags: .maskControl)
    private let up = DoubleTapDetector.Input.control(down: false, flags: [])

    @Test func firesOnSecondPress() {
        #expect(run([(down, 0), (up, 0.1), (down, 0.3)]) == [false, false, true])
    }

    @Test func tooSlowBetweenTaps() {
        #expect(run([(down, 0), (up, 0.1), (down, 0.6)]) == [false, false, false])
    }

    @Test func heldTooLong() {
        #expect(run([(down, 0), (up, 0.5), (down, 0.6)]) == [false, false, false])
    }

    @Test func ctrlShortcutInBetweenResets() {
        // Ctrl+C 之后马上再按 Ctrl，不算连按
        #expect(run([(down, 0), (.other, 0.05), (up, 0.1), (down, 0.2)]) == [false, false, false, false])
    }

    @Test func otherModifierHeldDoesNotCount() {
        let shiftDown = DoubleTapDetector.Input.control(down: true, flags: [.maskControl, .maskShift])
        let shiftUp = DoubleTapDetector.Input.control(down: false, flags: .maskShift)
        #expect(run([(shiftDown, 0), (shiftUp, 0.1), (shiftDown, 0.2)]) == [false, false, false])
    }

    @Test func thirdPressStartsOver() {
        // 触发后接着按，要再连按两下才会再触发
        #expect(run([(down, 0), (up, 0.1), (down, 0.2), (up, 0.3), (down, 0.4), (up, 0.5), (down, 0.6)])
            == [false, false, true, false, false, false, true])
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
    }

    @Test func byteSyllableMatchAgreesWithCharacterVersion() {
        let names = ["年度报告.docx", "剪贴板", "绿色", "Win顺 设置", "（草稿）合同"]
        let queries = ["bg", "baogao", "ndbg", "jiantb", "jtb", "lv", "lu", "ls", "wins", "sz", "cght", "xyz", "nd"]
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

