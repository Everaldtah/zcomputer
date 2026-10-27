import XCTest
@testable import ZAgent

final class ZAgentPlaceholderTests: XCTestCase {
    func testModuleName() { XCTAssertEqual(ZAgentModule.name, "ZAgent") }
}
