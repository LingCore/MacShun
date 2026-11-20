// SPDX-License-Identifier: MIT
// GPU property names and memory accounting adapted from exelban/stats.
// Copyright (c) 2019 Serhiy Mytrovtsiy. See THIRD_PARTY_NOTICES.md.

import Darwin
import Foundation
import IOKit

enum PerformanceMetric: CaseIterable, Identifiable {
    case cpu, gpu, memory, temperature
    var id: Self { self }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: L("内存")
        case .temperature: L("芯片温度")
        }
    }

    var barLabel: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "RAM"
        case .temperature: "TEMP"
        }
    }
}

struct CPUCounters {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32

    /// 首次采样只建立基线；UInt32 计数回绕后仍按区间差值计算。
    func usage(since previous: CPUCounters) -> Double? {
        let busy = Double(user &- previous.user) + Double(system &- previous.system) + Double(nice &- previous.nice)
        let total = busy + Double(idle &- previous.idle)
        return total > 0 ? busy / total * 100 : nil
    }
}

struct MemoryUsage {
    let used: Double
    let total: Double
    var percent: Double { total > 0 ? used / total * 100 : 0 }

    /// 与活动监视器相同的口径：应用、联动和压缩内存，不把可回收的文件缓存算作占用。
    static func calculate(total: Double, pageSize: Double, active: UInt32, inactive: UInt32,
                          speculative: UInt32, wired: UInt32, compressed: UInt32,
                          purgeable: UInt32, external: UInt32) -> MemoryUsage? {
        guard total.isFinite, total > 0, pageSize.isFinite, pageSize > 0 else { return nil }
        let occupied = Double(active) + Double(inactive) + Double(speculative) + Double(wired) + Double(compressed)
        let reclaimable = Double(purgeable) + Double(external)
        return MemoryUsage(used: min(total, max(0, (occupied - reclaimable) * pageSize)), total: total)
    }

    private static let formatter = Locked<ByteCountFormatter>({
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowedUnits = [.useGB, .useMB]
        return f
    }())

    var description: String {
        Self.formatter.withLock { formatter in
            let usedText = formatter.string(fromByteCount: Int64(used))
            let totalText = formatter.string(fromByteCount: Int64(total))
            return "\(usedText) / \(totalText)"
        }
    }
}

struct PerformanceSnapshot {
    var cpu: Double?
    var gpu: Double?
    var gpuCount = 0
    var memory: MemoryUsage?
    var temperature: Double?
    var sampledAt: Date?
    var cpuPending = false

    func value(_ metric: PerformanceMetric) -> Double? {
        switch metric {
        case .cpu: cpu
        case .gpu: gpu
        case .memory: memory?.percent
        case .temperature: temperature
        }
    }

    func text(_ metric: PerformanceMetric, compact: Bool = false) -> String {
        guard let value = value(metric), value.isFinite else {
            if compact { return "—" }
            return sampledAt == nil || (metric == .cpu && cpuPending) ? L("正在读取…") : L("暂不可用")
        }
        return String(format: metric == .temperature ? "%.0f°C" : "%.0f%%", value)
    }
}

struct PerformanceHistory {
    static let capacity = 10
    private var samples: [PerformanceSnapshot] = []

    mutating func append(_ snapshot: PerformanceSnapshot) {
        if samples.count == Self.capacity { samples.removeFirst() }
        samples.append(snapshot)
    }

    func values(for metric: PerformanceMetric) -> [Double?] {
        samples.map { $0.value(metric) }
    }
}

/// 仅在 PerformanceMonitor 的串行工作队列使用，不启动进程，不写硬件，也不请求管理员权限。
final class SystemMetricsSampler {
    private let host = mach_host_self()
    private let pageSize: Double
    private let totalMemory = Double(ProcessInfo.processInfo.physicalMemory)
    private var previousCPU: CPUCounters?
    private var temperatureReader: ChipTemperatureReader?
    private var gpuServices: [io_service_t] = []
    private var gpuServicesLoaded = false
    private var gpuRetryAfter: TimeInterval = 0

