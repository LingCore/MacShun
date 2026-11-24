// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Network

/// 局域网发现的对端信息（来自 Bonjour 或 UDP 广播信标）。
struct DiscoveredSyncPeer: Equatable, Identifiable, Sendable {
    var deviceID: String
    var deviceName: String
    var platform: SyncPlatform
    var groupID: String
    var host: String
    var port: UInt16
    var pairingOpen: Bool
    var lastSeen: Date

    var id: String { deviceID }
    var endpoint: SyncEndpoint { SyncEndpoint(host: host, port: port) }
}

/// 局域网双轨发现：Bonjour（_shunsync._tcp）+ UDP 局域网广播信标（兜底 Windows mDNS 不稳定场景）。
/// 仅在开启跨设备共享时启动；关闭后完全释放 socket 与 browser。
final class SyncDiscovery: @unchecked Sendable {
    private let queue: DispatchQueue
    private let udpPort: UInt16
    private let localDeviceID: String
    private var beaconProvider: () -> DiscoveryBeacon?
    private var onPeerDiscovered: (DiscoveredSyncPeer) -> Void

    private var browser: NWBrowser?
    private var udpFD: Int32 = -1
    private var udpReadSource: DispatchSourceRead?
    private var beaconTimer: DispatchSourceTimer?
    private var highFrequencyBeacon = false
    private var cachedBroadcastTargets: (addresses: [String], refreshedAt: TimeInterval)?
    private var resolvedHosts: [String: (host: String, updatedAt: Date)] = [:]
    private var probingIDs: Set<String> = []
    private var running = false

    static func beaconCadence(highFrequency: Bool) -> (interval: DispatchTimeInterval, leeway: DispatchTimeInterval) {
        highFrequency ? (.seconds(5), .seconds(1)) : (.seconds(15), .seconds(3))
    }

    init(
        queue: DispatchQueue,
        udpPort: UInt16 = SyncProtocol.defaultUDPDiscoveryPort,
        localDeviceID: String,
        beaconProvider: @escaping () -> DiscoveryBeacon?,
        onPeerDiscovered: @escaping (DiscoveredSyncPeer) -> Void
    ) {
        self.queue = queue
        self.udpPort = udpPort
        self.localDeviceID = localDeviceID
        self.beaconProvider = beaconProvider
        self.onPeerDiscovered = onPeerDiscovered
    }

