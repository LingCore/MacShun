// SPDX-License-Identifier: MIT

import Foundation

/// ShunSync v1 跨平台剪贴板共享协议定义。
/// 完整线缆格式见 docs/shunsync-protocol.md。
enum SyncProtocol {
    static let version = 1
    static let bonjourServiceType = "_shunsync._tcp"
    static let defaultTCPPort: UInt16 = 37219
    static let defaultUDPDiscoveryPort: UInt16 = 37220
    /// 单帧最大长度（20 MB：容纳 15 MB PNG 原图与协议头）。
    static let maxFrameBytes = 20 * 1024 * 1024
    static let maxTextBytes = 2 * 1024 * 1024
    static let maxInlineImageBytes = 15 * 1024 * 1024
    static let fileChunkBytes = 256 * 1024
    static let heartbeatIntervalSeconds: TimeInterval = 20
    static let connectionTimeoutSeconds: TimeInterval = 60
    static let pairingTimeoutSeconds: TimeInterval = 60
    static let pairingWindowSeconds: TimeInterval = 120

    /// 兼容标准 UUID 与 Qt `QUuid::toString()` 默认带大括号 `{...}` 的格式。
    static func parseUUID(_ raw: String) -> UUID? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") && trimmed.count >= 2 {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        return UUID(uuidString: trimmed)
    }
}

enum SyncPlatform: String, Codable, Equatable, Hashable, Sendable {
    case macos
    case windows
    case other

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = SyncPlatform(rawValue: raw.lowercased()) ?? .other
    }

    var displaySymbol: String {
        switch self {
        case .macos: "laptopcomputer"
        case .windows: "pc"
        case .other: "desktopcomputer"
        }
    }
}

struct PeerHint: Codable, Equatable, Hashable, Sendable {
    var deviceId: String
    var deviceName: String
    var platform: SyncPlatform
    var host: String
    var port: UInt16
}

struct SharedFileEntry: Codable, Equatable, Hashable, Sendable {
    var index: Int
    /// 始终使用 POSIX `/` 分隔的相对路径，不含前导 `/` 或 `..`。
    var relativePath: String
    var isDirectory: Bool
    var size: Int64
    var modifiedMs: Int64
}

/// 尚未落盘的远端文件清单，保存在 ClipboardItem 上供历史列表展示与按需拉取。
struct RemoteFileInfo: Codable, Equatable, Hashable, Sendable {
    var transferID: UUID
    var originDeviceID: String
    var originDeviceName: String
    var totalBytes: Int64
    var entries: [SharedFileEntry]

    /// 供界面展示与搜索的顶层名称（去重保序）。
    var topLevelNames: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in entries {
            let head = entry.relativePath.split(separator: "/", maxSplits: 1).first.map(String.init) ?? entry.relativePath
            if !head.isEmpty && seen.insert(head).inserted {
                result.append(head)
            }
        }
        return result
    }
}

// MARK: - 握手消息（明文 JSON，位于加密切换前）

struct SyncHelloMessage: Codable, Equatable, Sendable {
    var type = "hello"
    var proto: Int = SyncProtocol.version
    var mode: ShunSyncCrypto.HandshakeMode
    var groupId: String?
    var deviceId: String
    var deviceName: String
    var platform: SyncPlatform
    var ephPub: String
    var nonce: String
    var listenPort: UInt16
}

struct SyncHelloAckMessage: Codable, Equatable, Sendable {
    var type = "hello_ack"
    var proto: Int = SyncProtocol.version
    var accepted: Bool
    var error: String?
    var deviceId: String
    var deviceName: String
    var platform: SyncPlatform
    var ephPub: String?
    var nonce: String?
    var proof: String?
    var listenPort: UInt16?
}

// MARK: - 加密控制消息（frameKind = 0x01）

struct SyncControlEnvelope: Codable, Sendable {
    var type: String
}

struct AuthFinishMessage: Codable, Equatable, Sendable {
    var type = "auth_finish"
    var proof: String
}

