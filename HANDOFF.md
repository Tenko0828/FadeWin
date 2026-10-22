# FadeWin 交接文档

给接手的 AI 助手（Gemini）看。目标：在不破坏现有效果的前提下**继续优化**、**排查 bug**。读完这份文档再动代码。

---

## 0. 先遵守这几条

- **不要推送到 GitHub，也不要建远端仓库。** 用户明确要求先在本地用。所有改动只 `git commit` 到本地 `main`，提交信息用中文。
- **系统权限只能用户自己点。** 屏幕录制授权、系统弹出的「允许」按钮都不要试图用脚本或模拟点击去点，提示用户自己操作。
- **代码风格跟着现有代码走**：注释和界面文字用中文，注释写“为什么”而不是“做了什么”，命名沿用现有的（`overlays`、`shown`、`vis`、`Replica` 等）。
- **每次改完都要真的跑起来看。** 只编译通过不算验证，方法见第 4 节。
- 用户是在**自己正在用的电脑**上测试。测试会抢前台窗口、改速度设置，测完要把设置还原（见 4.3），并尽量少打断用户。

---

## 1. 这是什么

macOS 菜单栏小工具：**窗口越久没碰越淡，点一下恢复**。

- 位置：`~/Documents/大肥鱼の家/FadeWin`（Swift Package，无 Xcode 工程）
- 系统：macOS 27.0.1，SDK 26.5，只装了 Command Line Tools（**没有 `metal` 编译器**）
- 安装后：`/Applications/FadeWin.app`，开机自启，Bundle ID `local.tenko.fadewin`
- 用户当前设置：外观＝透视（`seeThrough`），速度＝快（`fast`），隐私薄雾＝开

### 三种外观（菜单栏「外观」）

| 外观 | 做法 | 权限 |
| --- | --- | --- |
| 透视 `seeThrough`（用户在用） | 用 ScreenCaptureKit 抓「窗口后面」的画面盖在窗口上，按闲置程度变淡；边缘画液态玻璃边框；底下加隐私磨砂 | 屏幕录制 |
| 液态玻璃 `glass` | 盖一块 `NSGlassEffectView`，越久越厚（macOS 26+） | 无 |
| 纯色薄雾 `veil` | 盖一层白/黑半透明色块 | 无 |

选了透视但没授权时，自动用玻璃（或薄雾）顶着。

### 一个已经验证过的硬限制

**macOS 不允许改别的 App 窗口的透明度。** 试过私有接口 `SLSSetWindowAlpha`（SkyLight），返回 0 但窗口毫无变化。所以所有效果都是**在目标窗口正上方叠一个我们自己的无边框窗口（下文叫“雾层”）**，不要再在这条路上花时间。

---

## 2. 代码结构

| 文件 | 内容 |
| --- | --- |
| `Sources/FadeWin/Fader.swift` | 核心。窗口列表轮询、闲置计时、雾层创建/层级/位置、60 帧动画、移动与调度中心处理、三种外观的绘制 |
| `Sources/FadeWin/SeeThrough.swift` | 透视用的屏幕抓取：`Replica`（每个窗口一路 `SCStream`）和 `SeeThrough`（管理所有抓取、决定排除哪些窗口） |
| `Sources/FadeWin/GlassRim.swift` | 玻璃边框的 Core Image 内核、`Edges`（哪些边是真边）、`SeeView`（透视雾层的视图层级） |
| `Sources/FadeWin/main.swift` | 菜单栏菜单（含「不褪色的窗口和 App」）、图标渲染、开机启动、`--check-permission` / `--list-video` 等命令行参数 |
| `Sources/FadeWin/VideoWatch.swift` | 识别正在播放视频的 App：读系统的“别让屏幕休眠”申请，并把浏览器辅助进程追溯回浏览器本体 |
| `Sources/FadeWin/Hotkeys.swift` | 全局快捷键（Carbon，不需要权限）：⌥⌘P 暂停/继续、⌥⌘R 全部恢复、⌥⌘L 锁定/解锁当前窗口 |
| `Sources/FadeWin/Hud.swift` | 按快捷键后屏幕上方的小提示 |
| `build.sh` | 打包 `.app`、渲染图标、签名；`./build.sh install` 装进「应用程序」并重启 |
| `Resources/Info.plist` | `LSUIElement`（不进 Dock） |

