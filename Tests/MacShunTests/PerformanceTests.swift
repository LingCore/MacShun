// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import Testing
@testable import MacShun

@Suite("性能监控")
struct PerformanceTests {
    @Test func cpuUsesIntervalInsteadOfLifetime() throws {
        let previous = CPUCounters(user: 500, system: 200, idle: 1000, nice: 10)
        let current = CPUCounters(user: 510, system: 205, idle: 1060, nice: 15)
        #expect(try #require(current.usage(since: previous)) == 25)
        #expect(previous.usage(since: previous) == nil)
    }

    @Test func cpuCounterWrap() throws {
        let previous = CPUCounters(user: .max - 4, system: 0, idle: 0, nice: 0)
        let current = CPUCounters(user: 5, system: 0, idle: 30, nice: 0)
        #expect(try #require(current.usage(since: previous)) == 25)
    }

    @Test func memoryExcludesReclaimableCache() throws {
        let usage = try #require(MemoryUsage.calculate(total: 1000, pageSize: 10, active: 20, inactive: 15,
                                                       speculative: 5, wired: 10, compressed: 5, purgeable: 4, external: 6))
        #expect(usage.used == 450)
        #expect(usage.percent == 45)
        #expect(MemoryUsage.calculate(total: 0, pageSize: 10, active: 0, inactive: 0,
                                     speculative: 0, wired: 0, compressed: 0, purgeable: 0, external: 0) == nil)
    }

    @Test func memoryHandlesInconsistentCountersWithoutOverflow() throws {
        let over = try #require(MemoryUsage.calculate(total: 1000, pageSize: 16384, active: .max, inactive: .max,
                                                      speculative: .max, wired: .max, compressed: .max, purgeable: 0, external: 0))
        let under = try #require(MemoryUsage.calculate(total: 1000, pageSize: 16384, active: 0, inactive: 0,
                                                       speculative: 0, wired: 0, compressed: 0, purgeable: .max, external: .max))
        #expect(over.percent == 100)
        #expect(under.percent == 0)
    }

    @Test func gpuDistinguishesIdleFromUnavailable() {
        #expect(SystemMetricsSampler.gpuUsage(["Device Utilization %": 0]) == 0)
        #expect(SystemMetricsSampler.gpuUsage([:]) == nil)
        #expect(SystemMetricsSampler.gpuUsage(["Renderer Utilization %": 10]) == nil)
        #expect(SystemMetricsSampler.gpuUsage(["Device Utilization %": -1, "GPU Activity(%)": 23]) == 23)
        #expect(SystemMetricsSampler.gpuUsage(["Device Utilization %": Double.nan]) == nil)
        #expect(SystemMetricsSampler.gpuUsage(["GPU Activity(%)": 101]) == nil)
    }

    @Test func cpuBaselineIsPendingRatherThanUnavailable() {
        let snapshot = PerformanceSnapshot(sampledAt: Date(), cpuPending: true)
        #expect(snapshot.text(.cpu) == L("正在读取…"))
        #expect(snapshot.text(.cpu, compact: true) == "—")
        #expect(snapshot.text(.gpu) == L("暂不可用"))
    }

    @Test func smcABIMatchesKernelProtocol() {
        #expect(MemoryLayout<SMCReadPacket>.stride == 80)
        #expect(MemoryLayout<SMCReadPacket>.offset(of: \.info) == 28)
        #expect(MemoryLayout<SMCReadPacket>.offset(of: \.command) == 42)
        #expect(MemoryLayout<SMCReadPacket>.offset(of: \.bytes) == 48)
    }

    @Test func smcDecodesBothTemperatureFormats() {
        #expect(ChipTemperatureReader.decode(type: ChipTemperatureReader.code("sp78"), bytes: [42, 128]) == 42.5)
        let bits = Float(54.25).bitPattern
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) }
        #expect(ChipTemperatureReader.decode(type: ChipTemperatureReader.code("flt "), bytes: bytes) == 54.25)
    }

    @Test func smcRejectsInvalidTemperatures() {
        let type = ChipTemperatureReader.code("sp78")
        #expect(ChipTemperatureReader.decode(type: type, bytes: [0, 0]) == nil)
        #expect(ChipTemperatureReader.decode(type: type, bytes: [255, 0]) == nil)
        #expect(ChipTemperatureReader.decode(type: type, bytes: [42]) == nil)
        #expect(ChipTemperatureReader.decode(type: ChipTemperatureReader.code("flt "), bytes: [0, 0, 192, 127]) == nil)
        #expect(ChipTemperatureReader.decode(type: ChipTemperatureReader.code("ui16"), bytes: [42, 0]) == nil)
        #expect(ChipTemperatureReader.sensorKeys.allSatisfy { $0.utf8.count == 4 })
        #expect(Set(ChipTemperatureReader.sensorKeys).count == ChipTemperatureReader.sensorKeys.count)
        #expect(!ChipTemperatureReader.sensorKeys.contains("TB0T")) // 不以电池温度冒充芯片温度
    }

    @Test func olderConfigAndPartialPreferencesSurvive() throws {
        let old = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"keyboard":{"enabled":false}}"#.utf8))
        #expect(!old.keyboard.enabled)
        #expect(old.performance == PerformanceConfig())
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"performance":{"gpu":false,"temperature":false}}"#.utf8))
        #expect(config.performance.metrics == [.cpu, .memory])
        #expect(try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config)) == config)
    }

    @Test func disablingEveryMetricStopsSampling() {
        var config = PerformanceConfig()
        config.enabled = false
        #expect(!config.isActive)
        config.enabled = true
        config.cpu = false
        config.gpu = false
        config.memory = false
        config.temperature = false
        #expect(!config.isActive)
    }

    @Test @MainActor func barKeepsWidthWhenValuesChange() {
        let pending = PerformanceMenuBarImage.make(snapshot: PerformanceSnapshot(), metrics: PerformanceMetric.allCases, needsAttention: false)
        let loaded = PerformanceSnapshot(cpu: 100, gpu: 0, memory: MemoryUsage(used: 100, total: 100), temperature: 110)
        let full = PerformanceMenuBarImage.make(snapshot: loaded, metrics: PerformanceMetric.allCases, needsAttention: true)
        #expect(pending.size == full.size)
        #expect(full.isTemplate)
        #expect(loaded.text(.gpu, compact: true) == "0%")
        #expect(PerformanceSnapshot().text(.gpu, compact: true) == "—")
    }
}
