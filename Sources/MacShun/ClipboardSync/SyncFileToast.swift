// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

/// 收到远端设备复制的文件时，在屏幕右上角弹出的不抢焦点轻量浮条。
/// 悬停时自动暂停倒计时，不操作 6 秒后静默消失，不占用网络或磁盘。
@MainActor
final class SyncFileToastController {
    enum Phase: Equatable {
        case offer
        case downloading(percent: Int)
        case done(String)
        case failed(String)
    }

    @MainActor
    final class Model: ObservableObject {
        @Published var info: RemoteFileInfo?
        @Published var platform: SyncPlatform = .other
        @Published var phase: Phase = .offer
        @Published var isHovered = false
    }

    private let model = Model()
    private var panel: ToastPanel?
    private var dismissTask: Task<Void, Never>?
    private var activeTask: Task<Void, Never>?

    var onReceiveAndCopy: ((RemoteFileInfo, @escaping (Int) -> Void) async throws -> Void)?
    var onReceiveAndSaveToDownloads: ((RemoteFileInfo, @escaping (Int) -> Void) async throws -> Void)?
    var onCancelTransfer: ((UUID) -> Void)?

    deinit {
        dismissTask?.cancel()
        activeTask?.cancel()
    }

    func show(info: RemoteFileInfo, platform: SyncPlatform) {
        // 正在下载其他文件时不打断当前进度条。
        if case .downloading = model.phase { return }
        dismissTask?.cancel()
        activeTask?.cancel()
        model.info = info
        model.platform = platform
        model.phase = .offer
        model.isHovered = false
        presentPanel()
        scheduleAutoDismiss(after: 6)
    }

    func hide() {
        dismissTask?.cancel()
        dismissTask = nil
        activeTask?.cancel()
        activeTask = nil
        panel?.orderOut(nil)
        model.info = nil
    }

    private func presentPanel() {
        let panel = ensurePanel()
        let screen = WindowPlacement.pointerScreen(at: NSEvent.mouseLocation) ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = 340
        let height: CGFloat = 96
        let margin: CGFloat = 16
        let origin = NSPoint(x: visible.maxX - width - margin, y: visible.maxY - height - margin)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        panel.orderFrontRegardless()
    }

    private func ensurePanel() -> ToastPanel {
        if let panel { return panel }
        let p = ToastPanel()
        let view = SyncFileToastView(
            model: model,
            onHoverChanged: { [weak self] hovering in self?.handleHover(hovering) },
            onCopy: { [weak self] in self?.startReceive(saveToDownloads: false) },
            onSave: { [weak self] in self?.startReceive(saveToDownloads: true) },
            onCancel: { [weak self] in self?.cancelDownload() },
            onDismiss: { [weak self] in self?.hide() }
        )
        let host = NSHostingView(rootView: view)
        host.safeAreaRegions = []
        host.sizingOptions = []
        p.contentView = host
        self.panel = p
        return p
    }

    private func handleHover(_ hovering: Bool) {
        model.isHovered = hovering
        if hovering {
            dismissTask?.cancel()
            dismissTask = nil
        } else {
            switch model.phase {
            case .offer: scheduleAutoDismiss(after: 3.5)
            case .done, .failed: scheduleAutoDismiss(after: 2)
            case .downloading: break
            }
        }
    }

    private func startReceive(saveToDownloads: Bool) {
        guard let info = model.info else { return }
        dismissTask?.cancel()
        dismissTask = nil
        activeTask?.cancel()
        model.phase = .downloading(percent: 0)

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                let onProgress: (Int) -> Void = { [weak self] percent in
                    guard let self, case .downloading = self.model.phase else { return }
                    self.model.phase = .downloading(percent: percent)
                }
                if saveToDownloads {
                    try await self.onReceiveAndSaveToDownloads?(info, onProgress)
                    guard !Task.isCancelled else { return }
                    self.model.phase = .done(L("已保存到“下载”文件夹"))
                } else {
                    try await self.onReceiveAndCopy?(info, onProgress)
                    guard !Task.isCancelled else { return }
                    self.model.phase = .done(L("已复制到剪贴板，按 ⌘V 粘贴"))
                }
                self.scheduleAutoDismiss(after: 2.5)
            } catch {
                guard !Task.isCancelled else { return }
                self.model.phase = .failed(error.localizedDescription)
                self.scheduleAutoDismiss(after: 3.5)
            }
        }
    }

    private func cancelDownload() {
        if let id = model.info?.transferID {
            onCancelTransfer?(id)
        }
        hide()
    }

    private func scheduleAutoDismiss(after seconds: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.model.isHovered else { return }
            if case .downloading = self.model.phase { return }
            self.hide()
        }
    }
}

private final class ToastPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 96),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct SyncFileToastView: View {
    @ObservedObject var model: SyncFileToastController.Model
    let onHoverChanged: (Bool) -> Void
    let onCopy: () -> Void
    let onSave: () -> Void
    let onCancel: () -> Void
    let onDismiss: () -> Void

    private var summaryText: String {
        guard let info = model.info else { return "" }
        let names = info.topLevelNames
        let size = SyncPathSanitizer.formatBytes(info.totalBytes)
        if names.count <= 1 {
            return "\(names.first ?? L("文件")) · \(size)"
        }
        return L("%@ 等 %ld 项 · %@", names[0], names.count, size)
    }

    var body: some View {
        ZStack {
            VisualEffectBackground()
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)

            if let info = model.info {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: model.platform.displaySymbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24, height: 24)
                            .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(L("来自 %@ 的文件", info.originDeviceName))
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Text(summaryText)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 4)
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .help(L("忽略"))
                    }

                    bottomBar
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering in
            onHoverChanged(hovering)
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        switch model.phase {
        case .offer:
            HStack(spacing: 8) {
                Button(L("接收并复制"), action: onCopy)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button(L("存到下载"), action: onSave)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer(minLength: 0)
            }

        case .downloading(let percent):
            HStack(spacing: 8) {
                ProgressView(value: Double(percent), total: 100)
                    .controlSize(.small)
                Text("\(percent)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                Button(L("取消"), action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }

        case .done(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .lineLimit(1)

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(1)
        }
    }
}
