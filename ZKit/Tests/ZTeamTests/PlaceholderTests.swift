import XCTest
@testable import ZTeam

final class ZTeamPlaceholderTests: XCTestCase {
    func testModuleName() { XCTAssertEqual(ZTeamModule.name, "ZTeam") }
}
