# AGENTS.md

给后续 Claude Code 编辑这个项目的快速上手 + 踩坑总结。

## 是什么

macOS 悬浮窗,把预设 prompts 一键发到 **终端里跑的 Claude Code CLI**(iTerm2 / Apple Terminal)。同时起一个 LAN HTTP server 让手机当遥控器。

**目标范围明确只覆盖终端 CLI**。Electron / Chromium / 浏览器 / Cursor / Claude Desktop 都不在范围内 — 历史上为了适配它们引入的复杂度(标定位置 / 真实 click / 坐标转换)已经全部砍掉,不要再加回来。

## 构建

```bash
./build.sh             # 编译 + 打包到 ./PromptKeyboard.app
./build.sh install     # 同上,并替换 /Applications/PromptKeyboard.app
swift build -c release # 仅编译,不打包
```

每次改完代码:
```bash
osascript -e 'tell application "PromptKeyboard" to quit'; sleep 1
./build.sh install && open /Applications/PromptKeyboard.app
```

## 代码地图

| 文件 | 干什么 |
|---|---|
| `PromptKeyboardApp.swift` | App entry / `AppDelegate` / `TerminalTarget` / `FloatingPanel` / HTTP route |
| `ContentView.swift` | SwiftUI 主面板 — header / targetBar / 卡片网格 / footer / 编辑 popover / 模板菜单 |
| `EditorView.swift` | 编辑器 sheet — 侧栏 List + 详情表单,提供"+ 模板"菜单 |
| `PromptStore.swift` | `Prompt` model + `PromptStore` (`@Published [Prompt]` 持久化到 UserDefaults) + `PromptTemplates` 预设库 |
| `InputSender.swift` | 把文本发到目标终端的核心 — 剪贴板 + postToPid ⌘V + 回车 |
| `HTTPServer.swift` | 极简纯 Foundation HTTP server,无第三方依赖 |
| `WebUI.swift` | 手机端 HTML/CSS/JS(全在一个 Swift 字符串里) |

## 输入路径(核心,**先读这段再改 InputSender / TerminalTarget**)

`TerminalTarget` 有两种模式,UI 上由 targetBar 的 🔒/🔓 切换:

**跟随模式 (默认)**: 目标 = 当前 frontmost。监听 `NSWorkspace.didActivateApplicationNotification` 持续更新 frontmostPID / frontmostBundleID,只有 bundleID 命中白名单(`terminalBundleIDs`,目前 iTerm2 + Terminal)时才允许发送。

**锁定模式**: 用户在 frontmost 是终端时点 🔒,把那一刻的 pid/name/bundleID 拷到 lockedXxx。之后 sendPID 始终返回 lockedPID,无论 frontmost 在哪。监听 `didTerminateApplicationNotification`,锁定的 app 退出时自动解锁。

发送流程(`PromptButton` + HTTP `/api/send` 共用):
1. `target.isTerminal == false` 或 `sendPID == nil` → 红闪拒绝
2. `target.prepareForSend()`:
   - 跟随模式 → 返回 nil,立即发
   - 锁定模式 + frontmost == 锁定 app → 返回 nil,立即发
   - 锁定模式 + frontmost ≠ 锁定 app → `NSWorkspace.openApplication(at: bundleURL, configuration:)`(activates=true) 把锁定 app 叫到前台,返回 0.2s 让 activate 生效
   - 锁定的 pid 已死 → 返回 -1,自动解锁,本次放弃
3. `InputSender.send(text, autoEnter, toPID:)`:`NSPasteboard` 写文本 → `CGEvent.postToPid` 投递 ⌘V → 可选 postToPid Return → 0.15s 后复原原剪贴板

`FloatingPanel` 是 nonactivating panel,点按钮不抢 key window,所以跟随模式下 frontmost 始终是终端本身。锁定模式下主动把目标拉到前台是为了 ⌘V 能正确粘到该终端的 key window(后台 app 的 ⌘V 行为不保证 — 多数 app 的 Paste 菜单项在窗口非 key 时是 disabled)。**注意**: 这里**不能**用 `NSRunningApplication.activate()` — macOS 14+ 它要 user-provided event,nonactivating panel 给不出,会静默失败;`.activateIgnoringOtherApps` Apple 14+ 明文 "will have no effect"。走 `NSWorkspace.openApplication`(LaunchServices)绕过这个限制,target 已运行时只 activate 不会重启。

锁定状态不持久化 — 关 app 重开回到跟随模式。

**锁定的粒度是 app 实例,不是窗口**: iTerm2 / Apple Terminal 都是单进程多窗口架构,N 个窗口/tab 共用一个 pid。锁了 iTerm 后用户在 iTerm 内手动切到另一个窗口,⌘V 会粘到 iTerm 当前的 key window(也就是用户切到的那个),不是按🔒那一刻的窗口。要锁到具体窗口必须改成 AX `AXWindow` ID + 发送前 raise 指定窗口,复杂度上一个量级,目前不做。

