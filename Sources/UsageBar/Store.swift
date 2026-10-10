import AppKit
import Combine
import Network
import UsageCore

@MainActor
final class AppStore: ObservableObject {
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
    let demo: Bool
    let root: URL
    var executable = CodexAdapter.findExecutable()
    var claudeExecutable = ClaudeConnection.findExecutable()
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
    private var sleeping = false
    private var readOnly = false
    private var shuttingDown = false
    private let costs = CostAdapter()
    private let keychain = KeychainStore()
    private struct Saved: Codable { var accounts: [Account]; var paused: Bool; var menuPreferences: MenuPreferences? }

    init(demo: Bool = false, root: URL = Paths.root, monitor: Bool = true,
         fetch: (@Sendable (Account, Date) async throws -> Snapshot)? = nil,
         openExternal: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.demo = demo; self.root = root; self.fetchOverride = fetch; self.openExternal = openExternal
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
            } catch { notice = "Account settings could not be read. The existing file was preserved. Restore accounts.json before adding accounts."; readOnly = true }
        }
        guard monitor else { return }
        network.pathUpdateHandler = { @Sendable [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor in self?.offline = offline; if !offline { self?.refresh() } }
        }
        network.start(queue: DispatchQueue(label: "Ai-llowance.network", qos: .utility))
        // Dispatch deadlines do not depend on AppKit's default/event-tracking run-loop mode.
        let heartbeat = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "Ai-llowance.heartbeat", qos: .utility))
        heartbeat.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(3))
        heartbeat.setEventHandler { @Sendable [weak self] in
            Task { @MainActor in self?.now = Date(); self?.refresh() }
        }
        self.heartbeat = heartbeat
        heartbeat.resume()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.refreshTask?.cancel(); self?.loginTask?.cancel() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = false; self?.now = Date(); self?.refresh() }
        }
    }
    var refreshSummary: String {
        if demo { return "Sample data" }
        if paused { return "Paused" }
        if offline { return "Offline" }
        if signingIn != nil || !waitingForClaude.isEmpty { return "Finish sign-in" }
        if refreshing { return "Updating…" }
        let active = accounts.filter { $0.enabled }
        if active.contains(where: { errors[$0.id] != nil }) { return "Check accounts" }
        guard !active.isEmpty else { return "Auto-refresh · 1 min" }
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
    func setShowAccountNames(_ value: Bool) { updateMenu { $0.showAccountNames = value } }
    func setMenuDisplay(_ value: MenuDisplay) { updateMenu { $0.display = value } }
    func setMenuAggregation(_ value: MenuAggregation) { updateMenu { $0.aggregation = value } }
    func setAllMenuAccounts(_ value: Bool) {
        updateMenu {
            if !value && $0.allAccounts { $0.selectedAccountIDs = Set(accounts.filter { !$0.kind.isAPI }.map(\.id)) }
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
            do { try Paths.write(Saved(accounts: accounts, paused: paused, menuPreferences: menuPreferences), to: root.appendingPathComponent("accounts.json")) }
            catch { throw UsageError.storage }
        }
    }
    @discardableResult
    func add(name: String, kind: ConnectionKind, secret: String, existing: Bool, refreshAfter: Bool = true) throws -> Account {
        guard !demo, !readOnly else { throw UsageError.storage }
        guard accounts.count < 1000, name.utf8.count <= 4096, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw UsageError.invalidData }
        if kind == .codex && existing && accounts.contains(where: { $0.usesExistingCodex }) {
            throw UsageError.unavailable("The existing Codex CLI profile is already connected.")
        }
        let account = Account(name: name.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, usesExistingCodex: kind == .codex && existing)
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
            if existing { refresh(force: true) } else { signIn(account) }
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
            if account.kind == .claudeCode { try claudeConnection().uninstall(account: account) }
            let old = accounts
            accounts.removeAll { $0.id == account.id }
            do { try persist() } catch { accounts = old; throw error }
            snapshots[account.id] = nil; errors[account.id] = nil; schedules[account.id] = nil; claudeSignedIn[account.id] = nil
            authenticationRequired.remove(account.id); connectionVersions[account.id] = nil
            waitingForClaude[account.id] = nil; claudeCompletions[account.id] = nil
            if account.kind == .claudeCode { try? FileManager.default.removeItem(at: Paths.feed(account.id, root: root)) }
            if account.kind == .codex && !account.usesExistingCodex { try? FileManager.default.removeItem(at: Paths.profile(account.id, root: root)) }
        } catch { notice = safeMessage(error) }
    }
    func refresh(force: Bool = false) {
        now = Date()
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
            }
            for account in due {
                if Task.isCancelled || paused || sleeping || offline { return }
                guard accounts.contains(where: { $0.id == account.id && $0.enabled }), signingIn != account.id, waitingForClaude[account.id] == nil else { continue }
                let version = connectionVersions[account.id]
                let start = Date()
                var schedule = schedules[account.id] ?? PollState()
                do {
                    let snapshot = try await fetchAccount(account, at: start)
                    try Task.checkCancellation()
                    guard accounts.contains(where: { $0.id == account.id && $0.enabled }), connectionVersions[account.id] == version,
                          signingIn != account.id, waitingForClaude[account.id] == nil else { continue }
                    if account.kind == .codex, let index = accounts.firstIndex(where: { $0.id == account.id }) {
                        let identity = try CodexIdentity.validate(snapshot, for: accounts[index], accounts: accounts, snapshots: snapshots)
                        if accounts[index].expectedIdentity == nil {
                            accounts[index].expectedIdentity = identity
                            do { try persist() }
                            catch { accounts[index].expectedIdentity = nil; throw error }
                        }
                    }
                    snapshots[account.id] = snapshot; errors[account.id] = nil; authenticationRequired.remove(account.id)
                    schedule.succeeded(at: Date())
                    if account.kind == .claudeCode {
                        claudeSignedIn[account.id] = true
                        if notice?.hasPrefix("Finish Claude’s browser sign-in once.") == true { notice = nil }
                        // Once direct usage works, restore the user's old status line. No bridge is needed.
                        do { try claudeConnection().uninstall(account: account) }
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
                            authenticationRequired.insert(account.id)
                        default: break
                        }
                    }
                    errors[account.id] = safeMessage(error); schedule.failed(error, at: Date())
                    if account.kind == .claudeCode && error as? UsageError == .authentication {
                        claudeSignedIn[account.id] = false
                        schedule.nextAttempt = Date().addingTimeInterval(60)
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
        loginTask = Task { [self] in
            do {
                try await CodexAdapter(executable: executable, root: root).login(account: account) { [weak self] url in
                    try await MainActor.run {
                        try Task.checkCancellation()
                        guard let self else { throw CancellationError() }
                        self.codexSignInURL = url
                        if openBrowser && !self.openExternal(url) {
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
        refreshTask?.cancel(); loginTask?.cancel(); connectionTask?.cancel()
        await refreshTask?.value
        await loginTask?.value
        await connectionTask?.value
    }
    func chooseExecutable() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose the installed Codex CLI executable."
        guard panel.runModal() == .OK, let url = panel.url, FileManager.default.isExecutableFile(atPath: url.path) else { return }
        executable = url
        // The choice is intentionally per launch; no arbitrary executable is restored silently.
        schedules = [:]; refresh(force: true)
    }
    func chooseClaudeExecutable() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose the installed Claude Code executable."
        guard panel.runModal() == .OK, let url = panel.url, FileManager.default.isExecutableFile(atPath: url.path) else { return }
        claudeExecutable = url
        for account in accounts where account.kind == .claudeCode { schedules[account.id] = PollState() }
        refresh(force: true)
    }
    func safeMessage(_ error: Error) -> String {
        if let known = error as? UsageError { return known.localizedDescription }
        if error is DecodingError { return UsageError.invalidData.localizedDescription }
        return "Could not refresh. Check the connection and try again. Last known data is preserved."
    }
}
