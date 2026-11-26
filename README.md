<p align="center">
  <img src="docs/images/icon.png" width="128" height="128" alt="Mac顺 app icon">
</p>

<h1 align="center">Mac顺 · MacShun</h1>

<p align="center">
  <b>让 Mac 用得更顺手</b> —— 免费开源的 macOS 菜单栏小工具<br>
  <b>Make your Mac smoother to use</b> — a free, open-source macOS menu bar app<br>
  <sub>原名 Win顺 · formerly WinShun</sub>
</p>

<p align="center">
  <a href="https://github.com/LingCore/MacShun/releases/latest"><img src="https://img.shields.io/github/v/release/LingCore/MacShun?label=%E4%B8%8B%E8%BD%BD%20Download" alt="Download"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%2B%20Intel-universal-blue" alt="Apple Silicon and Intel">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT"></a>
  <a href="https://linux.do"><img src="https://img.shields.io/badge/LINUX%20DO-%E7%A4%BE%E5%8C%BA%20Community-1f1f1f" alt="LINUX DO 社区"></a>
</p>

<p align="center">
  <a href="#中文">中文</a> · <a href="#english">English</a>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/keyboard-dark.png">
    <img src="docs/images/keyboard-light.png" width="720" alt="Mac顺 设置窗口：键盘页 / MacShun settings window, keyboard page">
  </picture>
</p>

---

<a id="中文"></a>

## 中文

**Mac顺 是什么？** 一个让 Mac 用得更顺手的小工具。Mac 自带的没有、或者藏得很深的常用功能，装上就有：剪贴板历史、连按两下 Ctrl 搜文件（文件里的字也能搜）、窗口分屏、关掉鼠标加速、每块屏幕按百分比调缩放。从 Windows 换过来的人，还能直接用熟悉的习惯：Alt+Tab 切换程序、Win+E 打开访达，鼠标滚轮方向也和 Windows 一样。不用学新的快捷键，也不用写任何配置。

它常驻在屏幕顶部的菜单栏，不占程序坞，不需要账号，完全免费。联网用于软件更新、读取拾穗计划公开用户数，以及每天最多一次的匿名装机报告（可在“设置 › 通用”关闭）。界面有简体中文和英文两种，默认跟随系统语言。

### 功能

连接多台显示器时，主动打开设置、软件更新或文件搜索，窗口会出现在鼠标指针所在的屏幕。

#### 📋 剪贴板历史（Option+V / Win+V）

- Mac 键盘按 **⌥ Option+V**，Windows 键盘按 **Win+V**，也可以点菜单栏的 Mac顺 图标，选择 **打开剪贴板历史**。单击选中，双击或按 **Enter** 粘贴。在文件搜索框里打开时，选中的文字会填进搜索框。
- 面板优先贴着文字光标或 Mac顺 的文件搜索框打开，找不到文字光标时跟随鼠标。面板可以向上或向下展开，搜索框始终在靠近打开位置的一侧。
- **分类、预览和粘贴**。按文字、链接、图片、文件或已固定筛选。悬停可快速看内容，点眼睛或按 **⌘Y** 打开侧边预览。预览里选中文字后，按 **Enter** 可直接粘贴选段。点列表里的回车箭头可粘贴整条。
- **数字键快贴**。按住 **Option** 查看可见条目的编号，按 **Option+1～9** 直接粘贴对应项。按 **⇧Enter** 粘贴纯文本，按 **⌘⇧C** 只复制。
- **备注和来源筛选**。右键条目可添加或编辑备注，备注也能用拼音搜。用搜索栏的来源筛选按钮，可把搜索限定到某个应用。
- **合并粘贴**。按住 **⌘** 依次点选多条文字，或从条目菜单加入，按 **Enter** 或点击「合并粘贴」按选择顺序换行贴出。
- **支持拼音搜索**：输入全拼或首字母都能找到，比如输入 `jtb` 就能搜到“剪贴板”。
- 记录文字、图片和 Finder 复制的文件。可按文件名搜索并重新粘贴一组文件，文件移动、删除或暂时不可用时会提示。常用内容可以固定并优先显示。在搜索栏右侧点「全部清除」并确认，即可清除未固定的记录。
- 历史图片上右键选 **复制图中文字**，即可复制完整识别结果；按 Enter 仍粘贴图片。
- **按图中文字找图片**：已记录的截图和图片会在本机后台识别，旧历史也会补上。按 Win+V 输入图里的文字或拼音，按 Enter 粘贴原图，按 F3 将它贴到屏幕。
- 自动跳过密码管理器标记为隐藏的内容。默认不联网，内容只存在你自己的电脑上。
- **跨设备剪贴板共享（ShunSync v1）**：可在 **设置 › 剪贴板** 按需开启，在局域网或虚拟局域网（如 Tailscale）内与多台 Mac顺 和 Win顺 端到端加密共享文字、图片、文件与文件夹，不需要账号或云端服务器。支持局域网自动发现、6 位确认码配对或群组邀请码加入；文件默认只同步清单并在角落弹出提示卡片，可一键「接收并复制」或「存到下载」按需流式传输，隐藏密码条目永不同步。菜单栏可一键暂停或恢复共享。
- 从菜单栏「暂停剪贴板记录」可暂时停止收录，已有历史仍能搜索和粘贴。恢复后从下一次复制开始记录。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/panel-dark.png">
    <img src="docs/images/panel-light.png" width="400" alt="Mac顺 剪贴板历史面板，支持拼音搜索">
  </picture>
</p>

#### 截图与识别屏幕文字

