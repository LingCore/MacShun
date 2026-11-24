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

    private static func allMetricsConfig(
        style: PerformanceMenuBarStyle = .text,
        combineProcessors: Bool = true
    ) -> PerformanceConfig {
        var config = PerformanceConfig()
        config.cpu = true
        config.gpu = true
        config.memory = true
        config.temperature = true
        config.menuBarStyle = style
        config.combineProcessors = combineProcessors
        return config
    }

    @Test func olderConfigAndPartialPreferencesSurvive() throws {
        let old = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"keyboard":{"enabled":false}}"#.utf8))
        #expect(!old.keyboard.enabled)
        #expect(old.performance == PerformanceConfig())
        #expect(old.performance.metrics == [.cpu, .memory])
        #expect(old.performance.refreshInterval == .fiveSeconds)
        // 老版本已显式保存四项全开的配置文件时，升级后保留原选择，同时刷新间隔落到默认省电档位。
        let legacyAllOn = try JSONDecoder().decode(
            AppConfig.self,
            from: Data(#"{"performance":{"cpu":true,"gpu":true,"memory":true,"temperature":true}}"#.utf8)
        )
        #expect(legacyAllOn.performance.metrics == [.cpu, .gpu, .memory, .temperature])
        #expect(legacyAllOn.performance.refreshInterval == .fiveSeconds)
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"performance":{"gpu":false,"temperature":false}}"#.utf8))
        #expect(config.performance.metrics == [.cpu, .memory])
        #expect(config.performance.menuBarStyle == .text)
        var updated = config
        updated.performance.menuBarStyle = .trend
        updated.performance.combineProcessors = false
        updated.performance.refreshInterval = .tenSeconds
        #expect(try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(updated)) == updated)
        let future = try JSONDecoder().decode(
            PerformanceConfig.self,
            from: Data(#"{"menuBarStyle":"unknown","refreshInterval":999,"cpu":false}"#.utf8)
        )
        #expect(future.menuBarStyle == .text)
        #expect(future.refreshInterval == .fiveSeconds)
        #expect(!future.cpu)
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

    @Test func historyKeepsTheLatestTenSamplesAndMissingReadings() {
        var history = PerformanceHistory()
        for index in 0..<15 {
            history.append(PerformanceSnapshot(cpu: Double(index), gpu: index == 10 ? nil : Double(index)))
        }
        #expect(history.values(for: .cpu) == (5..<15).map { Double($0) as Double? })
        #expect(history.values(for: .gpu) == (5..<15).map { $0 == 10 ? nil : Double($0) })
    }

    @Test @MainActor func barKeepsWidthWhenValuesChange() {
        let loaded = PerformanceSnapshot(cpu: 100, gpu: 0, memory: MemoryUsage(used: 100, total: 100), temperature: 110)
        let variants: [(PerformanceMenuBarStyle, Bool, CGFloat)] = [
            (.text, true, 206), (.icons, true, 86), (.icons, false, 109), (.trend, true, 163), (.trend, false, 175),
        ]
        for (style, combined, width) in variants {
            let config = Self.allMetricsConfig(style: style, combineProcessors: combined)
            let pending = PerformanceMenuBarImage.make(snapshot: PerformanceSnapshot(), configuration: config, needsAttention: false)
            let full = PerformanceMenuBarImage.make(snapshot: loaded, configuration: config, needsAttention: true)
            #expect(pending.size == NSSize(width: width, height: 22))
            #expect(pending.size == full.size)
            #expect(full.isTemplate)
        }
        // 默认只开 CPU + 内存时宽度更紧凑（28 + 40 + 6 + 40 = 114）。
        #expect(PerformanceMenuBarImage.width(for: PerformanceConfig()) == 114)
        #expect(loaded.text(.gpu, compact: true) == "0%")
        #expect(PerformanceSnapshot().text(.gpu, compact: true) == "—")
    }

    @Test @MainActor func disablingEitherProcessorLeavesTheOtherAsAnIndividualMetric() {
        let snapshot = PerformanceSnapshot(cpu: 17, gpu: 28)
        for style in [PerformanceMenuBarStyle.icons, .trend] {
            for cpuEnabled in [true, false] {
                var config = PerformanceConfig()
                config.menuBarStyle = style
                config.cpu = cpuEnabled
                config.gpu = !cpuEnabled
                #expect(!config.canCombineProcessors)
                let combined = PerformanceMenuBarImage.make(snapshot: snapshot, configuration: config, needsAttention: false)
                config.combineProcessors = false
                let separate = PerformanceMenuBarImage.make(snapshot: snapshot, configuration: config, needsAttention: false)
                #expect(combined.size == separate.size)
            }
        }
    }

    @Test func smcDecodesRawBufferWithoutAllocation() {
        let sp78: [UInt8] = [55, 64]
        let decodedSP78 = sp78.withUnsafeBytes {
            ChipTemperatureReader.decode(type: ChipTemperatureReader.code("sp78"), bytes: $0)
        }
        #expect(decodedSP78 == 55.25)
        var flt = Float(68.5).bitPattern.littleEndian
        let decodedFlt = withUnsafeBytes(of: &flt) {
            ChipTemperatureReader.decode(type: ChipTemperatureReader.code("flt "), bytes: $0)
        }
        #expect(decodedFlt == 68.5)
    }

    @Test @MainActor func menuBarImageRasterizesAcrossAllStyles() throws {
        var history = PerformanceHistory()
        for step in 1...6 {
            history.append(PerformanceSnapshot(
                cpu: Double(step * 12),
                gpu: Double(step * 8),
                memory: MemoryUsage(used: Double(step) * 2_000_000_000, total: 16_000_000_000),
                temperature: 45 + Double(step * 3)
            ))
        }
        let latest = PerformanceSnapshot(
            cpu: 72, gpu: 48,
            memory: MemoryUsage(used: 12_000_000_000, total: 16_000_000_000),
            temperature: 63
        )
        for style in [PerformanceMenuBarStyle.text, .icons, .trend] {
            for combined in [true, false] {
                let config = Self.allMetricsConfig(style: style, combineProcessors: combined)
                let image = PerformanceMenuBarImage.make(
                    snapshot: latest, history: history, configuration: config, needsAttention: !combined
                )
                let w = Int(image.size.width * 2)
                let h = Int(image.size.height * 2)
                let rep = try #require(NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                ))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                image.draw(in: NSRect(origin: .zero, size: NSSize(width: w, height: h)))
                NSGraphicsContext.restoreGraphicsState()
                // 确认实际绘制出了非空模板像素
                let data = try #require(rep.bitmapData)
                let count = rep.bytesPerRow * h
                let hasInk = UnsafeBufferPointer(start: data, count: count).contains(where: { $0 != 0 })
                #expect(hasInk)
            }
        }
    }

    @Test func smcHotKeySelectionCoversEachFamilyAndCapsCount() {
        let readings: [(key: String, value: Double)] = [
            ("Tp00", 68.4), ("Tp04", 63.7), ("Tp0C", 69.9), ("Tp0G", 63.8),
            ("Tg0U", 47.0), ("Tg0X", 47.3), ("Tg1Y", 47.6), ("Tg0a", 47.6),
            ("Tf04", 50.4), ("Tf14", 55.5), ("Tf19", 55.5),
        ]
        let selected = ChipTemperatureReader.selectHotKeys(from: readings, perFamily: 2)
        #expect(selected == ["Tp0C", "Tp00", "Tg1Y", "Tg0a", "Tf14", "Tf19"])
        #expect(ChipTemperatureReader.selectHotKeys(from: [], perFamily: 2).isEmpty)
    }

    @Test @MainActor func visualKeySkipsRedrawWhenRenderedPixelsMatch() {
        let textConfig = Self.allMetricsConfig(style: .text)
        var textConfigSlow = textConfig
        textConfigSlow.refreshInterval = .tenSeconds
        let first = PerformanceSnapshot(
            cpu: 12.1, gpu: 3.2,
            memory: MemoryUsage(used: 50, total: 100),
            temperature: 48.1,
            sampledAt: Date(timeIntervalSince1970: 100)
        )
        let second = PerformanceSnapshot(
            cpu: 12.4, gpu: 3.1,
            memory: MemoryUsage(used: 50, total: 100),
            temperature: 48.4,
            sampledAt: Date(timeIntervalSince1970: 102)
        )
        let changed = PerformanceSnapshot(
            cpu: 14.0, gpu: 3.1,
            memory: MemoryUsage(used: 50, total: 100),
            temperature: 48.4,
            sampledAt: Date(timeIntervalSince1970: 104)
        )
        #expect(PerformanceMenuBarImage.visualKey(snapshot: first, configuration: textConfig, needsAttention: false, scale: 2)
                == PerformanceMenuBarImage.visualKey(snapshot: second, configuration: textConfig, needsAttention: false, scale: 2))
        // 仅切换刷新间隔不改变菜单栏视觉输出，VisualKey 保持一致。
        #expect(PerformanceMenuBarImage.visualKey(snapshot: first, configuration: textConfig, needsAttention: false, scale: 2)
                == PerformanceMenuBarImage.visualKey(snapshot: first, configuration: textConfigSlow, needsAttention: false, scale: 2))
        #expect(PerformanceMenuBarImage.visualKey(snapshot: first, configuration: textConfig, needsAttention: false, scale: 2)
                != PerformanceMenuBarImage.visualKey(snapshot: changed, configuration: textConfig, needsAttention: false, scale: 2))

        let iconConfig = Self.allMetricsConfig(style: .icons)
        let iconA = PerformanceSnapshot(cpu: 12.0, gpu: 10.0, memory: MemoryUsage(used: 50, total: 100), temperature: 48.0)
        let iconB = PerformanceSnapshot(cpu: 13.0, gpu: 10.0, memory: MemoryUsage(used: 50, total: 100), temperature: 48.0)
        let iconJump = PerformanceSnapshot(cpu: 35.0, gpu: 10.0, memory: MemoryUsage(used: 50, total: 100), temperature: 48.0)
        #expect(PerformanceMenuBarImage.visualKey(snapshot: iconA, configuration: iconConfig, needsAttention: false, scale: 2)
                == PerformanceMenuBarImage.visualKey(snapshot: iconB, configuration: iconConfig, needsAttention: false, scale: 2))
        #expect(PerformanceMenuBarImage.visualKey(snapshot: iconA, configuration: iconConfig, needsAttention: false, scale: 2)
                != PerformanceMenuBarImage.visualKey(snapshot: iconJump, configuration: iconConfig, needsAttention: false, scale: 2))
        #expect(PerformanceMenuBarImage.width(for: iconConfig) == 86)
        #expect(PerformanceMenuBarImage.width(for: textConfig) == 206)
    }

    @Test @MainActor func lowPowerModeAndBackgroundPermissionPollingThrottleWakeups() {
        let fastNormal = PerformanceMonitor.samplingCadence(for: .twoSeconds, lowPowerMode: false)
        let fastLowPower = PerformanceMonitor.samplingCadence(for: .twoSeconds, lowPowerMode: true)
        #expect(fastNormal.interval == .seconds(2) && fastNormal.temperatureInterval == 6)
        #expect(fastLowPower.interval == .seconds(5) && fastLowPower.temperatureInterval == 10)

        let defaultNormal = PerformanceMonitor.samplingCadence(lowPowerMode: false)
        let defaultLowPower = PerformanceMonitor.samplingCadence(lowPowerMode: true)
        #expect(defaultNormal.interval == .seconds(5) && defaultNormal.temperatureInterval == 10)
        #expect(defaultLowPower.interval == .seconds(10) && defaultLowPower.temperatureInterval == 20)

        let slowNormal = PerformanceMonitor.samplingCadence(for: .tenSeconds, lowPowerMode: false)
        let slowLowPower = PerformanceMonitor.samplingCadence(for: .tenSeconds, lowPowerMode: true)
        #expect(slowNormal.interval == .seconds(10) && slowNormal.temperatureInterval == 20)
        #expect(slowLowPower.interval == .seconds(15) && slowLowPower.temperatureInterval == 30)

        let normalClip = ClipboardWatcher.pollCadence(lowPowerMode: false)
        let lowPowerClip = ClipboardWatcher.pollCadence(lowPowerMode: true)
        #expect(normalClip.interval >= 1.5 && normalClip.tolerance >= 0.5)
        #expect(lowPowerClip.interval > normalClip.interval)

        let steadyBeacon = SyncDiscovery.beaconCadence(highFrequency: false)
        let pairingBeacon = SyncDiscovery.beaconCadence(highFrequency: true)
        #expect(steadyBeacon.interval == .seconds(15))
        #expect(pairingBeacon.interval == .seconds(5))

        // 剪贴板未授权但设置窗口关闭时，不能陷入永久 1 秒轮询。
        #expect(AppDelegate.permissionPollingInterval(
            allGood: true, clipboardNeedsPermission: true, settingsVisible: false,
            guideActive: false, selfTest: false, uptimeSinceLaunch: 600
        ) == 60)
        #expect(AppDelegate.permissionPollingInterval(
            allGood: true, clipboardNeedsPermission: true, settingsVisible: true,
            guideActive: false, selfTest: false, uptimeSinceLaunch: 600
        ) == 1)
        #expect(AppDelegate.permissionPollingInterval(
            allGood: false, clipboardNeedsPermission: false, settingsVisible: false,
            guideActive: false, selfTest: false, uptimeSinceLaunch: 600
        ) == 15)
        #expect(AppDelegate.permissionPollingInterval(
            allGood: false, clipboardNeedsPermission: false, settingsVisible: false,
            guideActive: true, selfTest: false, uptimeSinceLaunch: 600
        ) == 1)
    }
}
