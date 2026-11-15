// SPDX-License-Identifier: MIT

import AppKit
import Combine

/// 主线程发布读数；硬件访问在串行低优先级队列。关掉、睡眠和重新配置时撤销旧采样。
final class PerformanceMonitor: ObservableObject {
    static let shared = PerformanceMonitor()
    @Published private(set) var snapshot = PerformanceSnapshot()
    private let worker = DispatchQueue(label: "com.macshun.performance", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var sampler: SystemMetricsSampler? // 只在 worker 访问
    private var configuration: PerformanceConfig?
    private var generation = 0
    private var sleeping = false
    private var observers: [NSObjectProtocol] = []

    init(snapshot: PerformanceSnapshot = PerformanceSnapshot()) {
        self.snapshot = snapshot
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = true
            self?.restart()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sleeping = false
            self?.restart()
        })
    }

    deinit {
        timer?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func apply(_ config: PerformanceConfig) {
        precondition(Thread.isMainThread)
        guard configuration != config else { return }
        configuration = config
        restart()
    }

    func stop() {
        precondition(Thread.isMainThread)
        configuration = nil
        restart()
    }

    private func restart() {
        generation += 1
        let currentGeneration = generation
        timer?.cancel()
        timer = nil
        snapshot = PerformanceSnapshot()
        worker.async { [weak self] in self?.sampler = nil }
        guard let config = configuration, config.isActive, !sleeping else { return }

        let source = DispatchSource.makeTimerSource(queue: worker)
        source.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(250))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if self.sampler == nil { self.sampler = SystemMetricsSampler() }
            guard let sample = self.sampler?.sample(config) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.snapshot = sample
            }
        }
        timer = source
        source.resume()
    }
}
