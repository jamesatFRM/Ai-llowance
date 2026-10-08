import AppKit
import SwiftUI
import CoreImage
import UsageCore

@MainActor
enum ProviderImages {
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
        case nil: NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "All accounts")
        }
    }
}

struct ProviderMark: View {
    let provider: MenuProvider?
    var size: CGFloat = 15
    var body: some View {
        if let image = ProviderImages.image(provider) {
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
