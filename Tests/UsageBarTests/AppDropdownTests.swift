import Testing
@testable import UsageBar

@Test @MainActor
func dropdownNavigationSkipsDisabledActionsAndSeparatorsAndWraps() {
    let options = AppDropdownOptions(items: [
        AppDropdownItem("Unavailable", selected: true, enabled: false) {},
        .separator,
        AppDropdownItem("First") {},
        AppDropdownItem("Selected", selected: true) {},
        AppDropdownItem("Last") {}
    ])
    #expect(options.initialIndex == 3)
    #expect(options.step(from: 3, by: 1) == 4)
    #expect(options.step(from: 4, by: 1) == 2)
    #expect(options.step(from: 2, by: -1) == 4)
    #expect(options.step(from: nil, by: -1) == 4)
    #expect(!options.canSelect(0))
    #expect(!options.canSelect(1))
    #expect(!options.canSelect(-1))
    #expect(!options.canSelect(5))
}

@Test @MainActor
func dropdownTypeAheadWrapsAndIgnoresDisabledMatches() {
    let options = AppDropdownOptions(items: [
        AppDropdownItem("Personal") {},
        AppDropdownItem("Paused", enabled: false) {},
        AppDropdownItem("Project") {},
        AppDropdownItem("Éxample") {}
    ])
    #expect(options.match("p", after: 0) == 2)
    #expect(options.match("p", after: 2) == 0)
    #expect(options.match("EX", after: nil) == 3)
    #expect(options.match("unknown", after: 0) == nil)
}

@Test @MainActor
func emptyOrUnavailableDropdownsCannotSelectAnAction() {
    for items in [[], [.separator, AppDropdownItem("Unavailable", enabled: false) {}]] as [[AppDropdownItem]] {
        let options = AppDropdownOptions(items: items)
        #expect(options.initialIndex == nil)
        #expect(options.step(from: nil, by: 1) == nil)
        #expect(options.match("u", after: nil) == nil)
        #expect(!options.canSelect(0))
    }
}
