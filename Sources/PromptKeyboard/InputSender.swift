import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum InputSender {
    /// 纯前台方案:假设目标 App 已经在前台。
    /// 1. 在绑定时记下的输入框位置上 postToPid 模拟 click(鼠标光标不动,只投递事件给目标进程)
    /// 2. postToPid 投递 ⌘V 把剪贴板内容粘进去
    /// 3. autoEnter 再投递回车
    /// - Parameters:
    ///   - autoEnter: 粘贴完是否再敲一次回车
    ///   - toPID: 给了 PID 就用 postToPid 投递到该进程;为 nil 时走 cghidEventTap 打到当前 keyWindow
    ///   - clickOffset: 绑定时记下的输入框相对主窗口左上角的 offset
    static func send(_ text: String, autoEnter: Bool, toPID: pid_t? = nil, clickOffset: CGPoint? = nil) {
        ensureAccessibilityPermission()

        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        // 第 1 步:在输入框位置 click 让它获得 first responder
        if let pid = toPID, let offset = clickOffset {
            clickWindowOffset(pid: pid, offset: offset)
        }

        // 第 2 步:短延迟后发 ⌘V
        let pasteDelay = (toPID != nil && clickOffset != nil) ? 0.06 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + pasteDelay) {
            postCmdV(toPID: toPID)
            let restore = {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    restorePasteboard(previous)
                }
            }
            if autoEnter {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                    postReturn(toPID: toPID)
                    restore()
                }
            } else {
                restore()
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

    /// 读目标 App 当前主窗口位置 + offset 得到 click 点,postToPid 模拟左键单击
    /// 因为是 postToPid 而不是 cghidEventTap,用户的硬件鼠标光标不会移动
    private static func clickWindowOffset(pid: pid_t, offset: CGPoint) {
        let axApp = AXUIElementCreateApplication(pid)
        var mainWindowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMainWindowAttribute as CFString, &mainWindowRef) == .success,
              let mainWindow = mainWindowRef else { return }
        var posRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(mainWindow as! AXUIElement, kAXPositionAttribute as CFString, &posRef) == .success,
              let pRef = posRef else { return }
        var windowPos = CGPoint.zero
        AXValueGetValue(pRef as! AXValue, .cgPoint, &windowPos)

        let clickPoint = CGPoint(x: windowPos.x + offset.x, y: windowPos.y + offset.y)

        // privateState 不继承硬件修饰键,避免 Ctrl+click 被误判为右键
        let src = CGEventSource(stateID: .privateState)
        let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                           mouseCursorPosition: clickPoint, mouseButton: .left)
        let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                         mouseCursorPosition: clickPoint, mouseButton: .left)
        down?.flags = []
        up?.flags = []
        down?.postToPid(pid)
        up?.postToPid(pid)
    }

    /// 第一次调用时会触发系统弹窗:申请"辅助功能"权限
    @discardableResult
    static func ensureAccessibilityPermission() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
}
