import XCTest
@testable import FanControlCore

final class SMCCodecTests: XCTestCase {
    func testFPE2Decode() {
        XCTAssertEqual(SMCCodec.decodeFPE2([0x17, 0x70]), 1500.0)  // 0x1770=6000, /4
    }
    func testFPE2RoundTrip() {
        let bytes = SMCCodec.encodeFPE2(2500)
        XCTAssertEqual(SMCCodec.decodeFPE2(bytes), 2500.0)
    }
    func testFLTDecode() {
        // Float(1000.0).bitPattern = 0x447A0000 → little-endian bytes 00 00 7A 44
        let v = SMCCodec.decodeFLT([0x00, 0x00, 0x7A, 0x44])
        XCTAssertEqual(v, 1000.0, accuracy: 0.001)
    }
    func testFLTRoundTrip() {
        let bytes = SMCCodec.encodeFLT(3906.5)
        XCTAssertEqual(SMCCodec.decodeFLT(bytes), 3906.5, accuracy: 0.001)
    }
    func testSP78Decode() {
        // 68*256+32 = 17440 /256 = 68.125°C
        XCTAssertEqual(SMCCodec.decodeSP78([68, 32]), 68.125, accuracy: 0.001)
    }
    func testSP78Negative() {
        XCTAssertEqual(SMCCodec.decodeSP78([0xFF, 0xFF]), -0.00390625, accuracy: 0.0001)
    }
    func testFourCC() {
        XCTAssertEqual(SMCCodec.fourCC("FNum"), 0x464E756D)
        XCTAssertEqual(SMCCodec.fourCC("TC0P"), 0x54433050)
    }
    func testDecodeByType() {
        XCTAssertEqual(SMCCodec.decode(dataType: "fpe2", bytes: [0x17, 0x70]), 1500.0)
        XCTAssertEqual(SMCCodec.decode(dataType: "flt ", bytes: [0x00, 0x00, 0x7A, 0x44]), 1000.0, accuracy: 0.001)
        XCTAssertEqual(SMCCodec.decode(dataType: "sp78", bytes: [68, 32]), 68.125, accuracy: 0.001)
        XCTAssertEqual(SMCCodec.decode(dataType: "ui8 ", bytes: [2]), 2.0)
    }
    func testEncodeByType() {
        let bytes = SMCCodec.encode(rpm: 3906.5, dataType: "flt ")
        XCTAssertEqual(SMCCodec.decode(dataType: "flt ", bytes: bytes), 3906.5, accuracy: 0.001)
    }
}
