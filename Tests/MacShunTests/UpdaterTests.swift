// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing
@testable import MacShun

@Suite("检查更新")
struct UpdaterTests {
    /// 仓库里的发布说明，和发到 GitHub 上的一样
    private func notes(_ version: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("docs/release-notes/v\(version).md"), encoding: .utf8)
    }

    @Test func versionOrder() {
        #expect(AppVersion.isNewer("0.3.1", than: "0.3.0"))
        #expect(AppVersion.isNewer("v0.10.0", than: "0.9.9"))
        #expect(AppVersion.isNewer("1.0", than: "0.99.99"))
        #expect(AppVersion.isNewer("0.3.0.1", than: "0.3"))
        #expect(!AppVersion.isNewer("0.3.0", than: "0.3.0"))
        #expect(!AppVersion.isNewer("v0.3", than: "0.3.0"))
        #expect(!AppVersion.isNewer("0.2.1", than: "0.3.0"))
        #expect(!AppVersion.isNewer("0.3.0-beta", than: "0.3.0"))
        #expect(AppVersion.normalized(" v0.3.0 ") == "0.3.0")
    }

    @Test func parsesGitHubRelease() throws {
        let json = """
        {"tag_name": "v0.3.1", "html_url": "https://github.com/LingCore/MacShun/releases/tag/v0.3.1",
         "body": "说明", "draft": false, "prerelease": false,
         "assets": [
          {"name": "MacShun-0.3.1.dmg.sha256", "size": 84,
           "browser_download_url": "https://github.com/LingCore/MacShun/releases/download/v0.3.1/MacShun-0.3.1.dmg.sha256"},
          {"name": "MacShun-0.3.1.dmg", "size": 4063973, "digest": "sha256:ABCDEF",
           "browser_download_url": "https://github.com/LingCore/MacShun/releases/download/v0.3.1/MacShun-0.3.1.dmg"}
         ]}
        """
        let release = try ReleaseInfo.parse(Data(json.utf8))
        #expect(release.version == "0.3.1")
        #expect(release.notes == "说明")
        #expect(release.package?.url.lastPathComponent == "MacShun-0.3.1.dmg")
        #expect(release.package?.size == 4_063_973)
        #expect(release.package?.sha256 == "ABCDEF")
    }

    @Test func releaseWithoutPackage() throws {
        let json = #"{"tag_name": "v0.2.1", "html_url": "https://github.com/x/y", "body": null, "assets": []}"#
        let release = try ReleaseInfo.parse(Data(json.utf8))
        #expect(release.package == nil)
        #expect(release.notes.isEmpty)
        // 改名前的安装包名字也认
        let old = #"{"tag_name": "v0.2.1", "html_url": "https://github.com/x/y", "assets": [{"name": "WinShun-0.2.1.dmg", "size": 1, "browser_download_url": "https://github.com/x/y/WinShun-0.2.1.dmg"}]}"#
        #expect(try ReleaseInfo.parse(Data(old.utf8)).package?.sha256 == nil)
        #expect(try ReleaseInfo.parse(Data(old.utf8)).package?.url.lastPathComponent == "WinShun-0.2.1.dmg")
    }

    @Test func summarySplitsLanguages() throws {
        let text = try notes("0.2.1")
        #expect(ReleaseNotes.summary(text, chinese: true) == "文件搜索结果有了右键菜单，剪贴板历史可以一键清空。")
        #expect(ReleaseNotes.summary(text, chinese: false) == "New: a right-click menu in file search, and Clear All in clipboard history.")
        // 中文里夹着英文单词、引号也分得开
        let renamed = try notes("0.3.0")
        #expect(ReleaseNotes.summary(renamed, chinese: true).hasPrefix("Win顺 改名为 **Mac顺**"))
        #expect(ReleaseNotes.summary(renamed, chinese: true).hasSuffix("删除按钮。"))
        #expect(ReleaseNotes.summary(renamed, chinese: false).hasPrefix("WinShun is now **MacShun**"))
        // 只有一种语言时整段都给
        #expect(ReleaseNotes.summary("只有中文。\n\n## 下载", chinese: false) == "只有中文。")
        #expect(ReleaseNotes.summary("## 标题\n正文", chinese: true) == "")
    }

    @Test func highlightsPerLanguage() throws {
        let text = try notes("0.2.0")
        let zh = ReleaseNotes.highlights(text, chinese: true)
        let en = ReleaseNotes.highlights(text, chinese: false)
        #expect(zh.count == 5)
        #expect(en.count == 5)
        #expect(zh[0].symbol == "🔍")
        #expect(zh[0].text.hasPrefix("**文件搜索（像 Everything）**"))
        #expect(en[0].symbol == "🔍")
        #expect(en[0].text.hasPrefix("**File search (like Everything)**"))
        // 带变体选择符的 emoji
        #expect(zh[2].symbol == "🖥️")
        #expect(en[4].text.hasPrefix("**Cursor size**"))
        #expect(ReleaseNotes.highlights("没有新功能这一节", chinese: true).isEmpty)
        // 没有 emoji、没有英文那行
        let plain = ReleaseNotes.highlights("## What's new\n- **一条**：说明\n\n## 下载", chinese: false)
        #expect(plain == [ReleaseNotes.Highlight(symbol: "", text: "**一条**：说明")])
    }

    @Test func digest() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("MacShunTests-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let sha = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        #expect(throws: Never.self) { try Updater.verifyDigest(of: file, expected: sha.uppercased()) }
        #expect(throws: Never.self) { try Updater.verifyDigest(of: file, expected: nil) }
        #expect(throws: UpdateError.self) { try Updater.verifyDigest(of: file, expected: String(repeating: "0", count: 64)) }
    }

    @Test func oldConfigTurnsOnAutomaticChecks() throws {
        let old = #"{"keyboard": {}, "mouse": {}}"#
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(old.utf8))
        #expect(config.update.automatic)
    }
}
