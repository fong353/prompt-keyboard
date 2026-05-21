# Prompt Keyboard

A floating macOS panel that sends prepared prompts to Claude Code (or any target app) with one click. Also serves a phone-friendly web UI on your LAN — point any phone at your Mac and use it as a remote control.

> Status: works on macOS 14+, tested with Claude Desktop and various terminal hosts.

## Features

- **Non-focus-stealing floating panel** — click buttons while you keep working in another window
- **Target binding** — bind a specific process (e.g. Claude Desktop) as the destination; prompts land there even when it's minimized or hidden, then focus auto-returns to where you were
- **LAN web UI** — built-in HTTP server; scan the in-app QR code or open `http://<your-mac-ip>:8765` from any phone browser
- **~65 curated templates** in 9 groups (quick-reply, explain, test, debug, refactor, git, slash commands, language, English) — import individually or by group
- **In-app editor** for adding/removing/reordering prompts and toggling auto-Enter per-prompt
- **Zero external dependencies** — only macOS system frameworks (no Vapor, no NIO, no third-party packages)

## How it works

1. SwiftUI panel (`NSPanel` with `.nonactivatingPanel`) holds your buttons. It never steals focus, so the keyWindow stays on whatever you were working in.
2. On click: write text to `NSPasteboard` → simulate `⌘V` → simulate `Return` (optional, per-prompt).
3. With a binding: force the target process to the front (AX `kAXMinimizedAttribute = false` + `kAXRaiseAction` + `kAXFrontmostAttribute = true` + `NSRunningApplication.activate()`), send the keys via `CGEvent.postToPid()`, then re-activate the originally-frontmost app so your workflow isn't disrupted.
4. The phone web UI does `POST /api/send {id}` — the Mac side runs the exact same flow.

## Install

Requires Xcode Command Line Tools (Swift 6.0+, macOS 14+).

```bash
git clone https://github.com/fong353/prompt-keyboard.git
cd prompt-keyboard
./build.sh install      # builds release, packages .app, copies to /Applications
open /Applications/PromptKeyboard.app
```

First launch will request **Accessibility** permission — needed for `CGEvent` injection and `AXUIElement` to control other apps.

## Usage

### On Mac

1. Focus your target window (e.g. Claude Desktop input field).
2. Without switching focus, click **绑定 / Bind** in the floating panel — the binding bar shows the target app name + PID.
3. Switch to any other app and click prompt buttons — they go to the bound target. Focus returns automatically.

### From phone (same Wi-Fi)

1. Tap the QR icon in the floating panel and scan with your phone camera, or just type `http://<your-mac-ip>:8765` in any browser.
2. Same buttons appear in a grid. Tap to send.

### Editing prompts

Click the gear icon to open the editor. Add, remove, reorder. The **⊞** menu in the editor toolbar imports curated templates by group — pick one or "全部导入 / Import all".

## Tech stack

- SwiftUI + AppKit (`NSPanel` + `NSHostingView`)
- `Network.framework` — custom ~150-line HTTP/1.1 server (no NIO / Vapor)
- `CGEvent` + `AXUIElement` for keyboard injection and target window control
- `CIQRCodeGenerator` for the QR code
- `UserDefaults` JSON for prompt persistence
- ~900 lines of Swift total, no third-party packages

## File layout

```
Sources/PromptKeyboard/
  PromptKeyboardApp.swift   App entry + AppDelegate + HTTP routing + FloatingPanel
  PromptStore.swift         Prompt model + persistence + template groups
  InputSender.swift         Clipboard + ⌘V + Enter + force-bring-to-front
  HTTPServer.swift          Tiny HTTP/1.1 server (Network framework)
  WebUI.swift               Single-page HTML embedded as Swift string
  ContentView.swift         Main floating panel UI
  EditorView.swift          In-app prompt editor
build.sh                    SwiftPM build → .app packaging → ad-hoc sign → install
make_icon.swift             Renders the app icon (.icns) from SF Symbols
```

## Permissions

- **Accessibility** (required): allows `CGEvent.postToPid()` and `AXUIElement` calls to control other apps. Grant once in System Settings → Privacy & Security → Accessibility.
- **Network** (LAN only): the HTTP server binds to `0.0.0.0:8765` on your local interface. Nothing leaves your LAN.

No outbound network calls. No telemetry. No login. No cloud.

## License

MIT
