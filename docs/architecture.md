# 模块划分与实现

Mac顺（MacShun）是基于 SwiftPM 的 macOS 14+ 菜单栏应用，界面由 AppKit 与 SwiftUI 混合实现。

## 模块总览

| 目录 | 职责 | 核心系统接口与技术 | 主要系统权限 |
|---|---|---|---|
| `App/` | 程序入口、菜单栏图标、设置窗口与搜索、开机自启、权限引导、拾穗展示、自动更新、匿名装机统计、真机自测 | SwiftUI、AppKit、`SMAppService`、`URLSession`、Security | 无（更新与引导依赖已授予权限） |
| `Keyboard/` | Windows 快捷键规则（K1–K8）、按键布局自动学习、双击 Ctrl 检测 | `CGEventTap`、AX 焦点查询 | 辅助功能 |
| `Mouse/` | 指针去加速与速度、滚轮方向与按行步长、侧键映射、Ctrl+滚轮缩放、光标大小 | `CGEventTap`、IOKit HID、`CGSSetCursorScale` | 辅助功能、输入监控（完全磁盘访问可选） |
| `Clipboard/` | 剪贴板轮询、本地存储、分类筛选、预览、拼音与图中文字检索、模拟粘贴 | `NSPasteboard`、`NSPanel`、`CGEvent`、Vision OCR | 读取剪贴板（始终允许）、辅助功能 |
| `FileSearch/` | 文件名索引、FSEvents 增量更新、展开筛选与排序、路径/同音查找、文件内容索引、系统功能口语搜索、原生文件面板跳转 | `readdir`、FSEvents、SQLite FTS5、PDFKit、libcompression、Vision OCR、`NSPanel` | 文件和文件夹（桌面/文稿/下载等） |
| `Capture/` | 区域/窗口截图、屏幕取色、矢量与文字/步骤/多边形/锚点选区标注、手机号与邮箱辅助打码、长截图拼接与再标注、屏幕取字、桌面贴图 | ScreenCaptureKit（`SCScreenshotManager`）、Vision、`NSPanel` | 屏幕录制 |
| `Window/` | Win+方向键分屏、跨屏自由拖拽与共享边缘停留预览、贴靠助手、系统原生平铺冲突检测 | `AXUIElement`、`CGWindowListCopyWindowInfo`、`NSEvent` 全局监听 | 辅助功能 |
| `Display/` | 每块显示器按百分比选清晰缩放档位、选刷新率 | `CGDisplayCopyAllDisplayModes`、`CGConfigureDisplayWithDisplayMode` | 无 |
| `Performance/` | 菜单栏 CPU、GPU、内存占用与芯片温度采集及多样式渲染（文字、纯图标仪表、折线走势） | Mach host statistics、IOKit（GPU / SMC 只读）、`NSImage` | 无 |
| `Shared/` | 事件拦截独立线程、设备监控、前台应用与输入法追踪、焦点查询、配置持久化、拼音转换、本地化、多屏窗口定位、日志 | `CGEventTap`、IOKit HID、`CFStringTransform`、Text Input Sources | — |

## 核心文件索引

- **App**：`AppDelegate.swift` 组装各控制器与生命周期；`SettingsView.swift` 与 `SettingsSearch.swift` 提供设置界面与拼音可搜目录；`Updater.swift` / `UpdateWindow.swift` / `UpdateProbe.swift` 负责通过拾穗发布服务（优先 `mirrors`、兜底 GitHub）下载、核对 SHA-256 与代码签名并原地替换；`InstallReport.swift` 负责可选的每日一次匿名装机上报；`SelfTest.swift` / `GuideTest.swift` 承担真机交互自测。
- **Keyboard & Mouse**：`KeyMapper.swift` 与 `ScrollTransform.swift` / `SideButtons.swift` 为纯规则层；`KeyboardEngine.swift` 与 `MouseEngine.swift` 运行在 `EventTapService` 独立线程；`LayoutInference.swift` 按键盘分别学习 Windows / Mac 键位模式；`PointerAcceleration.swift` 读写 HID 线性加速与速度属性；`CursorSize.swift` 写系统偏好（有完全磁盘访问时）并在无权限时退回 `CGSSetCursorScale` 周期维护。
- **Clipboard**：`ClipboardWatcher.swift` 轮询 `changeCount` 并跳过密码管理器标记的隐藏条目；`ClipboardStore.swift` 管理文本/富格式附件/图片存盘与后台图像文字识别；`ClipboardPanel.swift` / `ClipboardController.swift` / `ClipboardPreview.swift` 提供面板、分类筛选、纯文本粘贴、与文件搜索框联动叠放。
- **FileSearch**：`FileIndex.swift` 与 `IndexedFolders.swift` 维护按目录紧凑存储（`FolderEntries`）的分区索引快照；`FileNameSearch.swift` 与 `FileSearchFilters.swift` 处理多核并行匹配、路径加分、同音回退与未收录目录直读；`ContentIndex.swift` / `ContentExtractor.swift` / `ZipReader.swift` 维护本地 SQLite FTS5 全文索引与子进程 OCR；`SystemFeatureCatalog.swift` / `SystemFeatureQuery.swift` 提供本机系统设置口语检索；`FileSearchPanel.swift` 与辅助视图实现胶囊/展开双态面板、原生文件对话框定位（`FileDialogTarget.swift`）和结果拖出。
- **Capture**：`ScreenCaptureController.swift` 统筹冻结选区（`FrozenScreen.swift`）、取字与输出；`CaptureCanvas.swift` / `CaptureToolbar.swift` / `CaptureAnnotations.swift` / `CaptureLineShape.swift` / `CapturePolygon.swift` 管理选区编辑、箭头/折线/曲线/文字/序号标注及撤销重做；`CaptureLoupe.swift` 负责放大镜与 HEX/RGB/HSL 取色；`CaptureRedaction.swift` 用快速 Vision 识别在本机检测手机号和邮箱；`ScrollingCapture.swift` / `ScrollCaptureSource.swift` / `ScrollStitcher.swift` / `LongCaptureEditor.swift` 处理长截图滚动拼接与滚动标注；`ScreenPins.swift` 管理桌面悬浮贴图。
- **Window & Display & Performance**：`WindowSnapper.swift` / `DragSnapIntent.swift` / `WindowLayout.swift` / `WindowElement.swift` / `SnapAssist.swift` 实现窗口状态跟踪、共享边缘停留意图状态机和跨屏布局；`DisplayScaling.swift` 计算清晰 HiDPI 缩放比例与刷新率档位；`PerformanceMonitor.swift` 在低优先级串行队列每 2 秒采样 `SystemMetrics.swift` 与 `ChipTemperature.swift`，由 `PerformanceMenuBarImage.swift` / `PerformanceMenuBarGlyphs.swift` 绘制菜单栏图像。