    deinit {
        stop()
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.startBonjourBrowser()
            self.startUDPSocket()
            self.startBeaconTimer()
            self.broadcastBeaconNow()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.running = false
            self.browser?.cancel()
            self.browser = nil
            self.beaconTimer?.cancel()
            self.beaconTimer = nil
            self.udpReadSource?.cancel()
            self.udpReadSource = nil
            self.resolvedHosts.removeAll()
            self.probingIDs.removeAll()
            self.cachedBroadcastTargets = nil
            if self.udpFD >= 0 {
                close(self.udpFD)
                self.udpFD = -1
            }
        }
    }

    /// 状态变化（如开启配对窗口、改名、系统唤醒）时立刻补发一帧信标并刷新广播网卡列表。
    func triggerBroadcast() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.cachedBroadcastTargets = nil
            self.broadcastBeaconNow()
        }
    }

    /// 配对窗口打开时提频到 5 秒以便快速发现；常规稳态使用 15 秒以减少待机唤醒。
    func setHighFrequency(_ enabled: Bool) {
        queue.async { [weak self] in
            guard let self, self.highFrequencyBeacon != enabled else { return }
            self.highFrequencyBeacon = enabled
            guard self.running else { return }
            self.startBeaconTimer()
        }
    }

    // MARK: - Bonjour

    static func makeTXTRecord(from beacon: DiscoveryBeacon) -> NWTXTRecord {
        var txt = NWTXTRecord()
        txt["v"] = "\(beacon.proto)"
        txt["id"] = beacon.deviceId
        txt["gid"] = beacon.groupId
        txt["name"] = String(beacon.deviceName.prefix(64))
        txt["os"] = beacon.platform.rawValue
        txt["port"] = "\(beacon.tcpPort)"
        txt["pair"] = beacon.pairingOpen ? "1" : "0"
        return txt
    }

    private func startBonjourBrowser() {
        let params = NWParameters()
        params.includePeerToPeer = false
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
            type: SyncProtocol.bonjourServiceType,
            domain: "local."
        )
        let browser = NWBrowser(for: descriptor, using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.running else { return }
            for result in results {
                self.handleBonjourResult(result)
            }
        }
        browser.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                Log.sync.error("Bonjour 浏览失败：\(error.localizedDescription, privacy: .public)")
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func handleBonjourResult(_ result: NWBrowser.Result) {
        guard case .bonjour(let txt) = result.metadata,
              let deviceID = txt["id"], !deviceID.isEmpty,
              deviceID != localDeviceID,
              let groupID = txt["gid"], !groupID.isEmpty,
              let portStr = txt["port"], let port = UInt16(portStr), port > 0
        else { return }

        let name = txt["name"] ?? deviceID
        let platform = txt["os"].flatMap(SyncPlatform.init(rawValue:)) ?? .other
        let pairingOpen = txt["pair"] == "1"

        // 15 秒内已通过 UDP 或 Bonjour 解析过该设备 IP 时直接复用，避免反复发起空 TCP 探测。
        let now = Date()
        if let cached = resolvedHosts[deviceID], now.timeIntervalSince(cached.updatedAt) < 15 {
            let peer = DiscoveredSyncPeer(
                deviceID: deviceID,
                deviceName: name,
                platform: platform,
                groupID: groupID,
                host: cached.host,
                port: port,
                pairingOpen: pairingOpen,
                lastSeen: now
            )
            onPeerDiscovered(peer)
            return
        }
        guard !probingIDs.contains(deviceID) else { return }
        probingIDs.insert(deviceID)

        resolveBonjourHost(endpoint: result.endpoint) { [weak self] host in
            guard let self else { return }
            self.probingIDs.remove(deviceID)
            guard self.running, let host, !host.isEmpty else { return }
            let seenAt = Date()
            self.resolvedHosts[deviceID] = (host, seenAt)
            let peer = DiscoveredSyncPeer(
                deviceID: deviceID,
                deviceName: name,
                platform: platform,
                groupID: groupID,
                host: host,
                port: port,
                pairingOpen: pairingOpen,
                lastSeen: seenAt
            )
            self.onPeerDiscovered(peer)
        }
    }

    private func resolveBonjourHost(endpoint: NWEndpoint, completion: @escaping (String?) -> Void) {
        if let direct = SyncConnection.extractHost(from: endpoint) {
            completion(direct)
            return
        }
        // 使用临时 NWConnection 解析 Bonjour service 到具体 IP，然后立即取消。
        let params = NWParameters.tcp
        let probe = NWConnection(to: endpoint, using: params)
        var finished = false
        let timer = DispatchSource.makeTimerSource(queue: queue)

        func finish(_ host: String?) {
            guard !finished else { return }
            finished = true
            timer.cancel()
            probe.stateUpdateHandler = nil
            probe.cancel()
            completion(host)
        }

        timer.schedule(deadline: .now() + 3)
        timer.setEventHandler { finish(nil) }
        timer.resume()

        probe.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let remote = probe.currentPath?.remoteEndpoint,
                   let host = SyncConnection.extractHost(from: remote) {
                    finish(host)
                } else {
                    finish(nil)
                }
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        probe.start(queue: queue)
    }

    // MARK: - UDP 局域网广播发现

    private func startUDPSocket() {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            Log.sync.error("创建 UDP 发现套接字失败")
            return
        }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = udpPort.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Log.sync.error("绑定 UDP 发现端口 \(self.udpPort) 失败：errno=\(errno)")
            close(fd)
            return
        }

        self.udpFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainUDPPackets()
        }
        source.resume()
        self.udpReadSource = source
    }

    private func startBeaconTimer() {
        beaconTimer?.cancel()
        let cadence = Self.beaconCadence(highFrequency: highFrequencyBeacon)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + cadence.interval, repeating: cadence.interval, leeway: cadence.leeway)
        timer.setEventHandler { [weak self] in
            self?.broadcastBeaconNow()
        }
        timer.resume()
        self.beaconTimer = timer
    }

    private func broadcastAddresses() -> [String] {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = cachedBroadcastTargets, now - cached.refreshedAt < 60 {
            return cached.addresses
        }
        let addresses = Self.activeBroadcastAddresses()
        cachedBroadcastTargets = (addresses, now)
        return addresses
    }

    private func broadcastBeaconNow() {
        guard running, udpFD >= 0,
              let beacon = beaconProvider(),
              let data = try? JSONEncoder().encode(beacon)
        else { return }

        let targets = broadcastAddresses()
        for targetIP in targets {
            var dst = sockaddr_in()
            dst.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            dst.sin_family = sa_family_t(AF_INET)
            dst.sin_port = udpPort.bigEndian
            guard inet_pton(AF_INET, targetIP, &dst.sin_addr) == 1 else { continue }
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                withUnsafePointer(to: &dst) { dstPtr in
                    dstPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        _ = sendto(udpFD, base, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    private func drainUDPPackets() {
        guard running, udpFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &from) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(udpFD, &buffer, buffer.count, 0, sa, &fromLen)
                }
            }
            guard count > 0 else { break }
            var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var sinAddr = from.sin_addr
            guard inet_ntop(AF_INET, &sinAddr, &ipBuf, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let host = String(cString: ipBuf)
            let payload = Data(buffer[0..<count])
            guard let beacon = try? JSONDecoder().decode(DiscoveryBeacon.self, from: payload),
                  beacon.proto == SyncProtocol.version,
                  beacon.deviceId != localDeviceID,
                  beacon.tcpPort > 0
            else { continue }

            let seenAt = Date()
            resolvedHosts[beacon.deviceId] = (host, seenAt)
            let peer = DiscoveredSyncPeer(
                deviceID: beacon.deviceId,
                deviceName: beacon.deviceName.isEmpty ? beacon.deviceId : beacon.deviceName,
                platform: beacon.platform,
                groupID: beacon.groupId,
                host: host,
                port: beacon.tcpPort,
                pairingOpen: beacon.pairingOpen,
                lastSeen: seenAt
            )
            onPeerDiscovered(peer)
        }
    }

    // MARK: - 活跃局域网接口枚举

    /// 返回当前活跃物理网卡的 IPv4 广播地址列表（跳过回环与虚拟隧道接口）。
    static func activeBroadcastAddresses() -> [String] {
        var result = Set<String>()
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return ["255.255.255.255"] }
        defer { freeifaddrs(first) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            let supportsBroadcast = (flags & IFF_BROADCAST) != 0
            let name = String(cString: current.pointee.ifa_name)
            let isVirtual = name.hasPrefix("utun") || name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("lo")

            if isUp && !isLoopback && supportsBroadcast && !isVirtual,
               let addr = current.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
               let dst = current.pointee.ifa_dstaddr, dst.pointee.sa_family == sa_family_t(AF_INET) {
                var sin = dst.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &sin, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let ip = String(cString: buf)
                    if !ip.isEmpty && ip != "0.0.0.0" { result.insert(ip) }
                }
            }
            ptr = current.pointee.ifa_next
        }
        if result.isEmpty { result.insert("255.255.255.255") }
        return Array(result)
    }

    /// 获取本机首选局域网 IPv4 地址（用于生成附带地址提示的群组邀请码）。
    static func preferredLocalIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }

        var candidates: [(priority: Int, ip: String)] = []
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            let name = String(cString: current.pointee.ifa_name)
            if isUp && !isLoopback,
               let addr = current.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET) {
                var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &sin, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
                    let ip = String(cString: buf)
                    if ip.hasPrefix("169.254.") { ptr = current.pointee.ifa_next; continue }
                    let prio: Int
                    if name == "en0" { prio = 0 }
                    else if name.hasPrefix("en") { prio = 1 }
                    else if name.hasPrefix("utun") { prio = 2 }
                    else { prio = 3 }
                    candidates.append((prio, ip))
                }
            }
            ptr = current.pointee.ifa_next
        }
        return candidates.sorted { $0.priority < $1.priority }.first?.ip
    }
}
