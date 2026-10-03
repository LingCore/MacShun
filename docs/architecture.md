# 模块划分与实现

更新日期：2026-10-02。三个核心功能的第一版已经写完，单元测试和真机自测都通过；还有几项只能人工确认（见文末“待验证”）。

## 模块

| 目录 | 负责的内容 | 用到的系统接口 | 需要的系统权限 |
|---|---|---|---|
| `App/` | 程序入口、菜单栏图标、设置界面、开机自启、权限引导 | SwiftUI、AppKit、`SMAppService` | 无 |
| `Keyboard/` | Windows 键位规则（K1–K9）、Win+E/D/L/S 等系统操作 | `CGEventTap`、辅助功能接口（查询焦点） | 辅助功能 |
| `Mouse/` | 指针加速、滚轮方向和步长、侧键、Ctrl+滚轮、光标大小（M1–M6） | `CGEventTap`、IOKit HID、`CGSSetCursorScale` | 辅助功能、输入监控 |
| `FileSearch/` | 文件名索引、连按两下 Ctrl 弹出的搜索框（F1），文件内容索引（F2） | FSEvents、`FileManager`、`NSPanel`、SQLite FTS5、PDFKit、libcompression | 首次扫描时系统询问“桌面”“文稿”“下载”的访问权限 |
| `Display/` | 每块显示器按百分比选缩放（D1）、选刷新率（D2） | `CGDisplayCopyAllDisplayModes`、`CGConfigureDisplayWithDisplayMode` | 无 |
| `Clipboard/` | 记录剪贴板、保存历史、弹出面板、模拟粘贴（C1–C5） | `NSPasteboard`（轮询 `changeCount`）、`NSPanel`、`CGEvent` | 读取剪贴板（“粘贴”设为始终允许）、辅助功能（模拟粘贴、找光标位置） |
| `Shared/` | 事件拦截线程、配置、权限、拼音、前台应用与输入法、应用名单、日志 | `CFStringTransform`、Text Input Sources | 无 |

### 主要文件

| 文件 | 内容 |
|---|---|
| `Shared/EventTapService.swift` | 在独立线程上建立一个事件拦截，键盘事件交给 `KeyboardEngine`，滚轮和侧键交给 `MouseEngine` |
| `Keyboard/KeyMapper.swift` | 键位规则。纯函数，不碰系统事件，单元测试主要测它 |
| `Keyboard/KeyboardEngine.swift` | 记住每个按下的键是怎么处理的，松开时照做；Alt+Tab 时模拟 ⌘ 一直按住 |
| `Keyboard/SystemActions.swift` | Win+E/D/L/S/Space 对应的操作 |
| `Mouse/ScrollTransform.swift` | 滚轮换算（方向、按行滚动）。纯函数 |
| `Mouse/MouseDeviceMonitor.swift` | 列出鼠标；记住最近一次是哪个鼠标在滚动，用于按鼠标分别设置 |
| `Mouse/PointerAcceleration.swift` | 按鼠标关闭指针加速、调指针速度 |
| `Mouse/CursorSize.swift` | 光标大小 |
| `Keyboard/CapsLockSwitch.swift` | 还原早先 Caps Lock 试验留下的系统设置 |
| `Keyboard/DoubleTapDetector.swift` | 识别连按两下 Ctrl。纯函数 |
| `FileSearch/FileIndex.swift` | 文件名索引：扫描、FSEvents 增量更新、打分排序（打分是纯函数） |
| `FileSearch/FileSearchPanel.swift` | 胶囊搜索框，合并文件名和内容两路结果 |
| `FileSearch/ContentIndex.swift` | 文件内容索引：SQLite FTS5，增量更新，查询和摘要（分词、查询、摘要是纯函数） |
| `FileSearch/ContentExtractor.swift` | 从 txt/csv/json、Office、PDF 里读出文字 |
| `FileSearch/ZipReader.swift` | 读 docx/xlsx/pptx 外面那层 zip |
| `Display/DisplayScaling.swift` | 算出每块显示器清晰的缩放档位和能用的刷新率（纯函数），切换显示模式 |
| `Clipboard/ClipboardStore.swift` | 历史记录的保存、去重、固定、搜索 |
| `Clipboard/ClipboardPanel.swift` | Win+V 弹出的面板 |
| `Shared/Pinyin.swift` | 汉字转拼音、多音字纠正表、拼音匹配 |
| `Shared/AppCatalog.swift` | 终端、远程桌面和虚拟机、浏览器等应用名单 |

## 关键决定

