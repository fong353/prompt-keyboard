import Foundation
import SwiftUI

struct Prompt: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var content: String
    var autoEnter: Bool = true
}

final class PromptStore: ObservableObject {
    @Published var prompts: [Prompt] = [] {
        didSet { save() }
    }

    private let storageKey = "PromptKeyboard.prompts.v1"

    init() {
        load()
        if prompts.isEmpty {
            prompts = Self.defaults
        }
    }

    func add(_ prompt: Prompt) {
        prompts.append(prompt)
    }

    func update(_ prompt: Prompt) {
        if let idx = prompts.firstIndex(where: { $0.id == prompt.id }) {
            prompts[idx] = prompt
        }
    }

    func remove(at offsets: IndexSet) {
        prompts.remove(atOffsets: offsets)
    }

    func move(from src: IndexSet, to dst: Int) {
        prompts.move(fromOffsets: src, toOffset: dst)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(prompts) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([Prompt].self, from: data)
        else { return }
        prompts = decoded
    }

    static let defaults: [Prompt] = [
        // 出厂默认:挑最常按的 9 个,涵盖反馈/解释/测试/Git/语言
        Prompt(title: "继续", content: "继续", autoEnter: true),
        Prompt(title: "可以", content: "可以", autoEnter: true),
        Prompt(title: "不行", content: "不行,重做", autoEnter: true),
        Prompt(title: "解释", content: "解释一下你刚才的改动思路", autoEnter: true),
        Prompt(title: "测试", content: "为刚才的改动写测试验证一下", autoEnter: true),
        Prompt(title: "精简", content: "再精简一下,去掉不必要的内容", autoEnter: true),
        Prompt(title: "撤销", content: "撤销刚才的改动", autoEnter: true),
        Prompt(title: "提交", content: "把当前改动 commit,信息你来写", autoEnter: true),
        Prompt(title: "中文", content: "请用中文回复", autoEnter: true)
    ]
}

/// 编辑面板里"+ 模板"菜单用的预设清单,分类组织
struct PromptTemplateGroup: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let items: [Prompt]
}

