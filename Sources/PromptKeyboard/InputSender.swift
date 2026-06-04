import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum InputSender {
    /// 把 text 投递到 toPID 进程并(可选)按回车。
    /// 假设 toPID 是已经在前台的终端 — caller (TerminalTarget) 负责保证这一点。
    /// 流程: 写剪贴板 → postToPid ⌘V → autoEnter 时再 postToPid Return → 复原剪贴板。
    static func send(_ text: String, autoEnter: Bool, toPID: pid_t) {
        ensureAccessibilityPermission()

        let pb = NSPasteboard.general
        let previous = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

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

    private static func restorePasteboard(_ previous: String?) {
        guard let previous else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(previous, forType: .string)
    }

    private static func postCmdV(toPID: pid_t) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        down?.postToPid(toPID)
        up?.postToPid(toPID)
    }

    private static func postReturn(toPID: pid_t) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_Return)
        let down = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)
        down?.postToPid(toPID)
        up?.postToPid(toPID)
    }

    /// 第一次调用时会触发系统弹窗:申请"辅助功能"权限
    @discardableResult
    static func ensureAccessibilityPermission() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }
}
