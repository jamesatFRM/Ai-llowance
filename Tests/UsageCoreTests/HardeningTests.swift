import Foundation
import Testing
@testable import UsageCore

@Test func decodedQuotaCannotBypassPercentageAndMetadataValidation() throws {
    for payload in [
        #"{"id":"week","label":"Week","usedPercent":101}"#,
        #"{"id":"week","label":"Week","usedPercent":-1}"#,
        #"{"id":"","label":"Week","usedPercent":1}"#,
        #"{"id":"week","label":"Week","usedPercent":1,"durationMinutes":0}"#,
        #"{"id":"week","label":"Week","usedPercent":1,"resetsAt":1e100}"#
    ] {
        #expect(throws: UsageError.invalidData) { try JSONDecoder().decode(QuotaWindow.self, from: Data(payload.utf8)) }
    }
    let window = try QuotaWindow(id: "week", label: "Week", usedPercent: 99, resetsAt: Date(), durationMinutes: 10080)
    #expect(try JSONDecoder().decode(QuotaWindow.self, from: JSONEncoder().encode(window)) == window)
}

@Test func accountModeGroupsProvidersStablyAndHonorsSelection() {
    let first = Account(name: "OpenAI one", kind: .codex)
    let second = Account(name: "Claude one", kind: .claudeCode)
    let third = Account(name: "OpenAI two", kind: .codex)
    let fourth = Account(name: "Claude two", kind: .claudeCode)
    var preferences = MenuPreferences(); preferences.display = .byAccount
    func entries() -> [MenuEntry] {
        MenuSummary.entries(accounts: [first, second, third, fourth], snapshots: [:], unavailable: [], preferences: preferences, now: Date())
    }
    #expect(entries().map(\.label) == [second.name, fourth.name, first.name, third.name])
    #expect(entries().map(\.provider) == [.claude, .claude, .openAI, .openAI])
    preferences.allAccounts = false; preferences.selectedAccountIDs = [third.id, second.id]
    #expect(entries().map(\.label) == [second.name, third.name])
}

@Test func providerRestrictionCannotShowAnApparentlyHealthyMenuAllowance() throws {
    let now = Date()
    let account = Account(name: "Restricted", kind: .codex)
    let payload = Data(#"{"ordinaryUsageAllowed":false,"rateLimits":{"secondary":{"usedPercent":0,"windowDurationMins":10080}}}"#.utf8)
    let snapshot = try UsageParser.codex(payload, at: now)
    #expect(snapshot.providerRestricted == true)
    for display in MenuDisplay.allCases {
        var preferences = MenuPreferences(); preferences.display = display
        let entries = MenuSummary.entries(accounts: [account], snapshots: [account.id: snapshot], unavailable: [], preferences: preferences, now: now)
        #expect(entries.count == 1)
        #expect(entries[0].remainingPercent == nil)
    }
    let legacy = Data(#"{"observedAt":0,"windows":[],"source":"Old version"}"#.utf8)
    #expect(try JSONDecoder().decode(Snapshot.self, from: legacy).providerRestricted == nil)
}

@Test func privateWritesReplaceAtomicallyAndCleanUpOnFailure() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("private.json")
    try Paths.writePrivate(Data("original".utf8), to: file)
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    try Paths.writePrivate(Data("replacement".utf8), to: file, executable: true)
    #expect(try Paths.readData(file) == Data("replacement".utf8))
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o700)
    let directory = root.appendingPathComponent("nonempty")
    try Paths.writePrivate(Data("keep".utf8), to: directory.appendingPathComponent("keep"))
    #expect(throws: UsageError.storage) { try Paths.writePrivate(Data("invalid target".utf8), to: directory) }
    #expect(try Paths.readData(directory.appendingPathComponent("keep")) == Data("keep".utf8))
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".write-") })
    #expect(throws: UsageError.invalidData) { try Paths.readData(file, limit: 5) }
    #expect(try Paths.readData(file, limit: 11).count == 11)
}

@Test func privateWriteReplacesSymlinkWithoutOverwritingItsDestination() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("original")
    let link = root.appendingPathComponent("link")
    try Paths.writePrivate(Data("preserve".utf8), to: original)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
    try Paths.writePrivate(Data("new".utf8), to: link)
    #expect(try Paths.readData(original) == Data("preserve".utf8))
    #expect(try Paths.readData(link) == Data("new".utf8))
}

@Test func codexCleanupKillsAChildThatIgnoresTerminationBeforeReturning() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("stalled")
    let ready = root.appendingPathComponent("ready")
    try Paths.writePrivate(Data("#!/bin/sh\ntrap '' TERM\nprintf ready > \(ShellQuote.argument(ready.path))\nwhile :; do read -r line || :; done\n".utf8), to: script, executable: true)
    let rpc = try CodexRPC(executable: script, home: root, existing: false, timeout: 2)
    defer { rpc.stop() }
    let readyDeadline = Date().addingTimeInterval(3)
    while !FileManager.default.fileExists(atPath: ready.path) && rpc.process.isRunning && Date() < readyDeadline { Thread.sleep(forTimeInterval: 0.01) }
    try #require(FileManager.default.fileExists(atPath: ready.path))
    rpc.process.terminate()
    Thread.sleep(forTimeInterval: 0.05)
    #expect(rpc.process.isRunning) // Exercise the SIGKILL fallback, not ordinary SIGTERM cleanup.
    let start = Date()
    rpc.stop()
    #expect(Date().timeIntervalSince(start) < 2)
    // Allow the kernel/Foundation termination observer to reap the SIGKILLed child.
    let deadline = Date().addingTimeInterval(1)
    while rpc.process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
    #expect(!rpc.process.isRunning)
}
