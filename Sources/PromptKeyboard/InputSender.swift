import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum InputSender {
    /// 纯前台方案:假设目标 App 已经在前台。
    /// 1. 在标定的绝对屏幕坐标上 postToPid 模拟 click(鼠标光标不动,事件只投递给目标进程)
    /// 2. postToPid 投递 ⌘V 把剪贴板内容粘进去
    /// 3. autoEnter 再投递回车
    /// - Parameters:
    ///   - autoEnter: 粘贴完是否再敲一次回车
    ///   - toPID: 给了 PID 就用 postToPid 投递到该进程;为 nil 时走 cghidEventTap 打到当前 keyWindow
    ///   - clickPosition: 标定时记下的输入框绝对屏幕坐标 (CG/AX,top-left of primary)
    static func send(_ text: String, autoEnter: Bool, toPID: pid_t? = nil, clickPosition: CGPoint? = nil) {
        ensureAccessibilityPermission()

        // 记下原鼠标位置 — 发送完恢复回去,用户不会丢光标
        let originalCursor = CGEvent(source: nil)?.location

        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        // 第 1 步:在标定位置真实 click — 鼠标会跳过去,你能看到 click 实际落点
        if let _ = toPID, let point = clickPosition {
            clickAt(point: point)
        }

        // 第 2 步:短延迟后发 ⌘V
        let pasteDelay = (toPID != nil && clickPosition != nil) ? 0.10 : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + pasteDelay) {
            postCmdV(toPID: toPID)
            let restore = {
                // 把鼠标移回原位置
                if let orig = originalCursor {
                    let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                       mouseCursorPosition: orig, mouseButton: .left)
                    move?.post(tap: .cghidEventTap)
                }
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

    /// 在绝对屏幕坐标上模拟真实左键单击 — 走 cghidEventTap,鼠标会真跳过去,
    /// 这样命中是真实命中,所有 app 都会按 hit testing 处理。send() 末尾会把鼠标移回原位置。
    private static func clickAt(point: CGPoint) {
        // privateState 不继承硬件修饰键,避免 Ctrl+click 被误判为右键
        let src = CGEventSource(stateID: .privateState)
        let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                           mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                         mouseCursorPosition: point, mouseButton: .left)
        down?.flags = []
        up?.flags = []
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// 第一次调用时会触发系统弹窗:申请"辅助功能"权限
    @discardableResult
    static func ensureAccessibilityPermission() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
}
