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

@Test func chartBarsPreserveActualReadingsAndEmptyIntervals() {
    let start = Date(timeIntervalSince1970: 1000)
    let raw = [HistorySample(timestamp: start, value: 80, segment: 0),
               HistorySample(timestamp: start.addingTimeInterval(5), value: 75, segment: 0),
               HistorySample(timestamp: start.addingTimeInterval(100), value: 99, segment: 1)]
    let bars = HistorySeries.barSamples(raw, count: 10)
    #expect(bars.count == 2)
    #expect(bars.map(\.value) == [75, 99])
    #expect(bars.map(\.timestamp) == [raw[1].timestamp, raw[2].timestamp])
    #expect(bars.map(\.segment) == [0, 1])
    #expect(HistorySeries.barSamples([], count: 10).isEmpty)
    #expect(HistorySeries.barSamples(raw, count: 0).isEmpty)
    #expect(HistorySeries.barSamples([raw[0]]).count == 1)
}

@Test func timeBasedSmoothingPreservesFlatReadingsAndExactEndpoints() {
    let start = Date(timeIntervalSince1970: 1000)
    let flat = (0..<60).map { HistorySample(timestamp: start.addingTimeInterval(Double($0) * 30), value: 97, segment: 0) }
    #expect(HistorySeries.smoothTrend(flat).allSatisfy { abs($0.value - 97) < 0.000001 })
    let step = (0..<60).map { HistorySample(timestamp: start.addingTimeInterval(Double($0) * 30), value: $0 < 30 ? 90 : 70, segment: 0) }
    let smooth = HistorySeries.smoothTrend(step)
    #expect(smooth.first?.value == 90)
    #expect(smooth.last?.value == 70)
    #expect(smooth[20].value < 90 && smooth[40].value > 70)
    #expect(smooth.allSatisfy { (70...90).contains($0.value) })
}

@Test func fittedAllowanceScaleHasHeadroomAndNeverExaggeratesBelowTenPoints() {
    #expect(HistorySeries.allowanceTrendDomain([96, 99, 100]) == 90...100)
    #expect(HistorySeries.allowanceTrendDomain([46, 62]) == 40...65)
    #expect(HistorySeries.allowanceTrendDomain([0, 0]) == 0...10)
    #expect(HistorySeries.allowanceTrendDomain([100]) == 90...100)
    #expect(HistorySeries.allowanceTrendDomain([.nan, .infinity]) == 0...100)
    #expect(HistorySeries.allowanceTrendDomain([0, 100]) == 0...100)
}
