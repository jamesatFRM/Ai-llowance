import SwiftUI
import Charts
import AppKit
import UsageCore

// Explicit wrapper alias avoids the newer SDK State macro; remains compatible with macOS 14.
private typealias ViewState<Value> = SwiftUI.State<Value>

private struct DropdownContentHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// One native material layer, with inexpensive fills above it. No animated effects or extra polling.
private struct PanelBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            Rectangle().fill(.regularMaterial)
                .overlay(alignment: .top) {
                    LinearGradient(colors: [Brand.blue.opacity(0.055), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 150)
                }
        }
    }
}

private struct LiquidGlassPreference: EnvironmentKey {
    static let defaultValue = true
}
private extension EnvironmentValues {
    var liquidGlass: Bool {
        get { self[LiquidGlassPreference.self] }
        set { self[LiquidGlassPreference.self] = newValue }
    }
}
// A decorative native view must never intercept controls or initiate window dragging.
final class PassiveGlassView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { false }
    override var acceptsFirstResponder: Bool { false }
}

private struct DesktopGlass: NSViewRepresentable {
    @Environment(\.colorScheme) private var scheme
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = PassiveGlassView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        let name: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
        if view.appearance?.name != name { view.appearance = NSAppearance(named: name) }
    }
}

// One native material backing; cards use inexpensive translucent fills.
private struct WorkspaceBackground: View {
    var transparency: Double = 0.75
    @Environment(\.liquidGlass) private var liquidGlass
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            if reduceTransparency || !liquidGlass {
                Color(nsColor: .windowBackgroundColor)
            } else {
                DesktopGlass()
                    .overlay(scheme == .dark ? Color.black.opacity(1 - transparency * 0.85) : Color.white.opacity(1 - transparency * 0.9))
            }
            if !reduceTransparency && liquidGlass {
                RadialGradient(colors: [Color.mint.opacity(scheme == .dark ? 0.10 : 0.06), .clear], center: .topLeading, startRadius: 0, endRadius: 650)
                RadialGradient(colors: [Color.purple.opacity(scheme == .dark ? 0.09 : 0.045), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 650)
            }
            LinearGradient(colors: scheme == .dark
                ? [Color.white.opacity(0.055), Color.white.opacity(0.015), Color.black.opacity(0.10)]
                : [Color.white.opacity(0.55), Color.white.opacity(0.20), Color.black.opacity(0.025)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

@MainActor
private func providerAccent(_ provider: MenuProvider) -> Color {
    switch provider {
    case .openAI: Color(red: 0.23, green: 0.78, blue: 0.61)
    case .claude: Color(red: 0.95, green: 0.55, blue: 0.37)
    case .copilot: Brand.violet
    case .openRouter: Color(red: 0.78, green: 0.54, blue: 0.98)
    case .vercelGateway: Brand.cyan
    case .grok, .xai: Color(red: 0.86, green: 0.72, blue: 0.40)
    }
}

private struct InsetSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var tint: Color = .clear
    var cornerRadius: CGFloat = 10
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.065 : 0.72),
                    Color.white.opacity(colorScheme == .dark ? 0.035 : 0.42)
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(tint.opacity(0.09))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.075), lineWidth: 0.5)
                }
        }
    }
}

private struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.secondary : Color.secondary.opacity(0.45))
            .background(Color.primary.opacity(configuration.isPressed ? 0.10 : 0.035), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct Dashboard: View {
    @ObservedObject var store: AppStore
    var renderForSharing = false
    var maximumHeight: CGFloat = 620
    var manage: () -> Void
    var moveEarlier: (() -> Void)? = nil
    var moveLater: (() -> Void)? = nil
    var resetOrder: (() -> Void)? = nil
    @ViewState private var expandedAccountID: UUID?
    @ViewState private var providerContentHeight: CGFloat = 500

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                BrandIcon(size: 22)
                Text("Ai-llowance").font(.system(size: 12, weight: .semibold))
                Spacer()
                if store.refreshing { ProgressView().controlSize(.mini) }
                Text(store.refreshSummary).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Button { store.refresh(force: true) } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .medium)).frame(width: 22, height: 22) }
                    .buttonStyle(QuietButtonStyle()).help("Refresh (respects provider backoff)")
                    .accessibilityLabel("Refresh accounts").disabled(store.refreshing || store.paused || store.demo)
            }.padding(.horizontal, 9).padding(.top, 1)
            if store.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    Label("Connect your first account", systemImage: "person.crop.circle.badge.plus").font(.system(size: 12, weight: .semibold))
                    Text("See your limits before they stop your work.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Get started", action: manage).controlSize(.small)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).modifier(InsetSurface())
            } else if renderForSharing {
                providerContent
            } else {
                ScrollView {
                    providerContent.background(GeometryReader { geometry in
                        Color.clear.preference(key: DropdownContentHeight.self, value: geometry.size.height)
                    })
                }
                .scrollIndicators(.automatic)
                .frame(height: min(providerContentHeight, max(40, min(500, maximumHeight - 100))))
                .clipped()
                .onPreferenceChange(DropdownContentHeight.self) { providerContentHeight = $0 }
            }
            HStack(spacing: 5) {
                Button(action: manage) { Label("Dashboard", systemImage: "square.grid.2x2").padding(.horizontal, 5).frame(height: 22) }
                    .buttonStyle(QuietButtonStyle()).help("Open dashboard")
                Spacer()
                Text(AppUpdater.versionLabel).monospacedDigit().foregroundStyle(.secondary).padding(.trailing, 3)
                UpdateCheckButton(updater: store.updater)
                Button { store.togglePause() } label: { Image(systemName: store.paused ? "play.fill" : "pause.fill").frame(width: 22, height: 22) }
                    .help(store.paused ? "Resume automatic refresh" : "Pause automatic refresh")
                    .accessibilityLabel(store.paused ? "Resume automatic refresh" : "Pause automatic refresh").disabled(store.demo)
                Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power").frame(width: 22, height: 22) }
                    .help("Quit Ai-llowance").accessibilityLabel("Quit Ai-llowance")
            }.font(.system(size: 10)).buttonStyle(QuietButtonStyle()).foregroundStyle(.secondary).padding(.horizontal, 9).padding(.bottom, 3)
        }.padding(7).frame(width: 350).background(WorkspaceBackground(transparency: store.menuPreferences.dropdownTransparency)).preferredColorScheme(store.menuPreferences.theme.colorScheme).environment(\.liquidGlass, store.menuPreferences.liquidGlass)
    }

    private func manage(_ account: Account) { store.selectedAccountID = account.id; manage() }
    private var attentionAccounts: [Account] {
        Array(store.accounts.enumerated().filter { _, account in
            guard account.enabled else { return false }
            let status = readingStatus(account)
            return store.needsSignIn(account) || store.errors[account.id] != nil || status.state == .restricted || status.state == .exhausted
        }.sorted { lhs, rhs in
            let left = store.needsSignIn(lhs.element) || store.errors[lhs.element.id] != nil
            let right = store.needsSignIn(rhs.element) || store.errors[rhs.element.id] != nil
            return left == right ? lhs.offset < rhs.offset : left
        }.prefix(3).map(\.element))
    }
    private func readingStatus(_ account: Account) -> AllowanceStatus {
        AllowanceStatus.evaluate(snapshot: store.snapshots[account.id], kind: account.kind, now: store.now, hasError: store.errors[account.id] != nil)
    }
    private var providerContent: some View {
        VStack(spacing: 8) {
            if !attentionAccounts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Circle().fill(Color.orange).frame(width: 4, height: 4)
                        Text("Needs attention").font(.system(size: 9, weight: .semibold)).textCase(.uppercase).tracking(0.6)
                    }.foregroundStyle(.secondary)
                    ForEach(attentionAccounts) { account in
                        let status = readingStatus(account)
                        Button { manage(account) } label: {
                            HStack(spacing: 7) {
                                Image(systemName: store.needsSignIn(account) ? "person.crop.circle.badge.exclamationmark" : status.symbol)
                                    .frame(width: 14).foregroundStyle(.orange)
                                Text(account.name).fontWeight(.medium).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(store.connectionState(account).title).foregroundStyle(.secondary).lineLimit(1)
                                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                            }.font(.system(size: 11)).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(11).modifier(InsetSurface(tint: .orange))
            }
            ForEach(MenuProvider.allCases, id: \.self) { provider in
                let accounts = store.accounts.filter { $0.kind.provider == provider }
                if !accounts.isEmpty {
                    VStack(spacing: 0) {
                        if store.menuPreferences.dropdownShowHeadings { HStack {
                            Text(provider.title).font(.system(size: 9, weight: .semibold)).textCase(.uppercase).tracking(0.7)
                            Spacer()
                            Text("\(accounts.count)").font(.system(size: 8, weight: .medium)).monospacedDigit()
                                .frame(minWidth: 16, minHeight: 13)
                                .background(Color.primary.opacity(0.045), in: Capsule())
                        }.foregroundStyle(.secondary).padding(.bottom, 5) }
                        ForEach(accounts) { account in
                            CompactAccountRow(account: account, snapshot: store.snapshots[account.id], error: store.errors[account.id], now: store.now, cached: store.isCached(account),
                                expanded: expandedAccountID == account.id,
                                detailedLabels: store.menuPreferences.detailedQuotaLabels, connection: store.connectionState(account), dropdownPreferences: store.menuPreferences, colorByAllowance: store.menuPreferences.colorByAllowance,
                                history: expandedAccountID == account.id || store.menuPreferences.dropdownShowRecentUsage ? store.history(for: account) : [],
                                expand: { expandedAccountID = expandedAccountID == account.id ? nil : account.id },
                                manage: { manage(account) }, openUsage: { store.openUsage(account) })
                            if account.id != accounts.last?.id { Divider().opacity(0.35).padding(.leading, 21).padding(.vertical, 4) }
                        }
                    }.padding(.horizontal, 11).padding(.vertical, 9)
                        .modifier(InsetSurface(tint: providerAccent(provider), cornerRadius: 14))
                }
            }
        }
    }
}

private struct CompactAccountRow: View {
    let account: Account
    let snapshot: Snapshot?
    let error: String?
    let now: Date
    let cached: Bool
    let expanded: Bool
    let detailedLabels: Bool
    var connection: ConnectionPresentation? = nil
    var dropdownPreferences = MenuPreferences()
    let colorByAllowance: Bool
    let history: [UsageHistoryPoint]
    let expand: () -> Void
    let manage: () -> Void
    let openUsage: () -> Void
    private var status: AllowanceStatus { AllowanceStatus.evaluate(snapshot: snapshot, kind: account.kind, now: now, hasError: error != nil) }
    private var reading: ReadingPresentation { ReadingPresentation(snapshot: snapshot, kind: account.kind, now: now, saved: connection?.saved == true || cached) }
    private var window: QuotaWindow? { reading.window }
    private var detail: String {
        if let connection, connection.saved || connection.needsAction || status.state == .exhausted || snapshot == nil {
            let period = window.map { ReadingPresentation.windowLabel($0) + " · " } ?? ""
            return period + connection.title + " · " + connection.detail
        }
        if !account.enabled { return "Paused" }
        if error != nil { return snapshot == nil ? "Check connection" : "Last known · refresh failed" }
        if cached { return "Saved reading · checking for update" }
        if status.state == .stale { return "Last known · waiting for update" }
        if status.state == .restricted { return "Provider restriction" }
        if snapshot?.unlimited == true { return "No reported limit" }
        if let balanceLabel = snapshot?.balanceLabel { return balanceLabel }
        if snapshot?.balanceUSD != nil { return "Credit balance" }
        if snapshot?.costUSD != nil { return "Spent this month · UTC" }
        if let window { return dropdownPreferences.dropdownShowResets ? "\(shortWindowLabel(window)) · \(resetText(window.resetsAt, at: now))" : shortWindowLabel(window) }
        return snapshot == nil ? "Waiting for first reading" : "Quota unavailable"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: expand) {
                VStack(spacing: 4) {
                    HStack(spacing: 7) {
                        ProviderMark(provider: account.kind.provider, size: 14).foregroundStyle(NSColor.accountHex(account.menuColorHex).map { Color(nsColor: $0) } ?? providerAccent(account.kind.provider))
                        Text(account.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 5)
                        Text(reading.value).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(error != nil || reading.saved || cached || status.state == .stale || status.state == .restricted || !account.enabled ? Color.secondary : (colorByAllowance && window != nil ? Color(nsColor: .allowance(window!.remainingPercent)) : NSColor.accountHex(account.menuColorHex).map { Color(nsColor: $0) } ?? Color.primary))
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary).frame(width: 12)
                    }
                    HStack(spacing: 7) {
                        Text(detail).font(.system(size: 9)).foregroundStyle(error != nil || status.state == .restricted ? Color.orange : Color.secondary).lineLimit(connection?.saved == true || connection?.needsAction == true || status.state == .exhausted ? 2 : 1)
                        Spacer(minLength: 2)
                        VStack(alignment: .trailing, spacing: 3) {
                            if dropdownPreferences.dropdownShowRecentUsage {
                                RecentUsageSparkline(history: history, kind: account.kind, now: now,
                                    tint: NSColor.accountHex(account.menuColorHex).map { Color(nsColor: $0) } ?? providerAccent(account.kind.provider))
                                    .frame(width: 60, height: 18)
                            }
                            if dropdownPreferences.dropdownShowBars, connection?.saved != true, connection?.needsAction != true, status.state != .exhausted, let window {
                                AllowanceBar(remaining: window.remainingPercent, unavailable: error != nil || reading.saved || cached || status.state == .stale || status.state == .restricted || !account.enabled)
                                    .frame(width: 54, height: 3)
                            }
                        }
                    }.padding(.leading, 21)
                    if dropdownPreferences.dropdownShowEmails, let email = account.expectedIdentity ?? snapshot?.identity {
                        Text(email).font(.system(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 21)
                    }
                }.padding(.vertical, dropdownPreferences.dropdownRoomyRows ? 9 : 4).contentShape(Rectangle())
            }.buttonStyle(.plain).help("\(account.kind.title) · click for limits and actions")
                .accessibilityLabel("\(account.name), \(reading.value), \(detail), \(expanded ? "collapse" : "show details")")
            if detailedLabels, let snapshot {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(snapshot.windows) { window in
                        QuotaDetailRow(window: window, now: now, unavailable: reading.saved || error != nil || cached || snapshot.isStale(at: now, windows: [window]) || !account.enabled || snapshot.providerRestricted == true, showReset: dropdownPreferences.dropdownShowResets, showBar: dropdownPreferences.dropdownShowBars)
                    }
                }.padding(.leading, 21).padding(.bottom, 4)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !dropdownPreferences.dropdownShowEmails, let email = account.expectedIdentity ?? snapshot?.identity {
                        Text(email).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    if let snapshot {
                        if !detailedLabels {
                            ForEach(snapshot.windows) { window in QuotaDetailRow(window: window, now: now, unavailable: reading.saved || error != nil || cached || snapshot.isStale(at: now, windows: [window]) || !account.enabled || snapshot.providerRestricted == true, showReset: dropdownPreferences.dropdownShowResets, showBar: dropdownPreferences.dropdownShowBars) }
                        }
                        HistorySparkline(points: history, kind: account.kind)
                        Text(readingAge(snapshot.observedAt, at: now)).font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    if let error { Text(error).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                    HStack {
                        Button(action: openUsage) { Label("Open usage", systemImage: "arrow.up.right").padding(.horizontal, 6).frame(height: 20) }
                        Spacer()
                        Button(action: manage) { Label(error == nil ? "Account" : "Fix connection", systemImage: "gearshape").padding(.horizontal, 6).frame(height: 20) }
                    }.font(.system(size: 10)).buttonStyle(QuietButtonStyle()).foregroundStyle(.secondary)
                }.padding(.leading, 21).padding(.top, 2).padding(.bottom, 4)
            }
        }
    }
}

