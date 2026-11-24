// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

/// 剪贴板设置页中的“跨设备剪贴板共享”区块。
/// 不使用 @State（兼容仅装 Command Line Tools 的编译环境），临时状态统一放在 @StateObject 中。
struct ClipboardSyncSettingsSections: View {
    @Binding var config: ClipboardSyncConfig
    @ObservedObject var sync: ClipboardSyncService
    let clipboardEnabled: Bool
    let onCopyInviteCode: (String) -> Void

    @EnvironmentObject private var selection: SettingsSelection
    @StateObject private var ui = SyncSettingsUIState()

    private var defaultHostName: String {
        let host = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return host.isEmpty ? "Mac" : host
    }

    private var onlineIDs: Set<String> {
        Set(sync.connectedPeers.map(\.deviceID))
    }

    /// 局域网发现但尚未加入本群组的设备（已可配对的排在前面）。
    private var pairablePeers: [DiscoveredSyncPeer] {
        sync.discoveredPeers
            .filter { $0.groupID != sync.groupID }
            .sorted { a, b in
                if a.pairingOpen != b.pairingOpen { return a.pairingOpen }
                return a.deviceName.localizedStandardCompare(b.deviceName) == .orderedAscending
            }
    }

    var body: some View {
        Section {
            Toggle(isOn: $config.enabled) {
                Text(L("跨设备剪贴板共享"))
                Text(L("与局域网或虚拟局域网内的 Win顺、Mac顺 加密共享文字、图片和文件"))
            }
            .settingsAnchor(.clipboardSyncEnabled)

            if config.enabled {
                statusRow
                if let error = sync.statusMessage {
                    InfoRow(
                        symbol: "exclamationmark.triangle",
                        title: L("共享服务异常"),
                        detail: error
                    )
                }
                if let feedback = ui.feedback {
                    Text(feedback)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(L("跨设备共享"))
        }
        .disabled(!clipboardEnabled)

        if config.enabled {
            Section(L("我的设备")) {
                if let pairing = sync.activePairing {
                    pairingCard(pairing)
                }

                if !sync.knownPeers.isEmpty {
                    ForEach(sync.knownPeers) { peer in
                        knownPeerRow(peer)
                    }
                }

                if !pairablePeers.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("附近的设备"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        ForEach(pairablePeers) { peer in
                            discoveredPeerRow(peer)
                        }
                    }
                }

                addDeviceBlock
            }
            .disabled(!clipboardEnabled)

            Section(L("同步内容")) {
                Toggle(L("同步文字和链接"), isOn: $config.syncText)
                Toggle(L("同步图片和截图"), isOn: $config.syncImages)
                Toggle(L("同步文件和文件夹"), isOn: $config.syncFiles)
                if config.syncFiles {
                    Toggle(isOn: $config.notifyIncomingFiles) {
                        Text(L("收到文件时在屏幕右上角提示接收"))
                        Text(L("不自动下载，点击后再接收；不点几秒后自动消失，也可随时在剪贴板历史里取用"))
                    }
                }
            }
            .disabled(!clipboardEnabled)

            Section {
                DisclosureGroup(L("高级设置"), isExpanded: $ui.showAdvanced) {
                    advancedContent
                }
            }
            .disabled(!clipboardEnabled)
            .onAppear { expandAdvancedIfNeeded(selection.highlight) }
            .onChange(of: selection.highlight) { expandAdvancedIfNeeded(selection.highlight) }
        }
    }

    // MARK: - 顶部状态

    private var statusRow: some View {
        let count = sync.connectedPeers.count
        let dotColor: Color = sync.isPaused ? .orange : (count > 0 ? .green : .secondary.opacity(0.5))
        let text: String = {
            if sync.isPaused { return L("已暂停共享") }
            if count > 0 { return L("已连接 %ld 台设备", count) }
            return L("等待设备连接")
        }()

        return HStack(spacing: 8) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            Text(text)
            Spacer()
            Button(sync.isPaused ? L("恢复共享") : L("暂停共享")) {
                sync.togglePause()
            }
            .nativeButtonHover()
        }
    }