### 2.1 两个循环（`Fader`）

- **`poll()`，每秒 30 次**：`CGWindowListCopyWindowInfo` 取屏幕上所有窗口（从前到后）。算出：
  - 谁是「正在用」：**排在最前面的普通窗口，并且属于前台 App**（只看前台 App 不够——点桌面时访达是前台，但它的窗口可能压在后面）。
  - 每个窗口的目标褪色程度 `targets[id]`（0…1），由闲置时间经 `1-(1-t)²` 曲线算出。
  - 创建/移动雾层，保证雾层在目标窗口正上方（只在层级不对时才调用 `order(.above, relativeTo:)`）。
  - 透视模式下把需要抓取的窗口交给 `SeeThrough.sync`。
- **`animate()`，每秒 60 次**：`shown[id]` 平滑追 `targets[id]`（褪色时速率 2.5，恢复时 10，约 0.3 秒）；`vis[id]` 是“显现度”，窗口在动时立刻归零，停稳后淡回。最终绘制量 = `shown × vis`，交给 `apply()`。雾层淡到 0 才收走。

### 2.2 透视的关键设计（`SeeThrough.sync`）

一个窗口 X 的“后面”＝**整块屏幕去掉 X 自己，以及所有排在 X 前面的窗口**（包括 Dock、菜单栏、前面窗口的雾层），再加上 X 自己的雾层 ID（刚建的雾层可能还没出现在窗口列表里）。

这样叠在一起的窗口才能各褪各的：如果只排除 X 自己，X 的画面里会带着前面窗口 B 的旧图，B 褪色时就会透出这张旧图，看起来 B 褪不干净。之前修过这个 bug，**不要改回去**。

- 每路抓取最多约 220 万像素；同时抓 3 路以上时降到每秒 15 帧；最多 6 路（`maxReplicas`），超出的用薄雾顶着。
- 只改了层级（点了别的窗口）时只换排除列表，不重置画面；位置/尺寸变了才 `awaitFreshFrame()`，等**尺寸对得上的新帧**到了才算就绪，避免闪一下旧画面。
- `Replica` 自己当 `SCStreamDelegate`，抓取意外停止时会从列表里移除，下一轮重抓。

### 2.3 透视雾层的视图层级（`SeeView`，从下到上）

1. `frost`：`NSVisualEffectView`，`.behindWindow`，`state = .active`（雾层窗口永远不是活动窗口，不设 active 就不磨砂）。模糊的是目标窗口自己的内容 → 隐私薄雾。
2. `canvas.base`：抓到的“窗口后面”的实时画面，不透明度 `0.72 × 程度`（`maxSeeThrough`，留一点影子，用户嫌全透明看不见）。
3. `canvas.rim`：玻璃边框，不透明度 `min(1, 程度×1.6)`，比中间更早出现，褪尽后轮廓仍清楚。

所有 `CALayer` 都关了隐式动画（`actions` 设成 `NSNull`），否则自带的 0.25 秒过渡会让画面一闪一闪。

### 2.4 玻璃边框内核（`GlassRim`）

- 用的是 **Core Image Kernel Language 字符串**（`CIKernel(source:)`，已废弃但能用）。因为机器上没有 `metal` 编译器，没法编 `.metallib`。
- 圆角矩形距离场 → 边缘一圈采样点往里偏（折射/扭曲），红绿蓝偏移量不同（色散），左上来光加高光线。
- **内核是运行时编译的**，编译失败只会让 `kernel == nil`、边框整个消失，**打包时不报错**。改内核后必须单独跑一次确认（见 4.4）。踩过的坑：变量名 `half` 是 Metal 的类型名，会编译失败。
- `Edges`：窗口被屏幕边缘截断时，截断的那一侧不画圆角和边框（实现方式是把形状往画面外延伸）；`SeeView` 也用 `maskedCorners` 和自绘遮罩图跟着处理。

### 2.5 几个特殊场景