private func shortWindowLabel(_ window: QuotaWindow) -> String { ReadingPresentation.windowLabel(window) }
private func resetText(_ date: Date?, at now: Date) -> String { ReadingPresentation.resetText(date, at: now) }
private func readingAge(_ date: Date, at now: Date) -> String {
    let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
    if minutes == 0 { return "Read just now" }
    if minutes < 60 { return "Read \(minutes)m ago" }
    if minutes < 1440 { return "Read \(minutes / 60)h \(minutes % 60)m ago" }
    return "Read \(minutes / 1440)d ago"
}
private func menuEntryValue(_ entry: MenuEntry) -> String {
    if entry.isBalance { return entry.balanceUSD?.formatted(.currency(code: "USD").precision(.fractionLength(0...2))) ?? "—" }
    return entry.isUnlimited ? "∞" : (entry.remainingPercent.map { "\(Int($0))%" } ?? "—")
}
private struct QuotaDetailRow: View {
    let window: QuotaWindow
    let now: Date
    var unavailable = false
    var showReset = true
    var showBar = true
    var body: some View {
        let stale = window.resetsAt.map { $0 <= now } ?? false
        VStack(spacing: 3) {
            HStack {
                Text(shortWindowLabel(window)).lineLimit(1)
                Spacer()
                Text("\(Int(window.remainingPercent))% left").fontWeight(.medium).monospacedDigit()
            }.font(.system(size: 10))
            if showReset || showBar { HStack {
                if showReset { Text(resetText(window.resetsAt, at: now)).font(.system(size: 9)).foregroundStyle(.secondary) }
                Spacer()
                if showBar { AllowanceBar(remaining: window.remainingPercent, unavailable: unavailable || stale).frame(width: 64, height: 3) }
            } }
        }.foregroundStyle(unavailable || stale ? .secondary : .primary)
    }
}
private struct HistorySparkline: View {
    let points: [UsageHistoryPoint]
    let kind: ConnectionKind
    private var samples: [HistorySample] { HistorySeries.samples(points, kind: kind) }
    private var series: [(Date, Double)] { samples.map { ($0.timestamp, $0.value) } }
    private var values: [Double] { series.map { $0.1 } }
    var body: some View {
        if values.count >= 2 {
            VStack(alignment: .leading, spacing: 3) {
                SparklineShape(values: values, dates: series.map { $0.0 }, segments: samples.map(\.segment)).stroke(Brand.gradient, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)).frame(height: 26)
                HStack {
                    Text("Recent readings")
                    Spacer()
                    if let first = points.first { Text(first.timestamp, format: .dateTime.hour().minute()) }
                    Text("→")
                    if let last = points.last { Text(last.timestamp, format: .dateTime.hour().minute()) }
                }.font(.system(size: 8)).foregroundStyle(.tertiary)
            }.accessibilityElement(children: .ignore).accessibilityLabel("\(values.count) recent local usage readings")
        }
    }
}
private struct SparklineShape: Shape {
    let values: [Double]
    let dates: [Date]
    let segments: [Int]
    func path(in rect: CGRect) -> Path {
        guard values.count > 1, let low = values.min(), let high = values.max() else { return Path() }
        let range = max(high - low, 1)
        var path = Path()
        for (index, value) in values.enumerated() {
            let duration = (dates.last ?? .distantPast).timeIntervalSince(dates.first ?? .distantPast)
            let position = dates.count == values.count && duration > 0 ? dates[index].timeIntervalSince(dates[0]) / duration : Double(index) / Double(values.count - 1)
            let point = CGPoint(x: CGFloat(position) * rect.width, y: rect.midY - CGFloat((value - (high + low) / 2) / range) * max(0, rect.height - 4))
            if index == 0 || (segments.count == values.count && segments[index] != segments[index - 1]) { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
private struct SettingsCard<Content: View>: View {
    @Environment(\.liquidGlass) private var liquidGlass
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    var inset: CGFloat = 14
    var tint: Color = .clear
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(inset).frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
                shape.fill(Color(nsColor: .windowBackgroundColor).opacity(reduceTransparency || !liquidGlass ? 1 : scheme == .dark ? 0.10 : 0.22))
                    .overlay {
                        if !reduceTransparency && liquidGlass {
                            shape.fill(LinearGradient(colors: [
                                Color.white.opacity(scheme == .dark ? 0.14 : 0.75),
                                tint.opacity(0.045),
                                Color.white.opacity(scheme == .dark ? 0.025 : 0.28)
                            ], startPoint: .topLeading, endPoint: .bottomTrailing))
                        }
                    }
                    .overlay {
                        shape.strokeBorder(LinearGradient(colors: [
                            Color.white.opacity(scheme == .dark ? 0.38 : 0.95),
                            Color.primary.opacity(0.07),
                            Color.white.opacity(scheme == .dark ? 0.14 : 0.60)
                        ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: contrast == .increased ? 1.5 : 0.8)
                    }
                    .shadow(color: Color.black.opacity(scheme == .dark ? 0.13 : 0.04), radius: 12, y: 5)
            }
    }
}

private enum DashboardSection: String, CaseIterable, Identifiable {
    case trends = "Trends", overview = "Overview", history = "History", accounts = "Accounts", settings = "Settings", connection = "Connection"
    var id: String { rawValue }
}


private struct AccountReading: View {
    let account: Account
    let snapshot: Snapshot?
    let error: String?
    let now: Date
    let cached: Bool
    let connection: ConnectionPresentation
    var body: some View {
        let reading = ReadingPresentation(snapshot: snapshot, kind: account.kind, now: now, saved: connection.saved)
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                ProviderMark(provider: account.kind.provider)
                Text(account.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer()
                if !account.enabled { Image(systemName: "pause.fill").foregroundStyle(.secondary).help("Paused") }
                else if error != nil { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).help("Connection needs attention") }
                Text(reading.value).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(reading.saved ? .secondary : .primary)
            }
            if let email = account.expectedIdentity ?? snapshot?.identity { Text(email).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
            Text((reading.saved ? "Last known · " : "") + reading.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            if let snapshot {
                if let label = snapshot.balanceLabel { Text(label).font(.system(size: 10)).foregroundStyle(.secondary) }
                else if snapshot.balanceUSD != nil { Text("Credit balance").font(.system(size: 10)).foregroundStyle(.secondary) }
                else if snapshot.costUSD != nil { Text("API spending · this UTC month").font(.system(size: 10)).foregroundStyle(.secondary) }
                ForEach(snapshot.windows) { window in QuotaDetailRow(window: window, now: now, unavailable: reading.saved || error != nil || cached || snapshot.isStale(at: now, windows: [window]) || !account.enabled || snapshot.providerRestricted == true) }
                ConnectionStatusLine(connection: connection)
                if snapshot.providerRestricted == true { Text("Provider restriction. These percentages do not guarantee requests are available.").font(.system(size: 10)).foregroundStyle(.orange) }
            }
            if let error { Text(error).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General", menuBar = "Menu Bar", dropdown = "Dropdown", updates = "Updates", advanced = "Advanced"
    var id: String { rawValue }
}

private struct ConnectionStatusLine: View {
    let connection: ConnectionPresentation
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(connection.title, systemImage: connection.symbol)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(connection.needsAction ? Color.orange : connection.saved ? .secondary : .primary)
            Text(connection.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
}

struct AccountsView: View {
    @ObservedObject var store: AppStore
    var showMenu: () -> Void
    @ViewState private var selectedKind: ConnectionKind = .claudeCode
    @ViewState private var setupStarted = false
    @ViewState private var setupExistingIDs: Set<UUID> = []
    @ViewState private var manualConnection = false
    @ViewState private var name = ""
    @ViewState private var secret = ""
    @ViewState private var scopeID = ""
    @ViewState private var connectionError: String?
    @ViewState private var removing: Account?
    @ViewState private var renaming: Account?
    @ViewState private var newName = ""
    @ViewState private var keyAccount: Account?
    @ViewState private var replacement = ""
    @ViewState private var diagnosticsText: String?
    @ViewState private var collectingDiagnostics = false
    @ViewState private var diagnosticsCopied = false
    @ViewState private var section: DashboardSection = .history
    @ViewState private var dropdownPreviewExpandedID: UUID?
    @ViewState private var settingsSection: SettingsSection = .menuBar
    @ViewState private var historyHours = 24
    @ViewState private var historyAccountID: UUID?
    @AppStorage("hideFromDock") private var hideFromDock = true
    @ViewState private var handledAccountNavigationVersion: UInt64 = 0
    @ViewState private var handledSettingsNavigationVersion: UInt64 = 0

    var body: some View {
        VStack(spacing: 0) {
            dashboardNavigation
            Divider().opacity(0.35)
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    if let notice = store.notice {
                        HStack(alignment: .top, spacing: 8) {
                            Label(notice, systemImage: "info.circle")
                                .font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button { store.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 9)).frame(width: 20, height: 20) }
                                .buttonStyle(QuietButtonStyle()).accessibilityLabel("Dismiss message")
                        }.padding(.horizontal, 22).padding(.bottom, 10)
                    }
                    Divider().opacity(0.4)
                    GeometryReader { viewport in
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(alignment: .leading, spacing: 16) {
                                    if store.dashboardVisible { switch section {
                                    case .overview: overviewContent
                                    case .connection: connectionPage
                                    case .history: historyContent
                                    case .trends: HistoryTrendsView(store: store)
                                    case .accounts: accountsContent
                                    case .settings: selectedTabContent.frame(maxWidth: settingsSection == .dropdown ? 1000 : 640).frame(maxWidth: .infinity, alignment: .top)
                                    } }
                                }.frame(width: max(0, viewport.size.width - 24)).padding(12)
                            }
                            .onAppear { historyWidth = max(0, viewport.size.width - 24) }
                            .onChange(of: viewport.size.width) { _, width in historyWidth = max(0, width - 24) }
                            .onAppear {
                                if handledAccountNavigationVersion != store.accountNavigationVersion {
                                    handledAccountNavigationVersion = store.accountNavigationVersion
                                    section = .accounts
                                }
                                if store.accounts.isEmpty { section = .overview }
                                if store.settingsNavigationVersion != handledSettingsNavigationVersion {
                                    handledSettingsNavigationVersion = store.settingsNavigationVersion; section = .settings
                                }
                                if (CommandLine.arguments.contains("--history") || Bundle.main.object(forInfoDictionaryKey: "AILHistoryPreview") as? Bool == true) { section = .trends }
                                store.rediscoverTools(); scrollToSelected(proxy)
                            }
                            .onChange(of: store.accountNavigationVersion) { _, _ in
                                handledAccountNavigationVersion = store.accountNavigationVersion
                                if section != .connection { section = .accounts }
                                scrollToSelected(proxy)
                            }
                            .onChange(of: store.settingsNavigationVersion) { _, version in
                                handledSettingsNavigationVersion = version; section = .settings
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider().opacity(0.4)
            HStack {
                Label("Stored on this Mac", systemImage: "lock.shield").foregroundStyle(.secondary)
                Spacer()
                Button("Show menu", action: showMenu)
                Text((store.demo ? "Sample data · " : "") + AppUpdater.versionLabel).foregroundStyle(.tertiary)
                Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power").frame(width: 26, height: 26) }.buttonStyle(QuietButtonStyle()).help("Quit Ai-llowance")
            }.font(.system(size: 10)).padding(.horizontal, 14).padding(.vertical, 6)
        }.frame(minWidth: 760, minHeight: 480).controlSize(.regular).background { WorkspaceBackground(transparency: store.menuPreferences.dashboardTransparency) }.preferredColorScheme(store.menuPreferences.theme.colorScheme).environment(\.liquidGlass, store.menuPreferences.liquidGlass)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.001))
        .alert("Remove \(removing?.name ?? "account")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) { if let account = removing { Task { await store.remove(account) } }; removing = nil }
        } message: {
            Text("The connection and its app-owned key or OpenAI sign-in will be removed. Existing CLI sign-ins are kept. For Claude, use Sign out in Terminal first if you also want to clear that login.")
        }
        .sheet(item: $renaming) { account in
            AccountAppearanceEditor(account: account) { name, menu, dashboard, graph in
                if store.setAccountAppearance(account, name: name, menu: menu, dashboard: dashboard, graph: graph) { renaming = nil }
            } cancel: { renaming = nil }
        }
        .sheet(item: $keyAccount) { account in
            VStack(alignment: .leading, spacing: 16) {
                Text("Replace \(account.name) key").font(.headline)
                SecureField(keyLabel(account.kind), text: $replacement).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Cancel") { replacement = ""; keyAccount = nil }
                    Spacer()
                    Button("Save to Keychain") {
                        do { try store.replaceKey(account, secret: replacement); replacement = ""; keyAccount = nil }
                        catch { store.notice = store.safeMessage(error) }
                    }.disabled(replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.demo)
                }
            }.padding(24).frame(width: 420)
        }
        .sheet(isPresented: Binding(get: { diagnosticsText != nil }, set: { if !$0 { diagnosticsText = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Support diagnostics").font(.title2.weight(.semibold))
                Text("Review before copying. This report contains app and tool versions, connection states, and history counts. It excludes names, emails, keys, usage amounts and paths. Nothing is sent automatically.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    Text(diagnosticsText ?? "").font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.frame(height: 280).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button("Done") { diagnosticsText = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(diagnosticsCopied ? "Copied" : "Copy diagnostics") {
                        NSPasteboard.general.clearContents()
                        diagnosticsCopied = NSPasteboard.general.setString(diagnosticsText ?? "", forType: .string)
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 560)
        }
    }
    private var dashboardNavigation: some View {
        HStack(spacing: 6) {
            if historyWidth >= 860 {
                BrandIcon(size: 23)
                Text("Ai-llowance").font(.system(size: 12, weight: .semibold)).padding(.trailing, 6).fixedSize()
            }
            ForEach([DashboardSection.history, .trends, .overview, .settings]) { item in
                Button { section = item } label: {
                    Label(item == .history ? "Usage" : item == .trends ? "History" : item == .overview ? "Accounts" : "Settings",
                          systemImage: item == .history ? "chart.xyaxis.line" : item == .trends ? "clock.arrow.circlepath" : item == .overview ? "square.grid.2x2" : "gearshape")
                        .font(.system(size: 11, weight: .medium)).fixedSize()
                        .padding(.horizontal, 8).frame(height: 28)
                        .foregroundStyle(section == item || (item == .overview && (section == .accounts || section == .connection)) ? Color.primary : .secondary)
                        .background(section == item || (item == .overview && (section == .accounts || section == .connection)) ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 4)
            if section == .history {
                Picker("Account", selection: $historyAccountID) {
                    Text("All accounts").tag(nil as UUID?)
                    ForEach(store.accounts) { Text($0.pickerLabel).tag(Optional($0.id)) }
                }.labelsHidden().frame(width: 120)
                Button { section = .accounts } label: { Image(systemName: "slider.horizontal.3").frame(width: 26, height: 28) }
                    .buttonStyle(QuietButtonStyle()).help("Manage accounts").accessibilityLabel("Manage accounts")
                Menu {
                    Picker("Chart style", selection: Binding(get: { store.menuPreferences.dashboardChartStyle }, set: { store.setDashboardChartStyle($0) })) {
                        ForEach(DashboardChartStyle.allCases) { style in Label(style.title, systemImage: style.symbol).tag(style) }
                    }
                    Divider()
                    Toggle("Full 0–100% scale", isOn: Binding(get: { store.menuPreferences.dashboardChartFullScale }, set: { store.setDashboardChartFullScale($0) }))
                } label: { Image(systemName: store.menuPreferences.dashboardChartStyle.symbol).frame(width: 26, height: 28) }
                .menuStyle(.borderlessButton).fixedSize().help("Chart style · " + store.menuPreferences.dashboardChartStyle.title)
                .accessibilityLabel("Chart style")
                Picker("Time range", selection: $historyHours) {
                    Text("24 hours").tag(24); Text("7 days").tag(168)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 146)
            }
            Button { store.rediscoverTools(); store.refresh(force: true) } label: {
                Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
            }.buttonStyle(QuietButtonStyle()).help("Refresh · " + store.refreshSummary)
                .accessibilityLabel("Refresh accounts").disabled(store.demo || store.paused || store.refreshing)
        }.padding(.horizontal, 12).padding(.vertical, 8)
    }
    private func scrollToSelected(_ proxy: ScrollViewProxy) {
        guard section == .accounts, let id = store.selectedAccountID else { return }
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
    }
    private var chartSettings: some View {
        GroupBox("Dashboard charts") {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 8) {
                    ForEach(DashboardChartStyle.allCases) { style in
                        Button { store.setDashboardChartStyle(style) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: style.symbol).font(.system(size: 17)).frame(width: 24)
                                Text(style.title)
                                Spacer(minLength: 0)
                                if store.menuPreferences.dashboardChartStyle == style { Image(systemName: "checkmark.circle.fill") }
                            }.font(.system(size: 12, weight: .medium)).padding(10)
                                .foregroundStyle(store.menuPreferences.dashboardChartStyle == style ? Color.accentColor : Color.primary)
                                .background(Color.primary.opacity(store.menuPreferences.dashboardChartStyle == style ? 0.09 : 0.035), in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }
                Toggle("Use full 0–100% scale", isOn: Binding(get: { store.menuPreferences.dashboardChartFullScale }, set: { store.setDashboardChartFullScale($0) }))
                    .toggleStyle(SettingsSwitchStyle())
                Text("Overview combines account trends, usage share and daily bars. Line, area, bars and dots show history. Ring, pie and gauge show current allowance; API accounts keep a history chart. Your choice is saved for all dashboard cards.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(10)
        }
    }
    private var selectedTabContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings").font(.system(size: 20, weight: .semibold))
            Picker("Settings section", selection: $settingsSection) {
                ForEach(SettingsSection.allCases) { section in Text(section.rawValue).tag(section) }
            }.pickerStyle(.segmented).labelsHidden().controlSize(.large)
            switch settingsSection {
            case .general:
                appearanceSettings
                chartSettings
                behaviorSettings
            case .menuBar:
                menuBarSettings
            case .dropdown:
                dropdownSettings
            case .updates:
                UpdateSettings(updater: store.updater)
            case .advanced:
                moreConnections
            }
        }
    }
    @ViewBuilder private var accountsContent: some View {
            HStack {
                Button { section = .overview } label: { Label("Back to Accounts", systemImage: "chevron.left") }.buttonStyle(QuietButtonStyle())
                Spacer()
            }
            if store.accounts.isEmpty { connectionSetup }
            ForEach(MenuProvider.allCases, id: \.self) { provider in
                if store.accounts.contains(where: { $0.kind.provider == provider }) { accountSection(provider) }
            }
            if !store.accounts.isEmpty {
                simpleConnectOptions
            }
    }
    private var serviceKinds: [ConnectionKind] { [.claudeCode, .codex, .copilot, .openAIAPI, .claudeAPI, .openRouter, .vercelGateway, .xai, .grokSubscription] }
    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your accounts").font(.system(size: 20, weight: .semibold))
                    Text("Connect multiple accounts from each service.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                agentHelpMenu.fixedSize()
            }
            if !store.accounts.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(serviceKinds.filter { kind in store.accounts.contains { $0.kind == kind } }, id: \.self) { kind in
                        connectionTile(kind)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Add a service").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                    ForEach(serviceKinds.filter { kind in !store.accounts.contains { $0.kind == kind } }, id: \.self) { kind in
                        Button { connectService(kind) } label: {
                            HStack(spacing: 10) {
                                ProviderMark(provider: kind.provider, size: 23).foregroundStyle(providerAccent(kind.provider))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(serviceTitle(kind)).font(.system(size: 12, weight: .semibold))
                                    Text(kind.isBalance ? "Credits & balance" : kind.isAPI ? "API spending" : "Subscription allowance").font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "plus.circle").foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, minHeight: 42, alignment: .leading).padding(12)
                                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
                        }.buttonStyle(.plain).disabled(busyConnecting || store.demo).help("Connect " + serviceTitle(kind))
                    }
                }
            }
            setupProgress
        }
    }
    private func serviceTitle(_ kind: ConnectionKind) -> String {
        switch kind {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .copilot: "GitHub Copilot"
        case .openAIAPI: "OpenAI API"
        case .claudeAPI: "Claude API"
        case .openRouter: "OpenRouter"
        case .vercelGateway: "Vercel AI Gateway"
        case .xai: "xAI"
        case .grokSubscription: "Grok & Grok Bot"
        }
    }
    private func connectionTile(_ kind: ConnectionKind) -> some View {
        let accounts = store.accounts.filter { $0.kind == kind }
        let recommended = (kind == .claudeCode || kind == .codex) ? store.recommendedAccount(for: kind) : nil
        let title: String = switch kind {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .copilot: "GitHub Copilot"
        case .openAIAPI: "OpenAI API"
        case .claudeAPI: "Claude API"
        case .openRouter: "OpenRouter"
        case .vercelGateway: "Vercel AI Gateway"
        case .xai: "xAI"
        case .grokSubscription: "Grok & Grok Bot"
        }
        let detail = kind.isBalance ? "Credits & balance" : kind.isAPI ? "API spending" : "Subscription allowance"
        return SettingsCard(inset: 12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    ProviderMark(provider: kind.provider, size: 24)
                        .foregroundStyle(providerAccent(kind.provider))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                if accounts.isEmpty {
                    Text("No accounts yet").font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    ForEach(accounts) { account in
                        Button { store.selectedAccountID = account.id; section = .accounts } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "person.crop.circle")
                                Text(account.expectedIdentity ?? store.snapshots[account.id]?.identity ?? account.name)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 0)
                                let connection = store.connectionState(account)
                                Image(systemName: connection.symbol)
                                    .foregroundStyle(connection.needsAction ? Color.orange : Color.secondary)
                                    .accessibilityLabel(connection.title)
                                Image(systemName: "chevron.right").font(.system(size: 8))
                            }.font(.system(size: 11)).padding(.vertical, 3).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(account.expectedIdentity ?? account.name)
                    }
                }
                Spacer(minLength: 0)
                HStack {
                    if let recommended {
                        Button(kind == .claudeCode ? "Open Claude Code" : "Open Codex") { store.useAccount(recommended) }.controlSize(.small).disabled(store.demo)
                    }
                    Spacer(minLength: 0)
                    if kind == .copilot && !accounts.isEmpty {
                        Text("Uses the current CLI account").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        Button(accounts.isEmpty ? "Connect" : "Add another account") { connectService(kind) }
                            .controlSize(.small).disabled(busyConnecting || store.demo)
                    }
                }

            }.frame(height: CGFloat(max(120, 64 + 32 * (serviceKinds.map { kind in store.accounts.filter { $0.kind == kind }.count }.max() ?? 0))), alignment: .topLeading)
        }
    }
    private func connectService(_ kind: ConnectionKind) {
        selectedKind = kind
        secret = ""; scopeID = ""; name = ""; connectionError = nil
        manualConnection = false
        setupStarted = false
        setupExistingIDs = Set(store.accounts.map(\.id))
        section = .connection
        store.rediscoverTools()
    }
    private var connectionPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            Button { secret = ""; section = .overview } label: {
                Label("Back to Accounts", systemImage: "chevron.left")
            }.buttonStyle(.plain).foregroundStyle(.secondary)
            VStack(spacing: 16) {
                ProviderMark(provider: selectedKind.provider, size: 36)
                    .foregroundStyle(providerAccent(selectedKind.provider))
                Text("Connect \(selectedKind == .codex ? "Codex" : selectedKind == .claudeCode ? "Claude Code" : selectedKind.provider.title)")
                    .font(.system(size: 22, weight: .semibold))
                Text(selectedKind == .xai ? "Track your prepaid API credits." : selectedKind.isAPI ? "Track your API usage and balance." : "Use your existing subscription sign-in.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button {
                    if selectedKind == .claudeCode || selectedKind == .codex {
                        guard executable(for: selectedKind) != nil else { NSWorkspace.shared.open(installationURL(selectedKind)); return }
                        let existing = store.accounts.contains { $0.kind == selectedKind && (selectedKind == .claudeCode ? $0.usesExistingClaude == true : $0.usesExistingCodex) }
                        setupExistingIDs = Set(store.accounts.map(\.id)); setupStarted = true
                        if selectedKind == .claudeCode { store.connectClaude(existing: !existing) }
                        else { store.connectOpenAI(existing: !existing) }
                    } else if selectedKind == .grokSubscription {
                        guard executable(for: .grokSubscription) != nil else { NSWorkspace.shared.open(installationURL(.grokSubscription)); return }
                        setupExistingIDs = []; setupStarted = true
                        store.connectGrok()
                    } else if selectedKind == .copilot {
                        guard executable(for: .copilot) != nil else { NSWorkspace.shared.open(installationURL(.copilot)); return }
                        setupExistingIDs = []; setupStarted = true
                        store.connectCopilot()
                    }
                    else {
                        NSWorkspace.shared.open(selectedKind == .xai ? URL(string: "https://console.x.ai")! : selectedKind.documentation)
                        manualConnection = true
                    }
                } label: {
                    Label(selectedKind.isAPI ? "Open \(selectedKind.provider.title) setup" : "Connect account", systemImage: "arrow.up.right.square")
                        .font(.system(size: 14, weight: .semibold)).frame(minWidth: 230).padding(.vertical, 7)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(busyConnecting || store.demo)
                if selectedKind.isAPI {
                    Text("This provider requires an API key. After signing in, return here to finish setup.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }.frame(maxWidth: .infinity).padding(.vertical, 12)
            setupProgress
            if selectedKind == .claudeCode || selectedKind == .codex {
                Text("Adding another account? Use a separate browser profile or private window and check the email before signing in.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            DisclosureGroup("Manual setup & advanced options", isExpanded: $manualConnection) {
                connectionForm.padding(.top, 12)
            }.font(.system(size: 12)).padding(16)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        }.frame(maxWidth: 520).frame(maxWidth: .infinity).padding(.top, 8)
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var historyWidth: CGFloat = 800
    private func dashboardCard(_ account: Account) -> some View {
        let earlier: (() -> Void)? = store.orderedDashboardAccounts.first?.id == account.id ? nil : { store.moveDashboardAccount(account.id, offset: -1) }
        let later: (() -> Void)? = store.orderedDashboardAccounts.last?.id == account.id ? nil : { store.moveDashboardAccount(account.id, offset: 1) }
                        let points = store.history(for: account).filter { $0.timestamp >= store.now.addingTimeInterval(-Double(historyHours) * 3600) && $0.timestamp <= store.now }
                        return HistoryCard(account: account, points: points, snapshot: store.snapshots[account.id],
                                    error: store.errors[account.id] != nil, cached: store.isCached(account), needsReconnect: store.needsSignIn(account), connection: store.connectionState(account), now: store.now, historyHours: historyHours, chartStyle: store.menuPreferences.dashboardChartStyle, fullScale: store.menuPreferences.dashboardChartFullScale,
                                    overviewTint: store.menuPreferences.dashboardChartStyle == .mixed ? overviewAccountTint(account, accounts: store.accounts) : nil,
                                    actionTitle: store.recoveryAction(account) == .wait ? "Connection details" : store.recoveryAction(account).title,
                                    openUsage: {
                                        switch store.recoveryAction(account) {
                                        case .retry: store.retryConnection(account)
                                        case .resume: store.toggle(account)
                                        case .openUsage: store.openUsage(account)
                                        default: store.selectedAccountID = account.id; section = .accounts
                                        }
                                    }, manage: { renaming = account },
                                    moveEarlier: earlier,
                                    moveLater: later,
                                    resetOrder: { store.resetDashboardAccountOrder() })
                            .frame(width: accountGrid.cardWidth)
    }
    private var visibleHistoryAccounts: [Account] { store.orderedDashboardAccounts.filter { historyAccountID == nil || $0.id == historyAccountID } }
    private var accountGrid: AccountGridLayout { AccountGridLayout(count: visibleHistoryAccounts.count, width: historyWidth) }
    private var historyRows: [[Account]] {
        var offset = 0
        return accountGrid.rowCounts.map { count in
            defer { offset += count }
            return Array(visibleHistoryAccounts[offset..<(offset + count)])
        }
    }
    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.accounts.isEmpty { Text("Connect an account to start collecting history.").foregroundStyle(.secondary) }
            ForEach(historyRows, id: \.first?.id) { row in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(row) { account in
                        dashboardCard(account)
                    }
                }.frame(maxWidth: .infinity, alignment: .center)
            }
            if visibleHistoryAccounts.contains(where: { !$0.kind.isAPI }) {
            let histories = Dictionary(uniqueKeysWithValues: visibleHistoryAccounts.map { ($0.id, store.history(for: $0).filter { $0.timestamp >= store.now.addingTimeInterval(-7 * 86400) }) })
            if store.menuPreferences.dashboardChartStyle == .mixed {
                if historyWidth >= 850 {
                    HStack(alignment: .top, spacing: 12) {
                        UsageOverviewCharts(accounts: visibleHistoryAccounts, colorAccounts: store.accounts, histories: histories, now: store.now).frame(width: max(290, historyWidth * 0.34))
                        ActivityHeatmap(accounts: visibleHistoryAccounts, histories: histories, now: store.now)
                    }
                } else {
                    UsageOverviewCharts(accounts: visibleHistoryAccounts, colorAccounts: store.accounts, histories: histories, now: store.now)
                    ActivityHeatmap(accounts: visibleHistoryAccounts, histories: histories, now: store.now)
                }
            } else {
                ActivityHeatmap(accounts: visibleHistoryAccounts, histories: histories, now: store.now)
            }
            }
        }.animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: historyAccountID)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: visibleHistoryAccounts.map(\.id))
        .onChange(of: store.accounts.map(\.id)) { _, ids in
            if let selected = historyAccountID, !ids.contains(selected) { historyAccountID = nil }
        }
    }
    private var busyConnecting: Bool { store.connectingClaude || store.signingIn != nil || !store.waitingForClaude.isEmpty }
    private var setupAccount: Account? { store.accounts.last { $0.kind == selectedKind && !setupExistingIDs.contains($0.id) } }
    private var connectionSetup: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Connect your first account", systemImage: "person.crop.circle.badge.plus").font(.system(size: 14, weight: .semibold))
                Text("Choose the coding assistant you already use. We’ll check its local sign-in and show your usage.").font(.system(size: 11)).foregroundStyle(.secondary)
                simpleProviderButton(.claudeCode)
                simpleProviderButton(.codex)
                setupProgress
                agentHelpMenu
                Button("Other providers, API keys, or CLI setup…") { section = .overview }
                    .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.accentColor)
            }
        }
    }
    private var simpleConnectOptions: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Add an account", systemImage: "plus.circle.fill").font(.system(size: 13, weight: .semibold))
                simpleProviderButton(.claudeCode)
                simpleProviderButton(.codex)
                setupProgress
                agentHelpMenu
                Button("More providers and API keys…") { section = .overview }
                    .buttonStyle(.plain).font(.system(size: 10, weight: .medium)).foregroundStyle(Color.accentColor)
            }
        }
    }
    @ViewBuilder private var setupProgress: some View {
        if setupStarted, let account = setupAccount {
            let snapshot = store.snapshots[account.id]
            let verified = account.expectedIdentity != nil && snapshot?.identity == account.expectedIdentity && snapshot != nil && !store.isCached(account) && store.errors[account.id] == nil && snapshot?.providerRestricted != true && !(snapshot?.isStale(at: store.now) ?? true)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Find assistant", systemImage: executable(for: account.kind) != nil ? "checkmark.circle.fill" : "circle")
                    Image(systemName: "chevron.right")
                    Label("Sign in", systemImage: !store.needsSignIn(account) && snapshot != nil ? "checkmark.circle.fill" : "circle")
                    Image(systemName: "chevron.right")
                    Label("Verify", systemImage: verified ? "checkmark.circle.fill" : "circle")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                if verified {
                    Label("Verified · \(account.expectedIdentity ?? account.name)", systemImage: "checkmark.shield.fill").font(.system(size: 11)).foregroundStyle(.green)
                } else {
                    Text(store.errors[account.id] ?? "Finish sign-in, then we’ll verify your account and first reading.").font(.system(size: 11)).foregroundStyle(.secondary)
                    accountActions(account)
                }
            }
        }
    }
    private var agentHelpMenu: some View {
        Menu {
            Button("Copy prompt & open Claude Code") { store.openAgentHelp(for: .claudeCode) }
            Button("Copy prompt & open Codex") { store.openAgentHelp(for: .codex) }
        } label: {
            Label("Get setup help from Claude or Codex", systemImage: "sparkles")
                .font(.system(size: 10, weight: .medium))
        }.menuStyle(.borderlessButton).foregroundStyle(Color.accentColor)
    }
    @ViewBuilder private func simpleProviderButton(_ kind: ConnectionKind) -> some View {
        let installed = executable(for: kind) != nil
        let existing = store.accounts.contains { $0.kind == kind && (kind == .claudeCode ? $0.usesExistingClaude == true : $0.usesExistingCodex) }
        Button {
            connectService(kind)
        } label: {
            HStack(spacing: 10) {
                ProviderMark(provider: kind.provider, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(installed ? (existing ? "Add another \(kind.provider.title) account" : "Connect \(kind.provider.title)") : "Install \(cliName(kind))")
                        .font(.system(size: 12, weight: .semibold))
                    Text(installed ? (kind == .claudeCode ? "Sign in once per email · independent of Claude Desktop" : "Use your existing subscription sign-in · no API key") : "One-time setup · then return here")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: installed ? "arrow.right.circle.fill" : "arrow.up.right.square")
                    .foregroundStyle(Color.accentColor)
            }
            .padding(11).contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .modifier(InsetSurface(tint: kind.provider == .claude ? .orange : .green, cornerRadius: 10))
        }
        .buttonStyle(.plain).disabled(installed && busyConnecting)
    }
    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            if section != .connection { HStack {
                ProviderMark(provider: selectedKind.provider, size: 19)
                Picker("Service", selection: $selectedKind) {
                    ForEach(ConnectionKind.allCases) { kind in Text(kind.title).tag(kind) }
                }.labelsHidden()
            }
            .disabled(busyConnecting)
            .onChange(of: selectedKind) { _, _ in secret = ""; scopeID = ""; name = ""; connectionError = nil; store.rediscoverTools() } }
            if selectedKind.isAPI { apiConnectionForm }
            else { cliConnectionForm }
            if let account = setupAccount, busyConnecting || store.needsSignIn(account) || store.errors[account.id] != nil {
                accountActions(account)
                if let error = store.errors[account.id] { Text(error).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            } else if let account = setupAccount, store.snapshots[account.id] == nil, store.refreshing {
                Label("Reading your allowance…", systemImage: "arrow.clockwise").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let connectionError { Text(connectionError).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            if let account = setupAccount, store.errors[account.id] == nil, !store.isCached(account), let snapshot = store.snapshots[account.id], !snapshot.isStale(at: store.now), snapshot.providerRestricted != true {
                HStack {
                    Label("First reading received · \(account.expectedIdentity ?? snapshot.identity ?? account.name)", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(.green).lineLimit(2)
                    Spacer()
                    Button("View account") { store.selectedAccountID = account.id; section = .accounts }.controlSize(.small)
                }
            }
        }.disabled(store.demo)
    }
    private func startManualConnection(existing: Bool) {
        setupExistingIDs = Set(store.accounts.map(\.id))
        setupStarted = true
        switch selectedKind {
        case .claudeCode: store.connectClaude(existing: existing)
        case .codex: store.connectOpenAI(existing: existing)
        case .grokSubscription: store.connectGrok()
        case .copilot: store.connectCopilot()
        default: break
        }
    }
    private var cliConnectionForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            let installed = executable(for: selectedKind) != nil
            HStack {
                Label(installed ? "\(cliName(selectedKind)) found" : "Install \(cliName(selectedKind)) first", systemImage: installed ? "checkmark.circle" : "arrow.down.circle")
                    .font(.system(size: 11)).foregroundStyle(installed ? Color.secondary : Color.primary)
                Spacer()
                Button("Check again") { store.rediscoverTools() }.controlSize(.small)
                Button("Choose…") { chooseExecutable(selectedKind) }.controlSize(.small)
            }
            if !installed {
                HStack {
                    Link("Installation guide ↗", destination: installationURL(selectedKind))
                    Text("Then return here. We’ll detect it.").foregroundStyle(.secondary)
                }.font(.system(size: 11))
            } else {
                if selectedKind == .claudeCode {
                    HStack {
                        Button("Connect a Claude account") { startManualConnection(existing: false) }
                        Text("Separate sign-in for each email. Desktop account switching stays independent.")
                            .foregroundStyle(.secondary)
                    }.controlSize(.small).disabled(busyConnecting)
                } else if selectedKind == .codex {
                    HStack {
                        Button("Use existing Codex sign-in") { startManualConnection(existing: true) }.disabled(store.accounts.contains { $0.usesExistingCodex })
                        Button("Add another account") { startManualConnection(existing: false) }
                    }.controlSize(.small).disabled(busyConnecting)
                } else if selectedKind == .grokSubscription {
                    HStack {
                        Button("Connect Grok shared allowance") { startManualConnection(existing: true) }.disabled(busyConnecting)
                        Button("Sign in to Grok…") { store.openGrokSignIn() }
                    }.controlSize(.small)
                    Text(selectedKind.explanation).font(.system(size: 10)).foregroundStyle(.secondary)
                } else if selectedKind == .copilot {
                    HStack {
                        Button("Connect Copilot (preview)") { startManualConnection(existing: true) }.disabled(busyConnecting || store.accounts.contains { $0.kind == .copilot })
                        Button("Sign in to Copilot…") { store.openCopilotSignIn() }
                    }.controlSize(.small)
                    Text("Uses your Copilot CLI sign-in. Quota support depends on your installed CLI.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if selectedKind == .claudeCode || selectedKind == .codex {
                Text(store.accounts.contains { $0.kind == selectedKind } ? "Another account? Use its own browser profile or private window. Check the email before continuing." : "Your existing CLI sign-in stays yours. No API key needed for a subscription.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if busyConnecting { Label("Finish sign-in; your first reading will appear automatically.", systemImage: "arrow.up.right.square").font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }
    private var apiConnectionForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            if selectedKind == .xai {
                Text("In xAI Settings → Management Keys, create a key with permission to read billing credits.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            TextField("Account label (optional)", text: $name).textFieldStyle(.roundedBorder)
            SecureField(keyLabel(selectedKind), text: $secret).textFieldStyle(.roundedBorder)
            if selectedKind == .xai {
                HStack {
                    TextField("xAI team ID", text: $scopeID).textFieldStyle(.roundedBorder)
                    Link("Find team ID ↗", destination: URL(string: "https://console.x.ai/team/default/settings/team")!).font(.system(size: 11))
                }
                Text("Use an xAI Management API key for API credits. To connect a Grok shared subscription, choose Grok in Accounts.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if selectedKind != .xai {
                Text(selectedKind.explanation).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Connect securely") {
                    do {
                        setupExistingIDs = Set(store.accounts.map(\.id))
                        let account = try store.add(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? suggestedAccountName : name, kind: selectedKind, secret: secret, existing: false,
                            scopeID: scopeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : scopeID.trimmingCharacters(in: .whitespacesAndNewlines))
                        store.selectedAccountID = account.id
                        secret = ""; scopeID = ""; name = ""; connectionError = nil
                    } catch { connectionError = store.safeMessage(error) }
                }.disabled(secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (selectedKind == .xai && scopeID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                Link("Key & access guide ↗", destination: selectedKind.documentation)
                Spacer()
                Label("Saved in Keychain", systemImage: "lock").foregroundStyle(.secondary)
            }.font(.system(size: 11)).controlSize(.small)
        }
    }
    private func executable(for kind: ConnectionKind) -> URL? {
        switch kind { case .claudeCode: store.claudeExecutable; case .codex: store.executable; case .grokSubscription: store.grokExecutable; case .copilot: store.copilotExecutable; default: nil }
    }
    private func chooseExecutable(_ kind: ConnectionKind) {
        switch kind { case .claudeCode: store.chooseClaudeExecutable(); case .codex: store.chooseExecutable(); case .grokSubscription: store.chooseGrokExecutable(); case .copilot: store.chooseCopilotExecutable(); default: break }
    }
    private func cliName(_ kind: ConnectionKind) -> String { kind == .grokSubscription ? "Grok CLI" : kind == .claudeCode ? "Claude Code" : kind == .copilot ? "Copilot CLI" : "Codex CLI" }
    private func installationURL(_ kind: ConnectionKind) -> URL {
        switch kind {
        case .claudeCode: URL(string: "https://code.claude.com/docs/en/setup")!
        case .grokSubscription: URL(string: "https://github.com/xai-org/grok-build")!
        case .copilot: URL(string: "https://docs.github.com/en/copilot/how-tos/copilot-cli/install-copilot-cli")!
        default: URL(string: "https://developers.openai.com/codex/cli")!
        }
    }
    private var suggestedAccountName: String {
        switch selectedKind {
        case .openAIAPI: "OpenAI API"
        case .claudeAPI: "Claude API"
        default: selectedKind.provider.title
        }
    }
    private func keyLabel(_ kind: ConnectionKind) -> String {
        switch kind {
        case .openAIAPI, .claudeAPI: "Organization admin API key"
        case .openRouter: "OpenRouter API key"
        case .vercelGateway: "AI Gateway API key"
        case .xai: "xAI management API key"
        default: "API key"
        }
    }
    private func accountSection(_ provider: MenuProvider) -> some View {
        let accounts = store.accounts.filter { $0.kind.provider == provider }
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(provider.title).font(.system(size: 13, weight: .semibold))
                Text("\(accounts.count)").font(.system(size: 9, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 18, minHeight: 16).background(Color.primary.opacity(0.045), in: Capsule())
                Spacer()
            }
            ForEach(accounts) { account in
                SettingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        AccountReading(account: account, snapshot: store.snapshots[account.id], error: store.errors[account.id], now: store.now, cached: store.isCached(account), connection: store.connectionState(account))
                        if store.needsSignIn(account), account.kind == .claudeCode {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(account.usesExistingClaude == true ? "One-time reconnect required" : "Reconnect to resume readings", systemImage: "person.crop.circle.badge.exclamationmark")
                                    .font(.headline)
                                Text(account.usesExistingClaude == true
                                     ? "This update separates your Claude accounts. Reconnect with \(account.expectedIdentity ?? "this account’s email") once so switching in Claude Desktop cannot change whose usage appears here."
                                     : "Sign in with \(account.expectedIdentity ?? "this account’s email") to resume automatic background readings. Verified history is kept while you reconnect.")
                                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                Text("You can close Claude Desktop and Terminal after sign-in. No need to add the account again.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                        }
                        if (account.kind == .claudeCode || account.kind == .codex) && (store.needsSignIn(account) || account.expectedIdentity == nil) {
                            Button { store.openAgentHelp(for: account.kind, account: account) } label: {
                                Label("Copy setup prompt & open \(account.kind == .claudeCode ? "Claude" : "Codex")", systemImage: "sparkles")
                                    .font(.system(size: 10, weight: .medium))
                            }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                                .help("Copies a safe setup prompt and opens this account’s CLI. Paste the prompt there.")
                        }
                        accountActions(account)
                        DisclosureGroup("Details & link preferences") {
                            VStack(alignment: .leading, spacing: 10) {
                                HistorySparkline(points: store.history(for: account), kind: account.kind)
                                if let snapshot = store.snapshots[account.id] { Text("\(snapshot.source) · updated \(snapshot.observedAt.formatted(.dateTime.hour().minute()))").font(.system(size: 10)).foregroundStyle(.secondary) }
                                if !store.browserProfiles.isEmpty {
                                    Picker("Open links with", selection: Binding(get: { store.browserProfileID(account) ?? "" }, set: { store.setBrowserProfile(account, id: $0.isEmpty ? nil : $0) })) {
                                        Text("System default browser").tag("")
                                        ForEach(store.browserProfiles, id: \.id) { profile in Text(profile.name).tag(profile.id) }
                                    }.font(.system(size: 11))
                                }
                                Text("Choose the browser profile signed into this account. Default-browser links use its current sign-in.").font(.system(size: 10)).foregroundStyle(.secondary)
                            }.padding(.top, 8)
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.id(account.id)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(store.selectedAccountID == account.id ? Color.accentColor.opacity(0.55) : .clear, lineWidth: 1.5))
            }
        }
    }
    @ViewBuilder
    private func accountActions(_ account: Account) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.waitingForClaude[account.id] != nil {
                HStack {
                    Label("Finish sign-in in your browser", systemImage: "arrow.up.right.square").foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop waiting") { store.cancelClaudeSignIn(account) }.help("Close the sign-in Terminal window before retrying.")
                }
            } else if store.signingIn == account.id {
                HStack {
                    Text("Open the link in this account’s browser profile.").foregroundStyle(.secondary)
                    Spacer()
                    if store.codexSignInURL != nil { Button("Copy sign-in link") { store.copyCodexSignInLink() } }
                    Button("Cancel") { store.cancelSignIn() }
                }
            }
            HStack(spacing: 12) {
                switch store.recoveryAction(account) {
                case .finishSignIn: EmptyView()
                case .resume: Button("Resume account") { store.toggle(account) }
                case .replaceKey: Button("Update API key") { replacement = ""; keyAccount = account }
                case .reconnect:
                    Button("Reconnect account") {
                        if account.kind == .claudeCode { store.openClaude(account, login: true) }
                        else { store.signIn(account, openBrowser: false) }
                    }.disabled(busyConnecting)
                case .checkSignIn:
                    if account.kind == .grokSubscription {
                        Button("Sign in to Grok…") { store.openGrokSignIn() }
                    } else if account.kind == .copilot {
                        Button("Sign in to Copilot…") { store.openCopilotSignIn() }
                    }
                    Button("Check sign-in") { store.retryConnection(account) }
                        .help("Finish signing in through this provider’s CLI, then check again.")
                case .retry: Button("Retry connection") { store.retryConnection(account) }
                case .wait:
                    if store.paused { Button("Resume refresh") { store.togglePause() } }
                    else { Label(store.connectionState(account).title, systemImage: store.connectionState(account).symbol).foregroundStyle(.secondary) }
                case .openUsage: Button("Open usage ↗") { store.openUsage(account) }
                }
                Spacer()
                Menu {
                    if account.kind == .claudeCode {
                        Button("Open Claude Code") { store.openClaude(account) }
                        Button("Open in a project…") { store.openClaude(account, chooseProject: true) }
                        Button("Sign in again") { store.openClaude(account, login: true) }
                        Button("Sign out in Terminal") { store.openClaude(account, logout: true) }
                        Divider()
                    } else if account.kind == .codex && !account.usesExistingCodex {
                        Button("Sign in again") { store.signIn(account, openBrowser: false) }.disabled(busyConnecting)
                        Divider()
                    } else if account.kind.isAPI {
                        Button("Replace key") { replacement = ""; keyAccount = account }
                        Divider()
                    }
                    Button("Name & color…") { newName = account.name; renaming = account }
                    Button(account.enabled ? "Pause account" : "Resume account") { store.toggle(account) }
                    Button("Remove account", role: .destructive) { removing = account }.disabled(store.refreshing || store.removing || busyConnecting)
                } label: { Image(systemName: "ellipsis").frame(width: 32, height: 32) }
                    .menuStyle(.borderlessButton).frame(width: 36).help("\(account.name) options").accessibilityLabel("\(account.name) options")
            }
        }.font(.system(size: 13)).controlSize(.large).disabled(store.demo)
    }
    private var behaviorSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("General") {
                VStack(spacing: 12) {
                    Toggle("Launch at login", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
                    Divider()
                    Toggle("Hide from Dock", isOn: $hideFromDock)
                        .onChange(of: hideFromDock) { _, hidden in
                            NSApplication.shared.setActivationPolicy(hidden ? .accessory : .regular)
                            NSApplication.shared.activate(ignoringOtherApps: true)
                        }
                    if store.loginItemNeedsApproval {
                        Link("Open Login Items Settings…", destination: URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                    }
                    Divider()
                    Toggle("Refresh automatically", isOn: Binding(get: { !store.paused }, set: { if $0 == store.paused { store.togglePause() } }))
                    Divider()
                    HStack {
                        Text("Refresh interval")
                        Spacer()
                        Picker("Refresh interval", selection: Binding(get: { store.refreshMinutes }, set: { store.setRefreshMinutes($0) })) {
                            Text("Automatic").tag(0)
                            Text("Every 5 minutes").tag(5)
                            Text("Every 15 minutes").tag(15)
                            Text("Every 30 minutes").tag(30)
                        }.labelsHidden().frame(width: 190).disabled(store.paused)
                    }
                    Text("Provider limits and power-saving mode may delay refreshes.").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    Toggle("Allowance notifications", isOn: Binding(get: { store.notificationsEnabled }, set: { store.setNotificationsEnabled($0) }))
                    Divider()
                    Toggle("Remind me before weekly resets", isOn: Binding(get: { store.menuPreferences.resetRemindersEnabled }, set: { store.setResetRemindersEnabled($0) }))
                        .disabled(!store.notificationsEnabled)
                    resetReminderControls(second: false)
                    Toggle("Add a second reminder", isOn: Binding(get: { store.menuPreferences.secondResetReminderEnabled }, set: { store.setSecondResetReminderEnabled($0) }))
                        .disabled(!store.notificationsEnabled || !store.menuPreferences.resetRemindersEnabled)
                    if store.menuPreferences.secondResetReminderEnabled { resetReminderControls(second: true) }
                    Text("Each reminder can alert once per account and weekly reset, using fresh readings while Ai-llowance is running. Percentages mean at least that much remains.")
                        .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(10)
            }
        }.font(.system(size: 13)).toggleStyle(SettingsSwitchStyle()).controlSize(.regular).disabled(store.demo)
    }
    private func resetReminderControls(second: Bool) -> some View {
        let percent = second ? store.menuPreferences.secondResetReminderMinimumPercent : store.menuPreferences.resetReminderMinimumPercent
        let hours = second ? store.menuPreferences.secondResetReminderLeadHours : store.menuPreferences.resetReminderLeadHours
        let time = hours < 24 ? "\(hours)h" : "\(hours / 24)d" + (hours % 24 == 0 ? "" : " \(hours % 24)h")
        return VStack(alignment: .leading, spacing: 8) {
            Text(second ? "Reminder 2" : "Reminder 1").font(.system(size: 12, weight: .semibold))
            HStack { Text("At least this much remaining"); Spacer(); Text("\(percent)%").monospacedDigit() }
            Slider(value: Binding(get: { Double(percent) }, set: { value in
                if second { store.setSecondResetReminderMinimumPercent(Int(value.rounded())) }
                else { store.setResetReminderMinimumPercent(Int(value.rounded())) }
            }), in: 0...100, step: 1).accessibilityLabel(second ? "Reminder 2 remaining percentage" : "Reminder 1 remaining percentage")
            HStack { Text("Before the weekly reset"); Spacer(); Text(time).monospacedDigit() }
            Slider(value: Binding(get: { Double(hours) }, set: { value in
                if second { store.setSecondResetReminderLeadHours(Int(value.rounded())) }
                else { store.setResetReminderLeadHours(Int(value.rounded())) }
            }), in: 1...168, step: 1).accessibilityLabel(second ? "Reminder 2 lead time in hours" : "Reminder 1 lead time in hours")
        }.padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            .disabled(!store.notificationsEnabled || !store.menuPreferences.resetRemindersEnabled)
    }
    private var moreConnections: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Support") {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connection diagnostics")
                        Text("A private, reviewable report for troubleshooting. No credentials or personal identifiers.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if collectingDiagnostics { ProgressView().controlSize(.small) }
                    Button("Review diagnostics…") {
                        collectingDiagnostics = true; diagnosticsCopied = false
                        Task { @MainActor in
                            defer { collectingDiagnostics = false }
                            do { diagnosticsText = try await store.diagnosticReport() }
                            catch { store.notice = "Could not prepare diagnostics. Your account data has not changed." }
                        }
                    }.disabled(collectingDiagnostics)
                }.padding(10)
            }
            GroupBox("Installed tools") {
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Find installed tools")
                            Text("Check this Mac for supported command-line apps.").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Scan Again") { store.rediscoverTools() }
                    }
                    Divider()
                    HStack { Text("Codex location"); Spacer(); Button("Choose…") { store.chooseExecutable() }.accessibilityLabel("Choose Codex location") }
                    Divider()
                    HStack { Text("Claude location"); Spacer(); Button("Choose…") { store.chooseClaudeExecutable() }.accessibilityLabel("Choose Claude location") }
                    Divider()
                    HStack { Text("Copilot location"); Spacer(); Button("Choose…") { store.chooseCopilotExecutable() }.accessibilityLabel("Choose Copilot location") }
                    Divider()
                    HStack { Text("Grok location"); Spacer(); Button("Choose…") { store.chooseGrokExecutable() }.accessibilityLabel("Choose Grok location") }
                }.padding(10)
            }.disabled(store.demo)
            GroupBox("Provider dashboards") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("Cursor"); Spacer(); Link("Open Dashboard ↗", destination: URL(string: "https://www.cursor.com/dashboard")!) }
                    Divider()
                    HStack { Text("Gemini"); Spacer(); Link("Open Dashboard ↗", destination: URL(string: "https://aistudio.google.com/usage")!) }
                    Text("These services open in your browser. Automatic tracking is not connected.")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(10)
            }
            Label("No Ai-llowance analytics or backend.", systemImage: "lock.shield")
                .font(.callout).foregroundStyle(.secondary)
        }.font(.system(size: 13)).controlSize(.regular)
    }
    private var dropdownSettings: some View {
        HStack(alignment: .top, spacing: 20) {
            GroupBox("Dropdown") {
                VStack(alignment: .leading, spacing: 8) {
                    TransparencyControl(title: "Dropdown transparency", value: store.menuPreferences.dropdownTransparency, save: store.setDropdownTransparency)
                        .disabled(!store.menuPreferences.liquidGlass)
                    Text("Uses Liquid Glass from General. Higher transparency lets more of the desktop show through.").font(.callout).foregroundStyle(.secondary)
                    Divider()
                    Toggle("Always show individual limits", isOn: Binding(get: { store.menuPreferences.detailedQuotaLabels }, set: { store.setDetailedQuotaLabels($0) }))
                    Text("Show each limit and reset time without expanding an account.")
                        .font(.callout).foregroundStyle(.secondary)
                    Divider()
                    Toggle("Show account emails", isOn: Binding(get: { store.menuPreferences.dropdownShowEmails }, set: { store.setDropdownShowEmails($0) }))
                    Divider()
                    Toggle("Show reset times", isOn: Binding(get: { store.menuPreferences.dropdownShowResets }, set: { store.setDropdownShowResets($0) }))
                    Divider()
                    Toggle("Show recent usage graph", isOn: Binding(get: { store.menuPreferences.dropdownShowRecentUsage }, set: { store.setDropdownShowRecentUsage($0) }))
                    Text("A tiny 6-hour consumption graph beside each account. Spikes show heavier use; gaps mean no reading.")
                        .font(.callout).foregroundStyle(.secondary)
                    Divider()
                    Toggle("Show progress bars", isOn: Binding(get: { store.menuPreferences.dropdownShowBars }, set: { store.setDropdownShowBars($0) }))
                    Divider()
                    Toggle("Show provider headings", isOn: Binding(get: { store.menuPreferences.dropdownShowHeadings }, set: { store.setDropdownShowHeadings($0) }))
                    Divider()
                    Toggle("Use comfortable spacing", isOn: Binding(get: { store.menuPreferences.dropdownRoomyRows }, set: { store.setDropdownRoomyRows($0) }))
                }.padding(10)
            }
            VStack(alignment: .leading, spacing: 10) {
            GroupBox("Live dropdown preview") {
                ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Ai-llowance", systemImage: "chart.bar.fill").font(.headline)
                    if store.accounts.isEmpty {
                        Text("Connect an account to preview your dropdown.").foregroundStyle(.secondary)
                    }
                    ForEach(MenuProvider.allCases, id: \.self) { provider in
                        let accounts = store.accounts.filter { $0.kind.provider == provider }
                        if !accounts.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                if store.menuPreferences.dropdownShowHeadings {
                                    Text(provider.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                                }
                                ForEach(accounts) { account in
                                    CompactAccountRow(account: account, snapshot: store.snapshots[account.id], error: store.errors[account.id], now: store.now, cached: store.isCached(account),
                                        expanded: dropdownPreviewExpandedID == account.id,
                                        detailedLabels: store.menuPreferences.detailedQuotaLabels, connection: store.connectionState(account), dropdownPreferences: store.menuPreferences,
                                        colorByAllowance: store.menuPreferences.colorByAllowance,
                                        history: dropdownPreviewExpandedID == account.id || store.menuPreferences.dropdownShowRecentUsage ? store.history(for: account) : [],
                                        expand: { dropdownPreviewExpandedID = dropdownPreviewExpandedID == account.id ? nil : account.id },
                                        manage: { store.selectedAccountID = account.id; section = .accounts },
                                        openUsage: { store.openUsage(account) })
                                }
                            }.padding(11).modifier(InsetSurface(tint: providerAccent(provider), cornerRadius: 14))
                        }
                    }
                }.padding(10).frame(maxWidth: 350)
                    .background { WorkspaceBackground(transparency: store.menuPreferences.dropdownTransparency).clipShape(RoundedRectangle(cornerRadius: 18)) }
                    .frame(maxWidth: .infinity)
                }.frame(maxHeight: 480)
            }
            Text("Your current accounts and readings. Click an account to preview its expanded details.")
                .font(.callout).foregroundStyle(.secondary)
            }.frame(width: 340)
        }.font(.system(size: 13)).toggleStyle(SettingsSwitchStyle())
    }

    private var appearanceSettings: some View {
            GroupBox("Appearance") {
                VStack(spacing: 12) {
                    HStack {
                        Text("Appearance")
                        Spacer()
                        Picker("Appearance", selection: Binding(get: { store.menuPreferences.theme }, set: { store.setTheme($0) })) {
                            ForEach(AppTheme.allCases) { theme in Text(theme.title).tag(theme) }
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                    }
                    Divider()
                    Toggle("Liquid Glass", isOn: Binding(get: { store.menuPreferences.liquidGlass }, set: { store.setLiquidGlass($0) }))
                        .toggleStyle(SettingsSwitchStyle())
                    Text("Let desktop colors show through the dashboard and dropdown. Turn off for opaque backgrounds. macOS Reduce Transparency takes priority.")
                        .font(.callout).foregroundStyle(.secondary)
                    TransparencyControl(title: "Dashboard transparency", value: store.menuPreferences.dashboardTransparency, save: store.setDashboardTransparency)
                        .disabled(!store.menuPreferences.liquidGlass)
                }.padding(10)
            }
        .font(.system(size: 13))
    }
    private var menuBarSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Menu bar") {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            if store.menuEntries.isEmpty { Label("Usage", systemImage: "chart.bar") }
                            ForEach(Array(store.menuEntries.enumerated()), id: \.offset) { _, entry in
                                HStack(spacing: 4) {
                                    ProviderMark(provider: entry.provider, size: ProviderImages.menuIconSize, isMenuBar: true)
                                    Text(MenuEntryPresentation.title(entry, preferences: store.menuPreferences))
                                        .foregroundStyle(store.menuPreferences.colorByAllowance && !entry.isBalance && entry.remainingPercent != nil ? Color(nsColor: .allowance(entry.remainingPercent!)) : NSColor.accountHex(entry.colorHex).map { Color(nsColor: $0) } ?? Color.primary)
                                }
                            }
                        }.font(.system(size: 12, weight: .medium)).monospacedDigit().padding(12)
                    }.background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
                    Label("Live preview · changes appear immediately", systemImage: "menubar.rectangle")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Divider()

                    HStack {
                        Text("Group usage")
                        Spacer()
                        Picker("Group usage", selection: Binding(get: { store.menuPreferences.display }, set: { store.setMenuDisplay($0) })) {
                            ForEach(MenuDisplay.allCases) { mode in Text(mode.title).tag(mode) }
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 300)
                    }
                    if store.menuPreferences.display == .byAccount {
                        Toggle("Show account names", isOn: Binding(get: { store.menuPreferences.showAccountNames }, set: { store.setShowAccountNames($0) }))
                    } else {
                        HStack {
                            Text("Combined allowance")
                            Spacer()
                            Picker("Combined allowance", selection: Binding(get: { store.menuPreferences.aggregation }, set: { store.setMenuAggregation($0) })) {
                                ForEach(MenuAggregation.allCases) { mode in Text(mode.title).tag(mode) }
                            }.labelsHidden().frame(width: 190)
                        }
                    }
                    Divider()
                    Toggle("Show 5-hour allowance", isOn: Binding(get: { store.menuPreferences.showSessionInMenuBar }, set: { store.setShowSessionInMenuBar($0) }))
                    Text("Show 5-hour usage beside weekly usage when the account reports a session limit. Verified Claude Ultra accounts may only report weekly limits.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Text("Weekly label")
                        Spacer()
                        Picker("Weekly label", selection: Binding(get: { store.menuPreferences.weeklyMenuLabel }, set: { store.setWeeklyMenuLabel($0) })) {
                            ForEach(WeeklyMenuLabel.allCases) { label in Text(label.title).tag(label) }
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
                            .disabled(!store.menuPreferences.showSessionInMenuBar)
                    }
                    HStack {
                        Text("5-hour label")
                        Spacer()
                        Picker("5-hour label", selection: Binding(get: { store.menuPreferences.sessionMenuLabel }, set: { store.setSessionMenuLabel($0) })) {
                            ForEach(SessionMenuLabel.allCases) { label in Text(label.title).tag(label) }
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
                    }
                    Text("None hides the label, not the percentage. Weekly-only mode has no weekly label.")
                        .font(.callout).foregroundStyle(.secondary)
                    Divider()
                    Toggle("Color by allowance", isOn: Binding(get: { store.menuPreferences.colorByAllowance }, set: { store.setColorByAllowance($0) }))
                    Text("Cool colors turn warm as allowance runs low.")
                        .font(.callout).foregroundStyle(.secondary)
                    Divider()
                    HStack {
                        Text("Accounts shown")
                        Spacer()
                        Picker("Accounts shown", selection: Binding(get: { store.menuPreferences.allAccounts }, set: { store.setAllMenuAccounts($0) })) {
                            Text("All accounts").tag(true)
                            Text("Selected accounts").tag(false)
                        }.labelsHidden().frame(width: 190)
                    }
                    Divider()
                    HStack {
                        Text("Icon order").fontWeight(.medium)
                        Spacer()
                        Button("Reset order") { store.resetMenuAccountOrder() }
                            .disabled(store.menuPreferences.accountOrder.isEmpty)
                    }
                    Text("Top to bottom becomes left to right. Provider groups follow their first account. All together combines subscription icons.")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(Array(store.orderedMenuAccounts.enumerated()), id: \.element.id) { index, account in
                        HStack(spacing: 10) {
                            ProviderMark(provider: account.kind.provider, size: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.name)
                                if let email = account.expectedIdentity {
                                    Text(email).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if !account.enabled || (!store.menuPreferences.allAccounts && !store.menuPreferences.selectedAccountIDs.contains(account.id)) {
                                Text("Hidden").font(.caption).foregroundStyle(.secondary)
                            }
                            Button { store.moveMenuAccount(account.id, offset: -1) } label: {
                                Image(systemName: "chevron.up").frame(width: 18, height: 18)
                            }.disabled(index == 0).accessibilityLabel("Move \(account.name) left")
                                .help("Move left in the menu bar")
                            Button { store.moveMenuAccount(account.id, offset: 1) } label: {
                                Image(systemName: "chevron.down").frame(width: 18, height: 18)
                            }.disabled(index == store.orderedMenuAccounts.count - 1)
                                .accessibilityLabel("Move \(account.name) right").help("Move right in the menu bar")
                        }.padding(.vertical, 3)
                    }
                    if !store.menuPreferences.allAccounts {
                        ForEach(store.accounts.filter { !$0.kind.isAPI || $0.kind.isBalance }) { account in
                            Toggle(account.name, isOn: Binding(get: { store.menuPreferences.selectedAccountIDs.contains(account.id) }, set: { store.setMenuAccount(account, included: $0) })).toggleStyle(.checkbox)
                        }
                    }
                }.padding(10)
            }
        }.font(.system(size: 13)).toggleStyle(SettingsSwitchStyle()).controlSize(.regular)
    }

}

