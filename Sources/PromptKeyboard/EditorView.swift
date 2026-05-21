import SwiftUI

struct EditorView: View {
    @EnvironmentObject var store: PromptStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var draft: Prompt = Prompt(title: "", content: "")

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 180, idealWidth: 200)
            detail
                .frame(minWidth: 320)
        }
        .frame(minWidth: 540, minHeight: 360)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
        .onAppear {
            if selection == nil { selection = store.prompts.first?.id }
            loadDraft()
        }
        .onChange(of: selection) { _, _ in loadDraft() }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.prompts) { prompt in
                    HStack {
                        Text(prompt.title.isEmpty ? "(未命名)" : prompt.title)
                            .lineLimit(1)
                        Spacer()
                        if prompt.autoEnter {
                            Image(systemName: "return")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                        }
                    }
                    .tag(prompt.id)
                }
                .onMove { src, dst in store.move(from: src, to: dst) }
                .onDelete { idx in
                    store.remove(at: idx)
                    if let first = store.prompts.first {
                        selection = first.id
                    } else {
                        selection = nil
                    }
                }
            }
            Divider()
            HStack {
                Button {
                    let new = Prompt(title: "新提示词", content: "")
                    store.add(new)
                    selection = new.id
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                Button {
                    guard let sel = selection,
                          let idx = store.prompts.firstIndex(where: { $0.id == sel })
                    else { return }
                    store.remove(at: IndexSet(integer: idx))
                    selection = store.prompts.first?.id
                } label: {
                    Image(systemName: "minus")
                }
                .buttonStyle(.borderless)
                .disabled(selection == nil)
                templateMenu
                Spacer()
            }
            .padding(6)
        }
    }

    private var templateMenu: some View {
        Menu {
            ForEach(PromptTemplates.groups) { group in
                Menu {
                    Button("全部导入") {
                        importAll(group.items)
                    }
                    Divider()
                    ForEach(group.items) { p in
                        Button(p.title + " — " + previewContent(p.content)) {
                            importOne(p)
                        }
                    }
                } label: {
                    Label(group.name, systemImage: group.icon)
                }
            }
        } label: {
            Image(systemName: "square.grid.2x2")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("从模板添加提示词")
    }

    private func importOne(_ template: Prompt) {
        let copy = Prompt(title: template.title, content: template.content, autoEnter: template.autoEnter)
        store.add(copy)
        selection = copy.id
    }

    private func importAll(_ templates: [Prompt]) {
        var lastID: UUID?
        for t in templates {
            let copy = Prompt(title: t.title, content: t.content, autoEnter: t.autoEnter)
            store.add(copy)
            lastID = copy.id
        }
        if let id = lastID { selection = id }
    }

    private func previewContent(_ s: String) -> String {
        let line = s.replacingOccurrences(of: "\n", with: " ")
        return line.count > 24 ? String(line.prefix(24)) + "…" : line
    }

    @ViewBuilder
    private var detail: some View {
        if let sel = selection,
           let idx = store.prompts.firstIndex(where: { $0.id == sel }) {
            Form {
                Section("名称") {
                    TextField("按钮显示的名称", text: Binding(
                        get: { store.prompts[idx].title },
                        set: { store.prompts[idx].title = $0 }
                    ))
                }
                Section("内容") {
                    TextEditor(text: Binding(
                        get: { store.prompts[idx].content },
                        set: { store.prompts[idx].content = $0 }
                    ))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 160)
                }
                Section {
                    Toggle("发送后自动按回车", isOn: Binding(
                        get: { store.prompts[idx].autoEnter },
                        set: { store.prompts[idx].autoEnter = $0 }
                    ))
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView(
                "选择一项编辑",
                systemImage: "square.dashed",
                description: Text("或点击 + 添加新提示词")
            )
        }
    }

    private func loadDraft() {
        guard let sel = selection,
              let p = store.prompts.first(where: { $0.id == sel })
        else { return }
        draft = p
    }
}
