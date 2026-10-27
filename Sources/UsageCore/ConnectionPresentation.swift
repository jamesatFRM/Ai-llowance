import Foundation

/// One vocabulary for saved readings, recovery, and freshness on every surface.
public struct ConnectionPresentation: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let symbol: String
    public let needsAction: Bool
    public let saved: Bool
    public static func make(snapshot: Snapshot?, kind: ConnectionKind, now: Date, enabled: Bool = true,
                            offline: Bool = false, refreshing: Bool = false, reconnect: Bool = false,
                            cached: Bool = false, failed: Bool = false, networkFailure: Bool = false, failure: UsageError? = nil,
                            retryAt: Date? = nil) -> Self {
        let age = snapshot.map { reading -> String in
            let minutes = max(0, Int(now.timeIntervalSince(reading.observedAt) / 60))
            return minutes == 0 ? "Last checked just now" : minutes < 60 ? "Last checked \(minutes)m ago" : "Last checked \(minutes / 60)h ago"
        } ?? "No reading yet"
        func state(_ title: String, _ detail: String, _ symbol: String, action: Bool = false, saved: Bool = true) -> Self {
            Self(title: title, detail: detail, symbol: symbol, needsAction: action, saved: saved && snapshot != nil)
        }
        if !enabled { return state("Paused", age, "pause.circle") }
        if reconnect { return state("Reconnect required", "Sign in with this account’s saved email", "person.crop.circle.badge.exclamationmark", action: true) }
        if offline { return state("Offline", age + " · retries when online", "wifi.slash") }
        if refreshing { return state("Updating…", age, "arrow.triangle.2.circlepath") }
        if failed {
            let retry = retryAt.map { "Retry in \(max(1, Int(ceil($0.timeIntervalSince(now) / 60))))m" } ?? "Retrying automatically"
            if networkFailure { return state("Connection interrupted", age + " · " + retry, "wifi.exclamationmark") }
            switch failure {
            case .rateLimited: return state("Provider busy", age + " · " + retry, "clock")
            case .timeout: return state("Connection timed out", age + " · " + retry, "wifi.exclamationmark")
            case .server: return state("Provider unavailable", age + " · " + retry, "cloud")
            case .invalidData: return state("Report unavailable", "Open account details to check the provider tool", "exclamationmark.circle", action: true)
            case .storage, .unavailable: return state("Connection needs attention", age + " · open account details", "exclamationmark.circle", action: true)
            default: return state("Refresh failed", age + " · " + retry, "arrow.clockwise")
            }
        }
        if cached || snapshot?.isStale(at: now) == true { return state("Saved reading", age + " · awaiting refresh", "clock") }
        guard snapshot != nil else { return state("Waiting for reading", "Usage appears after the first successful check", "clock") }
        let status = AllowanceStatus.evaluate(snapshot: snapshot, kind: kind, now: now)
        if status.state == .exhausted, let session = snapshot?.sessionWindow(for: kind), session.remainingPercent <= 0,
           let weekly = snapshot?.primaryWeeklyWindow(for: kind), weekly.remainingPercent > 0 {
            return state("5-hour limit reached", "Weekly allowance remains", status.symbol, saved: false)
        }
        return state(status.title, age, status.symbol, saved: false)
    }
}