- 从菜单栏点 **开始截图**，拖选区域或自动悬停识别界面元素、窗口与面板。自动选区融合视觉边缘识别与系统辅助功能探测，支持**滚轮切换层级**、**Tab** 切换仅框窗口、视觉边缘磁吸及整边拖拽缩放与翻转。按 **Enter** 或双击选区复制、**⌘S** 保存 PNG（设置默认保存目录后静默直存，**⇧⌘S** 另存为）、**⇧C** 在选区内一键 OCR 取字、**Esc** 或右键阶梯回退。按 **? / F1** 查看当前阶段快捷键浮卡，按 **H** 隐藏工具栏。
- **标注工具与快捷键**：除矩形、椭圆、箭头、直线/折线/曲线、文字、步骤序号、多边形与实心遮挡外，还提供**马赛克/高斯模糊、自由画笔、荧光笔与聚光灯**。支持 **1–9 / 0** 单键切换工具、**[** / **]** 调整粗细或强度，按住 **Shift** 锁定正方形/正圆或 15° 角度。
- 选中直线或箭头工具后，可设置箭头放在起点、终点或两端，或去掉箭头。箭头有实心、空心和开口三种样式。切回选择工具后点击已有线条，可以改样式或拖动两端。
- 在「标注样式 › 线型」里，直线工具可选折线或曲线，箭头工具可选曲线。折线单击加点，按 **Enter**、双击或右键完成，点击起点可闭合。绘制中按 **Delete** 撤回最后一个点，按 **Esc** 取消这笔。曲线拖出起终点，拖动控制点调弧度。画完后双击路径插入节点，直线和直箭头插点后可以像折线一样编辑，并保留箭头样式。单击节点再按 **Delete** 可删除，支持 **⌘Z** 撤销和 **⇧⌘Z** 重做。绘制和拖动节点或控制点时按住 **Shift**，方向每 15° 吸附一次。
- **屏幕取色**：开始截图后，把鼠标移到目标像素，放大镜会显示色块和色值。单按 **Shift** 在 **HEX、RGB、HSL** 之间切换，下次截图会沿用该格式。按 **C** 复制当前色值并退出截图。使用锚点选区或已编辑标注时，复制后可以继续编辑。
- **像素微调**：用 **WASD** 移动光标，每次 1 像素，按住 **Shift** 时每次 10 像素。框选前也可以用方向键移动光标。框选后，方向键移动选区，**Shift + 方向键**调整矩形选区的大小。
- **辅助打码**：选好截图范围后，点工具栏里实心遮挡旁的「辅助打码」。它在本机查找可能的中国大陆手机号和常见邮箱地址，点橙框即可实心遮挡。复制、保存和贴图只应用已确认的遮挡，发图前可以再检查一遍。
- 双击**实心遮挡**的边线插入锚点，按多边形编辑遮挡范围并沿用填充颜色。选中锚点后按 **Delete** 删除，用 **⌘Z** 撤销、**⇧⌘Z** 重做。
- 只想复制文字时，选 **识别屏幕文字**，框选后松开鼠标即可。简体、繁体中文和英文在本机识别。
- **写说明和标步骤**：选「文字标注」后点一下输入，Shift+Enter 换行，Enter 确认，双击可再改。选中文字框后，可拖动左右边框调整宽度，也可在「标注样式」里切换对齐、粗体和文字底框。选「步骤序号」后连续点击即可放置 1、2、3，双击序号可改编号。用选择工具点中标注可拖动，按 Delete 删除。删除序号时，后面的编号会自动补位。⌘Z 撤销，⇧⌘Z 重做。
- **多边形与标注样式**：用多边形标注圈出不规则区域；「锚点选区」可以沿物体轮廓逐点选取，导出的范围外透明。选区和多边形标注闭合后都能拖动锚点、双击边线插入锚点，或单击选点后按 **Delete** 删除。双击矩形或椭圆的边线可插点，分别转为多边形或闭合曲线编辑，沿用颜色和线宽。逐点绘制或拖动时，按住 **Shift** 可按 15° 吸附。选区编辑和标注按操作顺序用 **⌘Z** 撤销、**⇧⌘Z** 重做。通过「标注样式」选择颜色、线宽或文字大小。
- **尺寸预设、最近选区与历史回看**：按 **F** 或点击选区尺寸气泡可原地输入像素宽高、锁定比例或套用常用尺寸预设；再次截图时按 **R / ⇧R** 循环恢复最近 10 个选区，按 **, / .** 翻看最近截图历史。方向键移动 1 个实际像素，Shift 加方向键调整宽高。
- **长截图**：框住网页、文档或聊天记录里需要滚动的内容，点「长截图」或按 **⌘L / Ctrl+L**。等蓝框旁提示可以滚动后，用鼠标或触控板慢慢向下滚，点「完成」预览。要在长图上写说明或遮住一行，点「标注」，滚动到对应位置编辑，点「完成标注」后再复制、保存 PNG 或贴到屏幕。允许辅助功能后也可用 Enter 完成、Esc 取消。选区尽量只框正文，避开固定侧栏；如果画面中有大面积视频，先暂停播放。如果提示找不到重叠内容，往回滚一些再继续。
- **贴图**：选好截图后按 **F3** 或点「贴到屏幕」，含标注的图片会留在原处。也可从菜单栏「贴出剪贴板图片」，或在历史图片上右键贴出。拖动移动、拖角或滚轮缩放、双击恢复原始大小，Ctrl 加滚轮调透明度。右键支持贴图内 OCR 取字、原地二次标注编辑、90° 旋转、水平/垂直翻转、鼠标穿透（可从菜单栏「恢复贴图交互」一键恢复）、复制、保存和关闭；点中贴图后按 Esc 也能关闭。
- 两个操作都可以在 **设置 › 键盘 › 截图快捷键** 录入快捷键，默认留空。首次使用按系统提示允许屏幕录制。

#### 🔍 文件搜索（像 Everything）

