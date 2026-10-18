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
