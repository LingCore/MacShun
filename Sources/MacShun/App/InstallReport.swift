// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import IOKit

/// 匿名的“装机报告”：每台电脑每天最多向拾穗发布服务报告一次，用来统计用户数。
/// 只发随机化的电脑标识（机器标识加项目名做 SHA-256，原始标识不离开本机）、版本号、系统版本和芯片架构，
/// 不含文件、剪贴板或任何个人信息。设置里可以关掉；关掉后完全不发请求。失败了不提示，也不重试，等第二天。
/// 协议见 gleaning-web/clients/README.md 的“下载统计与用户数”。
enum InstallReport {
    static let project = "macshun"
    static let enabledKey = "stats.enabled"
    static let lastDayKey = "stats.lastReportDay"

    /// 默认开启
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    // MARK: - 纯函数

    /// 64 位小写十六进制。不同项目的同一台电脑得到不同的值，服务器没法跨产品关联
    static func installID(machine: String) -> String {
        let digest = SHA256.hash(data: Data("gleaning.install.v1:\(project):\(machine)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 和更新用同一个服务器（协议、主机、端口），换上新的路径，丢掉原有的查询和片段。不合规的地址（非 HTTPS 的远程地址等）返回 nil
    static func serverURL(feed: URL?, path: String, query: [URLQueryItem]? = nil) -> URL? {
        guard let feed, UpdateFeed.isWebURL(feed),
              var components = URLComponents(url: feed, resolvingAgainstBaseURL: false) else { return nil }
        components.path = path
        components.queryItems = query
        components.fragment = nil
        return components.url
    }

    /// 统计接口。不合规的地址不报告
    static func endpoint(feed: URL?) -> URL? {
        serverURL(feed: feed, path: "/api/v1/projects/\(project)/installs")
    }

    /// 官网的反馈页，参数用来预填“软件版本 / 系统”，都可以省略。更新地址不合规时退回官网项目页所在的服务器
    static func feedbackURL(
        feed: URL?, fallback: URL? = UpdateFeed.projectURL, version: String? = currentVersion(),
        system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> URL? {
        var query: [URLQueryItem] = []
        if let version { query.append(URLQueryItem(name: "version", value: version)) }
        query += [URLQueryItem(name: "platform", value: "macos"), URLQueryItem(name: "arch", value: UpdateFeed.runtimeArch),
                  URLQueryItem(name: "osVersion", value: UpdateFeed.systemVersionString(system))]
        let path = "/projects/\(project)/feedback"
        return serverURL(feed: feed, path: path, query: query) ?? serverURL(feed: fallback, path: path, query: query)
    }

    /// 服务器按严格语义化版本检查：1.2.0、1.3.0-beta.1
    static func isValidVersion(_ version: String) -> Bool {
        version.range(of: #"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$"#,
                      options: .regularExpression) != nil && version.count <= 80
    }

    /// 打包后的版本号。直接 swift build 跑起来没有 Info.plist，返回 nil（开发版不报告）
    static func currentVersion() -> String? {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              isValidVersion(version) else { return nil }
        return version
    }

    struct Payload: Encodable, Equatable {
        let installId: String
        let version: String
        let platform: String
        let arch: String
        let osVersion: String
    }

    static func payload(machine: String, version: String, system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> Payload {
        Payload(installId: installID(machine: machine), version: version, platform: "macos", arch: UpdateFeed.runtimeArch,
                osVersion: UpdateFeed.systemVersionString(system))
    }

    static func encode(_ payload: Payload) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(payload)
    }

    /// 本地日历的“年-月-日”
    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// 今天还没报告过就报告一次。先记下日期再发，失败了也要等到明天。
    /// 关闭、没有可用的地址或载荷时什么都不做，也不记日期。返回是否发出了请求
    @discardableResult
    static func reportIfDue(
        defaults: UserDefaults = .standard, now: Date = Date(), calendar: Calendar = .current,
        endpoint: URL?, payload: () -> Payload?, send: (URL, Data) async -> Void
    ) async -> Bool {
        guard isEnabled(defaults), let endpoint else { return false }
        let today = dayString(now, calendar: calendar)
        guard defaults.string(forKey: lastDayKey) != today else { return false }
        guard let body = payload().flatMap(encode) else { return false }
        defaults.set(today, forKey: lastDayKey)
        await send(endpoint, body)
        return true
    }

    // MARK: - 本机和网络

    /// IOKit 的 IOPlatformUUID。读不到就不报告
    static func machineID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? String
    }

    /// 不带 cookie、不缓存、不跟随跳转；任何错误和状态码都忽略
    static func post(_ endpoint: URL, body: Data) async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MacShun/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
        _ = try? await session.data(for: request)
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    // MARK: - 定时

    @MainActor private static var started = false

    /// 启动后过一会儿报告一次，之后每小时看一眼（每天最多发一次，所以很省）。
    /// 只在打包后的正常运行里启动：自测、授权引导测试、swift run 和单元测试里都不会发
    @MainActor
    static func start() {
        guard !started, Updater.isSupported, currentVersion() != nil else { return }
        started = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            while !Task.isCancelled {
                await reportIfDue(
                    endpoint: endpoint(feed: Updater.feedURL),
                    payload: {
                        guard let version = currentVersion(), let machine = machineID() else { return nil }
                        return payload(machine: machine, version: version)
                    },
                    send: { await post($0, body: $1) }
                )
                try? await Task.sleep(nanoseconds: 3600 * 1_000_000_000)
            }
        }
    }
}
