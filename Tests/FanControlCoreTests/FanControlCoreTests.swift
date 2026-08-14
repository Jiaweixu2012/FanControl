import XCTest
@testable import FanControlCore

final class FanControlCoreTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(FanControlVersion.string, "1.0.0")
    }
}
