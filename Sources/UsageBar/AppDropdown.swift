import SwiftUI

/// Lightweight glass chrome with a flat, keyboard-accessible macOS menu.
/// Settings deliberately keeps its native preference controls.
struct AppDropdown<Content: View>: View {
    let title: String
    let symbol: String?
    let accent: Color
    let showsChevron: Bool
    @Environment(\.colorScheme) private var scheme
    private let content: Content
    init(_ title: String, symbol: String? = nil, accent: Color = .primary, showsChevron: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.title = title; self.symbol = symbol; self.accent = accent; self.showsChevron = showsChevron
        self.content = content()
    }
    var body: some View {
        Menu { content } label: {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol) }
                if !title.isEmpty { Text(title).lineLimit(1) }
            }
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).buttonStyle(.plain)
        .font(.system(size: 11, weight: .medium))
        .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.08 : 0.4), Color.primary.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(LinearGradient(colors: [accent.opacity(0.26), Color.primary.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
        }
        .overlay(alignment: .trailing) {
            if showsChevron {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.trailing, 8).allowsHitTesting(false)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel(title.isEmpty ? "More options" : title)
    }
}

struct AppDropdownChoice: View {
    let title: String
    let selected: Bool
    var body: some View {
        if selected { Label(title, systemImage: "checkmark") }
        else { Text(title) }
    }
}
