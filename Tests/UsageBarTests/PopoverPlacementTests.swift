import Foundation
import Testing
@testable import UsageBar

@Test func popoverStaysBelowMenuBarAfterGrowing() {
    let screen = CGRect(x: 0, y: 0, width: 1200, height: 740)
    let frame = CGRect(x: 900, y: 500, width: 350, height: 400)
    let result = CGRect(origin: PopoverPlacement.origin(for: frame, inside: screen), size: frame.size)
    #expect(screen.contains(result))
    #expect(result.maxY == 740)
}
@Test func popoverSupportsNegativeMonitorCoordinatesAndPreservesValidPosition() {
    let screen = CGRect(x: -1400, y: -200, width: 1200, height: 740)
    let frame = CGRect(x: -1300, y: -100, width: 350, height: 400)
    #expect(PopoverPlacement.origin(for: frame, inside: screen) == frame.origin)
    let overflow = CGRect(x: -1500, y: 400, width: 350, height: 400)
    #expect(screen.contains(CGRect(origin: PopoverPlacement.origin(for: overflow, inside: screen), size: overflow.size)))
}
