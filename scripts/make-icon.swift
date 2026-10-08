import AppKit
import Foundation

// Original artwork; no provider marks or external assets.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.14, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 218, yRadius: 218).fill()
        for (index, width) in [CGFloat(410), 270, 350].enumerated() {
            let y = CGFloat(655 - index * 185)
            NSColor.white.withAlphaComponent(0.13).setFill()
            NSBezierPath(roundedRect: NSRect(x: 225, y: y, width: 574, height: 92), xRadius: 46, yRadius: 46).fill()
            (index == 1 ? NSColor(calibratedRed: 1, green: 0.56, blue: 0.19, alpha: 1)
                        : NSColor(calibratedRed: 0.25, green: 0.84, blue: 0.94, alpha: 1)).setFill()
            NSBezierPath(roundedRect: NSRect(x: 225, y: y, width: width, height: 92), xRadius: 46, yRadius: 46).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
    }
}