- **点回窗口时的闪烁**：系统会先把窗口提到最前、盖过雾层。所以在全局 `mouseDown`（按**所有层级窗口**的真实顺序判断点中的是谁）和 `didActivateApplication` 时，把正在恢复的雾层临时提到 `.floating` 层，并在恢复期间冻结抓取范围（`frozen`）。
- **窗口在动**（拖动、点壁纸显示桌面时所有窗口滑开）：雾层的 frame 一变就 `vis = 0` 立刻隐藏，停稳 0.35 秒（`settleDelay`）且抓取画面对上新位置后再淡回。
- **调度中心（三指上滑）**：窗口被系统缩放，但 `CGWindowList` 里的位置不变，没法跟。识别方法：出现名为 `ExposeShieldWindow` 的窗口（WindowManager 进程，层级 19；没权限读不到窗口名时按进程名+层级认）。期间全部隐藏，退出后多等 0.35 秒再淡回。
- **切换桌面空间 / 最小化**：不在屏幕上的窗口保留闲置计时，每 10 秒用 `.optionAll` 清理一次已经关掉的。

### 2.6 不褪色的情况

- **锁定的窗口**（⌥⌘L 或菜单）：只在本次运行有效（窗口编号重启会变）。
- **永不褪色的 App**（菜单里「「某 App」永不褪色」）：按 Bundle ID 存在 `exemptApps`。
- **正在播放视频的 App**：每秒查一次 `IOPMCopyAssertionsByProcess`，类型是 `PreventUserIdleDisplaySleep` / `NoDisplaySleepAssertion` 的申请者（听音乐不会申请这类）。用私有函数 `responsibility_get_pid_responsible_for_pid` 把 WebKit 等辅助进程追溯到浏览器本体。**Chrome 实测有效**（申请名 “Video Wake Lock”）；Safari 未实测。粒度是整个 App：浏览器放视频时它所有窗口都不褪色。`--list-video` 可以列出当前被认定在放视频的 App。
- 层级：除了普通窗口（0），浮动面板（3）和模态面板（8）也会褪色（有些 App 的设置窗口是面板）。雾层放在和目标窗口相同的层级上，恢复时提到目标层级 +1。

### 2.7 设置（`defaults read local.tenko.fadewin`）

| 键 | 值 |
| --- | --- |
| `speed` | `demo`（3 秒开始/12 秒褪尽）、`fast`（15/90）、`normal`（60/600，默认）、`slow`（300/3600） |
| `style` | `seeThrough` / `glass` / `veil` |
| `paused` | 布尔 |
| `noPrivacyFrost` | 布尔，为真时关掉隐私薄雾 |
| `exemptApps` | 字符串数组，永不褪色的 App 的 Bundle ID |

---

## 3. 编译、安装、权限

```bash
cd ~/Documents/大肥鱼の家/FadeWin && swift build                 # 只编译，看有没有错
cd ~/Documents/大肥鱼の家/FadeWin && ./build.sh install          # 打包、签名、装进 /Applications 并重启
```

- 签名是 ad-hoc，但 `build.sh` 用了固定的签名要求 `designated => identifier "local.tenko.fadewin"`。**实测重新编译后屏幕录制授权仍然有效**，不要去掉这一行，否则每次重编都要用户重新授权。
- 检查 App 自己有没有屏幕录制权限（必须以 App 身份跑，不能在终端里直接运行二进制，否则查到的是终端的权限）：

```bash
pkill -x FadeWin; open --stdout /tmp/perm.txt -a /Applications/FadeWin.app --args --check-permission; sleep 2; cat /tmp/perm.txt
```

- 用户授权后有时还会弹「……正在请求绕过系统无痕浏览窗口选择器」，这是 macOS 的二次确认，要用户自己点「允许」。macOS 还会定期弹「是否继续允许」，属于系统行为。

---

## 4. 怎么验证

### 4.1 看效果

```bash
defaults write local.tenko.fadewin speed demo
pkill -x FadeWin; sleep 0.5; open /Applications/FadeWin.app; sleep 1
osascript -e 'tell application "Finder" to activate'; sleep 14
screencapture -x /tmp/fade.png    # 然后看图
```

### 4.2 看有没有崩溃

```bash
pgrep -lf MacOS/FadeWin
ls -t ~/Library/Logs/DiagnosticReports | grep -i fadewin | head
```

