// SPDX-License-Identifier: MIT

import AppKit
import ServiceManagement

/// 本程序以前叫 Win顺（WinShun）。应用标识 io.github.lingcore.winshun 和签名证书都沿用改名前的，
/// 所以权限和设置不用重来；这里只把旧名字留下的东西接过来。
enum FormerName {
    /// ~/Library/Application Support/WinShun（剪贴板历史、内容索引）改名为 MacShun。
    /// 要在第一次用到剪贴板历史和内容索引之前调用。
    static func moveDataFolder() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appendingPathComponent("WinShun", isDirectory: true)
        let new = support.appendingPathComponent("MacShun", isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        do {
            try fm.moveItem(at: old, to: new)
            Log.app.notice("数据文件夹从 WinShun 改名为 MacShun")
        } catch {
            Log.app.error("数据文件夹改名失败：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 开着开机自启的话，登记的可能还是旧的 Win顺.app：重新登记一次，指向现在的程序。只做一次。
    static func refreshLoginItem() {
        let key = "formerName.loginItemRefreshed"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        guard SMAppService.mainApp.status == .enabled else { return }
        do {
            try SMAppService.mainApp.unregister()
            try SMAppService.mainApp.register()
            Log.app.notice("开机自启已重新登记到 \(Bundle.main.bundlePath, privacy: .public)")
        } catch {
            Log.app.error("重新登记开机自启失败：\(error.localizedDescription, privacy: .public)")
        }
    }
}
