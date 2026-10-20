import Foundation
import Testing
@testable import UsageCore

@Test func recommendationsRequireFreshVerifiedSameProviderAccounts() throws {
    let now = Date()
    var first = Account(name: "First", kind: .codex); first.expectedIdentity = "one@example.com"
    var second = Account(name: "Second", kind: .codex); second.expectedIdentity = "two@example.com"
    var other = Account(name: "Other", kind: .claudeCode); other.expectedIdentity = "other@example.com"
    func reading(_ identity: String, _ used: Double, at: Date? = nil, restricted: Bool = false) throws -> Snapshot {
        var snapshot = Snapshot(observedAt: at ?? now, windows: [try QuotaWindow(id: "codex.week", label: "Week", usedPercent: used, resetsAt: now.addingTimeInterval(86400), durationMinutes: 10080)], identity: identity, source: "fixture")
        snapshot.providerRestricted = restricted
        return snapshot
    }
    let accounts = [first, second, other]
    var readings = [first.id: try reading(first.expectedIdentity!, 80), second.id: try reading(second.expectedIdentity!, 10), other.id: try reading(other.expectedIdentity!, 0)]
    func best(_ unavailable: Set<UUID> = []) -> UUID? {
        AccountRecommendation.best(kind: .codex, accounts: accounts, snapshots: readings, unavailable: unavailable, now: now)?.id
    }
    #expect(best() == second.id)
    #expect(best([second.id]) == first.id)
    readings[second.id] = try reading("wrong@example.com", 0)
    #expect(best() == first.id)
    readings[second.id] = try reading(second.expectedIdentity!, 0, restricted: true)
    #expect(best() == first.id)
    readings[second.id] = try reading(second.expectedIdentity!, 0, at: now.addingTimeInterval(-86400))
    #expect(best() == first.id)
    readings[first.id] = try reading(first.expectedIdentity!, 100)
    #expect(best() == nil)
}

@Test func duplicateIdentityIsNeverRecommended() throws {
    let now = Date()
    var one = Account(name: "One", kind: .codex); one.expectedIdentity = "same@example.com"
    var two = Account(name: "Two", kind: .codex); two.expectedIdentity = one.expectedIdentity
    let snapshot = Snapshot(observedAt: now, windows: [try QuotaWindow(id: "codex.week", label: "Week", usedPercent: 1, resetsAt: now.addingTimeInterval(80000), durationMinutes: 10080)], identity: one.expectedIdentity, source: "fixture")
    #expect(AccountRecommendation.best(kind: .codex, accounts: [one, two], snapshots: [one.id: snapshot, two.id: snapshot], unavailable: [], now: now) == nil)
}

@Test func detailedLabelsAreOptionalAndSurviveSaving() throws {
    let old = try JSONDecoder().decode(MenuPreferences.self, from: Data("{}".utf8))
    #expect(!old.detailedQuotaLabels)
    var preferences = old; preferences.detailedQuotaLabels = true
    #expect(try JSONDecoder().decode(MenuPreferences.self, from: JSONEncoder().encode(preferences)).detailedQuotaLabels)
}

@Test func oldHistoryStillDecodesWithoutWindowMetadata() throws {
    let point = UsageHistoryPoint(timestamp: Date(), remainingPercent: 40)
    let restored = try JSONDecoder().decode(UsageHistoryPoint.self, from: JSONEncoder().encode(point))
    #expect(restored.windowID == nil)
    #expect(restored.remainingPercent == 40)
}
