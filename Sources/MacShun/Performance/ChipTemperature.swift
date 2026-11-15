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
    private var metadata: [String: SMCReadPacket.KeyInfo] = [:]
    private var availableKeys: [String]?
    private var retryAfter: TimeInterval = 0

    init() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        if IOServiceOpen(service, mach_task_self_, 0, &connection) != KERN_SUCCESS { connection = 0 }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    func read() -> Double? {
        guard connection != 0 else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        if availableKeys == nil || (availableKeys?.isEmpty == true && now >= retryAfter) {
            availableKeys = Self.sensorKeys.filter { keyInfo($0) != nil }
            retryAfter = now + 30
        }
        // 只用已识别的 CPU/GPU 芯片传感器，不用电池、硬盘或机身温度代替。
        return availableKeys?.compactMap { readValue($0) }.max()
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

    private func readValue(_ key: String) -> Double? {
        guard let info = keyInfo(key) else { return nil }
        var input = SMCReadPacket()
        input.key = Self.code(key)
        input.command = 5 // readBytes
        input.info.size = info.size
        guard var output = call(&input) else {
            metadata.removeValue(forKey: key)
            return nil
        }
        return withUnsafeBytes(of: &output.bytes) { Self.decode(type: info.type, bytes: Array($0.prefix(Int(info.size)))) }
    }

    static func decode(type: UInt32, bytes: [UInt8]) -> Double? {
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
