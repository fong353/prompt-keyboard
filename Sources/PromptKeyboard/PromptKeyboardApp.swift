import SwiftUI
import AppKit

@main
struct PromptKeyboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 用 Settings 占位,避免 SwiftUI 自动创建 main window
        // 真正的悬浮窗由 AppDelegate 手动创建为 NSPanel
        Settings { EmptyView() }
    }
}

final class NetworkInfo: ObservableObject {
    @Published var ip: String?
    @Published var port: UInt16 = 0

    var url: String? {
        guard let ip else { return nil }
        return "http://\(ip):\(port)"
    }
}

/// 跟踪发送目标。两种模式:
/// - **跟随**(默认): 目标 = 当前 frontmost,只有 frontmost 是已识别终端时才允许发送
/// - **锁定**: 用户手动锁了一个终端 pid,之后无论 frontmost 是什么都发到它。发送前如果 frontmost ≠ 锁定 pid,会先 activate() 把它叫到前台,再 postToPid 投递
///
/// 锁定的 app 退出时自动解锁。锁定状态不持久化(关 app 重开回到跟随模式)。
final class TerminalTarget: ObservableObject {
    // frontmost 持续更新,作为"跟随"模式的来源,也是"是否需要 activate"的判断依据
    @Published private(set) var frontmostPID: pid_t?
    @Published private(set) var frontmostName: String?
    @Published private(set) var frontmostBundleID: String?

    // 锁定状态;nil = 跟随模式
    @Published private(set) var lockedPID: pid_t?
    @Published private(set) var lockedName: String?
    @Published private(set) var lockedBundleID: String?

    /// 已识别的终端 app 白名单。后续要加 Ghostty / WezTerm 等就在这里加 bundle ID。
    static let terminalBundleIDs: Set<String> = [
        "com.googlecode.iterm2",   // iTerm2
        "com.apple.Terminal"       // Apple Terminal
    ]

    var isLocked: Bool { lockedPID != nil }

    /// 实际要 postToPid 投递的 pid
    var sendPID: pid_t? { lockedPID ?? frontmostPID }

    /// 给 UI 显示的目标名(锁定时是锁定的 app,否则是 frontmost)
    var displayName: String? { isLocked ? lockedName : frontmostName }

    var displayBundleID: String? { isLocked ? lockedBundleID : frontmostBundleID }

    /// 当前发送目标是不是终端
    var isTerminal: Bool {
        guard let bid = displayBundleID else { return false }
        return Self.terminalBundleIDs.contains(bid)
    }

    /// 当前 frontmost 是终端 → 可以"按它锁定"
    var canLockCurrent: Bool {
        guard !isLocked, let bid = frontmostBundleID else { return false }
        return Self.terminalBundleIDs.contains(bid)
    }