### 4.3 测完一定要还原

```bash
defaults write local.tenko.fadewin speed fast
pkill -x FadeWin; sleep 0.5; open /Applications/FadeWin.app
```

### 4.4 改了玻璃边框内核时

把 `GlassRim.swift` 里的内核字符串抽出来，写一个独立的小 Swift 程序用 `CIKernel(source:)` 编译、对一张测试图跑一次、存成 PNG 看。`CIKernel(source:)` 返回 `nil` 就是编译失败。

### 4.5 截图看不出来的东西

动画是否流畅、恢复是否闪烁、显示桌面和调度中心的过渡，截图基本看不出来。这类改动要请用户实测，并说清楚自己没验证到哪一步。

---

## 5. 已知问题和需要检查的地方

按优先级排列。标 ⚠️ 的是我（Claude）明确知道没解决的；其余是没测过、可能有问题的。

1. ⚠️ **用 Cmd-Tab 切回窗口时可能先清晰一两帧。** 系统的激活通知比窗口提到前台晚，没有鼠标按下事件可以提前处理。可以考虑监听键盘（需要辅助功能权限，用户目前没给）或别的更早的信号。
2. ⚠️ **恢复的 0.3 秒里，原来压在它前面的窗口那块区域可能短暂透出壁纸。** 原因：恢复期间冻结了抓取范围，排除列表还是旧的（把前面的窗口排除了），而窗口已经到了最前面。
3. ⚠️ **圆角是写死的**：透视 22 点、玻璃 20 点、薄雾 10 点。macOS 26 的窗口圆角因窗口类型而异（有工具栏的更大），对不齐时边角会有细小错位。可以研究按窗口类型或尺寸估算圆角。
4. **多显示器没有测过**：窗口跨两块屏、屏幕倍率不同、屏幕排列不在主屏右侧时，`sourceRect` 换算、雾层坐标、截断判断都可能出错。用户有一块 1135×789 的副屏（见 `CGWindowList` 输出）。
5. ~~线程安全~~：已由 Codex 改成 `OSAllocatedUnfairLock` 保护（`Replica.geometry`）。
6. **性能（已优化一轮）**：最初几个窗口同时透视时 CPU 24%–47%。`sample` 采样发现大头是玻璃边框——开销在**每次提交 Core Image 渲染任务**，不在像素多少（拆成四条边带反而更慢）。现在：每帧只提交一次、边框每秒最多重画 10 次、抓取 20 帧（3 路以上 10 帧）、雾层显示时窗口列表每秒 20 次（没有雾层时 4 次）、透明度没变就不重设。实测几个窗口透视时约 16%，没有雾层时约 1.5%。还能继续：被完全遮住的窗口暂停抓取；背后画面不变时 SCK 本来就不出新帧。
7. **调度中心识别靠的是窗口名 `ExposeShieldWindow`**，系统更新可能会变。App Exposé（三指下滑）、台前调度（Stage Manager）、全屏 App、切换桌面空间的动画都没测过。
8. **窗口被 App 自己持续改尺寸**（比如有动画的窗口）时雾层会一直藏着，可以接受，但值得确认不会卡住。
9. **非圆角或异形窗口**（游戏、某些 Electron App、无边框窗口）上，雾层是矩形加圆角，形状会对不上。
10. **浅色/深色模式切换时**，薄雾和玻璃染色是每帧读外观的，应该没问题，但没专门测。
11. **Gemini 设置窗口不褪色**：用户报告过。没能自动打开它确认（终端没有发送按键的权限），推测是浮动面板，已把层级 3 和 8 纳入处理，**待用户确认**。如果仍不褪色，让用户开着那个窗口，用 `CGWindowListCopyWindowInfo` 看它的 layer/alpha/尺寸。
12. **菜单「被遗忘的窗口」只显示 App 名**：读窗口标题需要屏幕录制权限，现在用户已经授权了，标题应该能显示，可以确认一下。
13. **`SCShareableContent` 刷新时机**：窗口列表里出现不认识的窗口就会刷新（有 0.4 秒节流）+ 每 5 秒刷新一次。新窗口频繁出现时会不会刷得太多，值得看一眼。

---

## 6. 可以继续优化的方向

