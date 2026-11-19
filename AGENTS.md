# AGENTS.md

Mac顺（MacShun）是 macOS 14+ 菜单栏应用，基于 SwiftPM（`Package.swift`，Swift 5 语言模式，AppKit + SwiftUI），仅需 Xcode Command Line Tools 即可编译。

## 仓库与工作边界

- **主仓库（当前目录）**：Mac顺客户端源码（`Sources/MacShun/`）、测试（`Tests/MacShunTests/`）、脚本（`scripts/`）与文档（`docs/`、`README.md`）。
- **独立子仓库（`gleaning-web/`）**：拾穗计划官网与发布服务（`github.com/LingCore/gleaning-web`），已列入根 `.gitignore`。涉及网站或发布服务时再进入该目录操作，提交各自独立。
- **本地归档（`macshun-资料/`）**：已通过 `.git/info/exclude` 忽略的早期调研、素材与旧记录，仅作背景参考，不作为当前规格或编码约束。

## 自主执行与确认边界

- **可直接完成**：阅读与修改代码、文档和 `Resources/en.lproj/Localizable.strings`；在本地编译到 `build/`；运行单元测试、`scripts/check-l10n.py`、`gleaning-web/` 构建与测试。
- **不要擅自执行**：`scripts/build-app.sh --install`（会替换 `/Applications/Mac顺.app`）、`scripts/release.sh --publish`（创建 GitHub Release）、部署或修改生产服务器（`/opt/gleaning`）、清理用户未提交改动。
- **清理临时输出**：验证完成后不要把一次性的 `.log`、`.json`、`.png` 或临时脚本留在 `build/` 或 `docs/` 下；`build/` 仅保留构建产物 `Mac顺.app`。
- **完成标准**：完成用户要求并跑完与本次改动匹配的检查即可结束，不必为小改动补写冗余测试或重复全量检查。

## 按需查阅的文档

- `README.md`：双语用户说明、权限说明与源码构建命令。
- `docs/architecture.md`：模块划分、核心文件与并发/实现约束。
- `docs/requirements.md`：当前功能范围与产品要求。
- `docs/release-notes/v<版本>.md`：对外发布的双语版本说明（必须保持 `Sources/MacShun/App/Updater.swift` 与 `scripts/release.sh` 依赖的格式：开头中英文摘要，其后 `## 新功能 · What's new` 下每条 `- emoji 中文` 接缩进英文）。
- `THIRD_PARTY_NOTICES.md`：第三方代码登记（`scripts/build-app.sh` 会打入 `.app`）。
- `gleaning-web/README.md`、`gleaning-web/docs/*`、`gleaning-web/clients/README.md`：仅在改动官网、发布后台或更新/上报协议时查阅。

## 验证命令

根据实际改动选择对应检查：

```bash
scripts/test.sh --filter <Suite>  # 定向单元测试（按改动模块选择）
scripts/test.sh                   # 全量单元测试（自动分进程运行共享 AppKit 状态的套件）
scripts/check-l10n.py             # 修改界面文案后检查中英文对齐与格式占位符
scripts/build-app.sh              # 编译并签名到 build/Mac顺.app（不替换 /Applications）
```

仅在改动事件拦截、辅助功能（AX）、系统设置引导、文件对话框或自更新链路且需要真机确认时，才运行交互自测（会模拟真实键鼠输入并短暂重启运行中的开发版）：

```bash
scripts/selftest.sh               # 全量真机自测（支持 keyboard/terminal/composition/window/search/system-search/gleaning）
scripts/guide-test.sh             # 授权引导浮窗自测
scripts/selftest-file-dialog.sh   # 原生打开/存储面板跳转自测
scripts/update-test.sh            # 本地假发布源更新替换自测
```

改动 `gleaning-web/` 时在该目录运行：

```bash
npm run check && npm test && npm run build
```

## 关键实现约定

- Swift 源文件首行保留 `// SPDX-License-Identifier: MIT`；新增第三方代码须同步登记到 `THIRD_PARTY_NOTICES.md`。
- `EventTapService` 独立线程与主线程/界面共享状态须用 `Locked` 包装；AppKit 与 Text Input Sources 调用仅在主线程执行。
- SwiftUI 视图不使用 `@State`（仅装 Command Line Tools 时缺少宏插件，沿用 `@StateObject` / `@ObservedObject` / `Binding`）。
- 保留 Bundle ID（`io.github.lingcore.winshun`）和本地开发签名证书名称（`WinShun Development`），避免破坏用户系统授权与原地自动更新校验。
