import XCTest
@testable import ZMemory

final class ZMemoryPlaceholderTests: XCTestCase {
    func testModuleName() { XCTAssertEqual(ZMemoryModule.name, "ZMemory") }
}
