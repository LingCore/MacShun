// SPDX-License-Identifier: MIT

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
        #expect(ReleaseNotes.summary(renamed, chinese: true).hasSuffix("不会再变回去。"))
        #expect(ReleaseNotes.summary(renamed, chinese: false).hasPrefix("WinShun is now **MacShun**"))
        #expect(ReleaseNotes.summary(renamed, chinese: false).hasSuffix("no longer resets."))
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

    @Test func prereleaseOrderingAndBuildMetadata() {
        #expect(AppVersion.isNewer("1.2.0", than: "1.2.0-beta.2"))
        #expect(AppVersion.isNewer("1.2.0-beta.10", than: "1.2.0-beta.2"))
        #expect(AppVersion.isNewer("1.2.0-rc.1", than: "1.2.0-beta.10"))
        #expect(!AppVersion.isNewer("1.2.0-beta.1", than: "1.2.0"))
        #expect(!AppVersion.isNewer("1.2.0+build.2", than: "1.2.0+build.1"))
    }

    @Test func localFeedAddsCompatibilityAndRejectsUnsafeSchemes() {
        #expect(UpdateFeed.defaultURL.host == "lcstp.com")
        #expect(UpdateFeed.projectURL.host == "lcstp.com")
        let url = UpdateFeed.url("http://127.0.0.1:8787/updates/macshun/stable.json")!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(items.contains(URLQueryItem(name: "platform", value: "macos")))
        #expect(items.contains { $0.name == "arch" })
        #expect(items.contains { $0.name == "osVersion" })
        #expect(UpdateFeed.url("http://example.com/updates/macshun/stable.json") == nil)
        #expect(UpdateFeed.url("file:///tmp/latest.json") == nil)
        #expect(UpdateFeed.url("https://user:secret@example.com/latest.json") == nil)
    }

    @Test func hostedReleaseRequiresDigestAndSafeDownloadURL() throws {
        let sha = String(repeating: "a", count: 64)
        let json = """
        {"tag_name":"v0.4.0","html_url":"http://127.0.0.1:8787/projects/macshun","body":"说明",
         "assets":[{"name":"MacShun-0.4.0.dmg","size":42,"digest":"sha256:\(sha)",
         "browser_download_url":"http://127.0.0.1:8787/downloads/asset/MacShun-0.4.0.dmg"}]}
        """
        let release = try ReleaseInfo.parse(Data(json.utf8), requiresDigest: true)
        #expect(release.package?.sha256 == sha)
        let missing = json.replacingOccurrences(of: ",\"digest\":\"sha256:\(sha)\"", with: "")
        #expect(throws: UpdateError.self) { try ReleaseInfo.parse(Data(missing.utf8), requiresDigest: true) }
        let unsafe = json.replacingOccurrences(of: "http://127.0.0.1:8787/downloads", with: "http://untrusted.invalid/downloads")
        #expect(throws: UpdateError.self) { try ReleaseInfo.parse(Data(unsafe.utf8), requiresDigest: true) }
    }

    @Test func digestAlsoChecksAdvertisedSize() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: UpdateError.self) { try Updater.verifyDigest(of: file, expected: nil, expectedSize: 4) }
        #expect(throws: Never.self) { try Updater.verifyDigest(of: file, expected: nil, expectedSize: 3) }
    }

    // MARK: - 镜像和候选地址

    private let github = URL(string: "https://github.com/LingCore/MacShun/releases/download/v1/MacShun-1.dmg")!
    private let mirrorA = URL(string: "https://mirror-a.example/https://github.com/x.dmg")!
    private let mirrorB = URL(string: "https://mirror-b.example/https://github.com/x.dmg")!
    /// "abc" 的 SHA-256
    private let abcSHA = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    private func package(mirrors: [URL], url: URL? = nil) -> ReleaseInfo.Package {
        ReleaseInfo.Package(url: url ?? github, size: 3, sha256: abcSHA, mirrors: mirrors)
    }

    /// 每个测试一个自己的文件夹，方便确认没有残留
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacShunTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func files(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    /// 假下载：按地址返回内容和状态码，或者抛错；记下试过的地址
    private final class FakeNetwork: @unchecked Sendable {
        enum Reply { case body(String, Int), failure }
        let dir: URL
        let replies: [URL: Reply]
        private(set) var tried: [URL] = []
        init(dir: URL, replies: [URL: Reply]) { self.dir = dir; self.replies = replies }

        func fetch(_ url: URL) async throws -> (file: URL, status: Int) {
            tried.append(url)
            switch replies[url] ?? .failure {
            case .failure: throw URLError(.cannotConnectToHost)
            case .body(let text, let status):
                let file = dir.appendingPathComponent(UUID().uuidString)
                try Data(text.utf8).write(to: file)
                return (file, status)
            }
        }
    }

    @Test func mirrorFailuresFallThroughToCanonical() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let net = FakeNetwork(dir: dir, replies: [
            mirrorA: .failure,                  // 连不上
            mirrorB: .body("xyz", 200),         // 摘要不符
            github: .body("abc", 200),
        ])
        let file = try await Updater.fetchPackage(package(mirrors: [mirrorA, mirrorB])) { try await net.fetch($0) }
        #expect(net.tried == [mirrorA, mirrorB, github])
        #expect(files(in: dir) == [file.lastPathComponent])
        #expect(try String(contentsOf: file, encoding: .utf8) == "abc")
    }

    @Test func firstGoodMirrorStopsTheSearch() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let net = FakeNetwork(dir: dir, replies: [mirrorA: .body("abc", 200), github: .body("abc", 200)])
        _ = try await Updater.fetchPackage(package(mirrors: [mirrorA])) { try await net.fetch($0) }
        #expect(net.tried == [mirrorA])
    }

    @Test func nonSuccessStatusAndWrongSizeMoveOn() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let net = FakeNetwork(dir: dir, replies: [
            mirrorA: .body("abc", 404),         // 状态码不对，内容再对也不要
            mirrorB: .body("abcd", 200),        // 大小不符
            github: .body("abc", 206),
        ])
        let file = try await Updater.fetchPackage(package(mirrors: [mirrorA, mirrorB])) { try await net.fetch($0) }
        #expect(net.tried == [mirrorA, mirrorB, github])
        #expect(files(in: dir) == [file.lastPathComponent])
    }

    @Test func allCandidatesFailLeavesNothingBehind() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let net = FakeNetwork(dir: dir, replies: [
            mirrorA: .failure,
            mirrorB: .body("xyz", 200),
            github: .body("abc", 503),
        ])
        await #expect(throws: UpdateError.self) {
            try await Updater.fetchPackage(self.package(mirrors: [self.mirrorA, self.mirrorB])) { try await net.fetch($0) }
        }
        #expect(net.tried.count == 3)
        #expect(files(in: dir).isEmpty)
        // 抛出来的是最后一个错误
        do {
            _ = try await Updater.fetchPackage(package(mirrors: [mirrorA, mirrorB])) { try await net.fetch($0) }
        } catch let error as UpdateError {
            guard case .server(503) = error else { Issue.record("应该是最后一个地址的 503，实际是 \(error)"); return }
        }
    }

    @Test func nonHTTPSMirrorsAreSkipped() async throws {
        let plain = URL(string: "http://mirror.example/x.dmg")!
        let ftp = URL(string: "ftp://mirror.example/x.dmg")!
        let credentials = URL(string: "https://user:pw@mirror.example/x.dmg")!
        let pack = package(mirrors: [plain, ftp, credentials, mirrorA, mirrorA])
        #expect(pack.candidates == [mirrorA, github])
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let net = FakeNetwork(dir: dir, replies: [mirrorA: .failure, github: .body("abc", 200)])
        _ = try await Updater.fetchPackage(pack) { try await net.fetch($0) }
        #expect(net.tried == [mirrorA, github])
    }

    @Test func withoutMirrorsOnlyCanonical() async throws {
        #expect(package(mirrors: []).candidates == [github])
        // 原始地址排在镜像后面，也不重复
        #expect(package(mirrors: [github, mirrorA]).candidates == [github, mirrorA])
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let net = FakeNetwork(dir: dir, replies: [github: .body("abc", 200)])
        _ = try await Updater.fetchPackage(package(mirrors: [])) { try await net.fetch($0) }
        #expect(net.tried == [github])
    }

    @Test func canonicalMustFollowURLRulesToo() async {
        let bad = URL(string: "http://untrusted.invalid/x.dmg")!
        #expect(package(mirrors: [mirrorA], url: bad).candidates == [mirrorA])
        #expect(package(mirrors: [], url: bad).candidates.isEmpty)
        await #expect(throws: UpdateError.self) {
            try await Updater.fetchPackage(self.package(mirrors: [], url: bad)) { _ in throw URLError(.badURL) }
        }
    }

    @Test func cancellationStopsTheLoopAndCleansUp() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let net = FakeNetwork(dir: dir, replies: [mirrorA: .body("abc", 200), github: .body("abc", 200)])
        let pack = package(mirrors: [mirrorA])
        let task = Task {
            try await Updater.fetchPackage(pack) { url in
                // 第一个地址下载完就被取消：文件要删掉，也不再试 GitHub
                let result = try await net.fetch(url)
                withUnsafeCurrentTask { $0?.cancel() }
                return result
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(net.tried == [mirrorA])
        #expect(files(in: dir).isEmpty)
    }

    @Test func parsesMirrorsWhenPresent() throws {
        let json = """
        {"tag_name":"v0.4.0","html_url":"https://lcstp.com/projects/macshun","body":"",
         "assets":[{"name":"MacShun-0.4.0.dmg","size":42,"digest":"sha256:\(abcSHA)",
         "browser_download_url":"https://github.com/LingCore/MacShun/releases/download/v0.4.0/MacShun-0.4.0.dmg",
         "mirrors":["https://gh-proxy.com/https://github.com/LingCore/MacShun/releases/download/v0.4.0/MacShun-0.4.0.dmg","http://insecure.example/a.dmg"]}]}
        """
        let package = try #require(try ReleaseInfo.parse(Data(json.utf8), requiresDigest: true).package)
        #expect(package.mirrors.count == 2)
        #expect(package.candidates.count == 2)
        #expect(package.candidates.first?.host == "gh-proxy.com")
        #expect(package.candidates.last?.host == "github.com")
        // 没有 mirrors 字段，或者是 null、空数组
        for variant in ["", ",\"mirrors\":null", ",\"mirrors\":[]"] {
            let plain = """
            {"tag_name":"v0.4.0","html_url":"https://lcstp.com/projects/macshun","body":"",
             "assets":[{"name":"MacShun-0.4.0.dmg","size":42,"digest":"sha256:\(abcSHA)",
             "browser_download_url":"https://github.com/LingCore/MacShun/releases/download/v0.4.0/MacShun-0.4.0.dmg"\(variant)}]}
            """
            let parsed = try #require(try ReleaseInfo.parse(Data(plain.utf8), requiresDigest: true).package)
            #expect(parsed.mirrors.isEmpty)
            #expect(parsed.candidates == [parsed.url])
        }
    }
}
