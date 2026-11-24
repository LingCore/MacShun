// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// ShunSync v1 加密与握手派生。仅依赖 Apple 原生 CryptoKit，零第三方依赖。
/// 算法与测试向量见 docs/shunsync-protocol.md，供 Mac顺（Swift）与 Win顺（C++/Qt6）字节级对齐。
enum ShunSyncCrypto {
    static let protocolVersion = 1
    static let keySize = 32
    static let nonceSize = 16
    static let gcmNonceSize = 12
    static let gcmTagSize = 16

    enum Role: Sendable {
        case client
        case server
    }

    enum HandshakeMode: String, Codable, Sendable {
        case sync
        case file
        case pair
    }

    struct SyncSessionKeys: Equatable, Sendable {
        let transcript: Data
        let serverProof: Data
        let clientProof: Data
        let c2sKey: Data
        let s2cKey: Data

        func sendKey(for role: Role) -> Data { role == .client ? c2sKey : s2cKey }
        func recvKey(for role: Role) -> Data { role == .client ? s2cKey : c2sKey }
    }

    struct PairingSessionKeys: Equatable, Sendable {
        let transcript: Data
        let sasCode: String
        let c2sKey: Data
        let s2cKey: Data

        func sendKey(for role: Role) -> Data { role == .client ? c2sKey : s2cKey }
        func recvKey(for role: Role) -> Data { role == .client ? s2cKey : c2sKey }
    }

    enum CryptoError: Error, Equatable {
        case invalidKeyLength
        case invalidPublicKey
        case sequenceOverflow
        case malformedCiphertext
        case authenticationFailed
    }

    static func generateGroupKey() -> Data {
        randomBytes(count: keySize)
    }

