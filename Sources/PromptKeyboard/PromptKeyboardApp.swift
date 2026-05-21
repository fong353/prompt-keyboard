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

/// 持有"按按钮要把按键打到哪个进程"的目标 PID + 用户自己标定的输入框位置
/// 不绑定时按按钮会发给当前 keyWindow(回到默认行为)
final class BindingState: ObservableObject {
    @Published var pid: pid_t?
    @Published var appName: String?
    @Published var bundleID: String?

    /// 用户标定时点击的位置,相对目标 app 主窗口左上角的 offset
    @Published var clickOffset: CGPoint?

    /// 是否处于"等待用户在目标输入框点击"的标定模式
    @Published var isCalibrating: Bool = false

    private var calibrationMonitor: Any?

    var isBound: Bool { pid != nil && clickOffset != nil }

    func unbind() {
        pid = nil
        appName = nil
        bundleID = nil
        clickOffset = nil
        cancelCalibration()
    }

    /// 启动"标定位置"流程:监听下一次全局 left mouse down,
    /// 把那一刻的 frontmost app + click 位置存为绑定
    func startCalibration() {
        guard !isCalibrating else { return }
        isCalibrating = true
        calibrationMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            self?.captureClick()
        }
    }

    func cancelCalibration() {
        if let m = calibrationMonitor {
            NSEvent.removeMonitor(m)
            calibrationMonitor = nil
        }
        isCalibrating = false
    }

    /// 把 click 当时的 frontmost app + 屏幕位置 转成 (pid, name, bundleID, clickOffset) 存起来
    private func captureClick() {
        // 这一刻先抓鼠标位置 — NSEvent 坐标系是 bottom-left origin
        let mouseLocBL = NSEvent.mouseLocation
        cancelCalibration()

        // 等 100ms 让 click 真的把 target app 切前台,再读 frontmost
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self,
                  let app = NSWorkspace.shared.frontmostApplication,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier
            else { return }

            // NSEvent BL → AX/CG TL: y 翻转,以主屏高度为参照
            let mainScreenHeight = NSScreen.main?.frame.height ?? 0
            let mouseLocTL = CGPoint(x: mouseLocBL.x, y: mainScreenHeight - mouseLocBL.y)

            // 读 target app 主窗口左上角
            var windowPos = CGPoint.zero
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var mwRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &mwRef) == .success,
               let mw = mwRef {
                var posRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(mw as! AXUIElement, kAXPositionAttribute as CFString, &posRef) == .success,
                   let pRef = posRef {
                    AXValueGetValue(pRef as! AXValue, .cgPoint, &windowPos)
                }
            }

            self.pid = app.processIdentifier
            self.appName = app.localizedName
            self.bundleID = app.bundleIdentifier
            self.clickOffset = CGPoint(x: mouseLocTL.x - windowPos.x, y: mouseLocTL.y - windowPos.y)
        }
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
