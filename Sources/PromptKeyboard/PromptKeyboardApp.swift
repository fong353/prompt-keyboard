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

/// 持有"按按钮要把按键打到哪个进程"的目标 PID
/// 不绑定时为 nil,按按钮会发给当前 keyWindow(回到默认行为)
final class BindingState: ObservableObject {
    @Published var pid: pid_t?
    @Published var appName: String?
    @Published var bundleID: String?

    /// 绑定那一刻 Claude focused element(输入框)相对主窗口左上角的偏移。
    /// 发送时 click 这个 offset + 当前主窗口位置,让输入框拿到 first responder。
    /// 用 offset 而不是绝对坐标 — 这样 Claude 窗口移动也能跟上。
    @Published var clickOffset: CGPoint?

    var isBound: Bool { pid != nil }

    /// 用当前 frontmost app 作为绑定目标(排除自己),并记下它当前 focused 元素位置
    func bindToFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let myBID = Bundle.main.bundleIdentifier
        if let bid = app.bundleIdentifier, bid == myBID { return }
        let p = app.processIdentifier
        pid = p
        appName = app.localizedName
        bundleID = app.bundleIdentifier
        clickOffset = computeFocusedElementOffset(pid: p)
    }

    func unbind() {
        pid = nil
        appName = nil
        bundleID = nil
        clickOffset = nil
    }

    /// 绑定的进程是否还活着,死了清掉绑定并返回 false
    @discardableResult
    func validate() -> Bool {
        guard let p = pid else { return false }
        if NSRunningApplication(processIdentifier: p) == nil {
            unbind()
            return false
        }
        return true
    }

    /// 读 frontmost focused element 的中心位置,以及 main window 左上角,返回 offset
    private func computeFocusedElementOffset(pid: pid_t) -> CGPoint? {
        let axApp = AXUIElementCreateApplication(pid)

        // 1. main window 左上角
        var mainWindowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &mainWindowRef) == .success,
              let mainWindow = mainWindowRef else { return nil }
        var windowPosRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(mainWindow as! AXUIElement, kAXPositionAttribute as CFString, &windowPosRef) == .success,
              let wpRef = windowPosRef else { return nil }
        var windowPos = CGPoint.zero
        AXValueGetValue(wpRef as! AXValue, .cgPoint, &windowPos)

        // 2. focused element 的中心 (global screen)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return nil }
        var elPosRef: CFTypeRef?
        var elSizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXPositionAttribute as CFString, &elPosRef) == .success,
              AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSizeAttribute as CFString, &elSizeRef) == .success,
              let epRef = elPosRef, let esRef = elSizeRef else { return nil }
        var elPos = CGPoint.zero
        var elSize = CGSize.zero
        AXValueGetValue(epRef as! AXValue, .cgPoint, &elPos)
        AXValueGetValue(esRef as! AXValue, .cgSize, &elSize)
        let elCenter = CGPoint(x: elPos.x + elSize.width / 2, y: elPos.y + elSize.height / 2)

        return CGPoint(x: elCenter.x - windowPos.x, y: elCenter.y - windowPos.y)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanel?
    let store = PromptStore()
    let network = NetworkInfo()
    let binding = BindingState()
    var server: HTTPServer?
    let httpPort: UInt16 = 8765

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        startHTTPServer()

        let content = ContentView()
            .environmentObject(store)
            .environmentObject(network)
            .environmentObject(binding)

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
            var targetPID: pid_t?
            var targetOffset: CGPoint?
            var bindAlive = true
            DispatchQueue.main.sync {
                found = self.store.prompts.first { $0.id == id }
                if self.binding.isBound {
                    bindAlive = self.binding.validate()
                    targetPID = self.binding.pid
                    targetOffset = self.binding.clickOffset
                }
            }
            guard let prompt = found else { return .notFound() }
            if !bindAlive {
                return HTTPResponse(
                    status: 409, statusText: "Conflict",
                    headers: ["Content-Type": "text/plain; charset=utf-8"],
                    body: Data("绑定的进程已退出,请在 Mac 端重新绑定".utf8)
                )
            }

            DispatchQueue.main.async {
                InputSender.send(prompt.content, autoEnter: prompt.autoEnter, toPID: targetPID, clickOffset: targetOffset)
            }
            return .json(["ok": true])

        default:
            return .notFound()
        }
    }
}

/// 不抢焦点的悬浮 Panel:这样点击我们窗口的按钮时,
/// 系统的 keyWindow 仍然是用户之前的终端窗口,⌘V 才能粘到目标里
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
