import SwiftUI
import Charts
import AppKit
import UsageCore

// Explicit wrapper alias avoids the newer SDK State macro; remains compatible with macOS 14.
private typealias ViewState<Value> = SwiftUI.State<Value>

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

// One native material backing; cards use inexpensive translucent fills.
private struct WorkspaceBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ZStack {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Rectangle().fill(.regularMaterial)
            }
            LinearGradient(colors: scheme == .dark
                ? [Color.white.opacity(0.055), Color.white.opacity(0.015), Color.black.opacity(0.10)]
                : [Color.white.opacity(0.55), Color.white.opacity(0.20), Color.black.opacity(0.025)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
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
    case .xai: Color(red: 0.86, green: 0.72, blue: 0.40)
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
            .background(Color.primary.opacity(configuration.isPressed ? 0.10 : 0.035), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct Dashboard: View {
    @ObservedObject var store: AppStore
    var renderForSharing = false
    var maximumHeight: CGFloat = 620
    var manage: () -> Void
    @ViewState private var expandedAccountID: UUID?

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
                ScrollView { providerContent }
                    .scrollIndicators(.hidden).fixedSize(horizontal: false, vertical: true).frame(maxHeight: max(40, min(500, maximumHeight - 100)))
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
        }.padding(7).frame(width: 350).background(WorkspaceBackground()).preferredColorScheme(store.menuPreferences.theme.colorScheme)
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
                                Text(store.needsSignIn(account) ? "Sign in" : (store.errors[account.id] != nil ? "Check" : status.title)).foregroundStyle(.secondary).lineLimit(1)
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
                        HStack {
                            Text(provider.title).font(.system(size: 9, weight: .semibold)).textCase(.uppercase).tracking(0.7)
                            Spacer()
                            Text("\(accounts.count)").font(.system(size: 8, weight: .medium)).monospacedDigit()
                                .frame(minWidth: 16, minHeight: 13)
                                .background(Color.primary.opacity(0.045), in: Capsule())
                        }.foregroundStyle(.secondary).padding(.bottom, 5)
                        ForEach(accounts) { account in
                            CompactAccountRow(account: account, snapshot: store.snapshots[account.id], error: store.errors[account.id], now: store.now, cached: store.isCached(account),
                                expanded: expandedAccountID == account.id,
                                detailedLabels: store.menuPreferences.detailedQuotaLabels, colorByAllowance: store.menuPreferences.colorByAllowance,
                                history: expandedAccountID == account.id ? store.history(for: account) : [],
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
    let colorByAllowance: Bool
    let history: [UsageHistoryPoint]
    let expand: () -> Void
    let manage: () -> Void
    let openUsage: () -> Void
    private var status: AllowanceStatus { AllowanceStatus.evaluate(snapshot: snapshot, kind: account.kind, now: now, hasError: error != nil) }
    private var window: QuotaWindow? { snapshot?.limitingWindow(for: account.kind) }
    private var detail: String {
        if !account.enabled { return "Paused" }
        if error != nil { return "Check connection" }
        if cached { return "Saved reading · checking for update" }
        if status.state == .stale { return "Last known · waiting for update" }
        if status.state == .restricted { return "Provider restriction" }
        if snapshot?.unlimited == true { return "No reported limit" }
        if let balanceLabel = snapshot?.balanceLabel { return balanceLabel }
        if snapshot?.balanceUSD != nil { return "Credit balance" }
        if snapshot?.costUSD != nil { return "Spent this month · UTC" }
        if detailedLabels, let snapshot, !snapshot.applicableWindows(for: account.kind).isEmpty {
            return snapshot.applicableWindows(for: account.kind).map { "\(shortWindowLabel($0)) \(Int($0.remainingPercent))%" }.joined(separator: " · ")
        }
        if let window { return "\(shortWindowLabel(window)) · \(resetText(window.resetsAt, at: now))" }
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
                        Text(readingValue(snapshot, window: window)).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(error != nil || cached || status.state == .stale || !account.enabled ? Color.secondary : (colorByAllowance && window != nil ? Color(nsColor: .allowance(window!.remainingPercent)) : NSColor.accountHex(account.menuColorHex).map { Color(nsColor: $0) } ?? Color.primary))
                        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary).frame(width: 12)
                    }
                    HStack(spacing: 7) {
                        Text(detail).font(.system(size: 9)).foregroundStyle(error != nil || status.state == .restricted ? Color.orange : Color.secondary).lineLimit(1)
                        Spacer(minLength: 2)
                        if let window {
                            AllowanceBar(remaining: window.remainingPercent, unavailable: error != nil || cached || status.state == .stale || !account.enabled || status.state == .restricted)
                                .frame(width: 54, height: 3)
                        }
                    }.padding(.leading, 21)
                }.padding(.vertical, 4).contentShape(Rectangle())
            }.buttonStyle(.plain).help("\(account.kind.title) · click for limits and actions")
                .accessibilityLabel("\(account.name), \(readingValue(snapshot, window: window)), \(detail), \(expanded ? "collapse" : "show details")")
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let email = account.expectedIdentity ?? snapshot?.identity {
                        Text(email).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    if let snapshot {
                        ForEach(snapshot.windows) { window in QuotaDetailRow(window: window, now: now, unavailable: error != nil || cached || snapshot.isStale(at: now, windows: [window]) || !account.enabled || snapshot.providerRestricted == true) }
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

private func shortWindowLabel(_ window: QuotaWindow) -> String {
    if window.durationMinutes == 300 { return "5h session" }
    if window.durationMinutes == 10_080 { return window.label.lowercased().contains("all models") || window.id == "7-day" || window.id.lowercased().hasPrefix("codex.") ? "Week" : window.label.replacingOccurrences(of: " · 7d", with: "") }
    return window.label
}
private func resetText(_ date: Date?, at now: Date) -> String {
    guard let date else { return "reset unknown" }
    let seconds = date.timeIntervalSince(now)
    guard seconds > 0 else { return "awaiting refresh" }
    let minutes = max(1, Int(ceil(seconds / 60)))
    if minutes < 60 { return "resets in \(minutes)m" }
    if minutes < 1440 { return "resets in \(minutes / 60)h\(minutes % 60 == 0 ? "" : " \(minutes % 60)m")" }
    return "resets \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
}
private func readingAge(_ date: Date, at now: Date) -> String {
    let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
    if minutes == 0 { return "Read just now" }
    if minutes < 60 { return "Read \(minutes)m ago" }
    if minutes < 1440 { return "Read \(minutes / 60)h \(minutes % 60)m ago" }
    return "Read \(minutes / 1440)d ago"
}
private func readingValue(_ snapshot: Snapshot?, window: QuotaWindow?) -> String {
    if snapshot?.unlimited == true { return "Unlimited" }
    if let balance = snapshot?.balanceUSD { return balance.formatted(.currency(code: "USD")) }
    if let window { return "\(Int(window.remainingPercent))% left" }
    if let cost = snapshot?.costUSD { return cost.formatted(.currency(code: "USD")) }
    if snapshot?.balanceLabel == "No key budget" { return "Not set" }
    return "No reading"
}
private func menuEntryValue(_ entry: MenuEntry) -> String {
    if entry.isBalance { return entry.balanceUSD?.formatted(.currency(code: "USD").precision(.fractionLength(0...2))) ?? "—" }
    return entry.isUnlimited ? "∞" : (entry.remainingPercent.map { "\(Int($0))%" } ?? "—")
}
private struct QuotaDetailRow: View {
    let window: QuotaWindow
    let now: Date
    var unavailable = false
    var body: some View {
        let stale = window.resetsAt.map { $0 <= now } ?? false
        VStack(spacing: 3) {
            HStack {
                Text(shortWindowLabel(window)).lineLimit(1)
                Spacer()
                Text("\(Int(window.remainingPercent))% left").fontWeight(.medium).monospacedDigit()
            }.font(.system(size: 10))
            HStack {
                Text(resetText(window.resetsAt, at: now)).font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                AllowanceBar(remaining: window.remainingPercent, unavailable: unavailable || stale).frame(width: 64, height: 3)
            }
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
    @Environment(\.colorScheme) private var scheme
    var inset: CGFloat = 14
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(inset).frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: scheme == .dark ? [Color.white.opacity(0.085), Color.white.opacity(0.025)] : [Color.white.opacity(0.78), Color.white.opacity(0.38)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.20 : 0.85), Color.primary.opacity(0.055), Color.primary.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7)
                    }
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(LinearGradient(colors: [Color.white.opacity(0.045), .clear], startPoint: .top, endPoint: .bottom))
                            .frame(height: 34).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
            }
    }
}

private enum DashboardSection: String, CaseIterable, Identifiable {
    case overview = "Overview", history = "History", accounts = "Accounts", settings = "Settings", connection = "Connection"
    var id: String { rawValue }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case accounts, menuBar, behavior, updates, advanced
    var id: String { rawValue }
    var title: String { switch self { case .accounts: "Accounts"; case .menuBar: "Menu bar"; case .behavior: "General"; case .updates: "Updates"; case .advanced: "Advanced" } }
    var symbol: String { switch self { case .accounts: "person.2"; case .menuBar: "menubar.rectangle"; case .behavior: "bell.badge"; case .updates: "arrow.down.circle"; case .advanced: "slider.horizontal.3" } }
    var subtitle: String { switch self { case .accounts: "Connections, limits, and account access"; case .menuBar: "Choose what appears beside the clock"; case .behavior: "Alerts and startup preferences"; case .updates: "Keep Ai-llowance current"; case .advanced: "Provider links and local diagnostics" } }
}
private struct AccountReading: View {
    let account: Account
    let snapshot: Snapshot?
    let error: String?
    let now: Date
    let cached: Bool
    var body: some View {
        let window = snapshot?.limitingWindow(for: account.kind)
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                ProviderMark(provider: account.kind.provider)
                Text(account.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer()
                if !account.enabled { Image(systemName: "pause.fill").foregroundStyle(.secondary).help("Paused") }
                else if error != nil { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).help("Connection needs attention") }
                Text(readingValue(snapshot, window: window)).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            if let email = account.expectedIdentity ?? snapshot?.identity { Text(email).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
            if let snapshot {
                if let label = snapshot.balanceLabel { Text(label).font(.system(size: 10)).foregroundStyle(.secondary) }
                else if snapshot.balanceUSD != nil { Text("Credit balance").font(.system(size: 10)).foregroundStyle(.secondary) }
                else if snapshot.costUSD != nil { Text("API spending · this UTC month").font(.system(size: 10)).foregroundStyle(.secondary) }
                ForEach(snapshot.windows) { window in QuotaDetailRow(window: window, now: now, unavailable: error != nil || cached || snapshot.isStale(at: now, windows: [window]) || !account.enabled || snapshot.providerRestricted == true) }
                if cached || snapshot.isStale(at: now) { Text(cached ? "Saved reading · checking for update" : "Last known reading · waiting for an update").font(.caption2).foregroundStyle(.orange) }
                if snapshot.providerRestricted == true { Text("Provider restriction. These percentages do not guarantee requests are available.").font(.system(size: 10)).foregroundStyle(.orange) }
            }
            if let error { Text(error).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct AccountsView: View {
    @ObservedObject var store: AppStore
    var showMenu: () -> Void
    @ViewState private var selectedKind: ConnectionKind = .claudeCode
    @ViewState private var setupStarted = false
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
    @ViewState private var section: DashboardSection = .history
    @ViewState private var historyHours = 24
    @ViewState private var historyAccountID: UUID?
    @ViewState private var selectedTab: SettingsTab = .behavior
    @AppStorage("hideFromDock") private var hideFromDock = true
    @ViewState private var handledAccountNavigationVersion: UInt64 = 0

    var body: some View {
        VStack(spacing: 0) {
            dashboardNavigation
            Divider().opacity(0.35)
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    if section == .settings { settingsTabs.padding(12) }
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
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                switch section {
                                case .overview: overviewContent
                                case .connection: connectionPage
                                case .history: historyContent
                                case .accounts: accountsContent
                                case .settings: selectedTabContent.frame(maxWidth: 640).frame(maxWidth: .infinity, alignment: .top)
                                }
                            }.padding(12)
                        }
                        .onAppear {
                            if handledAccountNavigationVersion != store.accountNavigationVersion {
                                handledAccountNavigationVersion = store.accountNavigationVersion
                                section = .accounts
                            }
                            if store.accounts.isEmpty { section = .accounts }
                            store.rediscoverTools(); scrollToSelected(proxy)
                        }
                        .onChange(of: store.accountNavigationVersion) { _, _ in
                            handledAccountNavigationVersion = store.accountNavigationVersion
                            section = .accounts
                            scrollToSelected(proxy)
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider().opacity(0.4)
            HStack {
                Label("Stored on this Mac", systemImage: "lock.shield").foregroundStyle(.secondary)
                Spacer()
                Button("Show menu", action: showMenu)
                Text(AppUpdater.versionLabel).foregroundStyle(.tertiary)
                Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power").frame(width: 26, height: 26) }.buttonStyle(QuietButtonStyle()).help("Quit Ai-llowance")
            }.font(.system(size: 10)).padding(.horizontal, 14).padding(.vertical, 6)
        }.frame(minWidth: 760, minHeight: 480).controlSize(.regular).background { if section == .settings { Color(nsColor: .windowBackgroundColor) } else { WorkspaceBackground() } }.preferredColorScheme(store.menuPreferences.theme.colorScheme)
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
    }
    private var dashboardNavigation: some View {
        HStack(spacing: 6) {
            BrandIcon(size: 23)
            Text("Ai-llowance").font(.system(size: 12, weight: .semibold)).padding(.trailing, 6)
            ForEach([DashboardSection.history, .overview, .settings]) { item in
                Button { section = item } label: {
                    Label(item == .history ? "Usage" : item == .overview ? "Accounts" : "Settings",
                          systemImage: item == .history ? "chart.xyaxis.line" : item == .overview ? "square.grid.2x2" : "gearshape")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8).frame(height: 28)
                        .foregroundStyle(section == item || (item == .overview && (section == .accounts || section == .connection)) ? Color.primary : .secondary)
                        .background(section == item || (item == .overview && (section == .accounts || section == .connection)) ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
            Spacer(minLength: 4)
            if section == .history {
                Picker("Account", selection: $historyAccountID) {
                    Text("All accounts").tag(nil as UUID?)
                    ForEach(store.accounts) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().frame(width: 120)
                Button { section = .accounts } label: { Image(systemName: "slider.horizontal.3").frame(width: 26, height: 28) }
                    .buttonStyle(QuietButtonStyle()).help("Manage accounts").accessibilityLabel("Manage accounts")
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
    private var settingsTabs: some View {
        Picker("Settings", selection: $selectedTab) {
            ForEach([SettingsTab.behavior, .menuBar, .updates, .advanced]) { tab in Text(tab.title).tag(tab) }
        }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 480)
    }
    @ViewBuilder private var selectedTabContent: some View {
        if store.demo { Text("Sample accounts · sign-in is disabled").font(.caption).foregroundStyle(.orange) }
        switch selectedTab {
        case .accounts: accountsContent
        case .menuBar: menuBarSettings
        case .behavior: behaviorSettings
        case .updates: UpdateSettings(updater: store.updater)
        case .advanced:
            VStack(alignment: .leading, spacing: 12) {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 11) {
                        Label("Advanced connections", systemImage: "slider.horizontal.3").font(.system(size: 13, weight: .semibold))
                        Text("For API keys, additional providers, or a custom CLI location.").font(.system(size: 10)).foregroundStyle(.secondary)
                        connectionForm
                    }
                }
                moreConnections
            }
        }
    }
    @ViewBuilder private var accountsContent: some View {
            HStack {
                Button { section = .history } label: { Label("All accounts", systemImage: "chevron.left") }.buttonStyle(QuietButtonStyle())
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
    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Connect a service").font(.system(size: 15, weight: .semibold))
                Spacer()
                agentHelpMenu.fixedSize()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 340), spacing: 10)], spacing: 10) {
                ForEach([ConnectionKind.claudeCode, .codex, .copilot, .openAIAPI, .claudeAPI, .openRouter, .vercelGateway, .xai], id: \.self) { kind in
                    connectionTile(kind)
                }
            }
            setupProgress
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
                HStack(spacing: 6) {
                    Text(accounts.isEmpty ? "Not connected" : "\(accounts.count) account\(accounts.count == 1 ? "" : "s") added")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if !accounts.isEmpty {
                        Button(recommended != nil && !kind.isAPI ? "Open" : "Manage") {
                            if let recommended, !kind.isAPI { store.useAccount(recommended) }
                            else { section = .accounts }
                        }.controlSize(.small).disabled(store.demo)
                        Button { connectService(kind) } label: { Image(systemName: "plus") }
                            .controlSize(.small).help("Add another \(title) account")
                            .accessibilityLabel("Add another \(title) account")
                            .disabled(busyConnecting || store.demo)
                    } else {
                        Button("Connect") { connectService(kind) }
                            .controlSize(.small).disabled(busyConnecting || store.demo)
                    }
                }
            }
        }
    }
    private func connectService(_ kind: ConnectionKind) {
        selectedKind = kind
        secret = ""; scopeID = ""; name = ""; connectionError = nil
        manualConnection = false
        setupStarted = false
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
                        setupStarted = true
                        if selectedKind == .claudeCode { store.connectClaude(existing: !existing) }
                        else { store.connectOpenAI(existing: !existing) }
                    } else if selectedKind == .copilot { store.connectCopilot() }
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
            DisclosureGroup("Manual setup & advanced options", isExpanded: $manualConnection) {
                connectionForm.padding(.top, 12)
            }.font(.system(size: 12)).padding(16)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        }.frame(maxWidth: 520).frame(maxWidth: .infinity).padding(.top, 8)
    }
    @ViewState private var historyWidth: CGFloat = 800
    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.accounts.isEmpty { Text("Connect an account to start collecting history.").foregroundStyle(.secondary) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: min(4, max(1, Int((historyWidth + 16) / 280)))), spacing: 12) {
            ForEach(store.accounts.filter { historyAccountID == nil || $0.id == historyAccountID }) { account in
                let points = store.history(for: account).filter { $0.timestamp >= store.now.addingTimeInterval(-Double(historyHours) * 3600) }
                HistoryCard(account: account, points: points, snapshot: store.snapshots[account.id],
                            error: store.errors[account.id] != nil, cached: store.isCached(account), now: store.now,
                            openUsage: { store.openUsage(account) }, manage: { renaming = account })
            }
            }
            ActivityHeatmap(accounts: store.accounts.filter { historyAccountID == nil || $0.id == historyAccountID },
                            histories: Dictionary(uniqueKeysWithValues: store.accounts.map { ($0.id, store.history(for: $0)) }), now: store.now)
        }.background(GeometryReader { geometry in
            Color.clear.onAppear { historyWidth = geometry.size.width }
                .onChange(of: geometry.size.width) { _, width in historyWidth = width }
        }).onChange(of: store.accounts.map(\.id)) { _, ids in
            if let selected = historyAccountID, !ids.contains(selected) { historyAccountID = nil }
        }
    }
    private var busyConnecting: Bool { store.connectingClaude || store.signingIn != nil || !store.waitingForClaude.isEmpty }
    private var setupAccount: Account? { store.accounts.last { $0.kind == selectedKind } }
    private var connectionSetup: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Connect your first account", systemImage: "person.crop.circle.badge.plus").font(.system(size: 14, weight: .semibold))
                Text("Choose the coding assistant you already use. We’ll check its local sign-in and show your usage.").font(.system(size: 11)).foregroundStyle(.secondary)
                simpleProviderButton(.claudeCode)
                simpleProviderButton(.codex)
                setupProgress
                agentHelpMenu
                Button("Other providers, API keys, or CLI setup…") { section = .settings; selectedTab = .advanced }
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
                Button("More providers and API keys…") { section = .settings; selectedTab = .advanced }
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
            guard installed else { NSWorkspace.shared.open(installationURL(kind)); return }
            section = .accounts
            selectedKind = kind
            setupStarted = true
            if kind == .claudeCode { store.connectClaude(existing: !existing) }
            else { store.connectOpenAI(existing: !existing) }
        } label: {
            HStack(spacing: 10) {
                ProviderMark(provider: kind.provider, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(installed ? (existing ? "Add another \(kind.provider.title) account" : "Connect \(kind.provider.title)") : "Install \(cliName(kind))")
                        .font(.system(size: 12, weight: .semibold))
                    Text(installed ? "Use your existing subscription sign-in · no API key" : "One-time setup · then return here")
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
            if let account = store.accounts.last(where: { $0.kind == selectedKind }), store.errors[account.id] == nil, !store.isCached(account), let snapshot = store.snapshots[account.id], !snapshot.isStale(at: store.now), snapshot.providerRestricted != true {
                HStack {
                    Label("First reading received · \(account.expectedIdentity ?? snapshot.identity ?? account.name)", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(.green).lineLimit(2)
                    Spacer()
                    Button("View account") { store.selectedAccountID = account.id }.controlSize(.small)
                }
            }
        }.disabled(store.demo)
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
                        Button("Use existing Claude sign-in") { store.connectClaude(existing: true) }
                            .disabled(store.accounts.contains { $0.kind == .claudeCode && $0.usesExistingClaude == true })
                        Button("Add another account") { store.connectClaude(existing: false) }
                    }.controlSize(.small).disabled(busyConnecting)
                } else if selectedKind == .codex {
                    HStack {
                        Button("Use existing Codex sign-in") { store.connectOpenAI(existing: true) }.disabled(store.accounts.contains { $0.usesExistingCodex })
                        Button("Add another account") { store.connectOpenAI() }
                    }.controlSize(.small).disabled(busyConnecting)
                } else if selectedKind == .copilot {
                    HStack {
                        Button("Connect Copilot (preview)") { store.connectCopilot() }.disabled(busyConnecting || store.accounts.contains { $0.kind == .copilot })
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
                Text("Use a Management API key, not a standard model API key. Grok subscriptions aren’t supported.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if selectedKind != .xai {
                Text(selectedKind.explanation).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Connect securely") {
                    do {
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
        switch kind { case .claudeCode: store.claudeExecutable; case .codex: store.executable; case .copilot: store.copilotExecutable; default: nil }
    }
    private func chooseExecutable(_ kind: ConnectionKind) {
        switch kind { case .claudeCode: store.chooseClaudeExecutable(); case .codex: store.chooseExecutable(); case .copilot: store.chooseCopilotExecutable(); default: break }
    }
    private func cliName(_ kind: ConnectionKind) -> String { kind == .claudeCode ? "Claude Code" : kind == .copilot ? "Copilot CLI" : "Codex CLI" }
    private func installationURL(_ kind: ConnectionKind) -> URL {
        switch kind {
        case .claudeCode: URL(string: "https://code.claude.com/docs/en/setup")!
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
                        AccountReading(account: account, snapshot: store.snapshots[account.id], error: store.errors[account.id], now: store.now, cached: store.isCached(account))
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
                if store.needsSignIn(account) && store.signingIn != account.id && store.waitingForClaude[account.id] == nil {
                    if account.kind.isAPI { Button("Replace key") { replacement = ""; keyAccount = account } }
                    else if account.kind == .claudeCode { Button("Sign in") { store.openClaude(account, login: true) } }
                    else if account.kind == .codex && !account.usesExistingCodex { Button("Sign in with this account") { store.signIn(account, openBrowser: false) }.disabled(busyConnecting) }
                    else if account.kind == .copilot {
                        Button("Sign in to Copilot…") { store.openCopilotSignIn() }
                        Button("Check sign-in") { store.retryConnection(account) }
                    } else { Button("Check Codex sign-in") { store.retryConnection(account) }.help("Sign in through Codex CLI, then check again.") }
                } else if store.errors[account.id] != nil {
                    Button("Retry connection") { store.retryConnection(account) }.disabled(store.refreshing)
                } else { Button("Open usage ↗") { store.openUsage(account) } }
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
            GroupBox("Startup") {
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
                }.padding(10)
            }
            GroupBox("Usage monitoring") {
                VStack(spacing: 12) {
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
                }.padding(10)
            }
            HStack {
                Link("Submit Feedback…", destination: URL(string: "https://github.com/jamesatFRM/Ai-llowance/issues/new")!)
                Spacer()
                Text("Ai-llowance " + AppUpdater.version).foregroundStyle(.secondary)
            }
        }.font(.system(size: 13)).toggleStyle(.switch).controlSize(.regular).disabled(store.demo)
    }
    private var moreConnections: some View {
        SettingsCard {
            DisclosureGroup("More tools & diagnostics") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Manual usage links").font(.system(size: 11, weight: .medium))
                        Spacer()
                        Link("Cursor ↗", destination: URL(string: "https://www.cursor.com/dashboard")!)
                        Link("Gemini ↗", destination: URL(string: "https://aistudio.google.com/usage")!)
                    }.font(.system(size: 11))
                    Text("These links open provider dashboards; automatic quota tracking is not connected.").font(.system(size: 10)).foregroundStyle(.secondary)
                    Divider().opacity(0.4)
                    HStack {
                        Button("Find installed tools") { store.rediscoverTools() }
                        Button("Choose Codex…") { store.chooseExecutable() }
                        Button("Choose Claude…") { store.chooseClaudeExecutable() }
                        Button("Choose Copilot…") { store.chooseCopilotExecutable() }
                    }.controlSize(.small).font(.system(size: 10))
                    Text((AppUpdater.isPreview ? "Preview release · not notarized. " : "") + "No Ai-llowance analytics or backend.").font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(.top, 10)
            }.font(.system(size: 12, weight: .medium))
        }.disabled(store.demo)
    }
    private var menuBarSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
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
                    Toggle("Show detailed quota labels", isOn: Binding(get: { store.menuPreferences.detailedQuotaLabels }, set: { store.setDetailedQuotaLabels($0) }))
                }.padding(10)
            }
            GroupBox("Menu bar") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Display")
                        Spacer()
                        Picker("Display", selection: Binding(get: { store.menuPreferences.display }, set: { store.setMenuDisplay($0) })) {
                            ForEach(MenuDisplay.allCases) { mode in Text(mode.title).tag(mode) }
                        }.labelsHidden().frame(width: 190)
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
                    Toggle("Color by remaining allowance", isOn: Binding(get: { store.menuPreferences.colorByAllowance }, set: { store.setColorByAllowance($0) }))
                    Text("White at 100%, cool colors through the middle, red at 0%. Overrides custom menu colors for percentages.")
                        .font(.callout).foregroundStyle(.secondary)
                    Divider()
                    Toggle("Include all accounts", isOn: Binding(get: { store.menuPreferences.allAccounts }, set: { store.setAllMenuAccounts($0) }))
                    if !store.menuPreferences.allAccounts {
                        ForEach(store.accounts.filter { !$0.kind.isAPI || $0.kind.isBalance }) { account in
                            Toggle(account.name, isOn: Binding(get: { store.menuPreferences.selectedAccountIDs.contains(account.id) }, set: { store.setMenuAccount(account, included: $0) })).toggleStyle(.checkbox)
                        }
                    }
                    Text("API credit balances appear as dollar amounts.").font(.callout).foregroundStyle(.secondary)
                }.padding(10)
            }
        }.font(.system(size: 13)).toggleStyle(.switch).controlSize(.regular).disabled(store.demo)
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
        GroupBox("Software Update") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Updates", systemImage: "arrow.down.circle").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(AppUpdater.version).font(.system(size: 13)).foregroundStyle(.secondary)
                    Button("Check for Updates…") { updater.check() }.disabled(!updater.canCheck).controlSize(.regular)
                }
                Toggle("Automatically check for updates", isOn: Binding(get: { updater.automaticChecks }, set: { updater.setAutomaticChecks($0) }))
                    .toggleStyle(.switch).controlSize(.regular).font(.system(size: 13)).disabled(!updater.canCheck)
                Text("Updates install when you choose. Your accounts stay on this Mac.").font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(10)
        }
    }
}