- **连按两下 Ctrl**，屏幕上方弹出胶囊搜索框，边打字边出结果，几万个文件也是瞬间出来。搜索框开着时再连按也不会关掉，Esc 关闭。
- **支持拼音和首字母**：输入 `bg` 找到“年度报告.docx”，输入 `bwl` 找到“备忘录”，输入 `weixin` 找到“微信”。
- **按日常说法找系统功能**：输入“耳机连不上”打开蓝牙设置，“谁在占内存”打开活动监视器；输入 Windows 叫法“任务管理器”也能找到它。用方向键选择、Enter 打开。切到 **系统** 可以浏览所有收录的入口，全程在本机匹配。
- **也能搜文件内容**：txt、Markdown、CSV、JSON，代码（ts、js、py、swift、vue、html 等）、配置（yaml、xml、toml）、字幕（srt、ass、lrc），以及 Word、Excel、PowerPoint、PDF 里的文字都能搜到（跳过 node_modules、dist、build 这类生成和依赖的文件夹）；截图、照片和扫描版 PDF 里的字也会自动识别，结果里直接显示匹配的那一行。中文按单字建索引，两个字的词也能搜到，不需要聚焦（Spotlight）。默认选 **文件与功能**，按 Tab 或点击右侧可切到 **全部 / 内容 / 系统**；只有“全部”和“内容”会搜文件正文。常打开的文件会排在前面。
- **筛选文件**。输入 `报价 *.pdf !草稿` 搜 PDF，并排除文件名含“草稿”的结果。`ext:pdf,docx` 可同时选两种格式。切换到“内容”时，关键词搜正文，筛选条件仍作用于文件名。要搜索字面名称 `!重要`，输入 `"!重要"`。
- Enter 打开，Ctrl+Enter 在访达中显示。按 **⌘Y** 或点“快速查看”预览选中项，按 ↑↓ 依次查看，Esc 返回原来的搜索结果。
- 按 **Ctrl+O / ⌘O** 或点「更多操作」，打开选中结果的操作菜单。用方向键选择操作，按 **Enter** 执行，按 **Esc** 回到搜索框。
- **拖出搜索结果**。把结果中的文件或文件夹直接拖到访达，或拖进支持接收文件的应用。按文件名和按内容搜到的结果都可以拖出。
- **展开和移动搜索面板**。点击右侧展开按钮或按 **Ctrl+E**，可多选文件类型，并叠加时间、大小和目录条件。筛选可以放在左侧或顶部。点列标题排序，滚到底自动加载更多。拖动顶部短横条或左侧放大镜移动窗口，拖动展开面板的右下角调整大小。胶囊和展开面板各自记住拖放位置，并在同一块屏幕上恢复。再次按 **Ctrl+E** 收回胶囊时会保留当前搜索，按 **⌘Y** 快速查看。
- **搜索指定目录**。在展开面板的「目录」菜单选「只搜这一次」，可临时搜索目录及子目录的文件名。要让它参与以后每次全局搜索，选「加入搜索范围」，也可以在「设置 → 文件搜索 → 搜索范围」添加或移除目录。SMB 共享请先在访达挂载；共享收录文件名，断开时标记离线，重新挂载后恢复。
- **保存筛选与同音查找**。「常用筛选」可保存目录、类型、时间、大小和排序，再用时保留当前输入的关键词。中文文件名没有字面匹配时会尝试同音，例如输入「年度报高」也能找到「年度报告」。
- **在项目里查找**。选中普通文件夹后按 **⌘F**，或右键选“在此文件夹中搜索”。输入关键词或筛选条件会搜索子文件夹，切到“内容”可查这个范围内已收录的正文。按 **Esc** 回到原来的搜索词和选中项。
- **常用项目夹**。右键点击文件夹结果，选“固定到常用项目夹”。再次连按两下 Ctrl，空白搜索页会列出这些项目。点击一项或按 Enter 进入文件夹搜索，按 Esc 回到列表。选中项目后可点“取消固定”。
- **在“打开”和“存储”窗口里找位置**。原生文件对话框打开时连按两下 **Ctrl**，搜索文件或目录，按 **Enter** 让对话框前往该目录或文件所在的目录。存储时会保留已输入的文件名。
- **可以直接粘贴路径**：`art/gpt/style_reference.png` 这样的相对路径、`桌面/塔防游戏/…` 这样用访达里显示的名字写的、`~/Desktop/…` 和完整路径都行，Windows 的 `D:\资料\合同.docx`（带不带引号都行）也认，盘符不管。文件夹写得不全或不对也没关系，名字对上的文件照样列出来，路径对上得越多排得越前。输入本机目录的完整路径并在末尾加 `/` 会列出直接子项，继续打字可在这一层筛选，包括可读取但未收录的目录。普通搜索也可以混合文件夹和文件名，例如 `春季 报价单` 能找到 `春季项目/报价单.xlsx`。完整名称优先，同名时优先当前访达文件夹。
- 搜索个人文件夹、应用程序和外接硬盘（外接硬盘在后台扫描，跳过 Windows 系统文件夹）。点号开头的文件和文件夹也能按名称找到，例如 `.gitignore` 和 `.config`。这些文件及点号目录里的文件只收录名称。文件名索引只放在内存里，内容索引只存在这台电脑上，都不联网。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/search-dark.png">
    <img src="docs/images/search-light.png" width="600" alt="Mac顺 文件搜索：连按两下 Ctrl 弹出搜索框，同时搜文件名和文件内容">
  </picture>
</p>

#### 🪟 分屏（像 Windows 11）

- **Win+← / →** 分到左右半边，半边时 **Win+↑ / ↓** 变成四分之一；按反方向恢复原来的大小，同一方向再按移到隔壁屏幕。
- **Win+↑** 最大化，**Win+↓** 恢复或最小化；**Win+Shift+← / →** 把窗口移到另一块屏幕。
- **拖到屏幕边缘分屏**：拖到左右边分到半边，拖到上边最大化，拖到四个角分到四分之一；拖动分好的窗口会恢复原来的大小。多显示器之间可以直接拖过；想在中间相接的边分屏时，在目标屏幕的边缘附近停一下，出现预览后松开即可。
- **贴靠助手**：分好一半后，另一半列出其他窗口，点一个就放进去。这是 Windows 的招牌功能，Rectangle 和 macOS 自带的分屏都没有。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/snap-dark.png">
    <img src="docs/images/snap-light.png" width="820" alt="Mac顺 分屏：窗口分到左半边后，右半边用贴靠助手选另一个窗口">
  </picture>
</p>

#### 🖱️ 鼠标像 Windows

- **关闭鼠标加速**：指针移动多远只看鼠标移动多远，和 Windows 一样跟手。速度可以调得比系统设置的最快档还快。
- **滚轮方向和 Windows 一致**：只改鼠标，触控板和妙控鼠标保持苹果的“自然滚动”。
- **按行滚动**：每格滚动固定行数（默认 3 行），没有滚动加速。
- **侧键前进、后退**：鼠标第 4、5 键在访达、浏览器等所有程序里都能用。两个侧键也可以分别改成复制、粘贴、关闭标签页、任务视图、剪贴板历史，或者录一组任意的快捷键（按 Windows 的叫法录，比如 Ctrl+Shift+T）。用罗技、雷蛇等鼠标软件设置侧键的，选“不处理”，侧键原样交给它们，不会冲突。
- **光标大小**：像 Windows 一样在鼠标设置里直接调，1 到 4 倍。退出 Mac顺 后恢复原样。
- 接了多个鼠标时，可以给每个鼠标单独设置。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/mouse-dark.png">
    <img src="docs/images/mouse-light.png" width="420" alt="Mac顺 鼠标设置：关闭指针加速、滚轮方向、按行滚动">
  </picture>
</p>

#### 🖥️ 显示器缩放和刷新率

- 每块屏幕单独选缩放，像 Windows 一样按百分比（100%、125%、150%…）选，不用去系统设置里猜“看起来像多少”。
- 只列出文字清晰的档位。2K 这类非高分屏，macOS 只给 100% 和 200% 两个清晰档位，页面上会说明。
- 每块屏幕单独选刷新率（144 Hz、120 Hz、60 Hz…），高刷屏不用再去系统设置里找。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/display-dark.png">
    <img src="docs/images/display-light.png" width="520" alt="Mac顺 显示器设置：每块屏幕按百分比选缩放，单独选刷新率">
  </picture>
