import AppKit
import SwiftUI
import CoreImage
import UsageCore

@MainActor
enum ProviderImages {
    static let menuIconSize: CGFloat = 16
    private static var menuImages: [MenuProvider: NSImage] = [:]

    static func menuImage(_ provider: MenuProvider?) -> NSImage? {
        if let provider, let cached = menuImages[provider] { return cached.copy() as? NSImage }
        guard let source = image(provider) else { return nil }
        var result = source
        // Match visible artwork, not the different transparent margins in provider assets.
        if provider == .claude || provider == .openAI,
           let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let bitmap = NSBitmapImageRep(cgImage: cg)
            var left = bitmap.pixelsWide, top = bitmap.pixelsHigh, right = -1, bottom = -1
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                    left = min(left, x); right = max(right, x)
                    top = min(top, y); bottom = max(bottom, y)
                }
            }
            if right >= left, bottom >= top,
               let cropped = cg.cropping(to: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)) {
                let side = CGFloat(max(cropped.width, cropped.height))
                let canvas = NSImage(size: NSSize(width: menuIconSize, height: menuIconSize))
                canvas.lockFocus()
                let width = CGFloat(cropped.width) / side * menuIconSize
                let height = CGFloat(cropped.height) / side * menuIconSize
                NSImage(cgImage: cropped, size: .zero).draw(in: NSRect(x: (menuIconSize - width) / 2, y: (menuIconSize - height) / 2, width: width, height: height))
                canvas.unlockFocus()
                result = canvas
            }
        }
        result.size = NSSize(width: menuIconSize, height: menuIconSize)
        result.isTemplate = true
        if let provider { menuImages[provider] = result }
        return result.copy() as? NSImage
    }

    private static let claude = load("Claude")
    private static let openAI = load("ChatGPT")
    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        guard let original = NSImage(contentsOf: url) else { return nil }
        let image: NSImage
        if name == "ChatGPT" {
            // Convert the official black-on-white mark to an alpha template at load time.
            // Its geometry stays exact; native template rendering supplies the foreground color.
            guard let source = CIImage(contentsOf: url),
                  !source.extent.isEmpty else { return nil }
            let sized = source.transformed(by: CGAffineTransform(scaleX: 64 / source.extent.width, y: 64 / source.extent.height))
            let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
            guard let mask = context.createCGImage(sized.applyingFilter("CIColorInvert")
                .applyingFilter("CIMaskToAlpha"), from: sized.extent) else { return nil }
            image = NSImage(cgImage: mask, size: NSSize(width: 32, height: 32))
        } else { image = original }
        image.isTemplate = true
        return image
    }
    static func image(_ provider: MenuProvider?) -> NSImage? {
        switch provider {
        case .claude: claude?.copy() as? NSImage
        case .openAI: openAI?.copy() as? NSImage
        // Native symbols identify integrations without downloading or imitating provider artwork.
        case .copilot: NSImage(systemSymbolName: "terminal", accessibilityDescription: "GitHub Copilot")
        case .openRouter: NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "OpenRouter")
        case .vercelGateway: NSImage(systemSymbolName: "triangle", accessibilityDescription: "Vercel AI Gateway")
        case .xai: NSImage(systemSymbolName: "sparkle", accessibilityDescription: "xAI")
        case nil: Brand.menuMark()
        }
    }
}

struct ProviderMark: View {
    let provider: MenuProvider?
    var size: CGFloat = 15
    var isMenuBar = false
    var body: some View {
        if let image = isMenuBar ? ProviderImages.menuImage(provider) : ProviderImages.image(provider) {
            Image(nsImage: image).renderingMode(.template).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size).foregroundStyle(.primary).accessibilityLabel(provider?.title ?? "All accounts")
        }
    }
}

func allowanceColor(_ remaining: Double) -> Color {
    switch AllowanceBand.remaining(remaining) {
    case .normal: .primary
    case .warning: .yellow
    case .critical: .red
    }
}

struct AllowanceBar: View {
    let remaining: Double
    var unavailable = false
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                Capsule().fill(unavailable ? .gray : allowanceColor(remaining))
                    .frame(width: proxy.size.width * min(100, max(0, remaining)) / 100)
            }
        }.accessibilityLabel("\(Int(remaining)) percent remaining")
    }
}

extension AppTheme {
    var colorScheme: ColorScheme? {
        switch self { case .automatic: nil; case .light: .light; case .dark: .dark }
    }
}
