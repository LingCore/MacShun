# Win顺（WinShun）接入跨设备剪贴板共享指南

本文档面向 **Win顺（`LingCore/WinShun`，C++20 + Qt 6）**，用于快速实现与 **Mac顺（MacShun）** 100% 互通的跨设备剪贴板共享（支持 **1+ 台 Mac 与多台 Windows** 互通文字、图片、文件与文件夹）。

---

## 一、实现前准备（两份共享基线文件）

从 Mac顺 仓库把以下两份文件原样复制到 Win顺 仓库的 `docs/` 目录：

1. [`docs/shunsync-protocol.md`](shunsync-protocol.md)：完整协议规范（握手、加密、分帧、发现、文件流、多机防回环）。
2. [`docs/shunsync-test-vectors.json`](shunsync-test-vectors.json)：确定性加密与分帧测试向量。**Win顺 的单元测试必须逐字节跑通这份向量**，跑通即代表两端加密与协议 100% 对齐。

---

## 二、Windows 端关键技术选型（复用现有 Qt 6 + Windows 原生能力）

| 模块 | 推荐实现 | 注意事项 |
|---|---|---|
| TCP 监听与直连 | `QTcpServer` + `QTcpSocket`（开 `TCP_NODELAY`） | 默认监听 `37219`，冲突时回落 `0`（自动分配端口） |
| 局域网发现 | `QUdpSocket`（UDP `37220` 广播 `DiscoveryBeacon` JSON）+ 可选 Win10+ `windns.h`（`DnsServiceRegister` / `DnsServiceBrowse`） | 遍历 `QNetworkInterface::allInterfaces()`，跳过 `IsLoopBack`、未启用接口以及名称含 `vEthernet` / `WSL` / `Docker` / `Tailscale` / `ZeroTier` 的虚拟网卡，只向物理网卡广播 |
| 密码原语 | OpenSSL 3（`EVP_PKEY_X25519`、`EVP_MAC` HMAC-SHA256、`EVP_KDF` HKDF-SHA256、`EVP_aes_256_gcm`）或 `libsodium` | 无须生成/管理 X.509 证书，完全按 `shunsync-test-vectors.json` 校验 |
| 防回环与隐私 | `AddClipboardFormatListener` + `GetClipboardSequenceNumber()`；写入远端内容时附加私有剪贴板格式 `ShunSync.Origin` | 跳过含 `ExcludeClipboardContentFromMonitorProcessing` 或 `CanIncludeInClipboardHistory == 0` 的密码管理器条目 |
| 剪贴板读写 | 文本写 `CF_UNICODETEXT`（`\n` → `\r\n`）；图片写 `PNG` + `CF_DIB`；已落盘文件写 `CF_HDROP` | 收到远端大文件（> 20 MB）先只加入剪贴板历史，用户点击/粘贴时通过 `mode="file"` 流式拉取到 `%LOCALAPPDATA%\WinShun\SharedFiles\<transferId>\` 后写入 `CF_HDROP` |
| 防火墙 | 首次开启共享或安装脚本放行 TCP `37219` 与 UDP `37220`（仅专用/局域网配置文件） | 仅在用户显式开启“跨设备剪贴板共享”后才启动监听与广播 |
| 身份持久化 | `%LOCALAPPDATA%\WinShun\Sync\identity.json` | 与 Mac顺 格式一致（`deviceId`、`groupKey`、`revokedDeviceIds`、`knownPeers`）；UUID 统一用 `QUuid::toString(QUuid::WithoutBraces)` |

---

## 三、给 Win顺 仓库的直接可用 Vibe-Coding 提示词

在 Win顺 仓库打开你的 AI 编程工具，先确认 `docs/shunsync-protocol.md` 和 `docs/shunsync-test-vectors.json` 已复制到仓库中，然后直接把下面这段话发给它：

```text
请严格按照仓库里的 `docs/shunsync-protocol.md` 和 `docs/shunsync-test-vectors.json`，在 Win顺（C++20 + Qt 6）中实现与 Mac顺 100% 互通的“跨设备剪贴板共享（ShunSync v1）”功能，支持多台 Windows 和 Mac 组成对等共享组，同步文字、图片（PNG）以及文件和文件夹。

