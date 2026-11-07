// SPDX-License-Identifier: MIT

import AppKit
import CryptoKit
import Security

/// 通过拾穗发布服务检查和下载更新；网络失败时留在软件内提示重试。
/// 用户点“立即更新”后下载 dmg（先试加速镜像，最后试 GitHub 原始地址，换地址见 fetchPackage），
/// 核对文件摘要和代码签名（必须和正在运行的这个是同一张证书签的），替换掉自己再重新打开。
/// 检查时只发一个不带任何个人信息的请求；设置里可以关掉自动检查。只在主线程上用。
final class Updater: ObservableObject, @unchecked Sendable {
    static let shared = Updater()

    /// 发布新版本的仓库
    static let repository = "LingCore/MacShun"

    enum Activity: Equatable {
        case none, checking, downloading(Double), installing
    }

    /// 比正在用的新的版本
    @Published private(set) var available: ReleaseInfo?
    @Published private(set) var activity = Activity.none
    /// 最近一次手动检查或安装失败的原因，给用户看
    @Published private(set) var problem: String?
    @Published private(set) var lastChecked: Date? {
        didSet { defaults.set(lastChecked, forKey: Keys.lastChecked) }
    }

    /// 自动检查发现了该提醒的新版本，或者手动检查发现了新版本
    var onFound: ((_ release: ReleaseInfo, _ manual: Bool) -> Void)?

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var checkedThisRun = false
    /// 下载和安装的整个过程；取消它就停掉当前下载，也不再试下一个地址
    private var installTask: Task<Void, Never>?
    /// 每次安装一个新值，旧的一次留下的进度回调不再生效
    private var installToken = UUID()

    private enum Keys {
        static let lastChecked = "update.lastChecked"
        static let skipped = "update.skippedVersion"
        static let promptedVersion = "update.promptedVersion"
        static let promptedAt = "update.promptedAt"
    }

    /// 自动检查的间隔
    private static let interval: TimeInterval = 12 * 3600
    /// 点了“以后再说”（或者直接关掉窗口）之后，同一个版本隔多久再提醒
    private static let remindInterval: TimeInterval = 3 * 24 * 3600

    private init() {
        lastChecked = defaults.object(forKey: Keys.lastChecked) as? Date
    }

