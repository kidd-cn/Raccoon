// 用法:swift Scripts/make-icon.swift build/AppIcon.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/AppIcon.png"
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
NSColor.systemBlue.setFill()
NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size), xRadius: 180, yRadius: 180).fill()
let para = NSMutableParagraphStyle(); para.alignment = .center
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 620), .paragraphStyle: para]
NSAttributedString(string: "🦝", attributes: attrs)
    // -30: emoji 字形基于行高定位,重心偏上,经验性下移做视觉居中校正(实测)
    .draw(in: NSRect(x: 0, y: (size - 620) / 2 - 30, width: size, height: 700))
image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("render failed") }
do { try png.write(to: URL(fileURLWithPath: out)) }
catch { fatalError("写 \(out) 失败: \(error)") }
print("✅ \(out)")