**绝对不要**回到这些"看似优雅但被踩死的"思路(历史踩坑,留作警示):

- ❌ 加回"标定位置 + 真实 click"流程 — 终端不需要,只会让用户多一步操作
- ❌ 用 `cghidEventTap` 投递 ⌘V — 现在 frontmost 就是终端,`postToPid` 已经够,`cghidEventTap` 还会被前台其他可能弹出的 app 截胡
- ❌ AX `kAXFocusedAttribute = true` 自动 focus textarea — 即使对终端也没必要(整个窗口都是输入)
- ❌ `NSScreen.main?.frame.height` 做坐标转换 — 现在压根没有坐标转换了。多屏时 `main` 也可能不是 primary,要用 `CGDisplayBounds(CGMainDisplayID()).height`(已无场景,但同类问题别再犯)
- ❌ `Button + .draggable` 加在同一个 view — SwiftUI hit testing 冲突,点击会跑到左上角。要拖拽就**单独的拖动手柄 view 上挂 .draggable**
- ❌ 用 `NSRunningApplication.activate()` / `.activateIgnoringOtherApps` 把外部 app 拉前台 — macOS 14+ 前者要 user-provided event,nonactivating panel 给不出;后者 Apple 明文 "will have no effect"。要拉前台用 `NSWorkspace.shared.openApplication(at: app.bundleURL!, configuration:)`,LaunchServices 不受限,target 已运行时只 activate 不会重启

## 想加新终端

只要在 `TerminalTarget.terminalBundleIDs` 加一个 bundle ID 就行(Ghostty = `com.mitchellh.ghostty`,WezTerm = `com.github.wez.wezterm`,kitty = `net.kovidgoyal.kitty`,Warp = `dev.warp.Warp-Stable`,Alacritty = `org.alacritty`)。其他逻辑零改动。

## 想扩到非终端 app(慎重)

如果哪天又要发到 Electron / Cursor / Claude Desktop,**不要直接改 InputSender**。先看 git 历史里 `99830ee` 和 `6393b0e` 两个 commit — 当时的"标定位置 + cghidEventTap 真实 click"是被 Electron 逼出来的唯一可行解。要扩范围就把那套作为"非终端模式"重新引入,**保留**当前的"终端模式"快路径。

## UI 注意

- `FloatingPanel` 是 `.nonactivatingPanel` + `canBecomeKey = false` — **千万别打开 `isMovableByWindowBackground`,会抢走卡片的 .draggable 手势**
- 卡片拖动: 左侧 ≡ 手柄 view 单独 `.draggable`,主按钮不受影响;整张卡 `.dropDestination`
- header 右上: `⊞` 打开模板库(从 `PromptTemplates.groups` 追加到主网格), `齿轮` 打开 EditorView sheet
- 卡片右键菜单: 编辑 / 复制 / 上移 / 下移 / 删除
- 末尾的虚线"+" 卡片: 新增并自动弹编辑 popover; 也是拖到末尾的 drop target
- targetBar(顶部状态条): 紫色 `lock.fill` + 锁定名 + 🔓 = 锁定模式;绿色 `terminal.fill` + 终端名 + 🔒 = 跟随且在终端;灰色 `terminal` + "焦点不是终端" = 不可发。锁定按钮在 frontmost 是终端时才能按

## 权限

- **辅助功能**: `CGEvent.postToPid` 注入必需。每次 `./build.sh install` ad-hoc 重签名后,授权会失效 — 用户要在系统设置里**删掉再加回**(旧授权对的是旧签名 hash)。app 路径变了(`/Applications` ↔ 项目目录)同理要重加
- **App 管理 (TCC)**: 装到 `/Applications` 需要 Terminal 有 "App 管理" 权限,否则 `cp -R` 会**静默假成功**(exit 0,目录是空壳)。`build.sh install` 用 `ditto` 而不是 `cp -R` 规避这个 — `ditto` 走 copyfile API 可以过 TCC。事后校验可执行文件存在防止再被骗
- 网络: HTTP server 在 `8765` 端口,纯局域网

## HTTP API(手机遥控)

- `GET /` → Web UI
- `GET /api/prompts` → `{prompts: [{id, title, content, autoEnter}]}`
- `POST /api/send` body `{id}` → 焦点不是终端时返回 `409` + 中文说明

## 用户偏好(从 `~/.claude/CLAUDE.md`)

- 中文交流
- 不主动 commit/push,需要时先问
- 倾向成熟简洁的方案 — 发现思路不对直接说,不要默默打补丁(项目的踩坑历史就是这条原则的反证)