    /// 打包成 .app 运行时才检查（swift run、单元测试里不检查），自测时也不检查
    static var isSupported: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && !SelfTest.isRequested && !GuideTest.isRequested
    }

    /// 构建参数和本地测试可指定服务地址；正式版本默认连接自己的服务器。
    static var feedURL: URL? {
        let override = ProcessInfo.processInfo.environment["MACSHUN_UPDATE_FEED"]
        let configured = override ?? Bundle.main.object(forInfoDictionaryKey: "MacShunUpdateFeed") as? String
        return UpdateFeed.url(configured ?? UpdateFeed.defaultURL.absoluteString)
    }

    /// 测试用：发现新版本后不问用户，直接装（scripts/update-test.sh）
    private static let installWithoutAsking = ProcessInfo.processInfo.environment["MACSHUN_UPDATE_AUTOINSTALL"] == "1"

    // MARK: - 自动检查

    /// 打开或关掉自动检查。启动时和设置改了时调用，重复调用没关系
    func setAutomatic(_ on: Bool) {
        guard Self.isSupported else { return }
        guard on else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        // 每小时看一眼，离上次检查满 12 小时就再查（睡眠醒来后也能补上）
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        // 刚开机时网络可能还没好，等一会儿再查
        DispatchQueue.main.asyncAfter(deadline: .now() + (Self.installWithoutAsking ? 1 : 20)) { [weak self] in
            self?.checkIfDue()
        }
    }

    private func checkIfDue() {
        guard timer != nil else { return }
        // 每次启动都查一次，之后每 12 小时一次
        let due = !checkedThisRun || Date().timeIntervalSince(lastChecked ?? .distantPast) >= Self.interval
        if due { check(manual: false) }
    }

    // MARK: - 检查

    /// 查询最新兼容版本。manual：用户自己点的，失败了要告诉他
    func check(manual: Bool) {
        guard Self.isSupported, activity == .none else { return }
        activity = .checking
        if manual { problem = nil }

        guard let feed = Self.feedURL else { finishCheck(.failure(UpdateError.invalidResponse), manual: manual); return }
        fetchRelease(feed, manual: manual)
    }

    private func fetchRelease(_ feed: URL, manual: Bool) {
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MacShun/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let result = Result { () throws -> ReleaseInfo in
                if let error { throw error }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                // 服务明确回答“暂无兼容版本”时保留当前版本。
                if status == 204 { return ReleaseInfo(version: AppVersion.current, pageURL: feed, notes: "", package: nil) }
                guard status == 200, let data else { throw UpdateError.server(status) }
                return try ReleaseInfo.parse(data, requiresDigest: true)
            }
            DispatchQueue.main.async {
                self?.finishCheck(result, manual: manual)
            }
        }.resume()
    }

    private func finishCheck(_ result: Result<ReleaseInfo, Error>, manual: Bool) {
        activity = .none
        switch result {
        case .success(let release):
            lastChecked = Date()
            checkedThisRun = true
            let newer = AppVersion.isNewer(release.version, than: AppVersion.current)
            Log.app.notice("检查更新：最新 \(release.version, privacy: .public)，正在用 \(AppVersion.current, privacy: .public)")
            guard newer else {
                available = nil
                return
            }
            available = release
            if Self.installWithoutAsking {
                install()
            } else if manual || shouldRemind(release) {
                defaults.set(release.version, forKey: Keys.promptedVersion)
                defaults.set(Date(), forKey: Keys.promptedAt)
                onFound?(release, manual)
            }
        case .failure(let error):
            Log.app.error("检查更新失败：\(error.localizedDescription, privacy: .public)")
            if manual { problem = error.localizedDescription }
        }
    }

    /// 自动检查发现的新版本要不要弹窗：跳过的版本不提醒，提醒过的隔几天再提醒
    private func shouldRemind(_ release: ReleaseInfo) -> Bool {
        if defaults.string(forKey: Keys.skipped) == release.version { return false }
        if defaults.string(forKey: Keys.promptedVersion) == release.version,
           let at = defaults.object(forKey: Keys.promptedAt) as? Date,
           Date().timeIntervalSince(at) < Self.remindInterval {
            return false
        }
        return true
    }

    /// 这个版本不再自动提醒（手动检查、设置里还能看到）
    func skip(_ release: ReleaseInfo) {
        defaults.set(release.version, forKey: Keys.skipped)
    }

    func isSkipped(_ release: ReleaseInfo) -> Bool {
        defaults.string(forKey: Keys.skipped) == release.version
    }

    #if DEBUG
    /// 截图用：直接摆出某个状态，不联网
    func showPreview(available: ReleaseInfo?, activity: Activity = .none, problem: String? = nil, lastChecked: Date? = nil) {
        self.available = available
        self.activity = activity
        self.problem = problem
        self.lastChecked = lastChecked
    }
    #endif

    // MARK: - 下载和安装

    /// 下载新版本、核对、换掉自己，然后重新打开
    func install() {
        guard let release = available, activity == .none else { return }
        guard let package = release.package else {
            NSWorkspace.shared.open(UpdateFeed.projectURL)
            return
        }
        problem = nil
        activity = .downloading(0)
        let target = Bundle.main.bundleURL
        let token = UUID()
        installToken = token
        // 每次尝试下载的文件都放在这个文件夹里；成功、失败、取消，最后整个删掉
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacShun-update-\(UUID().uuidString)", isDirectory: true)
        installTask = Task { [weak self] in
            // Failed verification must never leave a package for a manual-install shortcut.
            defer { try? FileManager.default.removeItem(at: work) }
            do {
                let report: @Sendable (Double) -> Void = { fraction in
                    DispatchQueue.main.async {
                        guard let self, self.installToken == token, case .downloading = self.activity else { return }
                        self.activity = .downloading(fraction)
                    }
                }
                let dmg = try await Self.fetchPackage(package) { url in
                    // 换一个地址，进度从头算
                    report(0)
                    return try await Self.downloadFile(from: url, into: work, progress: report)
                }
                let me = self
                let proceed = await MainActor.run { () -> Bool in
                    guard !Task.isCancelled, let me, me.installToken == token else { return false }
                    me.activity = .installing
                    return true
                }
                guard proceed else { throw CancellationError() }
                try await Task.detached(priority: .userInitiated) {
                    try Self.installPackage(dmg, into: target, expectedVersion: release.version)
                }.value
                Log.app.notice("已更新到 \(release.version, privacy: .public)，重新打开")
                DispatchQueue.main.async { AppState.relaunch() }
            } catch {
                self?.fail(error)
            }
        }
    }

    /// 取消下载
    func cancel() {
        guard case .downloading = activity else { return }
        installTask?.cancel()
        installTask = nil
        activity = .none
    }

    /// 按顺序试每个地址（镜像在前，原始地址在后）：下载、状态码、大小和 SHA-256 都对才算数，返回下载好的文件。
    /// 某个地址出错就删掉它的文件，换下一个；全部失败抛最后一个错误。取消时立刻停下并清理。
    /// fetch 是真正下载的函数（测试时换成假的）：返回下载到的文件和 HTTP 状态码。
    static func fetchPackage(
        _ package: ReleaseInfo.Package,
        using fetch: (URL) async throws -> (file: URL, status: Int)
    ) async throws -> URL {
        let candidates = package.candidates
        guard !candidates.isEmpty else { throw UpdateError.invalidResponse }
        var lastError: Error = UpdateError.invalidResponse
        for (index, url) in candidates.enumerated() {
            try Task.checkCancellation()
            var file: URL?
            do {
                let result = try await fetch(url)
                file = result.file
                guard (200..<300).contains(result.status) else { throw UpdateError.server(result.status) }
                try verifyDigest(of: result.file, expected: package.sha256, expectedSize: package.size)
                try Task.checkCancellation()
                return result.file
            } catch {
                if let file { try? FileManager.default.removeItem(at: file) }
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                lastError = error
                Log.app.error("第 \(index + 1)/\(candidates.count) 个下载地址（\(url.host ?? "", privacy: .public)）失败：\(error.localizedDescription, privacy: .public)")
            }
        }
        throw lastError
    }

    /// 下载一个地址到 directory 里的新文件，返回文件和 HTTP 状态码（不判断对错）。Task 被取消时中止下载
    static func downloadFile(
        from url: URL, into directory: URL, progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> (file: URL, status: Int) {
        let handle = DownloadHandle()
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.downloadTask(with: request) { file, response, error in
                    handle.finish()
                    do {
                        if let error { throw error }
                        guard let file else { throw UpdateError.invalidResponse }
                        // 下载的临时文件在这个回调返回后就会被删掉，先挪到自己的文件夹里
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let dmg = directory.appendingPathComponent("\(UUID().uuidString).dmg")
                        try FileManager.default.moveItem(at: file, to: dmg)
                        continuation.resume(returning: (dmg, (response as? HTTPURLResponse)?.statusCode ?? 0))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                if let progress {
                    handle.observation = task.progress.observe(\.fractionCompleted) { value, _ in progress(value.fractionCompleted) }
                }
                handle.start(task)
            }
        } onCancel: {
            handle.cancel()
        }
    }

    /// 让取消回调能拿到正在下载的任务；取消可能比任务创建还早
    private final class DownloadHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDownloadTask?
        private var cancelled = false
        var observation: NSKeyValueObservation?

        func start(_ task: URLSessionDownloadTask) {
            lock.lock()
            self.task = task
            let stop = cancelled
            lock.unlock()
            if stop { task.cancel() } else { task.resume() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }

        func finish() {
            observation = nil
        }
    }

    private func fail(_ error: Error) {
        // 用户点了取消
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        Log.app.error("更新失败：\(error.localizedDescription, privacy: .public)")
        DispatchQueue.main.async {
            self.activity = .none
            self.installTask = nil
            self.problem = error.localizedDescription
        }
    }

    /// 自己装不上时：打开官网；失败包不会交给用户执行。
    func installManually() {
        NSWorkspace.shared.open(UpdateFeed.projectURL)
    }

    /// 核对发布服务提供的 SHA-256 和大小；安装前还要独立核对代码签名。
    static func verifyDigest(of file: URL, expected: String?, expectedSize: Int? = nil) throws {
        if let expectedSize {
            let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
            guard size?.intValue == expectedSize else { throw UpdateError.corrupted }
        }
        guard let expected else { return }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expected.lowercased() else { throw UpdateError.corrupted }
    }

    /// 打开 dmg，把里面的程序复制到 target 旁边，核对签名后原地换掉 target。在后台线程上运行
    static func installPackage(_ dmg: URL, into target: URL, expectedVersion: String? = nil) throws {
        let fm = FileManager.default
        let parent = target.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else { throw UpdateError.notWritable(parent.path) }

        let mount = dmg.deletingLastPathComponent().appendingPathComponent("mount", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        guard let app = try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" })
        else { throw UpdateError.noApp }

        // 先复制到和 target 同一个磁盘上的临时文件夹，核对复制出来的这份，再一步换过去
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? fm.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(target.lastPathComponent, isDirectory: true)
        try run("/usr/bin/ditto", [app.path, staged.path])

        try checkSignature(of: staged)
        let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))
        guard let id = info?["CFBundleIdentifier"] as? String, id == Bundle.main.bundleIdentifier,
              let version = info?["CFBundleShortVersionString"] as? String,
              AppVersion.isNewer(version, than: AppVersion.current),
              expectedVersion.map({ AppVersion.normalized($0) == AppVersion.normalized(version) }) ?? true
        else { throw UpdateError.wrongApp }

        _ = try fm.replaceItemAt(target, withItemAt: staged)
    }

    /// 新程序必须满足正在运行的这个的“指定要求”（同一个应用标识、同一张证书）才装：既不会装上别人做的假安装包，
    /// 也保证装好后系统里的授权（辅助功能、输入监控）还认它。以后换了证书，旧版就装不了新版，只能手动装（那时也要重新授权）
    static func checkSignature(of app: URL) throws {
        var me: SecCode?
        var myStatic: SecStaticCode?
        var requirement: SecRequirement?
        var code: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &myStatic) == errSecSuccess, let myStatic,
              SecCodeCopyDesignatedRequirement(myStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code
        else { throw UpdateError.signature }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            Log.app.error("新版本的签名不对：\(status)")
            throw UpdateError.signature
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let name = (tool as NSString).lastPathComponent
            Log.app.error("\(name, privacy: .public) 失败：\(output, privacy: .public)")
            throw UpdateError.tool(name)
        }
    }
}

