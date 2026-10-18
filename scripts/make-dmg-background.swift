import AppKit
let size = NSSize(width: 640, height: 420)
let image = NSImage(size: size)
image.lockFocus()
NSColor(srgbRed: 0.035, green: 0.055, blue: 0.12, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
func text(_ value: String, rect: NSRect, size: CGFloat, color: NSColor, weight: NSFont.Weight) {
    let style = NSMutableParagraphStyle(); style.alignment = .center
    (value as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style])
}
let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
NSImage(contentsOf: resources.appendingPathComponent("BrandIcon.png"))?.draw(in: NSRect(x: 164, y: 325, width: 50, height: 50))
text("Ai-llowance", rect: NSRect(x: 218, y: 329, width: 250, height: 42), size: 30, color: .white, weight: .semibold)
text("Drag the app into Applications", rect: NSRect(x: 40, y: 289, width: 560, height: 25), size: 15, color: NSColor(calibratedWhite: 0.78, alpha: 1), weight: .regular)
text("→", rect: NSRect(x: 280, y: 161, width: 80, height: 75), size: 52, color: NSColor(calibratedRed: 0.61, green: 0.62, blue: 0.95, alpha: 1), weight: .light)
text("Open from Applications. Updates keep your accounts intact.", rect: NSRect(x: 30, y: 49, width: 580, height: 24), size: 13, color: NSColor(calibratedWhite: 0.68, alpha: 1), weight: .regular)
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