- **改键方案**：程序自己用 `CGEventTap` 在会话层拦截按键，装好就能用，不依赖 Karabiner-Elements。
  - 规则只认“Windows 意义上”的修饰键，按紧挨空格键左边的键发出什么分两种布局：发出 ⌥ 时（Windows 模式）Win = ⌘、Alt = ⌥；发出 ⌘ 时（Mac 模式，以及苹果键盘）按位置对应，option = Win、command = Alt。
- **键盘的 Win/Mac 模式（K8）**：很多机械键盘有 Win/Mac 模式开关，切到 Mac 模式是键盘自己把 Alt、Win 两个键的信号对调。实测 MCHOSE K99 切换模式前后，报给系统的设备信息（型号、序列号、报告格式、接口）完全不变，键盘也不重新连接，所以无法直接读出模式。目标是用户什么都不用做：
  - 最常用的组合不依赖模式（`KeyMapper.systemShortcut`）：⌥ 一定当 Alt 或 Win 用（Windows 用户不会用 ⌥+字母打 √ ∂ ß），所以 Win+V/E/L/S 两种模式下都能用；Alt+Tab 的 ⌥Tab、⌘Tab 都能切换程序；Alt+F4 的 ⌥F4、⌘F4 都退出程序。
  - 只有 Win+D、Win+Space 按当前模式认 Win 键：Windows 模式下 Alt+D 是浏览器地址栏的习惯，⌥Space 常被 Alfred、Raycast 等启动器占用。
  - 模式在后台从按法学习，不弹提示（`Keyboard/LayoutInference.swift`）：Alt+Tab、Alt+F4 发出 ⌥ 是 Windows 模式、发出 ⌘ 是 Mac 模式；⌥+V/E/L/S 是 Win 键的按法，说明是 Mac 模式。F4 看到一次就算，其他的要连续两次。
  - 按键盘分别记住模式。和鼠标一样，用 IOKit 监听各键盘的原始输入，知道每个按键来自哪把键盘（`Shared/InputDeviceMonitor.swift`）。苹果键盘一定是 ⌘ 紧挨空格。设置页只显示每把键盘当前的模式，旁边有一个“不对”按钮。
  - 鼠标上的“键盘”接口（宏按键，例如 ATK 鼠标）不会出现在键盘列表里，因为列表只显示打过字的键盘。
  - 曾经做过“第一次用新键盘时弹提示，请用户按一下 Alt 识别”，作者试用后觉得不够简单，改成了现在的做法。
- **要不要改写取决于焦点**：Home/End 和 Finder 的 Enter、Delete、Backspace 先通过辅助功能接口查询键盘焦点。
  - 浏览器里 ⌘← 是“后退”，所以只有确定光标在输入框里才把 Home/End 换成 ⌘←/⌘→。
  - Finder 里只有确定焦点在文件列表上才改写，问不到焦点就按 Mac 原样处理，避免误删文件。