enum UpdateError: LocalizedError {
    case server(Int), invalidResponse, corrupted, noApp, signature, wrongApp, notWritable(String), tool(String)

    var errorDescription: String? {
        switch self {
        case .server(403), .server(429): L("更新服务繁忙，请稍后重试。")
        case .server(let status): L("更新服务返回了错误（%ld）。", status)
        case .invalidResponse: L("更新信息无效，请稍后重试。")
        case .corrupted: L("下载的文件不完整，请重试。")
        case .noApp: L("安装包里没有找到 Mac顺。")
        case .signature: L("新版本的签名校验失败，已拒绝安装。请稍后重试或联系开发者。")
        case .wrongApp: L("安装包里的程序不对，没有安装。")
        case .notWritable(let path): L("没有权限替换“%@”里的程序，请手动安装。", path)
        case .tool(let name): L("安装时出错（%@）。", name)
        }
    }
}

/// 发布服务返回的一个版本；字段沿用兼容的 Releases 格式。
struct ReleaseInfo: Equatable {
    /// 版本号，不带前面的 v
    let version: String
    /// 发布页
    let pageURL: URL
    /// 发布说明（Markdown），格式见 ReleaseNotes
    let notes: String
    /// 安装包。没有时只能去发布页下载
    let package: Package?

