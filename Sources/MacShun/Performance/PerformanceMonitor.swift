// SPDX-License-Identifier: MIT

import AppKit
import Combine

/// 主线程发布读数；硬件访问在串行低优先级队列。关掉、睡眠、息屏、锁屏或切用户时暂停采样；低电量模式自动降频。
final class PerformanceMonitor: ObservableObject {
    struct Cadence: Equatable {
        let interval: DispatchTimeInterval
        let leeway: DispatchTimeInterval
        let temperatureInterval: TimeInterval
    }

    static func samplingCadence(
        for refreshInterval: PerformanceRefreshInterval = PerformanceConfig().refreshInterval,
        lowPowerMode: Bool
    ) -> Cadence {
        switch refreshInterval {
        case .twoSeconds:
            if lowPowerMode {
                return Cadence(interval: .seconds(5), leeway: .seconds(1), temperatureInterval: 10)
            }
            return Cadence(interval: .seconds(2), leeway: .milliseconds(500), temperatureInterval: 6)
        case .fiveSeconds:
            if lowPowerMode {
                return Cadence(interval: .seconds(10), leeway: .seconds(2), temperatureInterval: 20)
            }
            return Cadence(interval: .seconds(5), leeway: .seconds(1), temperatureInterval: 10)
        case .tenSeconds:
            if lowPowerMode {
                return Cadence(interval: .seconds(15), leeway: .seconds(3), temperatureInterval: 30)
            }
            return Cadence(interval: .seconds(10), leeway: .seconds(2), temperatureInterval: 20)
        }
    }

    static let shared = PerformanceMonitor()
    @Published private(set) var snapshot = PerformanceSnapshot()
    private(set) var history = PerformanceHistory()
    private let worker = DispatchQueue(label: "com.macshun.performance", qos: .utility)
    private let activeMetrics = Locked<[PerformanceMetric]>([])
    private let temperatureMinInterval = Locked<TimeInterval>(
        samplingCadence(lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled).temperatureInterval
    )
    private var timer: DispatchSourceTimer?
    private var sampler: SystemMetricsSampler? // 只在 worker 访问
    private var samplingMetrics: [PerformanceMetric] = []
    private var refreshInterval: PerformanceRefreshInterval = PerformanceConfig().refreshInterval
    private var generation = 0
    private var asleep = false
    private var screenAsleep = false
    private var screenLocked = false
    private var sessionInactive = false
    private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var paused: Bool { asleep || screenAsleep || screenLocked || sessionInactive }
    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var powerObserver: NSObjectProtocol?

    init(snapshot: PerformanceSnapshot = PerformanceSnapshot()) {
        self.snapshot = snapshot
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setPausedState { $0.asleep = true }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setPausedState { $0.asleep = false }
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setPausedState { $0.screenAsleep = true }
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setPausedState { $0.screenAsleep = false }
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setPausedState { $0.sessionInactive = true }
        })
        observers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.setPausedState { $0.sessionInactive = false }
        })
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.setPausedState { $0.screenLocked = true }
        })
        distributedObservers.append(distributed.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.setPausedState { $0.screenLocked = false }
        })
        powerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handlePowerStateChange()
        }
    }

    deinit {
        timer?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
    }

    func apply(_ config: PerformanceConfig) {
        precondition(Thread.isMainThread)
        let metrics = config.enabled ? config.metrics : []
        let metricsChanged = samplingMetrics != metrics
        let intervalChanged = refreshInterval != config.refreshInterval
        guard metricsChanged || intervalChanged else { return }
        samplingMetrics = metrics
        refreshInterval = config.refreshInterval
        activeMetrics.set(metrics)
        let cadence = Self.samplingCadence(for: refreshInterval, lowPowerMode: lowPowerMode)
        temperatureMinInterval.set(cadence.temperatureInterval)
        if metrics.isEmpty {
            tearDown(resetData: true)
            return
        }
        guard !paused else { return }
        if timer != nil {
            if intervalChanged {
                // 仅变更刷新频率时复用采样器与历史曲线，若同时增减指标则立即补采一次。
                startTimer(immediate: metricsChanged)
            } else {
                // 运行中增减监控项时复用现有采样器与历史曲线，避免重启 SMC 连接或丢失 CPU 基线。
                let currentGeneration = generation
                worker.async { [weak self] in
                    self?.sampleOnce(generation: currentGeneration)
                }
            }
        } else {
            startTimer()
        }
    }

    func stop() {
        precondition(Thread.isMainThread)
        samplingMetrics = []
        activeMetrics.set([])
        tearDown(resetData: true)
    }

    private func handlePowerStateChange() {
        let nowLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard nowLowPower != lowPowerMode else { return }
        lowPowerMode = nowLowPower
        let cadence = Self.samplingCadence(for: refreshInterval, lowPowerMode: nowLowPower)
        temperatureMinInterval.set(cadence.temperatureInterval)
        if timer != nil {
            // 低电量模式切换时仅更新定时器频率，不重置历史或硬件连接。
            startTimer(immediate: false)
        }
    }

    private func setPausedState(_ update: (PerformanceMonitor) -> Void) {
        let wasPaused = paused
        update(self)
        let nowPaused = paused
        guard wasPaused != nowPaused else { return }
        if nowPaused {
            tearDown(resetData: false)
        } else if !samplingMetrics.isEmpty {
            startTimer()
        }
    }

    private func tearDown(resetData: Bool) {
        generation += 1
        timer?.cancel()
        timer = nil
        if resetData {
            history = PerformanceHistory()
            snapshot = PerformanceSnapshot()
        }
        worker.async { [weak self] in self?.sampler = nil }
    }

    private func startTimer(immediate: Bool = true) {
        generation += 1
        let currentGeneration = generation
        timer?.cancel()
        timer = nil
        guard !samplingMetrics.isEmpty, !paused else { return }

        let cadence = Self.samplingCadence(for: refreshInterval, lowPowerMode: lowPowerMode)
        temperatureMinInterval.set(cadence.temperatureInterval)
        let source = DispatchSource.makeTimerSource(queue: worker)
        let deadline: DispatchTime = immediate ? .now() : .now() + cadence.interval
        source.schedule(deadline: deadline, repeating: cadence.interval, leeway: cadence.leeway)
        source.setEventHandler { [weak self] in
            self?.sampleOnce(generation: currentGeneration)
        }
        timer = source
        source.resume()
    }

    private func sampleOnce(generation currentGeneration: Int) {
        let metrics = activeMetrics.get()
        guard !metrics.isEmpty else { return }
        if sampler == nil { sampler = SystemMetricsSampler() }
        guard let sample = sampler?.sample(metrics: metrics, temperatureMinInterval: temperatureMinInterval.get()) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.history.append(sample)
            self.snapshot = sample
        }
    }
}
