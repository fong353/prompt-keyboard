import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

struct ContentView: View {
    @EnvironmentObject var store: PromptStore
    @EnvironmentObject var network: NetworkInfo
    @EnvironmentObject var binding: BindingState
    @State private var showEditor = false
    @State private var showQR = false

    var body: some View {
        VStack(spacing: 0) {
            header
            bindingBar
            Divider()
            buttonGrid
            Divider()
            footer
        }
        .frame(minWidth: 280, minHeight: 240)
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showEditor) {
            EditorView()
                .environmentObject(store)
        }
        .popover(isPresented: $showQR) {
            QRView(url: network.url ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "keyboard")
            Text("提示词键盘")
                .font(.headline)
            Spacer()
            TemplateMenu()
                .environmentObject(store)
            Button {
                showEditor = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("编辑提示词")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var bindingBar: some View {
        HStack(spacing: 6) {
            if binding.isBound {
                Image(systemName: "scope")
                    .foregroundStyle(.green)
                Text(binding.appName ?? "")
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text("PID \(binding.pid ?? 0)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    binding.unbind()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("解绑")
            } else {
                Image(systemName: "scope")
                    .foregroundStyle(.secondary)
                Text("未绑定 · 发送到当前焦点窗口")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    binding.bindToFrontmost()
                } label: {
                    Text("绑定")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("绑定前先在目标 App 里点一下输入框(光标在闪),再点这里")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private var buttonGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 100, maximum: 180), spacing: 6)],
                spacing: 6
            ) {
                ForEach(store.prompts) { prompt in
                    PromptButton(prompt: prompt, binding: binding)
                }
                AddCardButton()
            }
            .padding(8)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "iphone")
                .foregroundStyle(.secondary)
            if let url = network.url {
                Text(url)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .onTapGesture {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                    .help("点击复制地址 · 手机连同一 Wi-Fi 打开")
                Button {
                    showQR = true
                } label: {
                    Image(systemName: "qrcode")
                }
                .buttonStyle(.borderless)
                .help("显示二维码")
            } else {
                Text("局域网 IP 获取中…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct QRView: View {
    let url: String

    var body: some View {
        VStack(spacing: 10) {
            if let img = qrImage() {
                Image(nsImage: img)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
            }
            Text(url)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(16)
    }

    private func qrImage() -> NSImage? {
        guard !url.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.utf8)
        filter.correctionLevel = "M"
        guard let ci = filter.outputImage else { return nil }
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

private struct PromptButton: View {
    let prompt: Prompt
    @ObservedObject var binding: BindingState
    @EnvironmentObject var store: PromptStore
    @State private var flashed = false
    @State private var error = false
    @State private var editing = false

    var body: some View {
        HStack(spacing: 0) {
            // 左侧拖动手柄 — 只在它上面 draggable,主按钮的点击不受影响
            Image(systemName: "line.3.horizontal")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 14)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .help("按住拖动可重新排序")
                .draggable(prompt.id.uuidString) {
                    Text(prompt.title)
                        .padding(6)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                }

            Button {
                // 绑定的进程死了就拒绝发送并红闪一下
                if binding.isBound && !binding.validate() {
                    withAnimation(.easeOut(duration: 0.12)) { error = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        withAnimation(.easeIn(duration: 0.2)) { error = false }
                    }
                    return
                }
                InputSender.send(prompt.content, autoEnter: prompt.autoEnter, toPID: binding.pid, clickOffset: binding.clickOffset)
                withAnimation(.easeOut(duration: 0.12)) { flashed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    withAnimation(.easeIn(duration: 0.18)) { flashed = false }
                }
            } label: {
                Text(prompt.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(
                        error ? Color.red.opacity(0.4) :
                        flashed ? Color.accentColor.opacity(0.35) : Color.clear
                    )
                    .cornerRadius(6)
            }
            .buttonStyle(.bordered)
        }
        .help(helpText)
        .contextMenu {
            Button("编辑…") { editing = true }
            Button("复制") { store.duplicate(id: prompt.id) }
            Divider()
            Button("上移") { store.moveUp(id: prompt.id) }
            Button("下移") { store.moveDown(id: prompt.id) }
            Divider()
            Button("删除", role: .destructive) { store.delete(id: prompt.id) }
        }
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            PromptEditPopover(prompt: prompt, isPresented: $editing)
                .environmentObject(store)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let dropped = UUID(uuidString: raw) else { return false }
            store.move(id: dropped, before: prompt.id)
            return true
        }
    }

    private var helpText: String {
        var s = prompt.content
        if prompt.autoEnter { s += "\n(自动回车)" }
        if let name = binding.appName { s += "\n→ \(name)" }
        s += "\n(右键编辑)"
        return s
    }
}

private struct AddCardButton: View {
    @EnvironmentObject var store: PromptStore
    @State private var editingID: UUID?

    var body: some View {
        Button {
            let new = Prompt(title: "新提示词", content: "")
            store.add(new)
            editingID = new.id
        } label: {
            Image(systemName: "plus")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                        .foregroundStyle(.quaternary)
                )
        }
        .buttonStyle(.plain)
        .help("新增提示词 · 拖卡片到这里 = 移到末尾")
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let dropped = UUID(uuidString: raw) else { return false }
            store.moveToEnd(id: dropped)
            return true
        }
        .popover(
            isPresented: Binding(
                get: { editingID != nil },
                set: { if !$0 { editingID = nil } }
            ),
            arrowEdge: .bottom
        ) {
            if let id = editingID,
               let p = store.prompts.first(where: { $0.id == id }) {
                PromptEditPopover(
                    prompt: p,
                    isPresented: Binding(
                        get: { editingID != nil },
                        set: { if !$0 { editingID = nil } }
                    )
                )
                .environmentObject(store)
            }
        }
    }
}

private struct PromptEditPopover: View {
    let prompt: Prompt
    @Binding var isPresented: Bool
    @EnvironmentObject var store: PromptStore
    @State private var title: String = ""
    @State private var content: String = ""
    @State private var autoEnter: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("名称")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("按钮显示的名称", text: $title)
                .textFieldStyle(.roundedBorder)

            Text("内容")
                .font(.caption)
                .foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                if content.isEmpty {
                    Text("点击后发送的文本…")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $content)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(.quaternary, lineWidth: 1)
            )

            Toggle("发送后自动按回车", isOn: $autoEnter)

            HStack {
                Spacer()
                Button("完成") {
                    var updated = prompt
                    updated.title = title
                    updated.content = content
                    updated.autoEnter = autoEnter
                    store.update(updated)
                    isPresented = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            title = prompt.title
            content = prompt.content
            autoEnter = prompt.autoEnter
        }
    }
}

private struct TemplateMenu: View {
    @EnvironmentObject var store: PromptStore

    var body: some View {
        Menu {
            ForEach(PromptTemplates.groups) { group in
                Menu {
                    Button("全部导入") {
                        for t in group.items {
                            store.add(Prompt(title: t.title, content: t.content, autoEnter: t.autoEnter))
                        }
                    }
                    Divider()
                    ForEach(group.items) { p in
                        Button("\(p.title) — \(preview(p.content))") {
                            store.add(Prompt(title: p.title, content: p.content, autoEnter: p.autoEnter))
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
        .help("从模板库添加")
    }

    private func preview(_ s: String) -> String {
        let line = s.replacingOccurrences(of: "\n", with: " ")
        return line.count > 24 ? String(line.prefix(24)) + "…" : line
    }
}