// Keep native switch controls aligned consistently across settings groups.
private struct SettingsSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 20) {
            configuration.label
            Spacer(minLength: 12)
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
        }.frame(minHeight: 26)
    }
}

private struct UpdateCheckButton: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        Button { updater.check() } label: { Image(systemName: "arrow.down.circle").frame(width: 22, height: 22) }
            .disabled(!updater.canCheck).help("Check for Updates…").accessibilityLabel("Check for Updates")
    }
}
private struct UpdateSettings: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        GroupBox("Updates & support") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Ai-llowance " + AppUpdater.version).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Button("Check for Updates…") { updater.check() }.disabled(!updater.canCheck).controlSize(.regular)
                }
                Toggle("Automatically check for updates", isOn: Binding(get: { updater.automaticChecks }, set: { updater.setAutomaticChecks($0) }))
                    .toggleStyle(SettingsSwitchStyle()).controlSize(.regular).font(.system(size: 13)).disabled(!updater.canCheck)
                Text("Checks at launch and hourly while this app is running. You’ll be prompted when an update is available.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let checked = updater.lastChecked {
                    Text("Last checked " + checked.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Link("Star Ai-llowance on GitHub ↗", destination: URL(string: "https://github.com/jamesatFRM/Ai-llowance")!)
                    .font(.system(size: 12, weight: .medium))
                Divider()
                HStack {
                    Text("Questions or suggestions?").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Link("Send Feedback…", destination: URL(string: "https://github.com/jamesatFRM/Ai-llowance/issues/new")!)
                }
            }.padding(10)
        }
    }
}