    // MARK: - 添加电脑（万能连接框：自动识别 IP 或邀请码，跨组自动转 6 位码配对）

    private var addDeviceBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField(L("输入对方 IP（如 172.16.30.81）或粘贴邀请码"), text: $ui.connectInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { handleSmartConnect() }
                Button(L("连接")) {
                    handleSmartConnect()
                }
                .buttonStyle(.borderedProminent)
                .disabled(ui.connectInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sync.activePairing != nil)
            }
            .settingsAnchor(.clipboardSyncDevices)

            HStack(spacing: 8) {
                Text(L("同局域网设备会自动出现；跨网段直接输 IP 即可配对。加第 3、4 台电脑只需连组内任意一台。"))
                    .settingsFooter()
                Spacer(minLength: 8)
                Button(L("复制邀请码")) {
                    let code = sync.makeInviteCode()
                    onCopyInviteCode(code)
                    ui.show(L("已复制邀请码，在另一台电脑的 Win顺 或 Mac顺 粘贴连接即可"))
                }
                .controlSize(.small)
                .nativeButtonHover()
            }
        }
    }

    // MARK: - 6 位码配对确认卡片

    private func pairingCard(_ pairing: ActivePairingSession) -> some View {
        let code = formatSAS(pairing.sasCode)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: pairing.peerPlatform.displaySymbol)
                    .foregroundStyle(Color.accentColor)
                Text(pairing.direction == .incoming
                     ? L("“%@”请求加入你的剪贴板共享", pairing.peerDeviceName)
                     : L("正在与“%@”配对", pairing.peerDeviceName))
                    .font(.headline)
            }
            HStack(spacing: 12) {
                Text(L("请核对两台电脑上的 6 位配对码是否一致："))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(code)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack(spacing: 8) {
                if pairing.direction == .incoming {
                    Button(L("确认一致并允许")) {
                        sync.approveActivePairing()
                        ui.show(L("已允许“%@”加入共享", pairing.peerDeviceName))
                    }
                    .buttonStyle(.borderedProminent)
                    Button(L("拒绝")) {
                        sync.rejectActivePairing()
                    }
                } else {
                    ProgressView().controlSize(.small)
                    Text(L("请在对方电脑点击确认…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("取消")) {
                        sync.cancelActivePairing()
                    }
                }
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 设备行

    private func knownPeerRow(_ peer: KnownSyncPeer) -> some View {
        let online = onlineIDs.contains(peer.deviceID)
        let overrideValue = config.deviceAutoWriteOverrides[peer.deviceID]
        return HStack(spacing: 8) {
            Image(systemName: peer.platform.displaySymbol)
                .foregroundStyle(online ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(peer.deviceName)
                    Circle()
                        .fill(online ? Color.green : Color.secondary.opacity(0.35))
                        .frame(width: 6, height: 6)
                    Text(online ? L("在线") : L("离线"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let host = peer.lastHost, !host.isEmpty {
                    Text(host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            Menu {
                Button(L("跟随全局设置")) {
                    config.deviceAutoWriteOverrides.removeValue(forKey: peer.deviceID)
                }
                Button(L("自动写入剪贴板")) {
                    config.deviceAutoWriteOverrides[peer.deviceID] = true
                }
                Button(L("仅加入历史，不覆盖剪贴板")) {
                    config.deviceAutoWriteOverrides[peer.deviceID] = false
                }
            } label: {
                Text(overrideValue == nil ? L("跟随全局")
                     : (overrideValue == true ? L("自动写入") : L("仅入历史")))
                    .font(.caption)
            }
            .fixedSize()
            Button(L("移除"), role: .destructive) {
                confirmRemovePeer(peer)
            }
            .controlSize(.small)
            .nativeButtonHover()
        }
    }

    private func discoveredPeerRow(_ peer: DiscoveredSyncPeer) -> some View {
        HStack(spacing: 8) {
            Image(systemName: peer.platform.displaySymbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(peer.deviceName)
                Text(peer.host)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button(L("连接")) {
                startConnectOrPair(endpoint: peer.endpoint, label: peer.deviceName)
            }
            .controlSize(.small)
            .nativeButtonHover()
            .disabled(sync.activePairing != nil)
        }
    }

    // MARK: - 折叠的高级设置

    @ViewBuilder
    private var advancedContent: some View {
        LabeledContent(L("本机名称")) {
            TextField(defaultHostName, text: $config.deviceName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
        }

        LabeledContent(L("本机地址")) {
            HStack(spacing: 8) {
                Text(sync.localAddressDisplay ?? L("端口 %ld", Int(sync.listenPort)))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(L("群组 %@", sync.shortGroupID))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .help(L("同组设备的群组标识前 8 位应完全一致"))
                if let address = sync.localAddressDisplay {
                    Button(L("复制")) {
                        onCopyInviteCode(address)
                        ui.show(L("已复制本机地址 %@", address))
                    }
                    .controlSize(.small)
                    .nativeButtonHover()
                }
                Button(L("重新扫描")) {
                    sync.refreshDiscoveryAndReconnect()
                    ui.show(L("已重新扫描局域网并尝试重连设备"))
                }
                .controlSize(.small)
                .nativeButtonHover()
            }
        }

        Toggle(isOn: $config.autoWritePasteboard) {
            Text(L("收到内容时自动写入系统剪贴板"))
            Text(L("关闭时，其他设备复制的文字和图片只加入剪贴板历史，不覆盖本机当前剪贴板"))
        }
        .settingsAnchor(.clipboardSyncAutoWrite)

        Toggle(isOn: $config.allowPairingRequests) {
            Text(L("允许新设备发起 6 位码配对"))
            Text(L("关闭后不会弹出陌生设备的配对请求，需要配对时可点下方临时开放"))
        }

        if !config.allowPairingRequests {
            HStack(spacing: 8) {
                if sync.isPairingWindowOpen {
                    Button(L("关闭临时配对窗口")) { sync.closePairingWindow() }
                        .nativeButtonHover()
                    Text(L("2 分钟内允许新设备发起配对…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(L("临时开放配对 2 分钟")) {
                        sync.openPairingWindow()
                        ui.show(L("已临时开放配对 2 分钟"))
                    }
                    .nativeButtonHover()
                }
            }
        }

        if config.syncFiles {
            Picker(L("小文件自动预取"), selection: $config.autoDownloadFileLimitMB) {
                Text(L("仅手动接收")).tag(0)
                Text(L("10 MB 以内")).tag(10)
                Text(L("20 MB 以内")).tag(20)
                Text(L("50 MB 以内")).tag(50)
                Text(L("100 MB 以内")).tag(100)
            }
            .settingsAnchor(.clipboardSyncFiles)
            Text(L("默认仅同步文件清单，需要时再按需接收；设置上限后，不超过该体积的小文件会自动后台下载并写入剪贴板。"))
                .settingsFooter()
        }

        if !config.manualPeers.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("已保存的手动设备地址（Tailscale / 跨网段）"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .settingsAnchor(.clipboardSyncManualPeers)
                ForEach(config.manualPeers, id: \.self) { addr in
                    HStack(spacing: 8) {
                        Text(addr).monospacedDigit()
                        Spacer()
                        Button(L("测试连接")) {
                            if let ep = SyncEndpoint.parse(addr) {
                                testManualPeer(ep)
                            }
                        }
                        .controlSize(.small)
                        .nativeButtonHover()
                        Button(L("移除")) {
                            config.manualPeers.removeAll { $0 == addr }
                        }
                        .controlSize(.small)
                        .nativeButtonHover()
                    }
                }
            }
        }

        LabeledContent(L("接收文件缓存")) {
            HStack(spacing: 8) {
                Text(SyncPathSanitizer.formatBytes(sync.cacheBytes))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button(L("打开缓存目录")) {
                    try? sync.cacheManager.ensureRootDirectory()
                    NSWorkspace.shared.activateFileViewerSelecting([sync.cacheManager.rootDirectory])
                }
                .nativeButtonHover()
                Button(L("清空缓存")) {
                    sync.clearCache()
                    ui.show(L("已清空接收文件缓存"))
                }
                .nativeButtonHover()
                .disabled(sync.cacheBytes == 0)
            }
        }

        HStack {
            Spacer()
            Button(L("重置群组密钥…"), role: .destructive) {
                confirmResetGroup()
            }
            .controlSize(.small)
            .nativeButtonHover()
        }
    }

    // MARK: - 交互逻辑

    private func expandAdvancedIfNeeded(_ id: SettingsItem.ID?) {
        switch id {
        case .clipboardSyncAutoWrite, .clipboardSyncFiles, .clipboardSyncManualPeers:
            if !ui.showAdvanced { ui.showAdvanced = true }
        default:
            break
        }
    }

    private func formatSAS(_ raw: String) -> String {
        guard raw.count == 6 else { return raw }
        let mid = raw.index(raw.startIndex, offsetBy: 3)
        return "\(raw[..<mid]) \(raw[mid...])"
    }

    /// 万能连接入口：自动识别邀请码或 IP/主机名（免写端口），不在同组时自动转 6 位码配对。
    private func handleSmartConnect() {
        let raw = ui.connectInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        if ShunSyncCrypto.decodeInviteCode(raw) != nil {
            let hint = sync.joinWithInviteCode(raw)
            if let hint, let ep = SyncEndpoint.parse(hint), !config.manualPeers.contains(ep.formatted) {
                config.manualPeers.append(ep.formatted)
            }
            ui.connectInput = ""
            ui.show(L("已加入共享组，正在连接设备…"))
            return
        }

        guard let endpoint = SyncEndpoint.parse(raw) else {
            ui.show(L("格式不对，请输入对方 IP（如 172.16.30.81）或粘贴完整邀请码"))
            return
        }
        let formatted = endpoint.formatted
        if !config.manualPeers.contains(formatted) {
            config.manualPeers.append(formatted)
        }
        ui.connectInput = ""
        startConnectOrPair(endpoint: endpoint, label: formatted)
    }

    private func startConnectOrPair(endpoint: SyncEndpoint, label: String) {
        ui.show(L("正在连接 %@…", label))
        Task {
            let message = await sync.connectOrPair(endpoint: endpoint)
            ui.show(message)
        }
    }

    private func testManualPeer(_ endpoint: SyncEndpoint) {
        ui.show(L("正在连接 %@…", endpoint.formatted))
        Task {
            let result = await sync.connectManuallyWithDiagnosis(endpoint)
            ui.show(result)
        }
    }

    private func confirmRemovePeer(_ peer: KnownSyncPeer) {
        let alert = NSAlert()
        alert.messageText = L("移除“%@”并更换群组密钥？", peer.deviceName)
        alert.informativeText = L("这台设备将无法再访问剪贴板共享，其他当前在线的设备会自动更新为新密钥。")
        alert.addButton(withTitle: L("移除")).hasDestructiveAction = true
        alert.addButton(withTitle: L("取消"))
        if alert.runModal() == .alertFirstButtonReturn {
            config.deviceAutoWriteOverrides.removeValue(forKey: peer.deviceID)
            sync.removeAndRotatePeer(deviceID: peer.deviceID)
            ui.show(L("已移除“%@”并更新群组密钥", peer.deviceName))
        }
    }

    private func confirmResetGroup() {
        let alert = NSAlert()
        alert.messageText = L("重置本机群组密钥？")
        alert.informativeText = L("重置后会断开所有已配对设备，需要重新配对或分发新邀请码。")
        alert.addButton(withTitle: L("重置")).hasDestructiveAction = true
        alert.addButton(withTitle: L("取消"))
        if alert.runModal() == .alertFirstButtonReturn {
            config.deviceAutoWriteOverrides = [:]
            sync.resetGroupKey()
            ui.show(L("已生成新的群组密钥"))
        }
    }
}

@MainActor
private final class SyncSettingsUIState: ObservableObject {
    @Published var connectInput = ""
    @Published var showAdvanced = false
    @Published var feedback: String?
    private var clearTask: Task<Void, Never>?

    func show(_ message: String) {
        clearTask?.cancel()
        feedback = message
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            guard let self, !Task.isCancelled, self.feedback == message else { return }
            self.feedback = nil
        }
    }
}
