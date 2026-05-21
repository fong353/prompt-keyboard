# CLAUDE.md

给后续 Claude Code 编辑这个项目的快速上手 + 踩坑总结。

## 是什么

macOS 悬浮窗,把预设 prompts 一键发到 Claude Code / 终端 / 任何 app。同时起一个 LAN HTTP server 让手机当遥控器。

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
| `PromptKeyboardApp.swift` | App entry / `AppDelegate` / `BindingState` / `FloatingPanel` / HTTP route |
| `ContentView.swift` | SwiftUI 主面板 — header / bindingBar / 卡片网格 / footer / 编辑 popover / 模板菜单 |
| `EditorView.swift` | 编辑器 sheet — 侧栏 List + 详情表单,提供"+ 模板"菜单 |
| `PromptStore.swift` | `Prompt` model + `PromptStore` (`@Published [Prompt]` 持久化到 UserDefaults) + `PromptTemplates` 预设库 |
| `InputSender.swift` | 把文本发到目标 app 的核心 — 剪贴板 + click + ⌘V + 回车 |
| `HTTPServer.swift` | 极简纯 Foundation HTTP server,无第三方依赖 |
| `WebUI.swift` | 手机端 HTML/CSS/JS(全在一个 Swift 字符串里) |

## 输入路径(核心,**先读这段再改 InputSender**)

最终方案是**纯前台 + 真实 click**:

1. 标定流程: 用户点"标定位置"→ `NSEvent.addGlobalMonitorForEvents` 捕获下一次 left mouse down → 记当时 frontmost app 的 pid/name/bundleID + 屏幕坐标(NSEvent BL → CG TL 用 `CGMainDisplayID()` 拿 primary 高度做 y 翻转)
2. 发送: `CGEvent` via `cghidEventTap` 模拟真实左键单击标定位置 → `⌘V` → `Return` → 把鼠标光标移回原位置(用户感觉是光标飞一下又回来)
3. 不切前台、不还原原前台 app、不持久化 binding — 用户保证目标 app 在前台

**绝对不要**回到这些"看似优雅但被踩死的"思路:

- ❌ `CGEvent.postToPid()` 投递 mouse event — Electron / Chromium app **静默忽略**,click 像没发生,⌘V 跑到菜单栏 Edit。`postToPid` 投递 key event 反而 OK,但用 `cghidEventTap` 已经够了不需要混
- ❌ AX `kAXFocusedAttribute = true` 设到 textarea — Electron 的 Web 元素不响应
- ❌ "用 AX 找 focused element 位置" 自动标定 — Electron 报的 position 经常对不上视觉位置(可能跟 `fullSizeContentView` 有关)。**让用户自己点**
- ❌ `NSScreen.main?.frame.height` 做坐标转换 — 多屏时 `main` 可能不是 primary。**用 `CGDisplayBounds(CGMainDisplayID()).height`**
- ❌ `Button + .draggable` 加在同一个 view — SwiftUI hit testing 冲突,点击会跑到左上角。要拖拽就**单独的拖动手柄 view 上挂 .draggable**

## 后台输入(目前未实现)

macOS 在 app 处于后台时基本不让它处理键盘事件,所以"完全后台"做不到。如果要做"目标在后台也能用",方案:
- `send()` 入口判断 frontmost ≠ 目标 → 记原前台 → `forceBringToFront(target pid)` (AX raise + frontmost + activate) → 等 0.25s → 走当前流程 → 收尾 `originalFrontApp.activate()`
- 体感: 目标 app "闪一下"
- 加 ~25 行,**InputSender 不会回到打补丁的复杂度**,因为 click 仍然是 cghidEventTap 真实命中

## UI 注意

- `FloatingPanel` 是 `.nonactivatingPanel` + `canBecomeKey = false` — **千万别打开 `isMovableByWindowBackground`,会抢走卡片的 .draggable 手势**
- 卡片拖动: 左侧 ≡ 手柄 view 单独 `.draggable`,主按钮不受影响;整张卡 `.dropDestination`
- header 右上: `⊞` 打开模板库(从 `PromptTemplates.groups` 追加到主网格), `齿轮` 打开 EditorView sheet
- 卡片右键菜单: 编辑 / 复制 / 上移 / 下移 / 删除
- 末尾的虚线"+" 卡片: 新增并自动弹编辑 popover; 也是拖到末尾的 drop target

## 权限

- **辅助功能**: `CGEvent` 注入 + `AXUIElement` 控制其他 app 必需。每次 `./build.sh install` ad-hoc 重签名后,授权会失效 — 用户要在系统设置里**删掉再加回**(旧授权对的是旧签名 hash)
- 网络: HTTP server 在 `8765` 端口,纯局域网

## 用户偏好(从 `~/.claude/CLAUDE.md`)

- 中文交流
- 不主动 commit/push,需要时先问
- 倾向成熟简洁的方案 — 发现思路不对直接说,不要默默打补丁(项目的踩坑历史就是这条原则的反证)
