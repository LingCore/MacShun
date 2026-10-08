// SPDX-License-Identifier: MIT

import Foundation

/// 当前在前台的应用。
struct AppIdentity: Equatable {
    var bundleID: String?
    var name: String?
}

/// 应用的类别，决定按键怎么改写。
enum AppKind: Equatable {
    case normal
    /// 终端：不改写 Ctrl 组合键，改用 Ctrl+Shift+C/V 复制粘贴（K5）。
    case terminal
    case finder
    /// 远程桌面、虚拟机，以及用户排除的应用：不改写任何按键（K6）。
    case excluded
}

/// 各类应用的名单。
enum AppCatalog {
    static let finder = "com.apple.finder"

    static let terminals: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "dev.warp.Warp-Preview",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "io.alacritty",
        "com.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "com.mitchellh.ghostty",
        "org.tabby",
    ]

    /// 远程桌面和虚拟机（K6）。
    static let remoteAndVM: Set<String> = [
        // 微软远程桌面，新名字叫 Windows App
        "com.microsoft.rdc.macos",
        "com.microsoft.rdc.mac",
        "com.microsoft.rdc",
        "com.microsoft.rdc.osx.beta",
        // 虚拟机
        "com.parallels.desktop.console",
        "com.parallels.desktop",
        "com.parallels.vm",
        "com.vmware.fusion",
        "org.virtualbox.app.VirtualBoxVM",
        "com.utmapp.UTM",
        // 远程控制
        "com.apple.ScreenSharing",
        "com.teamviewer.TeamViewer",
        "com.philandro.anydesk",
        "com.carriez.rustdesk",
        "com.carriez.flutterHbb",
        "com.p5sys.jump.mac.viewer",
        "com.p5sys.jump.mac.viewer.web",
        "com.realvnc.vncviewer",
        "com.realvnc.rvncconnect",
        "com.edovia.screens.5",
        "com.edovia.screens.mac",
        // 国产远程工具
        "com.youqu.todesk.mac",           // ToDesk
        "com.oray.sunlogin.macclient",    // 向日葵客户端
        "com.oray.remote",                // 向日葵控制端
        "com.netease.uuremote",           // UU远程
    ]

    /// 以这些前缀开头的应用也当作虚拟机，例如 Parallels 融合模式下的每个 Windows 程序。
    static let remoteAndVMPrefixes: [String] = [
        "com.parallels.winapp.",
        "com.vmware.proxyApp.",
    ]

    /// 应用标识不确定时，按应用名称再认一遍。
    static let remoteAndVMNameKeywords: [String] = [
        "ToDesk",
        "向日葵",
        "Sunlogin",
        "SunloginClient",
        "UU远程",
        "UU Remote",
        "网易UU远程",
        "TeamViewer",
        "AnyDesk",
        "RustDesk",
        "Parallels Desktop",
        "VMware Fusion",
        "VirtualBox",
        "Microsoft Remote Desktop",
    ]

    /// 名称必须完全相同才算，避免误判。
    static let remoteAndVMExactNames: Set<String> = [
        "Windows App",
        "UTM",
    ]

    /// 浏览器：网页里 ⌘← 是“后退”，所以只有确定光标在输入框里时才改写 Home/End。
    static let browsers: Set<String> = [
        "com.apple.Safari",
        "com.apple.SafariTechnologyPreview",
        "com.google.Chrome",
        "com.google.Chrome.beta",
        "com.google.Chrome.dev",
        "com.google.Chrome.canary",
        "com.microsoft.edgemac",
        "com.microsoft.edgemac.Beta",
        "com.microsoft.edgemac.Dev",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "org.mozilla.nightly",
        "com.brave.Browser",
        "company.thebrowser.Browser",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        "org.chromium.Chromium",
        "com.kagi.kagimacOS",
        "net.qihoo.360browser",
        "com.tencent.qqbrowserappmac",
        "com.tencent.QQBrowser",
    ]

    /// 截图快捷键是 ⌃⌘A 的聊天软件：微信、QQ（K9）。
    static let chatAppsWithControlCommandAScreenshot: Set<String> = [
        "com.tencent.xinWeChat",
        "com.tencent.qq",
    ]

    /// 搜狗输入法的输入源前缀。它用 ⌃. 切换中英文标点，和 Windows 版的 Ctrl+. 一样（K9）。
    static let sogouInputSourcePrefix = "com.sogou.inputmethod"

    /// 本身就支持鼠标侧键前进后退的应用，侧键原样交给它们（M4）。
    static let nativeSideButtonPrefixes: [String] = [
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "org.mozilla.",
        "com.brave.Browser",
        "company.thebrowser.",
        "com.vivaldi.",
        "com.operasoftware.",
        "org.chromium.",
        "com.microsoft.VSCode",
        "com.visualstudio.code",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.jetbrains.",
    ]

    static func isRemoteOrVM(_ app: AppIdentity) -> Bool {
        if let id = app.bundleID {
            if remoteAndVM.contains(id) { return true }
            if remoteAndVMPrefixes.contains(where: { id.hasPrefix($0) }) { return true }
        }
        if let name = app.name {
            if remoteAndVMExactNames.contains(name) { return true }
            if remoteAndVMNameKeywords.contains(where: { name.localizedCaseInsensitiveContains($0) }) { return true }
        }
        return false
    }

    static func kind(of app: AppIdentity, userExcluded: [String]) -> AppKind {
        if let id = app.bundleID, userExcluded.contains(id) { return .excluded }
        if isRemoteOrVM(app) { return .excluded }
        guard let id = app.bundleID else { return .normal }
        if id == finder { return .finder }
        if terminals.contains(id) { return .terminal }
        return .normal
    }

    static func isBrowser(_ app: AppIdentity) -> Bool {
        guard let id = app.bundleID else { return false }
        return browsers.contains(id)
    }

    static func handlesSideButtonsNatively(_ app: AppIdentity) -> Bool {
        guard let id = app.bundleID else { return false }
        return nativeSideButtonPrefixes.contains(where: { id.hasPrefix($0) })
    }
}
