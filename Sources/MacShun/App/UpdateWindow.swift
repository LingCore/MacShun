// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// “软件更新”窗口：正在检查、已是最新、有新版本（更新内容、立即更新）、下载进度、出错，都在这一个窗口里。
final class UpdateWindowController {
    static let shared = UpdateWindowController()

    private var window: NSWindow?

    /// activate：用户自己点的，把窗口切到前台。自动检查发现新版本时只把窗口摆到最上面，不抢正在打字的键盘
    func show(activate: Bool) {
        if window == nil {
            let view = UpdateView(updater: .shared) { [weak self] in self?.window?.close() }
            let host = NSHostingController(rootView: view)
            host.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: host)
            window.title = L("软件更新")
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        guard let window else { return }
        if activate {
            Foreground.bring(window)
        } else if !window.isVisible {
            window.orderFrontRegardless()
        }
    }
}

struct UpdateView: View {
    @ObservedObject var updater: Updater
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 60, height: 60)
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline)
                        .font(.title3.weight(.semibold))
                    if let detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                if updater.activity == .checking {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if let release = updater.available {
                ReleaseNotesBox(release: release)
            }
            if let problem = updater.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            controls
        }
        // 上面已经让出了标题栏的高度
        .padding(.horizontal, 22)
        .padding(.top, 4)
        .padding(.bottom, 20)
        .frame(width: 460)
    }

    private var current: String { AppVersion.current }

    private var headline: String {
        if updater.activity == .checking { return L("正在检查更新…") }
        if let release = updater.available { return L("Mac顺 %@ 可以更新了", release.version) }
        if updater.problem != nil { return L("检查更新失败") }
        return L("已经是最新版本")
    }

    private var detail: String? {
        if updater.activity == .checking { return nil }
        if updater.available != nil { return L("你现在用的是 %@。更新后设置和授权都会保留。", current) }
        if updater.problem != nil { return nil }
        return L("Mac顺 %@ 是目前最新的版本。", current)
    }

    @ViewBuilder
    private var controls: some View {
        switch updater.activity {
        case .checking:
            EmptyView()
        case .downloading(let fraction):
            HStack(spacing: 12) {
                ProgressView(value: fraction)
                Text(L("正在下载 %ld%%", Int((fraction * 100).rounded())))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(L("取消")) { updater.cancel() }
                    .nativeButtonHover()
            }
        case .installing:
            HStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.linear)
                Text(L("正在安装，装好后自动重新打开…"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        case .none:
            buttons
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 10) {
            if let release = updater.available {
                if !updater.isSkipped(release) {
                    Button(L("跳过这个版本")) {
                        updater.skip(release)
                        close()
                    }
                    .buttonStyle(HoverLinkStyle(color: .secondary))
                    .font(.callout)
                }
                Spacer()
                if updater.downloadedPackage != nil {
                    // 下载好了却装不上（签名不对、没有权限），再试也一样，让用户自己拖进“应用程序”
                    Button(L("手动安装")) { updater.installManually() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .nativeButtonHover()
                } else if updater.problem != nil {
                    Button(L("手动安装")) { updater.installManually() }
                        .nativeButtonHover()
                    Button(L("重试")) { updater.install() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .nativeButtonHover()
                } else {
                    Button(L("以后再说"), action: close)
                        .keyboardShortcut(.cancelAction)
                        .nativeButtonHover()
                    Button(L("立即更新")) { updater.install() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .nativeButtonHover()
                }
            } else if updater.problem != nil {
                Spacer()
                Button(L("去 GitHub 下载")) { updater.installManually() }
                    .nativeButtonHover()
                Button(L("重试")) { updater.check(manual: true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .nativeButtonHover()
            } else {
                Spacer()
                Button(L("好"), action: close)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .nativeButtonHover()
            }
        }
    }
}

/// 新版本的更新内容：开头那句话和“新功能”的每一条，界面是什么语言就显示哪种
private struct ReleaseNotesBox: View {
    let release: ReleaseInfo

    var body: some View {
        let chinese = AppLanguage.isChinese
        let summary = ReleaseNotes.summary(release.notes, chinese: chinese)
        let highlights = ReleaseNotes.highlights(release.notes, chinese: chinese)
        VStack(alignment: .leading, spacing: 10) {
            if !summary.isEmpty || !highlights.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !summary.isEmpty {
                            Text(Self.markdown(summary))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(Array(highlights.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(item.symbol.isEmpty ? "•" : item.symbol)
                                    .frame(width: 18)
                                Text(Self.markdown(item.text))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))
                )
            }
            Button(L("在 GitHub 上查看完整说明")) { NSWorkspace.shared.open(release.pageURL) }
                .buttonStyle(.hoverLink)
                .font(.callout)
        }
    }

    /// 发布说明里的 **粗体**、`代码`、链接
    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
