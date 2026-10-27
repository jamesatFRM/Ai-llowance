import Foundation
import Testing
@testable import UsageCore

@Test func connectionPresentationSeparatesOfflineRetryAndReconnect() {
    let now = Date()
    let snapshot = Snapshot(observedAt: now.addingTimeInterval(-480), source: "Fixture")
    let offline = ConnectionPresentation.make(snapshot: snapshot, kind: .codex, now: now, offline: true, failed: true, failure: .timeout)
    #expect(offline.title == "Offline")
    #expect(offline.detail.contains("8m ago"))
    #expect(!offline.needsAction && offline.saved)
    let busy = ConnectionPresentation.make(snapshot: snapshot, kind: .codex, now: now, failed: true, failure: .rateLimited(600), retryAt: now.addingTimeInterval(600))
    #expect(busy.title == "Provider busy")
    #expect(busy.detail.contains("10m"))
    let auth = ConnectionPresentation.make(snapshot: snapshot, kind: .codex, now: now, reconnect: true)
    #expect(auth.needsAction)
    #expect(auth.title == "Reconnect required")
}

@Test func sessionExhaustionDoesNotClaimWeeklyAllowanceIsEmpty() throws {
    let now = Date()
    let snapshot = Snapshot(observedAt: now, windows: [
        try QuotaWindow(id: "week.all models", label: "Week", usedPercent: 20, durationMinutes: 10_080),
        try QuotaWindow(id: "session", label: "Session", usedPercent: 100, resetsAt: now.addingTimeInterval(300), durationMinutes: 300)
    ], source: "Fixture")
    let fresh = ConnectionPresentation.make(snapshot: snapshot, kind: .claudeCode, now: now)
    #expect(fresh.title == "5-hour limit reached")
    #expect(fresh.detail.contains("Weekly allowance remains"))
    #expect(!fresh.saved)
    let expired = ConnectionPresentation.make(snapshot: snapshot, kind: .claudeCode, now: now.addingTimeInterval(301))
    #expect(expired.saved)
    #expect(expired.title == "Saved reading")
}