    struct Package: Equatable {
        let url: URL
        let size: Int
        /// 发布服务计算的 SHA-256（十六进制）；兼容解析旧数据时允许为空。
        let sha256: String?
        /// 下载镜像，按优先顺序；可能为空。镜像不可信，安全性靠下面的摘要和代码签名
        var mirrors: [URL] = []

        /// 依次尝试的下载地址：先是 https 镜像，最后是原始地址（也要合规）；去掉重复
        var candidates: [URL] {
            var seen = Set<URL>()
            let mirrors = mirrors.filter { $0.scheme == "https" && UpdateFeed.isWebURL($0) }
            return (mirrors + (UpdateFeed.isWebURL(url) ? [url] : [])).filter { seen.insert($0).inserted }
        }
    }

    /// 解析发布服务的 Releases 兼容字段。
    static func parse(_ data: Data, requiresDigest: Bool = false) throws -> ReleaseInfo {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
            let size: Int
            let digest: String?
            let mirrors: [String]?
        }
        struct Release: Decodable {
            let tagName: String
            let htmlUrl: URL
            let body: String?
            let assets: [Asset]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let release = try decoder.decode(Release.self, from: data)
        guard UpdateFeed.isWebURL(release.htmlUrl) else { throw UpdateError.invalidResponse }
        // 改名前的安装包叫 WinShun-<版本>.dmg
        let dmg = release.assets.first { $0.name.hasPrefix("MacShun-") && $0.name.hasSuffix(".dmg") }
            ?? release.assets.first { $0.name.hasSuffix(".dmg") }
        if let dmg {
            guard UpdateFeed.isWebURL(dmg.browserDownloadUrl), dmg.size > 0 else { throw UpdateError.invalidResponse }
            if requiresDigest {
                guard let digest = dmg.digest, digest.range(of: "^sha256:[a-fA-F0-9]{64}$", options: .regularExpression) != nil
                else { throw UpdateError.invalidResponse }
            }
        }
        return ReleaseInfo(
            version: AppVersion.normalized(release.tagName),
            pageURL: release.htmlUrl,
            notes: release.body ?? "",
            package: dmg.map {
                let sha = $0.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil }
                return Package(url: $0.browserDownloadUrl, size: $0.size, sha256: sha,
                               mirrors: ($0.mirrors ?? []).compactMap { URL(string: $0) })
            }
        )
    }
}