enum PromptTemplates {
    // 按用户工作流分组,每组按使用频率由高到低排
    // 参考: Claude Code cheatsheet / AI 编程助手高频提示词总结
    static let groups: [PromptTemplateGroup] = [
        // 一字符 / 两字符的高频反馈 — 这类按下次数最多
        PromptTemplateGroup(name: "快速反馈", icon: "bolt.fill", items: [
            Prompt(title: "继续", content: "继续", autoEnter: true),
            Prompt(title: "可以", content: "可以", autoEnter: true),
            Prompt(title: "好的", content: "好", autoEnter: true),
            Prompt(title: "不行", content: "不行,重做", autoEnter: true),
            Prompt(title: "撤销", content: "撤销刚才的改动", autoEnter: true),
            Prompt(title: "等等", content: "等一下,先别动", autoEnter: true),
            Prompt(title: "跳过", content: "跳过这个,继续下一项", autoEnter: true),
            Prompt(title: "停", content: "停,先讨论", autoEnter: true)
        ]),

        // 让 Claude 复盘 / 解释 / 总结
        PromptTemplateGroup(name: "解释复述", icon: "bubble.left.and.text.bubble.right", items: [
            Prompt(title: "解释思路", content: "解释一下你刚才的改动思路", autoEnter: true),
            Prompt(title: "为什么", content: "为什么要这么做?有什么替代方案?", autoEnter: true),
            Prompt(title: "总结进度", content: "总结一下到目前为止做了什么、还剩什么", autoEnter: true),
            Prompt(title: "复述需求", content: "请用你自己的话复述一下我的需求,确认你理解对了", autoEnter: true),
            Prompt(title: "更详细", content: "再展开讲一下,要细节", autoEnter: true),
            Prompt(title: "更简短", content: "再精简一下,去掉不必要的内容", autoEnter: true),
            Prompt(title: "结论先行", content: "直接给结论,不要铺垫", autoEnter: true)
        ]),

        // 测试相关 — 高频写测试场景
        PromptTemplateGroup(name: "测试验证", icon: "checkmark.seal", items: [
            Prompt(title: "写测试", content: "为刚才的改动写测试验证一下", autoEnter: true),
            Prompt(title: "跑测试", content: "把测试跑一下看是否通过", autoEnter: true),
            Prompt(title: "最小复现", content: "写一个最小可复现的例子", autoEnter: true),
            Prompt(title: "边界场景", content: "再补几个边界场景的测试", autoEnter: true),
            Prompt(title: "覆盖率", content: "看看测试覆盖率,缺什么补什么", autoEnter: true),
            Prompt(title: "回归", content: "运行所有相关测试,确保没有回归", autoEnter: true)
        ]),

        // 调试 / 找 bug / 加日志
        PromptTemplateGroup(name: "调试修复", icon: "ant", items: [
            Prompt(title: "报错了", content: "刚才的命令报错了,看下输出修一下", autoEnter: true),
            Prompt(title: "为什么不工作", content: "这段代码为什么不工作?", autoEnter: true),
            Prompt(title: "找 bug", content: "在这段代码里找 bug 并修复", autoEnter: true),
            Prompt(title: "加日志", content: "加一些日志方便定位问题", autoEnter: true),
            Prompt(title: "错误处理", content: "补一下错误处理,别让异常裸奔", autoEnter: true),
            Prompt(title: "兜底", content: "加个兜底,失败时优雅降级", autoEnter: true),
            Prompt(title: "复现", content: "先复现这个问题再说", autoEnter: true)
        ]),

        // 重构 / 优化
        PromptTemplateGroup(name: "重构优化", icon: "wrench.and.screwdriver", items: [
            Prompt(title: "精简", content: "在不改变功能的前提下,精简这段代码", autoEnter: true),
            Prompt(title: "抽函数", content: "把重复逻辑抽成函数", autoEnter: true),
            Prompt(title: "改异步", content: "改成异步实现,不要阻塞主线程", autoEnter: true),
            Prompt(title: "性能", content: "分析性能瓶颈并优化", autoEnter: true),
            Prompt(title: "可读性", content: "提高可读性,变量命名再清晰一点", autoEnter: true),
            Prompt(title: "删冗余", content: "去掉无用代码和注释", autoEnter: true),
            Prompt(title: "别过设计", content: "别过度设计,保持简单可靠", autoEnter: true)
        ]),

        // Git / 提交 / PR
        PromptTemplateGroup(name: "Git 提交", icon: "arrow.triangle.branch", items: [
            Prompt(title: "提交", content: "把当前改动 commit,信息你来写", autoEnter: true),
            Prompt(title: "分块提交", content: "按逻辑分多个 commit,每个一件事", autoEnter: true),
            Prompt(title: "改信息", content: "重写一下最后一次的 commit message", autoEnter: true),
            Prompt(title: "看 diff", content: "git diff 一下,告诉我改了什么", autoEnter: true),
            Prompt(title: "写 PR", content: "写一下 PR 描述,包括动机和改动要点", autoEnter: true),
            Prompt(title: "merge", content: "把当前分支合并到主分支", autoEnter: true)
        ]),

        // 斜杠命令
        PromptTemplateGroup(name: "斜杠命令", icon: "slash.circle", items: [
            Prompt(title: "/clear", content: "/clear", autoEnter: true),
            Prompt(title: "/compact", content: "/compact", autoEnter: true),
            Prompt(title: "/help", content: "/help", autoEnter: true),
            Prompt(title: "/cost", content: "/cost", autoEnter: true),
            Prompt(title: "/model", content: "/model", autoEnter: true),
            Prompt(title: "/context", content: "/context", autoEnter: true),
            Prompt(title: "/init", content: "/init", autoEnter: true),
            Prompt(title: "/review", content: "/review", autoEnter: true),
            Prompt(title: "/security-review", content: "/security-review", autoEnter: true),
            Prompt(title: "/memory", content: "/memory", autoEnter: true),
            Prompt(title: "/status", content: "/status", autoEnter: true),
            Prompt(title: "/config", content: "/config", autoEnter: true)
        ]),

        // 语言切换
        PromptTemplateGroup(name: "语言", icon: "character.bubble", items: [
            Prompt(title: "中文回复", content: "请用中文回复", autoEnter: true),
            Prompt(title: "中文 commit", content: "用中文写 commit message", autoEnter: true),
            Prompt(title: "加中文注释", content: "给关键逻辑加中文注释", autoEnter: true),
            Prompt(title: "Reply in English", content: "please reply in English", autoEnter: true)
        ]),

        // 英文常用 — 在英文项目里更顺手
        PromptTemplateGroup(name: "English", icon: "abc", items: [
            Prompt(title: "continue", content: "continue", autoEnter: true),
            Prompt(title: "yes", content: "yes", autoEnter: true),
            Prompt(title: "no, redo", content: "no, redo it", autoEnter: true),
            Prompt(title: "undo", content: "undo the last change", autoEnter: true),
            Prompt(title: "explain", content: "explain your reasoning", autoEnter: true),
            Prompt(title: "concise", content: "make it more concise", autoEnter: true),
            Prompt(title: "add tests", content: "add tests for the recent change", autoEnter: true),
            Prompt(title: "fix it", content: "fix the error and re-run", autoEnter: true),
            Prompt(title: "refactor", content: "refactor without changing behavior", autoEnter: true),
            Prompt(title: "commit", content: "commit the current changes, write the message yourself", autoEnter: true)
        ])
    ]
}
