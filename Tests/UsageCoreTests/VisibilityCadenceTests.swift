import Foundation
import Testing
@testable import UsageCore

@Test func openingPanelAfterRecentBackgroundReadUsesVisibleCadence() {
    let start = Date(timeIntervalSince1970: 2_000_000)
    var state = PollState()
    state.succeeded(at: start, interval: ConnectionKind.claudeCode.refreshInterval(visible: false))
    #expect(state.nextAttempt == start.addingTimeInterval(600))

    // Opening five seconds later must respect the manual read throttle while
    // ensuring the next regular read is a minute after the previous one.
    state.adjustHealthyInterval(ConnectionKind.claudeCode.refreshInterval(visible: true))
    #expect(!state.shouldRefresh(at: start.addingTimeInterval(5), manual: true))
    #expect(!state.shouldRefresh(at: start.addingTimeInterval(59)))
    #expect(state.shouldRefresh(at: start.addingTimeInterval(60)))
    #expect(state.lastSuccess == start)

    state.adjustHealthyInterval(ConnectionKind.claudeCode.refreshInterval(visible: false))
    #expect(!state.shouldRefresh(at: start.addingTimeInterval(60)))
    #expect(state.shouldRefresh(at: start.addingTimeInterval(600)))
}

@Test func visibilityChangesNeverShortenProviderBackoff() {
    let start = Date(timeIntervalSince1970: 2_000_000)
    for error in [UsageError.server, .authentication, .rateLimited(1200)] {
        var state = PollState()
        state.succeeded(at: start, interval: 600)
        state.failed(error, at: start.addingTimeInterval(10))
        let retry = state.nextAttempt
        state.adjustHealthyInterval(60)
        #expect(state.nextAttempt == retry)
        #expect(state.failures == 1)
        #expect(!state.shouldRefresh(at: retry.addingTimeInterval(-1), manual: true))
        state.adjustHealthyInterval(900)
        #expect(state.nextAttempt == retry)
    }
}

@Test func firstReadingRemainsDueAfterVisibilityChange() {
    var state = PollState()
    let original = state.nextAttempt
    state.adjustHealthyInterval(600)
    #expect(state.nextAttempt == original)
    #expect(state.shouldRefresh(at: Date()))
}
