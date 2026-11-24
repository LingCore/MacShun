// SPDX-License-Identifier: MIT

import Foundation

/// 已知的同组设备记录（用于展示离线成员、记住上次局域网 IP 加速重连）。
struct KnownSyncPeer: Codable, Equatable, Identifiable, Sendable {
    var deviceID: String
    var deviceName: String
    var platform: SyncPlatform
    var lastHost: String?
    var lastPort: UInt16
    var lastSeen: Date

    var id: String { deviceID }
}

/// 本地同步身份与群组根密钥，独立存于 0o600 权限文件中，不混入普通 UserDefaults。
struct SyncIdentity: Codable, Equatable, Sendable {
    var deviceID: String
    var groupKey: Data
    var revokedDeviceIDs: [String]
    var knownPeers: [KnownSyncPeer]

    var groupID: String { ShunSyncCrypto.groupID(for: groupKey) }
}

final class SyncIdentityStore {
    let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("identity.json") }

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = support.appendingPathComponent("MacShun/Sync", isDirectory: true)
        }
    }

    func loadOrCreate() -> SyncIdentity {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(SyncIdentity.self, from: data),
           !decoded.deviceID.isEmpty,
           decoded.groupKey.count == ShunSyncCrypto.keySize {
            return decoded
        }
        let fresh = SyncIdentity(
            deviceID: UUID().uuidString.lowercased(),
            groupKey: ShunSyncCrypto.generateGroupKey(),
            revokedDeviceIDs: [],
            knownPeers: []
        )
        save(fresh)
        return fresh
    }

    func save(_ identity: SyncIdentity) {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(identity)
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            Log.sync.error("保存剪贴板共享身份失败：\(error.localizedDescription, privacy: .public)")
        }
    }
}