    init() {
        var hostPageSize: vm_size_t = vm_page_size
        _ = host_page_size(host, &hostPageSize)
        self.pageSize = Double(hostPageSize)
    }

    deinit {
        clearGPUServices()
        mach_port_deallocate(mach_task_self_, host)
    }

    func sample(metrics: [PerformanceMetric]) -> PerformanceSnapshot {
        var snapshot = PerformanceSnapshot()
        if metrics.contains(.cpu) {
            if let counters = readCPU() {
                snapshot.cpuPending = previousCPU == nil
                snapshot.cpu = previousCPU.flatMap { counters.usage(since: $0) }
                previousCPU = counters
            } else {
                previousCPU = nil
            }
        } else {
            previousCPU = nil
        }
        if metrics.contains(.memory) { snapshot.memory = readMemory() }
        if metrics.contains(.gpu) {
            let values = readGPU()
            snapshot.gpu = values.max()
            snapshot.gpuCount = values.count
        } else if gpuServicesLoaded {
            clearGPUServices()
        }
        if metrics.contains(.temperature) {
            if temperatureReader == nil { temperatureReader = ChipTemperatureReader() }
            snapshot.temperature = temperatureReader?.read()
        } else {
            temperatureReader = nil
        }
        snapshot.sampledAt = Date()
        return snapshot
    }

    private func readCPU() -> CPUCounters? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUCounters(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }

    private func readMemory() -> MemoryUsage? {
        var info = vm_statistics64()
        // 使用已支持的 REV1 字段范围，兼容 SDK 比当前系统新时的结构体扩展。
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.offset(of: \.total_uncompressed_pages_in_compressor)! /
                                          MemoryLayout<integer_t>.stride + MemoryLayout<UInt64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return MemoryUsage.calculate(total: totalMemory, pageSize: pageSize,
                                     active: info.active_count, inactive: info.inactive_count, speculative: info.speculative_count,
                                     wired: info.wire_count, compressed: info.compressor_page_count,
                                     purgeable: info.purgeable_count, external: info.external_page_count)
    }

    private func clearGPUServices() {
        for service in gpuServices { IOObjectRelease(service) }
        gpuServices.removeAll()
        gpuServicesLoaded = false
        gpuRetryAfter = 0
    }

    private func reloadGPUServices() {
        for service in gpuServices { IOObjectRelease(service) }
        gpuServices.removeAll()
        gpuServicesLoaded = true
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            gpuRetryAfter = ProcessInfo.processInfo.systemUptime + 60
            return
        }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            gpuServices.append(service)
        }
        if gpuServices.isEmpty {
            gpuRetryAfter = ProcessInfo.processInfo.systemUptime + 60
        }
    }

    private func readGPU() -> [Double] {
        let now = ProcessInfo.processInfo.systemUptime
        if !gpuServicesLoaded || (gpuServices.isEmpty && now >= gpuRetryAfter) {
            reloadGPUServices()
        }
        guard !gpuServices.isEmpty else { return [] }
        let (values, hasStaleService) = readCachedGPUValues()
        if !hasStaleService {
            return values
        }
        // 外接显卡拔插或服务句柄离开 IOService 平面时重新枚举一次。
        reloadGPUServices()
        return readCachedGPUValues().values
    }

    private func readCachedGPUValues() -> (values: [Double], hasStaleService: Bool) {
        var values: [Double] = []
        values.reserveCapacity(gpuServices.count)
        var hasStaleService = false
        for service in gpuServices {
            if IORegistryEntryInPlane(service, kIOServicePlane) == 0 {
                hasStaleService = true
                continue
            }
            // 双显卡机型上休眠的独显可能暂时没有 PerformanceStatistics，跳过该卡，不影响其余存活显卡读数。
            guard let statistics = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else {
                continue
            }
            if let value = Self.gpuUsage(statistics) {
                values.append(value)
            }
        }
        return (values, hasStaleService)
    }

    static func gpuUsage(_ statistics: [String: Any]) -> Double? {
        for key in ["Device Utilization %", "GPU Activity(%)"] {
            if let value = (statistics[key] as? NSNumber)?.doubleValue, value.isFinite, (0...100).contains(value) {
                return value
            }
        }
        return nil
    }
}