private struct HistoryCard: View {
    @ViewState private var hoveredDate: Date?
    let account: Account
    let points: [UsageHistoryPoint]
    let snapshot: Snapshot?
    let error: Bool
    let cached: Bool
    let needsReconnect: Bool
    let connection: ConnectionPresentation
    let now: Date
    let historyHours: Int
    let chartStyle: DashboardChartStyle
    let fullScale: Bool
    var overviewTint: Color? = nil
    private var effectiveStyle: DashboardChartStyle {
        if historyHours == 168 { return .bars }
        return chartStyle == .mixed ? .matrix : account.kind.isAPI && chartStyle.isCurrentAllowance ? .line : chartStyle
    }
    var actionTitle: String
    var openUsage: () -> Void
    var manage: () -> Void
    var moveEarlier: (() -> Void)? = nil
    var moveLater: (() -> Void)? = nil
    var resetOrder: (() -> Void)? = nil
    private var status: AllowanceStatus { AllowanceStatus.evaluate(snapshot: snapshot, kind: account.kind, now: now, hasError: error) }
    private var statusColor: Color {
        if connection.needsAction { return .orange }
        if !account.enabled || cached || connection.saved { return .secondary }
        switch status.state {
        case .ready, .unlimited: return Color(red: 0.23, green: 0.78, blue: 0.61)
        case .low, .exhausted, .restricted: return .orange
        default: return .secondary
        }
    }
    private var graphTint: Color { overviewTint ?? NSColor.accountHex(account.graphColorHex).map { Color(nsColor: $0) } ?? providerAccent(account.kind.provider) }
    private var gradientAccent: Color {
        guard let base = NSColor(graphTint).usingColorSpace(.sRGB) else { return graphTint }
        let shift: CGFloat = base.hueComponent < 0.15 ? -0.10 : 0.10
        let hue = (base.hueComponent + shift + 1).truncatingRemainder(dividingBy: 1)
        return Color(nsColor: NSColor(hue: hue, saturation: max(0.65, base.saturationComponent), brightness: 1, alpha: 1))
    }
    private var dashboardTint: Color { NSColor.accountHex(account.dashboardColorHex).map { Color(nsColor: $0) } ?? providerAccent(account.kind.provider) }
    private var metric: String { account.kind.isBalance ? "Balance (USD)" : account.kind.isAPI ? "Month-to-date spending (USD)" : "Recorded allowance remaining (%)" }
    private func value(_ point: UsageHistoryPoint) -> Double? {
        if account.kind.isBalance { return point.balanceUSD.map { NSDecimalNumber(decimal: $0).doubleValue } }
        if account.kind.isAPI { return point.costUSD.map { NSDecimalNumber(decimal: $0).doubleValue } }
        return point.remainingPercent
    }
    private var plotted: [UsageHistoryPoint] { points.filter { value($0) != nil } }
    private var samples: [HistorySample] { HistorySeries.samples(points, kind: account.kind) }
    private var hoveredSample: HistorySample? {
        guard let hoveredDate else { return nil }
        return (effectiveStyle == .bars ? HistorySeries.barSamples(samples, count: historyHours == 168 ? 28 : 24) : samples).min { abs($0.timestamp.timeIntervalSince(hoveredDate)) < abs($1.timestamp.timeIntervalSince(hoveredDate)) }
    }
    private var fittedTrend: Bool { !account.kind.isAPI && !fullScale && effectiveStyle != .bars && effectiveStyle != .dots }
    private var plotDomain: ClosedRange<Double> {
        if fittedTrend { return HistorySeries.allowanceTrendDomain(samples.map(\.value)) }
        if account.kind.isAPI {
            return min(0, (samples.map(\.value).min() ?? 0) * 1.08)...max(1, (samples.map(\.value).max() ?? 1) * 1.08)
        }
        return 0...100
    }
    private var historyCaption: String {
        guard !account.kind.isAPI else { return "Recorded history" }
        let hours = UsageHeatmap.hours(points: points, kind: account.kind, calendar: .current)
            .filter { Calendar.current.isDate($0.key, inSameDayAs: now) }
        guard !hours.isEmpty else { return "History building" }
        return String(format: "%.1f pts observed today", hours.values.reduce(0, +))
    }
    private var reading: ReadingPresentation { ReadingPresentation(snapshot: snapshot, kind: account.kind, now: now, saved: connection.saved || cached) }
    private var sessionQuota: QuotaWindow? { reading.session }
    private var quotaSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(reading.value)
                .font(.system(size: 32, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(connection.saved ? Color.secondary : Color.primary)
                .lineLimit(1).minimumScaleFactor(0.65)
            HStack {
                Text(reading.compactTitle).lineLimit(2)
                Spacer(minLength: 4)
                Text(reading.reset).lineLimit(2).multilineTextAlignment(.trailing)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.vertical, 5).frame(height: 58, alignment: .topLeading)
            .accessibilityElement(children: .ignore).accessibilityLabel(reading.accessibilitySummary)
    }
    private var sessionSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let session = sessionQuota {
                HStack {
                    Text("5-hour window")
                    Spacer()
                    Text("\(Int(session.remainingPercent))% left").monospacedDigit()
                }.font(.system(size: 11, weight: .medium))
                GeometryReader { geometry in
                    Capsule().fill(Color.primary.opacity(0.065))
                        .overlay(alignment: .leading) {
                            Capsule().fill(graphTint.opacity(connection.saved ? 0.35 : 0.85))
                                .frame(width: geometry.size.width * min(100, max(0, session.remainingPercent)) / 100)
                        }
                }.frame(height: 5)
                Text(ReadingPresentation.resetText(session.resetsAt, at: now)).font(.system(size: 9)).foregroundStyle(.secondary)
            } else {
                Label("5-hour limit not reported", systemImage: "info.circle")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42, alignment: .leading)
    }