struct AuthOkMessage: Codable, Equatable, Sendable {
    var type = "auth_ok"
    var peers: [PeerHint]
}

struct PairGrantMessage: Codable, Equatable, Sendable {
    var type = "pair_grant"
    var groupKey: String
    var peers: [PeerHint]
}

struct PairRejectMessage: Codable, Equatable, Sendable {
    var type = "pair_reject"
    var reason: String
}

struct PairCancelMessage: Codable, Equatable, Sendable {
    var type = "pair_cancel"
}

struct PingMessage: Codable, Equatable, Sendable {
    var type = "ping"
    var ts: Int64
}

struct PongMessage: Codable, Equatable, Sendable {
    var type = "pong"
    var ts: Int64
}

struct PeerUpdateMessage: Codable, Equatable, Sendable {
    var type = "peer_update"
    var deviceName: String
    var listenPort: UInt16
    var peers: [PeerHint]
}

struct ClipTextMessage: Codable, Equatable, Sendable {
    var type = "clip_text"
    var eventId: String
    var timestampMs: Int64
    var originDeviceId: String
    var originDeviceName: String
    var originPlatform: SyncPlatform
    var fingerprint: String
    var text: String
    var targetDeviceId: String?
}

struct ClipImageMeta: Codable, Equatable, Sendable {
    var eventId: String
    var timestampMs: Int64
    var originDeviceId: String
    var originDeviceName: String
    var originPlatform: SyncPlatform
    var fingerprint: String
    var width: Int
    var height: Int
    var byteSize: Int
    var targetDeviceId: String?
}

struct ClipFilesMessage: Codable, Equatable, Sendable {
    var type = "clip_files"
    var eventId: String
    var timestampMs: Int64
    var originDeviceId: String
    var originDeviceName: String
    var originPlatform: SyncPlatform
    var fingerprint: String
    var transferId: String
    var totalBytes: Int64
    var entries: [SharedFileEntry]
    var targetDeviceId: String?
}

struct FilePullRequestMessage: Codable, Equatable, Sendable {
    var type = "file_pull_req"
    var transferId: String
    var fileIndex: Int
    var offset: Int64
}

struct FilePullDoneMessage: Codable, Equatable, Sendable {
    var type = "file_pull_done"
    var transferId: String
    var fileIndex: Int
    var totalSent: Int64
    var sha256: String
}

struct FilePullErrorMessage: Codable, Equatable, Sendable {
    var type = "file_pull_err"
    var transferId: String
    var fileIndex: Int
    var code: String
    var message: String
}

struct GroupRotateMessage: Codable, Equatable, Sendable {
    var type = "group_rotate"
    var newGroupKey: String
    var revokedDeviceIds: [String]
}

struct ByeMessage: Codable, Equatable, Sendable {
    var type = "bye"
}

// MARK: - 局域网 UDP 发现信标

struct DiscoveryBeacon: Codable, Equatable, Sendable {
    var proto: Int = SyncProtocol.version
    var deviceId: String
    var deviceName: String
    var platform: SyncPlatform
    var groupId: String
    var tcpPort: UInt16
    var pairingOpen: Bool
}

// MARK: - 二进制帧编解码

enum SyncFrameKind: UInt8 {
    case json = 0x01
    case fileChunk = 0x02
    case imageClip = 0x03
}

enum SyncFrame: Equatable, Sendable {
    case json(Data)
    case fileChunk(transferID: UUID, fileIndex: UInt32, offset: UInt64, data: Data)
    case imageClip(meta: ClipImageMeta, png: Data)

    enum CodecError: Error, Equatable {
        case emptyFrame
        case unknownKind(UInt8)
        case truncatedPayload
        case invalidMetadata
        case frameTooLarge
    }

