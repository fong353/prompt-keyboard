#!/usr/bin/env swift
// 生成 macOS .icns 图标:蓝色圆角底 + 白色 keyboard SF Symbol
// 用法: ./make_icon.swift <output.icns>
import AppKit
import Foundation

guard CommandLine.arguments.count >= 2 else {
    print("usage: make_icon.swift <output.icns>")
    exit(1)
}
let outputPath = CommandLine.arguments[1]

func render(size: Int) -> Data? {
    let s = NSSize(width: size, height: size)
    let img = NSImage(size: s)
    img.lockFocus()

    // 圆角背景渐变
    let radius = CGFloat(size) * 0.22
    let bgRect = NSRect(origin: .zero, size: s)
    let path = NSBezierPath(roundedRect: bgRect, xRadius: radius, yRadius: radius)
    path.addClip()

    let gradient = NSGradient(colors: [
        NSColor(red: 0.30, green: 0.55, blue: 1.00, alpha: 1.0),
        NSColor(red: 0.20, green: 0.40, blue: 0.90, alpha: 1.0)
    ])
    gradient?.draw(in: bgRect, angle: -90)

    // SF Symbol: keyboard.fill 白色,居中
    let pt = CGFloat(size) * 0.5
    let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: .semibold)
    if let sym = NSImage(systemSymbolName: "keyboard.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let ss = sym.size
        // 先把 symbol 染成白色
        let white = NSImage(size: ss)
        white.lockFocus()
        sym.draw(at: .zero, from: NSRect(origin: .zero, size: ss),
                 operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        NSRect(origin: .zero, size: ss).fill(using: .sourceAtop)
        white.unlockFocus()

        let drawRect = NSRect(
            x: (s.width - ss.width) / 2,
            y: (s.height - ss.height) / 2,
            width: ss.width,
            height: ss.height
        )
        white.draw(in: drawRect)
    }

    img.unlockFocus()

    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { return nil }
    return png
}

let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("PromptKeyboard-\(UUID().uuidString).iconset")
try? FileManager.default.removeItem(at: tmp)
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

let mapping: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for (size, name) in mapping {
    guard let data = render(size: size) else {
        FileHandle.standardError.write(Data("render \(size) failed\n".utf8))
        exit(1)
    }
    try data.write(to: tmp.appendingPathComponent(name))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", tmp.path, "-o", outputPath]
try task.run()
task.waitUntilExit()

try? FileManager.default.removeItem(at: tmp)

print("✓ \(outputPath)")