- **常用软件（K9）**：调研结果见下表。
- **鼠标按设备设置**：滚轮事件不带设备信息，所以另外用 IOKit 监听各鼠标的滚轮和按键输入，最近有输入的鼠标就是当前设备。只接了一个鼠标时不用猜。
- **指针加速**：用系统公开的 HID 属性 `HIDUseLinearScalingMouseAcceleration`（和 macOS 14 起“系统设置”里关掉“指针加速”的效果一样），可以每个鼠标分别设置，跟踪速度仍然有效。这个属性不会保存，鼠标重连、睡眠唤醒后由程序重新设置；退出时恢复原值。
- **指针速度**：没有加速时，系统把鼠标的移动计数直接乘以 `HIDMouseAcceleration`（就是“跟踪速度”，系统滑块最高 3）得到指针移动的点数（见 IOHIDFamily 的 `IOHIDPointerScrollFilter::setupPointerAcceleration` 和 `IOHIDSimpleAccelerator`）。程序按鼠标把这个值设成用户选的倍数（0.25–8 倍），改了马上生效；没调过就跟系统设置一样。只在没有加速时调，有加速时这个值是用来选加速曲线的，交给系统。调过速度后，“系统设置”里的跟踪速度对这个鼠标不再起作用（程序每 30 秒会把它改回来）。
- **光标大小**：用窗口服务器未公开的 `CGSSetCursorScale` 实时改（1–4 倍，和“辅助功能 → 显示 → 指针大小”同一个东西），不写系统偏好 `com.apple.universalaccess`。退出时恢复成系统偏好里的大小；和指针速度一起每 30 秒检查一次，被系统改回去时重新设置。实测 macOS 27 普通程序可以调用，不需要权限。
- **显示器缩放**：Windows 的百分比 = 原生宽度 ÷ “看起来像”的宽度。只列出清晰的档位：原生分辨率（100%），以及高分屏模式里渲染像素不少于原生像素的（系统先按 2 倍渲染再缩小，文字清晰）。2K 这类非高分屏，系统给的高分屏模式只有原生像素的一半，所以只有 100% 和 200%。切换用 `CGCompleteDisplayConfiguration(.permanently)`，和系统设置里改一样会一直保留。
- **刷新率**：列出和当前模式大小（点和像素）都一样的模式的刷新率，按两位小数区分（59.94 和 60 分开）；切缩放时优先保持当前刷新率。同一个大小和刷新率有时有两个模式（2K 144Hz 屏上看到过，公开属性完全一样，猜是时序不同），优先系统标为默认（`ioFlags & 0x4`）的，都不是就用列表里靠后的，和系统自己选的一致。
- **Caps Lock（试过后去掉）**：系统设置“使用大写锁定键切换‘ABC’输入法”背后是 Carbon 里没有公开的 `TISSetRomanSwitchState(Boolean)`（直接写 `TISRomanSwitchState` 偏好不生效）。关掉它之后，苹果拼音收到 Caps Lock 会进自己的英文模式，打出来仍是小写；再临时切到 ABC 又会被系统自动关掉 Caps Lock。做不到 Windows 那样一按就大写，所以去掉了，`Keyboard/CapsLockSwitch.swift` 只负责还原用过那几个版本留下的系统设置。
- **文件搜索**：Mac 的 APFS 没有 NTFS 那样的文件总表（Everything 快的原因），所以自己扫一遍建索引，之后靠 FSEvents 增量更新。第一轮扫个人文件夹（不含“资源库”）和应用程序（含 Cryptexes 里的 Safari），实测 2.3 万个文件 0.4 秒；第二轮在后台扫外接硬盘，跳过 Windows 系统文件夹，扫的时候不耽误搜索。macOS 的 NTFS 驱动（FSKit）查每个文件的属性很慢、而且一次只处理一个，所以外接硬盘不用 FileManager，只用 readdir 读名字和类型，只给文件夹查隐藏标记，几块盘一起用 4 个线程扫，边扫边并进索引：实测 41 万个文件从 82 秒降到 11 秒。原来的 FileManager 方式遇到文件特别多的文件夹（几千个）会读取失败、整个漏掉，readdir 没有这个问题。每次搜索遍历全部文件名，按字节查找，43 万个文件约 70 毫秒。应用程序另外收录访达里的本地化名字（“备忘录”），所以能按中文名和拼音搜到。索引按文件夹紧凑存放（`FolderEntries`）：一个文件夹里所有文件的名字、小写名字、逐字拼音放在一块连续的字节里，每个文件只另占一个 24 字节的 Item；拼音按字节匹配，用临时缓冲区不分配二维数组。比每个文件各用一个 String 和几个数组省一半以上内存（实测中文文件名每个从 213 字节降到 89 字节），搜索也快约一倍。扫描时每个文件夹读完就释放 FileManager 的临时对象，减少内存碎片。第一次呼出时才开始建索引，让系统询问“桌面”等文件夹权限发生在用户主动打开的时候。
- **文件内容搜索**：不用聚焦（Spotlight）。聚焦查短词慢、拿不到匹配处的文字、外接 NTFS 盘通常不建索引、用户排除的文件夹搜不到。改为自己建 SQLite FTS5 索引（系统自带的 libsqlite3，macOS 27 上是 3.54），放在 `~/Library/Application Support/WinShun/ContentIndex/`。
  - 要读哪些文件由文件名索引告诉它（扫描完、FSEvents 有变化时交过来文件列表和范围），按修改时间和大小判断要不要重读。程序依赖包（node_modules、site-packages 等）不读。
  - 中文分词：存进去之前每个汉字前后加空格，用 `unicode61` 分成单字；查询时一个词变成短语（“合 同”），所以一两个字也能搜，不需要词典。英文按前缀匹配。至少两个汉字或三个字母才搜内容。
  - 全文索引是 contentless 的（不存原文）；原文用 zlib 压缩后另存一份，用来截取结果里显示的那一行。contentless 表删除时要交回原来的文字，所以从存的原文重新算一遍（不依赖 3.43 才有的 `contentless_delete`）。
  - 读文字：txt/csv/json 依次试 UTF-8、UTF-16（BOM）、GB18030，JSON 里的 `\uXXXX` 换回汉字；docx/xlsx/pptx 用 libcompression 自己解 zip，再用 XMLParser 取文字（不用 textutil，启动进程每个文件要 90 毫秒）；xlsx 只读文字格子；pdf 用 PDFKit，最多 100 页。每个文件最多收录 512 KB 文字。iCloud 里还没下载的文件（`SF_DATALESS`）不读，免得触发下载。
  - 一批十几个文件几个核同时读（解析、压缩、分词），读完在一个事务里写进数据库；PDF 一次四个。外接硬盘边扫边读，不等全部扫完。读完后调用 `malloc_zone_pressure_relief` 把用过的大块内存还给系统。
  - 实测（个人文件夹加 4 块 NTFS 盘，1.8 万个文件有内容）：第一次从启动到全部读完 24 秒，索引 215 MB；以后每次启动只检查修改时间。搜索 3–19 毫秒。
  - 搜索框只在打开时切到英文输入法，不再限制只能英文，要搜中文内容时可以切回中文输入法。