/// 版本号：0.3.0、v0.3.1 这样用点分开的数字。
enum AppVersion {
    static var current: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// 给人看的版本号；直接用 swift build 跑起来没有 Info.plist，说“开发版”
    static var display: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? L("开发版")
    }

    /// 去掉标签前面的 v
    static func normalized(_ tag: String) -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespaces)
        return trimmed.first == "v" || trimmed.first == "V" ? String(trimmed.dropFirst()) : trimmed
    }

    /// 每一段的数字。“-beta”这样的后缀不看
    static func numbers(_ version: String) -> [Int] {
        let core = normalized(version).split(separator: "+", maxSplits: 1).first?.split(separator: "-", maxSplits: 1).first ?? ""
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }

    static func isNewer(_ candidate: String, than base: String) -> Bool {
        let a = numbers(candidate), b = numbers(base)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        func prerelease(_ value: String) -> [String]? {
            let core = normalized(value).split(separator: "+", maxSplits: 1).first ?? ""
            let parts = core.split(separator: "-", maxSplits: 1)
            return parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : nil
        }
        let preA = prerelease(candidate), preB = prerelease(base)
        if preA == nil && preB != nil { return true }
        guard let preA, let preB else { return false }
        for i in 0..<min(preA.count, preB.count) where preA[i] != preB[i] {
            let x = Int(preA[i]), y = Int(preB[i])
            if let x, let y { return x > y }
            if x != nil || y != nil { return x == nil }
            return preA[i] > preB[i]
        }
        return preA.count > preB.count
    }
}

/// 发布协议只允许 HTTPS；本机 HTTP 用于隔离的开发与更新测试。
enum UpdateFeed {
    static let defaultURL = URL(string: "https://lcstp.com/updates/macshun/stable.json")!
    static let projectURL = URL(string: "https://lcstp.com/projects/macshun#downloads")!
    static func isWebURL(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, let host = url.host else { return false }
        return url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost", "[::1]", "::1"].contains(host))
    }

