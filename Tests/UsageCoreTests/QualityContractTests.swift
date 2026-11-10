import Foundation
import Darwin
import Testing
@testable import UsageCore

private let qualityNow = Date(timeIntervalSince1970: 1_800_000_000)
private func qualitySnapshot(weekly: Double = 75, session: Double? = 90, at date: Date = qualityNow) throws -> Snapshot {
    var windows = [try QuotaWindow(id: "week.all models", label: "All models", usedPercent: 100 - weekly,
                                   resetsAt: date.addingTimeInterval(86400), durationMinutes: 10080)]
    if let session { windows.append(try QuotaWindow(id: "session", label: "Session", usedPercent: 100 - session,
        resetsAt: date.addingTimeInterval(3600), durationMinutes: 300)) }
    return Snapshot(observedAt: date, windows: windows, identity: "fixture@example.com", source: "Fixture")
}

@Test func primaryReadingContractKeepsWeeklyAndFiveHourDistinct() throws {
    let snapshot = try qualitySnapshot(weekly: 97, session: 40)
    let reading = ReadingPresentation(snapshot: snapshot, kind: .claudeCode, now: qualityNow)
    #expect(reading.value == "97% left")
    #expect(reading.title == "Weekly allowance")
    #expect(reading.session?.remainingPercent == 40)
    #expect(!reading.saved)
    let entry = try #require(MenuSummary.entries(accounts: [Account(name: "Fixture", kind: .claudeCode)],
        snapshots: [:], unavailable: [], preferences: MenuPreferences(), now: qualityNow).first)
    #expect(entry.remainingPercent == nil) // Missing is never fabricated as zero.
    #expect(ReadingPresentation(snapshot: nil, kind: .claudeCode, now: qualityNow).value == "No reading")
    let zero = ReadingPresentation(snapshot: try qualitySnapshot(weekly: 0, session: nil), kind: .claudeCode, now: qualityNow)
    #expect(zero.value == "0% left" && zero.session == nil)
}

@Test func savedReadingsAndPassedResetsNeverPromiseReplenishment() throws {
    let old = try qualitySnapshot(at: qualityNow.addingTimeInterval(-7200))
    let reading = ReadingPresentation(snapshot: old, kind: .claudeCode, now: qualityNow)
    #expect(reading.saved)
    #expect(reading.accessibilitySummary.hasPrefix("Last known"))
    #expect(ReadingPresentation.resetText(old.windows[1].resetsAt, at: qualityNow) == "Reset passed · refresh to verify")
    #expect(ReadingPresentation.resetText(nil, at: qualityNow) == "Reset not reported")
    let low = try qualitySnapshot(weekly: 97, session: 10)
    #expect(ConnectionPresentation.make(snapshot: low, kind: .claudeCode, now: qualityNow).title == "5-hour allowance low")
    #expect(!ConnectionPresentation.make(snapshot: low, kind: .claudeCode, now: qualityNow, refreshing: true).saved)
    #expect(ConnectionPresentation.make(snapshot: old, kind: .claudeCode, now: qualityNow, refreshing: true).saved)
}

@Test func APIReadingContractNeverDescribesSpendingAsCreditsOrQuota() {
    let cost = Snapshot(observedAt: qualityNow, costUSD: 12, source: "Fixture")
    let spending = ReadingPresentation(snapshot: cost, kind: .openAIAPI, now: qualityNow)
    #expect(spending.title == "Month-to-date spending · USD")
    #expect(spending.reset == "Calendar month · UTC")
    let balance = ReadingPresentation(snapshot: Snapshot(observedAt: qualityNow, source: "Fixture", balanceUSD: 12), kind: .vercelGateway, now: qualityNow)
    #expect(balance.title == "Credit balance · USD")
    #expect(balance.value == spending.value)
    #expect(balance.session == nil)
}

