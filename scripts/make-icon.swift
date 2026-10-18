import AppKit
import Foundation

// Original Ai-llowance identity. One source supplies the app tile and template mark.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
func monogram(_ context: CGContext, color: CGColor) {
    context.setStrokeColor(color)
    context.setLineWidth(110)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: 294, y: 300))
    context.addLine(to: CGPoint(x: 475, y: 708))
    context.addQuadCurve(to: CGPoint(x: 553, y: 708), control: CGPoint(x: 514, y: 789))
    context.addLine(to: CGPoint(x: 735, y: 300))
    context.strokePath()
    context.move(to: CGPoint(x: 337, y: 365))
    context.addCurve(to: CGPoint(x: 649, y: 369), control1: CGPoint(x: 438, y: 464), control2: CGPoint(x: 533, y: 456))
    context.strokePath()
}
func render(pixels: Int, template: Bool = false) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    if template {
        // Fit the mark itself to the menu-bar glyph bounds; no tile padding.
        context.scaleBy(x: CGFloat(pixels) / 620, y: CGFloat(pixels) / 620)
        context.translateBy(x: -202, y: -205)
        monogram(context, color: NSColor.black.cgColor)
    } else {
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let tile = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 218, yRadius: 218)
        context.saveGState()
        tile.addClip()
        NSGradient(colorsAndLocations:
            (NSColor(srgbRed: 0.17, green: 0.78, blue: 0.96, alpha: 1), 0),
            (NSColor(srgbRed: 0.29, green: 0.46, blue: 1, alpha: 1), 0.48),
            (NSColor(srgbRed: 0.67, green: 0.27, blue: 0.97, alpha: 1), 1))!
            .draw(from: NSPoint(x: 210, y: 984), to: NSPoint(x: 790, y: 40), options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
        context.restoreGState()
        NSColor.white.withAlphaComponent(0.18).setStroke(); tile.lineWidth = 12; tile.stroke()
        monogram(context, color: NSColor.white.cgColor)
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: size * scale).write(to: directory.appendingPathComponent(name))
    }
}
if CommandLine.arguments.count > 2 {
    let resources = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    try render(pixels: 128).write(to: resources.appendingPathComponent("BrandIcon.png"))
    try render(pixels: 64, template: true).write(to: resources.appendingPathComponent("BrandMark.png"))
}
