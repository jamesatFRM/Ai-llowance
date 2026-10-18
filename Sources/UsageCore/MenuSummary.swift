import Foundation

public enum MenuDisplay: String, Codable, CaseIterable, Identifiable, Sendable {
    case combined, byProvider, byAccount
    public var id: String { rawValue }
    public var title: String {
        switch self { case .combined: "All together"; case .byProvider: "By provider"; case .byAccount: "By account" }
    }
}
public enum MenuAggregation: String, Codable, CaseIterable, Identifiable, Sendable {
    case average, lowest
    public var id: String { rawValue }
    public var title: String { self == .average ? "Average remaining" : "Lowest remaining" }
}
public enum AppTheme: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, light, dark
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}
public struct MenuPreferences: Codable, Equatable, Sendable {
    public var theme: AppTheme = .automatic
    public var display: MenuDisplay = .byProvider
    public var aggregation: MenuAggregation = .average
    public var showAccountNames = true
    public var allAccounts = true
    public var selectedAccountIDs: Set<UUID> = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case theme, display, aggregation, showAccountNames, allAccounts, selectedAccountIDs }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        theme = try values.decodeIfPresent(AppTheme.self, forKey: .theme) ?? .automatic
        display = try values.decodeIfPresent(MenuDisplay.self, forKey: .display) ?? .byProvider
        aggregation = try values.decodeIfPresent(MenuAggregation.self, forKey: .aggregation) ?? .average
        showAccountNames = try values.decodeIfPresent(Bool.self, forKey: .showAccountNames) ?? true
        allAccounts = try values.decodeIfPresent(Bool.self, forKey: .allAccounts) ?? true
        selectedAccountIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .selectedAccountIDs) ?? []
    }
}
public enum MenuProvider: String, CaseIterable, Codable, Sendable {
    case claude, openAI, copilot, openRouter, vercelGateway, xai
    public var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .claude: "Claude"
        case .copilot: "Copilot"
        case .openRouter: "OpenRouter"
        case .vercelGateway: "AI Gateway"
        case .xai: "xAI"
        }
    }
}
public struct MenuEntry: Sendable, Equatable {
    public let provider: MenuProvider?
    public let label: String
    public let remainingPercent: Double?
    public let accountCount: Int
    public let isUnlimited: Bool
    public let balanceUSD: Decimal?
    public let isBalance: Bool
    public init(provider: MenuProvider?, label: String, remainingPercent: Double?, accountCount: Int, isUnlimited: Bool = false,
                balanceUSD: Decimal? = nil, isBalance: Bool = false) {
        self.provider = provider; self.label = label; self.remainingPercent = remainingPercent
        self.accountCount = accountCount; self.isUnlimited = isUnlimited
        self.balanceUSD = balanceUSD; self.isBalance = isBalance
    }
}

extension Snapshot {
    public func primaryWeeklyWindow(for kind: ConnectionKind) -> QuotaWindow? {
        switch kind {
        case .claudeCode:
            return weeklyWindows.first { $0.id == "week.all models" || $0.id == "7-day" }
        case .codex:
            if let codex = weeklyWindows.first(where: { $0.id.lowercased().hasPrefix("codex.") || $0.label.lowercased().hasPrefix("codex ·") }) { return codex }
            return weeklyWindows.count == 1 ? weeklyWindows.first : nil
        case .copilot: return windows.min { $0.remainingPercent < $1.remainingPercent }
        case .openAIAPI, .claudeAPI, .openRouter, .vercelGateway, .xai: return nil
        }
    }
}