@Test func recoveryContractHasOneNextActionForEachState() {
    func action(kind: ConnectionKind = .claudeCode, enabled: Bool = true, signing: Bool = false,
                reconnect: Bool = false, shared: Bool = false, failed: Bool = false, blocked: Bool = false) -> AccountRecoveryAction {
        .make(kind: kind, enabled: enabled, signingIn: signing, reconnect: reconnect, sharedSignIn: shared, failed: failed, blocked: blocked)
    }
    #expect(action(signing: true, reconnect: true, failed: true) == .finishSignIn)
    #expect(action(enabled: false, reconnect: true) == .resume)
    #expect(action(reconnect: true) == .reconnect)
    #expect(action(kind: .xai, reconnect: true) == .replaceKey)
    #expect(action(kind: .grokSubscription, reconnect: true, shared: true) == .checkSignIn)
    #expect(action(failed: true, blocked: true) == .wait)
    #expect(action(failed: true) == .retry)
    #expect(action() == .openUsage)
}

@Test func diagnosticsAllowlistCannotExposeAssociatedErrorsOrAccountData() throws {
    let privateValue = "PRIVATE_FIXTURE_SENTINEL"
    var account = Account(name: privateValue, kind: .claudeCode, scopeID: privateValue)
    account.expectedIdentity = privateValue + "@example.com"
    var snapshot = try qualitySnapshot()
    snapshot.identity = privateValue; snapshot.source = privateValue; snapshot.note = privateValue
    snapshot.windows[0].label = privateValue; snapshot.windows[0].id = privateValue
    let errors: [UsageError] = [.unavailable(privateValue), .accountChanged(privateValue), .duplicateAccount(privateValue), .storage]
    for error in errors {
        let report = DiagnosticReport(appVersion: "0.5.9", build: "244", macOS: "15.0.0", preview: true,
            offline: false, paused: false, settingsReadable: true, automaticUpdates: true,
            tools: [DiagnosticTool(provider: .claudeCode, installed: true, version: privateValue)],
            accounts: [DiagnosticAccount(account: account, snapshot: snapshot, saved: true, failure: error, retryAt: nil,
                historyPoints: 100, summaryDays: 30, now: qualityNow)])
        let text = try report.text()
        #expect(!text.contains(privateValue))
        #expect(!text.contains(account.id.uuidString))
        #expect(!text.contains("example.com"))
        #expect(text.contains(DiagnosticAccount.failureCode(error)))
        #expect(text.contains("Nothing is sent automatically"))
    }
    #expect(ToolVersionProbe.sanitizedVersion("2.1.294") == "2.1.294")
    #expect(ToolVersionProbe.sanitizedVersion("2.1.294\n" + privateValue) == nil)
}

@Test func consumptionCoverageDistinguishesMeasuredZeroFromMissingTime() {
    let start = HistoryTrends.calendar.startOfDay(for: qualityNow)
    let days = [UsageDay(day: start, weekly: .init(amount: 0, seconds: 3600)),
                UsageDay(day: start.addingTimeInterval(86400), weekly: .init(amount: 12, seconds: 3600))]
    let end = start.addingTimeInterval(2 * 86400)
    let summary = ConsumptionSummary(days: days, kind: .claudeCode, session: false, since: start, now: end)
    #expect(summary.amount == 12 && summary.measuredDays == 2)
    #expect(abs(summary.coverage - 1.0 / 24) < 0.00001)
    let missingSession = ConsumptionSummary(days: days, kind: .claudeCode, session: true, since: start, now: end)
    #expect(missingSession.amount == 0 && missingSession.measuredDays == 0 && missingSession.coverage == 0)
    let buckets = ConsumptionHistory.buckets(days, kind: .claudeCode, session: false, since: start, now: end, weekly: false)
    #expect(buckets.count == 2 && buckets[0].amount == 0)
    #expect(buckets.allSatisfy { $0.partial })
}

@Test func historyStatePreservesAFullYearAcrossRefreshAndRestart() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("QualityHistory-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    var account = Account(name: "Fixture", kind: .claudeCode); account.expectedIdentity = "fixture@example.com"
    let cache = SnapshotCache(root: root)
    let oldDate = qualityNow.addingTimeInterval(-365 * 86400)
    let old = try qualitySnapshot(at: oldDate)
    try cache.save(old, for: account)
    var next = old; next.observedAt = oldDate.addingTimeInterval(300); next.windows[0].usedPercent += 5
    try cache.save(next, for: account)
    try cache.save(qualitySnapshot(), for: account)
    let restored = SnapshotCache(root: root).loadState(accounts: [account], now: qualityNow)
    #expect(restored.snapshots[account.id]?.observedAt == qualityNow)
    #expect(restored.history[account.id]?.first?.timestamp == next.observedAt)
    #expect(restored.usage[account.id]?.first?.weekly?.amount == 5)
    #expect(restored.history == cache.loadHistory(accounts: [account], now: qualityNow))
    #expect(restored.usage == cache.loadUsage(accounts: [account], now: qualityNow))
    #expect(SnapshotCache.retentionDays >= 366)
}