    var body: some View {
        let samples = self.samples
        let plotted = self.plotted
        let plotDomain = self.plotDomain
        let displaySamples = HistorySeries.plotSamples(samples)
        let series = effectiveStyle == .bars ? HistorySeries.barSamples(samples, count: historyHours == 168 ? 28 : 24) : effectiveStyle == .dots ? displaySamples : HistorySeries.smoothTrend(displaySamples)
        let segmentCounts = Dictionary(grouping: series, by: \.segment).mapValues(\.count)
        SettingsCard(inset: 16, tint: dashboardTint) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    ProviderMark(provider: account.kind.provider, size: 23).foregroundStyle(dashboardTint)
                    Text(account.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: connection.symbol).foregroundStyle(statusColor).help(connection.title)
                }
                Text(account.expectedIdentity ?? snapshot?.identity ?? account.kind.title)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                quotaSummary
                if effectiveStyle.isCurrentAllowance {
                    CurrentAllowanceChart(percent: snapshot?.displayWindow(for: account.kind)?.remainingPercent,
                                          style: effectiveStyle, tint: graphTint,
                                          saved: reading.saved)
                        .frame(height: 92)
                    Text(reading.saved ? "Remaining vs. used · last known" : "Remaining vs. used · current limit")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                } else if plotted.isEmpty {
                    Text("No readings in this range yet. History grows as this Mac refreshes your accounts.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity).frame(height: 92)
                } else {
                    Chart {
                        ForEach(series) { sample in
                            if effectiveStyle == .matrix || effectiveStyle == .bars {
                                PointMark(x: .value("Time", sample.timestamp), y: .value(metric, sample.value))
                                    .foregroundStyle(Color.clear).symbolSize(0)
                            } else if effectiveStyle == .dots {
                                PointMark(x: .value("Time", sample.timestamp), y: .value(metric, sample.value))
                                    .foregroundStyle(graphTint.opacity(0.8)).symbolSize(18)
                            } else {
                            if effectiveStyle == .area || effectiveStyle == .glow {
                            AreaMark(x: .value("Time", sample.timestamp), yStart: .value("Baseline", plotDomain.lowerBound), yEnd: .value(metric, sample.value), series: .value("Period", "core-" + String(sample.segment)))
                                .foregroundStyle(LinearGradient(stops: [.init(color: graphTint.opacity(0.44), location: 0), .init(color: graphTint.opacity(0.20), location: 0.35), .init(color: graphTint.opacity(0), location: 1)], startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.monotone)
                            }
                            if effectiveStyle == .glow {
                                LineMark(x: .value("Time", sample.timestamp), y: .value(metric, sample.value), series: .value("Period", "halo-" + String(sample.segment)))
                                    .foregroundStyle(graphTint.opacity(0.13))
                                    .lineStyle(StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                                    .interpolationMethod(.monotone)
                            }
                            LineMark(x: .value("Time", sample.timestamp), y: .value(metric, sample.value), series: .value("Period", "core-" + String(sample.segment)))
                                .foregroundStyle(LinearGradient(colors: [graphTint.opacity(0.75), graphTint, graphTint], startPoint: .leading, endPoint: .trailing))
                                .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                                .interpolationMethod(.monotone)
                            if sample.id == series.last?.id || segmentCounts[sample.segment] == 1 {
                                PointMark(x: .value("Time", sample.timestamp), y: .value(metric, sample.value))
                                    .foregroundStyle(graphTint)
                                    .symbol {
                                        Circle().fill(graphTint)
                                            .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                                            .frame(width: sample.id == series.last?.id ? 7 : 3, height: sample.id == series.last?.id ? 7 : 3)
                                    }
                            }
                            }
                        }
                    }
                    .id(effectiveStyle)
                    .chartYScale(domain: plotDomain, range: .plotDimension(startPadding: 6, endPadding: 10))
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) {
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.035))
                            AxisValueLabel(format: points.last!.timestamp.timeIntervalSince(points.first!.timestamp) > 86400 ? .dateTime.month(.abbreviated).day() : .dateTime.hour(.defaultDigits(amPM: .abbreviated)))
                                .font(.system(size: 9)).foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) {
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.primary.opacity(0.08))
                            AxisValueLabel().font(.system(size: 9)).foregroundStyle(Color(nsColor: .secondaryLabelColor))
                        }
                    }
                    .chartOverlay { proxy in
                        GeometryReader { geometry in
                            ZStack(alignment: .topLeading) {
                                if effectiveStyle == .matrix || effectiveStyle == .bars, let plotFrame = proxy.plotFrame {
                                    let frame = geometry[plotFrame]
                                    DotMatrixPlot(points: series.compactMap { sample in
                                        guard let x = proxy.position(forX: sample.timestamp), let y = proxy.position(forY: sample.value) else { return nil }
                                        return MatrixPoint(x: x, y: y, segment: sample.segment)
                                    }, tint: graphTint, bars: effectiveStyle == .bars)
                                        .frame(width: frame.width, height: frame.height)
                                        .offset(x: frame.minX, y: frame.minY)
                                        .allowsHitTesting(false)
                                }
                            Rectangle().fill(.clear).contentShape(Rectangle())
                                .onContinuousHover { phase in
                                    switch phase {
                                    case .active(let location):
                                        // Window/control drags must not trigger chart redraws.
                                        guard NSEvent.pressedMouseButtons == 0 else { return }
                                        if let plotFrame = proxy.plotFrame {
                                            let frame = geometry[plotFrame]
                                            let date: Date? = frame.contains(location) ? proxy.value(atX: location.x - frame.minX, as: Date.self) : nil
                                            let nearest = date.flatMap { date in samples.min { abs($0.timestamp.timeIntervalSince(date)) < abs($1.timestamp.timeIntervalSince(date)) }?.timestamp }
                                            if hoveredDate != nearest { hoveredDate = nearest }
                                        }
                                    case .ended: hoveredDate = nil
                                    }
                                }
                            }
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if let sample = hoveredSample {
                            Text(sample.timestamp.formatted(date: .omitted, time: .shortened) + " · " + (account.kind.isAPI ? String(format: "$%.2f", sample.value) : String(format: "%.1f%% left", sample.value)))
                                .font(.system(size: 10, weight: .medium)).monospacedDigit()
                                .padding(5).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(height: 92).padding(.top, 3).padding(.bottom, 2)
                    if let last = plotted.last {
                        HStack {
                            Text(fittedTrend ? String(format: "Smoothed trend · %.0f–%.0f%%", plotDomain.lowerBound, plotDomain.upperBound) : effectiveStyle == .bars ? "Latest reading per time bucket" : historyCaption).lineLimit(1).help(fittedTrend ? "The trend uses a fitted vertical scale and one-hour smoothing. Hover for exact recorded readings. Switch to the full 0–100% scale in the chart menu. Missing intervals and resets are never connected." : "History uses the full scale. Hover for exact recorded readings; missing intervals and resets are not connected.")
                            Spacer()
                            Text(last.timestamp, format: .dateTime.hour().minute()).help("Last reading: " + last.timestamp.formatted(date: .abbreviated, time: .shortened))
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                    }

                }
                if !account.kind.isAPI { sessionSummary }
                else {
                    Label(account.kind.isBalance ? "Credits, separate from plan limits" : "Spending, not a credit balance", systemImage: "info.circle")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42, alignment: .leading)
                }
                ConnectionStatusLine(connection: connection)
                    .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .topLeading)
                HStack(spacing: 8) {
                    Button(action: openUsage) { Label(actionTitle, systemImage: actionTitle == "Open usage" ? "arrow.up.right" : "arrow.clockwise").frame(maxWidth: .infinity).frame(height: 28) }
                    Menu {
                        Button("Name & color…", action: manage)
                        Divider()
                        Button("Move earlier") { moveEarlier?() }.disabled(moveEarlier == nil)
                        Button("Move later") { moveLater?() }.disabled(moveLater == nil)
                        Button("Reset dashboard order") { resetOrder?() }.disabled(resetOrder == nil)
                    } label: { Image(systemName: "slider.horizontal.3").frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).fixedSize().help("Name, color & dashboard order").accessibilityLabel("Options for " + account.name)
                }.font(.system(size: 11, weight: .medium)).buttonStyle(QuietButtonStyle())
            }
        }
    }
}