public enum MenuSummary {
    public static func entries(accounts: [Account], snapshots: [UUID: Snapshot], unavailable: Set<UUID>,
                               preferences: MenuPreferences, now: Date) -> [MenuEntry] {
        let duplicateIDs = duplicateSubscriptionAccountIDs(in: accounts, snapshots: snapshots)
        let selected = accounts.filter {
            $0.enabled && (!$0.kind.isAPI || $0.kind.isBalance)
                && (preferences.allAccounts || preferences.selectedAccountIDs.contains($0.id))
        }
        func provider(_ account: Account) -> MenuProvider { account.kind.provider }
        func identityMatches(_ snapshot: Snapshot, account: Account) -> Bool {
            guard !duplicateIDs.contains(account.id) else { return false }
            guard let expected = CodexIdentity.normalized(account.expectedIdentity) else { return true }
            return expected == CodexIdentity.normalized(snapshot.identity)
        }
        func entry(_ group: [Account], label: String, icon: MenuProvider?) -> MenuEntry {
            let allUnlimited = !group.isEmpty && group.allSatisfy { account in
                guard !unavailable.contains(account.id), let snapshot = snapshots[account.id],
                      identityMatches(snapshot, account: account), snapshot.providerRestricted != true, snapshot.unlimited == true,
                      snapshot.applicableWindows(for: account.kind).isEmpty,
                      (try? snapshot.validated()) != nil, !snapshot.isStale(at: now) else { return false }
                return true
            }
            let values = group.compactMap { account -> Double? in
                guard !unavailable.contains(account.id), let snapshot = snapshots[account.id],
                      identityMatches(snapshot, account: account), snapshot.providerRestricted != true,
                      (try? snapshot.validated()) != nil else { return nil }
                let applicable = snapshot.applicableWindows(for: account.kind)
                guard let window = snapshot.limitingWindow(for: account.kind),
                      !snapshot.isStale(at: now, windows: applicable) else { return nil }
                return window.remainingPercent
            }
            // Incomplete groups stay unavailable; silently dropping a depleted/unread account is misleading.
            let value: Double?
            if values.count != group.count || values.isEmpty { value = nil }
            else if preferences.aggregation == .lowest { value = values.min() }
            else { value = values.reduce(0, +) / Double(values.count) }
            return MenuEntry(provider: icon, label: label, remainingPercent: value, accountCount: group.count, isUnlimited: allUnlimited)
        }
        func balanceEntry(_ account: Account) -> MenuEntry {
            let balance: Decimal?
            if !unavailable.contains(account.id), let snapshot = snapshots[account.id],
               identityMatches(snapshot, account: account), (try? snapshot.validated()) != nil,
               !snapshot.isStale(at: now), snapshot.providerRestricted != true {
                balance = snapshot.balanceUSD
            } else { balance = nil }
            return MenuEntry(provider: provider(account), label: account.name, remainingPercent: nil,
                             accountCount: 1, balanceUSD: balance, isBalance: true)
        }
        func allowanceAccounts(_ provider: MenuProvider? = nil) -> [Account] {
            selected.filter { !$0.kind.isBalance && (provider == nil || $0.kind.provider == provider) }
        }
        func balanceAccounts(_ provider: MenuProvider? = nil) -> [Account] {
            selected.filter { $0.kind.isBalance && (provider == nil || $0.kind.provider == provider) }
        }
        switch preferences.display {
        case .combined:
            let allowances = allowanceAccounts()
            return (allowances.isEmpty ? [] : [entry(allowances, label: "All accounts", icon: nil)])
                + balanceAccounts().map(balanceEntry)
        case .byProvider:
            return MenuProvider.allCases.flatMap { icon in
                let group = allowanceAccounts(icon)
                let allowance = group.isEmpty ? [] : [entry(group, label: icon.title, icon: icon)]
                return allowance + balanceAccounts(icon).map(balanceEntry)
            }
        case .byAccount:
            return MenuProvider.allCases.flatMap { icon in
                selected.filter { provider($0) == icon }.map { account in
                    account.kind.isBalance ? balanceEntry(account) : entry([account], label: account.name, icon: icon)
                }
            }
        }
    }
}

extension Snapshot {
    public func sessionWindow(for kind: ConnectionKind) -> QuotaWindow? {
        let sessions = windows.filter { $0.durationMinutes == 300 || $0.id == "session" || $0.id == "5-hour" }
        if kind == .claudeCode { return sessions.first { $0.id == "session" || $0.id == "5-hour" } }
        if kind == .codex {
            return sessions.first { $0.id.lowercased().hasPrefix("codex.") || $0.label.lowercased().hasPrefix("codex ·") }
                ?? (sessions.count == 1 ? sessions.first : nil)
        }
        return nil
    }
}

/// Shared by every quota bar. Exact 20% belongs to the critical band.
public enum AllowanceBand: Sendable {
    case normal, warning, critical
    public static func remaining(_ percent: Double) -> Self {
        if percent <= 20 { return .critical }
        if percent < 30 { return .warning }
        return .normal
    }
}
