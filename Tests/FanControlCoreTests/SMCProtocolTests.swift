import XCTest
@testable import FanControlCore

final class SMCProtocolTests: XCTestCase {
    func testStructOffsets() {
        XCTAssertEqual(SMCConnection.structSize, 80)
        XCTAssertEqual(SMCConnection.offKey, 0)
        XCTAssertEqual(SMCConnection.offKeyInfoSize, 28)
        XCTAssertEqual(SMCConnection.offKeyInfoType, 32)
        XCTAssertEqual(SMCConnection.offData8, 42)
        XCTAssertEqual(SMCConnection.offBytes, 48)
    }
    func testBuildRequest() {
        let req = SMCConnection.buildRequest(key: "FNum", command: 9)
        XCTAssertEqual(req.count, 80)
        let fourcc = UInt32(littleEndian: (UInt32(req[0]) | (UInt32(req[1]) << 8) | (UInt32(req[2]) << 16) | (UInt32(req[3]) << 24)))
        XCTAssertEqual(fourcc, 0x464E756D)
        XCTAssertEqual(req[42], 9)
    }
    func testBackfillKeyInfo() {
        var req = SMCConnection.buildRequest(key: "F0Ac", command: 5)
        SMCConnection.backfill(&req, dataSize: 4, dataType: SMCCodec.fourCC("flt "))
        let size = UInt32(littleEndian: (UInt32(req[28]) | (UInt32(req[29]) << 8) | (UInt32(req[30]) << 16) | (UInt32(req[31]) << 24)))
        XCTAssertEqual(size, 4)
        let type = UInt32(littleEndian: (UInt32(req[32]) | (UInt32(req[33]) << 8) | (UInt32(req[34]) << 16) | (UInt32(req[35]) << 24)))
        XCTAssertEqual(type, SMCCodec.fourCC("flt "))
    }
}
