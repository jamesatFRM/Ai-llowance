import Foundation
import Darwin
import Testing
@testable import UsageCore

private struct IdentityRaceFixture {
    let root: URL
    let executable: URL
    let quotaMarker: URL

    init(provider: String, mode: String) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("provider-identity-\(UUID().uuidString)")
        try Paths.prepare(root)
        executable = root.appendingPathComponent(provider)
        quotaMarker = root.appendingPathComponent("quota-read")
        let script = #"""
        #!/usr/bin/python3
        import json, os, sys
        root = os.path.dirname(os.path.realpath(__file__))
        mode = "MODE"
        marker = os.path.join(root, "quota-read")
        def identity(after):
            if mode == "switch" and after: return "second@example.com"
            if mode == "case" and after: return " FIRST@example.com "
            if mode == "missing": return None
            return "first@example.com"
        if os.path.basename(__file__) == "claude":
            after = os.path.exists(marker)
            if sys.argv[1] == "auth":
                print(json.dumps({"loggedIn": not (mode == "logout" and after), "authMethod": "claude.ai", "email": identity(after)}))
            else:
                open(marker, "w").close()
                print(json.dumps({"type": "result", "subtype": "success", "is_error": False, "num_turns": 0, "total_cost_usd": 0,
                    "result": "Current session: 25% used\nCurrent week (all models): 50% used"}))
        else:
            after = False
            for line in sys.stdin:
                request = json.loads(line)
                method = request["method"]
                if method == "initialized": continue
                if method == "initialize": result = {}
                elif method == "account/read":
                    assert request["params"]["refreshToken"] == (not after)
                    result = {"account": None if mode == "logout" and after else {"type": "chatgpt", "email": identity(after)}}
                elif method == "account/rateLimits/read":
                    open(marker, "w").close()
                    after = True
                    result = {"rateLimits": {"primary": {"usedPercent": 25, "windowDurationMins": 300}}}
                else: raise RuntimeError("Unexpected operation")
                print(json.dumps({"id": request["id"], "result": result}), flush=True)
        """#.replacingOccurrences(of: "MODE", with: mode)
        try Paths.writePrivate(Data(script.utf8), to: executable, executable: true)
    }

    func fetch(provider: String, expected: String? = nil) async throws -> Snapshot {
        var account = Account(name: "Fixture", kind: provider == "claude" ? .claudeCode : .codex)
        account.expectedIdentity = expected
        if provider == "claude" {
            return try await ClaudeUsageAdapter(executable: executable, root: root).fetch(account: account, now: Date())
        }
        try Paths.prepare(Paths.profile(account.id, root: root))
        return try await CodexAdapter(executable: executable, root: root).fetch(account: account, now: Date())
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}

@Test func subscriptionAdaptersRejectIdentitySwitchOrLogoutDuringQuotaRead() async throws {
    for provider in ["claude", "codex"] {
        for mode in ["switch", "logout"] {
            let fixture = try IdentityRaceFixture(provider: provider, mode: mode)
            defer { fixture.clean() }
            await #expect(throws: UsageError.accountChanged("first@example.com")) {
                try await fixture.fetch(provider: provider)
            }
            #expect(FileManager.default.fileExists(atPath: fixture.quotaMarker.path))
        }
    }
}

@Test func subscriptionAdaptersRejectWrongOrMissingIdentityBeforeReadingQuota() async throws {
    for provider in ["claude", "codex"] {
        let wrong = try IdentityRaceFixture(provider: provider, mode: "stable")
        defer { wrong.clean() }
        await #expect(throws: UsageError.accountChanged("connected@example.com")) {
            try await wrong.fetch(provider: provider, expected: "connected@example.com")
        }
        #expect(!FileManager.default.fileExists(atPath: wrong.quotaMarker.path))
        let missing = try IdentityRaceFixture(provider: provider, mode: "missing")
        defer { missing.clean() }
        await #expect(throws: UsageError.authentication) {
            try await missing.fetch(provider: provider)
        }
        #expect(!FileManager.default.fileExists(atPath: missing.quotaMarker.path))
    }
}

@Test func subscriptionAdaptersAllowStableNormalizedIdentityAcrossQuotaRead() async throws {
    for provider in ["claude", "codex"] {
        let fixture = try IdentityRaceFixture(provider: provider, mode: "case")
        defer { fixture.clean() }
        let snapshot = try await fixture.fetch(provider: provider, expected: " First@Example.com ")
        #expect(snapshot.identity == "first@example.com")
        #expect(snapshot.windows.first?.remainingPercent == 75)
    }
}

@Test func exitedCodexHelperThrowsInsteadOfTerminatingAppWithBrokenPipe() throws {
    let rpc = try CodexRPC(executable: URL(fileURLWithPath: "/usr/bin/true"),
                           home: FileManager.default.temporaryDirectory, existing: false, timeout: 2)
    defer { rpc.stop() }
    rpc.process.waitUntilExit()
    #expect(fcntl(rpc.input.fileHandleForWriting.fileDescriptor, F_GETNOSIGPIPE) == 1)
    #expect(throws: (any Error).self) { try rpc.send(["id": 1, "method": "initialize"]) }
}