    init() {
        refresh()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(activated(_:)),
                       name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(deactivated(_:)),
                       name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(appTerminated(_:)),
                       name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    func lockCurrent() {
        guard canLockCurrent else { return }
        lockedPID = frontmostPID
        lockedName = frontmostName
        lockedBundleID = frontmostBundleID
    }

    func unlock() {
        lockedPID = nil
        lockedName = nil
        lockedBundleID = nil
    }

    /// 发送前调用。锁定模式 + frontmost ≠ 锁定 app 时,把锁定 app 叫到前台。
    /// 返回 nil = 可以立即发送;> 0 = 需要等这么久再发(让 activate 生效);返回特殊值 -1 = 锁定 app 已退出,调用方应拒绝发送
    func prepareForSend() -> TimeInterval? {
        guard let lpid = lockedPID else { return nil } // 跟随模式直接发
        guard let app = NSRunningApplication(processIdentifier: lpid) else {
            unlock()
            return -1
        }
        if frontmostPID != lpid {
            app.activate()
            return 0.15
        }
        return nil
    }

    @objc private func activated(_ note: Notification) {
        DispatchQueue.main.async { self.refresh() }
    }

    @objc private func deactivated(_ note: Notification) {
        DispatchQueue.main.async { self.refresh() }
    }

    @objc private func appTerminated(_ note: Notification) {
        DispatchQueue.main.async {
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier == self.lockedPID
            else { return }
            self.unlock()
        }
    }

    private func refresh() {
        // 自己不算 frontmost — 自己被激活时保留之前的记录
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier
        else { return }
        self.frontmostPID = app.processIdentifier
        self.frontmostName = app.localizedName
        self.frontmostBundleID = app.bundleIdentifier
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel?
    let store = PromptStore()
    let network = NetworkInfo()
    let target = TerminalTarget()
    var server: HTTPServer?
    let httpPort: UInt16 = 8765

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        startHTTPServer()

        let content = ContentView()
            .environmentObject(store)
            .environmentObject(network)
            .environmentObject(target)

        let hosting = NSHostingView(rootView: content)
        let panel = FloatingPanel(
            contentRect: NSRect(x: 100, y: 100, width: 300, height: 420),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "提示词键盘"
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        // 不让"窗口背景"参与拖窗口 — 否则会抢走卡片手柄的 draggable 手势。
        // 用户从顶部标题栏区域(透明那一条)依然能拖动整个 panel。
        panel.isMovableByWindowBackground = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.contentView = hosting
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.orderFrontRegardless()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    private func startHTTPServer() {
        let server = HTTPServer(port: httpPort)
        server.router = { [weak self] req in
            self?.route(req) ?? .notFound()
        }
        do {
            try server.start()
            self.server = server
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.network.ip = LocalIP.primary()
                self.network.port = self.httpPort
            }
        } catch {
            NSLog("HTTP server start failed: %@", "\(error)")
        }
    }

    private func route(_ req: HTTPRequest) -> HTTPResponse {
        switch (req.method, req.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return .html(WebUI.html)

        case ("GET", "/api/prompts"):
            var prompts: [[String: Any]] = []
            DispatchQueue.main.sync {
                prompts = self.store.prompts.map { p in
                    [
                        "id": p.id.uuidString,
                        "title": p.title,
                        "content": p.content,
                        "autoEnter": p.autoEnter
                    ]
                }
            }
            return .json(["prompts": prompts])

        case ("POST", "/api/send"):
            guard let json = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let idStr = json["id"] as? String,
                  let id = UUID(uuidString: idStr)
            else { return .badRequest() }

            var found: Prompt?
            var pid: pid_t?
            var isTerm = false
            var displayName: String?
            DispatchQueue.main.sync {
                found = self.store.prompts.first { $0.id == id }
                pid = self.target.sendPID
                isTerm = self.target.isTerminal
                displayName = self.target.displayName
            }
            guard let prompt = found else { return .notFound() }
            guard isTerm, let targetPID = pid else {
                let msg = "当前焦点不是终端 (\(displayName ?? "无"))。请先锁定一个终端,或切到 iTerm2 / Terminal"
                return HTTPResponse(
                    status: 409, statusText: "Conflict",
                    headers: ["Content-Type": "text/plain; charset=utf-8"],
                    body: Data(msg.utf8)
                )
            }

            DispatchQueue.main.async {
                let delay = self.target.prepareForSend()
                if delay == -1 {
                    // 锁定 app 已退出,prepareForSend 已自动解锁;本次直接放弃
                    return
                }
                let after = delay ?? 0
                DispatchQueue.main.asyncAfter(deadline: .now() + after) {
                    InputSender.send(prompt.content, autoEnter: prompt.autoEnter, toPID: targetPID)
                }
            }
            return .json(["ok": true])

        default:
            return .notFound()
        }
    }
}

/// 不抢焦点的悬浮 Panel:这样点击我们窗口的按钮时,
/// 系统的 frontmost 仍然是用户之前的终端窗口,⌘V 才能粘到目标里
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