    static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let json = try JSONEncoder().encode(value)
        return try encode(.json(json))
    }

    static func encode(_ frame: SyncFrame) throws -> Data {
        switch frame {
        case .json(let data):
            guard data.count + 1 <= SyncProtocol.maxFrameBytes else { throw CodecError.frameTooLarge }
            var out = Data(capacity: 1 + data.count)
            out.append(SyncFrameKind.json.rawValue)
            out.append(data)
            return out

        case .fileChunk(let transferID, let fileIndex, let offset, let data):
            let headerBytes = 1 + 16 + 4 + 8
            guard headerBytes + data.count <= SyncProtocol.maxFrameBytes else { throw CodecError.frameTooLarge }
            var out = Data(capacity: headerBytes + data.count)
            out.append(SyncFrameKind.fileChunk.rawValue)
            var uuidBytes = transferID.uuid
            withUnsafeBytes(of: &uuidBytes) { out.append(contentsOf: $0) }
            out.append(SyncCipher.bigEndianBytes(fileIndex))
            out.append(SyncCipher.bigEndianBytes(offset))
            out.append(data)
            return out

        case .imageClip(let meta, let png):
            let metaData = try JSONEncoder().encode(meta)
            let total = 1 + 4 + metaData.count + png.count
            guard total <= SyncProtocol.maxFrameBytes else { throw CodecError.frameTooLarge }
            var out = Data(capacity: total)
            out.append(SyncFrameKind.imageClip.rawValue)
            out.append(SyncCipher.bigEndianBytes(UInt32(metaData.count)))
            out.append(metaData)
            out.append(png)
            return out
        }
    }

    static func decode(_ data: Data) throws -> SyncFrame {
        guard let first = data.first else { throw CodecError.emptyFrame }
        guard let kind = SyncFrameKind(rawValue: first) else { throw CodecError.unknownKind(first) }
        let body = data.dropFirst()
        switch kind {
        case .json:
            return .json(Data(body))

        case .fileChunk:
            guard body.count >= 28 else { throw CodecError.truncatedPayload }
            let start = body.startIndex
            let uuidSlice = body[start..<(start + 16)]
            let uuidBytes = Array(uuidSlice)
            let uuid = UUID(uuid: (
                uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
                uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
                uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
                uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
            ))
            let fileIndex = readBigEndianUInt32(body, offset: 16)
            let fileOffset = readBigEndianUInt64(body, offset: 20)
            let payload = Data(body[(start + 28)...])
            return .fileChunk(transferID: uuid, fileIndex: fileIndex, offset: fileOffset, data: payload)

        case .imageClip:
            guard body.count >= 4 else { throw CodecError.truncatedPayload }
            let metaLen = Int(readBigEndianUInt32(body, offset: 0))
            guard metaLen > 0, body.count >= 4 + metaLen else { throw CodecError.truncatedPayload }
            let start = body.startIndex
            let metaSlice = body[(start + 4)..<(start + 4 + metaLen)]
            let meta: ClipImageMeta
            do {
                meta = try JSONDecoder().decode(ClipImageMeta.self, from: Data(metaSlice))
            } catch {
                throw CodecError.invalidMetadata
            }
            let png = Data(body[(start + 4 + metaLen)...])
            return .imageClip(meta: meta, png: png)
        }
    }

    static func readBigEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
        let i = data.startIndex + offset
        return (UInt32(data[i]) << 24)
            | (UInt32(data[i + 1]) << 16)
            | (UInt32(data[i + 2]) << 8)
            | UInt32(data[i + 3])
    }

    static func readBigEndianUInt64(_ data: Data, offset: Int) -> UInt64 {
        let hi = UInt64(readBigEndianUInt32(data, offset: offset))
        let lo = UInt64(readBigEndianUInt32(data, offset: offset + 4))
        return (hi << 32) | lo
    }

    static func packWirePacket(_ payload: Data) throws -> Data {
        guard payload.count <= SyncProtocol.maxFrameBytes + ShunSyncCrypto.gcmTagSize else {
            throw CodecError.frameTooLarge
        }
        var packet = Data(capacity: 4 + payload.count)
        packet.append(SyncCipher.bigEndianBytes(UInt32(payload.count)))
        packet.append(payload)
        return packet
    }
}

