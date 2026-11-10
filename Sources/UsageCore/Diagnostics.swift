import Foundation

/// Explicit allowlist: never serialize Account, Snapshot, errors or paths into
/// a support report. Associated error messages can contain account identities.
public struct DiagnosticAccount: Codable, Sendable {
    public let provider: ConnectionKind
    public let enabled: Bool
    public let identityBound: Bool
    public let reading: String
    public let ageMinutes: Int?
    public let failure: String?
    public let retryInSeconds: Int?
    public let windowMinutes: [Int]
    public let resetKnown: Bool
    public let historyPoints: Int
    public let summaryDays: Int
    public init(account: Account, snapshot: Snapshot?, saved: Bool, failure: UsageError?, retryAt: Date?,
                historyPoints: Int, summaryDays: Int, now: Date) {
        provider = account.kind; enabled = account.enabled
        identityBound = CodexIdentity.normalized(account.expectedIdentity) != nil
        reading = snapshot == nil ? "missing" : saved ? "saved" : "current"
        ageMinutes = snapshot.map { max(0, Int(now.timeIntervalSince($0.observedAt) / 60)) }
        self.failure = failure.map(Self.failureCode)
        retryInSeconds = retryAt.flatMap { $0 > now ? min(86400, Int(ceil($0.timeIntervalSince(now)))) : nil }
        windowMinutes = Array(Set(snapshot?.applicableWindows(for: account.kind).compactMap(\.durationMinutes) ?? [])).sorted()
        resetKnown = snapshot?.displayWindow(for: account.kind)?.resetsAt != nil
        self.historyPoints = max(0, historyPoints); self.summaryDays = max(0, summaryDays)
    }
    public static func failureCode(_ error: UsageError) -> String {
        switch error {
        case .missingCredential: "missing_credential"
        case .authentication: "authentication"
        case .forbidden: "permission"
        case .rateLimited: "rate_limited"
        case .server: "provider_unavailable"
        case .invalidData: "unrecognized_report"
        case .unavailable: "unavailable"
        case .timeout: "timeout"
        case .storage: "secure_storage"
        case .accountChanged: "identity_mismatch"
        case .duplicateAccount: "duplicate_identity"
        case .claudeDedicatedSignInRequired: "dedicated_signin_required"
        }
    }
}

public struct DiagnosticTool: Codable, Sendable {
    public let provider: ConnectionKind
    public let installed: Bool
    public let version: String?
    public init(provider: ConnectionKind, installed: Bool, version: String? = nil) {
        self.provider = provider; self.installed = installed
        self.version = version.flatMap(ToolVersionProbe.sanitizedVersion)
    }
}

public struct DiagnosticReport: Encodable, Sendable {
    public let formatVersion = 1
    public let appVersion: String
    public let build: String
    public let macOS: String
    public let preview: Bool
    public let offline: Bool
    public let paused: Bool
    public let settingsReadable: Bool
    public let automaticUpdates: Bool
    public let retentionDays = SnapshotCache.retentionDays
    public let tools: [DiagnosticTool]
    public let accounts: [DiagnosticAccount]
    public init(appVersion: String, build: String, macOS: String, preview: Bool, offline: Bool, paused: Bool,
                settingsReadable: Bool, automaticUpdates: Bool, tools: [DiagnosticTool], accounts: [DiagnosticAccount]) {
        self.appVersion = ToolVersionProbe.sanitizedVersion(appVersion) ?? "development"
        self.build = build.allSatisfy(\.isNumber) && build.count <= 8 ? build : "development"
        self.macOS = ToolVersionProbe.sanitizedVersion(macOS) ?? "unknown"
        self.preview = preview; self.offline = offline; self.paused = paused
        self.settingsReadable = settingsReadable; self.automaticUpdates = automaticUpdates
        self.tools = tools; self.accounts = accounts
    }
    public func text() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return "Ai-llowance support diagnostics\nNo names, emails, account IDs, keys, usage amounts, file paths or raw provider output. Nothing is sent automatically.\n\n" + String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

public enum ToolVersionProbe {
    /// Only a complete, bounded version string can leave the version probe.
    public static func sanitizedVersion(_ value: String) -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: #"^\d{1,4}\.\d{1,4}\.\d{1,6}(?:-[A-Za-z0-9.-]{1,32})?$"#, options: .regularExpression) != nil else { return nil }
        // Prerelease suffixes are arbitrary text. Keep only numeric components
        // in a shareable report, even when a tool includes a custom build name.
        return String(value.prefix { $0 != "-" })
    }
    public static func read(executable: URL) async -> String? {
        // Explicit user action only; fixed version argument, small output and a
        // hard deadline. No provider usage reads or permanent version polling.
        let worker = Task.detached(priority: .utility) { () -> String? in
            let process = Process(), output = Pipe()
            process.executableURL = executable; process.arguments = ["--version"]
            process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                                   "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "NO_COLOR": "1",
                                   "DISABLE_TELEMETRY": "1", "DISABLE_ERROR_REPORTING": "1"]
            process.standardInput = FileHandle.nullDevice; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let result = try CommandOutput.read(process, output: output, timeout: 3, limit: 4096)
                guard result.exitCode == 0, let text = String(data: result.data, encoding: .utf8) else { return nil }
                // Known CLIs print either a version first or their product name.
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                let pattern = #"^(?:(?:codex-cli|claude|Claude Code|copilot|GitHub Copilot CLI|grok|Grok CLI)\s+)?(\d{1,4}\.\d{1,4}\.\d{1,6}(?:-[A-Za-z0-9.-]{1,32})?)(?:\s+\(Claude Code\))?$"#
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let match = regex.firstMatch(in: clean, range: NSRange(clean.startIndex..., in: clean)),
                      let range = Range(match.range(at: 1), in: clean) else { return nil }
                return sanitizedVersion(String(clean[range]))
            } catch { return nil }
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
