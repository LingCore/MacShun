// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

struct PerformanceSettings: View {
    @Binding var config: PerformanceConfig
    @ObservedObject var monitor: PerformanceMonitor

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
                metric(.cpu, isOn: $config.cpu, detail: L("处理器总占用"))
                    .settingsAnchor(.cpuUsage)
                metric(.gpu, isOn: $config.gpu, detail: monitor.snapshot.gpuCount > 1 ? L("显示占用最高的一块 GPU") : L("图形处理器占用"))
                    .settingsAnchor(.gpuUsage)
                metric(.memory, isOn: $config.memory, detail: config.enabled && config.memory ?
                       (monitor.snapshot.memory?.description ?? L("应用、联动和压缩内存")) : L("应用、联动和压缩内存"))
                    .settingsAnchor(.memoryUsage)
                metric(.temperature, isOn: $config.temperature, detail: L("CPU / GPU 的最高传感器读数"))
                    .settingsAnchor(.chipTemperature)
            } header: {
                Text(L("菜单栏显示"))
            } footer: {
                Text(L("每 2 秒更新，关闭的项目不再采集。温度指芯片温度，非机身温度；部分机型可能无法读取 GPU 或温度。"))
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

    private func metric(_ metric: PerformanceMetric, isOn: Binding<Bool>, detail: String) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(metric.title)
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text(config.enabled && isOn.wrappedValue ? monitor.snapshot.text(metric) : "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }
}

enum PerformanceMenuBarImage {
    /// 每列固定宽度，1% → 100% 不挪动图标；模板图随菜单栏深浅和选中状态自动着色。
    static func make(snapshot: PerformanceSnapshot, metrics: [PerformanceMetric], needsAttention: Bool) -> NSImage {
        let columnWidth: CGFloat = 40, gap: CGFloat = 6, leading: CGFloat = 28
        let width = leading + CGFloat(metrics.count) * columnWidth + CGFloat(max(0, metrics.count - 1)) * gap
        let brand = BrandMark.menuBarImage(needsAttention: needsAttention)
        let image = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            brand.draw(in: NSRect(x: 0, y: 2, width: 18, height: 18))
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            for (index, metric) in metrics.enumerated() {
                let x = leading + CGFloat(index) * (columnWidth + gap)
                let label = NSAttributedString(string: metric.barLabel, attributes: [
                    .font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: NSColor.black, .paragraphStyle: paragraph
                ])
                let value = NSAttributedString(string: snapshot.text(metric, compact: true), attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.black, .paragraphStyle: paragraph
                ])
                label.draw(in: NSRect(x: x, y: 12, width: columnWidth, height: 11))
                value.draw(in: NSRect(x: x, y: 0, width: columnWidth, height: 14))
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