private struct MatrixPoint {
    let x: CGFloat
    let y: CGFloat
    let segment: Int
}

/// Screen-space rasterization of the same trend, never connecting separate periods.
private struct DotMatrixPlot: View {
    let points: [MatrixPoint]
    let tint: Color
    var bars = false
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 4
            let radius: CGFloat = 1.15
            guard size.width > 0, size.height > 0 else { return }
            if bars {
                let width = max(3, min(14, size.width / 36))
                for point in points {
                    let top = min(size.height - 1, max(0, point.y))
                    let rect = CGRect(x: point.x - width / 2, y: top, width: width, height: max(1, size.height - top))
                    let path = Path(roundedRect: rect, cornerRadius: 2)
                    context.fill(path, with: .linearGradient(Gradient(colors: [tint.opacity(0.95), tint.opacity(0.22)]), startPoint: CGPoint(x: point.x, y: top), endPoint: CGPoint(x: point.x, y: size.height)))
                }
                return
            }
            for x in stride(from: step / 2, through: size.width, by: step) {
                var lineY: CGFloat?
                if let exact = points.min(by: { abs($0.x - x) < abs($1.x - x) }), abs(exact.x - x) <= step / 2 {
                    lineY = exact.y
                }
                if points.count > 1 {
                    for i in 1..<points.count {
                        let a = points[i - 1], b = points[i]
                        if a.segment == b.segment, a.x <= x, x <= b.x, b.x > a.x {
                            lineY = a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x)
                            break
                        }
                    }
                }
                for y in stride(from: step / 2, through: size.height, by: step) {
                    var opacity = 0.035
                    if let lineY {
                        let depth = y - lineY
                        if abs(depth) <= step * 0.7 { opacity = 0.95 }
                        else if depth > 0 {
                            opacity = 0.12 + 0.43 * pow(max(0, 1 - depth / max(1, size.height - lineY)), 1.6)
                        }
                    }
                    let dot = Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    context.fill(dot, with: .color(tint.opacity(opacity)))
                }
            }
        }.clipped().accessibilityHidden(true)
    }
}