private struct HistoryCard: View {
    let account: Account
    let points: [UsageHistoryPoint]
    let snapshot: Snapshot?
    let error: Bool
    let cached: Bool
    let now: Date
    var openUsage: () -> Void
    var manage: () -> Void
    private var status: AllowanceStatus { AllowanceStatus.evaluate(snapshot: snapshot, kind: account.kind, now: now, hasError: error) }
    private var statusColor: Color {
        if !account.enabled || cached { return .secondary }
        switch status.state {
        case .ready, .unlimited: return Color(red: 0.23, green: 0.78, blue: 0.61)
        case .low, .exhausted, .restricted: return .orange
        default: return .secondary
        }
    }
    private var graphTint: Color { NSColor.accountHex(account.graphColorHex).map { Color(nsColor: $0) } ?? providerAccent(account.kind.provider) }
    private var dashboardTint: Color { NSColor.accountHex(account.dashboardColorHex).map { Color(nsColor: $0) } ?? providerAccent(account.kind.provider) }
    private var metric: String { account.kind.isBalance ? "Balance (USD)" : account.kind.isAPI ? "Month-to-date spending (USD)" : "Limiting allowance remaining (%)" }
    private func value(_ point: UsageHistoryPoint) -> Double? {
        if account.kind.isBalance { return point.balanceUSD.map { NSDecimalNumber(decimal: $0).doubleValue } }
        if account.kind.isAPI { return point.costUSD.map { NSDecimalNumber(decimal: $0).doubleValue } }
        return point.remainingPercent
    }
    private var plotted: [UsageHistoryPoint] { points.filter { value($0) != nil } }
    private var samples: [HistorySample] { HistorySeries.samples(points, kind: account.kind) }
    var body: some View {
        let series = samples
        let segmentCounts = Dictionary(grouping: series, by: \.segment).mapValues(\.count)
        SettingsCard(inset: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ProviderMark(provider: account.kind.provider, size: 16).foregroundStyle(dashboardTint)
                    Text(account.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(dashboardTint)
                    Spacer()
                    Image(systemName: !account.enabled ? "pause.circle" : cached ? "clock" : status.symbol)
                        .foregroundStyle(statusColor).help(!account.enabled ? "Paused" : cached ? "Saved reading" : status.title)
                }
                Text(account.expectedIdentity ?? account.kind.title)
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack(alignment: .firstTextBaseline) {
                    Text(readingValue(snapshot, window: snapshot?.limitingWindow(for: account.kind)))
                        .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(error || cached || status.state == .stale || !account.enabled ? Color.secondary : Color.primary)
                    Spacer(minLength: 4)
                    Text(!account.enabled ? "Paused" : cached ? "Saved reading" : status.title)
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(statusColor).lineLimit(1)
                }
                Text(status.resetText(at: now) ?? (account.kind.isAPI ? metric : "Current allowance"))
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                if plotted.isEmpty {
                    Text("No readings in this range yet. History grows as this Mac refreshes your accounts.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 66)
                } else {
                    Chart {
                        ForEach(series) { sample in
                            AreaMark(x: .value("Time", sample.timestamp), yStart: .value("Baseline", 0), yEnd: .value(metric, sample.value), series: .value("Period", sample.segment))
                                .foregroundStyle(LinearGradient(colors: [graphTint.opacity(0.12), graphTint.opacity(0)], startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.monotone)
                            LineMark(x: .value("Time", sample.timestamp), y: .value(metric, sample.value), series: .value("Period", sample.segment))
                                .foregroundStyle(LinearGradient(colors: [graphTint.opacity(0.75), graphTint], startPoint: .leading, endPoint: .trailing))
                                .lineStyle(StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round))
                                .interpolationMethod(.monotone)
                            if sample.id == series.last?.id || segmentCounts[sample.segment] == 1 {
                                PointMark(x: .value("Time", sample.timestamp), y: .value(metric, sample.value))
                                    .foregroundStyle(graphTint).symbolSize(sample.id == series.last?.id ? 38 : 12)
                            }
                        }
                    }
                    .chartYScale(domain: account.kind.isAPI ? .automatic : .automatic(includesZero: true))
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) {
                            AxisGridLine().foregroundStyle(Color.primary.opacity(0.035))
                            AxisValueLabel(format: .dateTime.day().hour(.defaultDigits(amPM: .abbreviated)))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 3)) {
                            AxisGridLine().foregroundStyle(Color.primary.opacity(0.055))
                            AxisValueLabel()
                        }
                    }
                    .frame(height: 66).padding(.top, 2)
                    if let last = plotted.last {
                        HStack {
                            Text("History")
                            Spacer()
                            Text(last.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute())
                        }.font(.system(size: 10)).foregroundStyle(.secondary)
                    }

                }
                HStack(spacing: 8) {
                    Button(action: openUsage) { Label("Open usage", systemImage: "arrow.up.right").frame(maxWidth: .infinity).frame(height: 24) }
                    Button(action: manage) { Image(systemName: "slider.horizontal.3").frame(width: 28, height: 24) }.help("Name & color").accessibilityLabel("Edit " + account.name)
                }.font(.system(size: 11, weight: .medium)).buttonStyle(QuietButtonStyle())
            }
        }
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
        SettingsCard(inset: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Work rhythm", systemImage: "square.grid.3x3.fill").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("Last 7 days · " + (calendar.timeZone.abbreviation() ?? calendar.timeZone.identifier)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Grid(horizontalSpacing: 4, verticalSpacing: 2) {
                    GridRow {
                        Color.clear.frame(width: 62, height: 12)
                        ForEach(0..<24) { hour in
                            Text(hour % 6 == 0 ? String(format: "%02d", hour) : "")
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
                    Text("Allowance use · outlined = unmeasured").help("Recorded subscription allowance consumption, not coding hours. Gaps and resets are excluded; API spending is not mixed in.")
                }.font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
    private func heatmapCell(day: Date, hour: Int, buckets: [Date: Double], peak: Double) -> some View {
                                let matching = buckets.filter { calendar.isDate($0.key, inSameDayAs: day) && calendar.component(.hour, from: $0.key) == hour }
                                let value: Double? = matching.isEmpty ? nil : matching.values.reduce(0, +)
                                let strength = value.map { peak > 0 ? sqrt($0 / peak) : 0 } ?? 0
                                return RoundedRectangle(cornerRadius: 3)
                                    .fill(value == nil ? Color.primary.opacity(0.025) : Brand.cyan.opacity(0.12 + strength * 0.88))
                                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(value == nil ? 0.08 : 0), lineWidth: 0.5))
                                    .frame(maxWidth: .infinity).frame(height: 12)
                                    .help("\(day.formatted(date: .abbreviated, time: .omitted)) · \(hour):00 · " + (value.map { String(format: "%.1f allowance percentage points consumed", $0) } ?? "No measured interval"))
                                    .accessibilityLabel("\(day.formatted(date: .abbreviated, time: .omitted)), hour \(hour), " + (value.map { String(format: "%.1f allowance points consumed", $0) } ?? "Not measured"))
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
