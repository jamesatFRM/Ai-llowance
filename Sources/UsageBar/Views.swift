import SwiftUI
import AppKit
import UsageCore

// Explicit wrapper alias avoids the newer SDK State macro; remains compatible with macOS 14.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct Dashboard: View {
    @ObservedObject var store: AppStore
    var renderForSharing = false
    var manage: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text("Ai-llowance").font(.system(size: 12, weight: .semibold))
                Spacer()
                if store.refreshing { ProgressView().controlSize(.mini) }
                Text(store.refreshSummary)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Button { store.refresh(force: true) } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }
                    .buttonStyle(.plain).help("Refresh (respects provider backoff)")
                    .disabled(store.refreshing || store.paused || store.demo)
            }.padding(.horizontal, 9).padding(.top, 5)
            if store.accounts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No accounts connected").font(.system(size: 12, weight: .semibold))
                    Text("Claude and OpenAI limits, at a glance.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Connect an account", action: manage).controlSize(.small)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            } else {
                if renderForSharing { providerContent }
                else {
                    ScrollView { providerContent }
                        .scrollIndicators(.hidden).fixedSize(horizontal: false, vertical: true).frame(maxHeight: 500)
                }
            }
            if let notice = store.notice { Text(notice).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2).padding(.horizontal, 9) }
            HStack {
                Button(action: manage) { Label("Settings", systemImage: "gearshape") }.help("Settings")
                Spacer()
                Text("Preview · 0.1.0").foregroundStyle(.tertiary)
                Button { store.togglePause() } label: {
                    Image(systemName: store.paused ? "play.fill" : "pause.fill").frame(width: 22, height: 22)
                }.help(store.paused ? "Resume automatic refresh" : "Pause automatic refresh")
                    .accessibilityLabel(store.paused ? "Resume automatic refresh" : "Pause automatic refresh").disabled(store.demo)
                Button { NSApplication.shared.terminate(nil) } label: {
                    Image(systemName: "power").frame(width: 22, height: 22)
                }.help("Quit Ai-llowance").accessibilityLabel("Quit Ai-llowance")
            }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 9).padding(.bottom, 3)
        }.padding(7).frame(width: 350).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(store.menuPreferences.theme.colorScheme)
    }
    private var providerContent: some View {
        VStack(spacing: 9) {
            providerGroups("Claude", subscription: .claudeCode, api: .claudeAPI)
            providerGroups("OpenAI", subscription: .codex, api: .openAIAPI)
        }
    }
    @ViewBuilder
    private func providerGroups(_ name: String, subscription: ConnectionKind, api: ConnectionKind) -> some View {
        let subscriptions = store.accounts.filter { $0.kind == subscription }
        let billing = store.accounts.filter { $0.kind == api }
        if !subscriptions.isEmpty { compactGroup(name, trailing: "Weekly remaining", accounts: subscriptions) }
        if !billing.isEmpty { compactGroup("\(name) API spending", trailing: "This month · UTC", accounts: billing) }
    }
    @ViewBuilder
    private func accountEmail(_ snapshot: Snapshot?) -> some View {
        if let email = snapshot?.identity, !email.isEmpty {
            Text(email).font(.system(size: 9)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle).help(email)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 23).padding(.top, -3).padding(.bottom, 2)
        }
    }
    private func compactGroup(_ title: String, trailing: String, accounts: [Account]) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(title).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(trailing).font(.system(size: 9))
            }.foregroundStyle(.secondary).padding(.bottom, 4)
            ForEach(accounts) { account in
                let snapshot = store.snapshots[account.id]
                let windows = snapshot?.primaryWeeklyWindow(for: account.kind).map { [$0] } ?? []
                if windows.isEmpty {
                    CompactRow(account: account, snapshot: snapshot, window: nil, error: store.errors[account.id], now: store.now, claudeSignedIn: store.claudeSignedIn[account.id], action: manage)
                    accountEmail(snapshot)
                } else {
                    ForEach(windows) { window in
                        CompactRow(account: account, snapshot: snapshot, window: window, error: store.errors[account.id], now: store.now, claudeSignedIn: store.claudeSignedIn[account.id], action: manage)
                        if window.id == windows.first?.id { accountEmail(snapshot) }
                    }
                }
                if let snapshot, let session = snapshot.sessionWindow(for: account.kind) {
                    let staleSession = snapshot.isStale(at: store.now, windows: [session])
                    HStack(spacing: 7) {
                        Text("5h session").fontWeight(.bold).frame(width: 82, alignment: .leading)
                        AllowanceBar(remaining: session.remainingPercent, unavailable: staleSession || store.errors[account.id] != nil || !account.enabled)
                            .frame(width: 42, height: 3)
                        Spacer(minLength: 0)
                        Text(staleSession ? "Waiting for update" : "\(Int(session.remainingPercent))% left").monospacedDigit()
                    }.font(.system(size: 9)).foregroundStyle(.secondary)
                        .padding(.leading, 23).padding(.bottom, 5)
                }
            }
        }.padding(.horizontal, 11).padding(.vertical, 10)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct CompactRow: View {
    let account: Account
    let snapshot: Snapshot?
    let window: QuotaWindow?
    let error: String?
    let now: Date
    let claudeSignedIn: Bool?
    let action: () -> Void
    private var stale: Bool { snapshot?.isStale(at: now, windows: window.map { [$0] } ?? []) ?? false }
    private var detail: String {
        if !account.enabled { return "paused" }
        if account.kind == .claudeCode && snapshot == nil, let claudeSignedIn { return claudeSignedIn ? "refresh" : "sign in" }
        if error != nil { return "check account" }
        if stale { return "stale" }
        if snapshot?.providerRestricted == true { return "Provider limit" }
        guard let window else { return snapshot?.costUSD == nil ? (snapshot == nil ? "no reading" : "Weekly unavailable") : "API cost" }
        guard let reset = window.resetsAt else { return "Reset unknown" }
        return "Resets \(reset.formatted(.dateTime.weekday(.abbreviated)))"
    }
    private var value: String {
        if let window { return "\(Int(window.remainingPercent))% left" }
        if let amount = snapshot?.costUSD { return amount.formatted(.currency(code: "USD")) }
        return "—"
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                ProviderMark(provider: account.kind == .codex || account.kind == .openAIAPI ? .openAI : .claude).frame(width: 16)
                Text(account.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).frame(width: 82, alignment: .leading)
                if let window {
                    AllowanceBar(remaining: window.remainingPercent, unavailable: stale || error != nil || !account.enabled || snapshot?.providerRestricted == true)
                        .frame(width: 42, height: 4)
                } else { Color.clear.frame(width: 42, height: 4) }
                Spacer(minLength: 0)
                Text(detail).font(.system(size: 9)).foregroundStyle(stale || error != nil ? Color.orange : Color.secondary).lineLimit(1).minimumScaleFactor(0.85)
                Text(value).font(.system(size: 14, weight: .bold)).monospacedDigit().frame(minWidth: 55, alignment: .trailing)
                    .foregroundStyle(stale || !account.enabled ? .secondary : .primary)
            }.frame(height: 25).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help("\(account.kind.title) · \(account.name)\n\(window?.label ?? "") · \(detail)\n\(error ?? snapshot?.note ?? "Click for details and account settings.")")
            .accessibilityLabel("\(account.name), \(account.kind.title), \(window?.label ?? ""), \(value), \(detail)")
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.06), lineWidth: 1))
    }
}