private struct ActivityHeatmap: View {
    let accounts: [Account]
    let histories: [UUID: [UsageHistoryPoint]]
    let now: Date
    private let calendar = Calendar.current
    var body: some View {
        let today = calendar.startOfDay(for: now)
        let days = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0 - 6, to: today) }
        let buckets = accounts.reduce(into: [Date: Double]()) { result, account in
            let hours = UsageHeatmap.hours(points: histories[account.id] ?? [], kind: account.kind, calendar: calendar)
            for (hour, value) in hours where hour >= (days.first ?? today) && hour <= now { result[hour, default: 0] += value }
        }
        let peak = buckets.values.max() ?? 0
        SettingsCard(inset: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Allowance activity", systemImage: "square.grid.3x3.fill").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("Last 7 days · " + (calendar.timeZone.abbreviation() ?? calendar.timeZone.identifier)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Grid(horizontalSpacing: 4, verticalSpacing: 3) {
                    GridRow {
                        Color.clear.frame(width: 62, height: 12)
                        ForEach(0..<24) { hour in
                            Text(hour % 6 == 0 ? (hour == 0 ? "12a" : hour == 6 ? "6a" : hour == 12 ? "12p" : "6p") : "")
                                .font(.system(size: 9)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        }
                    }
                    ForEach(days, id: \.self) { day in
                        GridRow {
                            Text(day, format: .dateTime.weekday(.abbreviated).day()).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
                            ForEach(0..<24) { hour in
                                heatmapCell(day: day, hour: hour, buckets: buckets, peak: peak)
                            }
                        }
                    }
                }
                HStack(spacing: 5) {
                    Text("Less")
                    ForEach(0..<5) { level in RoundedRectangle(cornerRadius: 2).fill(Brand.cyan.opacity(0.12 + Double(level) * 0.22)).frame(width: 12, height: 10) }
                    Text("More")
                    Spacer()
                    Text("Outlined = no reading").help("Recorded subscription allowance consumption, not coding hours. Gaps and resets are excluded; API spending is not mixed in.")
                }.font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
    private func heatmapCell(day: Date, hour: Int, buckets: [Date: Double], peak: Double) -> some View {
        let matching = buckets.filter { calendar.isDate($0.key, inSameDayAs: day) && calendar.component(.hour, from: $0.key) == hour }
        let value: Double? = matching.isEmpty ? nil : matching.values.reduce(0, +)
        let strength = value.map { peak > 0 ? sqrt($0 / peak) : 0 } ?? 0
        let fill: Color = value == nil ? Color.primary.opacity(0.025) : Brand.cyan.opacity(0.12 + strength * 0.88)
        let border: Color = Color.primary.opacity(value == nil ? 0.08 : 0)
        let dateText = day.formatted(date: .abbreviated, time: .omitted)
        let amount = value.map { String(format: "%.1f allowance points consumed", $0) } ?? "No measured interval"
        let description = "\(dateText) · \(hour):00 · \(amount)"
        return RoundedRectangle(cornerRadius: 3)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(border, lineWidth: 0.5))
            .frame(maxWidth: .infinity).frame(height: 10)
            .help(description)
            .accessibilityLabel(description)
    }

}


