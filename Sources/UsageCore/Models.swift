import Foundation
import Darwin

public enum ConnectionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, claudeCode, openAIAPI, claudeAPI, copilot, openRouter, vercelGateway, xai
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .codex: "OpenAI · Codex subscription"
        case .claudeCode: "Claude · Code subscription"
        case .openAIAPI: "OpenAI · API spending"
        case .claudeAPI: "Claude · API spending"
        case .copilot: "GitHub · Copilot allowance"
        case .openRouter: "OpenRouter · key budget"
        case .vercelGateway: "Vercel AI Gateway · API credits"
        case .xai: "xAI · API credits"
        }
    }
    public var isAPI: Bool { self == .openAIAPI || self == .claudeAPI || isBalance }
    public var isBalance: Bool { self == .openRouter || self == .vercelGateway || self == .xai }
    public var provider: MenuProvider {
        switch self {
        case .codex, .openAIAPI: .openAI
        case .claudeCode, .claudeAPI: .claude
        case .copilot: .copilot
        case .openRouter: .openRouter
        case .vercelGateway: .vercelGateway
        case .xai: .xai
        }
    }
    public func refreshInterval(visible: Bool, lowPower: Bool = false) -> TimeInterval {
        if self == .openAIAPI || self == .claudeAPI { return 3600 }
        if isBalance { return visible && !lowPower ? 300 : 600 }
        return lowPower ? 900 : (visible ? 60 : 600)
    }
    public var freshnessInterval: TimeInterval { isAPI && !isBalance ? 7200 : 1800 }
    public var explanation: String {
        switch self {
        case .codex: "Reads the quota buckets reported by Codex. This is not a universal ChatGPT message counter. Sign in separately for each account."
        case .claudeCode: "Reads plan limits directly through Claude Code’s built-in /usage command, without a conversation. Requires a version that reports plan limits in print mode (verified with 2.1.294) and a subscription sign-in. Missing data stays unavailable."
        case .openAIAPI: "Organization API cost this UTC month. Requires an OpenAI Admin API key. A ChatGPT subscription or ordinary project key does not provide this report."
        case .claudeAPI: "Organization API cost this UTC month. Requires an Anthropic Admin API key. Excludes Priority Tier costs; this is not Claude subscription usage."
        case .copilot: "Reads account quota buckets through the installed GitHub Copilot CLI and its existing sign-in. This is not a count of all GitHub activity."
        case .openRouter: "Reads the API spending budget available to your OpenRouter key. This endpoint does not report total account credits or model subscription allowance."
        case .vercelGateway: "Reads your Vercel AI Gateway API credit balance. This is separate from Vercel hosting usage."
        case .xai: "Reads prepaid API credits for the selected xAI team using a Management API key. This is not a Grok subscription allowance."
        }
    }
    public var dashboard: URL {
        let address = switch self {
        case .codex: "https://chatgpt.com/codex/settings/usage"
        case .claudeCode: "https://claude.ai/settings/usage"
        case .openAIAPI: "https://platform.openai.com/usage"
        case .claudeAPI: "https://platform.claude.com/usage"
        case .copilot: "https://github.com/settings/copilot"
        case .openRouter: "https://openrouter.ai/settings/credits"
        case .vercelGateway: "https://vercel.com/dashboard"
        case .xai: "https://console.x.ai"
        }
        return URL(string: address)!
    }
    public var documentation: URL {
        let address = switch self {
        case .codex: "https://developers.openai.com/codex/app-server"
        case .claudeCode: "https://code.claude.com/docs/en/statusline"
        case .openAIAPI: "https://platform.openai.com/docs/api-reference/usage"
        case .claudeAPI: "https://platform.claude.com/docs/en/manage-claude/usage-cost-api"
        case .copilot: "https://docs.github.com/en/copilot/how-tos/copilot-sdk/features/usage-and-billing"
        case .openRouter: "https://openrouter.ai/docs/api-reference/credits/get-credits"
        case .vercelGateway: "https://vercel.com/docs/ai-gateway"
        case .xai: "https://docs.x.ai/developers/rest-api-reference/management/billing"
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
    // Non-secret identity binding; old settings decode without a binding.
    public var expectedIdentity: String?
    public var scopeID: String?
    public init(id: UUID = UUID(), name: String, kind: ConnectionKind, enabled: Bool = true, usesExistingCodex: Bool = false, usesExistingClaude: Bool = false, scopeID: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.enabled = enabled; self.usesExistingCodex = usesExistingCodex
        self.usesExistingClaude = usesExistingClaude
        self.scopeID = scopeID
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
        guard !id.isEmpty, id.utf8.count <= 1024, label.utf8.count <= 4096,
              durationMinutes.map({ $0 > 0 }) ?? true else { throw UsageError.invalidData }
        if let reset = resetsAt {
            guard reset.timeIntervalSince1970.isFinite, (0...253_402_300_799).contains(reset.timeIntervalSince1970) else { throw UsageError.invalidData }
        }
        self.id = id; self.label = label; self.usedPercent = usedPercent; self.resetsAt = resetsAt
        self.durationMinutes = durationMinutes
    }
    private enum CodingKeys: String, CodingKey { case id, label, usedPercent, resetsAt, durationMinutes }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(String.self, forKey: .id), label: values.decode(String.self, forKey: .label),
                      usedPercent: values.decode(Double.self, forKey: .usedPercent),
                      resetsAt: values.decodeIfPresent(Date.self, forKey: .resetsAt),
                      durationMinutes: values.decodeIfPresent(Int.self, forKey: .durationMinutes))
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
    public var providerRestricted: Bool?
    public var balanceUSD: Decimal?
    public var balanceLabel: String?
    public var unlimited: Bool?
    public var freshnessInterval: TimeInterval?
    public init(observedAt: Date, windows: [QuotaWindow] = [], costUSD: Decimal? = nil, periodStart: Date? = nil,
                identity: String? = nil, source: String, note: String? = nil, providerRestricted: Bool? = nil,
                balanceUSD: Decimal? = nil, balanceLabel: String? = nil, unlimited: Bool? = nil, freshnessInterval: TimeInterval? = nil) {
        self.observedAt = observedAt; self.windows = windows; self.costUSD = costUSD; self.periodStart = periodStart
        self.identity = identity; self.source = source; self.note = note; self.providerRestricted = providerRestricted
        self.balanceUSD = balanceUSD; self.balanceLabel = balanceLabel; self.unlimited = unlimited; self.freshnessInterval = freshnessInterval
    }
    public var weeklyWindows: [QuotaWindow] {
        // Claude's stable row IDs also cover readings made before duration metadata was added.
        windows.filter { $0.durationMinutes == 10_080 || $0.id.hasPrefix("week.") || $0.id == "7-day" }
    }
    public func isStale(at now: Date = Date(), windows relevantWindows: [QuotaWindow]? = nil) -> Bool {
        now.timeIntervalSince(observedAt) > (freshnessInterval ?? 900) || observedAt > now.addingTimeInterval(60)
        || (relevantWindows ?? windows).contains { $0.resetsAt.map { $0 <= now } ?? false }
        || (costUSD != nil && periodStart.map { CostAdapter.monthStart(now) != $0 } == true)
    }
    public func validated() throws -> Self {
        // Finite alone accepts dates such as 1e100. Keep every provider date in
        // the same representable calendar range as reset dates before UI formatting.
        let supportedDates: ClosedRange<TimeInterval> = 0...253_402_300_799
        guard observedAt.timeIntervalSince1970.isFinite, supportedDates.contains(observedAt.timeIntervalSince1970), windows.count <= 64,
              source.utf8.count <= 4096, (identity?.utf8.count ?? 0) <= 4096,
              (note?.utf8.count ?? 0) <= 16_384, (balanceLabel?.utf8.count ?? 0) <= 256,
              Set(windows.map(\.id)).count == windows.count else { throw UsageError.invalidData }
        for window in windows {
            _ = try QuotaWindow(id: window.id, label: window.label, usedPercent: window.usedPercent,
                                resetsAt: window.resetsAt, durationMinutes: window.durationMinutes)
        }
        let moneyLimit = Decimal(string: "1000000000000000")!
        if let costUSD { guard !costUSD.isNaN, costUSD >= 0, costUSD <= moneyLimit else { throw UsageError.invalidData } }
        // Some credit providers report a negative balance after overage.
        if let balanceUSD { guard !balanceUSD.isNaN, balanceUSD >= -moneyLimit, balanceUSD <= moneyLimit else { throw UsageError.invalidData } }
        if let freshnessInterval {
            guard freshnessInterval.isFinite, freshnessInterval >= 30, freshnessInterval <= 604800 else { throw UsageError.invalidData }
        }
        if let periodStart {
            guard periodStart.timeIntervalSince1970.isFinite, supportedDates.contains(periodStart.timeIntervalSince1970),
                  periodStart <= observedAt else { throw UsageError.invalidData }
        }
        return self
    }
    private enum CodingKeys: String, CodingKey {
        case observedAt, windows, costUSD, periodStart, identity, source, note, providerRestricted
        case balanceUSD, balanceLabel, unlimited, freshnessInterval
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(observedAt: try values.decode(Date.self, forKey: .observedAt),
                  windows: try values.decodeIfPresent([QuotaWindow].self, forKey: .windows) ?? [],
                  costUSD: try values.decodeIfPresent(Decimal.self, forKey: .costUSD),
                  periodStart: try values.decodeIfPresent(Date.self, forKey: .periodStart),
                  identity: try values.decodeIfPresent(String.self, forKey: .identity),
                  source: try values.decode(String.self, forKey: .source),
                  note: try values.decodeIfPresent(String.self, forKey: .note),
                  providerRestricted: try values.decodeIfPresent(Bool.self, forKey: .providerRestricted),
                  balanceUSD: try values.decodeIfPresent(Decimal.self, forKey: .balanceUSD),
                  balanceLabel: try values.decodeIfPresent(String.self, forKey: .balanceLabel),
                  unlimited: try values.decodeIfPresent(Bool.self, forKey: .unlimited),
                  freshnessInterval: try values.decodeIfPresent(TimeInterval.self, forKey: .freshnessInterval))
        _ = try validated()
    }
}

