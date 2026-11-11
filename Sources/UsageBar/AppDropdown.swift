import AppKit
import SwiftUI

private typealias DropdownState<Value> = SwiftUI.State<Value>

/// A flat option model keeps keyboard navigation and disabled actions consistent.
/// Settings deliberately keeps its native preference controls.
@MainActor
struct AppDropdownItem {
    let title: String
    var symbol: String? = nil
    var subtitle: String? = nil
    var selected = false
    var enabled = true
    var destructive = false
    var isSeparator = false
    var action: () -> Void = {}
    init(_ title: String, symbol: String? = nil, subtitle: String? = nil,
         selected: Bool = false, enabled: Bool = true, destructive: Bool = false,
         action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.subtitle = subtitle
        self.selected = selected; self.enabled = enabled; self.destructive = destructive; self.action = action
    }
    static var separator: Self {
        var item = Self("") {}; item.isSeparator = true; item.enabled = false; return item
    }
}

@MainActor @resultBuilder
enum AppDropdownBuilder {
    static func buildExpression(_ item: AppDropdownItem) -> [AppDropdownItem] { [item] }
    static func buildBlock(_ parts: [AppDropdownItem]...) -> [AppDropdownItem] { parts.flatMap { $0 } }
    static func buildArray(_ parts: [[AppDropdownItem]]) -> [AppDropdownItem] { parts.flatMap { $0 } }
    static func buildOptional(_ part: [AppDropdownItem]?) -> [AppDropdownItem] { part ?? [] }
    static func buildEither(first: [AppDropdownItem]) -> [AppDropdownItem] { first }
    static func buildEither(second: [AppDropdownItem]) -> [AppDropdownItem] { second }
}

@MainActor
struct AppDropdownOptions {
    let items: [AppDropdownItem]
    var enabledIndices: [Int] { items.indices.filter { items[$0].enabled && !items[$0].isSeparator } }
    var initialIndex: Int? { enabledIndices.first { items[$0].selected } ?? enabledIndices.first }
    func step(from index: Int?, by offset: Int) -> Int? {
        let available = enabledIndices
        guard !available.isEmpty else { return nil }
        guard let index, let position = available.firstIndex(of: index) else { return offset < 0 ? available.last : available.first }
        return available[((position + offset) % available.count + available.count) % available.count]
    }
    func match(_ text: String, after index: Int?) -> Int? {
        let indices = enabledIndices
        let start = index.flatMap { indices.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
        for offset in 0..<indices.count {
            let candidate = indices[(start + offset) % indices.count]
            if items[candidate].title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .hasPrefix(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)) { return candidate }
        }
        return nil
    }
    func canSelect(_ index: Int) -> Bool { items.indices.contains(index) && items[index].enabled && !items[index].isSeparator }
}

/// Both the control and its opened list use the app's glass surfaces.
/// The transient popover needs no global event monitors or timers.
struct AppDropdown: View {
    let title: String
    let symbol: String?
    let accent: Color
    let showsChevron: Bool
    let menuTitle: String?
    private let options: AppDropdownOptions
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @DropdownState private var presented = false
    @FocusState private var triggerFocused: Bool

    init(_ title: String, symbol: String? = nil, accent: Color = .accentColor, showsChevron: Bool = true,
         menuTitle: String? = nil, @AppDropdownBuilder content: () -> [AppDropdownItem]) {
        self.title = title; self.symbol = symbol; self.accent = accent; self.showsChevron = showsChevron
        self.menuTitle = menuTitle; self.options = AppDropdownOptions(items: content())
    }
    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).frame(minWidth: 13).accessibilityHidden(true) }
                if !title.isEmpty { Text(title).lineLimit(1).minimumScaleFactor(0.85).layoutPriority(1) }
                if showsChevron {
                    Spacer(minLength: 3)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, title.isEmpty ? 6 : 8)
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain).focusEffectDisabled().focused($triggerFocused)
        .background {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.08 : 0.4), Color.primary.opacity(0.025)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(LinearGradient(colors: [accent.opacity(presented ? 0.5 : 0.26), Color.primary.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.8)
                .allowsHitTesting(false)
        }
        .accessibilityLabel(title.isEmpty ? "More options" : title)
        .accessibilityValue((title.isEmpty ? "" : title + ", ") + (presented ? "Expanded" : "Collapsed"))
        .onKeyPress(keys: [.downArrow, .upArrow]) { _ in
            guard enabled else { return .ignored }
            presented = true; return .handled
        }
        .popover(isPresented: $presented, arrowEdge: .top) {
            AppDropdownList(title: menuTitle, options: options, accent: accent) { restoreFocus in
                presented = false
                if restoreFocus { triggerFocused = true }
            }
            .preferredColorScheme(scheme)
            .presentationBackground(.clear)
        }
    }
}

