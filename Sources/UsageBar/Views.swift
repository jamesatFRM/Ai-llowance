import SwiftUI
import AppKit
import UsageCore

// Explicit wrapper alias avoids the newer SDK State macro; remains compatible with macOS 14.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct Dashboard: View {
    @ObservedObject var store: AppStore
    var manage: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text("UsageBar").font(.system(size: 12, weight: .semibold))
                Spacer()
                if store.refreshing { ProgressView().controlSize(.mini) }
                Text(store.demo ? "Sample data" : (store.offline ? "Offline" : (store.paused ? "Paused" : "Auto-refresh · 1 min")))
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
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            } else {
                ScrollView {
                    VStack(spacing: 9) {
                        providerGroups("OpenAI", subscription: .codex, api: .openAIAPI)
                        providerGroups("Claude", subscription: .claudeCode, api: .claudeAPI)
                    }
                }.scrollIndicators(.hidden).fixedSize(horizontal: false, vertical: true).frame(maxHeight: 500)
            }
            if let notice = store.notice { Text(notice).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2).padding(.horizontal, 9) }
            HStack {
                Button("Accounts…", action: manage)
                Spacer()
                Text("Preview · 0.1.0").foregroundStyle(.tertiary)
                Menu {
                    Button(store.paused ? "Resume refresh" : "Pause refresh") { store.togglePause() }
                    Button("Quit UsageBar") { NSApplication.shared.terminate(nil) }
                } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 19)
            }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.secondary).padding(.horizontal, 9).padding(.bottom, 3)
        }.padding(7).frame(width: 350).background(Color(nsColor: .windowBackgroundColor)).preferredColorScheme(.dark)
    }
    @ViewBuilder
    private func providerGroups(_ name: String, subscription: ConnectionKind, api: ConnectionKind) -> some View {
        let subscriptions = store.accounts.filter { $0.kind == subscription }
        let billing = store.accounts.filter { $0.kind == api }
        if !subscriptions.isEmpty { compactGroup(name, trailing: "Remaining", accounts: subscriptions) }
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
                let windows = snapshot?.windows ?? []
                if windows.isEmpty {
                    CompactRow(account: account, snapshot: snapshot, window: nil, error: store.errors[account.id], now: store.now, claudeSignedIn: store.claudeSignedIn[account.id], action: manage)
                    accountEmail(snapshot)
                } else {
                    ForEach(windows) { window in
                        CompactRow(account: account, snapshot: snapshot, window: window, error: store.errors[account.id], now: store.now, claudeSignedIn: store.claudeSignedIn[account.id], action: manage)
                        if window.id == windows.first?.id { accountEmail(snapshot) }
                    }
                }
                if let snapshot {
                    let minutes = max(0, Int(store.now.timeIntervalSince(snapshot.observedAt) / 60))
                    Text("\(account.name) · \(minutes == 0 ? "read just now" : "read \(minutes)m ago")\(account.kind == .claudeCode ? " · direct read" : "")")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 2)
                }
            }
        }.padding(.horizontal, 11).padding(.vertical, 10)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
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
    private var stale: Bool { snapshot?.isStale(at: now) ?? false }
    private var color: Color { account.kind == .codex || account.kind == .openAIAPI ? .cyan : .orange }
    private var detail: String {
        if !account.enabled { return "paused" }
        if account.kind == .claudeCode && snapshot == nil, let claudeSignedIn { return claudeSignedIn ? "refresh" : "sign in" }
        if error != nil { return "check account" }
        if stale { return "stale" }
        guard let window else { return snapshot?.costUSD == nil ? "no reading" : "API cost" }
        guard let reset = window.resetsAt else { return "Reset unknown" }
        let minutes = max(0, Int(reset.timeIntervalSince(now) / 60))
        let remaining = minutes >= 1440 ? "\(minutes / 1440)d" : (minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : (minutes == 0 ? "<1m" : "\(minutes)m"))
        return "Resets in \(remaining)"
    }
    private var value: String {
        if let window { return "\(Int(window.remainingPercent))% left" }
        if let amount = snapshot?.costUSD { return amount.formatted(.currency(code: "USD")) }
        return "—"
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: account.kind == .codex || account.kind == .openAIAPI ? "circle.hexagongrid.fill" : "sparkle")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(color).frame(width: 16)
                Text(account.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).frame(width: 82, alignment: .leading)
                if let window {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.07))
                            Capsule().fill(stale || error != nil || !account.enabled ? .gray : color)
                                .frame(width: proxy.size.width * window.remainingPercent / 100)
                        }
                    }.frame(width: 42, height: 4)
                } else { Color.clear.frame(width: 42, height: 4) }
                Spacer(minLength: 0)
                Text(detail).font(.system(size: 9)).foregroundStyle(stale || error != nil ? Color.orange : Color.secondary).lineLimit(1).minimumScaleFactor(0.85)
                Text(value).font(.system(size: 12, weight: .bold)).monospacedDigit().frame(minWidth: 55, alignment: .trailing)
                    .foregroundStyle(stale || !account.enabled ? .secondary : .primary)
            }.frame(height: 25).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help("\(account.kind.title) · \(account.name)\n\(window?.label ?? "") · \(detail)\n\(error ?? snapshot?.note ?? "Click for details and account settings.")")
            .accessibilityLabel("\(account.name), \(account.kind.title), \(window?.label ?? ""), \(value), \(detail)")
    }
}

