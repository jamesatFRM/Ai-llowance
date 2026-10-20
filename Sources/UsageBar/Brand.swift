import AppKit
import SwiftUI

/// Cached small raster assets; no live drawing, animation, or extra background work.
@MainActor
enum Brand {
    static let cyan = Color(red: 0.17, green: 0.78, blue: 0.96)
    static let blue = Color(red: 0.29, green: 0.46, blue: 1)
    static let violet = Color(red: 0.67, green: 0.27, blue: 0.97)
    static let gradient = LinearGradient(colors: [blue, violet], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let icon = load("BrandIcon", template: false)
    static let mark = load("BrandMark", template: true)
    private static func load(_ name: String, template: Bool) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"), let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = template
        return image
    }
    static func menuMark() -> NSImage? {
        let image = mark?.copy() as? NSImage
        image?.size = NSSize(width: 15, height: 15)
        image?.accessibilityDescription = "Ai-llowance"
        return image
    }
}

struct BrandIcon: View {
    var size: CGFloat = 40
    var body: some View {
        if let image = Brand.icon {
            Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size).accessibilityHidden(true)
        }
    }
}


extension NSColor {
    static func accountHex(_ hex: String?) -> NSColor? {
        guard let hex, hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
    static func allowance(_ percent: Double) -> NSColor {
        if percent <= 0 { return .systemRed }
        if percent >= 100 { return .white }
        let stops: [(Double, NSColor)] = [(0, .systemRed), (15, .systemOrange), (30, .systemYellow), (50, .systemPurple), (70, .systemBlue), (85, .systemCyan), (100, .white)]
        let value = max(0, min(100, percent))
        for index in 1..<stops.count where value <= stops[index].0 {
            let a = stops[index - 1], b = stops[index]
            return a.1.blended(withFraction: CGFloat((value - a.0) / (b.0 - a.0)), of: b.1) ?? b.1
        }
        return .white
    }
}
