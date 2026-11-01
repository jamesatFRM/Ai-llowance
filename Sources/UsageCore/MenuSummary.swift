import Foundation

public enum WeeklyMenuLabel: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, short, full
    public var id: String { rawValue }
    public var title: String {
        switch self { case .none: return "None"; case .short: return "w"; case .full: return "Week" }
    }
}

public enum SessionMenuLabel: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, short, full
    public var id: String { rawValue }
    public var title: String {
        switch self { case .none: return "None"; case .short: return "5h"; case .full: return "5-Hour" }
    }
}

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
public enum DashboardChartStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case mixed, matrix, glow, line, area, bars, dots, ring, pie, gauge
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .mixed: "Overview"; case .matrix: "Dot matrix"; case .glow: "Glow"; case .line: "Line"; case .area: "Area"; case .bars: "Bars"
        case .dots: "Dots"; case .ring: "Ring"; case .pie: "Pie"; case .gauge: "Gauge"
        }
    }
    public var isCurrentAllowance: Bool { self == .ring || self == .pie || self == .gauge }
    public var symbol: String {
        switch self {
        case .mixed: "rectangle.3.group"; case .matrix: "circle.grid.3x3.fill"; case .glow, .line: "chart.xyaxis.line"; case .area: "chart.line.uptrend.xyaxis"
        case .bars: "chart.bar.fill"; case .dots: "circle.grid.3x3.fill"
        case .ring: "circle.circle"; case .pie: "chart.pie.fill"; case .gauge: "gauge.with.dots.needle.67percent"
        }
    }
}