</p>

#### 📊 性能监控

- 菜单栏默认每 5 秒显示 **CPU 和内存占用**，可在 **设置 › 性能监控** 按需开启 **GPU 与芯片温度**、切换 **每 2 / 5 / 10 秒** 刷新间隔（低电量模式自动进一步放缓），或选择 **文字读数、纯图标仪表、折线走势** 样式（图标与折线样式支持合并显示 CPU 和 GPU），关闭后停止采集。
- 内存显示应用、联动和压缩内存占用，不包含可回收的文件缓存；多块 GPU 时显示占用最高的一块。
- 温度取已识别的 CPU/GPU 传感器最高读数，不代表机身温度。部分机型可能无法读取 GPU 或温度，此时显示“暂不可用”。全程在本机读取，不需要管理员权限。

#### ⌨️ 快捷键像 Windows

- **Ctrl 组合键**：Ctrl+C/V/X 复制、粘贴、剪切，Ctrl+A 全选，Ctrl+Z 撤销，Ctrl+Y 重做，Ctrl+S 保存，Ctrl+F 查找。
- **文字编辑**：Home/End 到行首行尾，Ctrl+←/→ 按词移动，Ctrl+Backspace/Delete 按词删除；配合 Shift 选择文字。
- **系统快捷键**：Alt+Tab 切换程序，Alt+F4 退出当前应用，Win+E 打开访达，Win+D 显示桌面，Win+L 锁屏，Win+S 搜索，Win+Space 切换输入法。
- **访达（Finder）**：Ctrl+X 再 Ctrl+V 剪切移动文件，F2 重命名，Enter 打开，Delete 移到废纸篓，Backspace 返回上一级。
- **终端**：Ctrl+C 等控制键保留原样，用 Ctrl+Shift+C/V 复制、粘贴。
- **远程桌面和虚拟机**：保留原生按键行为，包括 ToDesk、向日葵和 UU 远程。
- **两种键盘都能用**：Windows 键盘和 Mac 键盘上 Ctrl、Option、⌘ 的位置不同，Mac顺 自动识别，不用设置。

所有选项都能用设置窗口顶部的**搜索框**找到（⌘F，支持拼音）。

### 下载安装

