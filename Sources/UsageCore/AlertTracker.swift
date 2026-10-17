import Foundation

public struct UsageAlert: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case low, exhausted, recovered }
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
    private var observations: [UUID: Observation] = [:]
    public init() {}
    public mutating func remove(_ id: UUID) { observations[id] = nil }
    public mutating func retain(accounts: [Account]) {
        let ids = Set(accounts.map(\.id)); observations = observations.filter { ids.contains($0.key) }
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
        let limiting = snapshot.applicableWindows(for: account.kind).min { $0.remainingPercent < $1.remainingPercent }
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
        case .recovered:
            title = "\(account.name) is available again"
            message = "A fresh provider reading confirms available allowance."
        } }
        return UsageAlert(kind: alertKind, accountID: account.id, remainingPercent: status.remainingPercent,
                          resetAt: status.resetAt, title: title, message: message)
    }
}