struct UsageCard: View {
    let account: Account
    let snapshot: Snapshot?
    let error: String?
    let now: Date
    private var stale: Bool { snapshot?.isStale(at: now) ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.name).font(.headline)
                    if let email = snapshot?.identity, !email.isEmpty {
                        Text(email).font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text(account.kind.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(!account.enabled ? "PAUSED" : (error != nil ? "ATTENTION" : (stale ? "STALE" : (snapshot == nil ? "SETUP" : "OBSERVED"))))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background((stale || error != nil ? Color.orange : Color.teal).opacity(0.12), in: Capsule())
            }
            if let snapshot {
                if let cost = snapshot.costUSD {
                    HStack(alignment: .firstTextBaseline) {
                        Text(cost, format: .currency(code: "USD")).font(.system(size: 28, weight: .medium, design: .rounded))
                        Text("Organization · month to date").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(snapshot.windows) { window in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(window.label).font(.caption)
                            Spacer()
                            Text("\(Int(window.remainingPercent))% left").font(.caption.weight(.semibold)).monospacedDigit()
                        }
                        ProgressView(value: window.usedPercent, total: 100)
                            .tint(stale || error != nil ? .gray : (window.usedPercent >= 90 ? .orange : .teal))
                            .accessibilityLabel("\(window.label): \(Int(window.usedPercent)) percent used")
                        if let reset = window.resetsAt {
                            Text(reset <= now ? "Reset time passed · waiting for a new reading" : "Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                if let note = snapshot.note { Text(note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Text("Read \(snapshot.observedAt.formatted(date: .abbreviated, time: .shortened))")
                    Spacer()
                    if stale { Text("Last known reading").foregroundStyle(.orange) }
                }.font(.caption2).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            else if snapshot == nil { Text(account.kind == .claudeCode ? "Reading Claude’s current plan limits…" : "Connect this account in Accounts.").font(.caption).foregroundStyle(.secondary) }
            Link("View usage website ↗", destination: account.kind.dashboard).font(.caption2)
        }.padding(14).background(.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
    }
}

struct AccountsView: View {
    @ObservedObject var store: AppStore
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
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your accounts").font(.largeTitle.weight(.semibold))
                    Text("Choose a provider. We’ll take care of the setup.").foregroundStyle(.secondary)
                }
                if store.demo { Text("DEMO — all readings are sample data. Connections are disabled.").foregroundStyle(.orange) }
                HStack(spacing: 12) {
                    Button { store.connectOpenAI() } label: {
                        Label("Connect OpenAI", systemImage: "circle.hexagongrid.fill").frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).tint(.teal)
                        .disabled(store.demo || store.signingIn != nil || store.refreshing)
                    Button {
                        store.connectClaude(existing: !store.accounts.contains { $0.kind == .claudeCode && $0.usesExistingClaude == true })
                    } label: {
                        Label(store.connectingClaude ? "Connecting…" : "Connect Claude", systemImage: "sparkle").frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).tint(.orange).disabled(store.demo || store.connectingClaude)
                }
                Text("Connect once. Both providers refresh automatically, including when you open this menu. An existing Claude Code sign-in is detected automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                if store.executable == nil || store.claudeExecutable == nil {
                    HStack {
                        if store.executable == nil { Link("Install Codex CLI ↗", destination: URL(string: "https://developers.openai.com/codex/cli")!) }
                        if store.claudeExecutable == nil { Link("Install Claude Code ↗", destination: URL(string: "https://code.claude.com/docs/en/setup")!) }
                    }.font(.caption)
                }
                ForEach(store.accounts) { account in
                    VStack(alignment: .leading, spacing: 10) {
                        UsageCard(account: account, snapshot: store.snapshots[account.id], error: store.errors[account.id], now: store.now)
                        HStack {
                            if account.kind == .codex {
                                if account.usesExistingCodex {
                                    Text("Existing CLI sign-in").font(.caption).foregroundStyle(.secondary)
                                } else if store.signingIn == account.id {
                                    ProgressView().controlSize(.small)
                                    Button("Cancel sign-in") { store.cancelSignIn() }
                                } else { Button("Sign in with ChatGPT") { store.signIn(account) }.disabled(store.signingIn != nil || store.refreshing) }
                            } else if account.kind == .claudeCode {
                                if store.claudeSignedIn[account.id] == false {
                                    Button("Sign in to Claude") { store.openClaude(account, login: true) }
                                } else {
                                    Button("Refresh usage") { store.refresh(force: true) }.disabled(store.refreshing)
                                }
                                Menu("More") {
                                    Button("Open Claude Code") { store.openClaude(account) }
                                    Button("Open in a project…") { store.openClaude(account, chooseProject: true) }
                                    Button("Sign in again") { store.openClaude(account, login: true) }
                                    Button("Sign out in Terminal") { store.openClaude(account, logout: true) }
                                }.fixedSize()
                            } else { Button("Replace admin key") { replacement = ""; keyAccount = account }.disabled(store.refreshing || store.removing) }
                            Spacer()
                            Button(account.enabled ? "Pause" : "Resume") { store.toggle(account) }
                            Button("Rename") { newName = account.name; renaming = account }
                            Button(role: .destructive) { removing = account } label: { Image(systemName: "trash") }.help("Remove account")
                                .disabled(store.refreshing || store.removing || store.signingIn != nil)
                        }.padding(.horizontal, 4).disabled(store.demo)
                    }
                }
                DisclosureGroup("More connection options") {
                    VStack(alignment: .leading, spacing: 14) {
                        Button("Use my existing OpenAI / Codex sign-in") { store.connectOpenAI(existing: true) }
                            .disabled(store.demo || store.refreshing || store.signingIn != nil || store.accounts.contains { $0.usesExistingCodex })
                        Divider()
                        Text("API spending (optional)").font(.headline)
                        Picker("Provider", selection: $kind) {
                            Text("OpenAI API").tag(ConnectionKind.openAIAPI)
                            Text("Anthropic API").tag(ConnectionKind.claudeAPI)
                        }.onChange(of: kind) { _, _ in secret = ""; error = nil }
                        TextField("Account label (optional)", text: $name)
                        SecureField("Organization admin API key", text: $secret)
                        Text("API billing is separate from subscriptions. It requires an admin key, stored in your Mac’s Keychain.").font(.caption).foregroundStyle(.secondary)
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
                        }.disabled(store.demo)
                    }.padding(.top, 12)
                }
                Button(store.paused ? "Resume refresh" : "Pause refresh") { store.togglePause() }.disabled(store.demo)
                if let notice = store.notice { Text(notice).foregroundStyle(.orange).font(.callout) }
                Text("UsageBar 0.1.0 preview · Not a production release\nNo analytics, backend service, browser-cookie access, or inference requests. Both providers refresh about once a minute with backoff and when opened. Claude uses its built-in usage command; no conversation is needed. Provider dashboards use your browser’s current account, which may differ from this connection.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(26)
        }.frame(minWidth: 620, idealWidth: 660, minHeight: 620)
        .alert("Remove \(removing?.name ?? "account")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) { if let account = removing { Task { await store.remove(account) } }; removing = nil }
        } message: { Text("Its admin key or app-owned OpenAI sign-in will be cleared. Any legacy UsageBar status line is restored automatically. Claude sign-ins remain managed by Claude; use Sign out in Terminal first if you also want to clear that login.") }
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
}
