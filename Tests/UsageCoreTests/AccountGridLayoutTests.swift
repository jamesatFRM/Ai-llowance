import Testing
@testable import UsageCore

@Test func accountGridBalancesEverySupportedCountAndWidth() {
    for width in [320.0, 596, 776, 1056, 1176, 1576] {
        for count in 1...10 {
            let layout = AccountGridLayout(count: count, width: width)
            #expect(layout.rowCounts.reduce(0, +) == count)
            #expect((layout.rowCounts.max()! - layout.rowCounts.min()!) <= 1)
            #expect(layout.cardWidth > 0)
            for row in layout.rowCounts {
                #expect(Double(row) * layout.cardWidth + Double(row - 1) * 12 <= width + 0.001)
            }
            if width >= 828 && count > 1 { #expect(!layout.rowCounts.contains(1)) }
        }
    }
    #expect(AccountGridLayout(count: 5, width: 1056).rowCounts == [3, 2])
    #expect(AccountGridLayout(count: 9, width: 1176).rowCounts == [3, 3, 3])
    #expect(AccountGridLayout(count: 10, width: 1176).rowCounts == [4, 3, 3])
    #expect(AccountGridLayout(count: 0, width: 1056).rowCounts.isEmpty)
    #expect(AccountGridLayout(count: 4, width: 1056).rowCounts == [4])
    #expect(AccountGridLayout(count: 4, width: 1056).cardWidth == 255)
}
