// SPDX-License-Identifier: MIT
#if DEBUG
import Foundation

/// 原生更新集成测试专用：仅替换临时目录中的自身副本，不启动事件拦截、窗口或设置。
enum UpdateProbe {
    private final class ProbeResult: @unchecked Sendable { var result: Result<URL, Error>? }

    static func run(source: String) throws {
        let target = Bundle.main.bundleURL.resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        guard target.path.hasPrefix(temporary.path + "/"), target.pathExtension == "app",
              let feed = UpdateFeed.url(source), ["localhost", "127.0.0.1", "::1", "[::1]"].contains(feed.host ?? "")
        else { throw UpdateError.invalidResponse }
        let release = try ReleaseInfo.parse(Data(contentsOf: feed), requiresDigest: true)
        guard AppVersion.isNewer(release.version, than: AppVersion.current) else {
            print("UPDATE_PROBE_UP_TO_DATE: \(AppVersion.current)")
            return
        }
        guard let package = release.package else { throw UpdateError.noApp }
        let work = target.deletingLastPathComponent().appendingPathComponent("probe-download", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        // 和软件里一样：按候选地址顺序下载，大小和摘要对了才继续。探针是同步的，等异步下载做完
        let box = ProbeResult()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                box.result = .success(try await Updater.fetchPackage(package) { url in
                    try await Updater.downloadFile(from: url, into: work)
                })
            } catch {
                box.result = .failure(error)
            }
            done.signal()
        }
        done.wait()
        let file = try box.result!.get()
        try Updater.installPackage(file, into: target, expectedVersion: release.version)
        print("UPDATE_PROBE_INSTALLED: \(release.version)")
    }
}
#endif
