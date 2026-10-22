import AppKit
import Combine
import Network
import UsageCore
import ServiceManagement
import UserNotifications

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var refreshMinutes = UserDefaults.standard.integer(forKey: "refreshMinutes")
    func refreshInterval(for kind: ConnectionKind, visible: Bool, lowPower: Bool) -> TimeInterval {
        max(kind.refreshInterval(visible: visible, lowPower: lowPower), [5, 15, 30].contains(refreshMinutes) ? Double(refreshMinutes * 60) : 0)
    }
    func setRefreshMinutes(_ minutes: Int) {
        guard !demo, !readOnly, [0, 5, 15, 30].contains(minutes) else { return }
        refreshMinutes = minutes
        UserDefaults.standard.set(minutes, forKey: "refreshMinutes")
        for account in accounts {
            schedules[account.id]?.adjustHealthyInterval(refreshInterval(for: account.kind, visible: interfaceVisible, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled))
        }
        scheduleHeartbeat()
    }
    @Published var accounts: [Account] = []
    @Published var snapshots: [UUID: Snapshot] = [:]
    @Published var errors: [UUID: String] = [:]
    @Published var refreshing = false
    @Published var signingIn: UUID?
    @Published private(set) var codexSignInURL: URL?
    @Published var removing = false
    @Published var connectingClaude = false
    @Published private(set) var waitingForClaude: [UUID: Date] = [:]
    @Published private(set) var authenticationRequired: Set<UUID> = []
    @Published var claudeSignedIn: [UUID: Bool] = [:]
    @Published var notice: String?
    @Published var paused = false
    @Published var offline = false
    @Published var now = Date()
    @Published private(set) var menuPreferences = MenuPreferences()
    @Published private(set) var accountNavigationVersion: UInt64 = 0
    @Published var selectedAccountID: UUID? {
        didSet { if selectedAccountID != nil { accountNavigationVersion &+= 1 } }
    }
    @Published private(set) var notificationsEnabled = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginItemNeedsApproval = false
    @Published private(set) var browserProfiles: [BrowserProfile] = []
    @Published private(set) var usageHistory: [UUID: [UsageHistoryPoint]] = [:]
    @Published var executable = CodexAdapter.findExecutable()
    @Published var claudeExecutable = ClaudeConnection.findExecutable()
    @Published var copilotExecutable = CopilotAdapter.findExecutable()
    private var interfaceVisible = false
    private var browserChoices: [String: String] = [:]
    private var rememberedTools: [String: RememberedExecutable] = [:]
    private var alerts = AlertTracker()
    private var pendingAlerts: [UsageAlert] = []
    private var notificationRequestVersion = UUID()
    private let requestNotificationAuthorization: @Sendable () async throws -> Bool
    private var cachedAccounts: Set<UUID> = []
    private var restoredLegacyFeeds: Set<UUID> = []
    private var cacheTask: Task<Void, Never>?
    lazy var updater = AppUpdater(enabled: !demo)
    let demo: Bool
    let root: URL
    var existingClaudeConfig = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    private var schedules: [UUID: PollState] = [:]
    private var refreshTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?
    private var heartbeat: DispatchSourceTimer?
    private var pendingManualRefresh = false
    private var connectionVersions: [UUID: UUID] = [:]
    private var claudeCompletions: [UUID: URL] = [:]
    private let fetchOverride: (@Sendable (Account, Date) async throws -> Snapshot)?
    private let openExternal: (URL) -> Bool
    private let network = NWPathMonitor()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var sleeping = false
    private var readOnly = false
    private var shuttingDown = false
    private let costs = CostAdapter()
    private let balances = BalanceAdapter()
    private let keychain = KeychainStore()
    private struct Saved: Codable {
        var accounts: [Account]; var paused: Bool; var menuPreferences: MenuPreferences?
        var notificationsEnabled: Bool?; var browserChoices: [String: String]?
        var rememberedTools: [String: RememberedExecutable]?
    }

    init(demo: Bool = false, root: URL = Paths.root, monitor: Bool = true,
         fetch: (@Sendable (Account, Date) async throws -> Snapshot)? = nil,
         requestNotificationAuthorization: @escaping @Sendable () async throws -> Bool = {
             try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
         },
         openExternal: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.demo = demo; self.root = root; self.fetchOverride = fetch; self.openExternal = openExternal
        self.requestNotificationAuthorization = requestNotificationAuthorization
        if demo {
            accounts = [Account(name: "Personal", kind: .claudeCode), Account(name: "Work", kind: .claudeCode),
                        Account(name: "Personal", kind: .codex), Account(name: "Work", kind: .codex)]
            for (index, account) in accounts.enumerated() {
                let claude = account.kind == .claudeCode
                let remaining = [72.0, 24.0, 58.0, 16.0][index]
                var windows = [try! QuotaWindow(id: claude ? "week.all models" : "codex.Secondary", label: "Week · 7d", usedPercent: 100 - remaining,
                    resetsAt: now.addingTimeInterval(Double(index + 2) * 86400), durationMinutes: 10_080)]
                if claude { windows.append(try! QuotaWindow(id: "session", label: "Session · 5h", usedPercent: index == 0 ? 18 : 52,
                    resetsAt: now.addingTimeInterval(7200), durationMinutes: 300)) }
                snapshots[account.id] = Snapshot(observedAt: now, windows: windows, identity: index % 2 == 0 ? "alex@example.com" : "work@example.com", source: "Sample data")
            }
            menuPreferences.display = .byAccount; menuPreferences.showAccountNames = false
            return
        }
        let url = root.appendingPathComponent("accounts.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let saved = try JSONDecoder().decode(Saved.self, from: Paths.readData(url))
                guard saved.accounts.count <= 1000, Set(saved.accounts.map(\.id)).count == saved.accounts.count,
                      saved.accounts.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.utf8.count <= 4096 }) else { throw UsageError.invalidData }
                accounts = saved.accounts; paused = saved.paused
                menuPreferences = saved.menuPreferences ?? MenuPreferences()
                notificationsEnabled = saved.notificationsEnabled ?? false
                browserChoices = saved.browserChoices ?? [:]
                rememberedTools = saved.rememberedTools ?? [:]
            } catch { notice = "Account settings could not be read. The existing file was preserved. Restore accounts.json before adding accounts."; readOnly = true }
        }
        if !readOnly {
            let cache = SnapshotCache(root: root)
            snapshots = cache.load(accounts: accounts, now: now)
            cachedAccounts = Set(snapshots.keys)
            usageHistory = cache.loadHistory(accounts: accounts, now: now)
            if let data = try? Paths.readData(root.appendingPathComponent("alerts.json"), limit: 256_000),
               let savedAlerts = try? JSONDecoder().decode(AlertTracker.self, from: data) { alerts = savedAlerts }
            alerts.retain(accounts: accounts)
        }
        rediscoverTools()
        guard monitor else { return }
        network.pathUpdateHandler = { @Sendable [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor in self?.offline = offline; if !offline { self?.refresh() } }
        }
        network.start(queue: DispatchQueue(label: "Ai-llowance.network", qos: .utility))
        // Dispatch deadlines do not depend on AppKit's default/event-tracking run-loop mode.
        let heartbeat = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "Ai-llowance.heartbeat", qos: .utility))
        heartbeat.schedule(deadline: .now() + 1, leeway: .seconds(1))
        heartbeat.setEventHandler { @Sendable [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        self.heartbeat = heartbeat
        heartbeat.resume()
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.refreshTask?.cancel(); self?.loginTask?.cancel() }
        })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = false; self?.now = Date(); self?.refresh() }
        })
    }
    var refreshSummary: String {
        if demo { return "Sample data" }
        if paused { return "Paused" }
        if offline { return "Offline" }
        if signingIn != nil || !waitingForClaude.isEmpty { return "Finish sign-in" }
        if refreshing { return "Updating…" }
        let active = accounts.filter { $0.enabled }
        if active.contains(where: { errors[$0.id] != nil }) { return "Check accounts" }
        guard !active.isEmpty else { return "Ready to connect" }
        let readings = active.compactMap { snapshots[$0.id]?.observedAt }
        guard readings.count == active.count, let oldest = readings.min() else { return "Waiting for readings" }
        let age = max(0, Int(now.timeIntervalSince(oldest)))
        return age < 60 ? "Updated just now" : "Updated \(age / 60)m ago"
    }
    var menuEntries: [MenuEntry] {
        MenuSummary.entries(accounts: accounts, snapshots: snapshots, unavailable: Set(errors.keys), preferences: menuPreferences, now: now)
    }
    private func updateMenu(_ change: (inout MenuPreferences) -> Void) {
        let previous = menuPreferences
        change(&menuPreferences)
        do { try persist() } catch { menuPreferences = previous; notice = "Could not save the menu-bar setting." }
    }
    func setTheme(_ value: AppTheme) { updateMenu { $0.theme = value } }
    func setDetailedQuotaLabels(_ value: Bool) { updateMenu { $0.detailedQuotaLabels = value } }
    func setColorByAllowance(_ value: Bool) { updateMenu { $0.colorByAllowance = value } }
    func setShowAccountNames(_ value: Bool) { updateMenu { $0.showAccountNames = value } }
    func setMenuDisplay(_ value: MenuDisplay) { updateMenu { $0.display = value } }
    func setMenuAggregation(_ value: MenuAggregation) { updateMenu { $0.aggregation = value } }
    func setAllMenuAccounts(_ value: Bool) {
        updateMenu {
            if !value && $0.allAccounts { $0.selectedAccountIDs = Set(accounts.filter { !$0.kind.isAPI || $0.kind.isBalance }.map(\.id)) }
            $0.allAccounts = value
        }
    }
    func setMenuAccount(_ account: Account, included: Bool) {
        updateMenu {
            if included { $0.selectedAccountIDs.insert(account.id) }
            else { $0.selectedAccountIDs.remove(account.id) }
        }
    }
    private func persist() throws {
        guard !readOnly else { throw UsageError.storage }
        if !demo {
            do { try Paths.write(Saved(accounts: accounts, paused: paused, menuPreferences: menuPreferences, notificationsEnabled: notificationsEnabled, browserChoices: browserChoices, rememberedTools: rememberedTools), to: root.appendingPathComponent("accounts.json")) }
            catch { throw UsageError.storage }
        }
    }
    @discardableResult
    func add(name: String, kind: ConnectionKind, secret: String, existing: Bool, refreshAfter: Bool = true, scopeID: String? = nil) throws -> Account {
        guard !demo, !readOnly else { throw UsageError.storage }
        guard accounts.count < 1000, name.utf8.count <= 4096, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw UsageError.invalidData }
        if kind == .codex && existing && accounts.contains(where: { $0.usesExistingCodex }) {
            throw UsageError.unavailable("The existing Codex CLI profile is already connected.")
        }
        let account = Account(name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, usesExistingCodex: kind == .codex && existing, scopeID: scopeID)
        if kind.isAPI { try keychain.save(secret.trimmingCharacters(in: .whitespacesAndNewlines), for: account.id) }
        if kind == .codex && !existing { try Paths.prepare(Paths.profile(account.id, root: root)) }
        accounts.append(account)
        do { try persist() }
        catch { accounts.removeAll { $0.id == account.id }; if kind.isAPI { try? keychain.delete(account.id) }; throw error }
        if refreshAfter { refresh(force: true) }
        return account
    }
    private func automaticName(_ provider: String, kind: ConnectionKind) -> String {
        let names = Set(accounts.filter { $0.kind == kind }.map { $0.name.lowercased() })
        var index = 1
        while names.contains((index == 1 ? provider : "\(provider) \(index)").lowercased()) { index += 1 }
        return index == 1 ? provider : "\(provider) \(index)"
    }
    func connectOpenAI(existing: Bool = false) {
        guard !demo, !readOnly, !removing, signingIn == nil, waitingForClaude.isEmpty else { return }
        guard executable != nil else { notice = "Install Codex CLI once, then click Connect OpenAI. If it is already installed, use Choose Codex CLI below."; return }
        do {
            let account = try add(name: automaticName("OpenAI", kind: .codex), kind: .codex, secret: "", existing: existing, refreshAfter: false)
            selectedAccountID = account.id
            if existing { refresh(force: true) } else { signIn(account, openBrowser: accounts.filter { $0.kind == .codex }.count == 1) }
        } catch { notice = safeMessage(error) }
    }
    func recommendedAccount(for kind: ConnectionKind) -> Account? {
        AccountRecommendation.best(kind: kind, accounts: accounts, snapshots: snapshots,
            unavailable: Set(errors.keys).union(cachedAccounts).union(authenticationRequired), now: now)
    }
    func useAccount(_ account: Account) {
        guard let current = accounts.first(where: { $0.id == account.id }),
              recommendedAccount(for: current.kind)?.id == current.id,
              AccountRecommendation.best(kind: current.kind, accounts: [current], snapshots: snapshots,
                unavailable: Set(errors.keys).union(cachedAccounts).union(authenticationRequired), now: Date()) != nil else {
            notice = "Refresh this account before opening it."; return
        }
        openAgentHelp(for: current.kind, account: current, setupHelp: false)
    }
    func openAgentHelp(for kind: ConnectionKind, account: Account? = nil, setupHelp: Bool = true) {
        guard !demo, !readOnly, kind == .claudeCode || kind == .codex else { return }
        if let account, !accounts.contains(where: { $0.id == account.id }) { return }
        if kind == .claudeCode && claudeExecutable == nil {
            notice = "Install or locate Claude Code in Advanced settings, then try again."; return
        }
        if kind == .codex && executable == nil {
            notice = "Install or locate Codex CLI in Advanced settings, then try again."; return
        }
        let agent = kind == .claudeCode ? "Claude Code" : "Codex"
        let prompt = """
        I’m setting up Ai-llowance to track my \(agent) subscription. Please guide me one step at a time through connecting the \(agent) sign-in I choose in Ai-llowance Dashboard → Accounts. I want subscription usage tracking, not API billing. Do not ask me to paste passwords, API keys, tokens, or other secrets into chat. Do not sign out, switch accounts, or change CLI configuration without explaining what will change and waiting for my confirmation. If Ai-llowance needs me to approve a browser sign-in or macOS permission, tell me to complete that directly in the app and then return here. Keep the instructions simple and stop when the account is connected.
        """
        if setupHelp {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt, forType: .string)
        }
        if kind == .claudeCode, let claudeExecutable {
            var profile = existingClaudeConfig
            if let account, account.usesExistingClaude != true {
                do { profile = try claudeConnection().config(account) }
                catch { notice = safeMessage(error); return }
            }
            let launcher = root.appendingPathComponent("AgentHelp/Claude-\(account?.id.uuidString ?? "default").command")
            let script = """
            #!/bin/zsh -f
            set -eu
            unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_BASE_URL
            unset CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY ANTHROPIC_PROFILE
            unset CLAUDE_SECURESTORAGE_CONFIG_DIR
            export CLAUDE_CONFIG_DIR=\(ShellQuote.argument(profile.path))
            export DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1
            cd "$HOME"
            exec \(ShellQuote.argument(claudeExecutable.path))
            """
            do {
                try Paths.writePrivate(Data(script.utf8), to: launcher, executable: true)
                guard openExternal(launcher) else { throw UsageError.unavailable("Could not open Claude Code in Terminal.") }
                notice = setupHelp ? "Setup prompt copied. Paste it into the Claude Code window that opened." : "Opened Claude Code with this account’s profile."
            } catch { notice = safeMessage(error) }
            return
        }
        guard let executable else { notice = "Install or locate Codex CLI in Advanced settings, then try again."; return }
        let defaultProfile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let profile = account.map { $0.usesExistingCodex ? defaultProfile : Paths.profile($0.id, root: root) } ?? defaultProfile
        let credentialArguments = account?.usesExistingCodex == false
            ? " -c " + ShellQuote.argument("cli_auth_credentials_store=\"keyring\"") : ""
        let launcher = root.appendingPathComponent("AgentHelp/Codex-\(account?.id.uuidString ?? "default").command")
        let script = """
        #!/bin/zsh -f
        set -eu
        unset OPENAI_API_KEY CODEX_API_KEY OPENAI_BASE_URL OPENAI_ORG_ID OPENAI_ORGANIZATION OPENAI_PROJECT_ID
        export CODEX_HOME=\(ShellQuote.argument(profile.path))
        cd "$HOME"
        exec \(ShellQuote.argument(executable.path))\(credentialArguments)
        """
        do {
            try Paths.writePrivate(Data(script.utf8), to: launcher, executable: true)
            guard openExternal(launcher) else { throw UsageError.unavailable("Could not open Codex CLI in Terminal.") }
            notice = setupHelp ? "Setup prompt copied. Paste it into the Codex window that opened." : "Opened Codex with this account’s profile."
        } catch { notice = safeMessage(error) }
    }
    private func claudeConnection() throws -> ClaudeConnection {
        guard let claudeExecutable else { throw UsageError.unavailable("Install Claude Code once, then click Connect Claude. If it is installed elsewhere, use Choose Claude CLI below.") }
        return ClaudeConnection(root: root, executable: claudeExecutable,
            bundledBridge: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/UsageBridge"), existingConfig: existingClaudeConfig)
    }
    func connectClaude(existing: Bool) {
        guard !shuttingDown, accounts.count < 1000, !demo, !connectingClaude, !readOnly, !removing, signingIn == nil, waitingForClaude.isEmpty else { return }
        if existing && accounts.contains(where: { $0.kind == .claudeCode && $0.usesExistingClaude == true }) {
            notice = "Your current Claude Code is already connected. Use Add another Claude account for a separate login."; return
        }
        connectingClaude = true
        connectionTask = Task {
            defer { connectingClaude = false }
            do {
                let connection = try claudeConnection()
                var account = Account(name: automaticName("Claude", kind: .claudeCode), kind: .claudeCode, usesExistingClaude: existing)
                let signedIn = existing ? (try await connection.authStatus(account: account)) : false
                try Task.checkCancellation()
                // Reuse only a signed-in subscription. An API-billed or logged-out CLI stays untouched.
                if existing && !signedIn { account.usesExistingClaude = false }
                try Paths.prepare(connection.config(account))
                claudeSignedIn[account.id] = signedIn
                accounts.append(account)
                selectedAccountID = account.id
                do { try persist() }
                catch { accounts.removeAll { $0.id == account.id }; try? connection.uninstall(account: account); throw error }
                if !signedIn {
                    openClaude(account, login: true)
                } else { notice = nil }
                schedules[account.id] = PollState(); refresh(force: true)
            } catch { notice = safeMessage(error) }
        }
    }
    func openClaude(_ account: Account, login: Bool = false, chooseProject: Bool = false, logout: Bool = false) {
        guard !demo, !removing, accounts.contains(where: { $0.id == account.id }) else { return }
        if login && (waitingForClaude[account.id] != nil || signingIn != nil) { return }
        do {
            let connection = try claudeConnection()
            if login || logout {
                connectionVersions[account.id] = UUID()
                authenticationRequired.insert(account.id)
                snapshots[account.id] = nil; errors[account.id] = nil; schedules[account.id] = PollState()
                clearCachedReading(account)
                claudeSignedIn[account.id] = false
                try? FileManager.default.removeItem(at: Paths.feed(account.id, root: root))
            }
            var project: URL?
            if chooseProject {
                let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                panel.message = "Choose a folder to use with this Claude account."
                guard panel.runModal() == .OK else { return }
                project = panel.url
            }
            let completion = login ? root.appendingPathComponent("ClaudeConnections/\(account.id.uuidString)/Login-\(UUID().uuidString).result") : nil
            let launcher = try connection.launcher(account: account, login: login, project: project, logout: logout, loginOnly: login, completion: completion)
            guard openExternal(launcher) else { throw UsageError.unavailable("Could not open Terminal. Click Sign in to try again, or allow Terminal to open .command files.") }
            if let completion {
                claudeCompletions[account.id] = completion
                waitingForClaude[account.id] = Date()
                notice = "Finish Claude’s browser sign-in once. Ai-llowance will read your limits automatically; no chat or open Terminal is needed afterward."
            }
        } catch { notice = safeMessage(error); errors[account.id] = safeMessage(error) }
    }
    func cancelClaudeSignIn(_ account: Account) {
        waitingForClaude[account.id] = nil
        if let url = claudeCompletions.removeValue(forKey: account.id) { try? FileManager.default.removeItem(at: url) }
        errors[account.id] = "Sign-in not completed. Close its Terminal window before trying again."
        authenticationRequired.insert(account.id)
        var schedule = PollState(); schedule.failed(UsageError.authentication, at: Date()); schedules[account.id] = schedule
        notice = nil
    }
    func checkClaudeSignIns(at date: Date = Date()) {
        for (id, started) in waitingForClaude {
            guard let account = accounts.first(where: { $0.id == id }), let url = claudeCompletions[id] else { continue }
            if let data = try? Paths.readData(url, limit: 15), data.count < 16 {
                waitingForClaude[id] = nil; claudeCompletions[id] = nil
                try? FileManager.default.removeItem(at: url)
                if String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "0" {
                    schedules[id] = PollState(); errors[id] = nil
                    authenticationRequired.remove(id); claudeSignedIn[id] = true
                } else {
                    errors[id] = "Claude sign-in did not finish. Try again; if Keychain is locked, unlock it first."
                    authenticationRequired.insert(id)
                    var schedule = PollState(); schedule.failed(UsageError.authentication, at: date); schedules[id] = schedule
                }
                notice = nil
            } else if date.timeIntervalSince(started) >= 600 { cancelClaudeSignIn(account) }
        }
    }
    func retryConnection(_ account: Account) {
        if authenticationRequired.contains(account.id) { schedules[account.id] = PollState() }
        refresh(force: true)
    }
    func needsSignIn(_ account: Account) -> Bool {
        authenticationRequired.contains(account.id) || (account.kind == .claudeCode && claudeSignedIn[account.id] == false)
            || (account.kind == .codex && !account.usesExistingCodex && snapshots[account.id] == nil && errors[account.id] == nil)
    }
    func duplicateIdentity(_ account: Account) -> String? {
        guard let identity = snapshots[account.id]?.identity?.lowercased(), !identity.isEmpty else { return nil }
        return accounts.first { $0.id != account.id && $0.kind == account.kind && snapshots[$0.id]?.identity?.lowercased() == identity }?.name
    }
    func setAccountAppearance(_ account: Account, name: String, menu: String?, dashboard: String?, graph: String?) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !demo, !readOnly, !name.isEmpty, name.utf8.count <= 4096,
              [menu, dashboard, graph].compactMap({ $0 }).allSatisfy({ $0.range(of: "^[0-9A-Fa-f]{6}$", options: .regularExpression) != nil }),
              let index = accounts.firstIndex(where: { $0.id == account.id }) else { return false }
        let old = accounts[index]
        accounts[index].name = name
        accounts[index].menuColorHex = menu; accounts[index].dashboardColorHex = dashboard; accounts[index].graphColorHex = graph
        do { try persist(); return true }
        catch { accounts[index] = old; notice = "Could not save account appearance."; return false }
    }
    func rename(_ account: Account, to name: String) {
        guard name.utf8.count <= 4096, let index = accounts.firstIndex(where: { $0.id == account.id }), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let old = accounts[index].name
        accounts[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try persist() } catch { accounts[index].name = old; notice = "Could not save the account name." }
    }
    func replaceKey(_ account: Account, secret: String) throws {
        guard !demo, !readOnly, account.kind.isAPI, accounts.contains(where: { $0.id == account.id }) else { throw UsageError.storage }
        guard !refreshing, !removing else { throw UsageError.unavailable("Wait for the current refresh to finish, then save the key.") }
        try keychain.save(secret.trimmingCharacters(in: .whitespacesAndNewlines), for: account.id)
        connectionVersions[account.id] = UUID()
        clearCachedReading(account)
        schedules[account.id] = PollState(); snapshots[account.id] = nil; errors[account.id] = nil
        refresh(force: true)
    }
    func toggle(_ account: Account) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index].enabled.toggle()
        do { try persist() } catch { accounts[index].enabled.toggle(); notice = "Could not save the account setting." }
        refresh()
    }
    func togglePause() {
        paused.toggle()
        do { try persist() } catch { paused.toggle(); notice = "Could not save the refresh setting." }
        if paused { refreshTask?.cancel() } else { refresh() }
        scheduleHeartbeat()
    }
    func remove(_ account: Account) async {
        guard !demo, !refreshing, !removing, signingIn == nil else { return }
        removing = true
        defer { removing = false }
        do {
            // Verify local settings are writable before changing any provider credentials.
            try persist()
            if account.kind.isAPI { try keychain.delete(account.id) }
            if account.kind == .codex && !account.usesExistingCodex {
                guard let executable else { throw UsageError.unavailable("Locate Codex CLI before removing this account so its stored sign-in can be cleared.") }
                try await CodexAdapter(executable: executable, root: root).logout(account: account)
            }
            if account.kind == .claudeCode { try ClaudeConnection.uninstall(account: account, root: root, existingConfig: existingClaudeConfig) }
            let old = accounts, oldBrowserChoice = browserChoices[account.id.uuidString]
            accounts.removeAll { $0.id == account.id }
            browserChoices[account.id.uuidString] = nil
            do { try persist() } catch { accounts = old; browserChoices[account.id.uuidString] = oldBrowserChoice; throw error }
            snapshots[account.id] = nil; errors[account.id] = nil; schedules[account.id] = nil; claudeSignedIn[account.id] = nil
            clearCachedReading(account)
            if selectedAccountID == account.id { selectedAccountID = nil }
            authenticationRequired.remove(account.id); connectionVersions[account.id] = nil
            waitingForClaude[account.id] = nil; claudeCompletions[account.id] = nil
            if account.kind == .claudeCode { try? FileManager.default.removeItem(at: Paths.feed(account.id, root: root)) }
            if account.kind == .codex && !account.usesExistingCodex { try? FileManager.default.removeItem(at: Paths.profile(account.id, root: root)) }
        } catch { notice = safeMessage(error) }
    }
    func refresh(force: Bool = false) {
        now = Date()
        defer { scheduleHeartbeat() }
        checkClaudeSignIns(at: now)
        guard !shuttingDown, !demo, !paused, !sleeping, !removing, !offline else { return }
        if refreshing { pendingManualRefresh = pendingManualRefresh || force; return }
        let due = accounts.filter {
            $0.enabled && signingIn != $0.id && waitingForClaude[$0.id] == nil && (schedules[$0.id] ?? PollState()).shouldRefresh(at: now, manual: force)
        }
        guard !due.isEmpty else { return }
        refreshing = true
        refreshTask = Task {
            defer {
                refreshing = false
                let pending = pendingManualRefresh
                pendingManualRefresh = false
                if pending { refresh(force: true) }
                deliverAlerts()
                scheduleHeartbeat()
            }
            for account in due {
                if Task.isCancelled || paused || sleeping || offline { return }
                guard accounts.contains(where: { $0.id == account.id && $0.enabled }), signingIn != account.id, waitingForClaude[account.id] == nil else { continue }
                let version = connectionVersions[account.id]
                let start = Date()
                var schedule = schedules[account.id] ?? PollState()
                do {
                    var snapshot = try await fetchAccount(account, at: start)
                    snapshot.freshnessInterval = account.kind.freshnessInterval
                    _ = try snapshot.validated()
                    try Task.checkCancellation()
                    guard accounts.contains(where: { $0.id == account.id && $0.enabled }), connectionVersions[account.id] == version,
                          signingIn != account.id, waitingForClaude[account.id] == nil else { continue }
                    if !account.kind.isAPI, let index = accounts.firstIndex(where: { $0.id == account.id }) {
                        let identity = try CodexIdentity.validate(snapshot, for: accounts[index], accounts: accounts, snapshots: snapshots)
                        if accounts[index].expectedIdentity == nil {
                            accounts[index].expectedIdentity = identity
                            do { try persist() }
                            catch { accounts[index].expectedIdentity = nil; throw error }
                        }
                    }
                    processAlert(snapshot, account: accounts.first(where: { $0.id == account.id }) ?? account)
                    snapshots[account.id] = snapshot; errors[account.id] = nil; authenticationRequired.remove(account.id)
                    cachedAccounts.remove(account.id)
                    if let currentAccount = accounts.first(where: { $0.id == account.id }) { saveCachedReading(snapshot, account: currentAccount) }
                    schedule.succeeded(at: Date(), interval: refreshInterval(for: account.kind, visible: interfaceVisible, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled))
                    if account.kind == .claudeCode {
                        claudeSignedIn[account.id] = true
                        if notice?.hasPrefix("Finish Claude’s browser sign-in once.") == true { notice = nil }
                        // Once direct usage works, restore the user's old status line. No bridge is needed.
                        do { if restoredLegacyFeeds.insert(account.id).inserted { try claudeConnection().uninstall(account: account) } }
                        catch { notice = "Usage is connected, but the previous status-line setting could not be restored automatically." }
                    }
                } catch is CancellationError { return }
                catch {
                    guard !Task.isCancelled, connectionVersions[account.id] == version,
                          accounts.contains(where: { $0.id == account.id && $0.enabled }) else { continue }
                    if [.authentication, .missingCredential, .forbidden].contains(error as? UsageError) { authenticationRequired.insert(account.id) }
                    if let identityError = error as? UsageError {
                        switch identityError {
                        case .accountChanged, .duplicateAccount:
                            snapshots[account.id] = nil
                            clearCachedReading(account)
                            authenticationRequired.insert(account.id)
                        default: break
                        }
                    }
                    errors[account.id] = safeMessage(error); schedule.failed(error, at: Date())
                    if account.kind == .claudeCode && error as? UsageError == .authentication {
                        claudeSignedIn[account.id] = false
                    }
                }
                schedules[account.id] = schedule
            }
            now = Date()
        }
    }
    private func fetchAccount(_ account: Account, at date: Date) async throws -> Snapshot {
        if let fetchOverride { return try await fetchOverride(account, date) }
        let adapter: any UsageAdapter
        switch account.kind {
        case .openAIAPI, .claudeAPI: adapter = costs
        case .openRouter, .vercelGateway, .xai: adapter = balances
        case .copilot:
            guard let copilotExecutable else { throw UsageError.unavailable("Install Copilot CLI, then choose Check again in Settings.") }
            adapter = CopilotAdapter(executable: copilotExecutable)
        case .claudeCode:
            guard let claudeExecutable else { throw UsageError.unavailable("Install or locate Claude Code in Advanced connections to read usage.") }
            adapter = ClaudeUsageAdapter(executable: claudeExecutable, root: root)
        case .codex:
            guard let executable else { throw UsageError.unavailable("Install or locate Codex CLI in Advanced connections to read usage.") }
            adapter = CodexAdapter(executable: executable, root: root)
        }
        return try await adapter.fetch(account: account, now: date)
    }
    func signIn(_ account: Account, openBrowser: Bool = true) {
        guard signingIn == nil, waitingForClaude.isEmpty, !removing, let executable, !demo, !readOnly,
              accounts.contains(where: { $0.id == account.id }) else {
            notice = "Wait for refresh to finish and make sure Codex CLI is installed."; return
        }
        connectionVersions[account.id] = UUID()
        codexSignInURL = nil
        signingIn = account.id
        errors[account.id] = nil
        snapshots[account.id] = nil
        clearCachedReading(account)
        loginTask = Task { [self] in
            do {
                try await CodexAdapter(executable: executable, root: root).login(account: account) { [weak self] url in
                    try await MainActor.run {
                        try Task.checkCancellation()
                        guard let self else { throw CancellationError() }
                        self.codexSignInURL = url
                        if openBrowser && !self.openLink(url, for: account) {
                            self.notice = "Browser did not open. Copy the sign-in link into the browser profile for this account."
                        }
                    }
                }
                schedules[account.id] = PollState(); errors[account.id] = nil; authenticationRequired.remove(account.id)
            } catch {
                errors[account.id] = error is CancellationError ? "Sign-in cancelled. Click Sign in to try again." : safeMessage(error)
                authenticationRequired.insert(account.id)
                var schedule = PollState(); schedule.failed(UsageError.authentication, at: Date()); schedules[account.id] = schedule
            }
            codexSignInURL = nil
            signingIn = nil; refresh(force: true)
        }
    }
    func copyCodexSignInLink() {
        guard signingIn != nil, let url = codexSignInURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
    func cancelSignIn() { loginTask?.cancel() }
    func shutdown() async {
        shuttingDown = true
        heartbeat?.cancel(); heartbeat = nil; network.cancel()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers = []
        refreshTask?.cancel(); loginTask?.cancel(); connectionTask?.cancel()
        await refreshTask?.value
        await loginTask?.value
        await connectionTask?.value
        await cacheTask?.value
    }
    func chooseExecutable() { chooseTool(.codex) }
    func chooseClaudeExecutable() { chooseTool(.claudeCode) }
    func chooseCopilotExecutable() { chooseTool(.copilot) }
    private func chooseTool(_ kind: ConnectionKind) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose the installed \(kind.provider.title) CLI."
        let remember = NSButton(checkboxWithTitle: "Remember this location until the file changes", target: nil, action: nil)
        panel.accessoryView = remember
        guard panel.runModal() == .OK, let url = panel.url,
              let record = RememberedExecutable(url: url) else { return }
        if kind == .codex { executable = url }
        else if kind == .claudeCode { claudeExecutable = url }
        else { copilotExecutable = url }
        rememberedTools[kind.rawValue] = remember.state == .on ? record : nil
        do { try persist() } catch { notice = "Could not remember the CLI location." }
        for account in accounts where account.kind == kind { schedules[account.id] = PollState() }
        refresh(force: true)
    }
    func rediscoverTools() {
        guard !demo else { return }
        func detected(_ kind: ConnectionKind, current: URL?, discover: () -> URL?) -> URL? {
            if let record = rememberedTools[kind.rawValue] {
                if let valid = record.validatedURL { return valid }
                if notice == nil { notice = "A remembered CLI file changed. Choose its location again, or use the detected installation." }
                return discover()
            }
            return current.flatMap { FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil } ?? discover()
        }
        executable = detected(.codex, current: executable, discover: CodexAdapter.findExecutable)
        claudeExecutable = detected(.claudeCode, current: claudeExecutable, discover: ClaudeConnection.findExecutable)
        copilotExecutable = detected(.copilot, current: copilotExecutable, discover: CopilotAdapter.findExecutable)
        browserProfiles = BrowserProfile.discover()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        loginItemNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }
    func setInterfaceVisible(_ value: Bool) {
        let becameVisible = value && !interfaceVisible
        let changed = value != interfaceVisible
        interfaceVisible = value
        if changed {
            let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            for account in accounts {
                schedules[account.id]?.adjustHealthyInterval(refreshInterval(for: account.kind, visible: value, lowPower: lowPower))
            }
        }
        if becameVisible { rediscoverTools(); refresh(force: true) }
        scheduleHeartbeat()
    }
    private func scheduleHeartbeat() {
        guard !shuttingDown, let heartbeat else { return }
        let delay = heartbeatDelay(at: Date())
        heartbeat.schedule(deadline: .now() + delay, leeway: .seconds(delay > 60 ? 10 : 1))
    }
    // Expire displayed readings on time without increasing provider polling.
    // Past deadlines are ignored, so a paused/stale account never creates a busy loop.
    func heartbeatDelay(at date: Date) -> TimeInterval {
        var delay: TimeInterval = interfaceVisible ? 60 : 900
        for account in accounts where account.enabled {
            guard let snapshot = snapshots[account.id] else { continue }
            var boundaries = snapshot.applicableWindows(for: account.kind).compactMap(\.resetsAt)
            boundaries.append(snapshot.observedAt.addingTimeInterval((snapshot.freshnessInterval ?? 900) + 1))
            if snapshot.costUSD != nil, let periodStart = snapshot.periodStart {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                if let nextMonth = calendar.date(byAdding: .month, value: 1, to: periodStart) { boundaries.append(nextMonth) }
            }
            for boundary in boundaries where boundary > date { delay = min(delay, boundary.timeIntervalSince(date)) }
        }
        if !waitingForClaude.isEmpty { delay = min(delay, 15) }
        if !paused && !offline && !sleeping && !refreshing {
            for account in accounts where account.enabled && signingIn != account.id && waitingForClaude[account.id] == nil {
                delay = min(delay, max(1, (schedules[account.id]?.nextAttempt ?? date).timeIntervalSince(date)))
            }
        }
        return max(1, delay)
    }
    func connectCopilot() {
        guard !demo, !readOnly, !removing else { return }
        rediscoverTools()
        guard copilotExecutable != nil else { notice = "Install Copilot CLI, then click Check again."; return }
        if let existing = accounts.first(where: { $0.kind == .copilot }) {
            selectedAccountID = existing.id; retryConnection(existing); return
        }
        do {
            let account = try add(name: "Copilot", kind: .copilot, secret: "", existing: true)
            selectedAccountID = account.id
        } catch { notice = safeMessage(error) }
    }
    func openCopilotSignIn() {
        guard !demo, let copilotExecutable else { return }
        let file = root.appendingPathComponent("Copilot/Sign in.command")
        let script = "#!/bin/zsh\nexport PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin\nunset GH_TOKEN GITHUB_TOKEN COPILOT_GITHUB_TOKEN\n" + ShellQuote.argument(copilotExecutable.path) + " login\nprintf '%s\n' 'Return to Ai-llowance and click Check sign-in.'\n"
        do { try Paths.writePrivate(Data(script.utf8), to: file, executable: true); _ = openExternal(file) }
        catch { notice = safeMessage(error) }
    }
    func history(for account: Account) -> [UsageHistoryPoint] { usageHistory[account.id] ?? [] }
    func isCached(_ account: Account) -> Bool { cachedAccounts.contains(account.id) }
    private func saveCachedReading(_ snapshot: Snapshot, account: Account) {
        guard !demo, !readOnly else { return }
        var points = usageHistory[account.id] ?? []
        let point = UsageHistoryPoint(timestamp: snapshot.observedAt, remainingPercent: AllowanceStatus.evaluate(snapshot: snapshot, kind: account.kind, now: now).remainingPercent, balanceUSD: snapshot.balanceUSD, costUSD: snapshot.costUSD)
        let status = AllowanceStatus.evaluate(snapshot: snapshot, kind: account.kind, now: now)
        if ![.unavailable, .stale, .restricted].contains(status.state),
           points.last.map({ point.timestamp.timeIntervalSince($0.timestamp) >= 300 }) ?? true { points.append(point) }
        usageHistory[account.id] = Array(points.filter { snapshot.observedAt.timeIntervalSince($0.timestamp) <= 604800 }.suffix(96))
        let previous = cacheTask, root = root
        cacheTask = Task.detached(priority: .utility) {
            await previous?.value
            _ = try? SnapshotCache(root: root).save(snapshot, for: account)
        }
    }
    private func clearCachedReading(_ account: Account) {
        cachedAccounts.remove(account.id); usageHistory[account.id] = nil
        alerts.remove(account.id)
        pendingAlerts.removeAll { $0.accountID == account.id }
        guard !demo, !readOnly else { return }
        let previous = cacheTask, root = root, state = alerts
        cacheTask = Task.detached(priority: .utility) {
            await previous?.value
            try? SnapshotCache(root: root).remove(account)
            try? Paths.write(state, to: root.appendingPathComponent("alerts.json"))
        }
    }
    private func processAlert(_ snapshot: Snapshot, account: Account) {
        if let alert = alerts.observe(account: account, snapshot: snapshot, now: Date()), notificationsEnabled {
            pendingAlerts.append(alert)
        }
    }
    private func deliverAlerts() {
        guard !demo, !readOnly else { return }
        let state = alerts, root = root, previous = cacheTask
        cacheTask = Task.detached(priority: .utility) {
            await previous?.value
            let file = root.appendingPathComponent("alerts.json")
            if let data = try? JSONEncoder().encode(state), (try? Paths.readData(file)) != data { try? Paths.writePrivate(data, to: file) }
        }
        let alerts = pendingAlerts; pendingAlerts = []
        guard notificationsEnabled, !alerts.isEmpty, !paused, !sleeping, !offline else { return }
        let content = UNMutableNotificationContent()
        content.title = alerts.count == 1 ? alerts[0].title : "\(alerts.count) allowance updates"
        content.body = alerts.prefix(3).map { alert in
            let name = accounts.first(where: { $0.id == alert.accountID })?.name ?? "Account"
            return name + " · " + alert.message
        }.joined(separator: "\n")
        content.userInfo = ["accountID": alerts[0].accountID.uuidString]
        let request = UNNotificationRequest(identifier: "allowance-update", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        guard !demo else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginItemNeedsApproval = SMAppService.mainApp.status == .requiresApproval
            if loginItemNeedsApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { notice = "macOS could not change launch at login. Open System Settings → General → Login Items." }
    }
    func setNotificationsEnabled(_ enabled: Bool) {
        guard !demo, !readOnly, !shuttingDown else { return }
        let version = UUID()
        notificationRequestVersion = version
        if !enabled {
            let previous = notificationsEnabled
            notificationsEnabled = false
            pendingAlerts = []
            do { try persist() }
            catch { notificationsEnabled = previous; notice = "Could not save the notification setting." }
            return
        }
        Task {
            do {
                let accepted = try await requestNotificationAuthorization()
                guard notificationRequestVersion == version, !shuttingDown else { return }
                let previous = notificationsEnabled
                notificationsEnabled = accepted
                do { try persist() }
                catch { notificationsEnabled = previous; notice = "Could not save the notification setting."; return }
                if !accepted { notice = "Allow notifications for Ai-llowance in System Settings to receive allowance alerts." }
            } catch {
                guard notificationRequestVersion == version, !shuttingDown else { return }
                notice = "Could not enable notifications. Check System Settings → Notifications."
            }
        }
    }
    func browserProfileID(_ account: Account) -> String? { browserChoices[account.id.uuidString] }
    func setBrowserProfile(_ account: Account, id: String?) {
        guard id == nil || browserProfiles.contains(where: { $0.id == id }) else { return }
        let old = browserChoices[account.id.uuidString]
        browserChoices[account.id.uuidString] = id
        do { try persist() } catch { browserChoices[account.id.uuidString] = old; notice = "Could not save the browser choice." }
    }
    @discardableResult private func openLink(_ url: URL, for account: Account) -> Bool {
        if let profile = browserProfileID(account) {
            guard browserProfiles.contains(where: { $0.id == profile }),
                  let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else {
                notice = "The chosen Chrome profile is unavailable. Choose a browser profile again for this account."
                return false
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = ["--profile-directory=\(profile)", url.absoluteString]
            NSWorkspace.shared.openApplication(at: chrome, configuration: configuration) { [weak self] _, error in
                if error != nil { Task { @MainActor in self?.notice = "Chrome could not open the selected profile. Check the browser choice for this account." } }
            }
            return true
        }
        return openExternal(url)
    }
    func openUsage(_ account: Account) { _ = openLink(account.kind.dashboard, for: account) }
    func safeMessage(_ error: Error) -> String {
        if let known = error as? UsageError { return known.localizedDescription }
        if error is DecodingError { return UsageError.invalidData.localizedDescription }
        return "Could not refresh. Check the connection and try again. Last known data is preserved."
    }
}