    static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        var rng = SystemRandomNumberGenerator()
        for i in bytes.indices {
            bytes[i] = UInt8.random(in: 0...255, using: &rng)
        }
        return Data(bytes)
    }

    /// 群组公开标识：SHA256("shunsync:gid:" || groupKey) 前 16 字节的小写十六进制（32 字符）。
    static func groupID(for groupKey: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("shunsync:gid:".utf8))
        hasher.update(data: groupKey)
        let digest = Data(hasher.finalize())
        return hexLower(digest.prefix(16))
    }

    static func sha256Hex(_ data: Data) -> String {
        hexLower(Data(SHA256.hash(data: data)))
    }

    static func hexLower<D: DataProtocol>(_ data: D) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// X25519 临时密钥对。
    static func generateEphemeralKeyPair() -> (privateKey: Curve25519.KeyAgreement.PrivateKey, publicKeyData: Data) {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        return (priv, priv.publicKey.rawRepresentation)
    }

    static func sharedSecret(privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublicKeyData: Data) throws -> Data {
        guard peerPublicKeyData.count == keySize else { throw CryptoError.invalidPublicKey }
        let peerPub: Curve25519.KeyAgreement.PublicKey
        do {
            peerPub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKeyData)
        } catch {
            throw CryptoError.invalidPublicKey
        }
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peerPub)
        return secret.withUnsafeBytes { Data($0) }
    }

    static func deriveTranscript(
        mode: HandshakeMode,
        clientNonce: Data,
        serverNonce: Data,
        clientEphPub: Data,
        serverEphPub: Data,
        clientDeviceID: String,
        serverDeviceID: String
    ) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data("shunsync:v1:\(mode.rawValue)".utf8))
        hasher.update(data: clientNonce)
        hasher.update(data: serverNonce)
        hasher.update(data: clientEphPub)
        hasher.update(data: serverEphPub)
        hasher.update(data: Data(clientDeviceID.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(serverDeviceID.utf8))
        return Data(hasher.finalize())
    }

    /// 同步/文件通道密钥派生（mode 应为 .sync 或 .file）。
    static func deriveSyncSession(
        mode: HandshakeMode,
        groupKey: Data,
        clientNonce: Data,
        serverNonce: Data,
        clientEphPub: Data,
        serverEphPub: Data,
        clientDeviceID: String,
        serverDeviceID: String,
        sharedSecret: Data
    ) throws -> SyncSessionKeys {
        guard groupKey.count == keySize, sharedSecret.count == keySize else {
            throw CryptoError.invalidKeyLength
        }
        let transcript = deriveTranscript(
            mode: mode,
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            clientEphPub: clientEphPub,
            serverEphPub: serverEphPub,
            clientDeviceID: clientDeviceID,
            serverDeviceID: serverDeviceID
        )
        let groupSym = SymmetricKey(data: groupKey)
        let serverProof = Data(HMAC<SHA256>.authenticationCode(for: Data("server:".utf8) + transcript, using: groupSym))
        let clientProof = Data(HMAC<SHA256>.authenticationCode(for: Data("client:".utf8) + transcript, using: groupSym))

        var ikm = Data(capacity: sharedSecret.count + groupKey.count)
        ikm.append(sharedSecret)
        ikm.append(groupKey)
        let ikmKey = SymmetricKey(data: ikm)

        let c2s = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikmKey,
            salt: transcript,
            info: Data("shunsync:v1:c2s".utf8),
            outputByteCount: keySize
        )
        let s2c = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikmKey,
            salt: transcript,
            info: Data("shunsync:v1:s2c".utf8),
            outputByteCount: keySize
        )
        return SyncSessionKeys(
            transcript: transcript,
            serverProof: serverProof,
            clientProof: clientProof,
            c2sKey: c2s.withUnsafeBytes { Data($0) },
            s2cKey: s2c.withUnsafeBytes { Data($0) }
        )
    }

    /// 6 位确认码配对通道密钥派生（mode 固定 .pair）。
    static func derivePairingSession(
        clientNonce: Data,
        serverNonce: Data,
        clientEphPub: Data,
        serverEphPub: Data,
        clientDeviceID: String,
        serverDeviceID: String,
        sharedSecret: Data
    ) throws -> PairingSessionKeys {
        guard sharedSecret.count == keySize else { throw CryptoError.invalidKeyLength }
        let transcript = deriveTranscript(
            mode: .pair,
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            clientEphPub: clientEphPub,
            serverEphPub: serverEphPub,
            clientDeviceID: clientDeviceID,
            serverDeviceID: serverDeviceID
        )
        let raw32 = (UInt32(transcript[0]) << 24)
            | (UInt32(transcript[1]) << 16)
            | (UInt32(transcript[2]) << 8)
            | UInt32(transcript[3])
        let sas = String(format: "%06u", raw32 % 1_000_000)

        let ikmKey = SymmetricKey(data: sharedSecret)
        let c2s = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikmKey,
            salt: transcript,
            info: Data("shunsync:v1:pair-c2s".utf8),
            outputByteCount: keySize
        )
        let s2c = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikmKey,
            salt: transcript,
            info: Data("shunsync:v1:pair-s2c".utf8),
            outputByteCount: keySize
        )
        return PairingSessionKeys(
            transcript: transcript,
            sasCode: sas,
            c2sKey: c2s.withUnsafeBytes { Data($0) },
            s2cKey: s2c.withUnsafeBytes { Data($0) }
        )
    }

    /// 恒定时间字节比较，防时序侧信道。
    static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(lhs, rhs) {
            diff |= (a ^ b)
        }
        return diff == 0
    }

    // MARK: - 群组邀请码

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func base64URLDecode(_ text: String) -> Data? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = s.count % 4
        if rem == 2 { s += "==" }
        else if rem == 3 { s += "=" }
        else if rem == 1 { return nil }
        return Data(base64Encoded: s)
    }

    /// 生成可复制粘贴的跨平台群组邀请码，如 `shunsync://join?k=...&p=192.168.1.10:37219`。
    static func encodeInviteCode(groupKey: Data, peerHint: String? = nil) -> String {
        var components = URLComponents()
        components.scheme = "shunsync"
        components.host = "join"
        var items = [URLQueryItem(name: "k", value: base64URLEncode(groupKey))]
        if let peerHint = peerHint?.trimmingCharacters(in: .whitespacesAndNewlines), !peerHint.isEmpty {
            items.append(URLQueryItem(name: "p", value: peerHint))
        }
        components.queryItems = items
        return components.string ?? "shunsync://join?k=\(base64URLEncode(groupKey))"
    }

    /// 解析 `shunsync://join?...` 或纯 32 字节 Base64 / Base64URL 密钥。
    static func decodeInviteCode(_ input: String) -> (groupKey: Data, peerHint: String?)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed),
           url.scheme?.lowercased() == "shunsync",
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let k = components.queryItems?.first(where: { $0.name == "k" })?.value,
           let keyData = base64URLDecode(k),
           keyData.count == keySize {
            let peer = components.queryItems?.first(where: { $0.name == "p" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (keyData, (peer?.isEmpty == false) ? peer : nil)
        }
        if let raw = base64URLDecode(trimmed), raw.count == keySize {
            return (raw, nil)
        }
        return nil
    }
}

