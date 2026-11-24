// SPDX-License-Identifier: MIT

import Foundation
import Network

/// 封装单条 ShunSync TCP 连接：长度前缀分帧、串行有序发送与对称加解密通道。
final class SyncConnection: @unchecked Sendable {
    enum ConnectionError: Error, Equatable {
        case closed
        case timeout
        case invalidFrameLength(Int)
        case networkFailed(String)
        case protocolMismatch(String)
        case rejected(String)
        case authenticationFailed
    }

    let connection: NWConnection
    let queue: DispatchQueue
    private let initialRemoteHost: String?

    var remoteHost: String? {
        if let initialRemoteHost, !initialRemoteHost.isEmpty { return initialRemoteHost }
        if let pathEndpoint = connection.currentPath?.remoteEndpoint,
           let host = Self.extractHost(from: pathEndpoint), !host.isEmpty {
            return host
        }
        return nil
    }

    private var sendCipher: SyncCipher?
    private var recvCipher: SyncCipher?
    private var closed = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        self.initialRemoteHost = Self.extractHost(from: connection.endpoint)
    }

    static func connect(to endpoint: SyncEndpoint, queue: DispatchQueue) -> SyncConnection {
        let params = NWParameters.tcp
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.enableKeepalive = true
            tcp.keepaliveIdle = 20
            tcp.keepaliveInterval = 10
            tcp.keepaliveCount = 3
        }
        let nwEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(endpoint.host),
            port: NWEndpoint.Port(rawValue: endpoint.port)!
        )
        let conn = NWConnection(to: nwEndpoint, using: params)
        return SyncConnection(connection: conn, queue: queue)
    }

    func startAndWaitReady(timeoutSeconds: TimeInterval = 10) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let stateLock = Locked(false)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            let conn = connection

            let finish: @Sendable (Result<Void, Error>) -> Void = { result in
                let first = stateLock.update { done -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                guard first else { return }
                timer.cancel()
                conn.stateUpdateHandler = nil
                switch result {
                case .success: continuation.resume()
                case .failure(let err): continuation.resume(throwing: err)
                }
            }

            timer.schedule(deadline: .now() + timeoutSeconds)
            timer.setEventHandler { [weak self] in
                self?.close()
                finish(.failure(ConnectionError.timeout))
            }
            timer.resume()

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.success(()))
                case .failed(let error):
                    finish(.failure(ConnectionError.networkFailed(error.localizedDescription)))
                case .cancelled:
                    finish(.failure(ConnectionError.closed))
                default:
                    break
                }
            }
            conn.start(queue: queue)
        }
    }

    /// 握手完成后激活单连接双向加密。后续读写将严格按序号走 AES-256-GCM。
    func activateCipher(sendKey: Data, recvKey: Data) throws {
        let send = try SyncCipher(sendKey: sendKey, recvKey: recvKey)
        let recv = try SyncCipher(sendKey: sendKey, recvKey: recvKey)
        queue.sync {
            self.sendCipher = send
            self.recvCipher = recv
        }
    }

    func close() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.closed = true
            self.connection.cancel()
        }
    }

    // MARK: - 明文握手帧

    func sendPlaintextJSON<T: Encodable>(_ value: T) async throws {
        let data = try JSONEncoder().encode(value)
        try await sendRawPacket(data, encrypt: false)
    }

    func receivePlaintextJSON<T: Decodable>(_ type: T.Type, timeoutSeconds: TimeInterval = 15) async throws -> T {
        let data = try await receiveRawPacket(decrypt: false, timeoutSeconds: timeoutSeconds)
        return try JSONDecoder().decode(type, from: data)
    }

    // MARK: - 加密协议帧

    func sendEncryptedFrame(_ frame: SyncFrame) async throws {
        let plain = try SyncFrame.encode(frame)
        try await sendRawPacket(plain, encrypt: true)
    }

    func sendEncryptedJSON<T: Encodable>(_ value: T) async throws {
        let plain = try SyncFrame.encodeJSON(value)
        try await sendRawPacket(plain, encrypt: true)
    }

    func receiveEncryptedFrame(timeoutSeconds: TimeInterval? = nil) async throws -> SyncFrame {
        let plain = try await receiveRawPacket(decrypt: true, timeoutSeconds: timeoutSeconds)
        return try SyncFrame.decode(plain)
    }

    // MARK: - 底层收发（发送严格在 queue 上串行加密并排入 NWConnection，保证 seq 与流顺序完全一致）

    private func sendRawPacket(_ payload: Data, encrypt: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self, !self.closed else {
                    continuation.resume(throwing: ConnectionError.closed)
                    return
                }
                do {
                    let wirePayload: Data
                    if encrypt {
                        guard let cipher = self.sendCipher else {
                            continuation.resume(throwing: ConnectionError.protocolMismatch("cipher not active"))
                            return
                        }
                        wirePayload = try cipher.seal(payload)
                    } else {
                        wirePayload = payload
                    }
                    let packet = try SyncFrame.packWirePacket(wirePayload)
                    self.connection.send(content: packet, completion: .contentProcessed { error in
                        if let error {
                            continuation.resume(throwing: ConnectionError.networkFailed(error.localizedDescription))
                        } else {
                            continuation.resume()
                        }
                    })
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func receiveRawPacket(decrypt: Bool, timeoutSeconds: TimeInterval?) async throws -> Data {
        let header = try await readExact(4, timeoutSeconds: timeoutSeconds)
        let length = Int(SyncFrame.readBigEndianUInt32(header, offset: 0))
        let maxWire = SyncProtocol.maxFrameBytes + ShunSyncCrypto.gcmTagSize
        guard length > 0, length <= maxWire else {
            throw ConnectionError.invalidFrameLength(length)
        }
        let wirePayload = try await readExact(length, timeoutSeconds: timeoutSeconds)
        if !decrypt { return wirePayload }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            queue.async { [weak self] in
                guard let self, let cipher = self.recvCipher else {
                    continuation.resume(throwing: ConnectionError.protocolMismatch("cipher not active"))
                    return
                }
                do {
                    continuation.resume(returning: try cipher.open(wirePayload))
                } catch {
                    continuation.resume(throwing: ConnectionError.authenticationFailed)
                }
            }
        }
    }

    private func readExact(_ count: Int, timeoutSeconds: TimeInterval?) async throws -> Data {
        var buffer = Data()
        buffer.reserveCapacity(count)
        while buffer.count < count {
            let remaining = count - buffer.count
            let chunk = try await readChunk(minimum: 1, maximum: remaining, timeoutSeconds: timeoutSeconds)
            buffer.append(chunk)
        }
        return buffer
    }

    private func readChunk(minimum: Int, maximum: Int, timeoutSeconds: TimeInterval?) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            queue.async { [weak self] in
                guard let self, !self.closed else {
                    continuation.resume(throwing: ConnectionError.closed)
                    return
                }
                var resumed = false
                var timer: DispatchSourceTimer?

                func finish(_ result: Result<Data, Error>) {
                    guard !resumed else { return }
                    resumed = true
                    timer?.cancel()
                    timer = nil
                    switch result {
                    case .success(let data): continuation.resume(returning: data)
                    case .failure(let err): continuation.resume(throwing: err)
                    }
                }

                if let timeoutSeconds {
                    let t = DispatchSource.makeTimerSource(queue: self.queue)
                    t.schedule(deadline: .now() + timeoutSeconds)
                    t.setEventHandler { [weak self] in
                        self?.close()
                        finish(.failure(ConnectionError.timeout))
                    }
                    t.resume()
                    timer = t
                }

                self.connection.receive(minimumIncompleteLength: minimum, maximumLength: maximum) { data, _, isComplete, error in
                    if let error {
                        finish(.failure(ConnectionError.networkFailed(error.localizedDescription)))
                        return
                    }
                    if let data, !data.isEmpty {
                        finish(.success(data))
                        return
                    }
                    if isComplete {
                        finish(.failure(ConnectionError.closed))
                        return
                    }
                    finish(.failure(ConnectionError.closed))
                }
            }
        }
    }

    static func extractHost(from endpoint: NWEndpoint) -> String? {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let addr):
                return ipv4String(addr)
            case .ipv6(let addr):
                let text = "\(addr)"
                // 剥离链路本地网卡后缀 %en0 或映射 IPv4 前缀 ::ffff:
                let cleaned = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
                if cleaned.lowercased().hasPrefix("::ffff:") {
                    return String(cleaned.dropFirst(7))
                }
                return cleaned
            case .name(let name, _):
                return name
            @unknown default:
                return nil
            }
        default:
            return nil
        }
    }

    private static func ipv4String(_ addr: IPv4Address) -> String {
        let bytes = Array(addr.rawValue)
        guard bytes.count == 4 else { return "\(addr)" }
        return "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])"
    }
}
