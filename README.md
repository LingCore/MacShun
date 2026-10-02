# Win顺

让习惯 Windows 的人，在 Mac 上也能顺手操作。

> **当前状态（2026-10-02）**：三个核心功能的第一版已经写完，单元测试和真机自测都通过，还有几项要人工确认。实现细节和待验证的项目见 [docs/architecture.md](docs/architecture.md)。

## 核心功能

1. **快捷键像 Windows**：Ctrl+C/V/X/Z/S 等代替 ⌘；Home/End、Ctrl+←/→ 按 Windows 的方式移动光标；
   支持 Alt+Tab、Alt+F4、Win+E/D/L/S、Win+Space；Finder 里支持 Ctrl+X 剪切、F2 重命名、Enter 打开、Delete 删除；
   在终端、远程桌面和虚拟机里不改写按键。键盘处于 Win 模式还是 Mac 模式都能用，不用设置。
2. **鼠标像 Windows**：指针没有加速（线性），速度可以调得比系统设置更快；滚轮方向、按行滚动的手感和 Windows 一致；鼠标侧键可以前进、后退。
3. **剪贴板历史**：按 Win+V 呼出，支持中文拼音和首字母搜索，内容只保存在本机。

以下功能以后再考虑：窗口贴靠、全盘文件名搜索。

需求明细见 [docs/requirements.md](docs/requirements.md)，模块划分见 [docs/architecture.md](docs/architecture.md)。

## 技术

- 语言：Swift。界面用 SwiftUI，配合 AppKit 做成常驻菜单栏的程序。
- 编译：Swift Package Manager。由 `scripts/` 里的脚本把程序打包成 `.app`，不依赖 Xcode。
- 最低系统版本：macOS 14。目前只编译本机架构（Apple Silicon）；发布时再出同时支持 Intel 的版本。

## 编译和运行

只需要 Command Line Tools，不需要 Xcode（`xcode-select --install`）。

```bash
scripts/dev-cert.sh            # 第一次：生成开发用的签名证书（只需一次）
scripts/build-app.sh           # 编译并打包成 build/Win顺.app
scripts/build-app.sh --install # 编译打包，装到“应用程序”文件夹并启动
scripts/test.sh                # 运行单元测试
scripts/selftest.sh            # 真机自测（需要先授权；约半分钟，期间不要操作键盘鼠标）
```

第一次运行要在“系统设置 → 隐私与安全性”里授权：
- **辅助功能**：改写按键、粘贴、找到文字光标的位置
- **输入监控**：识别是哪个鼠标在滚动
- **粘贴**：把 Win顺 设为“始终允许”，剪贴板历史才能在后台记录

Win顺 的设置窗口“通用”页会显示这三项是否已授权。授权后马上生效，不用重启。

查看日志：在“控制台”应用里按子系统 `io.github.bofu.winshun` 过滤。

## 目录结构

```
winshun/
├── Sources/WinShun/      程序源码（Swift 编译目标名为 WinShun）
│   ├── App/              程序入口、菜单栏、设置界面、开机自启
│   ├── Keyboard/         快捷键：Windows 键位映射，按应用排除
│   ├── Mouse/            鼠标：指针加速、滚轮、侧键
│   ├── Clipboard/        剪贴板历史：记录、弹出面板、拼音搜索
│   └── Shared/           公共部分：权限检查与引导、配置存储、拼音转换、日志
├── Tests/WinShunTests/   单元测试
├── Resources/            Info.plist、图标、中英文本地化文件
├── scripts/              编译、打包 .app、签名、公证的脚本
├── docs/                 需求和设计文档
├── LICENSE               GPL-3.0 许可证全文
└── THIRD_PARTY_NOTICES.md  借用的第三方代码登记
```

目录里的 `.gitkeep` 是空占位文件，用来让空目录能被 git 保留。目录里有了真正的文件后就可以删掉。

## 名称与标识

| 用途 | 写法 |
|---|---|
| 程序显示名 | Win顺 |
| 文件夹、仓库名 | `winshun` |
| Swift 编译目标 | `WinShun` |
| 应用标识（Bundle ID） | `io.github.bofu.winshun`（改了它就要重新授权） |

## 隐私原则

- 剪贴板内容只保存在本机，不上传。
- 除了以后可能加的“检查更新”，不联网。
- 自动跳过密码管理器标记为隐藏的剪贴板内容。

## 许可证

本项目以 **GPL-3.0-or-later** 发布，全文见 [LICENSE](LICENSE)。
借用的第三方代码及其原许可证登记在 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

版权所有者：待定。发布前填写作者名或 GitHub 用户名。

Windows 是微软公司的商标，Mac 是苹果公司的商标。本项目与微软、苹果没有任何关联。