private struct AccountReading: View {
    let account: Account
    let snapshot: Snapshot?
    let error: String?
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(account.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Spacer()
                if !account.enabled { Image(systemName: "pause.fill").foregroundStyle(.secondary).help("Paused") }
                else if error != nil { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange).help("Connection needs attention") }
            }
            if let email = snapshot?.identity {
                Text(email).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(email).textSelection(.enabled)
            }
            if let snapshot, let window = snapshot.primaryWeeklyWindow(for: account.kind) {
                let stale = snapshot.isStale(at: now, windows: [window])
                HStack(alignment: .firstTextBaseline) {
                    Text("\(Int(window.remainingPercent))%").font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("weekly left").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    if let reset = window.resetsAt { Text("Resets \(reset.formatted(.dateTime.weekday(.abbreviated)))").font(.system(size: 10)).foregroundStyle(.secondary) }
                }.foregroundStyle(stale || !account.enabled ? Color.secondary : .primary)
                AllowanceBar(remaining: window.remainingPercent, unavailable: stale || error != nil || !account.enabled || snapshot.providerRestricted == true).frame(height: 5)
                if let session = snapshot.sessionWindow(for: account.kind) {
                    let sessionStale = snapshot.isStale(at: now, windows: [session])
                    HStack {
                        Text("5h session").fontWeight(.bold)
                        AllowanceBar(remaining: session.remainingPercent, unavailable: sessionStale || error != nil || !account.enabled).frame(width: 48, height: 3)
                        Spacer()
                        Text(sessionStale ? "Waiting for update" : "\(Int(session.remainingPercent))% left").monospacedDigit()
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }
                let additional = snapshot.weeklyWindows.filter { $0.id != window.id }
                if !additional.isEmpty {
                    DisclosureGroup("Additional limits") {
                        ForEach(additional) { extra in
                            HStack {
                                Text(extra.label.replacingOccurrences(of: " · 7d", with: ""))
                                Spacer()
                                Text("\(Int(extra.remainingPercent))% left").monospacedDigit()
                            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.top, 4)
                        }
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if stale { Text("Last known reading · waiting for an update").font(.caption2).foregroundStyle(.orange) }
            } else if let amount = snapshot?.costUSD {
                Text(amount, format: .currency(code: "USD")).font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("API spending · this UTC month").font(.system(size: 10)).foregroundStyle(.secondary)
            } else {
                Text(error != nil ? "Needs attention" : (snapshot == nil ? "Waiting for a reading" : "Weekly limit unavailable")).font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 8)
            }
            if snapshot?.providerRestricted == true {
                Text("The provider reports a usage or credit restriction. Remaining percentages do not mean requests are available.")
                    .font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

struct AccountsView: View {
    @ObservedObject var store: AppStore
    var showMenu: () -> Void
    @ViewState private var name = ""
    @ViewState private var kind: ConnectionKind = .openAIAPI
    @ViewState private var secret = ""
    @ViewState private var error: String?
    @ViewState private var removing: Account?
    @ViewState private var renaming: Account?
    @ViewState private var newName = ""
    @ViewState private var keyAccount: Account?
    @ViewState private var replacement = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 24)).foregroundStyle(.primary)
                    .frame(width: 44, height: 44).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Settings").font(.system(size: 23, weight: .semibold))
                    Text("Your accounts. Your menu bar.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if store.refreshing { ProgressView().controlSize(.small) }
                Text(store.refreshSummary).font(.system(size: 11)).foregroundStyle(.secondary)
                Button { store.refresh(force: true) } label: { Image(systemName: "arrow.clockwise").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).help("Refresh accounts").accessibilityLabel("Refresh accounts")
                    .disabled(store.demo || store.paused || store.refreshing)
            }.padding(24)
            Divider().opacity(0.4)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if store.demo { Text("Sample accounts · sign-in is disabled in this preview").font(.caption).foregroundStyle(.orange) }
                    menuBarSettings
                    accountSection("Claude", kinds: [.claudeCode, .claudeAPI], provider: .claude)
                    accountSection("OpenAI", kinds: [.codex, .openAIAPI], provider: .openAI)
                    advancedSettings
                    if let notice = store.notice {
                        Label(notice, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(24)
            }
            Divider().opacity(0.4)
            HStack(spacing: 8) {
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
                Text("Stored on this Mac").foregroundStyle(.secondary)
                Spacer()
                Button("Show menu", action: showMenu).help("Open the menu-bar panel")
                Text("0.1.0 preview").foregroundStyle(.tertiary)
                Button { store.togglePause() } label: { Image(systemName: store.paused ? "play.fill" : "pause.fill").frame(width: 26, height: 26) }
                    .help(store.paused ? "Resume refresh" : "Pause refresh").accessibilityLabel(store.paused ? "Resume refresh" : "Pause refresh").disabled(store.demo)
                Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power").frame(width: 26, height: 26) }
                    .help("Quit Ai-llowance").accessibilityLabel("Quit Ai-llowance")
            }.font(.system(size: 10)).buttonStyle(.plain).padding(.horizontal, 24).padding(.vertical, 10)
        }.frame(minWidth: 640, idealWidth: 680, minHeight: 620)
            .background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(store.menuPreferences.theme.colorScheme)
        .alert("Remove \(removing?.name ?? "account")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) { if let account = removing { Task { await store.remove(account) } }; removing = nil }
        } message: { Text("Its admin key or app-owned OpenAI sign-in will be cleared. Any legacy Ai-llowance status line is restored automatically. Claude sign-ins remain managed by Claude; use Sign out in Terminal first if you also want to clear that login.") }
        .sheet(item: $renaming) { account in
            VStack(alignment: .leading, spacing: 16) {
                Text("Rename account").font(.headline)
                TextField("Name", text: $newName)
                HStack { Button("Cancel") { renaming = nil }; Spacer(); Button("Save") { store.rename(account, to: newName); renaming = nil } }
            }.padding(24).frame(width: 360)
        }
        .sheet(item: $keyAccount) { account in
            VStack(alignment: .leading, spacing: 16) {
                Text("Replace admin key").font(.headline)
                SecureField("New admin key", text: $replacement)
                HStack {
                    Button("Cancel") { replacement = ""; keyAccount = nil }
                    Spacer()
                    Button("Save to Keychain") {
                        do { try store.replaceKey(account, secret: replacement); replacement = ""; keyAccount = nil }
                        catch { store.notice = store.safeMessage(error) }
                    }.disabled(replacement.isEmpty)
                }
            }.padding(24).frame(width: 420)
        }
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
                    Text("Weekly remaining").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    if store.menuEntries.isEmpty { Label("Usage", systemImage: "gauge.with.dots.needle.33percent") }
                    ForEach(Array(store.menuEntries.enumerated()), id: \.offset) { _, entry in
                        HStack(spacing: 5) {
                            ProviderMark(provider: entry.provider)
                            if store.menuPreferences.display == .byAccount && store.menuPreferences.showAccountNames { Text(entry.label).lineLimit(1) }
                            Text(entry.remainingPercent.map { "\(Int($0))%" } ?? "—").monospacedDigit()
                        }.accessibilityLabel("\(entry.label): \(entry.remainingPercent.map { "\(Int($0)) percent weekly remaining" } ?? "unavailable")")
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
                        Text("About every minute, even with the panel closed.").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Automatic refresh", isOn: Binding(get: { !store.paused }, set: { if $0 == store.paused { store.togglePause() } }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
        }.disabled(store.demo)
    }
    private func accountSection(_ title: String, kinds: [ConnectionKind], provider: MenuProvider) -> some View {
        let accounts = store.accounts.filter { kinds.contains($0.kind) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                ProviderMark(provider: provider, size: 18)
                Text(title).font(.system(size: 14, weight: .semibold))
                Text("\(accounts.count)").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Color.primary.opacity(0.06), in: Capsule())
                Spacer()
                Button {
                    if kinds.contains(.claudeCode) { store.connectClaude(existing: !store.accounts.contains { $0.kind == .claudeCode && $0.usesExistingClaude == true }) }
                    else { store.connectOpenAI() }
                } label: { Label("Add account", systemImage: "plus").font(.system(size: 11)) }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(store.demo || store.connectingClaude || store.signingIn != nil || !store.waitingForClaude.isEmpty)
            }
            if (provider == .claude ? store.claudeExecutable == nil : store.executable == nil) {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(provider == .claude ? "Claude Code is needed to connect." : "Codex is needed to connect.")
                            .font(.system(size: 12, weight: .medium))
                        Text("Install it once, then return here. Already installed? Choose its location.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        HStack {
                            Link("Installation guide ↗", destination: URL(string: provider == .claude ? "https://code.claude.com/docs/en/setup" : "https://developers.openai.com/codex/cli")!)
                            Button("Choose installed app…") {
                                if provider == .claude { store.chooseClaudeExecutable() } else { store.chooseExecutable() }
                            }
                        }.font(.system(size: 11))
                    }
                }
            }
            if accounts.isEmpty {
                SettingsCard { Text("Connect \(title) to see your weekly usage here.").font(.system(size: 12)).foregroundStyle(.secondary) }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(accounts) { account in
                        SettingsCard {
                            VStack(alignment: .leading, spacing: 14) {
                                AccountReading(account: account, snapshot: store.snapshots[account.id], error: store.errors[account.id], now: store.now)
                                if let other = store.duplicateIdentity(account) {
                                    Text("Same email as \(other). If these use the same plan, keep just one connection to avoid counting it twice.")
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Divider().opacity(0.4)
                                accountActions(account)
                            }
                        }
                    }
                }
            }
        }
    }
    private func accountActions(_ account: Account) -> some View {
        HStack(spacing: 11) {
            if store.waitingForClaude[account.id] != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Finish sign-in in your browser").foregroundStyle(.secondary)
                    Button("Stop waiting") { store.cancelClaudeSignIn(account) }.help("Close the sign-in Terminal window before retrying.")
                }
            } else if store.signingIn == account.id {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Finish sign-in in your browser").foregroundStyle(.secondary)
                    Button("Cancel sign-in") { store.cancelSignIn() }
                }
            } else if store.needsSignIn(account) {
                if account.kind.isAPI {
                    Button("Replace key") { replacement = ""; keyAccount = account }
                } else if account.kind == .claudeCode {
                    Button("Sign in") { store.openClaude(account, login: true) }
                } else if account.kind == .codex && !account.usesExistingCodex {
                    Button("Sign in") { store.signIn(account) }.disabled(store.signingIn != nil)
                } else if account.kind == .codex {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sign in through Codex CLI.").foregroundStyle(.secondary)
                        Button("Check sign-in") { store.retryConnection(account) }
                    }
                }
            } else {
                Link("View usage ↗", destination: account.kind.dashboard).foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            if account.kind == .claudeCode {
                Menu {
                    Button("Open Claude Code") { store.openClaude(account) }
                    Button("Open in a project…") { store.openClaude(account, chooseProject: true) }
                    Button("Sign in again") { store.openClaude(account, login: true) }
                    Button("Sign out in Terminal") { store.openClaude(account, logout: true) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 16).help("Claude connection options")
            } else if account.kind.isAPI {
                Button { replacement = ""; keyAccount = account } label: { Image(systemName: "key") }.help("Replace API key")
            } else if !account.usesExistingCodex {
                Button { store.signIn(account) } label: { Image(systemName: "person.crop.circle.badge.checkmark") }.help("Sign in again").disabled(store.signingIn != nil || !store.waitingForClaude.isEmpty)
            }
            Button { newName = account.name; renaming = account } label: { Image(systemName: "pencil") }.help("Rename account").accessibilityLabel("Rename \(account.name)")
            Button { store.toggle(account) } label: { Image(systemName: account.enabled ? "pause.fill" : "play.fill") }
                .help(account.enabled ? "Pause account" : "Resume account").accessibilityLabel(account.enabled ? "Pause \(account.name)" : "Resume \(account.name)")
            Button(role: .destructive) { removing = account } label: { Image(systemName: "trash") }.help("Remove account").accessibilityLabel("Remove \(account.name)")
                .disabled(store.refreshing || store.removing || store.signingIn != nil)
        }.font(.system(size: 10)).buttonStyle(.plain).disabled(store.demo)
    }
    private var advancedSettings: some View {
        SettingsCard {
            DisclosureGroup("Advanced connections") {
                VStack(alignment: .leading, spacing: 14) {
                    Button("Use existing OpenAI / Codex sign-in") { store.connectOpenAI(existing: true) }
                        .disabled(store.demo || store.refreshing || store.signingIn != nil || store.accounts.contains { $0.usesExistingCodex })
                    Divider()
                    Text("API spending").font(.system(size: 12, weight: .semibold))
                    Picker("Provider", selection: $kind) {
                        Text("OpenAI API").tag(ConnectionKind.openAIAPI)
                        Text("Anthropic API").tag(ConnectionKind.claudeAPI)
                    }.onChange(of: kind) { _, _ in secret = ""; error = nil }
                    TextField("Account label (optional)", text: $name)
                    SecureField("Organization admin API key", text: $secret)
                    Text("API spending is separate from subscriptions and credit balances. The admin key is stored in Keychain.").font(.system(size: 10)).foregroundStyle(.secondary)
                    Button("Connect API spending") {
                        do {
                            try store.add(name: name.isEmpty ? (kind == .openAIAPI ? "OpenAI API" : "Anthropic API") : name, kind: kind, secret: secret, existing: false)
                            name = ""; secret = ""; error = nil
                        } catch { self.error = store.safeMessage(error) }
                    }.disabled(secret.isEmpty || store.demo)
                    if let error { Text(error).font(.caption).foregroundStyle(.orange) }
                    Divider()
                    HStack {
                        Button("Choose Codex CLI…") { store.chooseExecutable() }
                        Button("Choose Claude CLI…") { store.chooseClaudeExecutable() }
                    }
                    HStack {
                        if store.executable == nil { Link("Install Codex ↗", destination: URL(string: "https://developers.openai.com/codex/cli")!) }
                        if store.claudeExecutable == nil { Link("Install Claude Code ↗", destination: URL(string: "https://code.claude.com/docs/en/setup")!) }
                    }
                    Text("Preview release · not notarized. No Ai-llowance analytics or backend. Provider websites open with your browser’s current account.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(.top, 12).disabled(store.demo)
            }.font(.system(size: 12, weight: .medium))
        }
    }

}
