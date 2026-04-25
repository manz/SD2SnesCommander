import Testing
@testable import SD2SnesCommander

@MainActor
struct GamingDetectionTests {
    @Test func menuPathsReportAsNotGaming() {
        #expect(!MainViewModel.isGamingFromRomName("/sd2snes/menu.bin"))
        #expect(!MainViewModel.isGamingFromRomName("/sd2snes/m3nu.bin"))
        #expect(!MainViewModel.isGamingFromRomName("/SD2SNES/MENU.BIN"))
    }

    @Test func emptyOrNilNamesReportAsNotGaming() {
        #expect(!MainViewModel.isGamingFromRomName(nil))
        #expect(!MainViewModel.isGamingFromRomName(""))
    }

    @Test func realROMPathsReportAsGaming() {
        #expect(MainViewModel.isGamingFromRomName("/Hack/ff4.sfc"))
        #expect(MainViewModel.isGamingFromRomName("game.smc"))
    }

    @Test func displayRomNameStripsPathWhenGaming() {
        #expect(MainViewModel.displayRomName("/Hack/ff4.sfc", gaming: true) == "ff4.sfc")
        #expect(MainViewModel.displayRomName("ff4.sfc", gaming: true) == "ff4.sfc")
    }

    @Test func displayRomNameNilsOutWhenNotGaming() {
        #expect(MainViewModel.displayRomName("/sd2snes/menu.bin", gaming: false) == nil)
    }
}

@MainActor
struct NavigationHistoryTests {
    @Test func appendingNewPathExtendsHistory() {
        let vm = MainViewModel()
        vm.addToNavigationHistory("")
        vm.addToNavigationHistory("Games")
        vm.addToNavigationHistory("Games/Mario")

        #expect(vm.remoteNavigationHistory == ["", "Games", "Games/Mario"])
        #expect(vm.remoteHistoryIndex == 2)
        #expect(vm.canGoBack)
        #expect(!vm.canGoForward)
    }

    @Test func appendingSamePathDoesNotDuplicate() {
        let vm = MainViewModel()
        vm.addToNavigationHistory("Games")
        vm.addToNavigationHistory("Games")
        #expect(vm.remoteNavigationHistory == ["Games"])
        #expect(vm.remoteHistoryIndex == 0)
    }

    @Test func goingBackThenAddingTruncatesForwardHistory() {
        let vm = MainViewModel()
        vm.addToNavigationHistory("a")
        vm.addToNavigationHistory("b")
        vm.addToNavigationHistory("c")

        // Simulate stepping back twice then adding a new branch.
        vm.remoteHistoryIndex = 0
        vm.updateNavigationButtons()
        #expect(vm.canGoForward)

        vm.addToNavigationHistory("z")
        #expect(vm.remoteNavigationHistory == ["a", "z"])
        #expect(vm.remoteHistoryIndex == 1)
        #expect(!vm.canGoForward)
    }
}
