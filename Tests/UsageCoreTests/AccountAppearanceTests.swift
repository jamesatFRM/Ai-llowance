import Foundation
import Testing
@testable import UsageCore

@Test func accountColorsSurviveSavingAndLegacySettingsStillLoad() throws {
    var account = Account(name: "Personal", kind: .codex)
    account.menuColorHex = "FFAA33"
    account.graphColorHex = "33AAFF"
    let data = try JSONEncoder().encode(account)
    let decoded = try JSONDecoder().decode(Account.self, from: data)
    #expect(decoded == account)
    var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    legacy.removeValue(forKey: "menuColorHex")
    legacy.removeValue(forKey: "graphColorHex")
    let restored = try JSONDecoder().decode(Account.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(restored.menuColorHex == nil && restored.graphColorHex == nil)
    let preferences = try JSONDecoder().decode(MenuPreferences.self, from: Data("{}".utf8))
    #expect(!preferences.colorByAllowance)
}
@Test func combinedMenuColorsRequireAgreement() {
    var a = Account(name: "A", kind: .codex), b = Account(name: "B", kind: .codex)
    a.menuColorHex = "AAFF00"; b.menuColorHex = "FFAA00"
    var preferences = MenuPreferences(); preferences.display = .combined
    #expect(MenuSummary.entries(accounts: [a,b], snapshots: [:], unavailable: [], preferences: preferences, now: Date()).first?.colorHex == nil)
    b.menuColorHex = a.menuColorHex
    #expect(MenuSummary.entries(accounts: [a,b], snapshots: [:], unavailable: [], preferences: preferences, now: Date()).first?.colorHex == "AAFF00")
}

@Test func dashboardNamesDisambiguateOnlyCollisions() {
    var claude = Account(name: "Personal", kind: .claudeCode)
    var second = Account(name: "Personal", kind: .claudeCode)
    let codex = Account(name: "Personal", kind: .codex)
    claude.expectedIdentity = "one@example.com"
    second.expectedIdentity = "two@example.com"
    #expect(claude.dashboardLabel(in: [claude]) == "Personal")
    #expect(claude.dashboardLabel(in: [claude, codex]) == "Personal · Claude")
    let accounts = [claude, second, codex]
    #expect(claude.dashboardLabel(in: accounts).contains("one@example.com"))
    #expect(second.dashboardLabel(in: accounts).contains("two@example.com"))
    #expect(codex.dashboardLabel(in: accounts) == "Personal · OpenAI")
}
