// SPDX-License-Identifier: MIT

import AppKit
import CryptoKit
import Foundation
import Testing
@testable import MacShun

@Suite("ShunSync 跨设备剪贴板共享")
struct ClipboardSyncTests {
    private static func fromHex(_ hex: String) -> Data {
        var out = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    private func tempDir(_ label: String = "sync") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MacShunSyncTests-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - 1. 跨语言测试向量（docs/shunsync-test-vectors.json）

    private struct VectorDoc: Decodable {
        struct Inputs: Decodable {
            let groupKeyHex: String
            let clientEphPrivHex: String
            let serverEphPrivHex: String
            let clientEphPubHex: String
            let serverEphPubHex: String
            let clientNonceHex: String
            let serverNonceHex: String
            let clientDeviceId: String
            let serverDeviceId: String
        }
        struct SyncExpected: Decodable {
            let transcriptHex: String
            let serverProofHex: String
            let clientProofHex: String
            let c2sKeyHex: String
            let s2cKeyHex: String
        }
        struct PairExpected: Decodable {
            let transcriptHex: String
            let sasCode: String
            let c2sKeyHex: String
            let s2cKeyHex: String
        }
        struct FrameExpected: Decodable {
            let seq: UInt64
            let plaintextHex: String
            let ciphertextAndTagHex: String
        }
        struct Expected: Decodable {
            let groupId: String
            let inviteCode: String
            let sharedSecretHex: String
            let sync: SyncExpected
            let pair: PairExpected
            let frames: [FrameExpected]
        }
        let version: Int
        let inputs: Inputs
        let expected: Expected
    }

    @Test func matchesPublishedTestVectorsByteForByte() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let vectorURL = root.appendingPathComponent("docs/shunsync-test-vectors.json")
        let data = try Data(contentsOf: vectorURL)
        let doc = try JSONDecoder().decode(VectorDoc.self, from: data)
        #expect(doc.version == ShunSyncCrypto.protocolVersion)

        let groupKey = Self.fromHex(doc.inputs.groupKeyHex)
        #expect(ShunSyncCrypto.groupID(for: groupKey) == doc.expected.groupId)

        let invite = ShunSyncCrypto.encodeInviteCode(groupKey: groupKey, peerHint: "192.168.1.10:37219")
        #expect(invite == doc.expected.inviteCode)
        let decodedInvite = try #require(ShunSyncCrypto.decodeInviteCode(invite))
        #expect(decodedInvite.groupKey == groupKey)
        #expect(decodedInvite.peerHint == "192.168.1.10:37219")

        let clientPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.fromHex(doc.inputs.clientEphPrivHex))
        let serverPriv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.fromHex(doc.inputs.serverEphPrivHex))
        #expect(ShunSyncCrypto.hexLower(clientPriv.publicKey.rawRepresentation) == doc.inputs.clientEphPubHex)
        #expect(ShunSyncCrypto.hexLower(serverPriv.publicKey.rawRepresentation) == doc.inputs.serverEphPubHex)

        let ss = try ShunSyncCrypto.sharedSecret(privateKey: clientPriv, peerPublicKeyData: serverPriv.publicKey.rawRepresentation)
        #expect(ShunSyncCrypto.hexLower(ss) == doc.expected.sharedSecretHex)

        let clientNonce = Self.fromHex(doc.inputs.clientNonceHex)
        let serverNonce = Self.fromHex(doc.inputs.serverNonceHex)
        let syncKeys = try ShunSyncCrypto.deriveSyncSession(
            mode: .sync,
            groupKey: groupKey,
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            clientEphPub: clientPriv.publicKey.rawRepresentation,
            serverEphPub: serverPriv.publicKey.rawRepresentation,
            clientDeviceID: doc.inputs.clientDeviceId,
            serverDeviceID: doc.inputs.serverDeviceId,
            sharedSecret: ss
        )
        #expect(ShunSyncCrypto.hexLower(syncKeys.transcript) == doc.expected.sync.transcriptHex)
        #expect(ShunSyncCrypto.hexLower(syncKeys.serverProof) == doc.expected.sync.serverProofHex)
        #expect(ShunSyncCrypto.hexLower(syncKeys.clientProof) == doc.expected.sync.clientProofHex)
        #expect(ShunSyncCrypto.hexLower(syncKeys.c2sKey) == doc.expected.sync.c2sKeyHex)
        #expect(ShunSyncCrypto.hexLower(syncKeys.s2cKey) == doc.expected.sync.s2cKeyHex)

        let pairKeys = try ShunSyncCrypto.derivePairingSession(
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            clientEphPub: clientPriv.publicKey.rawRepresentation,
            serverEphPub: serverPriv.publicKey.rawRepresentation,
            clientDeviceID: doc.inputs.clientDeviceId,
            serverDeviceID: doc.inputs.serverDeviceId,
            sharedSecret: ss
        )
        #expect(ShunSyncCrypto.hexLower(pairKeys.transcript) == doc.expected.pair.transcriptHex)
        #expect(pairKeys.sasCode == doc.expected.pair.sasCode)
        #expect(ShunSyncCrypto.hexLower(pairKeys.c2sKey) == doc.expected.pair.c2sKeyHex)
        #expect(ShunSyncCrypto.hexLower(pairKeys.s2cKey) == doc.expected.pair.s2cKeyHex)

        let sender = try SyncCipher(sendKey: syncKeys.c2sKey, recvKey: syncKeys.s2cKey)
        let receiver = try SyncCipher(sendKey: syncKeys.s2cKey, recvKey: syncKeys.c2sKey)
        for frame in doc.expected.frames {
            let plain = Self.fromHex(frame.plaintextHex)
            let sealed = try sender.seal(plain)
            #expect(ShunSyncCrypto.hexLower(sealed) == frame.ciphertextAndTagHex)
            let opened = try receiver.open(sealed)
            #expect(opened == plain)
        }
        // 重放旧密文必须因序号/AAD 不匹配被 GCM 拒绝。
        let replay = Self.fromHex(doc.expected.frames[0].ciphertextAndTagHex)
        #expect(throws: ShunSyncCrypto.CryptoError.authenticationFailed) {
            _ = try receiver.open(replay)
        }
    }

    // MARK: - 2. 编解码、路径安全、防回环与配置兼容

    @Test func frameCodecRoundTripsAllKinds() throws {
        let tid = UUID()
        let chunkData = Data((0..<128).map { UInt8($0) })
        let encodedChunk = try SyncFrame.encode(.fileChunk(transferID: tid, fileIndex: 7, offset: 262_144, data: chunkData))
        let decodedChunk = try SyncFrame.decode(encodedChunk)
        #expect(decodedChunk == .fileChunk(transferID: tid, fileIndex: 7, offset: 262_144, data: chunkData))

        let meta = ClipImageMeta(
            eventId: "evt-1",
            timestampMs: 12345,
            originDeviceId: "dev-a",
            originDeviceName: "Mac",
            originPlatform: .macos,
            fingerprint: "abc",
            width: 320,
            height: 240,
            byteSize: 4,
            targetDeviceId: nil
        )
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let encodedImg = try SyncFrame.encode(.imageClip(meta: meta, png: png))
        let decodedImg = try SyncFrame.decode(encodedImg)
        #expect(decodedImg == .imageClip(meta: meta, png: png))
    }

    @Test func pathSanitizerRejectsTraversalAndCleansIllegalNames() {
        let root = URL(fileURLWithPath: "/tmp/shunsync-root", isDirectory: true)
        #expect(SyncPathSanitizer.resolveSafeURL(relativePath: "../secret.txt", under: root) == nil)
        #expect(SyncPathSanitizer.resolveSafeURL(relativePath: "a/../../etc/passwd", under: root) == nil)
        #expect(SyncPathSanitizer.resolveSafeURL(relativePath: "/etc/passwd", under: root) == nil)
        #expect(SyncPathSanitizer.resolveSafeURL(relativePath: "C:/Windows/win.ini", under: root) == nil)
        #expect(SyncPathSanitizer.resolveSafeURL(relativePath: "sub\\..\\evil.exe", under: root) == nil)
        #expect(SyncPathSanitizer.resolveSafeURL(relativePath: "", under: root) == nil)

        let safe = SyncPathSanitizer.resolveSafeURL(relativePath: "项目资料/报价:2026?.pdf", under: root)
        #expect(safe != nil)
        #expect(safe?.path.hasPrefix(root.standardizedFileURL.path + "/") == true)
        #expect(safe?.lastPathComponent == "报价_2026_.pdf")
    }

    @Test func eventTrackerSuppressesEchoAndResolvesLWW() {
        var tracker = SyncEventTracker()
        #expect(tracker.acceptEventID("e1") == true)
        #expect(tracker.acceptEventID("e1") == false)

        let t0 = Date(timeIntervalSince1970: 1000)
        tracker.noteRemoteApplied(fingerprint: "fp-remote", now: t0)
        #expect(tracker.consumeLocalEchoIfMatches(fingerprint: "fp-remote", now: t0.addingTimeInterval(1)) == true)
        // 单次消费后，用户再次主动复制同一内容不再被误抑制。
        #expect(tracker.consumeLocalEchoIfMatches(fingerprint: "fp-remote", now: t0.addingTimeInterval(2)) == false)

        #expect(tracker.shouldUpdateSystemClipboard(timestampMs: 2000, originDeviceID: "dev-b") == true)
        #expect(tracker.shouldUpdateSystemClipboard(timestampMs: 1999, originDeviceID: "dev-z") == false)
        #expect(tracker.shouldUpdateSystemClipboard(timestampMs: 2000, originDeviceID: "dev-a") == false)
        #expect(tracker.shouldUpdateSystemClipboard(timestampMs: 2000, originDeviceID: "dev-c") == true)
    }

    @Test func legacyConfigAndClipboardHistoryDecodeCleanly() throws {
        // 旧版配置不含 sync 字段，默认关闭跨设备共享。
        let oldConfigJSON = Data(#"{"clipboard":{"enabled":true,"maxItems":150,"recordImages":false}}"#.utf8)
        let cfg = try JSONDecoder().decode(AppConfig.self, from: oldConfigJSON)
        #expect(cfg.clipboard.maxItems == 150)
        #expect(cfg.clipboard.sync.enabled == false)
        #expect(cfg.clipboard.sync.autoDownloadFileLimitMB == 0)

        // 旧版 history.json 不含 sourceDeviceName / remoteFiles 字段也能无损读取。
        let oldItemJSON = Data("""
        [{"id":"00000000-0000-0000-0000-000000000001","kind":"text","text":"旧内容","extraFiles":{},"fingerprint":"fp1","created":"2026-01-01T00:00:00Z","lastUsed":"2026-01-01T00:00:00Z","pinned":false}]
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let items = try decoder.decode([ClipboardItem].self, from: oldItemJSON)
        #expect(items.count == 1)
        #expect(items[0].sourceDeviceName == nil)
        #expect(items[0].remoteFiles == nil)
        #expect(items[0].isPendingRemoteFiles == false)
    }

    @Test func cacheManagerPrunesByQuotaAndAge() throws {
        let root = tempDir("cache")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SyncCacheManager(directory: root)
        try cache.ensureRootDirectory()

        let oldDir = root.appendingPathComponent("old-transfer", isDirectory: true)
        let midDir = root.appendingPathComponent("mid-transfer", isDirectory: true)
        let newDir = root.appendingPathComponent("new-transfer", isDirectory: true)
        for dir in [oldDir, midDir, newDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 1024).write(to: dir.appendingPathComponent("a.bin"))
        }
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-10 * 86400)], ofItemAtPath: oldDir.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-2 * 86400)], ofItemAtPath: midDir.path)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: newDir.path)

        cache.prune(maxBytes: 1500, maxAgeDays: 7, now: now)
        #expect(!FileManager.default.fileExists(atPath: oldDir.path))
        #expect(!FileManager.default.fileExists(atPath: midDir.path))
        #expect(FileManager.default.fileExists(atPath: newDir.path))
    }

    // MARK: - 3. 真实三机（1 Mac + 2 Windows）TCP 回环端到端集成测试

    @MainActor
    private func makeNode(name: String, platform: SyncPlatform, root: URL) -> ClipboardSyncService {
        let idStore = SyncIdentityStore(directory: root.appendingPathComponent("\(name)-id", isDirectory: true))
        let cache = SyncCacheManager(directory: root.appendingPathComponent("\(name)-cache", isDirectory: true))
        return ClipboardSyncService(
            identityStore: idStore,
            cacheManager: cache,
            enableDiscovery: false,
            localPlatform: platform
        )
    }

    @MainActor
    private func waitUntil(timeoutSeconds: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return condition()
    }

    @Test @MainActor func threeDeviceMeshPairingTextImageFileFolderAndKeyRotation() async throws {
        let root = tempDir("mesh")
        defer { try? FileManager.default.removeItem(at: root) }

        let mac = makeNode(name: "MacBook", platform: .macos, root: root)
        let win1 = makeNode(name: "WinOffice", platform: .windows, root: root)
        let win2 = makeNode(name: "WinHome", platform: .windows, root: root)
        defer {
            mac.stop()
            win1.stop()
            win2.stop()
        }

        func makeConfig(name: String, autoLimitMB: Int = 20) -> ClipboardSyncConfig {
            var cfg = ClipboardSyncConfig()
            cfg.enabled = true
            cfg.deviceName = name
            cfg.listenPort = 0
            cfg.autoDownloadFileLimitMB = autoLimitMB
            return cfg
        }

        mac.apply(config: makeConfig(name: "MacBook"))
        win1.apply(config: makeConfig(name: "WinOffice"))
        win2.apply(config: makeConfig(name: "WinHome", autoLimitMB: 0))

        #expect(await waitUntil { mac.listenPort > 0 && win1.listenPort > 0 && win2.listenPort > 0 })

        // 1) Win-1 通过 6 位确认码与 Mac 配对（检验双端 SAS 码完全一致）。
        mac.openPairingWindow(duration: 30)
        let macEndpoint = SyncEndpoint(host: "127.0.0.1", port: mac.listenPort)
        let pairTask = Task {
            try await win1.initiatePairing(with: macEndpoint)
        }
        #expect(await waitUntil { mac.activePairing != nil && win1.activePairing != nil })
        #expect(mac.activePairing?.sasCode == win1.activePairing?.sasCode)
        #expect(mac.activePairing?.sasCode.count == 6)

        mac.approveActivePairing()
        try await pairTask.value
        #expect(win1.groupID == mac.groupID)
        #expect(await waitUntil {
            mac.connectedPeers.contains(where: { $0.deviceID == win1.localDeviceID })
                && win1.connectedPeers.contains(where: { $0.deviceID == mac.localDeviceID })
        })

        // 2) Win-2 通过群组邀请码加入，并与 Mac + Win-1 形成三机 Mesh。
        let invite = ShunSyncCrypto.encodeInviteCode(
            groupKey: mac.identityStore.loadOrCreate().groupKey,
            peerHint: "127.0.0.1:\(mac.listenPort)"
        )
        #expect(win2.joinWithInviteCode(invite) == "127.0.0.1:\(mac.listenPort)")
        win2.connectToEndpoint(SyncEndpoint(host: "127.0.0.1", port: win1.listenPort))
        #expect(await waitUntil {
            mac.connectedPeers.count == 2 && win1.connectedPeers.count == 2 && win2.connectedPeers.count == 2
        })

        // 3) 广播文本 + 定向发送 + 换行归一化 + 防回环。
        var win1Texts: [String] = []
        var win2Texts: [String] = []
        var macTexts: [String] = []
        var win1Images: [Data] = []
        var win1AutoFiles: [[URL]] = []
        var win2Manifests: [RemoteFileInfo] = []

        mac.onRemoteClipboard = { event in
            if case .text(let text, _, _, _, _, _) = event { macTexts.append(text) }
        }
        win1.onRemoteClipboard = { event in
            switch event {
            case .text(let text, _, _, _, _, _): win1Texts.append(text)
            case .image(let png, _, _, _, _, _, _, _): win1Images.append(png)
            case .filesReady(_, let urls, _, _): win1AutoFiles.append(urls)
            default: break
            }
        }
        win2.onRemoteClipboard = { event in
            switch event {
            case .text(let text, _, _, _, _, _): win2Texts.append(text)
            case .filesManifest(let info, _, _): win2Manifests.append(info)
            default: break
            }
        }

        let helloText = "第一行\r\n第二行"
        mac.broadcastLocalCapture(ClipboardCapture(
            kind: .text,
            text: helloText,
            fingerprint: ClipboardStore.fingerprint([Data("text".utf8), Data(helloText.utf8)])
        ))
        #expect(await waitUntil { win1Texts == ["第一行\n第二行"] && win2Texts == ["第一行\n第二行"] })
        #expect(macTexts.isEmpty)

        // Win-1 定向发给 Win-2，Mac 不应收到。
        let secretNote = "只发给家里电脑"
        win1.broadcastLocalCapture(
            ClipboardCapture(kind: .text, text: secretNote, fingerprint: ClipboardStore.fingerprint([Data("text".utf8), Data(secretNote.utf8)])),
            targetDeviceID: win2.localDeviceID
        )
        #expect(await waitUntil { win2Texts.contains(secretNote) })
        try? await Task.sleep(nanoseconds: 120_000_000)
        #expect(macTexts.isEmpty)

        // 4) 图片 PNG 实时同步。
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 6,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        let pngData = try #require(rep.representation(using: .png, properties: [:]))
        mac.broadcastLocalCapture(ClipboardCapture(
            kind: .image,
            png: pngData,
            imageSize: CGSize(width: 8, height: 6),
            fingerprint: ClipboardStore.fingerprint([Data("image".utf8), pngData])
        ))
        #expect(await waitUntil { win1Images == [pngData] })

        // 5) 文件夹同步：Win-1（阈值 20MB）自动静默预取；Win-2（阈值 0）按需拉取并验证断点续传。
        let srcFolder = root.appendingPathComponent("测试资料", isDirectory: true)
        let subFolder = srcFolder.appendingPathComponent("子目录", isDirectory: true)
        try FileManager.default.createDirectory(at: subFolder, withIntermediateDirectories: true)
        let smallPayload = Data("Hello from Mac顺!".utf8)
        let bigPayload = Data((0..<(600 * 1024)).map { UInt8($0 % 251) }) // > 2 个 256KB 分片
        try smallPayload.write(to: srcFolder.appendingPathComponent("说明.txt"))
        try Data().write(to: srcFolder.appendingPathComponent("空文件.txt"))
        try bigPayload.write(to: subFolder.appendingPathComponent("数据.bin"))

        mac.broadcastLocalCapture(ClipboardCapture(
            kind: .files,
            fileURLs: [srcFolder],
            fingerprint: ClipboardStore.fingerprint([Data("files".utf8), Data(srcFolder.path.utf8)])
        ))

        // Win-1 自动预取落盘（含 0 字节空文件与跨分片大文件）。
        #expect(await waitUntil(timeoutSeconds: 6) { !win1AutoFiles.isEmpty })
        let pulledWin1Folder = try #require(win1AutoFiles.first?.first)
        #expect(try Data(contentsOf: pulledWin1Folder.appendingPathComponent("说明.txt")) == smallPayload)
        #expect(try Data(contentsOf: pulledWin1Folder.appendingPathComponent("空文件.txt")).isEmpty)
        #expect(try Data(contentsOf: pulledWin1Folder.appendingPathComponent("子目录/数据.bin")) == bigPayload)

        // Win-2 收到清单后，预置一段 .shunsync-part 模拟断点续传，再执行按需拉取。
        #expect(await waitUntil { !win2Manifests.isEmpty })
        let manifest = try #require(win2Manifests.first)
        let stagingDir = try win2.cacheManager.stagingFolder(for: manifest.transferID)
        let resumeSub = stagingDir.appendingPathComponent("测试资料/子目录", isDirectory: true)
        try FileManager.default.createDirectory(at: resumeSub, withIntermediateDirectories: true)
        let partialPrefix = bigPayload.prefix(100_000)
        try partialPrefix.write(to: resumeSub.appendingPathComponent("数据.bin.shunsync-part"))

        let pulledWin2URLs = try await win2.pullRemoteFiles(info: manifest)
        let pulledWin2Folder = try #require(pulledWin2URLs.first)
        #expect(try Data(contentsOf: pulledWin2Folder.appendingPathComponent("说明.txt")) == smallPayload)
        #expect(try Data(contentsOf: pulledWin2Folder.appendingPathComponent("空文件.txt")).isEmpty)
        #expect(try Data(contentsOf: pulledWin2Folder.appendingPathComponent("子目录/数据.bin")) == bigPayload)

        // 6) 移除 Win-2 并轮换群组密钥：Mac 与 Win-1 自动平滑升级并保持在线，Win-2 重连返回明确诊断提示。
        let oldGroupID = mac.groupID
        mac.removeAndRotatePeer(deviceID: win2.localDeviceID)
        #expect(await waitUntil(timeoutSeconds: 6) {
            mac.groupID != oldGroupID
                && win1.groupID == mac.groupID
                && mac.connectedPeers.map(\.deviceID) == [win1.localDeviceID]
                && win1.connectedPeers.map(\.deviceID) == [mac.localDeviceID]
        })
        #expect(win2.groupID == oldGroupID)
        let diag = await win2.connectManuallyWithDiagnosis(SyncEndpoint(host: "127.0.0.1", port: mac.listenPort))
        #expect(diag.contains("共享组") || diag.lowercased().contains("group"))
        #expect(!mac.connectedPeers.contains(where: { $0.deviceID == win2.localDeviceID }))
    }

    @Test @MainActor func inBandFileTransferWorksAcrossOneWayNAT() async throws {
        let root = tempDir("inband-nat")
        defer { try? FileManager.default.removeItem(at: root) }

        let macBehindNAT = makeNode(name: "MacWiFi192", platform: .macos, root: root)
        let winWired = makeNode(name: "WinWired172", platform: .windows, root: root)
        defer {
            macBehindNAT.stop()
            winWired.stop()
        }

        // 同组密钥，仅允许 Mac 主动单向连向 Windows（模拟 192.168.50.x -> 172.16.30.81 二级路由 NAT）。
        let invite = ShunSyncCrypto.encodeInviteCode(groupKey: winWired.identityStore.loadOrCreate().groupKey)
        _ = macBehindNAT.joinWithInviteCode(invite)

        var macCfg = ClipboardSyncConfig()
        macCfg.enabled = true
        macCfg.deviceName = "MacWiFi192"
        macCfg.listenPort = 0
        macCfg.autoDownloadFileLimitMB = 0
        var winCfg = ClipboardSyncConfig()
        winCfg.enabled = true
        winCfg.deviceName = "WinWired172"
        winCfg.listenPort = 0
        winCfg.autoDownloadFileLimitMB = 0

        macBehindNAT.apply(config: macCfg)
        winWired.apply(config: winCfg)
        #expect(await waitUntil { macBehindNAT.listenPort > 0 && winWired.listenPort > 0 })

        macBehindNAT.connectToEndpoint(SyncEndpoint(host: "127.0.0.1", port: winWired.listenPort))
        #expect(await waitUntil {
            macBehindNAT.connectedPeers.count == 1 && winWired.connectedPeers.count == 1
        })

        var winReceivedManifest: RemoteFileInfo?
        winWired.onRemoteClipboard = { event in
            if case .filesManifest(let info, _, _) = event {
                winReceivedManifest = info
            }
        }

        let srcFile = root.appendingPathComponent("跨网段传输.bin")
        let payload = Data((0..<(400 * 1024)).map { UInt8(($0 * 7) % 253) })
        try payload.write(to: srcFile)

        macBehindNAT.broadcastLocalCapture(ClipboardCapture(
            kind: .files,
            fileURLs: [srcFile],
            fingerprint: ClipboardStore.fingerprint([Data("files".utf8), Data(srcFile.path.utf8)])
        ))

        #expect(await waitUntil { winReceivedManifest != nil })
        let manifest = try #require(winReceivedManifest)
        // 强制走单连接复用（in-band）拉取，验证 NAT 阻断新 TCP 连接时依然能完整传文件并校验 SHA-256。
        let pulled = try await winWired.pullRemoteFiles(info: manifest, forceInBand: true)
        let downloaded = try #require(pulled.first)
        #expect(try Data(contentsOf: downloaded) == payload)
    }

    @Test @MainActor func connectOrPairAutomaticallyPairsAndCopyToDownloadsAvoidsOverwrite() async throws {
        let root = tempDir("smart-pair")
        defer { try? FileManager.default.removeItem(at: root) }

        let mac = makeNode(name: "Mac", platform: .macos, root: root)
        let win = makeNode(name: "Win", platform: .windows, root: root)
        defer {
            mac.stop()
            win.stop()
        }

        var macCfg = ClipboardSyncConfig()
        macCfg.enabled = true
        macCfg.deviceName = "Mac"
        macCfg.listenPort = 0
        var winCfg = ClipboardSyncConfig()
        winCfg.enabled = true
        winCfg.deviceName = "Win"
        winCfg.listenPort = 0

        // 默认 allowPairingRequests = true，无需额外先开“配对窗口”。
        mac.apply(config: macCfg)
        win.apply(config: winCfg)
        #expect(await waitUntil { mac.listenPort > 0 && win.listenPort > 0 })

        let connectTask = Task {
            await mac.connectOrPair(endpoint: SyncEndpoint(host: "127.0.0.1", port: win.listenPort))
        }
        #expect(await waitUntil { mac.activePairing != nil && win.activePairing != nil })
        #expect(mac.activePairing?.sasCode == win.activePairing?.sasCode)
        win.approveActivePairing()
        _ = await connectTask.value

        #expect(mac.groupID == win.groupID)
        #expect(await waitUntil { mac.connectedPeers.count == 1 && win.connectedPeers.count == 1 })

        // 验证“存到下载”重名时自动编号，不覆盖原有文件。
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        let src = root.appendingPathComponent("report.pdf")
        try Data("v1".utf8).write(to: src)
        let first = try SyncCacheManager.copyToDownloads([src], destinationFolder: downloads)
        #expect(first.first?.lastPathComponent == "report.pdf")
        let second = try SyncCacheManager.copyToDownloads([src], destinationFolder: downloads)
        #expect(second.first?.lastPathComponent == "report (2).pdf")
    }

    @Test func parsesStandardAndQtBracedUUIDs() {
        let id = UUID()
        #expect(SyncProtocol.parseUUID(id.uuidString) == id)
        #expect(SyncProtocol.parseUUID("{\(id.uuidString.lowercased())}") == id)
        #expect(SyncProtocol.parseUUID("  {\(id.uuidString)}  ") == id)
        #expect(SyncProtocol.parseUUID("not-a-uuid") == nil)
    }
}
