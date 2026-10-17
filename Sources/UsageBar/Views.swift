import SwiftUI
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
                    LinearGradient(colors: [Color.accentColor.opacity(0.045), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 150)
                }
        }
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
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(tint.opacity(0.045))
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
    var manage: () -> Void
    @ViewState private var expandedAccountID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text("Ai-llowance").font(.system(size: 12, weight: .semibold, design: .rounded))
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
                    .scrollIndicators(.hidden).fixedSize(horizontal: false, vertical: true).frame(maxHeight: 500)
            }
            if let notice = store.notice { Text(notice).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2).padding(.horizontal, 9) }
            HStack(spacing: 5) {
                Button(action: manage) { Label("Settings", systemImage: "gearshape").padding(.horizontal, 5).frame(height: 22) }
                    .buttonStyle(QuietButtonStyle()).help("Settings")
                Spacer()
                Text(AppUpdater.versionLabel).monospacedDigit().foregroundStyle(.secondary).padding(.trailing, 3)
                UpdateCheckButton(updater: store.updater)
                Button { store.togglePause() } label: { Image(systemName: store.paused ? "play.fill" : "pause.fill").frame(width: 22, height: 22) }
                    .help(store.paused ? "Resume automatic refresh" : "Pause automatic refresh")
                    .accessibilityLabel(store.paused ? "Resume automatic refresh" : "Pause automatic refresh").disabled(store.demo)
                Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power").frame(width: 22, height: 22) }
                    .help("Quit Ai-llowance").accessibilityLabel("Quit Ai-llowance")
            }.font(.system(size: 10)).buttonStyle(QuietButtonStyle()).foregroundStyle(.secondary).padding(.horizontal, 9).padding(.bottom, 3)
        }.padding(7).frame(width: 350).background(PanelBackground()).preferredColorScheme(store.menuPreferences.theme.colorScheme)
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
                                history: expandedAccountID == account.id ? store.history(for: account) : [],
                                expand: { expandedAccountID = expandedAccountID == account.id ? nil : account.id },
                                manage: { manage(account) }, openUsage: { store.openUsage(account) })
                            if account.id != accounts.last?.id { Divider().opacity(0.35).padding(.leading, 21).padding(.vertical, 4) }
                        }
                    }.padding(.horizontal, 11).padding(.vertical, 9)
                        .modifier(InsetSurface())
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
        if let window { return "\(shortWindowLabel(window)) · \(resetText(window.resetsAt, at: now))" }
        return snapshot == nil ? "Waiting for first reading" : "Quota unavailable"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: expand) {
                VStack(spacing: 4) {
                    HStack(spacing: 7) {
                        ProviderMark(provider: account.kind.provider, size: 14)
                        Text(account.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 5)
                        Text(readingValue(snapshot, window: window)).font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(error != nil || cached || status.state == .stale || !account.enabled ? .secondary : .primary)
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
                        HistorySparkline(points: history)
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
    private var series: [(Date, Double)] {
        let hasQuota = points.contains { $0.remainingPercent != nil }
        let hasBalance = points.contains { $0.balanceUSD != nil }
        return points.compactMap { point in
            let value: Double?
            if hasQuota { value = point.remainingPercent }
            else if hasBalance { value = point.balanceUSD.map { NSDecimalNumber(decimal: $0).doubleValue } }
            else { value = point.costUSD.map { NSDecimalNumber(decimal: $0).doubleValue } }
            return value.map { (point.timestamp, $0) }
        }
    }
    private var values: [Double] { series.map { $0.1 } }
    var body: some View {
        if values.count >= 2 {
            VStack(alignment: .leading, spacing: 3) {
                SparklineShape(values: values, dates: series.map { $0.0 }).stroke(Color.accentColor.opacity(0.75), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)).frame(height: 26)
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
    func path(in rect: CGRect) -> Path {
        guard values.count > 1, let low = values.min(), let high = values.max() else { return Path() }
        let range = max(high - low, 1)
        var path = Path()
        for (index, value) in values.enumerated() {
            let duration = (dates.last ?? .distantPast).timeIntervalSince(dates.first ?? .distantPast)
            let position = dates.count == values.count && duration > 0 ? dates[index].timeIntervalSince(dates[0]) / duration : Double(index) / Double(values.count - 1)
            let point = CGPoint(x: CGFloat(position) * rect.width, y: rect.midY - CGFloat((value - (high + low) / 2) / range) * max(0, rect.height - 4))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .modifier(InsetSurface(cornerRadius: 12))
    }
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
    @ViewState private var name = ""
    @ViewState private var secret = ""
    @ViewState private var scopeID = ""
    @ViewState private var connectionError: String?
    @ViewState private var addingConnection = false
    @ViewState private var onboarding = false
    @ViewState private var removing: Account?
    @ViewState private var renaming: Account?
    @ViewState private var newName = ""
    @ViewState private var keyAccount: Account?
    @ViewState private var replacement = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary).frame(width: 42, height: 42).modifier(InsetSurface())
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.accounts.isEmpty ? "Welcome to Ai-llowance" : "Settings").font(.system(size: 21, weight: .semibold, design: .rounded))
                    Text(store.accounts.isEmpty ? "Connect once. Know what’s left." : "Your accounts. Your menu bar.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if store.refreshing { ProgressView().controlSize(.small) }
                Text(store.refreshSummary).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Button { store.rediscoverTools(); store.refresh(force: true) } label: { Image(systemName: "arrow.clockwise").frame(width: 26, height: 26) }
                    .buttonStyle(QuietButtonStyle()).help("Refresh accounts").accessibilityLabel("Refresh accounts").disabled(store.demo || store.paused || store.refreshing)
            }.padding(.horizontal, 22).padding(.vertical, 18)
            Divider().opacity(0.4)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if store.demo { Text("Sample accounts · sign-in is disabled").font(.caption).foregroundStyle(.orange) }
                        if store.accounts.isEmpty || onboarding { connectionSetup }
                        ForEach(MenuProvider.allCases, id: \.self) { provider in
                            if store.accounts.contains(where: { $0.kind.provider == provider }) { accountSection(provider) }
                        }
                        if !store.accounts.isEmpty && !onboarding {
                            SettingsCard {
                                DisclosureGroup(isExpanded: $addingConnection) { connectionForm.padding(.top, 12) } label: {
                                    Label("Add a connection", systemImage: "plus.circle").font(.system(size: 13, weight: .semibold))
                                }
                            }
                        }
                        behaviorSettings
                        DisclosureGroup("Menu bar & appearance") { menuBarSettings.padding(.top, 8) }.font(.system(size: 12, weight: .medium))
                        UpdateSettings(updater: store.updater)
                        moreConnections
                        if let notice = store.notice { Label(notice, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                    }.padding(22)
                }
                .onAppear { if store.accounts.isEmpty { onboarding = true }; store.rediscoverTools(); scrollToSelected(proxy) }
                .onChange(of: store.selectedAccountID) { _, _ in scrollToSelected(proxy) }
                .onChange(of: onboarding) { _, _ in scrollToSelected(proxy) }
            }
            Divider().opacity(0.4)
            HStack {
                Label("Stored on this Mac", systemImage: "lock.shield").foregroundStyle(.secondary)
                Spacer()
                Button("Show menu", action: showMenu)
                Text(AppUpdater.versionLabel).foregroundStyle(.tertiary)
                Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power").frame(width: 26, height: 26) }.buttonStyle(QuietButtonStyle()).help("Quit Ai-llowance")
            }.font(.system(size: 10)).padding(.horizontal, 22).padding(.vertical, 12)
        }.frame(minWidth: 580, minHeight: 560).background(PanelBackground()).preferredColorScheme(store.menuPreferences.theme.colorScheme)
        .alert("Remove \(removing?.name ?? "account")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) { if let account = removing { Task { await store.remove(account) } }; removing = nil }
        } message: {
            Text("The connection and its app-owned key or OpenAI sign-in will be removed. Existing CLI sign-ins are kept. For Claude, use Sign out in Terminal first if you also want to clear that login.")
        }
        .sheet(item: $renaming) { account in
            VStack(alignment: .leading, spacing: 16) {
                Text("Rename account").font(.headline)
                TextField("Account name", text: $newName).textFieldStyle(.roundedBorder)
                HStack { Button("Cancel") { renaming = nil }; Spacer(); Button("Save") { store.rename(account, to: newName); renaming = nil }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 340)
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
    private func scrollToSelected(_ proxy: ScrollViewProxy) {
        guard !onboarding, let id = store.selectedAccountID else { return }
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) }
    }
    private var busyConnecting: Bool { store.connectingClaude || store.signingIn != nil || !store.waitingForClaude.isEmpty }
    private var setupAccount: Account? { store.accounts.last { $0.kind == selectedKind } }
    private var setupStep: Int {
        guard let account = setupAccount else { return 1 }
        guard let snapshot = store.snapshots[account.id], !store.isCached(account), store.errors[account.id] == nil,
              !snapshot.isStale(at: store.now), snapshot.providerRestricted != true else { return 2 }
        return 3
    }
    private var connectionSetup: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Connect your first account", systemImage: "person.crop.circle.badge.plus").font(.system(size: 14, weight: .semibold))
                HStack(spacing: 14) {
                    Label("Choose", systemImage: setupStep > 1 ? "checkmark.circle" : "1.circle.fill")
                    Label("Connect", systemImage: setupStep > 2 ? "checkmark.circle" : setupStep == 2 ? "2.circle.fill" : "2.circle")
                    Label("First reading", systemImage: setupStep == 3 ? "checkmark.circle.fill" : "3.circle")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                connectionForm
            }
        }
    }
    private var connectionForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ProviderMark(provider: selectedKind.provider, size: 19)
                Picker("Service", selection: $selectedKind) {
                    ForEach(ConnectionKind.allCases) { kind in Text(kind.title).tag(kind) }
                }.labelsHidden()
            }
            .disabled(busyConnecting)
            .onChange(of: selectedKind) { _, _ in secret = ""; scopeID = ""; name = ""; connectionError = nil; store.rediscoverTools() }
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
                    if onboarding { Button("Done") { onboarding = false; showMenu() }.controlSize(.small) }
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
            TextField("Account label (optional)", text: $name).textFieldStyle(.roundedBorder)
            SecureField(keyLabel(selectedKind), text: $secret).textFieldStyle(.roundedBorder)
            if selectedKind == .xai {
                TextField("xAI team ID", text: $scopeID).textFieldStyle(.roundedBorder)
                Text("Prepaid API credits · beta. Requires a team Management API key; a standard model API key or Grok subscription will not work.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(selectedKind.explanation).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                        accountActions(account)
                        DisclosureGroup("Details & link preferences") {
                            VStack(alignment: .leading, spacing: 10) {
                                HistorySparkline(points: store.history(for: account))
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
                    Button("Rename account") { newName = account.name; renaming = account }
                    Button(account.enabled ? "Pause account" : "Resume account") { store.toggle(account) }
                    Button("Remove account", role: .destructive) { removing = account }.disabled(store.refreshing || store.removing || busyConnecting)
                } label: { Image(systemName: "ellipsis").frame(width: 22, height: 18) }
                    .menuStyle(.borderlessButton).frame(width: 26).help("\(account.name) options").accessibilityLabel("\(account.name) options")
            }
        }.font(.system(size: 11)).controlSize(.small).disabled(store.demo)
    }
    private var behaviorSettings: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: Binding(get: { store.notificationsEnabled }, set: { store.setNotificationsEnabled($0) })) {
                    Label("Quiet allowance alerts", systemImage: "bell.badge").font(.system(size: 12, weight: .medium))
                }.toggleStyle(.switch).controlSize(.small)
                Text("Low, empty, and available again. Only meaningful changes, grouped across accounts.").font(.system(size: 10)).foregroundStyle(.secondary)
                Divider().opacity(0.4)
                Toggle(isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) })) {
                    Label("Launch at login", systemImage: "sunrise").font(.system(size: 12, weight: .medium))
                }.toggleStyle(.switch).controlSize(.small)
                if store.loginItemNeedsApproval {
                    Link("Allow Ai-llowance in Login Items ↗", destination: URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                        .font(.system(size: 10))
                }
            }
        }.disabled(store.demo)
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
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Appearance").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Picker("Appearance", selection: Binding(get: { store.menuPreferences.theme }, set: { store.setTheme($0) })) {
                        ForEach(AppTheme.allCases) { theme in Text(theme.title).tag(theme) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 240)
                }
                Divider().opacity(0.4)
                HStack {
                    Label("Menu bar", systemImage: "menubar.rectangle").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("Quota remaining").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    if store.menuEntries.isEmpty { Label("Usage", systemImage: "gauge.with.dots.needle.33percent") }
                    ForEach(Array(store.menuEntries.enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 5) {
                            ProviderMark(provider: entry.provider)
                            if store.menuPreferences.display == .byAccount && store.menuPreferences.showAccountNames { Text(entry.label).lineLimit(1) }
                            Text(entry.isUnlimited ? "∞" : (entry.remainingPercent.map { "\(Int($0))%" } ?? "0%!")).monospacedDigit()
                        }.accessibilityLabel("\(entry.label): \(entry.isUnlimited ? "unlimited allowance" : (entry.remainingPercent.map { "\(Int($0)) percent quota remaining" } ?? "unavailable"))")
                    }
                    Spacer(minLength: 0)
                }.font(.system(size: 12, weight: .medium)).padding(10)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                Picker("Display", selection: Binding(get: { store.menuPreferences.display }, set: { store.setMenuDisplay($0) })) {
                    ForEach(MenuDisplay.allCases) { mode in Text(mode.title).tag(mode) }
                }.pickerStyle(.segmented).labelsHidden()
                if store.menuPreferences.display == .byAccount {
                    Toggle("Show account names", isOn: Binding(get: { store.menuPreferences.showAccountNames }, set: { store.setShowAccountNames($0) }))
                        .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
                    Text("Turn off for just icons and percentages. Hover over the menu bar to identify accounts.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Combine using").font(.system(size: 11)).foregroundStyle(.secondary)
                    Picker("Combine using", selection: Binding(get: { store.menuPreferences.aggregation }, set: { store.setMenuAggregation($0) })) {
                        ForEach(MenuAggregation.allCases) { aggregation in Text(aggregation.title).tag(aggregation) }
                    }.labelsHidden().frame(width: 190).disabled(store.menuPreferences.display == .byAccount)
                    Spacer()
                    Toggle("All accounts", isOn: Binding(get: { store.menuPreferences.allAccounts }, set: { store.setAllMenuAccounts($0) }))
                        .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
                }
                if !store.menuPreferences.allAccounts {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(store.accounts.filter { !$0.kind.isAPI }) { account in
                            Toggle(isOn: Binding(get: { store.menuPreferences.selectedAccountIDs.contains(account.id) }, set: { store.setMenuAccount(account, included: $0) })) {
                                HStack {
                                    Text(account.name)
                                    if let email = store.snapshots[account.id]?.identity { Text(email).foregroundStyle(.secondary).lineLimit(1) }
                                    if !account.enabled { Text("Paused").foregroundStyle(.secondary) }
                                }.font(.system(size: 11))
                            }.toggleStyle(.checkbox)
                        }
                    }
                }
                Text("Averages give each selected account equal weight. Accounts keep separate allowances; percentages are not pooled credits.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider().opacity(0.4)
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Automatic refresh").font(.system(size: 12, weight: .medium))
                        Text("Adapts to activity and provider limits.").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Automatic refresh", isOn: Binding(get: { !store.paused }, set: { if $0 == store.paused { store.togglePause() } }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
        }.disabled(store.demo)
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
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("Updates", systemImage: "arrow.down.circle").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(AppUpdater.version).font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Check for Updates…") { updater.check() }.disabled(!updater.canCheck).controlSize(.small)
                }
                Toggle("Automatically check for updates", isOn: Binding(get: { updater.automaticChecks }, set: { updater.setAutomaticChecks($0) }))
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11)).disabled(!updater.canCheck)
                Text("Updates install when you choose. Your accounts stay on this Mac.").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}