private struct AccountAppearanceEditor: View {
    let account: Account
    var save: (String, String?, String?, String?) -> Void
    var cancel: () -> Void
    @ViewState private var name: String
    @ViewState private var color: Color
    @ViewState private var menu: Bool
    @ViewState private var dashboard: Bool
    @ViewState private var graph: Bool
    init(account: Account, save: @escaping (String, String?, String?, String?) -> Void, cancel: @escaping () -> Void) {
        self.account = account; self.save = save; self.cancel = cancel
        _name = ViewState(initialValue: account.name)
        _color = ViewState(initialValue: NSColor.accountHex(account.graphColorHex ?? account.dashboardColorHex ?? account.menuColorHex).map { Color(nsColor: $0) } ?? providerAccent(account.kind.provider))
        _menu = ViewState(initialValue: account.menuColorHex != nil)
        _dashboard = ViewState(initialValue: account.dashboardColorHex != nil)
        _graph = ViewState(initialValue: account.graphColorHex != nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Account Appearance").font(.headline)
            TextField("Account name", text: $name).textFieldStyle(.roundedBorder)
            ColorPicker("Accent color", selection: $color, supportsOpacity: false)
            GroupBox("Apply color to") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Menu bar & dropdown", isOn: $menu)
                    Toggle("Dashboard", isOn: $dashboard)
                    Toggle("Usage graph", isOn: $graph)
                    HStack {
                        Button("All") { menu = true; dashboard = true; graph = true }
                        Button("Use provider colors") { menu = false; dashboard = false; graph = false }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            Text("Combined menu items use a custom color only when all included accounts share it.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                    let hex = String(format: "%02X%02X%02X", Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
                    save(name, menu ? hex : nil, dashboard ? hex : nil, graph ? hex : nil)
                }.keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.font(.system(size: 13)).padding(20).frame(width: 360)
    }
}

/// Current allowance is a composition, not a time series. Never infer a denominator for API dollars.
private struct CurrentAllowanceChart: View {
    let percent: Double?
    let style: DashboardChartStyle
    let tint: Color
    let saved: Bool
    private var remaining: Double? { percent.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil } }
    var body: some View {
        HStack(spacing: 16) {
            if let remaining {
                if style == .gauge {
                    ZStack {
                        Circle().trim(from: 0, to: 0.75).stroke(Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        Circle().trim(from: 0, to: 0.75 * remaining / 100)
                            .stroke(AngularGradient(colors: [tint.opacity(0.35), tint], center: .center, startAngle: .degrees(0), endAngle: .degrees(270)), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        Text(String(format: "%.0f%%", remaining)).font(.system(size: 16, weight: .semibold, design: .rounded)).rotationEffect(.degrees(-135))
                    }.rotationEffect(.degrees(135)).padding(7).frame(width: 74, height: 74)
                } else {
                    Chart {
                        SectorMark(angle: .value("Remaining", remaining), innerRadius: .ratio(style == .ring ? 0.76 : 0), angularInset: remaining > 0 && remaining < 100 ? 2 : 0)
                            .foregroundStyle(tint.gradient).cornerRadius(3)
                        SectorMark(angle: .value("Used", 100 - remaining), innerRadius: .ratio(style == .ring ? 0.76 : 0), angularInset: remaining > 0 && remaining < 100 ? 2 : 0)
                            .foregroundStyle(Color.primary.opacity(0.08)).cornerRadius(3)
                    }.chartLegend(.hidden).frame(width: 74, height: 74)
                        .overlay {
                            if style == .ring { Text(String(format: "%.0f%%", remaining)).font(.system(size: 16, weight: .semibold, design: .rounded)) }
                        }
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(saved ? "Saved allowance" : "Current allowance").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Label(String(format: "%.0f%% remaining", remaining), systemImage: "circle.fill").foregroundStyle(tint)
                    Label(String(format: "%.0f%% used", 100 - remaining), systemImage: "circle").foregroundStyle(.secondary)
                }.font(.system(size: 11, weight: .medium)).monospacedDigit()
            } else {
                Text("No allowance reading yet").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(remaining.map { String(format: "%@ %.0f percent remaining, %.0f percent used", saved ? "Saved allowance" : "Current allowance", $0, 100 - $0) } ?? "No allowance reading yet")
    }
}

private struct UsageOverviewCharts: View {
    let accounts: [Account]
    let colorAccounts: [Account]
    let histories: [UUID: [UsageHistoryPoint]]
    let now: Date
    private let calendar = Calendar.current
    private struct DailyUsage: Identifiable {
        let account: UUID
        let day: Date
        let value: Double
        var id: String { account.uuidString + String(day.timeIntervalSince1970) }
    }
    private var days: [Date] {
        let today = calendar.startOfDay(for: now)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0 - 6, to: today) }
    }
    private var eligible: [Account] { accounts.filter { !$0.kind.isAPI } }
    private var readings: [DailyUsage] {
        eligible.flatMap { account in
            let hours = UsageHeatmap.hours(points: histories[account.id] ?? [], kind: account.kind, calendar: calendar)
            return days.compactMap { day -> DailyUsage? in
                let observed = hours.filter { calendar.isDate($0.key, inSameDayAs: day) && $0.key <= now }
                guard !observed.isEmpty else { return nil }
                return DailyUsage(account: account.id, day: day, value: observed.values.reduce(0, +))
            }
        }
    }
    private func tint(_ account: Account) -> Color { overviewAccountTint(account, accounts: colorAccounts) }
    var body: some View {
        let records = readings
        let totals = eligible.map { account in (account, records.filter { $0.account == account.id }.reduce(0) { $0 + $1.value }) }
        let total = totals.reduce(0) { $0 + $1.1 }
        SettingsCard(inset: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                Text("Allowance use").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("Last 7 days").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if total > 0 {
                    HStack(spacing: 14) {
                        Chart {
                            ForEach(eligible) { account in
                                let amount = totals.first { $0.0.id == account.id }?.1 ?? 0
                                if amount > 0 {
                                    SectorMark(angle: .value("Allowance points", amount), innerRadius: .ratio(0.68), angularInset: 3)
                                        .foregroundStyle(tint(account).gradient).cornerRadius(3)
                                        .accessibilityLabel(account.name)
                                        .accessibilityValue(String(format: "%.1f allowance points, %.0f percent of observed consumption", amount, amount / total * 100))
                                }
                            }
                        }.frame(width: 94, height: 94)
                            .overlay { VStack(spacing: 1) {
                                Text(String(format: "%.0f", total)).font(.system(size: 17, weight: .semibold, design: .rounded))
                                Text("points").font(.system(size: 9)).foregroundStyle(.secondary)
                            } }
                        VStack(spacing: 3) {
                            let peak = max(1, days.map { day in records.filter { $0.day == day }.reduce(0) { $0 + $1.value } }.max() ?? 1)
                            ForEach(days, id: \.self) { day in
                                let daily = records.filter { $0.day == day }
                                let amount = daily.reduce(0) { $0 + $1.value }
                                HStack(spacing: 5) {
                                    Text(day.formatted(.dateTime.weekday(.abbreviated))).frame(width: 22, alignment: .leading)
                                    GeometryReader { geometry in
                                        HStack(spacing: 0) {
                                            ForEach(eligible) { account in
                                                let value = daily.first { $0.account == account.id }?.value ?? 0
                                                Rectangle().fill(tint(account).gradient)
                                                    .frame(width: geometry.size.width * value / peak)
                                                    .help(account.name + String(format: ": %.1f allowance points", value))
                                            }
                                        }.clipShape(RoundedRectangle(cornerRadius: 2))
                                    }.frame(height: 7)
                                    Text(daily.isEmpty ? "—" : String(format: "%.0f", amount)).monospacedDigit().frame(width: 18, alignment: .trailing)
                                }.font(.system(size: 9)).foregroundStyle(.secondary).frame(height: 10)
                            }
                        }.frame(height: 94)

                    }
                    HStack(spacing: 8) {
                        ForEach(eligible.prefix(4)) { account in
                            let amount = totals.first { $0.0.id == account.id }?.1 ?? 0
                            HStack(spacing: 3) {
                                Circle().fill(tint(account)).frame(width: 5, height: 5)
                                Text(account.name + (records.contains { $0.account == account.id } ? String(format: " %.0f%%", amount / total * 100) : " —")).lineLimit(1)
                            }.help(account.name + (records.contains { $0.account == account.id } ? String(format: ": %.1f allowance points consumed", amount) : ": no measured intervals"))
                        }
                        if eligible.count > 4 { Text("+\(eligible.count - 4)").help("Additional accounts are included in both charts.") }
                    }.font(.system(size: 9)).foregroundStyle(.secondary)
                } else {
                    Text(records.isEmpty ? "Collecting usage history" : "No measured consumption yet")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 108)
                }
                Text("Plan-relative points · not tokens or dollars")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .help("Each point is one percentage point of an account’s quota. Plans have different capacities, so this compares observed allowance depletion, not tokens, cost or coding time. API accounts are excluded. Empty days have no measured consumption or no readings.")
            }
        }
    }
}

@MainActor private func overviewAccountTint(_ account: Account, accounts: [Account]) -> Color {
    if let hex = account.graphColorHex, let color = NSColor.accountHex(hex) { return Color(nsColor: color) }
    let preceding = accounts.prefix { $0.id != account.id }.filter { $0.kind.provider == account.kind.provider }.count
    if preceding == 0 { return providerAccent(account.kind.provider) }
    return [Color.purple, Color.blue, Color.pink][(preceding - 1) % 3]
}

private struct TransparencyControl: View {
    let title: String
    let value: Double
    let save: (Double) -> Void
    @ViewState private var draft = 0.75
    @ViewState private var editing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int(draft * 100))%").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { draft }, set: {
                draft = $0
                if !editing { save($0) }
            }), in: 0...1, onEditingChanged: { active in
                editing = active
                if !active { save(draft) }
            }).accessibilityLabel(title)
            HStack { Text("Opaque"); Spacer(); Text("More transparent") }
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear { draft = value }
            .onChange(of: value) { _, updated in if !editing { draft = updated } }
    }
}
