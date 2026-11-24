// SPDX-License-Identifier: MIT

import AppKit
import CryptoKit
import Foundation
import Network

/// 当前已在线连接的同组设备。
struct ConnectedSyncPeer: Equatable, Identifiable, Sendable {
    var deviceID: String
    var deviceName: String
    var platform: SyncPlatform
    var host: String
    var port: UInt16
    var connectedAt: Date

    var id: String { deviceID }
    var endpoint: SyncEndpoint { SyncEndpoint(host: host, port: port) }
}

/// 正在进行的 6 位确认码配对会话。
struct ActivePairingSession: Equatable, Identifiable, Sendable {
    enum Direction: Equatable, Sendable {
        case incoming
        case outgoing
    }

    let id: UUID
    let direction: Direction
    let peerDeviceID: String
    let peerDeviceName: String
    let peerPlatform: SyncPlatform
    let sasCode: String
    let expiresAt: Date
}

/// 收到远端剪贴板内容时交给 ClipboardController 处理的事件。
enum RemoteClipboardEvent: Sendable {
    case text(
        text: String,
        fingerprint: String,
        originDeviceID: String,
        originDeviceName: String,
        originPlatform: SyncPlatform,
        shouldWritePasteboard: Bool
    )
    case image(
        png: Data,
        width: Int,
        height: Int,
        fingerprint: String,
        originDeviceID: String,
        originDeviceName: String,
        originPlatform: SyncPlatform,
        shouldWritePasteboard: Bool
    )
    case filesManifest(
        info: RemoteFileInfo,
        fingerprint: String,
        originPlatform: SyncPlatform
    )
    case filesReady(
        transferID: UUID,
        localURLs: [URL],
        originDeviceID: String,
        shouldWritePasteboard: Bool
    )
}

/// 跨设备剪贴板共享核心服务（ShunSync v1）。
/// 负责局域网/直连多机对等网、6 位码与邀请码配对、防回环广播以及流式文件传输。
@MainActor
final class ClipboardSyncService: ObservableObject {
    enum TransferError: Error, LocalizedError, Equatable {
        case syncDisabled
        case peerOffline
        case cancelled
        case invalidPath
        case integrityMismatch
        case remoteError(String)
        case ioFailed(String)

