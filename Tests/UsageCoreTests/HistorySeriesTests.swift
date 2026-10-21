import Foundation
import Testing
@testable import UsageCore

@Test func historyLineBreaksAtGapsResetsAndQuotaChanges() {
    let start = Date()
    let reset = start.addingTimeInterval(86400)
    let points = [
        UsageHistoryPoint(timestamp: start, remainingPercent: 80, windowID: "week", resetsAt: reset),
        UsageHistoryPoint(timestamp: start.addingTimeInterval(300), remainingPercent: 75, windowID: "week", resetsAt: reset),
        UsageHistoryPoint(timestamp: start.addingTimeInterval(600), remainingPercent: 100, windowID: "week", resetsAt: reset),
        UsageHistoryPoint(timestamp: start.addingTimeInterval(900), remainingPercent: 98, windowID: "session", resetsAt: reset),
        UsageHistoryPoint(timestamp: start.addingTimeInterval(7200), remainingPercent: 90, windowID: "session", resetsAt: reset)
    ]
    #expect(HistorySeries.samples(points, kind: .codex).map(\.segment) == [0, 0, 1, 2, 3])
}
@Test func spendingHistorySeparatesBillingRolloverAndNeverBridgesMissingValues() {
    let start = Date()
    let points = [UsageHistoryPoint(timestamp: start, costUSD: 50),
                  UsageHistoryPoint(timestamp: start.addingTimeInterval(300), costUSD: 51),
                  UsageHistoryPoint(timestamp: start.addingTimeInterval(600), costUSD: 1),
                  UsageHistoryPoint(timestamp: start.addingTimeInterval(900)),
                  UsageHistoryPoint(timestamp: start.addingTimeInterval(1200), costUSD: 2)]
    #expect(HistorySeries.samples(points, kind: .openAIAPI).map(\.segment) == [0, 0, 1, 2])
}

@Test func roundedResetTimeDoesNotTurnContinuousHistoryIntoDots() {
    let start = Date(), reset = Date().addingTimeInterval(86400)
    let points = [UsageHistoryPoint(timestamp: start, remainingPercent: 80, windowID: "week", resetsAt: reset),
                  UsageHistoryPoint(timestamp: start.addingTimeInterval(300), remainingPercent: 79, windowID: "week", resetsAt: reset.addingTimeInterval(60))]
    #expect(HistorySeries.samples(points, kind: .claudeCode).map(\.segment) == [0, 0])
}

@Test func historyConsumptionCountsOnlyObservedComparableDrops() {
    let start = Date()
    let values: [(Double, Int)] = [(80, 0), (75, 0), (100, 1), (98, 1), (50, 2), (49, 2)]
    let samples = values.enumerated().map { index, value in
        HistorySample(timestamp: start.addingTimeInterval(Double(index) * 300), value: value.0, segment: value.1)
    }
    let result = HistorySeries.consumption(samples)
    #expect(result.map(\.value) == [0, 5, 5, 7, 7, 8])
    #expect(result.map(\.segment) == samples.map(\.segment))
    #expect(result.map(\.timestamp) == samples.map(\.timestamp))
    #expect(HistorySeries.consumption([]).isEmpty)
}
