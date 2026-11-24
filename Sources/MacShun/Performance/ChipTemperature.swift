// SPDX-License-Identifier: MIT
// Read-only SMC protocol layout and sensor keys adapted from exelban/stats.
// Copyright (c) 2019 Serhiy Mytrovtsiy. See THIRD_PARTY_NOTICES.md.

import Foundation
import IOKit

/// AppleSMC 用户客户端的 80 字节 ABI。字段顺序和显式 padding 不能调整。
struct SMCReadPacket {
    struct Version {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }
    struct Limits {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpu: UInt32 = 0
        var gpu: UInt32 = 0
        var memory: UInt32 = 0
    }
    struct KeyInfo {
        var size: UInt32 = 0
        var type: UInt32 = 0
        var attributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var version = Version()
    var limits = Limits()
    var info = KeyInfo()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var command: UInt8 = 0
    var data: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
                (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

final class ChipTemperatureReader {
    private var connection: io_connect_t = 0
    private var openRetryAfter: TimeInterval = 0
    private var openBackoff: TimeInterval = 5
    private var metadata: [String: SMCReadPacket.KeyInfo] = [:]
    private var consecutiveFailures: [String: Int] = [:]
    private var availableKeys: [String]?
    private var hotKeys: [String]?
    private var lastFullScanAt: TimeInterval = 0
    private var lastReadAt: TimeInterval = 0
    private var cachedValue: Double?
    private var retryAfter: TimeInterval = 0
    private var scanBackoff: TimeInterval = 30

    /// 定期全量校准所有传感器的间隔，用于跟踪负载在 CPU 核心簇与 GPU 之间的迁移。
    static let fullScanInterval: TimeInterval = 60
    /// 传感器超过该数量时启用热键子集采样，常规轮询只读每族最热的若干键以大幅减少 SMC IPC。
    static let hotSubsetThreshold = 6
    static let hotKeysPerFamily = 2

    init() {
        openConnection()
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    private func resetConnectionState() {
        availableKeys = nil
        hotKeys = nil
        lastFullScanAt = 0
        lastReadAt = 0
        cachedValue = nil
        metadata.removeAll()
        consecutiveFailures.removeAll()
    }

    private func openConnection() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            connection = 0
            openRetryAfter = ProcessInfo.processInfo.systemUptime + openBackoff
            openBackoff = min(openBackoff * 3, 300)
            return
        }
        defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS {
            openBackoff = 5
            openRetryAfter = 0
            resetConnectionState()
        } else {
            connection = 0
            openRetryAfter = ProcessInfo.processInfo.systemUptime + openBackoff
            openBackoff = min(openBackoff * 3, 300)
        }
    }

    func read(minInterval: TimeInterval = 0) -> Double? {
        let now = ProcessInfo.processInfo.systemUptime
        if minInterval > 0, lastReadAt > 0, now - lastReadAt < minInterval {
            return cachedValue
        }
        if connection == 0 {
            guard now >= openRetryAfter else { return nil }
            openConnection()
            guard connection != 0 else { return nil }
        }
        if availableKeys == nil || (availableKeys?.isEmpty == true && now >= retryAfter) {
            let discovered = Self.sensorKeys.filter { keyInfo($0) != nil }
            availableKeys = discovered
            hotKeys = nil
            lastFullScanAt = 0
            if discovered.isEmpty {
                retryAfter = now + scanBackoff
                scanBackoff = min(scanBackoff * 2, 600)
            } else {
                scanBackoff = 30
            }
        }
        guard let allKeys = availableKeys, !allKeys.isEmpty else { return nil }
        let useFullScan = allKeys.count <= Self.hotSubsetThreshold
            || hotKeys == nil
            || hotKeys?.isEmpty == true
            || (now - lastFullScanAt) >= Self.fullScanInterval
        let targetKeys = useFullScan ? allKeys : (hotKeys ?? allKeys)

        // 只用已识别的 CPU/GPU 芯片传感器，不用电池、硬盘或机身温度代替。
        var warmest: Double?
        var readings: [(key: String, value: Double)] = []
        if useFullScan && allKeys.count > Self.hotSubsetThreshold {
            readings.reserveCapacity(allKeys.count)
        }
        var retired: [String] = []
        for key in targetKeys {
            if let value = readValue(key, retired: &retired) {
                warmest = warmest.map { max($0, value) } ?? value
                if useFullScan && allKeys.count > Self.hotSubsetThreshold {
                    readings.append((key, value))
                }
            }
        }
        if !retired.isEmpty {
            let drop = Set(retired)
            availableKeys?.removeAll { drop.contains($0) }
            hotKeys?.removeAll { drop.contains($0) }
            if !useFullScan {
                // 热键子集中有键退役时下次触发全量校准，避免漏掉同族其他传感器。
                hotKeys = nil
            }
            if availableKeys?.isEmpty == true {
                // 全部传感器键连续失效，说明 SMC 连接可能已失效，关闭并退避重连而不是立即对死连接重扫 127 个键。
                IOServiceClose(connection)
                connection = 0
                resetConnectionState()
                openRetryAfter = now + openBackoff
                openBackoff = min(openBackoff * 3, 300)
                return nil
            }
        }
        if useFullScan {
            lastFullScanAt = now
            if allKeys.count > Self.hotSubsetThreshold {
                let selected = Self.selectHotKeys(from: readings, perFamily: Self.hotKeysPerFamily)
                hotKeys = selected.isEmpty ? nil : selected
            }
        } else if warmest == nil {
            // 仅读子集全部无有效读数时立即清空子集，下一轮全量扫描。
            hotKeys = nil
        }
        lastReadAt = now
        cachedValue = warmest
        return warmest
    }

    /// 按传感器前两字符分族（如 Tp/Tg/Te/Tf/TC/TG）保留每族最热的若干键，
    /// 既覆盖 CPU/GPU 各自热点，又将单次轮询的 SMC 调用从几十次降到个位数。
    static func selectHotKeys(
        from readings: [(key: String, value: Double)],
        perFamily: Int = hotKeysPerFamily
    ) -> [String] {
        guard perFamily > 0, !readings.isEmpty else { return [] }
        var familyOrder: [String] = []
        var grouped: [String: [(index: Int, key: String, value: Double)]] = [:]
        for (index, item) in readings.enumerated() {
            let family = String(item.key.prefix(2))
            if grouped[family] == nil { familyOrder.append(family) }
            grouped[family, default: []].append((index, item.key, item.value))
        }
        var selected: [String] = []
        for family in familyOrder {
            guard let list = grouped[family] else { continue }
            let hottest = list.sorted { a, b in
                if a.value != b.value { return a.value > b.value }
                return a.index < b.index
            }.prefix(perFamily)
            selected.append(contentsOf: hottest.map(\.key))
        }
        return selected
    }

    static func code(_ key: String) -> UInt32 {
        key.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func keyInfo(_ key: String) -> SMCReadPacket.KeyInfo? {
        if let info = metadata[key] { return info }
        var input = SMCReadPacket()
        input.key = Self.code(key)
        input.command = 9 // readKeyInfo
        guard let output = call(&input), output.info.size > 0, output.info.size <= 32,
              (output.info.type == Self.code("sp78") && output.info.size == 2) ||
              (output.info.type == Self.code("flt ") && output.info.size == 4) else { return nil }
        metadata[key] = output.info
        return output.info
    }

    private func readValue(_ key: String, retired: inout [String]) -> Double? {
        guard let info = keyInfo(key) else { return nil }
        var input = SMCReadPacket()
        input.key = Self.code(key)
        input.command = 5 // readBytes
        input.info.size = info.size
        guard var output = call(&input) else {
            let failures = (consecutiveFailures[key] ?? 0) + 1
            consecutiveFailures[key] = failures
            // 单次瞬时读取失败不立即清空元数据，连续 3 次失败再退役该键。
            if failures >= 3 {
                metadata.removeValue(forKey: key)
                consecutiveFailures.removeValue(forKey: key)
                retired.append(key)
            }
            return nil
        }
        consecutiveFailures[key] = 0
        return withUnsafeBytes(of: &output.bytes) { raw in
            let slice = UnsafeRawBufferPointer(rebasing: raw.prefix(Int(info.size)))
            return Self.decode(type: info.type, bytes: slice)
        }
    }

    static func decode(type: UInt32, bytes: [UInt8]) -> Double? {
        bytes.withUnsafeBytes { decode(type: type, bytes: $0) }
    }

    static func decode(type: UInt32, bytes: UnsafeRawBufferPointer) -> Double? {
        let value: Double
        if type == code("sp78"), bytes.count == 2 {
            value = Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        } else if type == code("flt "), bytes.count == 4 {
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            value = Double(Float(bitPattern: bits))
        } else {
            return nil
        }
        // 无效、未就绪和断开的传感器不能变成 0°C 或荒谬的温度。
        return value.isFinite && value > 0 && value < 150 ? value : nil
    }

    private func call(_ input: inout SMCReadPacket) -> SMCReadPacket? {
        var output = SMCReadPacket()
        var size = MemoryLayout<SMCReadPacket>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, size, &output, &size)
        guard result == KERN_SUCCESS, output.result == 0, size == MemoryLayout<SMCReadPacket>.stride else { return nil }
        return output
    }

    // 已知 Intel 与 Apple Silicon CPU/GPU 传感器；仅探测存在的键，缓存其类型。
    // 来源：Stats Modules/Sensors/values.swift，后续机型在此维护，无需给用户增加兼容开关。
    static let sensorKeys: [String] = [
        "TC0D", "TC0E", "TC0F", "TCAD", "TCAC", "TCBC", "TC0c", "TC1c", "TC2c", "TC3c",
        "TC4c", "TC5c", "TC6c", "TC7c", "TC8c", "TC9c", "TC0C", "TC1C", "TC2C", "TC3C",
        "TC4C", "TC5C", "TC6C", "TC7C", "TC8C", "TC9C", "TCGC", "TG0D", "TGDD", "Tp09",
        "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b", "Tg05",
        "Tg0D", "Tg0L", "Tg0T", "Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp0f", "Tp0j", "Tg0f",
        "Tg0j", "Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D",
        "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E", "Tf14", "Tf18", "Tf19",
        "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A", "Te09", "Te0H", "Tp0V", "Tp0Y", "Tp0e",
        "Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0d", "Tg0e", "Tg0k", "Tp00", "Tp04",
        "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0a", "Tp0d", "Tp0g",
        "Tp0m", "Tp0p", "Tp0u", "Tp0y", "Tg0U", "Tg0X", "Tg0g", "Tg1Y", "Tg1c", "Tg1g",
        "Tp07", "Tp0I", "Tp0E", "Te07", "Te08", "Te0c", "Te0h", "Te0i", "Tg1e", "Tg0c",
        "Tg0b", "Tg1d", "Tg07", "Tg1f", "Tg09", "Tg0a", "Tg1h",
    ]
}
