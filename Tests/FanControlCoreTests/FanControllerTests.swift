import XCTest
import Combine
@testable import FanControlCore

final class MockReader: FanReading {
    var fans: [FanInfo] = []
    var temp: Double? = 60
    func refreshFans() throws -> [FanInfo] { fans }
    func cpuTemperature() throws -> Double? { temp }
}

final class MockWriter: FanWriting {
    var calls: [(index: Int, action: FanWriteAction)] = []
    var shouldFail = false
    func write(_ action: FanWriteAction, index: Int) throws {
        if shouldFail { throw SMCError.callFailed(1) }
        calls.append((index, action))
    }
}

final class FanControllerTests: XCTestCase {
    var reader: MockReader!
    var writer: MockWriter!
    var controller: FanController!

    override func setUp() {
        reader = MockReader()
        reader.fans = [
            FanInfo(index: 0, currentRPM: 1200, minRPM: 1200, maxRPM: 6500),
            FanInfo(index: 1, currentRPM: 1400, minRPM: 1300, maxRPM: 6800),
        ]
        writer = MockWriter()
        controller = FanController(reader: reader, writer: writer)
    }

    func testAutoModeWritesAutoForEveryFan() throws {
        controller.mode = .auto
        try controller.applyMode()
        XCTAssertEqual(writer.calls.count, 2)
        XCTAssertEqual(writer.calls.map(\.action), [.auto, .auto])
        XCTAssertEqual(writer.calls.map(\.index), [0, 1])
    }

    func testMinModeUsesEachFanMin() throws {
        controller.mode = .min
        try controller.applyMode()
        XCTAssertEqual(writer.calls.map(\.action), [.manual(1200), .manual(1300)])
    }

    func testMaxModeUsesEachFanMax() throws {
        controller.mode = .max
        try controller.applyMode()
        XCTAssertEqual(writer.calls.map(\.action), [.manual(6500), .manual(6800)])
    }

    func testCustomModeClampsPerFan() throws {
        controller.mode = .custom
        controller.customRPM = "2000"
        try controller.applyMode()
        XCTAssertEqual(writer.calls.map(\.action), [.manual(2000), .manual(2000)])
        // clamp: value below min of fan1 -> clamped to its min
        controller.customRPM = "1250"
        writer.calls.removeAll()
        try controller.applyMode()
        XCTAssertEqual(writer.calls.map(\.action), [.manual(1250), .manual(1300)])
    }

    func testInvalidCustomRPMProducesError() throws {
        controller.mode = .custom
        controller.customRPM = "abc"
        try controller.applyMode()
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(writer.calls.count, 0)
    }

    func testValidateRange() {
        let fans = [FanInfo(index: 0, currentRPM: 0, minRPM: 1200, maxRPM: 6500),
                    FanInfo(index: 1, currentRPM: 0, minRPM: 1300, maxRPM: 6800)]
        XCTAssertTrue(controller.isValidCustomRPM("1200", fans: fans))
        XCTAssertTrue(controller.isValidCustomRPM("6800", fans: fans))
        XCTAssertFalse(controller.isValidCustomRPM("1199", fans: fans))
        XCTAssertFalse(controller.isValidCustomRPM("6801", fans: fans))
        XCTAssertFalse(controller.isValidCustomRPM("12x", fans: fans))
    }

    func testWriteErrorSurfacesMessage() {
        writer.shouldFail = true
        controller.mode = .min
        try? controller.applyMode()
        XCTAssertNotNil(controller.errorMessage)
    }
}
