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
