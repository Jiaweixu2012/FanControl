import XCTest
@testable import FanControlCore

final class HelperProtocolTests: XCTestCase {
    func testRequestEncodeDecode() throws {
        let req = HelperRequest(cmd: .set, index: 1, rpm: 2000)
        let data = try HelperWire.encode(req)
        let decoded: HelperRequest = try HelperWire.decode(data)
        XCTAssertEqual(decoded, req)
    }
    func testPingRoundTrip() throws {
        let req = HelperRequest(cmd: .ping, index: nil, rpm: nil)
        let data = try HelperWire.encode(req)
        XCTAssertEqual(try HelperWire.decode(data), req)
    }
    func testResponseRoundTrip() throws {
        let resp = HelperResponse(ok: false, error: "not privileged")
        let data = try HelperWire.encode(resp)
        let decoded: HelperResponse = try HelperWire.decode(data)
        XCTAssertEqual(decoded, resp)
    }
    func testLineFraming() {
        let req = HelperRequest(cmd: .auto, index: 0, rpm: nil)
        let line = HelperWire.encodeLine(req)
        XCTAssertTrue(line.hasSuffix("\n"))
    }
}