private struct AppDropdownList: View {
    let title: String?
    let options: AppDropdownOptions
    let accent: Color
    let close: (Bool) -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.liquidGlass) private var liquidGlass
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @DropdownState private var highlighted: Int?
    @DropdownState private var search = ""
    @DropdownState private var searchDate = Date.distantPast
    @FocusState private var keyboardFocus: Bool
    private var width: CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let longest = options.items.map { max(($0.title as NSString).size(withAttributes: [.font: font]).width,
                                               (($0.subtitle ?? "") as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10)]).width) }.max() ?? 0
        return min(360, max(220, longest + 82))
    }
    private var height: CGFloat {
        min(420, options.items.reduce(CGFloat(12 + (title == nil ? 0 : 30))) { $0 + ($1.isSeparator ? 9 : $1.subtitle == nil ? 34 : 46) })
    }
    private func select(_ index: Int) {
        guard options.canSelect(index) else { return }
        close(false)
        options.items[index].action()
    }
    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                if let title {
                    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).frame(height: 30, alignment: .leading)
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(options.items.indices, id: \.self) { index in
                            let item = options.items[index]
                            if item.isSeparator {
                                Divider().overlay(Color.primary.opacity(0.04)).padding(.horizontal, 10).frame(height: 9)
                            } else {
                                row(item, index: index).id(index)
                            }
                        }
                    }.padding(.horizontal, 6)
                }.scrollIndicators(.automatic)
            }.padding(.vertical, 6)
                .frame(width: width, height: height)
                .background { surface }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.35 : scheme == .dark ? 0.16 : 0.10), lineWidth: 0.8).allowsHitTesting(false))
                .focusable().focusEffectDisabled().focused($keyboardFocus)
                .onAppear { highlighted = options.initialIndex; keyboardFocus = true }
                .onChange(of: highlighted) { _, index in
                    guard let index else { return }
                    if reduceMotion { proxy.scrollTo(index, anchor: nil) }
                    else { withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(index, anchor: nil) } }
                }
                .onKeyPress(keys: [.downArrow, .upArrow, .home, .end, .return, .space, .escape, .tab]) { press in
                    switch press.key {
                    case .downArrow: highlighted = options.step(from: highlighted, by: 1)
                    case .upArrow: highlighted = options.step(from: highlighted, by: -1)
                    case .home: highlighted = options.enabledIndices.first
                    case .end: highlighted = options.enabledIndices.last
                    case .return, .space: if let highlighted { select(highlighted) }
                    case .escape, .tab: close(true)
                    default: return .ignored
                    }
                    return .handled
                }
                .onKeyPress(characters: .alphanumerics) { press in
                    guard press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
                    let now = Date()
                    search = now.timeIntervalSince(searchDate) < 0.7 ? search + press.characters : press.characters
                    searchDate = now
                    if let match = options.match(search, after: highlighted) { highlighted = match }
                    else { search = press.characters; highlighted = options.match(search, after: highlighted) ?? highlighted }
                    return .handled
                }
        }
    }
    private var surface: some View {
        ZStack {
            if reduceTransparency || !liquidGlass { Color(nsColor: .windowBackgroundColor) }
            else { Rectangle().fill(.regularMaterial) }
            LinearGradient(colors: scheme == .dark
                ? [Color.white.opacity(0.08), Color.black.opacity(0.14)]
                : [Color.white.opacity(0.7), Color.white.opacity(0.25)], startPoint: .topLeading, endPoint: .bottomTrailing)
            LinearGradient(colors: [accent.opacity(scheme == .dark ? 0.075 : 0.04), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
    private func row(_ item: AppDropdownItem, index: Int) -> some View {
        let active = highlighted == index && item.enabled
        return Button { select(index) } label: {
            HStack(spacing: 9) {
                if let symbol = item.symbol {
                    Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                        .foregroundStyle(item.destructive ? Color.red : active || item.selected ? accent : .secondary)
                        .frame(width: 22)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.system(size: 12, weight: item.selected ? .semibold : .medium)).lineLimit(1)
                    if let subtitle = item.subtitle { Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 12)
                if item.selected { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(accent) }
            }
            .foregroundStyle(item.destructive ? Color.red : .primary)
            .padding(.horizontal, 10).frame(height: item.subtitle == nil ? 34 : 46)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(accent.opacity(active ? scheme == .dark ? 0.23 : 0.13 : item.selected ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .opacity(item.enabled ? 1 : 0.35)
        }
        .buttonStyle(.plain).disabled(!item.enabled).focusEffectDisabled()
        .onHover { inside in if inside && item.enabled { highlighted = index } }
        .accessibilityValue(item.selected ? "Selected" : "")
    }
}
