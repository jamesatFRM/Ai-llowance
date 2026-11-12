import Foundation

public enum DashboardInsightKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case weeklyPace, unusedAllowance, limitPressure, burnRate, usageCalendar, creditRunway
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .weeklyPace: "Weekly pace"; case .unusedAllowance: "Unused allowance"
        case .limitPressure: "Limit pressure"; case .burnRate: "Burn rate"
        case .usageCalendar: "Usage calendar"; case .creditRunway: "Credit runway"
        }
    }
    public var subtitle: String {
        switch self {
        case .weeklyPace: "See how your weekly allowance is tracking."
        case .unusedAllowance: "See what was left before each weekly reset."
        case .limitPressure: "Find the limit that is closest to empty."
        case .burnRate: "Find the busiest bursts in your recent usage."
        case .usageCalendar: "See your daily pattern across the year."
        case .creditRunway: "Estimate how long your API credits may last."
        }
    }
    public var symbol: String {
        switch self {
        case .weeklyPace: "chart.line.uptrend.xyaxis"; case .unusedAllowance: "arrow.counterclockwise.circle"
        case .limitPressure: "gauge.with.dots.needle.67percent"; case .burnRate: "waveform.path"
        case .usageCalendar: "calendar"; case .creditRunway: "creditcard"
        }
    }
    public func supports(_ kind: ConnectionKind) -> Bool {
        switch self {
        case .creditRunway: kind.isBalance
        case .weeklyPace, .unusedAllowance, .limitPressure: !kind.isAPI
        case .burnRate, .usageCalendar: true
        }
    }
    public var charts: [InsightChartStyle] {
        switch self {
        case .weeklyPace: [.area, .line]
        case .unusedAllowance: [.bars, .line]
        case .limitPressure: [.rings, .line]
        case .burnRate: [.area, .bars, .line]
        case .usageCalendar: [.calendar, .bars]
        case .creditRunway: [.area, .bars, .line]
        }
    }
    public var periods: [InsightPeriod] {
        switch self {
        case .weeklyPace: [.cycle]
        case .unusedAllowance: [.month, .quarter, .year]
        case .limitPressure: [.day, .week]
        case .burnRate: [.hours, .day, .week]
        case .usageCalendar: [.month, .quarter, .year]
        case .creditRunway: [.week, .fortnight, .month]
        }
    }
    public var defaultPeriod: InsightPeriod {
        switch self {
        case .weeklyPace: .cycle; case .unusedAllowance: .quarter; case .limitPressure: .week
        case .burnRate: .day; case .usageCalendar: .year; case .creditRunway: .fortnight
        }
    }
}

public enum InsightChartStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case area, line, bars, rings, calendar
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var symbol: String {
        switch self {
        case .area: "chart.line.uptrend.xyaxis"; case .line: "chart.xyaxis.line"
        case .bars: "chart.bar.fill"; case .rings: "circle.circle"; case .calendar: "calendar"
        }
    }
}
public enum InsightPeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case cycle, hours, day, week, fortnight, month, quarter, year
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .cycle: "This cycle"; case .hours: "6 hours"; case .day: "24 hours"
        case .week: "7 days"; case .fortnight: "14 days"; case .month: "30 days"
        case .quarter: "90 days"; case .year: "360 days"
        }
    }
    public var seconds: TimeInterval {
        switch self {
        case .cycle, .week: 7 * 86400; case .hours: 6 * 3600; case .day: 86400
        case .fortnight: 14 * 86400; case .month: 30 * 86400; case .quarter: 90 * 86400; case .year: 360 * 86400
        }
    }
}
public enum InsightSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact, wide, full
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var span: Int { self == .compact ? 1 : self == .wide ? 2 : 4 }
}
public enum InsightMetric: String, Codable, Sendable { case weekly, session, money }
public struct DashboardInsight: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var kind: DashboardInsightKind
    public var accountID: UUID?
    public var chart: InsightChartStyle
    public var period: InsightPeriod
    public var size: InsightSize
    public var collapsed: Bool
    public var metric: InsightMetric
    public init(id: UUID = UUID(), kind: DashboardInsightKind, accountID: UUID? = nil,
                chart: InsightChartStyle? = nil, period: InsightPeriod? = nil, size: InsightSize = .wide, collapsed: Bool = false, metric: InsightMetric = .weekly) {
        self.id = id; self.kind = kind; self.accountID = accountID
        self.chart = chart.flatMap { kind.charts.contains($0) ? $0 : nil } ?? kind.charts[0]
        self.period = period.flatMap { kind.periods.contains($0) ? $0 : nil } ?? kind.defaultPeriod
        self.size = size; self.collapsed = collapsed; self.metric = metric
    }
    private enum CodingKeys: String, CodingKey { case id, kind, accountID, chart, period, size, collapsed, metric }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(DashboardInsightKind.self, forKey: .kind)
        self.init(id: try c.decode(UUID.self, forKey: .id), kind: kind,
            accountID: try c.decodeIfPresent(UUID.self, forKey: .accountID),
            chart: (try c.decodeIfPresent(String.self, forKey: .chart)).flatMap(InsightChartStyle.init(rawValue:)),
            period: (try c.decodeIfPresent(String.self, forKey: .period)).flatMap(InsightPeriod.init(rawValue:)),
            size: (try c.decodeIfPresent(String.self, forKey: .size)).flatMap(InsightSize.init(rawValue:)) ?? .wide,
            collapsed: try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false,
            metric: (try c.decodeIfPresent(String.self, forKey: .metric)).flatMap(InsightMetric.init(rawValue:)) ?? .weekly)
    }
    public var tileID: String { "insight:" + id.uuidString }
}

public struct DashboardLayoutPreferences: Codable, Equatable, Sendable {
    public static let maximumInsights = 12
    public var insights: [DashboardInsight] = []
    public var order: [String] = []
    public var hidden: Set<String> = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case insights, order, hidden }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var seen = Set<UUID>()
        if var cards = try? c.nestedUnkeyedContainer(forKey: .insights) {
            var inspected = 0
            while !cards.isAtEnd && insights.count < Self.maximumInsights && inspected < 64 {
                let decoder = try cards.superDecoder(); inspected += 1
                if let card = try? DashboardInsight(from: decoder), seen.insert(card.id).inserted { insights.append(card) }
            }
        }
        var ids = Set<String>()
        order = (try c.decodeIfPresent([String].self, forKey: .order) ?? [])
            .filter { Self.validTileID($0) && ids.insert($0).inserted }.prefix(1014).map { $0 }
        hidden = Set((try c.decodeIfPresent([String].self, forKey: .hidden) ?? [])
            .filter(Self.validTileID).prefix(1014))
    }
    public static func accountTileID(_ id: UUID) -> String { "account:" + id.uuidString }
    public static func validTileID(_ id: String) -> Bool {
        if ["overview", "activity"].contains(id) { return true }
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 2 && ["account", "insight"].contains(String(parts[0])) && UUID(uuidString: String(parts[1])) != nil
    }
    public func arranged(_ ids: [String], includingHidden: Bool = false) -> [String] {
        let valid = Set(ids)
        var seen = Set<String>()
        return (order + ids).filter { valid.contains($0) && (includingHidden || !hidden.contains($0)) && seen.insert($0).inserted }
    }
}
