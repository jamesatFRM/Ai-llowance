import Foundation

public struct UsageAlert: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case low, exhausted, recovered, resetReminder }
    public let kind: Kind
    public let accountID: UUID
    public let remainingPercent: Double?
    public let resetAt: Date?
    public let title: String
    public let message: String
}

/// Observes successful fetches only. Never call this with a cache load or a clock tick.
public struct AlertTracker: Codable, Sendable {
    private struct Observation: Codable {
        var identity: String?
        var connectionKind: ConnectionKind
        var scopeID: String?
        var state: AllowanceStatus.State
        var observedAt: Date
        var issued: [String]
    }
    private struct ResetReminder: Codable {
        let identity: String
        let kind: ConnectionKind
        let scopeID: String?
        let credentialRevision: UUID?
        let reset: Date
    }
    private var resetReminderRules: [String: ResetReminder]?
    private var resetReminders: [UUID: ResetReminder]?
    private var observations: [UUID: Observation] = [:]
    public init() {}
    public mutating func remove(_ id: UUID) { observations[id] = nil; resetReminders?[id] = nil; resetReminderRules = resetReminderRules?.filter { !$0.key.hasPrefix(id.uuidString + "|") } }
    public mutating func retain(accounts: [Account]) {
        let ids = Set(accounts.map(\.id)); observations = observations.filter { ids.contains($0.key) }; resetReminders = resetReminders?.filter { ids.contains($0.key) }; resetReminderRules = resetReminderRules?.filter { entry in entry.key.split(separator: "|").first.flatMap { UUID(uuidString: String($0)) }.map { ids.contains($0) } ?? false }
    }
    public mutating func observeResetReminder(account: Account, snapshot: Snapshot, now: Date,
                                              leadHours: Int, minimumRemaining: Int, rule: Int = 0) -> UsageAlert? {
        guard account.enabled, !account.kind.isAPI, (1...168).contains(leadHours), (0...100).contains(minimumRemaining), (0...1).contains(rule),
              (try? snapshot.validated()) != nil, snapshot.providerRestricted != true,
              let identity = CodexIdentity.normalized(account.expectedIdentity),
              identity == CodexIdentity.normalized(snapshot.identity),
              let weekly = snapshot.primaryWeeklyWindow(for: account.kind),
              !snapshot.isStale(at: now, windows: [weekly]), let reset = weekly.resetsAt,
              reset > now, reset.timeIntervalSince(now) <= Double(leadHours) * 3600,
              weekly.remainingPercent >= Double(minimumRemaining) else { return nil }
        let key = account.id.uuidString + "|" + String(rule)
        if let prior = resetReminderRules?[key] ?? (rule == 0 ? resetReminders?[account.id] : nil), prior.identity == identity, prior.kind == account.kind,
           prior.scopeID == account.scopeID, prior.credentialRevision == account.credentialRevision,
           abs(prior.reset.timeIntervalSince(reset)) <= 120 { return nil }
        var reminders = resetReminderRules ?? [:]
        guard reminders.count < 2000 || reminders[key] != nil else { return nil }
        reminders[key] = ResetReminder(identity: identity, kind: account.kind, scopeID: account.scopeID,
                                             credentialRevision: account.credentialRevision, reset: reset)
        resetReminderRules = reminders
        let hours = max(1, Int(ceil(reset.timeIntervalSince(now) / 3600)))
        let time = hours % 24 == 0 ? "\(hours / 24) day\(hours == 24 ? "" : "s")" : "\(hours) hour\(hours == 1 ? "" : "s")"
        return UsageAlert(kind: .resetReminder, accountID: account.id, remainingPercent: weekly.remainingPercent,
                          resetAt: reset, title: "\(account.name) · weekly reset soon",
                          message: "\(Int(weekly.remainingPercent))% of your weekly allowance remains. Resets in about \(time).")
    }
    public mutating func observe(account: Account, snapshot: Snapshot, now: Date = Date()) -> UsageAlert? {
        let status = AllowanceStatus.evaluate(snapshot: snapshot, kind: account.kind, now: now)
        guard [.ready, .low, .exhausted, .unlimited].contains(status.state) else { return nil }
        // API spending is a report, not an allowance threshold.
        guard !account.kind.isAPI || account.kind.isBalance else { return nil }
        let identity = CodexIdentity.normalized(account.expectedIdentity)
        if !account.kind.isAPI || identity != nil {
            guard identity != nil, identity == CodexIdentity.normalized(snapshot.identity) else { return nil }
        }
        let previous = observations[account.id]
        guard previous.map({ snapshot.observedAt > $0.observedAt }) ?? true else { return nil }
        let sameConnection = previous?.identity == identity && previous?.connectionKind == account.kind && previous?.scopeID == account.scopeID
        var observation = Observation(identity: identity, connectionKind: account.kind, scopeID: account.scopeID,
                                      state: status.state, observedAt: snapshot.observedAt,
                                      issued: sameConnection ? (previous?.issued ?? []) : [])
        defer {
            if observations.count < 1000 || observations[account.id] != nil { observations[account.id] = observation }
        }
        guard sameConnection, let previous else { return nil }
        if previous.state == .exhausted, status.state != .exhausted, status.resetAt == nil {
            // A confirmed credit top-up starts a new cycle even when the provider
            // has no scheduled reset date. Repeated reads still do not alert.
            observation.issued = []
        }
        let alertKind: UsageAlert.Kind?
        if status.state == .exhausted, previous.state != .exhausted { alertKind = .exhausted }
        else if previous.state == .exhausted, status.state != .exhausted { alertKind = .recovered }
        else if status.state == .low, previous.state == .ready || previous.state == .unlimited { alertKind = .low }
        else { alertKind = nil }
        guard let alertKind else { return nil }
        let limiting = snapshot.limitingWindow(for: account.kind)
        let cycle = "\(limiting?.id ?? "balance")|\(status.resetAt.map { String($0.timeIntervalSince1970) } ?? "unspecified")|\(alertKind.rawValue)"
        guard !observation.issued.contains(cycle) else { return nil }
        observation.issued.append(cycle); observation.issued = Array(observation.issued.suffix(24))
        let title: String
        let message: String
        if account.kind.isBalance {
            let label: String
            switch account.kind {
            case .openRouter: label = "key budget"
            case .xai: label = "prepaid credits"
            case .vercelGateway: label = "team credits"
            default: label = "credits"
            }
            if alertKind == .exhausted {
                title = "\(account.name) · \(label) empty"
                message = "The provider reports no \(label) remaining." + (status.resetText(at: now).map { " " + $0 + "." } ?? "")
            } else {
                title = "\(account.name) · \(label) \(account.kind == .openRouter ? "replenished" : "restored")"
                message = account.kind == .openRouter
                    ? "A fresh report shows spending budget remaining. Account credits and model limits still apply."
                    : "A fresh report confirms positive \(label). Other provider limits may still apply."
            }
        } else { switch alertKind {
        case .low:
            title = "\(account.name) is running low"
            message = "\(Int(status.remainingPercent ?? 0))% left in \(limiting?.label ?? "the current allowance")."
        case .exhausted:
            title = "\(account.name) has no allowance left"
            message = status.resetText(at: now) ?? "Open Ai-llowance to check other accounts."
        case .resetReminder: return nil
        case .recovered:
            title = "\(account.name) is available again"
            message = "A fresh provider reading confirms available allowance."
        } }
        return UsageAlert(kind: alertKind, accountID: account.id, remainingPercent: status.remainingPercent,
                          resetAt: status.resetAt, title: title, message: message)
    }
}
