import Foundation

extension ConnectionKind {
    public var setupName: String {
        switch self {
        case .claudeCode: "Claude"
        case .codex: "Codex"
        case .grokSubscription: "Grok"
        case .copilot: "GitHub Copilot"
        case .openAIAPI: "OpenAI API"
        case .claudeAPI: "Claude API"
        case .vercelGateway: "Vercel AI Gateway"
        case .openRouter: "OpenRouter"
        case .xai: "xAI API credits"
        }
    }
    public var setupSummary: String {
        switch self {
        case .claudeCode: "Claude subscription · no API key"
        case .codex: "ChatGPT subscription · no API key"
        case .grokSubscription: "Shared subscription allowance"
        case .copilot: "Copilot subscription · preview"
        case .openAIAPI, .claudeAPI: "Organization spending · admin key required"
        case .openRouter: "Key spending budget"
        case .vercelGateway, .xai: "Prepaid API credits"
        }
    }
    public var supportsAdditionalAccounts: Bool { self != .copilot && self != .grokSubscription }
    public var setupTool: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex CLI"
        case .copilot: "Copilot CLI"
        case .grokSubscription: "Grok CLI"
        default: ""
        }
    }
    public func setupButton(installed: Bool) -> String {
        if !installed && !isAPI { return "Install " + setupTool }
        switch self {
        case .claudeCode, .codex: return "Sign in with " + setupName
        case .grokSubscription, .copilot: return "Connect " + setupName
        default: return "Get an API key"
        }
    }
}

public struct AccountSetupStatus: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, preparing, signingIn, checking, connected, needsSignIn, failed, paused, offline }
    public let phase: Phase
    public let title: String
    public let detail: String
    public var connected: Bool { phase == .connected }
    public var working: Bool { phase == .preparing || phase == .signingIn || phase == .checking }

    public static func make(kind: ConnectionKind, account: Account?, snapshot: Snapshot?, now: Date,
                            cached: Bool = false, preparing: Bool = false, signingIn: Bool = false,
                            refreshing: Bool = false, needsSignIn: Bool = false, failed: Bool = false,
                            paused: Bool = false, offline: Bool = false) -> Self {
        func state(_ phase: Phase, _ title: String, _ detail: String) -> Self { Self(phase: phase, title: title, detail: detail) }
        if offline { return state(.offline, "You’re offline", "Setup will continue when your internet connection returns.") }
        if signingIn { return state(.signingIn, "Finish signing in", kind == .claudeCode
            ? "Use the Terminal window and the browser it opens. We’ll check the account automatically."
            : "Finish in your browser, using the email you want to track.") }
        if preparing { return state(.preparing, "Opening sign-in…", "Your existing accounts stay connected.") }
        guard let account else { return state(.idle, "Ready to connect", "") }
        guard account.kind == kind else { return state(.failed, "Check the selected service", "This connection belongs to a different provider.") }
        if paused || !account.enabled { return state(.paused, "Refresh is paused", "Resume refresh to receive your first reading.") }
        if refreshing { return state(.checking, "Checking your account…", "Waiting for the provider’s first usage report.") }
        if needsSignIn { return state(.needsSignIn, kind.isAPI ? "Check your API key" : "Sign-in needs another try", "Your account is saved. Retry here without adding it again.") }
        if failed { return state(.failed, "Couldn’t read usage yet", "Your account is saved. Check the connection and retry.") }
        if snapshot?.providerRestricted == true { return state(.failed, "Provider access is restricted", "Your account is saved. Check access on the provider’s usage page.") }
        if let snapshot, (try? snapshot.validated()) != nil, !cached,
           !snapshot.isStale(at: now, windows: snapshot.applicableWindows(for: kind)) {
            if kind.isAPI {
                if (kind.isBalance ? snapshot.balanceUSD != nil : snapshot.costUSD != nil)
                    || (kind == .openRouter && snapshot.balanceLabel == "No key budget") {
                    return state(.connected, "Connected", snapshot.balanceLabel == "No key budget" ? "This key has no spending budget configured." : "Your first provider report is ready.")
                }
            } else if let expected = CodexIdentity.normalized(account.expectedIdentity),
                      expected == CodexIdentity.normalized(snapshot.identity),
                      AllowanceStatus.evaluate(snapshot: snapshot, kind: kind, now: now).state != .unavailable {
                return state(.connected, "Connected", account.expectedIdentity ?? "")
            }
            return state(.failed, "No usage report returned", "Your account is saved, but the provider hasn’t supplied a usable reading. Try again or check its usage page.")
        }
        return state(.checking, "Waiting for your first reading", "Your usage will appear here after the first successful check. You can leave this page and return later.")
    }

    public static func defaultName(kind: ConnectionKind, accounts: [Account]) -> String {
        let names = Set(accounts.filter { $0.kind == kind }.map { $0.name.lowercased() })
        var index = 1
        while names.contains((index == 1 ? kind.setupName : "\(kind.setupName) \(index)").lowercased()) { index += 1 }
        return index == 1 ? kind.setupName : "\(kind.setupName) \(index)"
    }
}