/// 单连接有状态 AES-256-GCM 加解密通道。
/// Nonce 固定为 4 字节 0x00000000 + 8 字节大端单调序号；AAD 为 8 字节大端序号。
final class SyncCipher {
    private let sendKey: SymmetricKey
    private let recvKey: SymmetricKey
    private(set) var sendSeq: UInt64 = 0
    private(set) var recvSeq: UInt64 = 0

    init(sendKey: Data, recvKey: Data) throws {
        guard sendKey.count == ShunSyncCrypto.keySize, recvKey.count == ShunSyncCrypto.keySize else {
            throw ShunSyncCrypto.CryptoError.invalidKeyLength
        }
        self.sendKey = SymmetricKey(data: sendKey)
        self.recvKey = SymmetricKey(data: recvKey)
    }

    func seal(_ plaintext: Data) throws -> Data {
        guard sendSeq < UInt64.max else { throw ShunSyncCrypto.CryptoError.sequenceOverflow }
        let seq = sendSeq
        let aad = Self.bigEndianBytes(seq)
        let nonce = try AES.GCM.Nonce(data: Data([0, 0, 0, 0]) + aad)
        let box = try AES.GCM.seal(plaintext, using: sendKey, nonce: nonce, authenticating: aad)
        sendSeq += 1
        var out = Data(capacity: box.ciphertext.count + box.tag.count)
        out.append(box.ciphertext)
        out.append(box.tag)
        return out
    }

    func open(_ ciphertextAndTag: Data) throws -> Data {
        guard recvSeq < UInt64.max else { throw ShunSyncCrypto.CryptoError.sequenceOverflow }
        guard ciphertextAndTag.count >= ShunSyncCrypto.gcmTagSize else {
            throw ShunSyncCrypto.CryptoError.malformedCiphertext
        }
        let seq = recvSeq
        let aad = Self.bigEndianBytes(seq)
        let nonce = try AES.GCM.Nonce(data: Data([0, 0, 0, 0]) + aad)
        let splitIndex = ciphertextAndTag.endIndex - ShunSyncCrypto.gcmTagSize
        let ciphertext = ciphertextAndTag[..<splitIndex]
        let tag = ciphertextAndTag[splitIndex...]
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(box, using: recvKey, authenticating: aad)
        } catch {
            throw ShunSyncCrypto.CryptoError.authenticationFailed
        }
        recvSeq += 1
        return plaintext
    }

    static func bigEndianBytes(_ value: UInt64) -> Data {
        var be = value.bigEndian
        return Data(bytes: &be, count: MemoryLayout<UInt64>.size)
    }

    static func bigEndianBytes(_ value: UInt32) -> Data {
        var be = value.bigEndian
        return Data(bytes: &be, count: MemoryLayout<UInt32>.size)
    }
}
