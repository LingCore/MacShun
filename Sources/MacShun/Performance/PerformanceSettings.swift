// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

struct PerformanceSettings: View {
    @Binding var config: PerformanceConfig
    let monitor: PerformanceMonitor
    var windowVisible = true

    var body: some View {
        SearchableForm {
            Section {
                SettingsPageHeader(tab: .performance, subtitle: L("在菜单栏查看占用和温度")) {
                    Toggle("", isOn: $config.enabled)
                        .labelsHidden()
                        .accessibilityLabel(L("启用性能监控"))
                }
                .settingsAnchor(.performanceEnabled)
            }

            Section {
                Picker(L("菜单栏样式"), selection: $config.menuBarStyle) {
                    ForEach(PerformanceMenuBarStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .settingsAnchor(.performanceMenuBarStyle)

                Toggle(L("合并 CPU 和 GPU"), isOn: $config.combineProcessors)
                    .disabled(!config.canCombineProcessors)
                    .settingsAnchor(.combinePerformanceProcessors)

                Picker(L("刷新间隔"), selection: $config.refreshInterval) {
                    ForEach(PerformanceRefreshInterval.allCases, id: \.self) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
                .pickerStyle(.menu)
                .settingsAnchor(.performanceRefreshInterval)
            } footer: {
                if let styleHint {
                    Text(styleHint).settingsFooter()
                }
            }
            .disabled(!config.enabled)

            Section {
                metric(.cpu, isOn: $config.cpu) {
                    Text(L("处理器总占用"))
                }
                .settingsAnchor(.cpuUsage)
                metric(.gpu, isOn: $config.gpu) {
                    if config.enabled && config.gpu && windowVisible {
                        LiveGPUDetail(monitor: monitor)
                    } else {
                        Text(monitor.snapshot.gpuCount > 1 ? L("显示占用最高的一块 GPU") : L("图形处理器占用"))
                    }
                }
                .settingsAnchor(.gpuUsage)
                metric(.memory, isOn: $config.memory) {
                    if config.enabled && config.memory && windowVisible {
                        LiveMemoryDetail(monitor: monitor)
                    } else {
                        Text(config.enabled && config.memory
                             ? (monitor.snapshot.memory?.description ?? L("应用、联动和压缩内存"))
                             : L("应用、联动和压缩内存"))
                    }
                }
                .settingsAnchor(.memoryUsage)
                metric(.temperature, isOn: $config.temperature) {
                    Text(L("CPU / GPU 的最高传感器读数"))
                }
                .settingsAnchor(.chipTemperature)
            } header: {
                Text(L("菜单栏显示"))
            } footer: {
                Text(L("关闭的项目不再采集；间隔越长越省电，开启低电量模式时会自动进一步放缓。温度指芯片温度，非机身温度；部分机型可能无法读取 GPU 或温度。"))
                    .settingsFooter()
            }
            .disabled(!config.enabled)

            Section {
                Button(L("打开活动监视器")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
                .nativeButtonHover()
            } footer: {
                Text(L("想看哪个程序占用最多，可以打开活动监视器。内存占用不包含可回收的文件缓存。"))
                    .settingsFooter()
            }
        }
    }

    private var styleHint: String? {
        let combined = config.canCombineProcessors && config.combineProcessors
        switch config.menuBarStyle {
        case .text:
            return L("图表样式可将 CPU 和 GPU 放在同一组。")
        case .icons:
            return combined ? L("芯片内左侧为 CPU，右侧为 GPU。悬停菜单栏可查看读数。")
                            : L("悬停菜单栏可查看读数。")
        case .trend:
            return combined ? L("实线为 CPU，虚线为 GPU。") : nil
        }
    }

    private func metric<Detail: View>(
        _ metric: PerformanceMetric,
        isOn: Binding<Bool>,
        @ViewBuilder detail: () -> Detail
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(metric.title)
                    detail()
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Group {
                    if config.enabled && isOn.wrappedValue {
                        if windowVisible {
                            LiveMetricReadout(monitor: monitor, metric: metric)
                        } else {
                            Text(monitor.snapshot.text(metric))
                        }
                    } else {
                        Text("—")
                    }
                }
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 56, alignment: .trailing)
                .fixedSize()
            }
        }
    }
}

/// 仅在设置窗口可见且对应指标开启时订阅实时读数，避免整个表单每 2 秒重建和触发布局约束重算。
private struct LiveMetricReadout: View {
    @ObservedObject var monitor: PerformanceMonitor
    let metric: PerformanceMetric

    var body: some View {
        Text(monitor.snapshot.text(metric))
    }
}

private struct LiveGPUDetail: View {
    @ObservedObject var monitor: PerformanceMonitor

    var body: some View {
        Text(monitor.snapshot.gpuCount > 1 ? L("显示占用最高的一块 GPU") : L("图形处理器占用"))
    }
}

private struct LiveMemoryDetail: View {
    @ObservedObject var monitor: PerformanceMonitor

    var body: some View {
        Text(monitor.snapshot.memory?.description ?? L("应用、联动和压缩内存"))
    }
}