        var errorDescription: String? {
            switch self {
            case .syncDisabled: return L("跨设备剪贴板共享未开启")
            case .peerOffline: return L("来源设备已离线，暂时无法接收文件")
            case .cancelled: return L("已取消接收文件")
            case .invalidPath: return L("文件路径不安全，已拒绝接收")
            case .integrityMismatch: return L("文件校验失败，请重试")
            case .remoteError(let msg):
                if msg == "not_found" { return L("文件已过期或已被移除") }
                if msg == "invalid_offset" { return L("文件大小已发生变化") }
                return msg.isEmpty ? L("对方暂时无法提供该文件") : msg
            case .ioFailed(let msg): return msg
            }
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var isPaused = false
    @Published private(set) var listenPort: UInt16 = 0
    @Published private(set) var connectedPeers: [ConnectedSyncPeer] = []
    @Published private(set) var discoveredPeers: [DiscoveredSyncPeer] = []
    @Published private(set) var knownPeers: [KnownSyncPeer] = []
    @Published private(set) var activePairing: ActivePairingSession?
    @Published private(set) var pairingWindowUntil: Date?
    @Published private(set) var activeTransfers: [UUID: SyncTransferProgress] = [:]
    @Published private(set) var cacheBytes: Int64 = 0
    @Published private(set) var statusMessage: String?

    var onRemoteClipboard: ((RemoteClipboardEvent) -> Void)?
    /// 收到局域网新设备的 6 位码配对请求时通知界面打开设置页，避免用户错过确认码。
    var onIncomingPairing: (() -> Void)?

    let identityStore: SyncIdentityStore
    let cacheManager: SyncCacheManager
    let fileRegistry = SyncFileRegistry()
    let localPlatform: SyncPlatform
    private let enableDiscovery: Bool
    private let netQueue = DispatchQueue(label: "MacShun.ClipboardSync.net", qos: .utility)

    private var identity: SyncIdentity
    private var config = ClipboardSyncConfig()
    private var listener: NWListener?
    private var discovery: SyncDiscovery?
    private var eventTracker = SyncEventTracker()

    /// 单连接复用拉取文件时的分帧投递信箱（适配二级路由 / NAT 只能单向建连的场景）。
    private final class InBandFileMailbox: @unchecked Sendable {
        private let waiters = Locked<[UUID: AsyncThrowingStream<SyncFrame, Error>.Continuation]>([:])

        func register(transferID: UUID) -> AsyncThrowingStream<SyncFrame, Error> {
            var continuation: AsyncThrowingStream<SyncFrame, Error>.Continuation!
            let stream = AsyncThrowingStream<SyncFrame, Error> { cont in
                continuation = cont
            }
            waiters.update { map in
                map[transferID]?.finish(throwing: TransferError.cancelled)
                map[transferID] = continuation
            }
            return stream
        }

        func deliver(_ frame: SyncFrame, for transferID: UUID) {
            let cont = waiters.withLock { $0[transferID] }
            cont?.yield(frame)
        }

        func unregister(transferID: UUID) {
            let cont = waiters.update { $0.removeValue(forKey: transferID) }
            cont?.finish()
        }

        func failAll(_ error: Error) {
            let all = waiters.update { map -> [AsyncThrowingStream<SyncFrame, Error>.Continuation] in
                let values = Array(map.values)
                map.removeAll()
                return values
            }
            all.forEach { $0.finish(throwing: error) }
        }
    }

    private struct FilePullChannel: Sendable {
        let sendRequest: @Sendable (FilePullRequestMessage) async throws -> Void
        let nextFrame: @Sendable () async throws -> SyncFrame
        let finish: @Sendable () async -> Void
    }

    private final class PeerSession {
        let id = UUID()
        let deviceID: String
        var deviceName: String
        let platform: SyncPlatform
        let host: String
        var listenPort: UInt16
        let initiatedByLocal: Bool
        let connectedAt = Date()
        let connection: SyncConnection
        let inBandFiles = InBandFileMailbox()
        var readerTask: Task<Void, Never>?
        var heartbeatTask: Task<Void, Never>?

        init(
            deviceID: String,
            deviceName: String,
            platform: SyncPlatform,
            host: String,
            listenPort: UInt16,
            initiatedByLocal: Bool,
            connection: SyncConnection
        ) {
            self.deviceID = deviceID
            self.deviceName = deviceName
            self.platform = platform
            self.host = host
            self.listenPort = listenPort
            self.initiatedByLocal = initiatedByLocal
            self.connection = connection
        }

        func cancel() {
            inBandFiles.failAll(TransferError.peerOffline)
            readerTask?.cancel()
            heartbeatTask?.cancel()
            connection.close()
        }
    }

    private struct PendingPairingContinuation {
        let id: UUID
        let connection: SyncConnection
        let approve: (() -> Void)?
        let reject: ((String) -> Void)?
        let cancel: (() -> Void)?
    }

    private var sessions: [String: PeerSession] = [:]
    private var dialingEndpoints: Set<String> = []
    private var dialingDeviceIDs: Set<String> = []
    private var pendingPairing: PendingPairingContinuation?
    private var pairingWindowTimer: Task<Void, Never>?
    private var lastPairingAttempt: [String: Date] = [:]
    private var maintenanceTask: Task<Void, Never>?
    private var transferTasks: [UUID: Task<[URL], Error>] = [:]
    private var autoPrefetchTasks: [UUID: Task<Void, Never>] = [:]
    private var asleep = false

    init(
        identityStore: SyncIdentityStore = SyncIdentityStore(),
        cacheManager: SyncCacheManager = SyncCacheManager(),
        enableDiscovery: Bool = true,
        localPlatform: SyncPlatform = .macos
    ) {
        self.identityStore = identityStore
        self.cacheManager = cacheManager
        self.enableDiscovery = enableDiscovery
        self.localPlatform = localPlatform
        let loaded = identityStore.loadOrCreate()
        self.identity = loaded
        self.knownPeers = loaded.knownPeers
        refreshCacheSizeAsync()
    }

    var localDeviceID: String { identity.deviceID }
    var groupID: String { identity.groupID }
    var shortGroupID: String { String(identity.groupID.prefix(8)) }

    /// 本机局域网直连地址（例如 `192.168.1.8:37219`），便于和 Win顺 核对或手动填写。
    var localAddressDisplay: String? {
        guard listenPort > 0, let ip = SyncDiscovery.preferredLocalIPv4() else { return nil }
        return "\(ip):\(listenPort)"
    }

    var effectiveDeviceName: String {
        let custom = config.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        let host = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return host.isEmpty ? "Mac" : host
    }

    var isPairingWindowOpen: Bool {
        guard let until = pairingWindowUntil else { return false }
        return until > Date()
    }

    /// 是否允许其他设备发起 6 位码配对（默认开启，也可在高级设置关闭并改用临时 2 分钟窗口）。
    var isAcceptingPairing: Bool {
        config.allowPairingRequests || isPairingWindowOpen
    }

    func shouldNotifyIncomingFiles(for info: RemoteFileInfo) -> Bool {
        guard config.notifyIncomingFiles else { return false }
        let limitBytes = Int64(max(0, config.autoDownloadFileLimitMB)) * 1024 * 1024
        return limitBytes == 0 || info.totalBytes > limitBytes
    }

    /// 生成可复制到 Win顺 / 其他 Mac顺 的群组邀请码。
    func makeInviteCode() -> String {
        let hint: String?
        if listenPort > 0, let ip = SyncDiscovery.preferredLocalIPv4() {
            hint = "\(ip):\(listenPort)"
        } else {
            hint = nil
        }
        return ShunSyncCrypto.encodeInviteCode(groupKey: identity.groupKey, peerHint: hint)
    }

    // MARK: - 配置与生命周期

    func apply(config newConfig: ClipboardSyncConfig) {
        let previous = config
        config = newConfig
        guard newConfig.enabled else {
            stop()
            return
        }
        let portChanged = isRunning && previous.listenPort != newConfig.listenPort
        if !isRunning {
            start()
        } else if portChanged {
            stop()
            start()
        } else {
            if previous.deviceName != newConfig.deviceName
                || previous.allowPairingRequests != newConfig.allowPairingRequests {
                updateBonjourService()
                broadcastPeerUpdate()
                discovery?.triggerBroadcast()
            }
            if previous.manualPeers != newConfig.manualPeers {
                connectConfiguredPeers()
            }
        }
        pruneCacheAsync()
    }

    func togglePause() {
        guard isRunning else { return }
        isPaused.toggle()
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
    }

    func handleWillSleep() {
        asleep = true
        discovery?.stop()
        maintenanceTask?.cancel()
        maintenanceTask = nil
    }

    func handleDidWake() {
        asleep = false
        guard isRunning else { return }
        discovery?.start()
        startMaintenanceLoop()
        connectConfiguredPeers()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        statusMessage = nil
        startListener(port: config.listenPort)
        if enableDiscovery && !asleep {
            let disc = SyncDiscovery(
                queue: netQueue,
                localDeviceID: identity.deviceID,
                beaconProvider: { [weak self] in
                    // 从主线程原子快照读取会阻塞，这里改用同步维护的快照。
                    self?.currentBeaconSnapshot()
                },
                onPeerDiscovered: { [weak self] peer in
                    Task { @MainActor [weak self] in
                        self?.handleDiscoveredPeer(peer)
                    }
                }
            )
            discovery = disc
            disc.start()
        }
        startMaintenanceLoop()
        connectConfiguredPeers()
        pruneCacheAsync()
    }

    func stop() {
        guard isRunning || listener != nil || discovery != nil else { return }
        isRunning = false
        isPaused = false
        statusMessage = nil
        closePairingWindow()
        cancelActivePairing()
        maintenanceTask?.cancel()
        maintenanceTask = nil
        discovery?.stop()
        discovery = nil
        listener?.cancel()
        listener = nil
        listenPort = 0
        for session in sessions.values { session.cancel() }
        sessions.removeAll()
        dialingEndpoints.removeAll()
        dialingDeviceIDs.removeAll()
        for task in transferTasks.values { task.cancel() }
        transferTasks.removeAll()
        for task in autoPrefetchTasks.values { task.cancel() }
        autoPrefetchTasks.removeAll()
        activeTransfers.removeAll()
        connectedPeers = []
        discoveredPeers = []
    }

    private let beaconSnapshotLock = Locked<DiscoveryBeacon?>(nil)

    private func refreshBeaconSnapshot() {
        guard isRunning, listenPort > 0 else {
            beaconSnapshotLock.set(nil)
            return
        }
        beaconSnapshotLock.set(DiscoveryBeacon(
            proto: SyncProtocol.version,
            deviceId: identity.deviceID,
            deviceName: effectiveDeviceName,
            platform: localPlatform,
            groupId: identity.groupID,
            tcpPort: listenPort,
            pairingOpen: isAcceptingPairing
        ))
    }

    private func currentBeaconSnapshot() -> DiscoveryBeacon? {
        beaconSnapshotLock.get()
    }

    // MARK: - 监听与入站分发

    private func startListener(port: UInt16, allowFallback: Bool = true) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
        }
        do {
            let nwListener: NWListener
            if port > 0, let nwPort = NWEndpoint.Port(rawValue: port) {
                nwListener = try NWListener(using: params, on: nwPort)
            } else {
                nwListener = try NWListener(using: params)
            }
            nwListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.isRunning, self.listener === nwListener else { return }
                    switch state {
                    case .ready:
                        self.listenPort = nwListener.port?.rawValue ?? port
                        self.statusMessage = nil
                        self.refreshBeaconSnapshot()
                        self.updateBonjourService()
                        self.discovery?.triggerBroadcast()
                        Log.sync.notice("剪贴板共享监听已就绪，端口 \(self.listenPort)")
                    case .failed(let error):
                        Log.sync.error("剪贴板共享监听失败（端口 \(port)）：\(error.localizedDescription, privacy: .public)")
                        nwListener.cancel()
                        self.listener = nil
                        if allowFallback && port != 0 {
                            self.startListener(port: 0, allowFallback: false)
                        } else {
                            self.statusMessage = L("本地网络监听失败，请检查系统“本地网络”权限")
                        }
                    default:
                        break
                    }
                }
            }
            nwListener.newConnectionHandler = { [weak self] nwConn in
                Task { @MainActor [weak self] in
                    guard let self, self.isRunning else {
                        nwConn.cancel()
                        return
                    }
                    let conn = SyncConnection(connection: nwConn, queue: self.netQueue)
                    Task { [weak self] in
                        await self?.handleIncomingConnection(conn)
                    }
                }
            }
            listener = nwListener
            nwListener.start(queue: netQueue)
        } catch {
            if allowFallback && port != 0 {
                startListener(port: 0, allowFallback: false)
            } else {
                statusMessage = L("本地网络监听失败，请检查系统“本地网络”权限")
            }
        }
    }

    private func updateBonjourService() {
        refreshBeaconSnapshot()
        guard enableDiscovery, let listener, let beacon = currentBeaconSnapshot() else { return }
        let txt = SyncDiscovery.makeTXTRecord(from: beacon)
        listener.service = NWListener.Service(
            name: String(beacon.deviceId.prefix(12)),
            type: SyncProtocol.bonjourServiceType,
            txtRecord: txt
        )
    }

    private func handleIncomingConnection(_ conn: SyncConnection) async {
        do {
            try await conn.startAndWaitReady(timeoutSeconds: 10)
            let hello = try await conn.receivePlaintextJSON(SyncHelloMessage.self, timeoutSeconds: 10)
            guard hello.type == "hello",
                  hello.proto == SyncProtocol.version,
                  !hello.deviceId.isEmpty,
                  hello.deviceId != identity.deviceID,
                  let clientEphPub = Data(base64Encoded: hello.ephPub),
                  let clientNonce = Data(base64Encoded: hello.nonce),
                  clientEphPub.count == ShunSyncCrypto.keySize,
                  clientNonce.count == ShunSyncCrypto.nonceSize
            else {
                try? await conn.sendPlaintextJSON(makeRejectAck("bad_hello"))
                conn.close()
                return
            }

            switch hello.mode {
            case .sync, .file:
                guard hello.groupId == identity.groupID else {
                    try? await conn.sendPlaintextJSON(makeRejectAck("wrong_group"))
                    conn.close()
                    return
                }
                guard !identity.revokedDeviceIDs.contains(hello.deviceId) else {
                    try? await conn.sendPlaintextJSON(makeRejectAck("revoked"))
                    conn.close()
                    return
                }
                let (serverPriv, serverPub) = ShunSyncCrypto.generateEphemeralKeyPair()
                let serverNonce = ShunSyncCrypto.randomBytes(count: ShunSyncCrypto.nonceSize)
                let shared = try ShunSyncCrypto.sharedSecret(privateKey: serverPriv, peerPublicKeyData: clientEphPub)
                let keys = try ShunSyncCrypto.deriveSyncSession(
                    mode: hello.mode,
                    groupKey: identity.groupKey,
                    clientNonce: clientNonce,
                    serverNonce: serverNonce,
                    clientEphPub: clientEphPub,
                    serverEphPub: serverPub,
                    clientDeviceID: hello.deviceId,
                    serverDeviceID: identity.deviceID,
                    sharedSecret: shared
                )
                let ack = SyncHelloAckMessage(
                    accepted: true,
                    error: nil,
                    deviceId: identity.deviceID,
                    deviceName: effectiveDeviceName,
                    platform: localPlatform,
                    ephPub: serverPub.base64EncodedString(),
                    nonce: serverNonce.base64EncodedString(),
                    proof: keys.serverProof.base64EncodedString(),
                    listenPort: listenPort
                )
                try await conn.sendPlaintextJSON(ack)
                try conn.activateCipher(sendKey: keys.s2cKey, recvKey: keys.c2sKey)

                let firstFrame = try await conn.receiveEncryptedFrame(timeoutSeconds: 10)
                guard case .json(let authData) = firstFrame,
                      let finish = try? JSONDecoder().decode(AuthFinishMessage.self, from: authData),
                      finish.type == "auth_finish",
                      let clientProof = Data(base64Encoded: finish.proof),
                      ShunSyncCrypto.constantTimeEquals(clientProof, keys.clientProof)
                else {
                    conn.close()
                    return
                }

                try await conn.sendEncryptedJSON(AuthOkMessage(peers: currentPeerHints()))
                let peerHost = conn.remoteHost ?? ""
                let peerPort = hello.listenPort > 0 ? hello.listenPort : SyncProtocol.defaultTCPPort
                if hello.mode == .sync {
                    attachSyncSession(
                        deviceID: hello.deviceId,
                        deviceName: hello.deviceName,
                        platform: hello.platform,
                        host: peerHost,
                        listenPort: peerPort,
                        initiatedByLocal: false,
                        connection: conn
                    )
                } else {
                    let registry = fileRegistry
                    Task.detached(priority: .utility) {
                        await Self.serveIncomingFileRequests(on: conn, registry: registry)
                    }
                }

            case .pair:
                await handleIncomingPairing(conn: conn, hello: hello, clientEphPub: clientEphPub, clientNonce: clientNonce)
            }
        } catch {
            conn.close()
        }
    }

    private func makeRejectAck(_ reason: String) -> SyncHelloAckMessage {
        SyncHelloAckMessage(
            accepted: false,
            error: reason,
            deviceId: identity.deviceID,
            deviceName: effectiveDeviceName,
            platform: localPlatform,
            ephPub: nil,
            nonce: nil,
            proof: nil,
            listenPort: listenPort
        )
    }

    // MARK: - 6 位确认码配对（服务端与客户端）

    /// 打开 2 分钟新设备加入窗口，让局域网内的 Win顺 / Mac顺 发起 6 位码配对。
    func openPairingWindow(duration: TimeInterval = SyncProtocol.pairingWindowSeconds) {
        guard isRunning else { return }
        pairingWindowTimer?.cancel()
        let until = Date().addingTimeInterval(duration)
        pairingWindowUntil = until
        updateBonjourService()
        discovery?.setHighFrequency(true)
        discovery?.triggerBroadcast()
        pairingWindowTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(1, duration) * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.closePairingWindow()
        }
    }

    func closePairingWindow() {
        pairingWindowTimer?.cancel()
        pairingWindowTimer = nil
        if pairingWindowUntil != nil {
            pairingWindowUntil = nil
            updateBonjourService()
            discovery?.setHighFrequency(false)
            discovery?.triggerBroadcast()
        }
    }

    private func handleIncomingPairing(
        conn: SyncConnection,
        hello: SyncHelloMessage,
        clientEphPub: Data,
        clientNonce: Data
    ) async {
        guard isAcceptingPairing, activePairing == nil else {
            try? await conn.sendPlaintextJSON(makeRejectAck(isAcceptingPairing ? "pairing_busy" : "pairing_closed"))
            conn.close()
            return
        }
        let rateKey = hello.deviceId.isEmpty ? (conn.remoteHost ?? "unknown") : hello.deviceId
        let now = Date()
        if let last = lastPairingAttempt[rateKey], now.timeIntervalSince(last) < 8 {
            try? await conn.sendPlaintextJSON(makeRejectAck("pairing_rate_limited"))
            conn.close()
            return
        }
        lastPairingAttempt[rateKey] = now
        // 清理过期的频控记录。
        lastPairingAttempt = lastPairingAttempt.filter { now.timeIntervalSince($0.value) < 60 }
        do {
            let (serverPriv, serverPub) = ShunSyncCrypto.generateEphemeralKeyPair()
            let serverNonce = ShunSyncCrypto.randomBytes(count: ShunSyncCrypto.nonceSize)
            let shared = try ShunSyncCrypto.sharedSecret(privateKey: serverPriv, peerPublicKeyData: clientEphPub)
            let pairKeys = try ShunSyncCrypto.derivePairingSession(
                clientNonce: clientNonce,
                serverNonce: serverNonce,
                clientEphPub: clientEphPub,
                serverEphPub: serverPub,
                clientDeviceID: hello.deviceId,
                serverDeviceID: identity.deviceID,
                sharedSecret: shared
            )
            let ack = SyncHelloAckMessage(
                accepted: true,
                error: nil,
                deviceId: identity.deviceID,
                deviceName: effectiveDeviceName,
                platform: localPlatform,
                ephPub: serverPub.base64EncodedString(),
                nonce: serverNonce.base64EncodedString(),
                proof: nil,
                listenPort: listenPort
            )
            try await conn.sendPlaintextJSON(ack)
            try conn.activateCipher(sendKey: pairKeys.s2cKey, recvKey: pairKeys.c2sKey)

            let sessionID = UUID()
            let session = ActivePairingSession(
                id: sessionID,
                direction: .incoming,
                peerDeviceID: hello.deviceId,
                peerDeviceName: hello.deviceName,
                peerPlatform: hello.platform,
                sasCode: pairKeys.sasCode,
                expiresAt: Date().addingTimeInterval(SyncProtocol.pairingTimeoutSeconds)
            )
            activePairing = session
            onIncomingPairing?()

            let decision = await waitForIncomingPairingDecision(sessionID: sessionID, conn: conn)
            if activePairing?.id == sessionID { activePairing = nil }
            pendingPairing = nil

            switch decision {
            case .approved:
                // 若此前移除过这台设备，重新配对时自动解除吊销。
                if identity.revokedDeviceIDs.contains(hello.deviceId) {
                    identity.revokedDeviceIDs.removeAll { $0 == hello.deviceId }
                    identityStore.save(identity)
                }
                let grant = PairGrantMessage(
                    groupKey: identity.groupKey.base64EncodedString(),
                    peers: currentPeerHintsIncludingSelf(remoteSeenHost: conn.remoteHost)
                )
                try? await conn.sendEncryptedJSON(grant)
                if let host = conn.remoteHost, hello.listenPort > 0 {
                    recordKnownPeer(
                        deviceID: hello.deviceId,
                        deviceName: hello.deviceName,
                        platform: hello.platform,
                        host: host,
                        port: hello.listenPort
                    )
                }
            case .rejected(let reason):
                try? await conn.sendEncryptedJSON(PairRejectMessage(reason: reason))
            case .cancelled:
                break
            }
            conn.close()
        } catch {
            if activePairing?.peerDeviceID == hello.deviceId { activePairing = nil }
            pendingPairing = nil
            conn.close()
        }
    }

    private enum PairingDecision {
        case approved
        case rejected(String)
        case cancelled
    }

    private func waitForIncomingPairingDecision(sessionID: UUID, conn: SyncConnection) async -> PairingDecision {
        await withCheckedContinuation { (continuation: CheckedContinuation<PairingDecision, Never>) in
            var resolved = false
            var cancelWatchTask: Task<Void, Never>?
            var timeoutTask: Task<Void, Never>?

            func finish(_ decision: PairingDecision) {
                guard !resolved else { return }
                resolved = true
                cancelWatchTask?.cancel()
                timeoutTask?.cancel()
                continuation.resume(returning: decision)
            }

            pendingPairing = PendingPairingContinuation(
                id: sessionID,
                connection: conn,
                approve: { finish(.approved) },
                reject: { reason in finish(.rejected(reason)) },
                cancel: { finish(.cancelled) }
            )

            // 监听客户端中途取消或断开。
            cancelWatchTask = Task {
                do {
                    _ = try await conn.receiveEncryptedFrame(timeoutSeconds: SyncProtocol.pairingTimeoutSeconds)
                    finish(.cancelled)
                } catch {
                    finish(.cancelled)
                }
            }

            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(SyncProtocol.pairingTimeoutSeconds * 1_000_000_000))
                finish(.rejected("timeout"))
            }
        }
    }

    func approveActivePairing() {
        pendingPairing?.approve?()
    }

    func rejectActivePairing() {
        pendingPairing?.reject?("declined")
    }

    func cancelActivePairing() {
        if let pending = pendingPairing {
            pending.cancel?()
            pending.connection.close()
            pendingPairing = nil
        }
        activePairing = nil
    }

    /// 主动向局域网已有设备发起 6 位确认码配对，对方批准后自动加入其同步群组。
    func initiatePairing(with endpoint: SyncEndpoint) async throws {
        guard isRunning else { throw TransferError.syncDisabled }
        guard activePairing == nil else { throw TransferError.remoteError(L("已有正在进行的配对请求")) }

        let conn = SyncConnection.connect(to: endpoint, queue: netQueue)
        try await conn.startAndWaitReady(timeoutSeconds: 10)

        let (clientPriv, clientPub) = ShunSyncCrypto.generateEphemeralKeyPair()
        let clientNonce = ShunSyncCrypto.randomBytes(count: ShunSyncCrypto.nonceSize)
        let hello = SyncHelloMessage(
            mode: .pair,
            groupId: nil,
            deviceId: identity.deviceID,
            deviceName: effectiveDeviceName,
            platform: localPlatform,
            ephPub: clientPub.base64EncodedString(),
            nonce: clientNonce.base64EncodedString(),
            listenPort: listenPort
        )
        try await conn.sendPlaintextJSON(hello)
        let ack = try await conn.receivePlaintextJSON(SyncHelloAckMessage.self, timeoutSeconds: 10)
        guard ack.accepted,
              let serverPubB64 = ack.ephPub, let serverPub = Data(base64Encoded: serverPubB64),
              let serverNonceB64 = ack.nonce, let serverNonce = Data(base64Encoded: serverNonceB64),
              serverPub.count == ShunSyncCrypto.keySize, serverNonce.count == ShunSyncCrypto.nonceSize
        else {
            conn.close()
            let err: String
            switch ack.error {
            case "pairing_closed":
                err = L("对方已关闭新设备配对，请在对方的高级设置中开启后再试")
            case "pairing_rate_limited":
                err = L("配对请求太频繁，请稍等几秒再试")
            case "pairing_busy":
                err = L("对方正在处理另一个配对请求，请稍后再试")
            default:
                err = L("对方拒绝了配对请求")
            }
            throw TransferError.remoteError(err)
        }

        let shared = try ShunSyncCrypto.sharedSecret(privateKey: clientPriv, peerPublicKeyData: serverPub)
        let pairKeys = try ShunSyncCrypto.derivePairingSession(
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            clientEphPub: clientPub,
            serverEphPub: serverPub,
            clientDeviceID: identity.deviceID,
            serverDeviceID: ack.deviceId,
            sharedSecret: shared
        )
        try conn.activateCipher(sendKey: pairKeys.c2sKey, recvKey: pairKeys.s2cKey)

        let sessionID = UUID()
        activePairing = ActivePairingSession(
            id: sessionID,
            direction: .outgoing,
            peerDeviceID: ack.deviceId,
            peerDeviceName: ack.deviceName,
            peerPlatform: ack.platform,
            sasCode: pairKeys.sasCode,
            expiresAt: Date().addingTimeInterval(SyncProtocol.pairingTimeoutSeconds)
        )
        pendingPairing = PendingPairingContinuation(
            id: sessionID,
            connection: conn,
            approve: nil,
            reject: nil,
            cancel: {
                Task { try? await conn.sendEncryptedJSON(PairCancelMessage()); conn.close() }
            }
        )

        defer {
            if activePairing?.id == sessionID { activePairing = nil }
            if pendingPairing?.id == sessionID { pendingPairing = nil }
            conn.close()
        }

        let frame = try await conn.receiveEncryptedFrame(timeoutSeconds: SyncProtocol.pairingTimeoutSeconds)
        guard case .json(let data) = frame,
              let envelope = try? JSONDecoder().decode(SyncControlEnvelope.self, from: data)
        else {
            throw TransferError.remoteError(L("配对响应无效"))
        }

        if envelope.type == "pair_grant",
           let grant = try? JSONDecoder().decode(PairGrantMessage.self, from: data),
           let newKey = Data(base64Encoded: grant.groupKey),
           newKey.count == ShunSyncCrypto.keySize {
            adoptGroupKey(newKey, revoked: [], peerHints: grant.peers + [
                PeerHint(
                    deviceId: ack.deviceId,
                    deviceName: ack.deviceName,
                    platform: ack.platform,
                    host: endpoint.host,
                    port: ack.listenPort ?? endpoint.port
                ),
            ])
        } else if envelope.type == "pair_reject" {
            throw TransferError.remoteError(L("对方未同意本次配对"))
        } else {
            throw TransferError.remoteError(L("配对未完成"))
        }
    }

    /// 通过粘贴群组邀请码加入已有同步群组。返回附带的建议对端地址（如有）。
    @discardableResult
    func joinWithInviteCode(_ code: String) -> String? {
        guard let decoded = ShunSyncCrypto.decodeInviteCode(code) else { return nil }
        var hints: [PeerHint] = []
        if let peerHint = decoded.peerHint, let ep = SyncEndpoint.parse(peerHint) {
            hints.append(PeerHint(deviceId: "", deviceName: peerHint, platform: .other, host: ep.host, port: ep.port))
        }
        adoptGroupKey(decoded.groupKey, revoked: [], peerHints: hints)
        if let peerHint = decoded.peerHint, let ep = SyncEndpoint.parse(peerHint) {
            connectToEndpoint(ep)
        }
        return decoded.peerHint
    }

    /// 移除指定设备并轮换群组密钥，已在线的其他可信设备自动无感升级。
    func removeAndRotatePeer(deviceID: String) {
        let newKey = ShunSyncCrypto.generateGroupKey()
        var revoked = Set(identity.revokedDeviceIDs)
        revoked.insert(deviceID)
        let revokedList = Array(revoked)
        let msg = GroupRotateMessage(
            newGroupKey: newKey.base64EncodedString(),
            revokedDeviceIds: revokedList
        )

        let remainingSessions = sessions.values.filter { $0.deviceID != deviceID }
        let removedSession = sessions.removeValue(forKey: deviceID)
        removedSession?.cancel()
        identity.knownPeers.removeAll { $0.deviceID == deviceID }
        knownPeers = identity.knownPeers

        Task {
            for session in remainingSessions {
                try? await session.connection.sendEncryptedJSON(msg)
            }
            // 短暂留出报文冲刷时间后本地切到新密钥并重连可信设备。
            try? await Task.sleep(nanoseconds: 150_000_000)
            adoptGroupKey(newKey, revoked: revokedList, peerHints: [])
        }
    }

    /// 退出当前组并生成全新群组密钥（重置本机群组）。
    func resetGroupKey() {
        identity.knownPeers = []
        knownPeers = []
        adoptGroupKey(ShunSyncCrypto.generateGroupKey(), revoked: [], peerHints: [])
    }

    private func adoptGroupKey(_ newKey: Data, revoked: [String], peerHints: [PeerHint]) {
        identity.groupKey = newKey
        identity.revokedDeviceIDs = revoked
        for hint in peerHints where !hint.deviceId.isEmpty && hint.deviceId != identity.deviceID {
            recordKnownPeer(
                deviceID: hint.deviceId,
                deviceName: hint.deviceName,
                platform: hint.platform,
                host: hint.host,
                port: hint.port,
                saveImmediately: false
            )
        }
        identityStore.save(identity)
        knownPeers = identity.knownPeers

        for session in sessions.values { session.cancel() }
        sessions.removeAll()
        connectedPeers = []
        updateBonjourService()
        discovery?.triggerBroadcast()

        if isRunning {
            for hint in peerHints where !hint.host.isEmpty && hint.port > 0 && hint.deviceId != identity.deviceID {
                connectToEndpoint(SyncEndpoint(host: hint.host, port: hint.port), expectedDeviceID: hint.deviceId.isEmpty ? nil : hint.deviceId)
            }
            connectConfiguredPeers()
        }
    }

    // MARK: - 发现与对等 Mesh 连接

    private func handleDiscoveredPeer(_ peer: DiscoveredSyncPeer) {
        guard isRunning, peer.deviceID != identity.deviceID else { return }
        if let idx = discoveredPeers.firstIndex(where: { $0.deviceID == peer.deviceID }) {
            discoveredPeers[idx] = peer
        } else {
            discoveredPeers.append(peer)
        }

        // 同组且未吊销的设备自动建立连接。
        if peer.groupID == identity.groupID, !identity.revokedDeviceIDs.contains(peer.deviceID) {
            recordKnownPeer(
                deviceID: peer.deviceID,
                deviceName: peer.deviceName,
                platform: peer.platform,
                host: peer.host,
                port: peer.port
            )
            if sessions[peer.deviceID] == nil {
                connectToEndpoint(peer.endpoint, expectedDeviceID: peer.deviceID)
            }
        }
    }

    func connectConfiguredPeers() {
        guard isRunning else { return }
        for raw in config.manualPeers {
            if let ep = SyncEndpoint.parse(raw) {
                connectToEndpoint(ep)
            }
        }
        for known in identity.knownPeers where !identity.revokedDeviceIDs.contains(known.deviceID) {
            if sessions[known.deviceID] == nil, let host = known.lastHost, !host.isEmpty, known.lastPort > 0 {
                connectToEndpoint(SyncEndpoint(host: host, port: known.lastPort), expectedDeviceID: known.deviceID)
            }
        }
    }

    /// 立刻补发发现信标并重连所有已知与手动配置的设备。
    func refreshDiscoveryAndReconnect() {
        guard isRunning else { return }
        updateBonjourService()
        discovery?.triggerBroadcast()
        connectConfiguredPeers()
    }

    /// 主动连接指定地址：若已在同一共享组直接连通；若不在同组则自动转入 6 位码配对。
    func connectOrPair(endpoint: SyncEndpoint) async -> String {
        guard isRunning else { return L("跨设备剪贴板共享未开启") }
        do {
            let (conn, ack, peerHints) = try await openAuthenticatedConnection(to: endpoint, mode: .sync, timeoutSeconds: 5)
            guard isRunning else { conn.close(); return L("跨设备剪贴板共享未开启") }
            attachSyncSession(
                deviceID: ack.deviceId,
                deviceName: ack.deviceName,
                platform: ack.platform,
                host: endpoint.host,
                listenPort: ack.listenPort ?? endpoint.port,
                initiatedByLocal: true,
                connection: conn
            )
            processGossipPeers(peerHints)
            return L("已连接到“%@”", ack.deviceName)
        } catch let err as SyncConnection.ConnectionError {
            if case .rejected(let reason) = err, reason == "wrong_group" {
                do {
                    try await initiatePairing(with: endpoint)
                    return L("配对成功，已连接到 %@", endpoint.formatted)
                } catch {
                    return error.localizedDescription
                }
            }
            return describeConnectionError(err, endpoint: endpoint)
        } catch {
            return L("无法连接到 %@，请确认对方在同一局域网/虚拟局域网且已开启共享", endpoint.formatted)
        }
    }

    /// 主动测试并连接指定地址，返回面向用户的清晰联调结果说明。
    func connectManuallyWithDiagnosis(_ endpoint: SyncEndpoint) async -> String {
        guard isRunning else { return L("跨设备剪贴板共享未开启") }
        do {
            let (conn, ack, peerHints) = try await openAuthenticatedConnection(to: endpoint, mode: .sync)
            guard isRunning else { conn.close(); return L("跨设备剪贴板共享未开启") }
            attachSyncSession(
                deviceID: ack.deviceId,
                deviceName: ack.deviceName,
                platform: ack.platform,
                host: endpoint.host,
                listenPort: ack.listenPort ?? endpoint.port,
                initiatedByLocal: true,
                connection: conn
            )
            processGossipPeers(peerHints)
            return L("已连接到“%@”", ack.deviceName)
        } catch let err as SyncConnection.ConnectionError {
            return describeConnectionError(err, endpoint: endpoint)
        } catch {
            return L("无法连接到 %@，请确认对方在同一局域网/虚拟局域网且已开启共享", endpoint.formatted)
        }
    }

    private func describeConnectionError(_ err: SyncConnection.ConnectionError, endpoint: SyncEndpoint) -> String {
        switch err {
        case .rejected(let reason):
            if reason == "wrong_group" {
                return L("地址可达，但对方不在同一共享组。请先配对或使用同一个群组邀请码")
            }
            if reason == "revoked" {
                return L("对方已移除本设备，需要重新配对才能加入")
            }
            return L("对方拒绝了连接（%@）", reason)
        case .timeout:
            return L("连接 %@ 超时，请确认对方已开启共享且防火墙已放行端口", endpoint.formatted)
        case .authenticationFailed:
            return L("身份校验失败，请确认两台电脑使用同一个群组邀请码")
        default:
            return L("无法连接到 %@，请确认对方在同一局域网/虚拟局域网且已开启共享", endpoint.formatted)
        }
    }

    /// 显式尝试连接一个对端（支持局域网 IP、Tailscale IP 或本地回环测试）。
    func connectToEndpoint(_ endpoint: SyncEndpoint, expectedDeviceID: String? = nil) {
        guard isRunning else { return }
        if let expectedDeviceID {
            guard expectedDeviceID != identity.deviceID,
                  sessions[expectedDeviceID] == nil,
                  !dialingDeviceIDs.contains(expectedDeviceID)
            else { return }
            dialingDeviceIDs.insert(expectedDeviceID)
        }
        let epKey = endpoint.formatted
        guard !dialingEndpoints.contains(epKey) else {
            if let expectedDeviceID { dialingDeviceIDs.remove(expectedDeviceID) }
            return
        }
        dialingEndpoints.insert(epKey)

        Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.dialingEndpoints.remove(epKey)
                    if let expectedDeviceID { self?.dialingDeviceIDs.remove(expectedDeviceID) }
                }
            }
            guard let self, self.isRunning else { return }
            do {
                let (conn, ack, peerHints) = try await self.openAuthenticatedConnection(to: endpoint, mode: .sync)
                guard self.isRunning else { conn.close(); return }
                self.attachSyncSession(
                    deviceID: ack.deviceId,
                    deviceName: ack.deviceName,
                    platform: ack.platform,
                    host: endpoint.host,
                    listenPort: ack.listenPort ?? endpoint.port,
                    initiatedByLocal: true,
                    connection: conn
                )
                self.processGossipPeers(peerHints)
            } catch {
                // 静默重试，离线设备不刷错误日志。
            }
        }
    }

    private func openAuthenticatedConnection(
        to endpoint: SyncEndpoint,
        mode: ShunSyncCrypto.HandshakeMode,
        timeoutSeconds: TimeInterval = 8
    ) async throws -> (SyncConnection, SyncHelloAckMessage, [PeerHint]) {
        let conn = SyncConnection.connect(to: endpoint, queue: netQueue)
        do {
            try await conn.startAndWaitReady(timeoutSeconds: timeoutSeconds)
            let (clientPriv, clientPub) = ShunSyncCrypto.generateEphemeralKeyPair()
            let clientNonce = ShunSyncCrypto.randomBytes(count: ShunSyncCrypto.nonceSize)
            let hello = SyncHelloMessage(
                mode: mode,
                groupId: identity.groupID,
                deviceId: identity.deviceID,
                deviceName: effectiveDeviceName,
                platform: localPlatform,
                ephPub: clientPub.base64EncodedString(),
                nonce: clientNonce.base64EncodedString(),
                listenPort: listenPort
            )
            try await conn.sendPlaintextJSON(hello)
            let ack = try await conn.receivePlaintextJSON(SyncHelloAckMessage.self, timeoutSeconds: 8)
            guard ack.accepted,
                  ack.deviceId != identity.deviceID,
                  let serverPubB64 = ack.ephPub, let serverPub = Data(base64Encoded: serverPubB64),
                  let serverNonceB64 = ack.nonce, let serverNonce = Data(base64Encoded: serverNonceB64),
                  let proofB64 = ack.proof, let serverProof = Data(base64Encoded: proofB64)
            else {
                throw SyncConnection.ConnectionError.rejected(ack.error ?? "rejected")
            }

            let shared = try ShunSyncCrypto.sharedSecret(privateKey: clientPriv, peerPublicKeyData: serverPub)
            let keys = try ShunSyncCrypto.deriveSyncSession(
                mode: mode,
                groupKey: identity.groupKey,
                clientNonce: clientNonce,
                serverNonce: serverNonce,
                clientEphPub: clientPub,
                serverEphPub: serverPub,
                clientDeviceID: identity.deviceID,
                serverDeviceID: ack.deviceId,
                sharedSecret: shared
            )
            guard ShunSyncCrypto.constantTimeEquals(serverProof, keys.serverProof) else {
                throw SyncConnection.ConnectionError.authenticationFailed
            }
            try conn.activateCipher(sendKey: keys.c2sKey, recvKey: keys.s2cKey)
            try await conn.sendEncryptedJSON(AuthFinishMessage(proof: keys.clientProof.base64EncodedString()))

            let okFrame = try await conn.receiveEncryptedFrame(timeoutSeconds: 8)
            guard case .json(let okData) = okFrame,
                  let ok = try? JSONDecoder().decode(AuthOkMessage.self, from: okData),
                  ok.type == "auth_ok"
            else {
                throw SyncConnection.ConnectionError.authenticationFailed
            }
            return (conn, ack, ok.peers)
        } catch {
            conn.close()
            throw error
        }
    }

    private func attachSyncSession(
        deviceID: String,
        deviceName: String,
        platform: SyncPlatform,
        host: String,
        listenPort: UInt16,
        initiatedByLocal: Bool,
        connection: SyncConnection
    ) {
        if let existing = sessions[deviceID] {
            let concurrentCollision = Date().timeIntervalSince(existing.connectedAt) < 5
            if concurrentCollision {
                // 双向并发连接确定性仲裁：deviceID 较小一侧发起的连接胜出，保证双端判断一致。
                let localWins = identity.deviceID < deviceID
                let keepNew = (localWins && initiatedByLocal) || (!localWins && !initiatedByLocal)
                if !keepNew {
                    connection.close()
                    return
                }
            }
            existing.cancel()
            sessions.removeValue(forKey: deviceID)
        }

        let session = PeerSession(
            deviceID: deviceID,
            deviceName: deviceName,
            platform: platform,
            host: host,
            listenPort: listenPort,
            initiatedByLocal: initiatedByLocal,
            connection: connection
        )
        sessions[deviceID] = session
        recordKnownPeer(deviceID: deviceID, deviceName: deviceName, platform: platform, host: host, port: listenPort)
        publishConnectedPeers()

        let sessionID = session.id
        session.readerTask = Task { [weak self] in
            await self?.runSessionReader(session)
            await MainActor.run { [weak self] in
                guard let self, self.sessions[deviceID]?.id == sessionID else { return }
                self.sessions.removeValue(forKey: deviceID)
                self.publishConnectedPeers()
            }
        }
        session.heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(SyncProtocol.heartbeatIntervalSeconds * 1_000_000_000))
                guard !Task.isCancelled, let self, self.sessions[deviceID]?.id == sessionID else { break }
                let ts = Int64(Date().timeIntervalSince1970 * 1000)
                do {
                    try await connection.sendEncryptedJSON(PingMessage(ts: ts))
                } catch {
                    connection.close()
                    break
                }
            }
        }

        // 新设备连上后立即广播一次已知节点名单，促使多台 Windows 与 Mac 快速全互联。
        broadcastPeerUpdate()
    }

    private func runSessionReader(_ session: PeerSession) async {
        while !Task.isCancelled {
            do {
                let frame = try await session.connection.receiveEncryptedFrame(timeoutSeconds: SyncProtocol.connectionTimeoutSeconds)
                await handleIncomingSyncFrame(frame, from: session)
            } catch {
                break
            }
        }
        session.cancel()
    }

    private func handleIncomingSyncFrame(_ frame: SyncFrame, from session: PeerSession) async {
        switch frame {
        case .json(let data):
            guard let envelope = try? JSONDecoder().decode(SyncControlEnvelope.self, from: data) else { return }
            switch envelope.type {
            case "ping":
                if let ping = try? JSONDecoder().decode(PingMessage.self, from: data) {
                    try? await session.connection.sendEncryptedJSON(PongMessage(ts: ping.ts))
                }
            case "pong":
                break
            case "peer_update":
                if let update = try? JSONDecoder().decode(PeerUpdateMessage.self, from: data) {
                    session.deviceName = update.deviceName
                    if update.listenPort > 0 { session.listenPort = update.listenPort }
                    recordKnownPeer(
                        deviceID: session.deviceID,
                        deviceName: session.deviceName,
                        platform: session.platform,
                        host: session.host,
                        port: session.listenPort
                    )
                    publishConnectedPeers()
                    processGossipPeers(update.peers)
                }
            case "clip_text":
                if let msg = try? JSONDecoder().decode(ClipTextMessage.self, from: data) {
                    handleRemoteText(msg)
                }
            case "clip_files":
                if let msg = try? JSONDecoder().decode(ClipFilesMessage.self, from: data) {
                    handleRemoteFiles(msg)
                }
            case "file_pull_req":
                // NAT / 二级路由下对方无法新开 mode="file" 连接时，允许直接在现有 sync 连接上拉取文件。
                if let req = try? JSONDecoder().decode(FilePullRequestMessage.self, from: data) {
                    let conn = session.connection
                    let registry = fileRegistry
                    Task.detached(priority: .utility) {
                        guard let transferID = SyncProtocol.parseUUID(req.transferId),
                              let url = registry.fileURL(transferID: transferID, fileIndex: req.fileIndex)
                        else {
                            try? await conn.sendEncryptedJSON(FilePullErrorMessage(
                                transferId: req.transferId,
                                fileIndex: req.fileIndex,
                                code: "not_found",
                                message: "not_found"
                            ))
                            return
                        }
                        await Self.streamFile(
                            url: url,
                            transferID: transferID,
                            fileIndex: req.fileIndex,
                            offset: max(0, req.offset),
                            over: conn
                        )
                    }
                }
            case "file_pull_done":
                if let done = try? JSONDecoder().decode(FilePullDoneMessage.self, from: data),
                   let transferID = SyncProtocol.parseUUID(done.transferId) {
                    session.inBandFiles.deliver(frame, for: transferID)
                }
            case "file_pull_err":
                if let err = try? JSONDecoder().decode(FilePullErrorMessage.self, from: data),
                   let transferID = SyncProtocol.parseUUID(err.transferId) {
                    session.inBandFiles.deliver(frame, for: transferID)
                }
            case "group_rotate":
                if let msg = try? JSONDecoder().decode(GroupRotateMessage.self, from: data),
                   let newKey = Data(base64Encoded: msg.newGroupKey),
                   newKey.count == ShunSyncCrypto.keySize,
                   !msg.revokedDeviceIds.contains(identity.deviceID) {
                    adoptGroupKey(newKey, revoked: msg.revokedDeviceIds, peerHints: [])
                }
            case "bye":
                session.cancel()
            default:
                break
            }

        case .imageClip(let meta, let png):
            handleRemoteImage(meta: meta, png: png)

        case .fileChunk(let transferID, _, _, _):
            session.inBandFiles.deliver(frame, for: transferID)
        }
    }

    private func processGossipPeers(_ peers: [PeerHint]) {
        for hint in peers where !hint.deviceId.isEmpty
            && hint.deviceId != identity.deviceID
            && !identity.revokedDeviceIDs.contains(hint.deviceId)
            && !hint.host.isEmpty && hint.port > 0 {
            recordKnownPeer(
                deviceID: hint.deviceId,
                deviceName: hint.deviceName,
                platform: hint.platform,
                host: hint.host,
                port: hint.port
            )
            if sessions[hint.deviceId] == nil {
                connectToEndpoint(SyncEndpoint(host: hint.host, port: hint.port), expectedDeviceID: hint.deviceId)
            }
        }
    }

    private func broadcastPeerUpdate() {
        let msg = PeerUpdateMessage(
            deviceName: effectiveDeviceName,
            listenPort: listenPort,
            peers: currentPeerHints()
        )
        for session in sessions.values {
            Task { try? await session.connection.sendEncryptedJSON(msg) }
        }
    }

    private func currentPeerHints() -> [PeerHint] {
        sessions.values.map {
            PeerHint(
                deviceId: $0.deviceID,
                deviceName: $0.deviceName,
                platform: $0.platform,
                host: $0.host,
                port: $0.listenPort
            )
        }
    }

    private func currentPeerHintsIncludingSelf(remoteSeenHost: String?) -> [PeerHint] {
        var hints = currentPeerHints()
        if listenPort > 0, let ip = SyncDiscovery.preferredLocalIPv4() {
            hints.append(PeerHint(
                deviceId: identity.deviceID,
                deviceName: effectiveDeviceName,
                platform: localPlatform,
                host: ip,
                port: listenPort
            ))
        }
        _ = remoteSeenHost
        return hints
    }

    private func publishConnectedPeers() {
        connectedPeers = sessions.values
            .map {
                ConnectedSyncPeer(
                    deviceID: $0.deviceID,
                    deviceName: $0.deviceName,
                    platform: $0.platform,
                    host: $0.host,
                    port: $0.listenPort,
                    connectedAt: $0.connectedAt
                )
            }
            .sorted { $0.deviceName.localizedStandardCompare($1.deviceName) == .orderedAscending }
    }

    private func recordKnownPeer(
        deviceID: String,
        deviceName: String,
        platform: SyncPlatform,
        host: String,
        port: UInt16,
        saveImmediately: Bool = true
    ) {
        let now = Date()
        if let idx = identity.knownPeers.firstIndex(where: { $0.deviceID == deviceID }) {
            let prev = identity.knownPeers[idx]
            identity.knownPeers[idx] = KnownSyncPeer(
                deviceID: deviceID,
                deviceName: deviceName,
                platform: platform,
                lastHost: host.isEmpty ? prev.lastHost : host,
                lastPort: port > 0 ? port : prev.lastPort,
                lastSeen: now
            )
        } else {
            identity.knownPeers.append(KnownSyncPeer(
                deviceID: deviceID,
                deviceName: deviceName,
                platform: platform,
                lastHost: host.isEmpty ? nil : host,
                lastPort: port,
                lastSeen: now
            ))
        }
        knownPeers = identity.knownPeers
        if saveImmediately { identityStore.save(identity) }
    }

    private func startMaintenanceLoop() {
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard let self, !Task.isCancelled, self.isRunning else { break }
                // 清理超过 45 秒没再发信标的发现记录（与 15 秒稳态信标匹配，容忍单帧 UDP 丢包）。
                let cutoff = Date().addingTimeInterval(-45)
                self.discoveredPeers.removeAll { $0.lastSeen < cutoff }
                self.connectConfiguredPeers()
            }
        }
    }

    // MARK: - 剪贴板广播（本机 → 组内设备）

    /// 广播本机新捕获的剪贴板内容（单跳广播，自动抑制远端回环）。
    func broadcastLocalCapture(_ capture: ClipboardCapture, targetDeviceID: String? = nil, explicitSend: Bool = false) {
        guard isRunning else { return }
        let isExplicit = explicitSend || (targetDeviceID != nil)
        if !isExplicit && isPaused { return }
        if !isExplicit && eventTracker.consumeLocalEchoIfMatches(fingerprint: capture.fingerprint) {
            return
        }
        let targets = targetSessions(for: targetDeviceID)
        guard !targets.isEmpty else { return }

        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        eventTracker.noteLocalCopy(timestampMs: ts, localDeviceID: identity.deviceID)
        let eventID = UUID().uuidString.lowercased()
        let originID = identity.deviceID
        let originName = effectiveDeviceName
        let originPlatform = localPlatform

        switch capture.kind {
        case .text:
            guard isExplicit || config.syncText,
                  let text = capture.text,
                  text.utf8.count <= SyncProtocol.maxTextBytes
            else { return }
            let msg = ClipTextMessage(
                eventId: eventID,
                timestampMs: ts,
                originDeviceId: originID,
                originDeviceName: originName,
                originPlatform: originPlatform,
                fingerprint: capture.fingerprint,
                text: text,
                targetDeviceId: targetDeviceID
            )
            sendToSessions(targets) { conn in
                try await conn.sendEncryptedJSON(msg)
            }

        case .image:
            guard isExplicit || config.syncImages else { return }
            let png = capture.png
            let tiff = capture.tiff
            let fallbackSize = capture.imageSize
            Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                let resolvedPNG: Data?
                if let png {
                    resolvedPNG = png
                } else if let tiff {
                    resolvedPNG = ClipboardImage.png(fromTIFF: tiff)
                } else {
                    resolvedPNG = nil
                }
                guard let data = resolvedPNG, data.count <= SyncProtocol.maxInlineImageBytes else { return }
                let size = fallbackSize ?? ClipboardImage.size(of: data) ?? .zero
                let fp = ClipboardStore.fingerprint([Data("image".utf8), data])
                let meta = ClipImageMeta(
                    eventId: eventID,
                    timestampMs: ts,
                    originDeviceId: originID,
                    originDeviceName: originName,
                    originPlatform: originPlatform,
                    fingerprint: fp,
                    width: Int(size.width),
                    height: Int(size.height),
                    byteSize: data.count,
                    targetDeviceId: targetDeviceID
                )
                await MainActor.run {
                    let liveTargets = self.targetSessions(for: targetDeviceID)
                    self.sendToSessions(liveTargets) { conn in
                        try await conn.sendEncryptedFrame(.imageClip(meta: meta, png: data))
                    }
                }
            }

        case .files:
            guard isExplicit || config.syncFiles,
                  let urls = capture.fileURLs, !urls.isEmpty
            else { return }
            let registry = fileRegistry
            Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                guard let batch = try? registry.register(urls: urls) else { return }
                let fp = Self.manifestFingerprint(batch.entries)
                let msg = ClipFilesMessage(
                    eventId: eventID,
                    timestampMs: ts,
                    originDeviceId: originID,
                    originDeviceName: originName,
                    originPlatform: originPlatform,
                    fingerprint: fp,
                    transferId: batch.transferID.uuidString.lowercased(),
                    totalBytes: batch.totalBytes,
                    entries: batch.entries,
                    targetDeviceId: targetDeviceID
                )
                await MainActor.run {
                    let liveTargets = self.targetSessions(for: targetDeviceID)
                    self.sendToSessions(liveTargets) { conn in
                        try await conn.sendEncryptedJSON(msg)
                    }
                }
            }
        }
    }

    /// 手动把历史列表中的某一条发送到指定设备（或全部在线设备）。
    func sendHistoryItem(_ item: ClipboardItem, store: ClipboardStore, targetDeviceID: String?) {
        guard isRunning else { return }
        switch item.kind {
        case .text:
            guard let text = item.text else { return }
            let capture = ClipboardCapture(kind: .text, text: text, fingerprint: item.fingerprint)
            broadcastLocalCapture(capture, targetDeviceID: targetDeviceID, explicitSend: true)
        case .image:
            guard let url = store.imageURL(for: item), let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
            let isTIFF = url.pathExtension.lowercased() == "tiff"
            let size = (item.imageWidth != nil && item.imageHeight != nil)
                ? CGSize(width: item.imageWidth!, height: item.imageHeight!)
                : nil
            let capture = ClipboardCapture(
                kind: .image,
                png: isTIFF ? nil : data,
                tiff: isTIFF ? data : nil,
                imageSize: size,
                fingerprint: item.fingerprint
            )
            broadcastLocalCapture(capture, targetDeviceID: targetDeviceID, explicitSend: true)
        case .files:
            guard let urls = item.fileURLs, !urls.isEmpty else { return }
            let capture = ClipboardCapture(kind: .files, fileURLs: urls, fingerprint: item.fingerprint)
            broadcastLocalCapture(capture, targetDeviceID: targetDeviceID, explicitSend: true)
        }
    }

    private func targetSessions(for targetDeviceID: String?) -> [PeerSession] {
        if let targetDeviceID, !targetDeviceID.isEmpty {
            return sessions[targetDeviceID].map { [$0] } ?? []
        }
        return Array(sessions.values)
    }

    private func sendToSessions(_ targets: [PeerSession], _ work: @escaping @Sendable (SyncConnection) async throws -> Void) {
        for session in targets {
            let conn = session.connection
            Task {
                do {
                    try await work(conn)
                } catch {
                    conn.close()
                }
            }
        }
    }

    // MARK: - 接收远端剪贴板内容

    private func effectiveAutoWrite(for originDeviceID: String) -> Bool {
        if let override = config.deviceAutoWriteOverrides[originDeviceID] {
            return override
        }
        return config.autoWritePasteboard
    }

    private func handleRemoteText(_ msg: ClipTextMessage) {
        guard !isPaused, config.syncText else { return }
        if let target = msg.targetDeviceId, !target.isEmpty, target != identity.deviceID { return }
        guard msg.originDeviceId != identity.deviceID,
              msg.text.utf8.count <= SyncProtocol.maxTextBytes,
              eventTracker.acceptEventID(msg.eventId)
        else { return }

        // Windows 文本统一归一化为 macOS 换行习惯（\n），同时基于归一化后的正文重新算指纹避免重复。
        let normalized = msg.text.replacingOccurrences(of: "\r\n", with: "\n")
        let fp = ClipboardStore.fingerprint([Data("text".utf8), Data(normalized.utf8)])
        let shouldWrite = effectiveAutoWrite(for: msg.originDeviceId)
            && eventTracker.shouldUpdateSystemClipboard(timestampMs: msg.timestampMs, originDeviceID: msg.originDeviceId)
        if shouldWrite {
            eventTracker.noteRemoteApplied(fingerprint: fp)
        }
        onRemoteClipboard?(.text(
            text: normalized,
            fingerprint: fp,
            originDeviceID: msg.originDeviceId,
            originDeviceName: msg.originDeviceName,
            originPlatform: msg.originPlatform,
            shouldWritePasteboard: shouldWrite
        ))
    }

    private func handleRemoteImage(meta: ClipImageMeta, png: Data) {
        guard !isPaused, config.syncImages else { return }
        if let target = meta.targetDeviceId, !target.isEmpty, target != identity.deviceID { return }
        guard meta.originDeviceId != identity.deviceID,
              !png.isEmpty, png.count <= SyncProtocol.maxInlineImageBytes,
              eventTracker.acceptEventID(meta.eventId)
        else { return }

        let size = ClipboardImage.size(of: png)
        let width = size.map { Int($0.width) } ?? meta.width
        let height = size.map { Int($0.height) } ?? meta.height
        let fp = ClipboardStore.fingerprint([Data("image".utf8), png])
        let shouldWrite = effectiveAutoWrite(for: meta.originDeviceId)
            && eventTracker.shouldUpdateSystemClipboard(timestampMs: meta.timestampMs, originDeviceID: meta.originDeviceId)
        if shouldWrite {
            eventTracker.noteRemoteApplied(fingerprint: fp)
        }
        onRemoteClipboard?(.image(
            png: png,
            width: width,
            height: height,
            fingerprint: fp,
            originDeviceID: meta.originDeviceId,
            originDeviceName: meta.originDeviceName,
            originPlatform: meta.originPlatform,
            shouldWritePasteboard: shouldWrite
        ))
    }

    private func handleRemoteFiles(_ msg: ClipFilesMessage) {
        guard !isPaused, config.syncFiles else { return }
        if let target = msg.targetDeviceId, !target.isEmpty, target != identity.deviceID { return }
        guard msg.originDeviceId != identity.deviceID,
              let transferID = SyncProtocol.parseUUID(msg.transferId),
              !msg.entries.isEmpty,
              eventTracker.acceptEventID(msg.eventId)
        else { return }

        let info = RemoteFileInfo(
            transferID: transferID,
            originDeviceID: msg.originDeviceId,
            originDeviceName: msg.originDeviceName,
            totalBytes: msg.totalBytes,
            entries: msg.entries
        )
        let fp = Self.manifestFingerprint(msg.entries)
        onRemoteClipboard?(.filesManifest(
            info: info,
            fingerprint: fp,
            originPlatform: msg.originPlatform
        ))

        // 小文件自动后台静默预取，下载完成后直接写成真实本地文件进剪贴板（100% 全应用兼容粘贴）。
        let limitBytes = Int64(max(0, config.autoDownloadFileLimitMB)) * 1024 * 1024
        if limitBytes > 0 && info.totalBytes <= limitBytes {
            let shouldWrite = effectiveAutoWrite(for: msg.originDeviceId)
                && eventTracker.shouldUpdateSystemClipboard(timestampMs: msg.timestampMs, originDeviceID: msg.originDeviceId)
            let prefetchTask = Task { [weak self] in
                guard let self else { return }
                defer { self.autoPrefetchTasks.removeValue(forKey: transferID) }
                do {
                    _ = try await self.pullRemoteFiles(info: info, autoWritePasteboard: shouldWrite)
                } catch {
                    // 静默预取失败不打扰用户，仍保留历史中的待接收条目供手动重试。
                    Log.sync.notice("自动预取文件未完成：\(error.localizedDescription, privacy: .public)")
                }
            }
            autoPrefetchTasks[transferID] = prefetchTask
        }
    }

    // MARK: - 专用文件传输通道（mode == .file，在后台队列流式读写，不阻塞主线程与文字同步）

    private nonisolated static func serveIncomingFileRequests(on conn: SyncConnection, registry: SyncFileRegistry) async {
        defer { conn.close() }
        while !Task.isCancelled {
            let frame: SyncFrame
            do {
                frame = try await conn.receiveEncryptedFrame(timeoutSeconds: 30)
            } catch {
                break
            }
            guard case .json(let data) = frame,
                  let envelope = try? JSONDecoder().decode(SyncControlEnvelope.self, from: data)
            else { break }
            if envelope.type == "bye" { break }
            guard envelope.type == "file_pull_req",
                  let req = try? JSONDecoder().decode(FilePullRequestMessage.self, from: data)
            else { continue }

            guard let transferID = SyncProtocol.parseUUID(req.transferId),
                  let url = registry.fileURL(transferID: transferID, fileIndex: req.fileIndex)
            else {
                try? await conn.sendEncryptedJSON(FilePullErrorMessage(
                    transferId: req.transferId,
                    fileIndex: req.fileIndex,
                    code: "not_found",
                    message: "not_found"
                ))
                continue
            }

            await streamFile(url: url, transferID: transferID, fileIndex: req.fileIndex, offset: max(0, req.offset), over: conn)
        }
    }

    private nonisolated static func streamFile(
        url: URL,
        transferID: UUID,
        fileIndex: Int,
        offset: Int64,
        over conn: SyncConnection
    ) async {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            guard offset <= fileSize else {
                try? await conn.sendEncryptedJSON(FilePullErrorMessage(
                    transferId: transferID.uuidString.lowercased(),
                    fileIndex: fileIndex,
                    code: "invalid_offset",
                    message: "invalid_offset"
                ))
                return
            }
            try handle.seek(toOffset: UInt64(offset))

            var hasher = SHA256()
            var cursor = offset
            var totalSent: Int64 = 0
            while !Task.isCancelled {
                let chunk = try handle.read(upToCount: SyncProtocol.fileChunkBytes) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
                try await conn.sendEncryptedFrame(.fileChunk(
                    transferID: transferID,
                    fileIndex: UInt32(fileIndex),
                    offset: UInt64(cursor),
                    data: chunk
                ))
                cursor += Int64(chunk.count)
                totalSent += Int64(chunk.count)
            }
            let sha = ShunSyncCrypto.hexLower(Data(hasher.finalize()))
            try await conn.sendEncryptedJSON(FilePullDoneMessage(
                transferId: transferID.uuidString.lowercased(),
                fileIndex: fileIndex,
                totalSent: totalSent,
                sha256: sha
            ))
        } catch {
            try? await conn.sendEncryptedJSON(FilePullErrorMessage(
                transferId: transferID.uuidString.lowercased(),
                fileIndex: fileIndex,
                code: "read_error",
                message: error.localizedDescription
            ))
        }
    }

    /// 按需拉取远端文件或文件夹（支持断点续传、SHA-256 校验与实时进度上报）。
    /// 优先使用独立 `mode="file"` 连接；若对端位于二级路由 / NAT 后无法直连，自动回落复用已建立的 `mode="sync"` 连接。
    /// 即使面板在中途关闭，下载完成后也会通过 `onRemoteClipboard(.filesReady)` 更新剪贴板历史。
    func pullRemoteFiles(
        info: RemoteFileInfo,
        autoWritePasteboard: Bool = false,
        forceInBand: Bool = false
    ) async throws -> [URL] {
        guard isRunning else { throw TransferError.syncDisabled }
        if let existing = transferTasks[info.transferID] {
            return try await existing.value
        }

        let liveSession = sessions[info.originDeviceID]
        let endpoint = endpointForDevice(info.originDeviceID)
        guard liveSession != nil || endpoint != nil else {
            throw TransferError.peerOffline
        }

        let channel: FilePullChannel
        if !forceInBand, let endpoint {
            do {
                let (conn, _, _) = try await openAuthenticatedConnection(
                    to: endpoint,
                    mode: .file,
                    timeoutSeconds: liveSession != nil ? 2.5 : 8
                )
                channel = FilePullChannel(
                    sendRequest: { req in try await conn.sendEncryptedJSON(req) },
                    nextFrame: { try await conn.receiveEncryptedFrame(timeoutSeconds: 30) },
                    finish: {
                        try? await conn.sendEncryptedJSON(ByeMessage())
                        conn.close()
                    }
                )
            } catch {
                guard let liveSession else { throw error }
                channel = Self.makeInBandChannel(session: liveSession, transferID: info.transferID)
            }
        } else if let liveSession {
            channel = Self.makeInBandChannel(session: liveSession, transferID: info.transferID)
        } else {
            throw TransferError.peerOffline
        }

        let cache = cacheManager
        let fileCount = max(info.entries.filter { !$0.isDirectory }.count, 1)
        activeTransfers[info.transferID] = SyncTransferProgress(
            transferID: info.transferID,
            originDeviceName: info.originDeviceName,
            bytesReceived: 0,
            totalBytes: max(info.totalBytes, 1),
            completedFiles: 0,
            totalFiles: fileCount
        )

        let task = Task.detached(priority: .userInitiated) { [weak self] () throws -> [URL] in
            let weakSelf = self
            do {
                let urls = try await Self.executeFilePull(
                    info: info,
                    channel: channel,
                    cacheManager: cache
                ) { progress in
                    Task { @MainActor in
                        weakSelf?.activeTransfers[info.transferID] = progress
                    }
                }
                await channel.finish()
                await MainActor.run {
                    guard let self = weakSelf else { return }
                    let pathsData = Data(urls.map(\.path).joined(separator: "\0").utf8)
                    let localFP = ClipboardStore.fingerprint([Data("files".utf8), pathsData])
                    if autoWritePasteboard {
                        self.eventTracker.noteRemoteApplied(fingerprint: localFP)
                    }
                    self.onRemoteClipboard?(.filesReady(
                        transferID: info.transferID,
                        localURLs: urls,
                        originDeviceID: info.originDeviceID,
                        shouldWritePasteboard: autoWritePasteboard
                    ))
                }
                return urls
            } catch {
                await channel.finish()
                throw error
            }
        }
        transferTasks[info.transferID] = task
        defer {
            transferTasks.removeValue(forKey: info.transferID)
            activeTransfers.removeValue(forKey: info.transferID)
            pruneCacheAsync()
        }
        return try await task.value
    }

    private static func makeInBandChannel(session: PeerSession, transferID: UUID) -> FilePullChannel {
        let conn = session.connection
        let mailbox = session.inBandFiles
        let stream = mailbox.register(transferID: transferID)
        final class IteratorBox: @unchecked Sendable {
            var iterator: AsyncThrowingStream<SyncFrame, Error>.Iterator
            init(_ stream: AsyncThrowingStream<SyncFrame, Error>) { self.iterator = stream.makeAsyncIterator() }
        }
        let box = IteratorBox(stream)
        return FilePullChannel(
            sendRequest: { req in try await conn.sendEncryptedJSON(req) },
            nextFrame: {
                guard let frame = try await box.iterator.next() else {
                    throw TransferError.peerOffline
                }
                return frame
            },
            finish: {
                mailbox.unregister(transferID: transferID)
            }
        )
    }

    func cancelTransfer(_ transferID: UUID) {
        autoPrefetchTasks[transferID]?.cancel()
        autoPrefetchTasks.removeValue(forKey: transferID)
        transferTasks[transferID]?.cancel()
        transferTasks.removeValue(forKey: transferID)
        activeTransfers.removeValue(forKey: transferID)
    }

    private func endpointForDevice(_ deviceID: String) -> SyncEndpoint? {
        if let live = sessions[deviceID], !live.host.isEmpty, live.listenPort > 0 {
            return SyncEndpoint(host: live.host, port: live.listenPort)
        }
        if let disc = discoveredPeers.first(where: { $0.deviceID == deviceID }) {
            return disc.endpoint
        }
        if let known = knownPeers.first(where: { $0.deviceID == deviceID }),
           let host = known.lastHost, !host.isEmpty, known.lastPort > 0 {
            return SyncEndpoint(host: host, port: known.lastPort)
        }
        return nil
    }

    private nonisolated static func executeFilePull(
        info: RemoteFileInfo,
        channel: FilePullChannel,
        cacheManager: SyncCacheManager,
        onProgress: @escaping @Sendable (SyncTransferProgress) -> Void
    ) async throws -> [URL] {
        let stagingRoot: URL
        do {
            stagingRoot = try cacheManager.stagingFolder(for: info.transferID)
        } catch {
            throw TransferError.ioFailed(error.localizedDescription)
        }

        let fm = FileManager.default
        let fileEntries = info.entries.filter { !$0.isDirectory }
        var totalReceived: Int64 = 0
        var completedFiles = 0

        // 先创建目录树，全部经路径安全清洗。
        for entry in info.entries where entry.isDirectory {
            guard let dirURL = SyncPathSanitizer.resolveSafeURL(relativePath: entry.relativePath, under: stagingRoot) else {
                cacheManager.removeStaging(for: info.transferID)
                throw TransferError.invalidPath
            }
            try fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }

        var lastProgressUpdate = Date.distantPast
        for entry in fileEntries {
            if Task.isCancelled { throw TransferError.cancelled }
            guard let destURL = SyncPathSanitizer.resolveSafeURL(relativePath: entry.relativePath, under: stagingRoot) else {
                cacheManager.removeStaging(for: info.transferID)
                throw TransferError.invalidPath
            }
            try fm.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            if fm.fileExists(atPath: destURL.path),
               let attrs = try? fm.attributesOfItem(atPath: destURL.path),
               let existingLen = (attrs[.size] as? NSNumber)?.int64Value,
               existingLen == entry.size {
                totalReceived += entry.size
                completedFiles += 1
                continue
            }

            let partURL = destURL.appendingPathExtension("shunsync-part")
            try await pullSingleFile(
                entry: entry,
                transferID: info.transferID,
                partURL: partURL,
                destURL: destURL,
                channel: channel,
                allowRetryFromZero: true
            ) { delta in
                totalReceived += delta
                let now = Date()
                if now.timeIntervalSince(lastProgressUpdate) >= 0.08 {
                    lastProgressUpdate = now
                    onProgress(SyncTransferProgress(
                        transferID: info.transferID,
                        originDeviceName: info.originDeviceName,
                        bytesReceived: min(totalReceived, info.totalBytes),
                        totalBytes: max(info.totalBytes, 1),
                        completedFiles: completedFiles,
                        totalFiles: max(fileEntries.count, 1)
                    ))
                }
            }
            completedFiles += 1
            onProgress(SyncTransferProgress(
                transferID: info.transferID,
                originDeviceName: info.originDeviceName,
                bytesReceived: min(totalReceived, info.totalBytes),
                totalBytes: max(info.totalBytes, 1),
                completedFiles: completedFiles,
                totalFiles: max(fileEntries.count, 1)
            ))
        }

        do {
            return try cacheManager.commitTransfer(transferID: info.transferID, entries: info.entries)
        } catch {
            throw TransferError.ioFailed(error.localizedDescription)
        }
    }

    private nonisolated static func pullSingleFile(
        entry: SharedFileEntry,
        transferID: UUID,
        partURL: URL,
        destURL: URL,
        channel: FilePullChannel,
        allowRetryFromZero: Bool,
        onBytesDelta: (Int64) -> Void
    ) async throws {
        let fm = FileManager.default
        var startOffset: Int64 = 0
        if fm.fileExists(atPath: partURL.path),
           let attrs = try? fm.attributesOfItem(atPath: partURL.path),
           let len = (attrs[.size] as? NSNumber)?.int64Value,
           len > 0 && len < entry.size {
            startOffset = len
            onBytesDelta(startOffset)
        } else {
            try? fm.removeItem(at: partURL)
            fm.createFile(atPath: partURL.path, contents: nil)
        }

        try await channel.sendRequest(FilePullRequestMessage(
            transferId: transferID.uuidString.lowercased(),
            fileIndex: entry.index,
            offset: startOffset
        ))

        let handle = try FileHandle(forWritingTo: partURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(startOffset))

        var sliceHasher = SHA256()
        var expectedOffset = UInt64(startOffset)
        var sliceBytes: Int64 = 0

        while true {
            if Task.isCancelled { throw TransferError.cancelled }
            let frame = try await channel.nextFrame()
            switch frame {
            case .fileChunk(let tid, let idx, let offset, let data):
                guard tid == transferID, Int(idx) == entry.index, offset == expectedOffset else {
                    throw TransferError.integrityMismatch
                }
                try handle.write(contentsOf: data)
                sliceHasher.update(data: data)
                expectedOffset += UInt64(data.count)
                sliceBytes += Int64(data.count)
                onBytesDelta(Int64(data.count))

            case .json(let data):
                guard let env = try? JSONDecoder().decode(SyncControlEnvelope.self, from: data) else {
                    throw TransferError.integrityMismatch
                }
                if env.type == "file_pull_done",
                   let done = try? JSONDecoder().decode(FilePullDoneMessage.self, from: data),
                   done.fileIndex == entry.index {
                    let computed = ShunSyncCrypto.hexLower(Data(sliceHasher.finalize()))
                    let finalLen = startOffset + sliceBytes
                    guard done.totalSent == sliceBytes,
                          done.sha256 == computed,
                          finalLen == entry.size
                    else {
                        try? handle.close()
                        try? fm.removeItem(at: partURL)
                        if allowRetryFromZero && startOffset > 0 {
                            onBytesDelta(-finalLen)
                            try await pullSingleFile(
                                entry: entry,
                                transferID: transferID,
                                partURL: partURL,
                                destURL: destURL,
                                channel: channel,
                                allowRetryFromZero: false,
                                onBytesDelta: onBytesDelta
                            )
                            return
                        }
                        throw TransferError.integrityMismatch
                    }
                    try handle.close()
                    if fm.fileExists(atPath: destURL.path) { try fm.removeItem(at: destURL) }
                    try fm.moveItem(at: partURL, to: destURL)
                    return
                } else if env.type == "file_pull_err",
                          let err = try? JSONDecoder().decode(FilePullErrorMessage.self, from: data) {
                    throw TransferError.remoteError(err.message)
                } else {
                    throw TransferError.integrityMismatch
                }

            case .imageClip:
                throw TransferError.integrityMismatch
            }
        }
    }

    // MARK: - 缓存与辅助

    func clearCache() {
        let mgr = cacheManager
        Task.detached(priority: .utility) { [weak self] in
            mgr.clearAll()
            let bytes = mgr.currentCacheBytes()
            let target = self
            await MainActor.run { target?.cacheBytes = bytes }
        }
    }

    func refreshCacheSizeAsync() {
        let mgr = cacheManager
        Task.detached(priority: .utility) { [weak self] in
            let bytes = mgr.currentCacheBytes()
            let target = self
            await MainActor.run { target?.cacheBytes = bytes }
        }
    }

    private func pruneCacheAsync() {
        let mgr = cacheManager
        let maxBytes = Int64(max(64, config.maxCacheMB)) * 1024 * 1024
        Task.detached(priority: .utility) { [weak self] in
            mgr.prune(maxBytes: maxBytes)
            let bytes = mgr.currentCacheBytes()
            let target = self
            await MainActor.run { target?.cacheBytes = bytes }
        }
    }

    nonisolated static func manifestFingerprint(_ entries: [SharedFileEntry]) -> String {
        let summary = entries.map { "\($0.relativePath)|\($0.isDirectory ? "d" : "f")|\($0.size)|\($0.modifiedMs)" }
            .joined(separator: "\n")
        return ClipboardStore.fingerprint([Data("remote-files".utf8), Data(summary.utf8)])
    }
}
