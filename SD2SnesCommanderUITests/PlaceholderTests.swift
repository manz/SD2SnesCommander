import XCTest

// UI tests are intentionally empty: the app talks to real USB hardware on
// launch, which makes scripted launches flaky in CI and locally. Unit tests
// in SD2snesCommanderCoreTests and SD2SnesCommanderTests cover the
// non-hardware behavior. This placeholder keeps the target building.
final class PlaceholderTests: XCTestCase {
    func testTargetBuilds() {
        XCTAssertTrue(true)
    }
}