public struct MenuPreferences: Codable, Equatable, Sendable {
    public var dashboardChartFullScale = false
    public var dashboardChartStyle: DashboardChartStyle = .mixed
    public var theme: AppTheme = .automatic
    public var liquidGlass = true
    public var display: MenuDisplay = .byAccount
    public var aggregation: MenuAggregation = .average
    public var showAccountNames = true
    public var showSessionInMenuBar = true
    public var weeklyMenuLabel: WeeklyMenuLabel = .short
    public var sessionMenuLabel: SessionMenuLabel = .short
    public var dropdownShowEmails = false
    public var dropdownShowResets = true
    public var dropdownShowBars = true
    public var dropdownShowHeadings = true
    public var dropdownRoomyRows = false
    public var detailedQuotaLabels = false
    public var colorByAllowance = false
    public var allAccounts = true
    public var selectedAccountIDs: Set<UUID> = []
    public var accountOrder: [UUID] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case liquidGlass, accountOrder, dashboardChartFullScale, dashboardChartStyle, dropdownShowEmails, dropdownShowResets, dropdownShowBars, dropdownShowHeadings, dropdownRoomyRows, sessionMenuLabel, weeklyMenuLabel, showSessionInMenuBar, colorByAllowance, theme, display, aggregation, showAccountNames, detailedQuotaLabels, allAccounts, selectedAccountIDs }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        dashboardChartFullScale = try values.decodeIfPresent(Bool.self, forKey: .dashboardChartFullScale) ?? false
        dashboardChartStyle = (try values.decodeIfPresent(String.self, forKey: .dashboardChartStyle)).flatMap(DashboardChartStyle.init(rawValue:)) ?? .mixed
        liquidGlass = try values.decodeIfPresent(Bool.self, forKey: .liquidGlass) ?? true
        theme = try values.decodeIfPresent(AppTheme.self, forKey: .theme) ?? .automatic
        display = try values.decodeIfPresent(MenuDisplay.self, forKey: .display) ?? .byAccount
        aggregation = try values.decodeIfPresent(MenuAggregation.self, forKey: .aggregation) ?? .average
        showAccountNames = try values.decodeIfPresent(Bool.self, forKey: .showAccountNames) ?? true
        showSessionInMenuBar = try values.decodeIfPresent(Bool.self, forKey: .showSessionInMenuBar) ?? true
        weeklyMenuLabel = try values.decodeIfPresent(WeeklyMenuLabel.self, forKey: .weeklyMenuLabel) ?? .short
        sessionMenuLabel = try values.decodeIfPresent(SessionMenuLabel.self, forKey: .sessionMenuLabel) ?? .short
        dropdownShowEmails = try values.decodeIfPresent(Bool.self, forKey: .dropdownShowEmails) ?? false
        dropdownShowResets = try values.decodeIfPresent(Bool.self, forKey: .dropdownShowResets) ?? true
        dropdownShowBars = try values.decodeIfPresent(Bool.self, forKey: .dropdownShowBars) ?? true
        dropdownShowHeadings = try values.decodeIfPresent(Bool.self, forKey: .dropdownShowHeadings) ?? true
        dropdownRoomyRows = try values.decodeIfPresent(Bool.self, forKey: .dropdownRoomyRows) ?? false
        detailedQuotaLabels = try values.decodeIfPresent(Bool.self, forKey: .detailedQuotaLabels) ?? false
        colorByAllowance = try values.decodeIfPresent(Bool.self, forKey: .colorByAllowance) ?? false
        allAccounts = try values.decodeIfPresent(Bool.self, forKey: .allAccounts) ?? true
        accountOrder = try values.decodeIfPresent([UUID].self, forKey: .accountOrder) ?? []
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
    public let primaryPeriod: String?
    public let sessionRemainingPercent: Double?
    public let showsSession: Bool
    public let accountCount: Int
    public let isUnlimited: Bool
    public let balanceUSD: Decimal?
    public let isBalance: Bool
    public let colorHex: String?
    public var isLastKnown = false
    public init(provider: MenuProvider?, label: String, remainingPercent: Double?, accountCount: Int, isUnlimited: Bool = false,
                balanceUSD: Decimal? = nil, isBalance: Bool = false, colorHex: String? = nil, primaryPeriod: String? = nil, sessionRemainingPercent: Double? = nil, showsSession: Bool = false) {
        self.provider = provider; self.label = label; self.remainingPercent = remainingPercent
        self.primaryPeriod = primaryPeriod; self.sessionRemainingPercent = sessionRemainingPercent; self.showsSession = showsSession
        self.accountCount = accountCount; self.isUnlimited = isUnlimited
        self.balanceUSD = balanceUSD; self.isBalance = isBalance; self.colorHex = colorHex
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
    /// Preserve the old provider order until customized; new accounts append.
    public static func orderedAccounts(_ accounts: [Account], preferences: MenuPreferences) -> [Account] {
        let defaults = MenuProvider.allCases.flatMap { provider in accounts.filter { $0.kind.provider == provider } }
        var seen = Set<UUID>()
        let saved = preferences.accountOrder.compactMap { id in
            accounts.first { $0.id == id }
        }.filter { seen.insert($0.id).inserted }
        return saved + defaults.filter { seen.insert($0.id).inserted }
    }

    public static func entries(accounts: [Account], snapshots: [UUID: Snapshot], unavailable: Set<UUID>,
                               preferences: MenuPreferences, now: Date, lastKnown: Set<UUID> = []) -> [MenuEntry] {
        let duplicateIDs = duplicateSubscriptionAccountIDs(in: accounts, snapshots: snapshots)
        let selected = orderedAccounts(accounts, preferences: preferences).filter {
            $0.enabled && (!$0.kind.isAPI || $0.kind.isBalance)
                && (preferences.allAccounts || preferences.selectedAccountIDs.contains($0.id))
        }

        func identityMatches(_ snapshot: Snapshot, account: Account) -> Bool {
            guard !duplicateIDs.contains(account.id) else { return false }
            guard let expected = CodexIdentity.normalized(account.expectedIdentity) else { return true }
            return expected == CodexIdentity.normalized(snapshot.identity)
        }
        func entry(_ group: [Account], label: String, icon: MenuProvider?) -> MenuEntry {
            let allUnlimited = !group.isEmpty && group.allSatisfy { account in
                guard (!unavailable.contains(account.id) || lastKnown.contains(account.id)), let snapshot = snapshots[account.id],
                      identityMatches(snapshot, account: account), snapshot.providerRestricted != true, snapshot.unlimited == true,
                      snapshot.applicableWindows(for: account.kind).isEmpty,
                      (try? snapshot.validated()) != nil, (!snapshot.isStale(at: now) || lastKnown.contains(account.id)) else { return false }
                return true
            }
            let values = group.compactMap { account -> Double? in
                guard (!unavailable.contains(account.id) || lastKnown.contains(account.id)), let snapshot = snapshots[account.id],
                      identityMatches(snapshot, account: account), snapshot.providerRestricted != true,
                      (try? snapshot.validated()) != nil else { return nil }
                let applicable = snapshot.applicableWindows(for: account.kind)
                guard let window = snapshot.displayWindow(for: account.kind),
                      (!snapshot.isStale(at: now, windows: applicable) || lastKnown.contains(account.id)) else { return nil }
                return window.remainingPercent
            }
            // Incomplete groups stay unavailable; silently dropping a depleted/unread account is misleading.
            let value: Double?
            if values.count != group.count || values.isEmpty { value = nil }
            else if preferences.aggregation == .lowest { value = values.min() }
            else { value = values.reduce(0, +) / Double(values.count) }
            let sessions = group.compactMap { account -> Double? in
                guard (!unavailable.contains(account.id) || lastKnown.contains(account.id)), let snapshot = snapshots[account.id],
                      identityMatches(snapshot, account: account), snapshot.providerRestricted != true,
                      (try? snapshot.validated()) != nil,
                      (!snapshot.isStale(at: now, windows: snapshot.applicableWindows(for: account.kind)) || lastKnown.contains(account.id)) else { return nil }
                return snapshot.sessionWindow(for: account.kind)?.remainingPercent
            }
            let sessionValue = sessions.count == group.count && !sessions.isEmpty
                ? (preferences.aggregation == .lowest ? sessions.min() : sessions.reduce(0, +) / Double(sessions.count)) : nil
            let periods = Set(group.compactMap { snapshots[$0.id]?.displayWindow(for: $0.kind)?.periodLabel })
            let period = periods.count == 1 ? periods.first : "Quota"
            // Do not invent a missing 5-hour window (for example, verified Ultra).
            // A grouped session percentage is meaningful only when every account reports it.
            let showSession = group.allSatisfy {
                ($0.kind == .claudeCode || $0.kind == .codex)
                    && snapshots[$0.id]?.sessionWindow(for: $0.kind) != nil
            } && period != "5h"
            var result = MenuEntry(provider: icon, label: label, remainingPercent: value, accountCount: group.count, isUnlimited: allUnlimited, colorHex: Set(group.compactMap(\.menuColorHex)).count == 1 && group.allSatisfy { $0.menuColorHex != nil } ? group.first?.menuColorHex : nil, primaryPeriod: period, sessionRemainingPercent: sessionValue, showsSession: showSession)
            result.isLastKnown = (value != nil || allUnlimited) && group.contains { lastKnown.contains($0.id) }
            return result
        }
        func balanceEntry(_ account: Account) -> MenuEntry {
            let balance: Decimal?
            if (!unavailable.contains(account.id) || lastKnown.contains(account.id)), let snapshot = snapshots[account.id],
               identityMatches(snapshot, account: account), (try? snapshot.validated()) != nil,
               (!snapshot.isStale(at: now) || lastKnown.contains(account.id)), snapshot.providerRestricted != true {
                balance = snapshot.balanceUSD
            } else { balance = nil }
            var result = MenuEntry(provider: account.kind.provider, label: account.name, remainingPercent: nil,
                             accountCount: 1, balanceUSD: balance, isBalance: true, colorHex: account.menuColorHex)
            result.isLastKnown = lastKnown.contains(account.id) && balance != nil
            return result
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
            var seenProviders = Set<MenuProvider>()
            let providers = selected.map { $0.kind.provider }.filter { seenProviders.insert($0).inserted }
            return providers.flatMap { icon in
                let group = allowanceAccounts(icon)
                let allowance = group.isEmpty ? [] : [entry(group, label: icon.title, icon: icon)]
                return allowance + balanceAccounts(icon).map(balanceEntry)
            }
        case .byAccount:
            return selected.map { account in
                account.kind.isBalance ? balanceEntry(account) : entry([account], label: account.name, icon: account.kind.provider)
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


extension QuotaWindow {
    public var periodLabel: String {
        if durationMinutes == 300 || id == "session" || id == "5-hour" { return "5h" }
        if durationMinutes == 10080 || id.hasPrefix("week.") || id == "7-day" { return "Week" }
        return label
    }
}
extension Snapshot {
    /// Display weekly allowance first; readiness/alerts still respect all limits.
    public func displayWindow(for kind: ConnectionKind) -> QuotaWindow? {
        primaryWeeklyWindow(for: kind) ?? limitingWindow(for: kind)
    }
}
