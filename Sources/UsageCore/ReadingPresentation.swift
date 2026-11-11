import Foundation

/// The same value, window name and reset wording on every account surface.
/// A reset date never implies that the provider has replenished an allowance.
public struct ReadingPresentation: Equatable, Sendable {
    public let value: String
    public let title: String
    public let reset: String
    public let period: String?
    public let saved: Bool
    public let session: QuotaWindow?
    public let window: QuotaWindow?

    public init(snapshot: Snapshot?, kind: ConnectionKind, now: Date, saved: Bool = false) {
        let snapshot = snapshot.flatMap { try? $0.validated() }
        let window = snapshot?.displayWindow(for: kind)
        self.window = window
        self.period = window?.periodLabel
        self.saved = snapshot != nil && (saved || snapshot!.isStale(at: now, windows: snapshot!.applicableWindows(for: kind)))
        self.session = snapshot?.sessionWindow(for: kind).flatMap { $0.id == window?.id ? nil : $0 }
        if snapshot?.unlimited == true { value = "Unlimited" }
        else if let balance = snapshot?.balanceUSD { value = balance.formatted(.currency(code: "USD")) }
        else if let cost = snapshot?.costUSD, kind.isAPI { value = cost.formatted(.currency(code: "USD")) }
        else if let window { value = "\(Int(window.remainingPercent))% left" }
        else if snapshot?.balanceLabel == "No key budget" { value = "Not set" }
        else { value = "No reading" }

        if kind.isBalance { title = kind == .openRouter ? "Key budget · USD" : "Credit balance · USD" }
        else if kind.isAPI { title = "Month-to-date spending · USD" }
        else if period == "Week" { title = "Weekly allowance" }
        else if period == "5h" { title = "5-hour allowance" }
        else if let window { title = window.label }
        else { title = "Allowance remaining" }

        if snapshot == nil { reset = "Awaiting first reading" }
        else if kind.isAPI { reset = kind.isBalance ? "Provider balance" : "Calendar month · UTC" }
        else if snapshot?.unlimited == true { reset = "No limit reported" }
        else if let window { reset = Self.resetText(window.resetsAt, at: now) }
        else { reset = "Limit not reported" }
    }

    public var accessibilitySummary: String {
        (saved ? "Last known reading. " : "") + title + ": " + value + ". " + reset
    }
    public var compactTitle: String {
        guard saved else { return title }
        switch period {
        case "Week": return "Last known · Weekly"
        case "5h": return "Last known · 5-hour"
        default: return title.contains("USD") ? "Last known · USD" : "Last known reading"
        }
    }

    public static func windowLabel(_ window: QuotaWindow) -> String {
        if window.durationMinutes == 300 || window.id == "session" { return "5-hour" }
        // Claude can report both an overall weekly allowance and a separate
        // named limit. Their shared duration does not make them the same quota.
        if window.id == "week.all models" || window.id == "7-day" { return "Weekly · All models" }
        if window.id.hasPrefix("week.") {
            let scope = window.id.dropFirst("week.".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !scope.isEmpty { return "Weekly · \(scope)" }
        }
        if window.durationMinutes == 10_080 { return "Weekly" }
        return window.label.replacingOccurrences(of: " · 7d", with: "")
    }

    public static func resetText(_ date: Date?, at now: Date) -> String {
        guard let date else { return "Reset not reported" }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "Reset passed · refresh to verify" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes < 60 { return "Resets in \(minutes)m" }
        if minutes < 1440 { return "Resets in \(minutes / 60)h" + (minutes % 60 == 0 ? "" : " \(minutes % 60)m") }
        return "Resets " + date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

public enum AccountRecoveryAction: String, Sendable {
    case finishSignIn, resume, reconnect, replaceKey, checkSignIn, retry, wait, openUsage
    public var title: String {
        switch self {
        case .finishSignIn: "Finish sign-in"
        case .resume: "Resume account"
        case .reconnect: "Reconnect account"
        case .replaceKey: "Update API key"
        case .checkSignIn: "Check sign-in"
        case .retry: "Retry connection"
        case .wait: "Waiting to retry"
        case .openUsage: "Open usage"
        }
    }
    public static func make(kind: ConnectionKind, enabled: Bool, signingIn: Bool, reconnect: Bool,
                            sharedSignIn: Bool, failed: Bool, blocked: Bool) -> Self {
        if signingIn { return .finishSignIn }
        if !enabled { return .resume }
        if reconnect { return kind.isAPI ? .replaceKey : sharedSignIn ? .checkSignIn : .reconnect }
        if blocked { return .wait }
        return failed ? .retry : .openUsage
    }
}
