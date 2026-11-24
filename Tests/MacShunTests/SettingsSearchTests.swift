// SPDX-License-Identifier: MIT

import Testing
@testable import MacShun

@Suite("设置搜索")
struct SettingsSearchTests {
    private func first(_ query: String) -> SettingsItem.ID? {
        SettingsItem.search(query).first?.id
    }

    private func finds(_ query: String, _ id: SettingsItem.ID) -> Bool {
        SettingsItem.search(query).contains { $0.id == id }
    }

    @Test func chineseTitle() {
        #expect(first("指针速度") == .pointerSpeed)
        #expect(finds("缩放", .ctrlWheelZoom))
    }

    @Test func pinyinAndInitials() {
        #expect(finds("suo", .ctrlWheelZoom))
        #expect(finds("zzsd", .pointerSpeed))
        #expect(finds("dlsz", .launchAtLogin))
    }

    @Test func keywords() {
        #expect(finds("Ctrl+C", .ctrlAsCommand))
        #expect(finds("Ctrl+V", .ctrlAsCommand))
        #expect(finds("复制", .ctrlAsCommand))
        #expect(finds("Home", .textNavigation))
        #expect(finds("terminal", .terminal))
        #expect(finds("开机", .launchAtLogin))
        #expect(finds("Alt+Tab", .systemShortcuts))
        #expect(finds("F2", .finderShortcuts))
        #expect(finds("Option+V", .clipboardEnabled))
        #expect(finds("⌘V", .clipboardEnabled))
        #expect(finds("language", .language))
        #expect(finds("更新", .version))
        #expect(finds("update", .autoUpdate))
        #expect(finds("版本", .version))
    }

    @Test func titlesComeFirst() {
        // 标题里有的排在只是关键词里有的前面
        #expect(first("剪贴板历史") == .clipboardEnabled)
    }

    @Test func performanceReadings() {
        #expect(first("CPU") == .cpuUsage)
        #expect(first("GPU") == .gpuUsage)
        #expect(first("内存") == .memoryUsage)
        #expect(finds("温度", .chipTemperature))
        #expect(finds("ram", .memoryUsage))
        #expect(finds("菜单栏", .performanceEnabled))
        #expect(first("刷新间隔") == .performanceRefreshInterval)
        #expect(finds("refresh", .performanceRefreshInterval))
    }

    @Test func noMatch() {
        #expect(SettingsItem.search("zzzzqqq").isEmpty)
        #expect(SettingsItem.search("  ").isEmpty)
    }

    @Test func idsAreUnique() {
        #expect(Set(SettingsItem.all.map(\.id)).count == SettingsItem.all.count)
    }
}
