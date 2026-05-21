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

    var isBound: Bool { pid != nil }

    /// 用当前 frontmost app 作为绑定目标(排除自己)
    func bindToFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let myBID = Bundle.main.bundleIdentifier
        if let bid = app.bundleIdentifier, bid == myBID { return }
        pid = app.processIdentifier
        appName = app.localizedName
        bundleID = app.bundleIdentifier
    }

    func unbind() {
        pid = nil
        appName = nil
        bundleID = nil
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
        panel.isMovableByWindowBackground = true
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
            var bindAlive = true
            DispatchQueue.main.sync {
                found = self.store.prompts.first { $0.id == id }
                if self.binding.isBound {
                    bindAlive = self.binding.validate()
                    targetPID = self.binding.pid
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
                InputSender.send(prompt.content, autoEnter: prompt.autoEnter, toPID: targetPID)
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
