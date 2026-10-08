import Foundation

public enum UsageParser {
    private struct CodexReport: Decodable {
        struct Bucket: Decodable {
            struct Window: Decodable { let usedPercent: Double; let windowDurationMins: Int?; let resetsAt: Double? }
            let limitId: String?; let limitName: String?; let primary: Window?; let secondary: Window?
            let rateLimitReachedType: String?
        }
        let rateLimits: Bucket?
        let rateLimitsByLimitId: [String: Bucket]?
        let ordinaryUsageAllowed: Bool?
    }
    public static func codex(_ data: Data, at now: Date = Date(), identity: String? = nil) throws -> Snapshot {
        let report = try JSONDecoder().decode(CodexReport.self, from: data)
        let buckets: [String: CodexReport.Bucket]
        if let all = report.rateLimitsByLimitId, !all.isEmpty { buckets = all }
        else if let one = report.rateLimits { buckets = [one.limitId ?? "codex": one] }
        else { throw UsageError.invalidData }
        var windows: [QuotaWindow] = []
        var limited = report.ordinaryUsageAllowed == false
        for (key, bucket) in buckets.sorted(by: { $0.key < $1.key }) {
            limited = limited || bucket.rateLimitReachedType != nil
            for (slot, window) in [("Primary", bucket.primary), ("Secondary", bucket.secondary)] {
                guard let window else { continue }
                let duration = window.windowDurationMins.map { $0 % 1440 == 0 ? "\($0 / 1440)d" : ($0 % 60 == 0 ? "\($0 / 60)h" : "\($0)m") } ?? slot
                windows.append(try QuotaWindow(id: "\(key).\(slot)", label: "\(bucket.limitName ?? key) · \(duration)",
                    usedPercent: window.usedPercent, resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) }, durationMinutes: window.windowDurationMins))
            }
        }
        return Snapshot(observedAt: now, windows: windows, identity: identity, source: "Codex app-server",
            note: limited ? "The provider reports a usage or credit restriction. Percentages alone do not indicate availability." : (windows.isEmpty ? "No quota windows were returned for this account. This does not mean zero usage or unlimited access." : nil), providerRestricted: limited)
    }

    private struct ClaudeReport: Decodable {
        struct Limits: Decodable {
            struct Window: Decodable { let used_percentage: Double?; let resets_at: Double? }
            let five_hour: Window?; let seven_day: Window?
        }
        let rate_limits: Limits?
    }
    public static func claude(_ data: Data, at now: Date = Date()) throws -> Snapshot {
        let report = try JSONDecoder().decode(ClaudeReport.self, from: data)
        var windows: [QuotaWindow] = []
        for (label, value) in [("5-hour", report.rate_limits?.five_hour), ("7-day", report.rate_limits?.seven_day)] {
            guard let percent = value?.used_percentage else { continue }
            windows.append(try QuotaWindow(id: label, label: label, usedPercent: percent,
                resetsAt: value?.resets_at.map { Date(timeIntervalSince1970: $0) }, durationMinutes: label == "5-hour" ? 300 : 10_080))
        }
        return Snapshot(observedAt: now, windows: windows, source: "Claude Code status-line feed",
            note: windows.isEmpty ? "Claude Code has not supplied subscription quota data. It may require an eligible Pro/Max plan, a newer version, and a completed response. Context tokens and session cost are not subscription quotas." : "Observed while Claude Code was active. Account assignment is manual; the feed does not verify your signed-in identity.")
    }

    public struct CostPage: Sendable { public let amount: Decimal; public let nextPage: String? }
    public static func costs(_ data: Data, kind: ConnectionKind) throws -> CostPage {
        struct Page<Row: Decodable>: Decodable {
            struct Bucket: Decodable { let results: [Row] }
            let data: [Bucket]; let has_more: Bool; let next_page: String?
        }
        struct OpenAIRow: Decodable {
            struct Amount: Decodable { let value: Decimal; let currency: String }
            let amount: Amount
        }
        struct ClaudeRow: Decodable { let amount: String; let currency: String }
        var total: Decimal = 0
        let more: Bool; let next: String?
        switch kind {
        case .openAIAPI:
            let page = try JSONDecoder().decode(Page<OpenAIRow>.self, from: data)
            for row in page.data.flatMap(\.results) {
                guard row.amount.currency.lowercased() == "usd", !row.amount.value.isNaN else { throw UsageError.invalidData }
                total += row.amount.value
            }
            more = page.has_more; next = page.next_page
        case .claudeAPI:
            let page = try JSONDecoder().decode(Page<ClaudeRow>.self, from: data)
            for row in page.data.flatMap(\.results) {
                guard row.currency.lowercased() == "usd", let amount = Decimal(string: row.amount, locale: Locale(identifier: "en_US_POSIX")), !amount.isNaN,
                      row.amount.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil else { throw UsageError.invalidData }
                total += amount / 100
            }
            more = page.has_more; next = page.next_page
        default: throw UsageError.invalidData
        }
        guard !total.isNaN else { throw UsageError.invalidData }
        guard !more || (next != nil && !next!.isEmpty) else { throw UsageError.invalidData }
        return CostPage(amount: total, nextPage: more ? next : nil)
    }
}

public struct ClaudeFeed: Codable, Sendable {
    public let accountID: UUID
    public let snapshot: Snapshot
    public init(accountID: UUID, snapshot: Snapshot) { self.accountID = accountID; self.snapshot = snapshot }
    public static func read(_ url: URL, accountID: UUID) throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw UsageError.unavailable("Waiting for a reading. Finish Claude’s sign-in if prompted, then use Claude Code normally.")
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: 65_537) ?? Data()
        guard data.count <= 65_536 else { throw UsageError.invalidData }
        let feed = try JSONDecoder().decode(ClaudeFeed.self, from: data)
        guard feed.accountID == accountID, feed.snapshot.observedAt <= Date().addingTimeInterval(60) else { throw UsageError.invalidData }
        for window in feed.snapshot.windows {
            guard window.usedPercent.isFinite, (0...100).contains(window.usedPercent) else { throw UsageError.invalidData }
        }
        return feed.snapshot
    }
}
