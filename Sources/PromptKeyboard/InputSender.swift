import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum InputSender {
    /// 把 text 写入剪贴板,然后模拟 ⌘V 粘贴
    /// - Parameters:
    ///   - autoEnter: 粘贴完是否再敲一次回车
    ///   - toPID: 如果给了 PID,事件直接投递到该进程(不依赖前台焦点);
    ///            为 nil 时走 cghidEventTap,等同于打到当前 keyWindow
    static func send(_ text: String, autoEnter: Bool, toPID: pid_t? = nil) {
        ensureAccessibilityPermission()

        // 抓住按下按钮瞬间的前台 App + 该目标窗口原始是否最小化,
        // 发送完成后好恢复回去 — 这样用户体感是"闪一下", 而不是 Claude Desktop 留在前面
        var originalFrontApp: NSRunningApplication?
        var wasMinimized = false
        let myBID = Bundle.main.bundleIdentifier
        if let pid = toPID {
            let front = NSWorkspace.shared.frontmostApplication
            if let f = front,
               f.processIdentifier != pid,
               f.bundleIdentifier != myBID {
                originalFrontApp = f
            }
            wasMinimized = isMinimized(pid: pid)
            forceBringToFront(pid: pid)
        }

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 给 activate/unminimize/raise 一点时间生效,再发按键
        let delay = (toPID != nil) ? 0.30 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            postCmdV(toPID: toPID)
            let afterSend = { (extra: TimeInterval) in
                DispatchQueue.main.asyncAfter(deadline: .now() + extra) {
                    restorePasteboard(previous)
                    // 恢复原始焦点 — 用户在干别的活时不希望被打断
                    if let pid = toPID, wasMinimized {
                        // 原本就是最小化的,发完再最小化回去
                        minimizeAllWindows(pid: pid)
                    }
                    if let app = originalFrontApp {
                        app.activate()
                    }
                }
            }
            if autoEnter {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    postReturn(toPID: toPID)
                    afterSend(0.18)
                }
            } else {
                afterSend(0.25)
            }
        }
    }

    private static func restorePasteboard(_ previous: String?) {
        guard let previous else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(previous, forType: .string)
    }

    private static func postCmdV(toPID: pid_t?) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)

        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand

        if let pid = toPID {
            down?.postToPid(pid)
            up?.postToPid(pid)
        } else {
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    private static func postReturn(toPID: pid_t?) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_Return)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        if let pid = toPID {
            down?.postToPid(pid)
            up?.postToPid(pid)
        } else {
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    /// 第一次调用时会触发系统弹窗:申请"辅助功能"权限
    @discardableResult
    static func ensureAccessibilityPermission() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// 检查目标 App 是否有任何窗口处于最小化状态
    private static func isMinimized(pid: pid_t) -> Bool {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return false }
        for window in windows {
            var m: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &m) == .success,
               (m as? Bool) == true {
                return true
            }
        }
        return false
    }

    /// 把目标 App 所有窗口最小化
    private static func minimizeAllWindows(pid: pid_t) {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return }
        for window in windows {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        }
    }

    /// 把指定 PID 的应用强行带到最前(取消最小化 + raise + frontmost + activate)
    private static func forceBringToFront(pid: pid_t) {
        let axApp = AXUIElementCreateApplication(pid)

        // 1. 遍历所有窗口,取消最小化并 raise
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement] {
            for window in windows {
                // 取消最小化
                var minimized: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
                   (minimized as? Bool) == true {
                    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                }
                // 把窗口浮到最前
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            }
        }

        // 2. 让 App 进程层面成为 frontmost(对 Electron 等也有效)
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)

        // 3. NSRunningApplication 走 macOS 标准激活路径,把焦点切过去
        NSRunningApplication(processIdentifier: pid)?.activate()
    }
}
