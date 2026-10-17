import Foundation

extension Snapshot {
    /// Overall allowance only. A model-specific limit cannot describe an entire account.
    public func applicableWindows(for kind: ConnectionKind) -> [QuotaWindow] {
        switch kind {
        case .claudeCode:
            return [sessionWindow(for: kind), primaryWeeklyWindow(for: kind)].compactMap { $0 }
        case .codex:
            let named = windows.filter { $0.id.lowercased().hasPrefix("codex.") || $0.label.lowercased().hasPrefix("codex ·") }
            return named.isEmpty ? [sessionWindow(for: kind), primaryWeeklyWindow(for: kind)].compactMap { $0 } : named
        case .copilot: return windows
        case .openRouter: return windows // A budget reset also expires its cached dollar balance.
        case .openAIAPI, .claudeAPI, .vercelGateway, .xai: return []
        }
    }

    /// Equal exhausted limits only recover after every applicable limit resets.
    /// An unknown reset must not be replaced with a promise from another window.
    public func limitingWindow(for kind: ConnectionKind) -> QuotaWindow? {
        applicableWindows(for: kind).min { first, second in
            if first.remainingPercent != second.remainingPercent { return first.remainingPercent < second.remainingPercent }
            switch (first.resetsAt, second.resetsAt) {
            case (nil, .some): return true
            case (.some, nil): return false
            case let (.some(firstReset), .some(secondReset)) where firstReset != secondReset: return firstReset > secondReset
            default: return first.id < second.id
            }
        }
    }
}

public struct AllowanceStatus: Equatable, Sendable {
    public enum State: String, Codable, Sendable { case ready, low, exhausted, restricted, stale, unavailable, unlimited }
    public let state: State
    public let title: String
    public let symbol: String
    public let detail: String?
    public let remainingPercent: Double?
    public let resetAt: Date?

    public static func evaluate(snapshot: Snapshot?, kind: ConnectionKind, now: Date = Date(), hasError: Bool = false) -> Self {
        guard let snapshot, (try? snapshot.validated()) != nil else { return Self(.unavailable, "No reading", "questionmark.circle") }
        if hasError { return Self(.unavailable, "Check connection", "exclamationmark.circle") }
        if snapshot.providerRestricted == true { return Self(.restricted, "Restricted", "hand.raised", detail: snapshot.note) }
        let windows = snapshot.applicableWindows(for: kind)
        if snapshot.isStale(at: now, windows: windows) { return Self(.stale, "Needs refresh", "clock.arrow.circlepath") }
        if kind.isBalance {
            let isBudget = kind == .openRouter
            guard let balance = snapshot.balanceUSD else { return Self(.unavailable, isBudget ? "No key budget" : "No balance", "questionmark.circle") }
            let title = isBudget ? (balance <= 0 ? "Budget exhausted" : "Budget remaining") : (balance <= 0 ? "Credits empty" : "Credits available")
            return Self(balance <= 0 ? .exhausted : .ready, title,
                        balance <= 0 ? "exclamationmark.circle.fill" : "checkmark.circle", detail: snapshot.balanceLabel,
                        resetAt: windows.compactMap(\.resetsAt).min())
        }
        if kind.isAPI {
            guard snapshot.costUSD != nil else { return Self(.unavailable, "No report", "questionmark.circle") }
            return Self(.ready, "Spending report", "dollarsign.circle", detail: "Month to date")
        }
        guard let limiting = snapshot.limitingWindow(for: kind) else {
            return snapshot.unlimited == true ? Self(.unlimited, "Unlimited", "infinity") : Self(.unavailable, "No allowance", "questionmark.circle")
        }
        let remaining = limiting.remainingPercent
        let state: State = remaining <= 0 ? .exhausted : (remaining <= 20 ? .low : .ready)
        return Self(state, state == .exhausted ? "Allowance empty" : (state == .low ? "Running low" : "Available"),
                    state == .ready ? "checkmark.circle" : "exclamationmark.circle.fill", detail: limiting.label,
                    remainingPercent: remaining, resetAt: limiting.resetsAt)
    }

    private init(_ state: State, _ title: String, _ symbol: String, detail: String? = nil, remainingPercent: Double? = nil, resetAt: Date? = nil) {
        self.state = state; self.title = title; self.symbol = symbol; self.detail = detail
        self.remainingPercent = remainingPercent; self.resetAt = resetAt
    }
    public func resetText(at now: Date = Date()) -> String? {
        guard let resetAt else { return nil }
        let seconds = resetAt.timeIntervalSince(now)
        guard seconds > 0 else { return "Refresh to verify reset" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes < 60 { return "Resets in \(minutes)m" }
        if minutes < 1440 { return "Resets in \(minutes / 60)h \(minutes % 60)m" }
        return "Resets in \(minutes / 1440)d \((minutes % 1440) / 60)h"
    }
}
