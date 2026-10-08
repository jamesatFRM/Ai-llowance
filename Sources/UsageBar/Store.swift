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
    @Published var removing = false
    @Published var connectingClaude = false
    @Published var claudeSignedIn: [UUID: Bool] = [:]
    @Published var notice: String?
    @Published var paused = false
    @Published var offline = false
    @Published var now = Date()
    let demo: Bool
    let root: URL
    var executable = CodexAdapter.findExecutable()
    var claudeExecutable = ClaudeConnection.findExecutable()
    private var schedules: [UUID: PollState] = [:]
    private var refreshTask: Task<Void, Never>?
    private var loginTask: Task<Void, Never>?
    private var timer: Timer?
    private let network = NWPathMonitor()
    private var sleeping = false
    private var readOnly = false
    private let costs = CostAdapter()
    private let keychain = KeychainStore()
    private struct Saved: Codable { var accounts: [Account]; var paused: Bool }

    init(demo: Bool = false, root: URL = Paths.root) {
        self.demo = demo; self.root = root
        if demo {
            let first = Account(name: "Personal", kind: .codex)
            let second = Account(name: "Studio", kind: .claudeCode)
            let third = Account(name: "Work organization", kind: .openAIAPI)
            accounts = [first, second, third]
            snapshots[first.id] = Snapshot(observedAt: now, windows: [try! QuotaWindow(id: "5h", label: "codex · 5h", usedPercent: 38, resetsAt: now.addingTimeInterval(7200)), try! QuotaWindow(id: "7d", label: "codex · 7d", usedPercent: 65, resetsAt: now.addingTimeInterval(172800))], identity: "personal@example.com", source: "Sample data")
            snapshots[second.id] = Snapshot(observedAt: now, windows: [try! QuotaWindow(id: "5h", label: "5-hour", usedPercent: 12, resetsAt: now.addingTimeInterval(3600))], identity: "studio@example.com", source: "Sample data", note: "Sample Claude plan limits.")
            snapshots[third.id] = Snapshot(observedAt: now, costUSD: Decimal(string: "24.18"), periodStart: CostAdapter.monthStart(now), source: "Sample data")
            return
        }
        let url = root.appendingPathComponent("accounts.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let saved = try JSONDecoder().decode(Saved.self, from: Data(contentsOf: url))
                accounts = saved.accounts; paused = saved.paused
            } catch { notice = "Account settings could not be read. The existing file was preserved. Restore accounts.json before adding accounts."; readOnly = true }
        }
        network.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor in self?.offline = offline; if !offline { self?.refresh() } }
        }
        network.start(queue: DispatchQueue(label: "UsageBar.network", qos: .utility))
        // A lightweight local due check avoids missing the one-minute deadline when a read
        // finishes just after a timer tick. Provider reads still happen only when due.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date(); self?.refresh() }
        }
        timer?.tolerance = 3
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = true; self?.refreshTask?.cancel(); self?.loginTask?.cancel() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sleeping = false; self?.now = Date(); self?.refresh() }
        }
    }
    var menuLabel: String {
        let values = accounts.filter { $0.enabled && errors[$0.id] == nil }.compactMap { snapshots[$0.id] }.filter { !$0.isStale(at: now) }.flatMap(\.windows)
        guard let remaining = values.map(\.remainingPercent).min() else { return "Usage" }
        return "\(Int(remaining))% left"
    }
    private func persist() throws {
        guard !readOnly else { throw UsageError.storage }
        if !demo { try Paths.write(Saved(accounts: accounts, paused: paused), to: root.appendingPathComponent("accounts.json")) }
    }
    @discardableResult
    func add(name: String, kind: ConnectionKind, secret: String, existing: Bool, refreshAfter: Bool = true) throws -> Account {
        guard !demo, !readOnly else { throw UsageError.storage }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw UsageError.invalidData }
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
        let count = accounts.filter { $0.kind == kind }.count
        return count == 0 ? provider : "\(provider) \(count + 1)"
    }
    func connectOpenAI(existing: Bool = false) {
        guard !demo, signingIn == nil, !refreshing else { return }
        guard executable != nil else { notice = "Install Codex CLI once, then click Connect OpenAI. If it is already installed, use Choose Codex CLI below."; return }
        do {
            let account = try add(name: automaticName("OpenAI", kind: .codex), kind: .codex, secret: "", existing: existing, refreshAfter: false)
            if existing { refresh(force: true) } else { signIn(account) }
        } catch { notice = safeMessage(error) }
    }
    private func claudeConnection() throws -> ClaudeConnection {
        guard let claudeExecutable else { throw UsageError.unavailable("Install Claude Code once, then click Connect Claude. If it is installed elsewhere, use Choose Claude CLI below.") }
        return ClaudeConnection(root: root, executable: claudeExecutable,
            bundledBridge: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/UsageBridge"))
    }
    func connectClaude(existing: Bool) {
        guard !demo, !connectingClaude, !readOnly else { return }
        if existing && accounts.contains(where: { $0.kind == .claudeCode && $0.usesExistingClaude == true }) {
            notice = "Your current Claude Code is already connected. Use Add another Claude account for a separate login."; return
        }
        connectingClaude = true
        Task {
            defer { connectingClaude = false }
            do {
                let connection = try claudeConnection()
                let account = Account(name: automaticName("Claude", kind: .claudeCode), kind: .claudeCode, usesExistingClaude: existing)
                let signedIn = existing ? ((try? await connection.authStatus(account: account)) ?? false) : false
                try Paths.prepare(connection.config(account))
                claudeSignedIn[account.id] = signedIn
                accounts.append(account)
                do { try persist() }
                catch { accounts.removeAll { $0.id == account.id }; try? connection.uninstall(account: account); throw error }
                if !signedIn {
                    let launcher = try connection.launcher(account: account, login: true, loginOnly: true)
                    guard NSWorkspace.shared.open(launcher) else { throw UsageError.unavailable("Could not open Claude’s sign-in. Click Sign in to Claude to try again.") }
                    notice = "Finish Claude’s browser sign-in once. UsageBar will read your limits automatically; no chat or open Terminal is needed afterward."
                } else { notice = nil }
                schedules[account.id] = PollState(); refresh(force: true)
            } catch { notice = safeMessage(error) }
        }
    }
    func openClaude(_ account: Account, login: Bool = false, chooseProject: Bool = false, logout: Bool = false) {
        do {
            let connection = try claudeConnection()
            if login || logout {
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
            let launcher = try connection.launcher(account: account, login: login, project: project, logout: logout, loginOnly: login)
            guard NSWorkspace.shared.open(launcher) else { throw UsageError.unavailable("Could not open Terminal. Make sure Terminal can open .command files.") }
        } catch { notice = safeMessage(error) }
    }
    func rename(_ account: Account, to name: String) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let old = accounts[index].name
        accounts[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try persist() } catch { accounts[index].name = old; notice = "Could not save the account name." }
    }
    func replaceKey(_ account: Account, secret: String) throws {
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
            if account.kind == .claudeCode { try? FileManager.default.removeItem(at: Paths.feed(account.id, root: root)) }
            if account.kind == .codex && !account.usesExistingCodex { try? FileManager.default.removeItem(at: Paths.profile(account.id, root: root)) }
        } catch { notice = safeMessage(error) }
    }
    func refresh(force: Bool = false) {
        guard !demo, !paused, !sleeping, !refreshing, !removing else { return }
        refreshing = true
        refreshTask = Task {
            defer { refreshing = false }
            for account in accounts where account.enabled && signingIn != account.id {
                if Task.isCancelled { return }
                if offline { continue }
                let start = Date()
                var schedule = schedules[account.id] ?? PollState()
                // Manual refresh never bypasses provider backoff; healthy reads are capped at one per 30 seconds.
                guard schedule.shouldRefresh(at: start, manual: force) else { continue }
                do {
                    let adapter: any UsageAdapter
                    switch account.kind {
                    case .openAIAPI, .claudeAPI: adapter = costs
                    case .claudeCode:
                        guard let claudeExecutable else { throw UsageError.unavailable("Install or locate Claude Code to read this account’s usage.") }
                        adapter = ClaudeUsageAdapter(executable: claudeExecutable, root: root)
                    case .codex:
                        guard let executable else { throw UsageError.unavailable("Install Codex CLI, or choose its executable in Accounts.") }
                        adapter = CodexAdapter(executable: executable, root: root)
                    }
                    let snapshot = try await adapter.fetch(account: account, now: start)
                    try Task.checkCancellation()
                    guard accounts.contains(where: { $0.id == account.id && $0.enabled }) else { continue }
                    snapshots[account.id] = snapshot; errors[account.id] = nil
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
    func signIn(_ account: Account) {
        guard signingIn == nil, !refreshing, !removing, let executable, !demo else {
            notice = "Wait for refresh to finish and make sure Codex CLI is installed."; return
        }
        signingIn = account.id
        snapshots[account.id] = nil
        loginTask = Task {
            do {
                try await CodexAdapter(executable: executable, root: root).login(account: account) { url in
                    Task { @MainActor in NSWorkspace.shared.open(url) }
                }
                schedules[account.id] = PollState(); errors[account.id] = nil
            } catch is CancellationError { errors[account.id] = "Sign-in cancelled." }
            catch { errors[account.id] = safeMessage(error) }
            signingIn = nil; refresh(force: true)
        }
    }
    func cancelSignIn() { loginTask?.cancel() }
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
    }
    func safeMessage(_ error: Error) -> String {
        if let known = error as? UsageError { return known.localizedDescription }
        if error is DecodingError { return UsageError.invalidData.localizedDescription }
        return "Could not refresh. Check the connection and try again. Last known data is preserved."
    }
}
