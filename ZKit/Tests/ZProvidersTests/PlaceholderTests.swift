import XCTest
@testable import ZProviders

final class ZProvidersPlaceholderTests: XCTestCase {
    func testModuleName() { XCTAssertEqual(ZProvidersModule.name, "ZProviders") }
}
