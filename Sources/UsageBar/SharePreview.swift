import AppKit
import SwiftUI

/// Shareable artifact rendered from the actual views and a strictly in-memory demo store.
struct SharePreview: View {
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ForEach(Array(store.menuEntries.enumerated()), id: \.offset) { _, entry in
                    HStack(spacing: 4) {
                        ProviderMark(provider: entry.provider, size: 13)
                        Text(entry.remainingPercent.map { "\(Int($0))%" } ?? "—")
                            .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    }
                }
            }.padding(.horizontal, 16).padding(.vertical, 9)
                .background(Color.primary.opacity(0.06), in: Capsule())
            Dashboard(store: store, renderForSharing: true, manage: {}).clipShape(RoundedRectangle(cornerRadius: 14))
        }.padding(20).background(Color(nsColor: .windowBackgroundColor))
    }
    @MainActor static func export(store: AppStore, directory: URL) throws {
        guard store.demo else { throw NSError(domain: "Preview", code: 1) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
            let content = SharePreview(store: store).environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 3
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "Preview", code: 2)
            }
            try png.write(to: directory.appendingPathComponent("Ai-llowance-share-\(name).png"), options: .atomic)
        }
    }
}