- ~~动画驱动~~：macOS 14+ 已改用 `NSScreen.displayLink` 跟屏幕刷新同步（`FrameTicker`），13 退回 60 Hz 计时器。
- **窗口移动的感知**：现在是每秒 30 次轮询。有辅助功能权限的话可以用 `AXObserver` 订阅窗口移动/缩放事件，更及时也更省电（要先征得用户同意加权限）。
- **玻璃边框**：可以加一点边缘内侧的模糊、根据背景亮度调整高光强度、让色散随窗口大小缩放；圆角按窗口实际情况自适应。
- **设置界面**：现在只有菜单。可以加一个小设置窗口：自定义开始褪色时间、最大透明度、边框强度、排除某些 App（比如视频播放器、终端）。
- ~~排除名单~~、~~快捷键~~：已完成（见 2.6 和 Hotkeys.swift）。
- **README 截图**：README 里还没有效果图。

---

## 7. 提交历史（从新到旧）

```
e07ee89 透视：隐私薄雾；被屏幕截断的边不画圆角和边框；调度中心期间隐藏；自检修复（点桌面/Dock 误判、抓取停止通知、旧帧、切换空间丢计时、暂停恢复、权限查询频率）
2c045af 透视：窗口移动时雾层先隐藏，停稳且抓取画面对上新位置后再淡回；轮询提到 30 次/秒；屏幕外部分不处理
5a13ec7 透视：液态玻璃边框（折射+色散+高光）；恢复时把雾层提到最上并冻结抓取范围，修复闪烁
e9ca539 透视：动画改为 60 帧平滑过渡，回到前台时快速恢复；按窗口层级排除前面的窗口，修复重叠和 Dock 重影；降低最大透明度和抓取分辨率
eaf5624 新增 --check-permission，用来排查屏幕录制授权
78f43d8 新增透视外观：用屏幕抓取模拟窗口变透明（需屏幕录制权限）
16dc61c 新增液态玻璃外观（macOS 26+）：窗口越久没碰越磨砂
3fc1fe7 褪色曲线改为先快后慢，各档速度提前；新增「演示」档
25bf12c 窗口褪色：窗口越久没碰越淡，点一下恢复
```

## 7.1 和 Codex 协作的方式

简单、文件边界清楚的任务交给 Codex（`~/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex exec -s workspace-write -C <工作树> -o <结果文件> - < 任务说明`）。先 `git worktree add -b codex/<名字> ../FadeWin-codex HEAD` 给它单独的工作树，任务说明里写清**只许改哪些文件、不许 install/pkill/push**。它的沙箱写不了主仓库的 `.git`，所以提交要由我们在它的工作树里代做，审查后 `git merge`，再 `git worktree remove`。

## 8. 用户提过的反馈（按时间）

便于理解为什么代码是现在这样：

1. 「似乎无效」→ 原来的褪色太慢太淡，改成先快后慢并提前开始。
2. 「不仅是蒙一层雾，而是窗口淡化、透明化，最好适配液态玻璃」→ 加了玻璃外观和透视外观。
3. 「动画不流畅；窗口重叠出 bug；完全虚化后太透明啥都看不到；点击恢复太生硬；透明窗口多了渲染出问题」→ 60 帧动画、按层级排除、最大透明度 72%、恢复动画、限制抓取分辨率和帧率。
4. 「恢复动画闪烁；褪尽后边框不明显；液态玻璃边框应该有色散和扭曲」→ 恢复时提层级、玻璃边框内核。
5. 「点壁纸显示桌面时，窗口快速退开，渲染闪烁卡顿」「三指上滑调度中心也一样」→ 移动时隐藏、调度中心识别。
6. 「淡化后的窗口加一层薄雾，加强隐私」→ 隐私磨砂。
7. 「窗口拉到屏幕外后边缘有一个弧形小三角」→ 截断边处理。
8. 以上用户实测**都正常了**。
9. 「Gemini 的设置窗口不会褪色」→ 纳入浮动/模态面板层级（待确认）。
10. 「视频播放时（App 或网页）不能褪色」→ VideoWatch。
11. 「加一个锁定窗口、关闭其褪色的功能」→ 锁定窗口 + 永不褪色的 App + ⌥⌘L。