核心要求：
1. 严格实现 `ShunSync v1` 协议：
   - 4 字节大端长度前缀分帧、X25519 + HKDF-SHA256 + HMAC-SHA256 握手、AES-256-GCM 双向序号加密（Nonce = 0x00000000 || BE64(seq)，AAD = BE64(seq)）。
   - 帧类型 `0x01` JSON 控制消息、`0x02` 二进制文件分片（256 KB）、`0x03` 二进制 PNG 图片。
   - 同步模式（`sync`）、按需文件流模式（`file`，支持 `offset` 断点续传与片段 SHA-256 校验，并在无法直连对端 `file` 端口时自动复用已有 `sync` 连接收发 `file_pull_req` / `0x02` / `file_pull_done`，适配二级路由 NAT 场景）、6 位确认码配对模式（`pair`）。
   - 支持群组邀请码 `shunsync://join?k=...&p=...` 生成与解析、移除设备并广播 `group_rotate` 密钥轮换。
2. 多机发现与直连：
   - 默认关闭共享；开启后监听 TCP 37219（冲突自动回落系统端口）并启用 UDP 37220 局域网广播发现（过滤回环及 WSL/Docker/vEthernet 等虚拟网卡）。
   - 支持手动添加 `IP:端口`（适配 Tailscale / 跨网段），并在认证后通过 `auth_ok.peers` 和 `peer_update.peers` 自动全互联多台设备。
3. 剪贴板防回环、隐私与文件策略：
   - 单跳广播（永不二次转发远端条目），写入系统剪贴板时记录序列号并加私有格式 `ShunSync.Origin` 防回环。
   - 自动跳过密码管理器标记（`ExcludeClipboardContentFromMonitorProcessing`、`CanIncludeInClipboardHistory == 0`）。
   - 文件/文件夹采用“清单即刻广播 + 默认仅手动按需流式拉取（带进度与取消，拉完写入 `CF_HDROP`），并支持可选的小文件自动预取上限（默认 `0` 关闭，可选 10/20/50/100 MB）”。
   - 接收路径严格做跨平台文件名清洗与路径穿越防护，缓存目录 `%LOCALAPPDATA%\WinShun\SharedFiles` 按 2GB / 7 天 LRU 清理。
4. 界面与易用性体验（保持和 Mac顺 一致的极简交互）：
   - 开启共享后默认允许接收 6 位码配对请求（带 8 秒频控防骚扰，高级设置里可关），不需要先跑去对方开“配对窗口”。
   - 设置页保持简洁：主界面只放「总开关与在线状态」「我的设备 + 一个万能输入框（输 IP 免写端口或直接贴邀请码，若不在同组自动转入 6 位码配对）+ 复制邀请码」「同步内容（文字/图片/文件/文件到达提示）」，其余（本机名、本机地址、群组前 8 位、自动写剪贴板、小文件预取上限、缓存管理、重置群组密钥）收进折叠的「高级设置」。
   - 收到远端文件时（默认仅手动接收），在屏幕角落弹一个不抢焦点的轻量提示卡片（6 秒自动淡出，鼠标悬停暂停），提供 **「接收并复制」**（拉完写进 `CF_HDROP` 可直接 `Ctrl+V`）和 **「存到下载」**（直接存到用户下载目录并在资源管理器选中）两个一键按钮；同时剪贴板历史面板里也保留待接收条目供随时取用与右键“发送到设备”。
   - 在系统托盘菜单增加一键暂停/恢复剪贴板共享。
5. 单元测试验证：
   - 编写 C++ 单元测试加载 `docs/shunsync-test-vectors.json`，逐字节校验 `groupId`、握手 `transcript`/`serverProof`/`clientProof`/`c2sKey`/`s2cKey`、6 位 `sasCode` 与 AES-256-GCM 密文帧。
   - 编写 3 实例本地回环集成测试，验证 6 位码配对、3 机文字/图片/文件/文件夹同步、防回环与设备吊销密钥轮换。
```
