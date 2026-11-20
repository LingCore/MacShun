// SPDX-License-Identifier: MIT

import AppKit
import Combine

/// 主线程发布读数；硬件访问在串行低优先级队列。关掉、睡眠、息屏或切用户时暂停采样。
final class PerformanceMonitor: ObservableObject {
    static let shared = PerformanceMonitor()
    @Published private(set) var snapshot = PerformanceSnapshot()
    private(set) var history = PerformanceHistory()
    private let worker = DispatchQueue(label: "com.macshun.performance", qos: .utility)
    private let activeMetrics = Locked<[PerformanceMetric]>([])
    private var timer: DispatchSourceTimer?
    private var sampler: SystemMetricsSampler? // 只在 worker 访问
    private var samplingMetrics: [PerformanceMetric] = []
    private var generation = 0
    private var asleep = false
    private var screenAsleep = false
    private var sessionInactive = false
    private var paused: Bool { asleep || screenAsleep || sessionInactive }
    private var observers: [NSObjectProtocol] = []

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
    }

    deinit {
        timer?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func apply(_ config: PerformanceConfig) {
        precondition(Thread.isMainThread)
        let metrics = config.enabled ? config.metrics : []
        guard samplingMetrics != metrics else { return }
        samplingMetrics = metrics
        activeMetrics.set(metrics)
        if metrics.isEmpty {
            tearDown(resetData: true)
            return
        }
        guard !paused else { return }
        if timer != nil {
            // 运行中增减监控项时复用现有采样器与历史曲线，避免重启 SMC 连接或丢失 CPU 基线。
            let currentGeneration = generation
            worker.async { [weak self] in
                self?.sampleOnce(generation: currentGeneration)
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

    private func startTimer() {
        generation += 1
        let currentGeneration = generation
        timer?.cancel()
        timer = nil
        guard !samplingMetrics.isEmpty, !paused else { return }

        let source = DispatchSource.makeTimerSource(queue: worker)
        source.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(250))
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
        guard let sample = sampler?.sample(metrics: metrics) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.history.append(sample)
            self.snapshot = sample
        }
    }
}
