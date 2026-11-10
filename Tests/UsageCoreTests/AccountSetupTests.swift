import Foundation
import Testing
@testable import UsageCore

private let setupNow = Date(timeIntervalSince1970: 1_800_000_000)
private func setupAccount(_ kind: ConnectionKind = .claudeCode) -> Account {
    var account = Account(name: "Fixture", kind: kind)
    account.expectedIdentity = "person@example.com"
    return account
}
private func setupReading() throws -> Snapshot {
    Snapshot(observedAt: setupNow, windows: [try QuotaWindow(id: "week.all models", label: "Week", usedPercent: 25,
        resetsAt: setupNow.addingTimeInterval(86400), durationMinutes: 10080)], identity: "PERSON@example.com", source: "Fixture")
}

@Test func setupAcceptsWeeklyOnlyPlansAndIgnoresExpiredModelSpecificLimits() throws {
    let account = setupAccount()
    var snapshot = try setupReading()
    #expect(AccountSetupStatus.make(kind: account.kind, account: account, snapshot: snapshot, now: setupNow).connected)
    snapshot.windows.append(try QuotaWindow(id: "week.sonnet", label: "Sonnet", usedPercent: 20,
        resetsAt: setupNow.addingTimeInterval(-60), durationMinutes: 10080))
    #expect(AccountSetupStatus.make(kind: account.kind, account: account, snapshot: snapshot, now: setupNow).connected)
}

@Test func setupRequiresTheVerifiedEmailAndARealAllowance() throws {
    let account = setupAccount()
    var snapshot = try setupReading()
    snapshot.identity = "someone-else@example.com"
    #expect(!AccountSetupStatus.make(kind: account.kind, account: account, snapshot: snapshot, now: setupNow).connected)
    snapshot.identity = nil
    #expect(!AccountSetupStatus.make(kind: account.kind, account: account, snapshot: snapshot, now: setupNow).connected)
    snapshot.identity = account.expectedIdentity; snapshot.windows = []
    let empty = AccountSetupStatus.make(kind: account.kind, account: account, snapshot: snapshot, now: setupNow)
    #expect(empty.phase == .failed)
    var unbound = account; unbound.expectedIdentity = nil
    #expect(!AccountSetupStatus.make(kind: account.kind, account: unbound, snapshot: try setupReading(), now: setupNow).connected)
}

@Test func savedExpiredInvalidAndRestrictedReportsCannotCompleteSetup() throws {
    let account = setupAccount(), snapshot = try setupReading()
    #expect(!AccountSetupStatus.make(kind: account.kind, account: account, snapshot: snapshot, now: setupNow, cached: true).connected)
    #expect(!AccountSetupStatus.make(kind: account.kind, account: account, snapshot: snapshot, now: setupNow.addingTimeInterval(3600)).connected)
    var invalid = snapshot; invalid.observedAt = setupNow.addingTimeInterval(3600)
    #expect(!AccountSetupStatus.make(kind: account.kind, account: account, snapshot: invalid, now: setupNow).connected)
    invalid = snapshot; invalid.windows[0].usedPercent = .nan
    #expect(!AccountSetupStatus.make(kind: account.kind, account: account, snapshot: invalid, now: setupNow).connected)
    var restricted = snapshot; restricted.providerRestricted = true
    #expect(AccountSetupStatus.make(kind: account.kind, account: account, snapshot: restricted, now: setupNow).phase == .failed)
}

@Test(arguments: [ConnectionKind.openAIAPI, .claudeAPI, .openRouter, .vercelGateway, .xai])
func APISetupUsesTheReportWithoutRequiringAnEmail(kind: ConnectionKind) {
    let account = Account(name: "API fixture", kind: kind)
    var snapshot = Snapshot(observedAt: setupNow, source: "Fixture")
    if kind.isBalance { snapshot.balanceUSD = 0 } else { snapshot.costUSD = 0 }
    #expect(AccountSetupStatus.make(kind: kind, account: account, snapshot: snapshot, now: setupNow).connected)
    if kind.isBalance { snapshot.balanceUSD = nil; snapshot.costUSD = 10 }
    else { snapshot.costUSD = nil; snapshot.balanceUSD = 10 }
    #expect(!AccountSetupStatus.make(kind: kind, account: account, snapshot: snapshot, now: setupNow).connected)
}

@Test func openRouterNoBudgetIsAValidReportAndNotAnInventedBalance() {
    let account = Account(name: "OpenRouter", kind: .openRouter)
    let snapshot = Snapshot(observedAt: setupNow, source: "Fixture", balanceLabel: "No key budget")
    let status = AccountSetupStatus.make(kind: .openRouter, account: account, snapshot: snapshot, now: setupNow)
    #expect(status.connected && status.detail.contains("no spending budget"))
    #expect(snapshot.balanceUSD == nil)
}

@Test func setupStatesShowWhatIsActuallyBlockingTheFirstReading() throws {
    let account = setupAccount(), snapshot = try setupReading()
    #expect(AccountSetupStatus.make(kind: account.kind, account: nil, snapshot: nil, now: setupNow).phase == .idle)
    #expect(AccountSetupStatus.make(kind: account.kind, account: nil, snapshot: nil, now: setupNow, preparing: true).phase == .preparing)
    #expect(AccountSetupStatus.make(kind: account.kind, account: account, snapshot: snapshot, now: setupNow, signingIn: true).phase == .signingIn)
    #expect(AccountSetupStatus.make(kind: account.kind, account: account, snapshot: snapshot, now: setupNow, refreshing: true, needsSignIn: true).phase == .checking)
    #expect(AccountSetupStatus.make(kind: account.kind, account: account, snapshot: snapshot, now: setupNow, needsSignIn: true).phase == .needsSignIn)
    #expect(AccountSetupStatus.make(kind: account.kind, account: account, snapshot: snapshot, now: setupNow, failed: true).phase == .failed)
    #expect(AccountSetupStatus.make(kind: account.kind, account: account, snapshot: snapshot, now: setupNow, paused: true).phase == .paused)
    #expect(AccountSetupStatus.make(kind: account.kind, account: account, snapshot: snapshot, now: setupNow, offline: true).phase == .offline)
    var disabled = account; disabled.enabled = false
    #expect(AccountSetupStatus.make(kind: account.kind, account: disabled, snapshot: snapshot, now: setupNow).phase == .paused)
    #expect(!AccountSetupStatus.make(kind: .codex, account: account, snapshot: snapshot, now: setupNow).connected)
}

@Test func setupNamesAvoidCollisionsWithoutMakingNamesMandatory() {
    let accounts = [Account(name: "VERCEL AI GATEWAY", kind: .vercelGateway),
                    Account(name: "Vercel AI Gateway 2", kind: .vercelGateway),
                    Account(name: "xAI API credits", kind: .xai)]
    #expect(AccountSetupStatus.defaultName(kind: .vercelGateway, accounts: accounts) == "Vercel AI Gateway 3")
    #expect(AccountSetupStatus.defaultName(kind: .xai, accounts: accounts) == "xAI API credits 2")
    #expect(AccountSetupStatus.defaultName(kind: .openAIAPI, accounts: accounts) == "OpenAI API")
}