- **窗口到前台**：macOS 14 起是协作式激活，用户正在用别的程序时，菜单栏程序自己请求激活会被拒绝，设置窗口会被挡在后面（自测复现过）。`App/Foreground.swift` 先正常请求激活并把窗口摆到最上面，没激活成功再用辅助功能接口把本程序设为前台。
- **读取剪贴板**：从 macOS 15.4 起，程序在后台读剪贴板会触发系统询问。剪贴板历史要求用户在“系统设置 → 隐私与安全性 → 粘贴”里把 Win顺 设为“始终允许”；没设好之前不自动读取，避免每次复制都弹窗。
- **拼音搜索**：用系统自带的 `CFStringTransform` 逐字转拼音。系统按字取最常见读音，`地`、`长` 的默认读音不对，`银行`、`重新`、`音乐`、`调整` 等多音字词也会转错，所以在 `Pinyin.swift` 里维护了纠正表。搜索框获得焦点时只允许英文输入，直接打 “jtb” 就能搜索。
- **签名**：开发期间用固定的自签名证书（`scripts/dev-cert.sh`），放在单独的钥匙串里。签名要求绑定这张证书，重新编译后权限不用重新授予。
- **应用标识**：`io.github.lingcore.winshun`。改了它就要重新授权。
- **只装 Command Line Tools 时的限制**：macOS 27 SDK 里 SwiftUI 的 `@State` 是宏，它的插件只随 Xcode 提供，所以代码里不用 `@State`；Swift Testing 的宏插件在 `plugins/testing` 子目录里，`scripts/test.sh` 会把路径告诉编译器。

## 常用软件的快捷键冲突（K9）

| 软件 | 情况 | 处理 |
|---|---|---|
| 微信 | Mac 版截图是 ⌃⌘A，Windows 版是 Alt+A | 微信或 QQ 运行时，Alt+A 换成 ⌃⌘A |
| QQ | Mac 版截图 ⌃⌘A，Windows 版 Ctrl+Alt+A | 同上，Ctrl+Alt+A 换成 ⌃⌘A |
| 钉钉 | Mac 版截图 ⌘⇧A，Windows 版 Ctrl+Shift+A | 改写后正好对上，不用处理 |
| 企业微信 | Windows 版截图 Alt+Shift+A，Mac 版说法不一（⌘⇧A 或 ⌃⌘A） | 暂不处理，待核实 |
| 飞书 | Mac 版把 Windows 的 Ctrl 都换成了 ⌘；只有 ⌃`、⌃Tab 用 ⌃ | 改写后正好对上；Ctrl+`、Ctrl+Tab 本来就不改写 |
| 搜狗输入法 | Mac 版 ⌃. 切换中英文标点（和 Windows 版的 Ctrl+. 一样）；⌃⇧F 简繁切换、⌃⇧E 表情 | 当前输入法是搜狗时，Ctrl+. 不改写；Ctrl+Shift+F/E 仍按应用快捷键改写（例如编辑器的“在文件中查找”），简繁、表情要用 ⌃⇧F/E |
| 微信输入法 | 没有查到用 ⌃ 的快捷键 | 不用处理 |
| macOS 输入法切换 | ⌃Space 切换输入法；Windows 上习惯 Win+Space | Ctrl+Space 不改写；Win+Space 换成切换输入法 |

来源：Homebrew cask 数据、macupdater、Karabiner 的应用定义、飞书和 QQ 的官方帮助页，以及本机安装的应用。未能核实的已在表里注明。

## 已知限制

