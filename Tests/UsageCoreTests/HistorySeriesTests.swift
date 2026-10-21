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

@Test func smoothedHistoryPreservesBoundariesAndStaysWithinObservedRange() {
    let start = Date()
    let values: [(Double, Int)] = [(0, 0), (0, 0), (0, 0), (10, 0), (10, 0), (10, 0), (100, 1), (100, 1)]
    let raw = values.enumerated().map { index, item in
        HistorySample(timestamp: start.addingTimeInterval(Double(index) * 300), value: item.0, segment: item.1)
    }
    let smooth = HistorySeries.smoothTrend(raw)
    #expect(smooth[2].value > 0 && smooth[2].value < 10)
    #expect(smooth[3].value > 0 && smooth[3].value < 10)
    #expect(smooth[0].value == 0 && smooth[5].value == 10)
    #expect(smooth[6].value == 100 && smooth[7].value == 100)
    #expect(smooth.map(\.segment) == raw.map(\.segment))
    #expect(smooth.map(\.timestamp) == raw.map(\.timestamp))
    #expect(smooth.prefix(6).allSatisfy { (0...10).contains($0.value) })
    #expect(HistorySeries.smoothTrend([]).isEmpty)
}