// MARK: - 端点解析与多机防回环

struct SyncEndpoint: Equatable, Hashable, Sendable {
    let host: String
    let port: UInt16

    var formatted: String {
        if host.contains(":") && !host.hasPrefix("[") {
            return "[\(host)]:\(port)"
        }
        return "\(host):\(port)"
    }

    /// 解析 `192.168.1.10:37219`、`100.64.0.2`、`[fe80::1]:37219` 或 `win-pc.local:37219`。
    static func parse(_ raw: String, defaultPort: UInt16 = SyncProtocol.defaultTCPPort) -> SyncEndpoint? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            guard !host.isEmpty else { return nil }
            let rest = trimmed[trimmed.index(after: close)...]
            if rest.isEmpty { return SyncEndpoint(host: host, port: defaultPort) }
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()), port > 0 else { return nil }
            return SyncEndpoint(host: host, port: port)
        }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 1 {
            return SyncEndpoint(host: trimmed, port: defaultPort)
        }
        if parts.count == 2 {
            let host = String(parts[0])
            guard !host.isEmpty, let port = UInt16(parts[1]), port > 0 else { return nil }
            return SyncEndpoint(host: host, port: port)
        }
        // 裸 IPv6 地址（无端口）
        return SyncEndpoint(host: trimmed, port: defaultPort)
    }
}

/// 多机同步防回环与并发排序（LWW）追踪器。
struct SyncEventTracker {
    private static let maxSeenEvents = 512
    private static let echoWindowSeconds: TimeInterval = 5

    private var seenOrder: [String] = []
    private var seenSet: Set<String> = []
    private var suppressedFingerprints: [String: Date] = [:]
    private var latestClock: (timestampMs: Int64, deviceID: String)?

    /// 若该事件 ID 未处理过则记录并返回 true；重复则返回 false。
    mutating func acceptEventID(_ id: String) -> Bool {
        guard !id.isEmpty, seenSet.insert(id).inserted else { return false }
        seenOrder.append(id)
        if seenOrder.count > Self.maxSeenEvents {
            let evicted = seenOrder.removeFirst()
            seenSet.remove(evicted)
        }
        return true
    }

    /// 收到远端条目并准备写入本机剪贴板时登记，避免监听线程将其当成新的本地复制广播出去。
    mutating func noteRemoteApplied(fingerprint: String, now: Date = Date()) {
        pruneSuppressed(now: now)
        suppressedFingerprints[fingerprint] = now.addingTimeInterval(Self.echoWindowSeconds)
    }

    /// 本地剪贴板出现变化时检查是否刚由远端同步写入；命中则消费并抑制回环。
    mutating func consumeLocalEchoIfMatches(fingerprint: String, now: Date = Date()) -> Bool {
        pruneSuppressed(now: now)
        guard let expiry = suppressedFingerprints[fingerprint], expiry >= now else { return false }
        suppressedFingerprints.removeValue(forKey: fingerprint)
        return true
    }

    /// 决定一条事件是否应覆盖本机当前系统剪贴板（基于 `(timestampMs, deviceID)` 决胜）。
    mutating func shouldUpdateSystemClipboard(timestampMs: Int64, originDeviceID: String) -> Bool {
        guard let current = latestClock else {
            latestClock = (timestampMs, originDeviceID)
            return true
        }
        if timestampMs > current.timestampMs
            || (timestampMs == current.timestampMs && originDeviceID >= current.deviceID) {
            latestClock = (timestampMs, originDeviceID)
            return true
        }
        return false
    }

    mutating func noteLocalCopy(timestampMs: Int64, localDeviceID: String) {
        if let current = latestClock, current.timestampMs > timestampMs {
            latestClock = (current.timestampMs + 1, localDeviceID)
        } else {
            latestClock = (timestampMs, localDeviceID)
        }
    }

    private mutating func pruneSuppressed(now: Date) {
        suppressedFingerprints = suppressedFingerprints.filter { $0.value >= now }
    }
}
