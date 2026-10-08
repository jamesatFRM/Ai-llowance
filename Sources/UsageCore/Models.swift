import Foundation

public enum ConnectionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claudeCode, openAIAPI, claudeAPI
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .codex: "OpenAI · Codex subscription"
        case .claudeCode: "Claude · Code subscription"
        case .openAIAPI: "OpenAI · API spending"
        case .claudeAPI: "Claude · API spending"
        }
    }
    public var isAPI: Bool { self == .openAIAPI || self == .claudeAPI }
    public var explanation: String {
        switch self {
        case .codex: "Reads the quota buckets reported by Codex. This is not a universal ChatGPT message counter. Sign in separately for each account."
        case .claudeCode: "Reads plan limits directly through Claude Code’s built-in /usage command, without a conversation. Requires a version that reports plan limits in print mode (verified with 2.1.294) and a subscription sign-in. Missing data stays unavailable."
        case .openAIAPI: "Organization API cost this UTC month. Requires an OpenAI Admin API key. A ChatGPT subscription or ordinary project key does not provide this report."
        case .claudeAPI: "Organization API cost this UTC month. Requires an Anthropic Admin API key. Excludes Priority Tier costs; this is not Claude subscription usage."
        }
    }
    public var dashboard: URL {
        let address = switch self {
        case .codex: "https://chatgpt.com/codex/settings/usage"
        case .claudeCode: "https://claude.ai/settings/usage"
        case .openAIAPI: "https://platform.openai.com/usage"
        case .claudeAPI: "https://platform.claude.com/usage"
        }
        return URL(string: address)!
    }
    public var documentation: URL {
        let address = switch self {
        case .codex: "https://developers.openai.com/codex/app-server"
        case .claudeCode: "https://code.claude.com/docs/en/statusline"
        case .openAIAPI: "https://platform.openai.com/docs/api-reference/usage"
        case .claudeAPI: "https://platform.claude.com/docs/en/manage-claude/usage-cost-api"
        }
        return URL(string: address)!
    }
}

public struct Account: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ConnectionKind
    public var enabled: Bool
    public var usesExistingCodex: Bool
    public var usesExistingClaude: Bool?
    public init(id: UUID = UUID(), name: String, kind: ConnectionKind, enabled: Bool = true, usesExistingCodex: Bool = false, usesExistingClaude: Bool = false) {
        self.id = id; self.name = name; self.kind = kind; self.enabled = enabled; self.usesExistingCodex = usesExistingCodex
        self.usesExistingClaude = usesExistingClaude
    }
}

public struct QuotaWindow: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var usedPercent: Double
    public var resetsAt: Date?
    public var durationMinutes: Int?
    public init(id: String, label: String, usedPercent: Double, resetsAt: Date? = nil, durationMinutes: Int? = nil) throws {
        guard usedPercent.isFinite, usedPercent >= 0, usedPercent <= 100 else { throw UsageError.invalidData }
        self.id = id; self.label = label; self.usedPercent = usedPercent; self.resetsAt = resetsAt
        self.durationMinutes = durationMinutes
    }
    public var remainingPercent: Double { max(0, 100 - usedPercent) }
}

public struct Snapshot: Codable, Equatable, Sendable {
    public var observedAt: Date
    public var windows: [QuotaWindow]
    public var costUSD: Decimal?
    public var periodStart: Date?
    public var identity: String?
    public var source: String
    public var note: String?
    public init(observedAt: Date, windows: [QuotaWindow] = [], costUSD: Decimal? = nil, periodStart: Date? = nil,
                identity: String? = nil, source: String, note: String? = nil) {
        self.observedAt = observedAt; self.windows = windows; self.costUSD = costUSD; self.periodStart = periodStart
        self.identity = identity; self.source = source; self.note = note
    }
    public var weeklyWindows: [QuotaWindow] {
        // Claude's stable row IDs also cover readings made before duration metadata was added.
        windows.filter { $0.durationMinutes == 10_080 || $0.id.hasPrefix("week.") || $0.id == "7-day" }
    }
    public func isStale(at now: Date = Date(), windows relevantWindows: [QuotaWindow]? = nil) -> Bool {
        now.timeIntervalSince(observedAt) > 900 || observedAt > now.addingTimeInterval(60)
        || (relevantWindows ?? windows).contains { $0.resetsAt.map { $0 <= now } ?? false }
    }
}

public enum UsageError: Error, LocalizedError, Sendable, Equatable {
    case missingCredential, authentication, forbidden, rateLimited(TimeInterval), server, invalidData, unavailable(String), timeout, storage
    public var errorDescription: String? {
        switch self {
        case .missingCredential: "Add an admin key to connect API spending."
        case .authentication: "Sign in again or replace the expired credential."
        case .forbidden: "This credential cannot read organization costs. An admin credential with reporting access is required."
        case .rateLimited: "The provider asked us to wait. Automatic refresh will back off."
        case .server: "The provider is temporarily unavailable. Last known data is preserved."
        case .invalidData: "The provider returned an unrecognized or incomplete report. No usage has been inferred."
        case .unavailable(let message): message
        case .timeout: "The connection timed out. Check your network and try again."
        case .storage: "Local secure storage is unavailable. No plaintext fallback was used."
        }
    }
}

public struct PollState: Sendable {
    public var nextAttempt = Date.distantPast
    public var failures = 0
    public init() {}
    public static let refreshInterval: TimeInterval = 60
    public static let manualRefreshInterval: TimeInterval = 30
    public func shouldRefresh(at now: Date, manual: Bool = false) -> Bool {
        let earlyManualRead = manual && failures == 0
            && now >= nextAttempt.addingTimeInterval(Self.manualRefreshInterval - Self.refreshInterval)
        return earlyManualRead || now >= nextAttempt
    }
    public mutating func succeeded(at now: Date) { failures = 0; nextAttempt = now.addingTimeInterval(Self.refreshInterval) }
    public mutating func failed(_ error: Error, at now: Date) {
        failures = min(failures + 1, 5)
        var delay = min(3600.0, 300 * pow(2, Double(failures - 1)))
        if case UsageError.rateLimited(let retry) = error { delay = max(delay, retry) }
        if error as? UsageError == .authentication || error as? UsageError == .missingCredential || error as? UsageError == .forbidden { delay = 3600 }
        nextAttempt = now.addingTimeInterval(delay)
    }
}

public enum Paths {
    public static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("UsageBar", isDirectory: true)
    }
    public static func profile(_ id: UUID, root: URL = root) -> URL { root.appendingPathComponent("CodexProfiles/\(id.uuidString)", isDirectory: true) }
    public static func feed(_ id: UUID, root: URL = root) -> URL { root.appendingPathComponent("ClaudeFeeds/\(id.uuidString).json") }
    public static func claudeProfile(_ id: UUID, root: URL = root) -> URL { root.appendingPathComponent("ClaudeProfiles/\(id.uuidString)", isDirectory: true) }
    public static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try prepare(url.deletingLastPathComponent())
        let data = try JSONEncoder().encode(value)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
