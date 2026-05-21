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
        HStack {
            Image(systemName: "keyboard")
            Text("提示词键盘")
                .font(.headline)
            Spacer()
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
                .help("绑定当前激活的窗口为目标")
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
    @State private var flashed = false
    @State private var error = false

    var body: some View {
        Button {
            // 绑定的进程死了就拒绝发送并红闪一下
            if binding.isBound && !binding.validate() {
                withAnimation(.easeOut(duration: 0.12)) { error = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    withAnimation(.easeIn(duration: 0.2)) { error = false }
                }
                return
            }
            InputSender.send(prompt.content, autoEnter: prompt.autoEnter, toPID: binding.pid)
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
        .help(helpText)
    }

    private var helpText: String {
        var s = prompt.content
        if prompt.autoEnter { s += "\n(自动回车)" }
        if let name = binding.appName { s += "\n→ \(name)" }
        return s
    }
}
