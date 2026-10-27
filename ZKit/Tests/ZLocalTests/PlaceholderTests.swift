import XCTest
@testable import ZLocal

final class ZLocalPlaceholderTests: XCTestCase {
    func testModuleName() { XCTAssertEqual(ZLocalModule.name, "ZLocal") }
}