public enum UsageError: Error, LocalizedError, Sendable, Equatable {
    case missingCredential, authentication, forbidden, rateLimited(TimeInterval), server, invalidData, unavailable(String), timeout, storage
    case accountChanged(String), duplicateAccount(String)
    public var errorDescription: String? {
        switch self {
        case .missingCredential: "Add an admin key to connect API spending."
        case .authentication: "Sign in again or replace the expired credential."
        case .accountChanged(let expected): "This connection needs \(expected). Its current sign-in belongs to another account. Sign in with the expected account."
        case .duplicateAccount(let other): "This email is already connected as \(other). Sign in with your other account; this duplicate is not counted."
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
    public private(set) var lastSuccess: Date?
    public init() {}
    public static let refreshInterval: TimeInterval = 60
    public static let manualRefreshInterval: TimeInterval = 30
    public func shouldRefresh(at now: Date, manual: Bool = false) -> Bool {
        let earlyManualRead = manual && failures == 0
            && lastSuccess.map { now.timeIntervalSince($0) >= Self.manualRefreshInterval } == true
        return earlyManualRead || now >= nextAttempt
    }
    public mutating func succeeded(at now: Date, interval: TimeInterval = Self.refreshInterval) {
        failures = 0; lastSuccess = now
        nextAttempt = now.addingTimeInterval(interval.isFinite && interval >= Self.manualRefreshInterval ? interval : Self.refreshInterval)
    }
    /// Change healthy cadence without making another read or shortening provider backoff.
    public mutating func adjustHealthyInterval(_ interval: TimeInterval) {
        guard failures == 0, let lastSuccess else { return }
        let delay = interval.isFinite && interval >= Self.manualRefreshInterval ? interval : Self.refreshInterval
        nextAttempt = lastSuccess.addingTimeInterval(delay)
    }
    public mutating func failed(_ error: Error, at now: Date) {
        failures = min(failures + 1, 5)
        var delay = min(3600.0, 300 * pow(2, Double(failures - 1)))
        if case UsageError.rateLimited(let retry) = error, retry.isFinite, retry >= 0 {
            // Broken Retry-After headers must not disable a connection forever.
            delay = max(delay, min(retry, 7 * 86400))
        }
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
        try writePrivate(JSONEncoder().encode(value), to: url)
    }
    public static func readData(_ url: URL, limit: Int = 2_000_000) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw UsageError.invalidData }
        return data
    }
    /// Create private before writing, then atomically replace. No world-readable temporary file.
    public static func writePrivate(_ data: Data, to url: URL, executable: Bool = false) throws {
        try prepare(url.deletingLastPathComponent())
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".write-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, executable ? 0o700 : 0o600)
        guard fd >= 0 else { throw UsageError.storage }
        defer { close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: written), buffer.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw UsageError.storage }
                written += count
            }
        }
        guard fsync(fd) == 0, Darwin.rename(temporary.path, url.path) == 0 else { throw UsageError.storage }
    }
}