    /// 运行的芯片架构，和发布服务的取值一致
    static var runtimeArch: String {
        #if arch(arm64)
        "arm64"
        #else
        "x64"
        #endif
    }

    static func systemVersionString(_ system: OperatingSystemVersion) -> String {
        "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
    }

    static func url(_ value: String) -> URL? {
        guard let url = URL(string: value), isWebURL(url) else { return nil }
        guard url.path.hasPrefix("/updates/") else { return url }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = (components.queryItems ?? []).filter { !["platform", "arch", "osVersion"].contains($0.name) }
        items += [URLQueryItem(name: "platform", value: "macos"), URLQueryItem(name: "arch", value: runtimeArch),
                  URLQueryItem(name: "osVersion", value: systemVersionString(ProcessInfo.processInfo.operatingSystemVersion))]
        components.queryItems = items
        return components.url
    }
}

/// 从发布说明里取更新窗口要显示的部分。发布说明（docs/release-notes）的格式：开头一段话，中文在前、英文在后；
/// “## 新功能 · What's new”下面每一条是“- 图标 中文”一行，接着缩进的一行英文。
enum ReleaseNotes {
    struct Highlight: Equatable {
        /// 开头的 emoji，没有时为空
        let symbol: String
        let text: String
    }

    /// 开头那段话里界面语言的那一半。分不开时整段都给
    static func summary(_ notes: String, chinese: Bool) -> String {
        let lines = notes.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { !$0.trimmed.isEmpty }), !lines[start].hasPrefix("#") else { return "" }
        let paragraph = lines[start...].prefix { !$0.trimmed.isEmpty }.map(\.trimmed).joined(separator: " ")
        guard let (zh, en) = splitLanguages(paragraph) else { return paragraph }
        return chinese ? zh : en
    }

    /// “新功能”里的每一条，界面语言的那一行
    static func highlights(_ notes: String, chinese: Bool) -> [Highlight] {
        let lines = notes.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: {
            $0.hasPrefix("## ") && $0.range(of: "what's new", options: .caseInsensitive) != nil
        }) else { return [] }
        var items: [(zh: String, en: [String])] = []
        for line in lines[(start + 1)...] {
            if line.hasPrefix("#") { break }
            if line.hasPrefix("- ") {
                items.append((String(line.dropFirst(2)).trimmed, []))
            } else if !items.isEmpty, line.first == " " || line.first == "\t", !line.trimmed.isEmpty {
                items[items.count - 1].en.append(line.trimmed)
            }
        }
        return items.map { item in
            var symbol = ""
            var zh = item.zh
            // 开头的 emoji 单独拿出来当圆点，英文那行没有，也用它
            if let space = zh.firstIndex(of: " "), isEmoji(zh[..<space]) {
                symbol = String(zh[..<space])
                zh = String(zh[zh.index(after: space)...])
            }
            let text = chinese || item.en.isEmpty ? zh : item.en.joined(separator: " ")
            return Highlight(symbol: symbol, text: text)
        }
    }

    /// “中文……。English…”：在某个中文句号后面，剩下的再也没有汉字，从那里分开
    static func splitLanguages(_ text: String) -> (String, String)? {
        var from = text.startIndex
        while let stop = text[from...].firstIndex(where: { "。！？".contains($0) }) {
            let next = text.index(after: stop)
            let rest = text[next...].trimmed
            if !rest.isEmpty && !rest.unicodeScalars.contains(where: isHan) {
                return (String(text[..<next]).trimmed, rest)
            }
            from = next
        }
        return nil
    }

    /// “🔍”“🖥️”这样的 emoji（可能带变体选择符、零宽连接符）。#、*、数字也算 emoji，不要它们
    private static func isEmoji(_ text: Substring) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            scalar.value == 0x200D || scalar.properties.isVariationSelector
                || (scalar.value > 0x7F && scalar.properties.isEmoji)
        }
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x9FFF).contains(scalar.value)
    }
}

private extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}