## 关键设计与约束

### 1. 事件拦截与设备区分
- `EventTapService` 在独立线程拦截键盘、滚轮和鼠标侧键事件，避免界面繁忙时阻塞输入。共享配置和前台状态一律通过 `Locked` 传递。
- `InputDeviceMonitor` 通过 IOKit 监听各输入设备原始事件，识别当前操作的键盘或鼠标：鼠标滚轮和加速按设备保存设置；键盘按设备分别记住 Windows / Mac 模式（`LayoutInference`），默认由 `KeyMapper.systemShortcut` 兼容常见组合键。
- 密码框等“安全键盘输入”状态下，macOS 会暂停将按键送入 `CGEventTap`，这是用户态事件拦截的固有系统边界。

### 2. 文件索引与全文检索
- 个人目录和应用程序使用 `FileIndex` 扫盘加 FSEvents 增量维护，外接硬盘（含 NTFS）改用 `readdir` 与多线程后台扫描，跳过缓存、依赖包（`node_modules` 等）、构建产物与日志文件。
- `ContentIndex` 在 `~/Library/Application Support/MacShun/ContentIndex/` 维护 contentless SQLite FTS5 索引（WAL 模式读写分离），中文按单字加标点分隔符（`U+E000`）切分，原文经 zlib 压缩另存用于截取匹配行；PDF 与图片（含扫描件 OCR）在有 90 秒超时保护的隔离子进程中解析，避免单文件崩溃影响主进程。
- `OpenHistory`（UserDefaults 最多 300 条）与 `PinnedSearchFolders` 分别保存打开加权和固定项目夹。

### 3. 跨屏分屏与原生平铺
- 拖动分屏采用只读全局 `NSEvent` 监听，不拦截或 warp 光标；`DragSnapIntent` 纯状态机负责外侧边缘即时预览与多屏共享边缘停留（180ms 稳定预览、250ms 跨屏保护）的防抖判定，并在屏幕参数变化或切屏时使旧候选失效。
- macOS 15+ 自带边缘拖动平铺启用时，Mac顺 自动让出拖动分屏并在设置 › 通用提示冲突检测及关闭入口；`Win+方向键` 快捷键不受系统拖动平铺开关影响。

### 4. 光标大小、显示器与性能监控
- `CursorSizeController` 优先写入 `com.apple.universalaccess` 的 `mouseDriverCursorSize`（需完全磁盘访问权限），无该权限时退回到运行时周期性调用 `CGSSetCursorScale` 并在退出时恢复。
- `DisplayScaling` 仅保留原生分辨率及渲染像素不少于原生分辨率的清晰 HiDPI 档位，修改通过 `CGCompleteDisplayConfiguration(.permanently)` 持久化。
- `PerformanceMonitor` 在关闭监控、单指标关闭或系统睡眠时停止采集并清理缓存；`ChipTemperature` 与 `SystemMetrics` 改写了 MIT 许可的 `exelban/stats` 只读 SMC / GPU 统计定义，详见根目录 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。

### 5. 更新、统计与构建环境
- `Updater` 通过拾穗发布服务检查版本，按 `mirrors` 优先、GitHub 原始地址兜底的顺序下载 DMG，强制核对字节大小、SHA-256 与同证书代码签名（`WinShun Development` / `io.github.lingcore.winshun`）后原地替换重启。
- `Package.swift` 当前使用 Swift 5 语言模式；为兼容仅安装 Command Line Tools（无 Xcode SwiftUI 宏插件）的环境，SwiftUI 视图不使用 `@State`。