1. 到 [Releases 页面](https://github.com/LingCore/MacShun/releases/latest) 下载 `MacShun-版本号.dmg`。**同一个文件同时支持 Apple 芯片（M1/M2/M3/M4…）和 Intel 芯片的 Mac**，不用挑版本。
2. 双击打开 dmg，把 **Mac顺** 拖进“应用程序”文件夹。
3. 第一次打开时，macOS 会提示“无法验证开发者”。这是因为作者还没有购买苹果的开发者证书，不是程序有问题。按下面的办法打开一次，以后就不会再问：
   - 打开“系统设置 → 隐私与安全性”，拉到最下面，点 **“仍要打开”**，输入密码确认。
   - 或者在“终端”里运行：`xattr -dr com.apple.quarantine "/Applications/Mac顺.app"`
4. 按提示授权（见下一节），菜单栏出现 Mac顺 的图标就说明在运行了。

系统要求：macOS 14 Sonoma 或更新版本。

### 需要的权限

改写按键和鼠标需要系统授权。Mac顺 的设置窗口会一步一步带你打开对应的设置页，授权后马上生效：

| 权限 | 用来做什么 |
|---|---|
| 辅助功能 | 改写按键、粘贴剪贴板内容、找到文字光标的位置、移动和调整别的程序的窗口（分屏） |
| 输入监控 | 识别是哪个键盘、哪个鼠标在输入（可以给每个设备单独设置） |
| 剪贴板读取 | 在后台记录剪贴板历史（在系统设置里选“始终允许”） |
| 文件和文件夹 | 第一次打开文件搜索时，系统会问能不能访问“桌面”“文稿”“下载”；点了不允许的文件夹搜不到 |
| 屏幕录制 | 首次截图、长截图或识别屏幕文字时由系统提示授权 |
| 本地网络 | 仅开启跨设备剪贴板共享时，用于在局域网内发现并加密连接你的其他 Mac顺 和 Win顺 电脑 |

### 常见问题

**Mac 鼠标滚轮方向是反的，怎么只改鼠标、不改触控板？**
macOS 自带的设置里，鼠标和触控板的滚动方向是绑在一起的。Mac顺 只改鼠标的方向，触控板不受影响。

**Mac 怎么关闭鼠标加速？**
在 Mac顺 的“鼠标”页打开“指针不加速”。指针速度还能调得比系统允许的最快速度更快。

**Mac 有没有像 Windows Win+V 那样的剪贴板历史？**
有。Mac 键盘按 **Option+V** 打开历史，**Command+V** 直接粘贴。Windows 键盘按 **Win+V** 打开。关闭“快捷键像 Windows”后，仍可从菜单栏选择“打开剪贴板历史”。

**和 Karabiner-Elements、LinearMouse、Maccy、Rectangle 有什么区别？**
这些都是很好的工具，但要分别安装、自己配置。Mac顺 把“快捷键 + 鼠标 + 剪贴板 + 分屏”一次做好，默认就是 Windows 的习惯，装上即用，并且针对中文用户做了优化（拼音搜索、国产远程软件）。

**Mac 怎么像 Windows 一样用 Win+方向键分屏？**
装上 Mac顺 就行：Win+← / → 分到左右半边，Win+↑ 最大化，拖到屏幕边缘也能分屏，分好一半后还会列出其他窗口让你选另一半（贴靠助手）。

**Mac 上有没有像 Everything 那样快速搜索文件的工具？**
装上 Mac顺，连按两下 Ctrl 就能搜，支持拼音首字母，不用记完整文件名。

**Mac 怎么搜 Word、Excel、PDF 里的文字？**
Mac顺 的文件搜索也能按内容搜：txt、CSV、JSON、代码、Word、Excel、PowerPoint、PDF 都支持，外接的 NTFS 硬盘也能搜，结果里直接显示匹配的那一行。

**Mac 接了两块屏幕，怎么让它们的缩放不一样？**
macOS 本来就支持每块屏幕单独设置。Mac顺 的“显示器”页把它做成了 Windows 那样的百分比，每块屏一个下拉菜单。

**收费吗？会上传我的数据吗？**
完全免费，源代码公开。检查更新时连接拾穗发布服务，下载安装包时先走第三方加速镜像（目前依次是 gh-proxy.com、ghfast.top），都不行再用 GitHub。可以在设置里关掉自动检查。打开“拾穗计划”页时会读取公开的作品用户数，查询不携带电脑标识。每天最多一次的匿名装机报告只包含随机化的电脑标识（由机器标识加项目名做 SHA-256 得到，不可还原）、版本号、系统版本和芯片架构。可以在“设置 › 通用”里关掉“发送匿名统计”，关掉后便不再发送装机报告。剪贴板内容默认只保存在你自己的电脑上；开启跨设备共享后，数据仅在你局域网或虚拟局域网内的设备间端到端加密直传，不经过云端服务器。

**怎么更新到新版本？**
Mac顺 定期向拾穗发布服务检查有没有新版本，有的话弹出窗口，写着新版本改了什么，点“立即更新”就会先从加速镜像下载（镜像不可用时换下一个地址，最后用 GitHub 原始地址），核对大小、SHA-256 和签名，通过后装好并重新打开，设置和授权都保留。镜像是第三方，安装包是否可信完全靠这些核对：摘要不符的文件会被丢弃。所有地址都失败才会提示重试。也可以在菜单栏图标里选“检查更新…”。0.3.0 仍通过 GitHub 检查更新，升到 0.4.0 后会自动切换到拾穗发布服务。

**以前装的是 Win顺？**
Win顺 改名叫 Mac顺 了。在菜单栏里退出 Win顺，把“应用程序”里的 Win顺 拖到废纸篓，再装 Mac顺。权限、设置和剪贴板历史都会保留，不用重新授权。

**怎么卸载？**
在菜单栏图标里选“退出”，然后把“应用程序”文件夹里的 Mac顺 拖到废纸篓。

### 反馈

遇到问题或有建议，欢迎在 [Issues](https://github.com/LingCore/MacShun/issues) 里提出。

### 从源码编译

只需要 Command Line Tools（`xcode-select --install`），不需要 Xcode。

```bash
scripts/dev-cert.sh            # 第一次：生成开发用的签名证书（只需一次）
scripts/build-app.sh --install # 编译打包，装到“应用程序”文件夹并启动
scripts/test.sh                # 运行单元测试
scripts/check-l10n.py          # 检查界面文字是否都有英文翻译
scripts/release.sh             # 打包发布用的通用版 dmg（Apple 芯片 + Intel）
```

源码结构和设计见 [docs/architecture.md](docs/architecture.md)，需求明细见 [docs/requirements.md](docs/requirements.md)。

---

<a id="english"></a>

## English

**What is MacShun?** MacShun (Mac顺, "a Mac that feels smooth"; formerly WinShun) is a small macOS menu bar app that makes your Mac smoother to use. It adds everyday tools that macOS lacks or hides away: clipboard history, press-Ctrl-twice file search (including text inside files), window snapping, turning off pointer acceleration, and per-display scaling in percentages. If you come from Windows, your habits work too: Alt+Tab to switch apps, Win+E to open Finder, and Windows-style mouse wheel direction. No new shortcuts to learn and no configuration files to write.

It lives in the menu bar, stays out of the Dock, needs no account, and is completely free. It connects to the internet for software updates, public user counts on the Gleaning page, and an anonymous install report at most once a day. You can turn off the report in Settings › General.

The interface is available in **English** and **Simplified Chinese**. It follows your system language, or you can pick one in Settings › General.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/keyboard-dark-en.png">
    <img src="docs/images/keyboard-light-en.png" width="720" alt="MacShun settings window: Windows keyboard shortcuts on Mac">
  </picture>
</p>

### Features

When you open Settings, Software Update, or File Search, the window opens on the display under your pointer.

#### 📋 Clipboard history (Option+V / Win+V)

- Press **Option+V** on a Mac keyboard or **Win+V** on a Windows keyboard. You can also choose **Open Clipboard History** from the MacShun menu bar icon. Click to select, then double-click or press **Return** to paste. In the file search bar, the selected text goes into the query.
- The panel opens next to the text caret or the MacShun file search bar, with the pointer as a fallback. It can open above or below, and its search field stays closest to where it opened.
- **Filter, preview, and paste.** Filter by text, links, images, files, or pinned items. Hover for a quick look, or click the eye or press **⌘Y** to open the side preview. Select text in the preview and press **Return** to paste the selection. Click the return arrow on a row to paste the whole entry.
- **Quick paste.** Hold **Option** to see the numbers for visible entries, then press **Option+1–9** to paste one. Press **Shift+Return** to paste plain text or **⌘⇧C** to copy.
- **Notes and source filters.** Right-click an entry to add or edit a note. Notes are searchable by text and pinyin. Use the source filter in the search bar to narrow results to one app.
- **Paste together.** Hold **⌘** and click text entries in the order you want, or add them from their menus. Press **Return** or choose **Paste Together** to paste them in that order, separated by newlines.
- **Pinyin search** for Chinese text (full pinyin or initials, e.g. `jtb` finds 剪贴板).
- Stores text, images, and files copied in Finder. Find files by name and paste them together again. MacShun reports files that have moved, been deleted, or are temporarily unavailable. Pin frequently used items to show them first. Choose **Clear All** on the right side of the search bar and confirm to clear unpinned history.
- Right-click an image and choose **Copy Text from Image** for the full recognized text. Enter pastes the image.
- **Find pictures by their text.** MacShun recognizes saved clipboard images locally, including older entries. Search for a word or its pinyin, then press Enter to paste the original image or F3 to float it on screen.
- Skips content that password managers mark as concealed. Stays offline and local to your Mac by default.
- **Cross-device clipboard sharing (ShunSync v1).** Optionally enable in **Settings › Clipboard** to sync text, images, files, and folders end-to-end encrypted with other MacShun and WinShun computers on your LAN or virtual LAN (such as Tailscale), with no account or cloud server. Supports LAN auto-discovery, 6-digit pairing, and group invite codes; files sync as manifests with a lightweight corner toast offering one-click **Receive & Copy** or **Save to Downloads** streaming transfer, and concealed password entries are never synced. Pause or resume sharing anytime from the menu bar.
- Choose **Pause Clipboard Recording** from the menu bar to pause new entries. Existing history stays available for search and paste. After resuming, recording starts with the next copy.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/panel-dark-en.png">
    <img src="docs/images/panel-light-en.png" width="400" alt="MacShun clipboard history panel (Win+V) with search">
  </picture>
</p>

#### Screenshots and text capture

- Choose **Take a Screenshot** from the menu bar to drag an area or hover-detect UI elements, panels, and windows. Auto-detection fuses pixel-based visual UI analysis with Accessibility probing, with **scroll wheel** to step through hierarchy levels, **Tab** for window-only mode, visual edge snapping, and full-edge drag resizing/flipping. Press **Enter** or double-click to copy, **⌘S** to save PNG (saves directly when a default folder is set, **⇧⌘S** for Save As), **⇧C** to OCR text inside the selection, and **Esc** or right-click to step back. Press **? / F1** for contextual shortcut hints and **H** to hide the toolbar.
- **Annotation tools and shortcuts.** Alongside rectangle, ellipse, arrow, line/polyline/curve, text, step number, polygon, and solid redaction, MacShun includes **mosaic/blur, freehand brush, highlighter, and spotlight**. Press **1–9 / 0** to switch tools, **[ / ]** to adjust stroke width or strength, and hold **Shift** to lock squares, circles, or 15° angles.
- The line and arrow tools support arrowheads at the start, end or both ends, or a plain line. Choose filled, outlined or open arrowheads. Switch to the selection tool and click an existing line to restyle it or drag its endpoints.
- Open **Annotation Style › Line shape** to draw a polyline or curve with the line tool, or a curve with the arrow tool. Click to add polyline nodes, then press **Enter**, double-click or right-click to finish. Click the first node to close the path. While drawing, press **Delete** to remove the last node or **Esc** to cancel the stroke. Drag out a curve and adjust its curvature with the control points. Double-click a finished line, arrow, polyline or curve to insert a node. Straight lines and arrows become editable polylines and retain their arrowhead styles. Select a node and press **Delete** to remove it. Use **⌘Z** to undo and **⇧⌘Z** to redo. Hold **Shift** to snap to 15° increments while drawing or editing points.
- **Screen color picker**. Hover over a pixel to see its swatch and value in the magnifier. Tap **Shift** to cycle through **HEX, RGB and HSL**. MacShun remembers the format for your next screenshot. Press **C** to copy the displayed value and exit. If you have a polygon selection or annotation edits, the screenshot stays open so you can keep editing.
- **Pixel adjustment**. Use **WASD** to move the pointer by one pixel, or hold **Shift** for ten. Arrow keys also move the pointer before you select an area. After selection, use the arrow keys to move it or **Shift + arrow keys** to resize a rectangular selection.
- **Redaction Assist.** After selecting an area, click Redaction Assist beside Solid Redaction. It looks for likely mainland Chinese mobile numbers and common email addresses on your Mac. Click an orange box to cover it. Copying, saving and floating an image include the covers you applied.
- Double-click the edge of a **Solid Redaction** mark to insert a point and edit it as a filled polygon with its original color. Select a point and press **Delete** to remove it. Use **⌘Z** to undo or **⇧⌘Z** to redo.
- Choose **Copy Text from Screen** and release the mouse to copy text. Simplified Chinese, Traditional Chinese and English are recognized on the Mac.
- **Add notes and numbered steps.** Select Text and click to type. Shift+Enter inserts a line break, and Enter commits the text. Double-click a label to edit it. Drag either side of a selected text box to adjust its width and wrap the text. Use Annotation Style to change the alignment, bold weight, or background of a text box. Choose Step Number and click to place successive badges. Double-click a badge to change its number. Select a mark to move or delete it. Deleting a badge shifts the following numbers down. ⌘Z undoes a change and ⇧⌘Z redoes it.
- **Polygons and annotation styles.** Outline an irregular area with a polygon, or use Anchor Selection to select a shape with a transparent exterior. Once a selection or polygon annotation is closed, drag points to reshape it, double-click an edge to insert a point, or select a point and press **Delete** to remove it. Double-click a rectangle or ellipse edge to insert a point and edit it as a polygon or closed curve, respectively, with its original color and stroke width. Hold **Shift** to snap to 15° increments when drawing or dragging points. Undo selection edits and annotations in order with **⌘Z**, or redo with **⇧⌘Z**. Annotation Style offers color, stroke width and text size controls.
- **Size presets, recent regions, and history.** Press **F** or click the dimension badge to type exact pixel dimensions, lock aspect ratios, or apply common presets. Press **R / ⇧R** to cycle through the last 10 regions on that display, and **, / .** to browse recent captures. Arrow keys move the selection by one physical pixel, and Shift with an arrow adjusts its width or height.
- **Scrolling screenshots**: select the scrollable content of a page, document or chat and press **⌘L / Ctrl+L**. When the controls are ready, scroll slowly down inside the blue frame. Click **Finish** to review. Choose **Annotate** to mark any part of the long image, then **Done** to return to the preview and copy, save a PNG or float it. With Accessibility access, Enter finishes and Esc cancels. Select the scrolling body to avoid repeating a fixed sidebar, and pause large videos before capturing. If an overlap is lost, scroll back slightly and continue.
- **Float an image** with F3 or the Float on Screen button after making a selection. You can also float a clipboard image from the menu bar or an image entry in history. Drag to move, drag a corner or scroll to zoom, double-click for actual size, and Control-scroll for opacity. Right-click for in-pin OCR text copy, in-place re-annotation, 90° rotation, horizontal/vertical flip, click-through mode (restore anytime via **Restore Pin Interaction** in the menu bar), copy, save, or close.
- Both actions have optional shortcuts under **Settings › Keyboard › Screenshot shortcuts**. Allow screen recording when prompted on first use.

#### 🔍 File search (like Everything)

- **Press Ctrl twice** to open a capsule search bar; results appear as you type, instantly even across tens of thousands of files. Pressing it again while open keeps it open; Esc closes it.
- **Pinyin search** for Chinese file and app names.
- **Find system features in everyday language**: try “no sound” for Sound Output or “task manager” for Activity Monitor. Press Enter to open the selected result, or choose **System** to browse. Matching happens on your Mac.
- **Searches file contents too**: text inside txt, Markdown, CSV and JSON files, code (ts, js, py, swift, vue, html…), config (yaml, xml, toml), subtitles (srt, ass, lrc), plus Word, Excel, PowerPoint and PDF (skipping generated and dependency folders like node_modules, dist and build); text in screenshots, photos and scanned PDFs is recognized too, with the matching line shown in the results. Works for short Chinese queries and doesn't depend on Spotlight. Start in **Files & Features**. Press Tab to switch to **Contents**, **System**, or **All**; only Contents and All search inside files. Files you open often rank higher.
- **Filter files** with `quote *.pdf !draft` to find PDFs and exclude names containing “draft”. Use `ext:pdf,docx` for either type. In Contents, words match document text while filters apply to the file name. Quote the whole query to search for a literal name such as `"!important"`.
- Enter opens the selection and Ctrl+Enter reveals it in Finder. Press **⌘Y** or click Quick Look to preview it, use ↑↓ to browse matches, and press Esc to return to the selected result.
- Press **Ctrl+O / ⌘O** or click **More Actions** to open the selected result’s actions. Use the arrow keys to choose an action, press **Enter** to run it, or **Esc** to return to search.
- **Drag out search results.** Drag a file or folder from the results to Finder or another app that accepts file drops. This works for both file name and content matches.
- **Expand or move the search panel**. Use **Ctrl+E** or the right-hand button to expand. Select more than one file kind and combine the selection with date, size, or folder filters. Put filters at the left or above the results. Click a column to sort and scroll to the bottom to load more. Drag the top grip to move the window or the lower-right corner to resize the expanded panel. The compact and expanded views remember their positions separately and restore them on the same display. Press **Ctrl+E** again to collapse with your current search, or **⌘Y** for Quick Look.
- **Search a specific folder**. Use **Search This Time** in the expanded panel’s Folder menu to search names in the folder and its subfolders. Choose **Add to Search Locations** to include it in future global searches. You can also manage folders in **Settings → File Search → Search Scope**. Mount SMB shares in Finder first. Added shares are indexed by name, marked offline when disconnected, and restored when remounted.
- **Save filters and find Chinese homophones**. Saved Filters recalls a folder, kind, date, size, and sort order while keeping your current query. If a Chinese file name has no literal match, search tries whole-syllable homophones.
- **Search within a project.** Select a folder and press **⌘F**, or choose **Search in This Folder** from its context menu. Words and filters apply throughout its subfolders. Choose Contents for previously indexed text. **Esc** returns to the previous query and selection.
- **Pin project folders.** Right-click a folder result and choose **Pin to Project Folders**. Press Ctrl twice to see your pins in the empty search panel. Click a folder or press Enter to search inside it, and press Esc to return to the list. Select a folder and click **Unpin** to remove its shortcut.
- **Jump to a folder in Open and Save dialogs.** With a native file dialog active, press **Ctrl twice** and find a folder or file. Press **Enter** to go to that folder or the file’s enclosing folder. The Save dialog keeps the name you entered.
- **Paste a path**: relative paths like `art/gpt/style_reference.png`, paths written with Finder's localized folder names, `~/Desktop/…` and full paths all work, and so do Windows paths like `D:\Docs\contract.docx` (quoted or not; the drive letter is ignored). If the folders are partly wrong, files with a matching name still show up, ranked by how much of the path matches. A native folder path ending in `/` lists its immediate children, even outside the index. Keep typing to filter that folder. Words can also match a mix of folder and file names: `spring quote` finds `Spring Project/Quote.xlsx`. Exact names come first, with ties favoring the current Finder folder.
- Searches your home folder, Applications and external drives (scanned in the background, Windows system folders skipped). The file name index stays in memory and the content index stays on your Mac; nothing goes online.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/search-dark-en.png">
    <img src="docs/images/search-light-en.png" width="600" alt="MacShun file search: press Ctrl twice to search file names and contents">
  </picture>
</p>

#### 🪟 Window snapping (like Windows 11)

- **Win+← / →** snaps to the left or right half; from a half, **Win+↑ / ↓** snaps to a quarter. The opposite arrow restores the window, the same arrow again moves it to the next display.
- **Win+↑** maximizes, **Win+↓** restores or minimizes; **Win+Shift+← / →** moves the window to the other display.
- **Drag to screen edges**: left or right edge for halves, top edge to maximize, corners for quarters. Dragging a snapped window restores its size. Drag freely between displays. To snap at a shared edge, pause near the edge on the display you want, then release when the preview appears.
- **Snap Assist**: after snapping to a half, your other windows appear in the other half; click one to fill it. Neither Rectangle nor macOS tiling has this.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/snap-dark-en.png">
    <img src="docs/images/snap-light-en.png" width="820" alt="MacShun window snapping: after snapping a window to the left half, Snap Assist offers windows for the right half">
  </picture>
</p>

#### 🖱️ Windows mouse behavior on Mac

- **Disable mouse acceleration**: pointer movement is linear, just like Windows. Speed can go beyond the fastest system setting.
- **Windows scroll direction for the mouse only**: the trackpad and Magic Mouse keep Apple's natural scrolling.
- **Line-by-line scrolling**: a fixed number of lines per notch (3 by default), no scroll acceleration.
- **Back / forward side buttons** work in Finder, browsers and every other app. Each side button can also be set to copy, paste, close tab, task view, clipboard history, or any shortcut you record (in Windows terms, e.g. Ctrl+Shift+T). If you set up the side buttons in Logitech, Razer or other mouse software, choose “Leave alone” and the buttons go straight to it.
- **Cursor size** right in the mouse settings, 1× to 4×, like Windows. Restored when you quit MacShun.
- Per-device settings when you use more than one mouse.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/mouse-dark-en.png">
    <img src="docs/images/mouse-light-en.png" width="420" alt="MacShun mouse settings: disable pointer acceleration, Windows scroll direction, line scrolling">
  </picture>
</p>

#### 🖥️ Display scaling and refresh rate

- Pick scaling for each screen in Windows-style percentages (100%, 125%, 150%…) instead of guessing "looks like" resolutions.
- Only sharp options are listed. For non-Retina screens such as 1440p monitors, macOS only offers 100% and 200% sharply, and the page says so.
- Pick the refresh rate for each screen (144 Hz, 120 Hz, 60 Hz…) right next to scaling.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/display-dark-en.png">
    <img src="docs/images/display-light-en.png" width="520" alt="MacShun display settings: Windows-style scaling percentages and refresh rate for each screen">
  </picture>
</p>

#### 📊 Performance monitor

- See **CPU and memory usage** in the menu bar every 5 seconds by default; turn on **GPU and chip temperature** as needed, choose **Every 2 / 5 / 10 seconds** refresh intervals (slowed further in Low Power Mode), or switch between **Text, Icons, and Trend** styles in **Settings › Performance Monitor** (icon and trend styles can combine CPU and GPU); disabled readings stop collecting.
- Memory includes app, wired and compressed memory, excluding reclaimable file caches. With multiple GPUs, the busiest GPU is shown.
- Temperature is the highest reading from recognized CPU/GPU sensors, rather than the enclosure temperature. Unsupported GPU or temperature readings show “Unavailable.” All readings stay on the Mac and require no administrator access.

#### ⌨️ Windows keyboard shortcuts on Mac

- **Ctrl shortcuts**: Ctrl+C/V/X copies, pastes and cuts, Ctrl+A selects all, Ctrl+Z undoes, Ctrl+Y redoes, Ctrl+S saves and Ctrl+F finds.
- **Text editing**: Home/End goes to the start/end of a line, Ctrl+←/→ moves by word, and Ctrl+Backspace/Delete deletes a word. Hold Shift to select text.
- **System shortcuts**: Alt+Tab switches apps, Alt+F4 quits the current app, Win+E opens Finder, Win+D shows the desktop, Win+L locks the screen, Win+S searches, Win+Space switches input method.
- **Finder**: Ctrl+X then Ctrl+V cuts and moves files, F2 renames, Enter opens, Delete moves to Trash, Backspace goes up a folder.
- **Terminals**: Ctrl+C and other control keys stay native; use Ctrl+Shift+C/V to copy and paste.
- **Remote desktops and virtual machines** receive their original keyboard input.
- **Works with both keyboard types**: Windows and Mac keyboards put Ctrl, Option and ⌘ in different places — MacShun detects which one you are typing on.

Every option can be found with the **search box** at the top of the settings window (⌘F).

### Download and install

1. Download `MacShun-<version>.dmg` from the [Releases page](https://github.com/LingCore/MacShun/releases/latest). **One universal file runs natively on both Apple Silicon (M1/M2/M3/M4…) and Intel Macs.**
2. Open the dmg and drag **Mac顺** into Applications.
3. On first launch macOS says it cannot verify the developer, because the app is not yet signed with a paid Apple Developer ID. Open it once using either method; macOS won't ask again:
   - Go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
   - Or run in Terminal: `xattr -dr com.apple.quarantine "/Applications/Mac顺.app"`
4. Grant the permissions below. When the MacShun icon appears in the menu bar, it is running.

Requires macOS 14 Sonoma or later.

### Permissions

| Permission | Why |
|---|---|
| Accessibility | Remap keys, paste from history, find the text cursor, move and resize other apps' windows (snapping) |
| Input Monitoring | Tell which keyboard or mouse an event came from (per-device settings) |
| Pasteboard access | Record clipboard history in the background (choose "Always Allow") |
| Files and Folders | The first time you open file search, macOS asks about Desktop, Documents and Downloads; folders you deny won't be searched |
| Screen Recording | Prompted on first use of screenshots, scrolling capture, or copying text from screen |
| Local Network | Only used when cross-device clipboard sharing is enabled, to discover and connect over encrypted LAN links to your other MacShun and WinShun computers |

The settings window walks you through each one, and changes take effect immediately.

### FAQ

**How do I reverse the mouse scroll direction without changing the trackpad?**
macOS ties the two together. MacShun changes the direction for mice only.

**How do I turn off mouse acceleration on macOS?**
Enable "linear pointer" on MacShun's Mouse page.

**Is there a Win+V clipboard history for Mac?**
Yes. On a Mac keyboard, **Option+V** opens history and **Command+V** pastes. On a Windows keyboard, press **Win+V** for history. With Windows shortcuts turned off, choose **Open Clipboard History** from the MacShun menu bar icon.

**How do I snap windows with Win+arrow keys on a Mac, like on Windows?**
Install MacShun: Win+← / → snaps to halves, Win+↑ maximizes, dragging to screen edges snaps too, and Snap Assist offers your other windows for the other half.

**How is it different from Karabiner-Elements, LinearMouse, Maccy or Rectangle?**
Those are great tools, but each does one thing and needs setup. MacShun does keyboard, mouse, clipboard and window snapping together, with Windows behavior as the default, and is tuned for Chinese users (pinyin search and support for popular Chinese remote desktop apps).

**Is there an Everything-like file search for Mac?**
MacShun includes one: press Ctrl twice and start typing.

**How do I search text inside Word, Excel or PDF files on a Mac?**
MacShun's file search also matches contents of txt, CSV, JSON, code, Word, Excel, PowerPoint and PDF files, including on external NTFS drives, and shows the matching line.

**How do I use different scaling on two monitors?**
macOS supports per-display scaling; MacShun's Displays page shows it as Windows-style percentages, one menu per screen.

**I have WinShun installed. How do I upgrade?**
WinShun has been renamed MacShun. Quit WinShun from the menu bar, drag Win顺 from Applications to the Trash, then install MacShun. Permissions, settings and clipboard history carry over, so there is nothing to grant again.

**Is it free? Does it collect data?**
Free and open source. MacShun checks for updates through the Gleaning release service and tries third-party mirrors for installer downloads, with GitHub as the fallback. You can turn off automatic checks in Settings. Opening the Gleaning page fetches public user counts without sending a computer identifier. The anonymous install report runs at most once a day and includes a SHA-256 hash of the machine identifier and project name, the app version, the macOS version, and the chip architecture. You can turn off install reports with “Send anonymous usage statistics” in Settings › General. Clipboard history stays local to your Mac by default; if you enable cross-device sharing, data is transferred end-to-end encrypted directly across your LAN or virtual LAN without any cloud server.

**How do I update?**
MacShun periodically checks the Gleaning release service. When there is a new version, a window shows what's new; click Update Now to download it from an accelerated mirror (falling back to the next address, and finally to the original GitHub URL), verify its size, SHA-256 and signature, then install and reopen, keeping settings and permissions. Mirrors are third parties, so trust comes entirely from those checks: a file with a wrong digest is discarded. You only see an error to retry if every address fails. You can also choose Check for Updates… from the menu bar icon. Version 0.3.0 checks GitHub for updates and switches to the Gleaning release service once it upgrades to 0.4.0.

### Feedback

Bug reports and suggestions are welcome in [Issues](https://github.com/LingCore/MacShun/issues).

### Build from source

Only the Command Line Tools are needed (`xcode-select --install`), not Xcode.

```bash
scripts/dev-cert.sh            # once: create a local code-signing certificate
scripts/build-app.sh --install # build, install to /Applications and launch
scripts/test.sh                # run unit tests
scripts/check-l10n.py          # check that every UI string has an English translation
scripts/release.sh             # build the universal release dmg (Apple Silicon + Intel)
```

See [docs/architecture.md](docs/architecture.md) for architecture and module details, and [docs/requirements.md](docs/requirements.md) for product requirements.

---

## LINUX DO

本项目积极参与并认可 [LINUX DO 社区](https://linux.do)。

MacShun is proud to be part of the [LINUX DO community](https://linux.do).

## 许可证 · License

Mac顺 以 [MIT 许可证](LICENSE) 发布。Copyright © 2026 LingCore.
借用的第三方代码登记在 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

MacShun is released under the [MIT License](LICENSE). Copyright © 2026 LingCore.

Windows 是微软公司的商标，Mac 和 macOS 是苹果公司的商标。本项目与微软、苹果没有任何关联。
Windows is a trademark of Microsoft Corporation. Mac and macOS are trademarks of Apple Inc. This project is not affiliated with Microsoft or Apple.