@Test func chartWorkIsBoundedWithoutLosingExtremaOrJoiningResetSegments() throws {
    let points = (0..<4096).map { index in
        HistorySample(timestamp: qualityNow.addingTimeInterval(Double(index)),
                      value: index == 2000 ? 0 : index == 2020 ? 100 : 50, segment: index / 512)
    }
    let rendered = HistorySeries.plotSamples(points)
    #expect(rendered.count <= 360)
    #expect(rendered.first?.timestamp == points.first?.timestamp)
    #expect(rendered.last?.timestamp == points.last?.timestamp)
    #expect(rendered.contains { $0.value == 0 })
    #expect(rendered.contains { $0.value == 100 })
    for sample in rendered {
        let original = try #require(points.first { $0.timestamp == sample.timestamp })
        #expect(original.value == sample.value && original.segment == sample.segment)
    }
}

@Test func unreadableHistoryIsPreservedBeforeNewReadingsAreSaved() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("QualityRecovery-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    var account = Account(name: "Fixture", kind: .claudeCode); account.expectedIdentity = "fixture@example.com"
    let corrupt = Data("unreadable fixture history".utf8)
    try Paths.writePrivate(corrupt, to: root.appendingPathComponent("Readings/\(account.id.uuidString).json"))
    let cache = SnapshotCache(root: root)
    #expect(cache.loadState(accounts: [account], now: qualityNow).unreadableRecords == 1)
    try cache.save(qualitySnapshot(), for: account)
    #expect(cache.loadState(accounts: [account], now: qualityNow).unreadableRecords == 0)
    let recovery = root.appendingPathComponent("Readings/Recovery/\(account.id.uuidString).json")
    #expect(try Paths.readData(recovery) == corrupt)
    try cache.remove(account)
    #expect(!FileManager.default.fileExists(atPath: recovery.path))
}

@Test func versionProbeAcceptsOnlyKnownVersionOutputAndNeverReturnsRawText() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("QualityVersion-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let tool = root.appendingPathComponent("fixture")
    try Paths.writePrivate(Data("#!/bin/sh\n[ \"$1\" = \"--version\" ] || exit 2\nprintf '2.1.294 (Claude Code)\\n'\n".utf8), to: tool, executable: true)
    #expect(await ToolVersionProbe.read(executable: tool) == "2.1.294")
    try Paths.writePrivate(Data("#!/bin/sh\nprintf '2.1.294\\nPRIVATE_FIXTURE_SENTINEL\\n'\n".utf8), to: tool, executable: true)
    #expect(await ToolVersionProbe.read(executable: tool) == nil)
}

@Test func cancellingDiagnosticsStopsItsOwnedVersionProcess() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("QualityVersionCancel-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let tool = root.appendingPathComponent("fixture"), pidFile = root.appendingPathComponent("pid")
    try Paths.writePrivate(Data(("#!/bin/sh\necho $$ > " + ShellQuote.argument(pidFile.path) + "\nexec /bin/sleep 30\n").utf8), to: tool, executable: true)
    let task = Task { await ToolVersionProbe.read(executable: tool) }
    let deadline = Date().addingTimeInterval(2)
    while !FileManager.default.fileExists(atPath: pidFile.path), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    let pid = try #require(Int32(String(decoding: try Data(contentsOf: pidFile), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
    defer { _ = kill(pid, SIGKILL) }
    task.cancel()
    #expect(await task.value == nil)
    let exitDeadline = Date().addingTimeInterval(1)
    while kill(pid, 0) == 0, Date() < exitDeadline { try await Task.sleep(for: .milliseconds(10)) }
    #expect(kill(pid, 0) == -1)
}