- **安全输入**：密码框获得焦点时（以及部分应用开启“安全键盘输入”时），macOS 不把按键交给事件拦截，这时 Ctrl+V 不会变成粘贴。这是 `CGEventTap` 的限制，只有驱动层的方案（例如 Karabiner-Elements）能绕过。
- 不能区分是哪个键盘按的键，所以 Windows 键盘和 Mac 键盘同时使用时只能选一种布局。
- 滚轮方向、按行滚动只对一格一格的滚轮生效；触控板和妙控鼠标是连续滚动，交给系统设置。
- 同型号的两个鼠标共用一组设置（按厂商号、产品号和名称识别）。
- Alt+F4 换成 ⌘Q，会退出整个程序（包括它的其他窗口）。

## 真机自测

`scripts/selftest.sh` 让 Win顺 自己模拟按键、滚轮和鼠标侧键（`App/SelfTest.swift`）。这些事件和真实按键一样经过事件拦截，自测再检查测试窗口收到的按键、光标位置、剪贴板内容和 Finder 里的文件。运行约半分钟，期间不要操作键盘鼠标。

2026-10-02 在 macOS 27.0.1 上运行，最近一次 41 项全部通过（自测期间不学习键盘模式，因为它会故意模拟另一种模式的按法）。各项包括：
- K1、K2：Ctrl+A/C/Z/Y、Home/End、Shift+End、Ctrl+Home/End、Ctrl+→、Ctrl+Backspace，Ctrl+H 保持原样
- C1、C2：Win+V 打开面板，输入 yhk 搜到“银行卡号”，Enter 粘贴到原来的窗口
- M3、M4、M5：慢转、快转都是每格 3 行；Ctrl+滚轮变成 ⌘=；侧键变成 ⌘[ / ⌘]
- K3：Alt+F4 → ⌘Q（⌥F4、⌘F4 都行）；⌥V 在两种模式下都打开剪贴板历史；Win+Space 切换输入法；Alt+Tab 切换到上一个程序并且 ⌘ 正常松开；Win+E 打开 Finder
- K4：F2 进入重命名，Backspace 返回上一级，Enter 打开文件夹，Ctrl+X、Ctrl+V 移动文件

自测中发现并修好的问题：
- 公开接口创建的 HID 客户端不能修改 `HIDUseLinearScalingMouseAcceleration`，改用 IOKit 里未公开的 `IOHIDEventSystemClientCreate`。
- 菜单栏程序没有“编辑”菜单，本程序自己的输入框里 ⌘C/⌘V/⌘A 都不起作用。已加上不显示的主菜单。
- 作者的 MCHOSE K99 处于 Mac 模式，Alt 键发出 ⌘、Win 键发出 ⌥，但设置默认是“Alt 发出 ⌥”，结果要按 Alt+S 才能打开聚焦搜索。布局选项因此改成按“紧挨空格的键发出什么”命名，并加了自动识别。

## 待验证（只能人工确认）

- Win+S：真实按键能打开聚焦搜索（作者 2026-10-02 确认），但自测检测不到聚焦搜索窗口，原因未查明。
- Win+D：程序坞接口可以找到，效果要看屏幕。
- Win+L：锁屏接口可以找到，自测不会真的锁屏。
- Alt+Tab 按住 Alt 时切换器能否停住、连按 Tab 能否选择（自测只验证了快速切换）。
- 真实鼠标的滚轮方向。模拟的滚轮事件不经过系统的“自然滚动”反转，所以自测只验证了行数，没有验证方向。
- 浏览器（Chrome 等）里能否问到输入框焦点。问不到时 Home/End 保持 Mac 原样。
- 指针加速、指针速度属性是否会被系统定期改回（程序每 30 秒检查一次）。
- 指针速度调快后的实际手感（自测只能确认系统收下了这个值，模拟的鼠标移动不经过系统的指针加速）。

## 可以参考的开源项目

| 项目 | 许可证 | 参考什么 |
|---|---|---|
| Maccy（https://github.com/p0deje/Maccy） | MIT | 剪贴板监听、历史存储、弹出面板 |
| LinearMouse（https://github.com/linearmouse/linearmouse） | MIT | 按设备设置指针和滚轮、侧键前进后退 |
| Karabiner-Elements（https://github.com/pqrs-org/Karabiner-Elements） | 待核实 | Windows 键位规则的设计，按应用排除的名单 |
| Rectangle（https://github.com/rxhanson/Rectangle） | MIT（待核实） | 以后做窗口贴靠时参考 |

目前没有借用任何第三方代码。借用代码时，要登记到根目录的 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。

## 编码约定

- 每个源文件第一行写 `// SPDX-License-Identifier: GPL-3.0-or-later`。
- 事件拦截线程和界面线程之间共享的状态一律用 `Locked` 包起来；输入法、AppKit 的接口只在主线程上调用。
- 签名证书、公证密码、Sparkle 私钥这些不能放进仓库，`.gitignore` 里已经排除了常见的证书和密钥文件。
