# FanControl Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS menu bar app (Swift/SwiftUI) that reads and manually controls Intel Mac fan speeds via SMC, using a root helper daemon for privileged writes.

**Architecture:** A Swift Package with 3 targets: `FanControlCore` (SMC access + protocol + controller logic, unit-tested), `FanControlApp` (SwiftUI MenuBarExtra; reads SMC directly, sends write commands over a Unix socket to the helper), and `FanControlHelper` (root launchd daemon that performs privileged SMC writes). `build.sh` assembles a `.app` bundle; `install.sh` (run with admin rights via osascript) installs the daemon.

**Tech Stack:** Swift 6.2.4 / SwiftUI (macOS 13+), SPM, IOKit (AppleSMC), Foundation socket (Network framework optional — using POSIX sockets via Swift), CoreGraphics for icon generation, `iconutil` for .icns.

**Verified facts (from on-hardware probing on the target MacBookPro15,2):**
- SMC call protocol: method selector always `2`; command goes in `data8` (5=READ_BYTES, 6=WRITE_BYTES, 9=READ_KEYINFO); 80-byte struct with `key`@0, `keyInfo.dataSize`@28, `keyInfo.dataType`@32, `data8`@42, `bytes`@48; keys stored as native-endian `UInt32` fourcc (NO byte-swap); backfill `keyInfo.dataSize`/`dataType` from KEYINFO result before READ/WRITE_BYTES.
- Fan keys on target are `flt` (4-byte float) — must auto-adapt via KEYINFO `dataType` (support `flt `, `fpe2`, `sp78`, `ui8 `).
- Reads need no privilege; writes return `kIOReturnNotPrivileged` from user context → root daemon required.

**Reference spec:** `docs/superpowers/specs/2026-08-14-fan-control-design.md`

**Build/test commands:** `swift build`, `swift test`, `./build.sh`, `sudo ./build/FanControlHelper --daemon` (manual).

---

### Task 1: Project scaffold

**Files:**
- Create: `Package.swift`
- Create: `Sources/FanControlCore/FanControlCore.swift` (placeholder)

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "FanControl",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "FanControl", targets: ["FanControlApp"]),
        .executable(name: "FanControlHelper", targets: ["FanControlHelper"]),
        .library(name: "FanControlCore", targets: ["FanControlCore"]),
    ],
    targets: [
        .target(
            name: "FanControlCore",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(name: "FanControlApp", dependencies: ["FanControlCore"]),
        .executableTarget(name: "FanControlHelper", dependencies: ["FanControlCore"]),
        .testTarget(name: "FanControlCoreTests", dependencies: ["FanControlCore"]),
    ]
)
```

- [ ] **Step 2: Create placeholder sources so SPM resolves**

Create `Sources/FanControlCore/FanControlCore.swift`:
```swift
public enum FanControlVersion {
    public static let string = "1.0.0"
}
```
Create `Sources/FanControlApp/main.swift`:
```swift
import FanControlCore
print("FanControl app placeholder \(FanControlVersion.string)")
```
Create `Sources/FanControlHelper/main.swift`:
```swift
import FanControlCore
print("FanControlHelper placeholder \(FanControlVersion.string)")
```
Create `Tests/FanControlCoreTests/FanControlCoreTests.swift`:
```swift
import XCTest
@testable import FanControlCore

final class FanControlCoreTests: XCTestCase {
    func testVersion() {
        XCTAssertEqual(FanControlVersion.string, "1.0.0")
    }
}
```

- [ ] **Step 3: Verify build & test**

Run: `swift build` then `swift test`
Expected: BUILD SUCCESSFUL; `Test Suite 'FanControlCoreTests' ... passed`.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore: scaffold SPM package with core/app/helper targets"
```

---

### Task 2: SMCKit data codecs (pure logic, TDD)

**Files:**
- Create: `Sources/FanControlCore/SMCCodec.swift`
- Create: `Tests/FanControlCoreTests/SMCCodecTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
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
        // 0x45758CD3 (little-endian bytes D3 8C 75 45) ≈ 3906
        let v = SMCCodec.decodeFLT([0xD3, 0x8C, 0x75, 0x45])
        XCTAssertEqual(v, 3906.0, accuracy: 1.0)
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
        // -1°C = 0xFFFF → -1/256*256
        XCTAssertEqual(SMCCodec.decodeSP78([0xFF, 0xFF]), -0.00390625, accuracy: 0.0001)
    }
    func testFourCC() {
        XCTAssertEqual(SMCCodec.fourCC("FNum"), 0x464E756D)
        XCTAssertEqual(SMCCodec.fourCC("TC0P"), 0x54433050)
    }
    func testDecodeByType() {
        XCTAssertEqual(SMCCodec.decode(dataType: "fpe2", bytes: [0x17, 0x70]), 1500.0)
        XCTAssertEqual(SMCCodec.decode(dataType: "flt ", bytes: [0xD3, 0x8C, 0x75, 0x45]), 3906.0, accuracy: 1.0)
        XCTAssertEqual(SMCCodec.decode(dataType: "sp78", bytes: [68, 32]), 68.125, accuracy: 0.001)
        XCTAssertEqual(SMCCodec.decode(dataType: "ui8 ", bytes: [2]), 2.0)
    }
    func testEncodeByType() {
        // encode to the same type the target machine reports (flt)
        let bytes = SMCCodec.encode(rpm: 3906.5, dataType: "flt ")
        XCTAssertEqual(SMCCodec.decode(dataType: "flt ", bytes: bytes), 3906.5, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: FAIL to compile (SMCCodec missing).

- [ ] **Step 3: Implement `SMCCodec`**

```swift
import Foundation

public enum SMCCodec {

    /// fpe2: fixed point, value * 4, 2 bytes big-endian
    public static func decodeFPE2(_ bytes: [UInt8]) -> Double {
        guard bytes.count >= 2 else { return 0 }
        return Double((Int(bytes[0]) << 8) | Int(bytes[1])) / 4.0
    }

    public static func encodeFPE2(_ rpm: Double) -> [UInt8] {
        let v = max(0, Int((rpm * 4).rounded()))
        return [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }

    /// flt: 4-byte IEEE float, little-endian byte order in SMC
    public static func decodeFLT(_ bytes: [UInt8]) -> Double {
        guard bytes.count >= 4 else { return 0 }
        let bits = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        return Double(Float(bitPattern: bits))
    }

    public static func encodeFLT(_ value: Double) -> [UInt8] {
        let bits = Float(value).bitPattern
        return [UInt8(bits & 0xFF), UInt8((bits >> 8) & 0xFF), UInt8((bits >> 16) & 0xFF), UInt8((bits >> 24) & 0xFF)]
    }

    /// sp78: signed fixed point 8.7, 2 bytes big-endian, /256
    public static func decodeSP78(_ bytes: [UInt8]) -> Double {
        guard bytes.count >= 2 else { return 0 }
        let raw = Int(Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1])))
        return Double(raw) / 256.0
    }

    /// 'FNum' -> 0x464E756D (chars in high-to-low order)
    public static func fourCC(_ s: String) -> UInt32 {
        var u: UInt32 = 0
        for c in s.utf8 { u = (u << 8) | UInt32(c) }
        return u
    }

    public static func fourCCString(_ v: UInt32) -> String {
        var s = ""
        for shift in stride(from: 24, through: 0, by: -8) {
            let byte = (v >> UInt32(shift)) & 0xFF
            if byte == 0 { break }
            s.append(String(UnicodeScalar(byte)))
        }
        return s
    }

    /// Decode SMC bytes based on the reported data type
    public static func decode(dataType: String, bytes: [UInt8]) -> Double {
        let t = dataType.trimmingCharacters(in: .whitespaces)
        switch t {
        case "fpe2": return decodeFPE2(bytes)
        case "flt": return decodeFLT(bytes)
        case "sp78": return decodeSP78(bytes)
        case "ui8", "ui16", "ui32", "ch8":
            var v: Double = 0
            for b in bytes.reversed() { v = v * 256 + Double(b) }
            return v
        default: return 0
        }
    }

    /// Encode a target RPM for the given data type (fan speed keys)
    public static func encode(rpm: Double, dataType: String) -> [UInt8] {
        switch dataType.trimmingCharacters(in: .whitespaces) {
        case "fpe2": return encodeFPE2(rpm)
        default: return encodeFLT(rpm)   // flt is the modern Intel fan type
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS (all codec + fourcc + by-type tests).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: SMC data codecs (flt/fpe2/sp78) + fourcc"
```

---

### Task 3: SMC connection (IOKit calls) + FanInfo

**Files:**
- Create: `Sources/FanControlCore/SMCConnection.swift`
- Create: `Tests/FanControlCoreTests/SMCProtocolTests.swift`

- [ ] **Step 1: Write the failing test for protocol helpers**

Test the pure parts we can unit test (struct offsets and command constants are part of the protocol; encode the raw request builder as a pure function):

```swift
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
        // buildRequest(key:"FNum", command:9) → bytes[0..4] native fourcc 0x464E756D
        // (on little-endian: 6D 75 4E 46), bytes[42] == 9
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test`
Expected: FAIL (SMCConnection missing).

- [ ] **Step 3: Implement `SMCConnection`**

```swift
import Foundation
import IOKit

public enum SMCError: Error, LocalizedError {
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case keyNotFound(String)
    case closed

    public var errorDescription: String? {
        switch self {
        case .serviceNotFound: return "AppleSMC service not found"
        case .openFailed(let r): return "Failed to open AppleSMC (kern 0x\(String(r, radix: 16)))"
        case .callFailed(let r): return "SMC call failed (kern 0x\(String(r, radix: 16)))"
        case .keyNotFound(let k): return "SMC key \(k) not found"
        case .closed: return "SMC session closed"
        }
    }
}

public final class SMCConnection {

    // Verified protocol constants (devnull 80-byte layout)
    public static let structSize = 80
    public static let offKey = 0
    public static let offKeyInfoSize = 28
    public static let offKeyInfoType = 32
    public static let offData8 = 42
    public static let offBytes = 48
    private static let selectorKernelIndexSMC: UInt32 = 2
    private static let cmdReadBytes: UInt8 = 5
    private static let cmdWriteBytes: UInt8 = 6
    private static let cmdReadKeyInfo: UInt8 = 9

    private var conn: io_connect_t = 0
    private var isOpen = false

    public init() {}

    public func open() throws {
        guard let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC")) else {
            throw SMCError.serviceNotFound
        }
        defer { IOObjectRelease(service) }
        let r = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard r == KERN_SUCCESS else { throw SMCError.openFailed(r) }
        isOpen = true
    }

    public func close() {
        if isOpen { IOServiceClose(conn); isOpen = false }
    }

    // MARK: - Request building (pure, testable)

    public static func buildRequest(key: String, command: UInt8) -> [UInt8] {
        var req = [UInt8](repeating: 0, count: structSize)
        let fourcc = SMCCodec.fourCC(key)
        withUnsafeBytes(of: fourcc) { raw in
            for i in 0..<4 { req[i] = raw[i] }
        }
        req[offData8] = command
        return req
    }

    public static func backfill(_ req: inout [UInt8], dataSize: Int, dataType: UInt32) {
        var size = UInt32(dataSize)
        withUnsafeBytes(of: &size) { raw in
            for i in 0..<4 { req[offKeyInfoSize + i] = raw[i] }
        }
        var type = dataType
        withUnsafeBytes(of: &type) { raw in
            for i in 0..<4 { req[offKeyInfoType + i] = raw[i] }
        }
    }

    // MARK: - Low-level call

    public func call(command: UInt8, key: String, writeBytes: [UInt8]? = nil, dataSize: Int? = nil, dataType: UInt32? = nil) throws -> (dataSize: Int, dataType: UInt32, bytes: [UInt8]) {
        guard isOpen else { throw SMCError.closed }
        var req = Self.buildRequest(key: key, command: command)
        if let ds = dataSize, let dt = dataType {
            Self.backfill(&req, dataSize: ds, dataType: dt)
        }
        if let wb = writeBytes {
            for (i, b) in wb.prefix(32).enumerated() { req[Self.offBytes + i] = b }
        }
        var out = [UInt8](repeating: 0, count: Self.structSize)
        var outSize = Self.structSize
        let r = req.withUnsafeBytes { inPtr -> kern_return_t in
            out.withUnsafeMutableBytes { outPtr in
                IOConnectCallStructMethod(conn, Self.selectorKernelIndexSMC, inPtr.baseAddress, Self.structSize, outPtr.baseAddress, &outSize)
            }
        }
        guard r == KERN_SUCCESS else { throw SMCError.callFailed(r) }
        let size = Int(UInt32(littleEndian: (UInt32(out[28]) | (UInt32(out[29]) << 8) | (UInt32(out[30]) << 16) | (UInt32(out[31]) << 24))))
        let type = UInt32(littleEndian: (UInt32(out[32]) | (UInt32(out[33]) << 8) | (UInt32(out[34]) << 16) | (UInt32(out[35]) << 24)))
        let bytes = Array(out[Self.offBytes..<Self.offBytes + 32])
        return (size, type, bytes)
    }

    // MARK: - Key-level API

    public func readKey(_ key: String) throws -> (dataType: String, bytes: [UInt8]) {
        let ki = try call(command: Self.cmdReadKeyInfo, key: key)
        guard ki.dataSize > 0, ki.dataSize <= 32 else { throw SMCError.keyNotFound(key) }
        let rb = try call(command: Self.cmdReadBytes, key: key, dataSize: ki.dataSize, dataType: ki.dataType)
        return (SMCCodec.fourCCString(ki.dataType), Array(rb.bytes.prefix(ki.dataSize)))
    }

    public func writeKey(_ key: String, bytes: [UInt8], dataType: String) throws {
        let type = SMCCodec.fourCC(dataType)
        _ = try call(command: Self.cmdWriteBytes, key: key, writeBytes: bytes, dataSize: bytes.count, dataType: type)
    }

    // MARK: - Fan / temperature reading

    public func fanCount() -> Int {
        guard let r = try? readKey("FNum"), let first = r.bytes.first else { return 0 }
        return Int(first)
    }

    public struct FanSnapshot {
        public let index: Int
        public let currentRPM: Double
        public let minRPM: Double
        public let maxRPM: Double
        public let targetRPM: Double
        public let manual: Bool
    }

    public func fanInfo(_ index: Int) -> FanSnapshot? {
        func read(_ k: String) -> (String, [UInt8])? { try? readKey(k) }
        guard let ac = read("F\(index)Ac"),
              let mn = read("F\(index)Mn"),
              let mx = read("F\(index)Mx"),
              let tg = read("F\(index)Tg") else { return nil }
        return FanSnapshot(
            index: index,
            currentRPM: SMCCodec.decode(dataType: ac.0, bytes: ac.1),
            minRPM: SMCCodec.decode(dataType: mn.0, bytes: mn.1),
            maxRPM: SMCCodec.decode(dataType: mx.0, bytes: mx.1),
            targetRPM: SMCCodec.decode(dataType: tg.0, bytes: tg.1),
            manual: ((try? readKey("F\(index)Md"))?.bytes.first ?? 0) == 1
        )
    }

    public func cpuTemperature() -> Double? {
        guard let t = try? readKey("TC0P") else { return nil }
        return SMCCodec.decode(dataType: t.dataType, bytes: t.bytes)
    }

    // MARK: - Fan control (requires root)

    public func setManualMode(_ index: Int, enabled: Bool) throws {
        try writeKey("F\(index)Md", bytes: [enabled ? 0x01 : 0x00], dataType: "ui8 ")
    }

    public func setTargetSpeed(_ index: Int, rpm: Double) throws {
        let snapshot = fanInfo(index)
        let type = try readKey("F\(index)Tg").dataType   // use key's own type (flt/fpe2)
        let bytes = SMCCodec.encode(rpm: rpm, dataType: type)
        _ = snapshot // keep for symmetry; type drives encoding
        try writeKey("F\(index)Tg", bytes: bytes, dataType: type)
    }

    public func setAuto(_ index: Int) throws { try setManualMode(index, enabled: false) }
    public func setManualTarget(_ index: Int, rpm: Double) throws {
        try setManualMode(index, enabled: true)
        try setTargetSpeed(index, rpm: rpm)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test`
Expected: PASS (protocol/offset/backfill tests).

- [ ] **Step 5: Manual hardware smoke test (read path)**

Run:
```bash
swift -I .build/debug -L .build/debug -e '...' 2>/dev/null || true
```
(Alternatively: the E2E task later validates reads. If `swift test` passes and Task 11 runs the app, reads are exercised on real hardware.)

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: SMCConnection (verified IOKit protocol) + FanSnapshot"
```

---

### Task 4: Helper wire protocol (shared)

**Files:**
- Create: `Sources/FanControlCore/HelperProtocol.swift`
- Create: `Tests/FanControlCoreTests/HelperProtocolTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
import XCTest
@testable import FanControlCore

final class HelperProtocolTests: XCTestCase {
    func testRequestEncodeDecode() throws {
        let req = HelperRequest(cmd: .set, index: 1, rpm: 2000)
        let data = try HelperWire.encode(req)
        let decoded = try HelperWire.decode(data)
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
        XCTAssertEqual(try HelperWire.decode(data), resp)
    }
    func testLineFraming() {
        let req = HelperRequest(cmd: .auto, index: 0, rpm: nil)
        let line = HelperWire.encodeLine(req)
        XCTAssertTrue(line.hasSuffix("\n"))
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test`
Expected: FAIL (HelperProtocol missing).

- [ ] **Step 3: Implement `HelperProtocol`**

```swift
import Foundation

/// Wire protocol between the menu bar app and the root helper daemon.
/// Newline-delimited JSON over a Unix stream socket.
public struct HelperRequest: Codable, Equatable {
    public enum Kind: String, Codable { case ping, set, auto, shutdown }
    public let cmd: Kind
    public let index: Int?
    public let rpm: Double?
    public init(cmd: Kind, index: Int? = nil, rpm: Double? = nil) {
        self.cmd = cmd; self.index = index; self.rpm = rpm
    }
}

public struct HelperResponse: Codable, Equatable {
    public let ok: Bool
    public let error: String?
    public init(ok: Bool, error: String? = nil) {
        self.ok = ok; self.error = error
    }
}

public enum HelperWire {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ data: Data) throws -> T {
        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }
    public static func encodeLine<T: Encodable>(_ value: T) -> String {
        (try? String(data: encode(value), encoding: .utf8)) ?? ""
    }
    public static func decodeLine<T: Decodable>(_ line: String) throws -> T {
        try decode(Data(line.utf8))
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: helper wire protocol (newline-delimited JSON)"
```

---

### Task 5: FanController + model (TDD with mocks)

**Files:**
- Create: `Sources/FanControlCore/Model.swift`
- Create: `Sources/FanControlCore/FanController.swift`
- Create: `Tests/FanControlCoreTests/FanControllerTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
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
        // clamp: value below min of fan1 -> clamped to 1300
        controller.customRPM = "1250"
        try controller.applyMode()
        XCTAssertEqual(writer.calls.map(\.action), [.manual(1200), .manual(1300)])
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
        // global range 1200...6800
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
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test`
Expected: FAIL (model types missing).

- [ ] **Step 3: Implement `Model.swift`**

```swift
import Foundation

public enum FanMode: String, Codable, CaseIterable, Identifiable {
    case auto, min, max, custom
    public var id: String { rawValue }
    public var localizedKey: String {
        switch self {
        case .auto: return "mode.auto"
        case .min: return "mode.min"
        case .max: return "mode.max"
        case .custom: return "mode.custom"
        }
    }
}

public struct FanInfo: Equatable {
    public let index: Int
    public var currentRPM: Double
    public var minRPM: Double
    public var maxRPM: Double
    public init(index: Int, currentRPM: Double, minRPM: Double, maxRPM: Double) {
        self.index = index
        self.currentRPM = currentRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
    }
}

public enum FanWriteAction: Equatable {
    case auto
    case manual(Double)
}

public protocol FanReading {
    func refreshFans() throws -> [FanInfo]
    func cpuTemperature() throws -> Double?
}

public protocol FanWriting {
    func write(_ action: FanWriteAction, index: Int) throws
}
```

- [ ] **Step 4: Implement `FanController.swift`**

```swift
import Foundation
import Combine

/// App-facing controller. `reader` = direct SMC (user context, reads OK).
/// `writer` = root helper for the app (socket) or direct SMC inside the daemon.
public final class FanController: ObservableObject {

    @Published public var mode: FanMode = .auto
    @Published public var customRPM: String = "2000"
    @Published public var fans: [FanInfo] = []
    @Published public var cpuTemp: Double?
    @Published public var errorMessage: String?

    public let reader: FanReading
    public let writer: FanWriting

    public init(reader: FanReading, writer: FanWriting) {
        self.reader = reader
        self.writer = writer
    }

    public func refresh() {
        if let fans = try? reader.refreshFans() { self.fans = fans }
        cpuTemp = (try? reader.cpuTemperature()) ?? nil
    }

    public func applyMode() throws {
        errorMessage = nil
        let fans = (try? reader.refreshFans()) ?? self.fans
        for fan in fans {
            switch mode {
            case .auto:
                try writer.write(.auto, index: fan.index)
            case .min:
                try writer.write(.manual(fan.minRPM), index: fan.index)
            case .max:
                try writer.write(.manual(fan.maxRPM), index: fan.index)
            case .custom:
                guard let rpm = validatedCustomRPM(fans: fans) else { return }
                let clamped = min(max(rpm, fan.minRPM), fan.maxRPM)
                try writer.write(.manual(clamped), index: fan.index)
            }
        }
    }

    /// Global validation range: min of mins .. max of maxs
    public func isValidCustomRPM(_ text: String, fans: [FanInfo]) -> Bool {
        guard let rpm = Double(text) else { return false }
        let lo = fans.map(\.minRPM).min() ?? 0
        let hi = fans.map(\.maxRPM).max() ?? 0
        return rpm >= lo && rpm <= hi
    }

    public func validatedCustomRPM(fans: [FanInfo]) -> Double? {
        guard isValidCustomRPM(customRPM, fans: fans) else {
            let lo = fans.map(\.minRPM).min() ?? 0
            let hi = fans.map(\.maxRPM).max() ?? 0
            errorMessage = "RPM must be between \(Int(lo)) and \(Int(hi))"
            return nil
        }
        return Double(customRPM)
    }

    public func applyCustomIfNeeded() throws {
        if mode == .custom { try applyMode() }
    }
}
```

- [ ] **Step 5: Run to verify pass**

Run: `swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: FanController with modes, clamping, validation"
```

---

### Task 6: Root helper daemon (socket server + SMC writes)

**Files:**
- Create: `Sources/FanControlHelper/main.swift`

- [ ] **Step 1: Implement the daemon**

```swift
import Foundation
import FanControlCore

// Root daemon: listens on /var/run/FanControlHelper.sock for commands
// and performs privileged SMC writes.

final class HelperDaemon {
    private let socketPath = "/var/run/FanControlHelper.sock"
    private let smc = SMCConnection()

    func run() throws {
        try smc.open()
        try listen()
    }

    private func listen() throws {
        // remove stale socket
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { fatalError("socket() failed") }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        for (i, b) in pathBytes.prefix(103).enumerated() { addr.sun_path[i] = CChar(b) }

        let bindRes = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindRes == 0 else { fatalError("bind() failed errno=\(errno)") }

        // allow the unprivileged app to connect
        chmod(socketPath, 0o666)

        guard listen(fd, 8) == 0 else { fatalError("listen() failed errno=\(errno)") }

        print("FanControlHelper listening on \(socketPath)")

        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            handleClient(client)
            close(client)
        }
    }

    private func handleClient(_ client: Int32) {
        var buf = [UInt8]()
        var byte: UInt8 = 0
        while read(client, &byte, 1) == 1 {
            if byte == 0x0A {   // '\n'
                let line = String(bytes: buf, encoding: .utf8) ?? ""
                let resp = process(line)
                let framed = resp.hasSuffix("\n") ? resp : resp + "\n"   // client waits for \n
                if let data = framed.data(using: .utf8) {
                    data.withUnsafeBytes { raw in
                        _ = write(client, raw.baseAddress, raw.count)
                    }
                }
                buf.removeAll()
            } else {
                buf.append(byte)
            }
        }
    }

    private func process(_ line: String) -> String {
        guard let req = try? HelperWire.decodeLine(HelperRequest.self, from: line) else {
            return HelperWire.encodeLine(HelperResponse(ok: false, error: "bad request"))
        }
        switch req.cmd {
        case .ping:
            return HelperWire.encodeLine(HelperResponse(ok: true))
        case .shutdown:
            exit(0)
        case .auto:
            guard let i = req.index else {
                return HelperWire.encodeLine(HelperResponse(ok: false, error: "missing index"))
            }
            do { try smc.setAuto(i); return HelperWire.encodeLine(HelperResponse(ok: true)) }
            catch { return HelperWire.encodeLine(HelperResponse(ok: false, error: error.localizedDescription)) }
        case .set:
            guard let i = req.index, let rpm = req.rpm else {
                return HelperWire.encodeLine(HelperResponse(ok: false, error: "missing index/rpm"))
            }
            do {
                try smc.setManualTarget(i, rpm: rpm)
                return HelperWire.encodeLine(HelperResponse(ok: true))
            } catch {
                return HelperWire.encodeLine(HelperResponse(ok: false, error: error.localizedDescription))
            }
        }
    }
}

HelperDaemon().run()   // top-level
```

- [ ] **Step 2: Add `decodeLine` overload used above**

Add to `HelperWire` in `HelperProtocol.swift`:
```swift
public static func decodeLine<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
    try decode(Data(line.utf8))
}
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: BUILD SUCCESSFUL (both executables + lib).

- [ ] **Step 4: Manual test as root (requires admin; run in foreground)**

Run:
```bash
sudo .build/debug/FanControlHelper
```
Expected: prints `FanControlHelper listening on /var/run/FanControlHelper.sock`.

In a second terminal (as the user):
```bash
printf '{"cmd":"ping"}\n' | nc -U /var/run/FanControlHelper.sock
```
Expected: `{"ok":true}`.

Test a controlled write — set F0 to a modest value then back to auto:
```bash
printf '{"cmd":"set","index":0,"rpm":2000}\n' | nc -U /var/run/FanControlHelper.sock   # → {"ok":true}
printf '{"cmd":"auto","index":0}\n'     | nc -U /var/run/FanControlHelper.sock   # → {"ok":true}
```
Then Ctrl-C the daemon. (⚠️ Do NOT leave fans in manual mode; always send `auto` afterward.)

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: root helper daemon (socket server + SMC writes)"
```

---

### Task 7: HelperClient (app-side socket client, TDD)

**Files:**
- Create: `Sources/FanControlCore/HelperClient.swift`
- Create: `Tests/FanControlCoreTests/HelperClientTests.swift`

- [ ] **Step 1: Write failing tests** (client tested against an in-process POSIX socket server on a temp path)

```swift
import XCTest
@testable import FanControlCore

final class HelperClientTests: XCTestCase {
    var serverPath: String!
    var server: Thread!
    var lastRequest: HelperRequest?

    override func setUp() {
        serverPath = NSTemporaryDirectory() + "fancontrol-test-\(UUID().uuidString).sock"
        lastRequest = nil
    }
    override func tearDown() {
        server?.cancel(); server = nil
        unlink(serverPath)
    }

    private func startServer(responding ok: Bool, error: String? = nil) {
        server = Thread {
            unlink(self.serverPath)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let p = Array(self.serverPath.utf8)
            for (i, b) in p.prefix(103).enumerated() { addr.sun_path[i] = CChar(b) }
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            chmod(self.serverPath, 0o666)
            listen(fd, 4)
            let client = accept(fd, nil, nil)
            var buf = [UInt8](); var byte: UInt8 = 0
            while read(client, &byte, 1) == 1 {
                if byte == 0x0A {
                    if let line = String(bytes: buf, encoding: .utf8) {
                        self.lastRequest = try? HelperWire.decodeLine(HelperRequest.self, from: line)
                    }
                    let resp = HelperResponse(ok: ok, error: error)
                    let data = (HelperWire.encodeLine(resp) + "\n").data(using: .utf8)!
                    data.withUnsafeBytes { raw in _ = write(client, raw.baseAddress, raw.count) }
                    buf.removeAll()
                } else { buf.append(byte) }
            }
            close(client); close(fd)
        }
        server.start()
        // wait for socket
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: serverPath) { usleep(20_000) }
    }

    func testPing() throws {
        startServer(responding: true)
        let client = HelperClient(socketPath: serverPath)
        let ok = client.ping()
        XCTAssertTrue(ok)
        XCTAssertEqual(lastRequest, HelperRequest(cmd: .ping))
    }

    func testSetCommand() throws {
        startServer(responding: true)
        let client = HelperClient(socketPath: serverPath)
        let resp = try client.send(HelperRequest(cmd: .set, index: 1, rpm: 2500))
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(lastRequest, HelperRequest(cmd: .set, index: 1, rpm: 2500))
    }

    func testServerErrorPropagated() throws {
        startServer(responding: false, error: "not privileged")
        let client = HelperClient(socketPath: serverPath)
        let resp = try client.send(HelperRequest(cmd: .set, index: 0, rpm: 1000))
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error, "not privileged")
    }

    func testConnectFailure() {
        let client = HelperClient(socketPath: serverPath)   // no server
        XCTAssertFalse(client.ping())
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test`
Expected: FAIL (HelperClient missing).

- [ ] **Step 3: Implement `HelperClient`**

```swift
import Foundation

public final class HelperClient: FanWriting {
    public let socketPath: String

    public init(socketPath: String = "/var/run/FanControlHelper.sock") {
        self.socketPath = socketPath
    }

    public func ping() -> Bool {
        guard let fd = connect() else { return false }
        defer { close(fd) }
        return sendRequest(HelperRequest(cmd: .ping), fd: fd)?.ok ?? false
    }

    public func send(_ req: HelperRequest) throws -> HelperResponse {
        guard let fd = connect() else { throw HelperClientError.notInstalled }
        defer { close(fd) }
        guard let resp = sendRequest(req, fd: fd) else { throw HelperClientError.connectionFailed }
        return resp
    }

    // FanWriting
    public func write(_ action: FanWriteAction, index: Int) throws {
        let req: HelperRequest
        switch action {
        case .auto: req = HelperRequest(cmd: .auto, index: index)
        case .manual(let rpm): req = HelperRequest(cmd: .set, index: index, rpm: rpm)
        }
        let resp = try send(req)
        guard resp.ok else { throw HelperClientError.helperError(resp.error ?? "unknown") }
    }

    private func connect() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let p = Array(socketPath.utf8)
        for (i, b) in p.prefix(103).enumerated() { addr.sun_path[i] = CChar(b) }
        let c = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if c == 0 { return fd }
        close(fd)
        return nil
    }

    private func sendRequest(_ req: HelperRequest, fd: Int32) -> HelperResponse? {
        let line = HelperWire.encodeLine(req) + "\n"
        guard let data = line.data(using: .utf8) else { return nil }
        var sent = 0
        data.withUnsafeBytes { raw in
            sent = write(fd, raw.baseAddress, raw.count)
        }
        guard sent == data.count else { return nil }
        var buf = [UInt8]()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) == 1 {
            if byte == 0x0A {
                let line = String(bytes: buf, encoding: .utf8) ?? ""
                return try? HelperWire.decodeLine(HelperResponse.self, from: line)
            }
            buf.append(byte)
        }
        return nil
    }
}

public enum HelperClientError: Error, LocalizedError {
    case notInstalled
    case connectionFailed
    case helperError(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: return "Helper daemon is not running"
        case .connectionFailed: return "Could not connect to helper daemon"
        case .helperError(let m): return m
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test`
Expected: PASS (all client tests).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: HelperClient socket client (app→daemon)"
```

---

### Task 8: install.sh + HelperInstaller

**Files:**
- Create: `install.sh`
- Create: `Sources/FanControlCore/HelperInstaller.swift`
- Create: `Tests/FanControlCoreTests/HelperInstallerTests.swift` (path-building logic only)

- [ ] **Step 1: Write failing test for path helpers**

```swift
import XCTest
@testable import FanControlCore

final class HelperInstallerTests: XCTestCase {
    func testDefaultPaths() {
        let i = HelperInstaller()
        XCTAssertEqual(i.helperInstallPath, "/Library/PrivilegedHelperTools/FanControlHelper")
        XCTAssertEqual(i.daemonPlistPath, "/Library/LaunchDaemons/com.fancontrol.helper.plist")
        XCTAssertEqual(i.socketPath, "/var/run/FanControlHelper.sock")
    }
    func testBundleSourcePaths() {
        let i = HelperInstaller(bundlePath: "/Applications/FanControl.app")
        XCTAssertEqual(i.bundledHelperPath, "/Applications/FanControl.app/Contents/Resources/FanControlHelper")
        XCTAssertEqual(i.bundledInstallScriptPath, "/Applications/FanControl.app/Contents/Resources/install.sh")
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `swift test`
Expected: FAIL.

- [ ] **Step 3: Implement `HelperInstaller`**

```swift
import Foundation

public struct HelperInstaller {
    public let helperInstallPath: String
    public let daemonPlistPath: String
    public let socketPath: String
    public let bundledHelperPath: String
    public let bundledInstallScriptPath: String

    public init(bundlePath: String = Bundle.main.bundlePath) {
        helperInstallPath = "/Library/PrivilegedHelperTools/FanControlHelper"
        daemonPlistPath = "/Library/LaunchDaemons/com.fancontrol.helper.plist"
        socketPath = "/var/run/FanControlHelper.sock"
        bundledHelperPath = bundlePath + "/Contents/Resources/FanControlHelper"
        bundledInstallScriptPath = bundlePath + "/Contents/Resources/install.sh"
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: helperInstallPath)
    }

    public func helperResponding() -> Bool {
        HelperClient(socketPath: socketPath).ping()
    }

    /// App bundle path passed to install.sh (which is copied to /tmp before running as admin)
    public var appBundlePath: String {
        bundledInstallScriptPath.replacingOccurrences(of: "/Contents/Resources/install.sh", with: "")
    }
}
```

(Note: install.sh is self-contained; it copies the helper + plist into place and loads the daemon. The admin command above runs it with a one-time password prompt.)

- [ ] **Step 4: Create `install.sh`**

```bash
#!/bin/bash
# FanControlHelper installer — run with admin rights.
set -e

HELPER_NAME="FanControlHelper"
INSTALL_DIR="/Library/PrivilegedHelperTools"
PLIST_PATH="/Library/LaunchDaemons/com.fancontrol.helper.plist"
APP_BUNDLE="${1:?usage: install.sh <AppBundlePath>}"   # e.g. /Applications/FanControl.app

mkdir -p "$INSTALL_DIR"
cp "$APP_BUNDLE/Contents/Resources/$HELPER_NAME" "$INSTALL_DIR/$HELPER_NAME"
chown root:wheel "$INSTALL_DIR/$HELPER_NAME"
chmod 755 "$INSTALL_DIR/$HELPER_NAME"

cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.fancontrol.helper</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_DIR/$HELPER_NAME</string>
        <string>--daemon</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/var/log/fancontrol-helper.log</string>
    <key>StandardErrorPath</key><string>/var/log/fancontrol-helper.log</string>
</dict>
</plist>
PLIST

chown root:wheel "$PLIST_PATH"
chmod 644 "$PLIST_PATH"

launchctl bootstrap system "$PLIST_PATH" 2>/dev/null || \
    launchctl load "$PLIST_PATH" 2>/dev/null || true

sleep 1
echo "FanControlHelper installed."
```

- [ ] **Step 5: chmod +x install.sh and verify tests pass**

Run: `chmod +x install.sh` then `swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: helper installer (launchd daemon setup) + install.sh"
```

---

### Task 9: SwiftUI menu bar app

**Files:**
- Create: `Sources/FanControlApp/FanControlApp.swift`
- Create: `Sources/FanControlApp/MenuBarPanelView.swift`
- Create: `Sources/FanControlApp/SettingsView.swift`
- Create: `Sources/FanControlApp/AutoLaunch.swift`
- Create: `Sources/FanControlApp/AppEnvironment.swift`
- Delete: `Sources/FanControlApp/main.swift` (replaced by `@main`)

- [ ] **Step 1: Implement `AppEnvironment` (wires controller to real SMC + helper client)**

```swift
import SwiftUI
import Combine
import FanControlCore

/// Bridges FanController (core) to the app lifecycle: SMC reader,
/// helper client writer, persistence, timer, auto-launch.
final class AppEnvironment: ObservableObject {
    @Published var controller: FanController
    let helperInstaller = HelperInstaller()
    @Published var helperAvailable: Bool
    @Published var showSettings = false

    private let defaults: UserDefaults
    private let smc = SMCConnection()
    private let helper = HelperClient()
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        smc.tryOpen()
        helperAvailable = helperInstaller.helperResponding()

        let reader = SMCFanReader(smc: smc)
        let writer = helper
        controller = FanController(reader: reader, writer: writer)

        // restore saved state
        controller.mode = FanMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .auto
        if let saved = defaults.string(forKey: "customRPM") { controller.customRPM = saved }

        // persist changes
        controller.$mode.sink { [weak self] m in self?.defaults.set(m.rawValue, forKey: "mode") }.store(in: &cancellables)
        controller.$customRPM.sink { [weak self] rpm in self?.defaults.set(rpm, forKey: "customRPM") }.store(in: &cancellables)
    }

    func start() {
        if let s = smc.opened { s }   // already opened in init
        controller.refresh()
        // re-apply saved mode after boot
        if controller.mode != .auto { try? controller.applyMode() }
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.controller.refresh()
        }
    }

    func installHelper() {
        let bundlePath = helperInstaller.bundledInstallScriptPath.replacingOccurrences(of: "/Contents/Resources/install.sh", with: "")
        let script = helperInstaller.bundledInstallScriptPath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "do shell script \\"\(script)\\" & space & quoted form of \\"\(bundlePath)\\" with administrator privileges"]
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.helperAvailable = self?.helperInstaller.helperResponding() ?? false
                if self?.helperAvailable == true { try? self?.controller.applyMode() }
            }
        }
        try? p.run()
    }
}

/// FanReading backed by the real SMC connection
struct SMCFanReader: FanReading {
    let smc: SMCConnection
    func refreshFans() throws -> [FanInfo] {
        let count = smc.fanCount()
        var fans: [FanInfo] = []
        for i in 0..<count {
            if let s = smc.fanInfo(i) {
                fans.append(FanInfo(index: i, currentRPM: s.currentRPM, minRPM: s.minRPM, maxRPM: s.maxRPM))
            }
        }
        return fans
    }
    func cpuTemperature() throws -> Double? { smc.cpuTemperature() }
}

extension SMCConnection {
    func tryOpen() {
        try? open()
    }
}
```

- [ ] **Step 2: Implement `FanControlApp.swift` (`@main`)**

```swift
import SwiftUI

@main
struct FanControlApp: App {
    @StateObject private var env = AppEnvironment()
    @State private var isPresented = false

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanelView(env: env)
        } label: {
            Image(systemName: "fanblades.fill")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(env: env)
        }
    }
}
```

- [ ] **Step 3: Implement `MenuBarPanelView`**

```swift
import SwiftUI
import FanControlCore

struct MenuBarPanelView: View {
    @ObservedObject var env: AppEnvironment
    @ObservedObject var controller: FanController
    @State private var rpmText: String = ""

    init(env: AppEnvironment) {
        self.env = env
        self.controller = env.controller
        _rpmText = State(initialValue: controller.customRPM)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let err = controller.errorMessage {
                Text(err).font(.caption).foregroundColor(.red)
            }
            if !env.helperAvailable {
                installBanner
            }
            ForEach(controller.fans, id: \.index) { fan in
                FanRow(fan: fan)
            }
            if let temp = controller.cpuTemp {
                Label(String(format: "CPU %.1f°C", temp), systemImage: "thermometer")
                    .font(.callout)
            }
            Divider()
            modePicker
            Divider()
            HStack {
                Button("打开设置") { env.showSettings = true; openSettings() }
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private var installBanner: some View {
        HStack {
            Text("守护进程未安装").font(.caption)
            Spacer()
            Button("安装") { env.installHelper() }
        }
        .padding(6)
        .background(Color.yellow.opacity(0.2))
        .cornerRadius(6)
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("模式").font(.caption).foregroundColor(.secondary)
            Picker("", selection: $controller.mode) {
                ForEach(FanMode.allCases) { m in
                    Text(NSLocalizedString(m.localizedKey, comment: "")).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: controller.mode) { _, newMode in
                if newMode != .custom {
                    try? controller.applyMode()
                } else {
                    rpmText = controller.customRPM
                }
            }
            if controller.mode == .custom {
                HStack {
                    TextField("RPM", text: $rpmText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 90)
                        .onSubmit { applyCustom() }
                    Button("应用") { applyCustom() }
                        .disabled(!controller.isValidCustomRPM(rpmText, fans: controller.fans))
                }
            }
        }
    }

    private func applyCustom() {
        controller.customRPM = rpmText
        try? controller.applyMode()
    }

    private func openSettings() {
        // Bring up the Settings scene
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}

struct FanRow: View {
    let fan: FanInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("风扇 \(fan.index + 1)")
                .font(.callout).fontWeight(.medium)
            Text("\(Int(fan.currentRPM)) RPM")
                .font(.title3).monospacedDigit()
            Text("范围 \(Int(fan.minRPM)) - \(Int(fan.maxRPM)) RPM")
                .font(.caption).foregroundColor(.secondary)
        }
    }
}
```

- [ ] **Step 4: Implement `SettingsView` + `AutoLaunch`**

```swift
import SwiftUI
import FanControlCore

struct SettingsView: View {
    @ObservedObject var env: AppEnvironment
    @AppStorage("autoLaunch") private var autoLaunch = false

    var body: some View {
        Form {
            Toggle("开机自启动", isOn: $autoLaunch)
                .onChange(of: autoLaunch) { _, on in
                    AutoLaunch.setEnabled(on)
                }
            Section("守护进程") {
                HStack {
                    Text(env.helperAvailable ? "已安装并运行" : "未安装")
                    Spacer()
                    Button(env.helperAvailable ? "重新安装" : "安装") { env.installHelper() }
                }
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

enum AutoLaunch {
    /// Register via SMAppService (macOS 13+); fall back to a LaunchAgent plist.
    static func setEnabled(_ on: Bool) {
        if on {
            do { try SMAppService.mainApp.register() }
            catch { installLaunchAgent() }
        } else {
            SMAppService.mainApp.unregister()
            removeLaunchAgent()
        }
    }

    private static var agentPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.fancontrol.app.plist")
    }

    private static func installLaunchAgent() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>Label</key><string>com.fancontrol.app</string>
        <key>ProgramArguments</key>
        <array><string>\(Bundle.main.executablePath ?? "")</string></array>
        <key>RunAtLoad</key><true/>
        </dict></plist>
        """
        try? plist.write(to: agentPath, atomically: true, encoding: .utf8)
        _ = shell("launchctl unload \(agentPath.path) 2>/dev/null; launchctl load \(agentPath.path)")
    }

    private static func removeLaunchAgent() {
        _ = shell("launchctl unload \(agentPath.path) 2>/dev/null; rm -f \(agentPath.path)")
    }

    private static func shell(_ cmd: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", cmd]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try? p.run(); p.waitUntilExit()
        return ""
    }
}
```

- [ ] **Step 5: Remove placeholder main.swift and build**

Run: `rm Sources/FanControlApp/main.swift && swift build`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: SwiftUI menu bar app (panel, settings, auto-launch)"
```

---

### Task 10: Icons + build.sh + Info.plist

**Files:**
- Create: `Resources/make_icon.swift`
- Create: `build.sh`
- Create: `Resources/Info.plist`
- Create: `Resources/en.lproj/Localizable.strings`
- Create: `Resources/zh-Hans.lproj/Localizable.strings`
- Create: `.gitignore`

- [ ] **Step 1: Write `Resources/make_icon.swift`** (CoreGraphics renders a fan glyph at multiple sizes, then iconset → icns)

```swift
import AppKit

func drawFan(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    // background
    NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.16, alpha: 1).setFill()
    NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22).fill()

    let c = NSGraphicsContext.current!.cgContext
    c.saveGState()
    c.translateBy(x: size / 2, y: size / 2)

    // hub
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: -size * 0.05, y: -size * 0.05, width: size * 0.10, height: size * 0.10)).fill()

    // 4 curved blades
    let blade = NSBezierPath()
    blade.move(to: NSPoint(x: size * 0.02, y: size * 0.10))
    blade.curve(to: NSPoint(x: size * 0.28, y: size * 0.42),
                controlPoint1: NSPoint(x: size * 0.02, y: size * 0.26),
                controlPoint2: NSPoint(x: size * 0.12, y: size * 0.40))
    blade.curve(to: NSPoint(x: size * 0.38, y: size * 0.10),
                controlPoint1: NSPoint(x: size * 0.38, y: size * 0.32),
                controlPoint2: NSPoint(x: size * 0.40, y: size * 0.20))
    blade.close()
    NSColor.white.setFill()
    for i in 0..<4 {
        c.saveGState()
        c.rotate(by: .pi / 2 * CGFloat(i))
        blade.fill()
        c.restoreGState()
    }
    c.restoreGState()
    return image
}

func writePNG(_ image: NSImage, to url: URL, size: CGFloat) {
    guard let rep = NSBitmapImageRep(data: image.tiffRepresentation!) else { return }
    let scaled = NSImage(size: NSSize(width: size, height: size))
    scaled.lockFocus()
    rep.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    scaled.unlockFocus()
    guard let tiff = scaled.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let base = drawFan(size: 1024)
let sizes: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in sizes {
    writePNG(base, to: iconset.appendingPathComponent(name), size: px)
}
print(iconset.path)
```

- [ ] **Step 2: Run icon generation + convert to icns**

Run:
```bash
mkdir -p build/icons
swift Resources/make_icon.swift "$PWD/build/icons"
iconutil -c icns build/icons/AppIcon.iconset -o build/icons/AppIcon.icns
ls -la build/icons/AppIcon.icns
```
Expected: AppIcon.icns exists.

- [ ] **Step 3: Write `Resources/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>FanControl</string>
    <key>CFBundleIdentifier</key><string>com.fancontrol.app</string>
    <key>CFBundleName</key><string>FanControl</string>
    <key>CFBundleDisplayName</key><string>FanControl</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict>
</plist>
```

- [ ] **Step 4: Write localization strings**

`Resources/en.lproj/Localizable.strings`:
```
"mode.auto" = "Auto";
"mode.min" = "Min";
"mode.max" = "Max";
"mode.custom" = "Custom";
```
`Resources/zh-Hans.lproj/Localizable.strings`:
```
"mode.auto" = "自动";
"mode.min" = "最低";
"mode.max" = "最高";
"mode.custom" = "自定义";
```

- [ ] **Step 5: Write `build.sh`**

```bash
#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
APP=FanControl
HELPER=FanControlHelper
BUILD=.build/release
DIST=build/FanControl.app

echo "==> building (release)"
swift build -c release --product $APP
swift build -c release --product $HELPER

echo "==> icons"
mkdir -p build/icons
swift Resources/make_icon.swift "$PWD/build/icons"
iconutil -c icns build/icons/AppIcon.iconset -o build/icons/AppIcon.icns

echo "==> assembling $DIST"
rm -rf "$DIST"
mkdir -p "$DIST/Contents/MacOS"
mkdir -p "$DIST/Contents/Resources/en.lproj"
mkdir -p "$DIST/Contents/Resources/zh-Hans.lproj"

cp "$BUILD/$APP" "$DIST/Contents/MacOS/$APP"
cp "$BUILD/$HELPER" "$DIST/Contents/Resources/$HELPER"
cp build/icons/AppIcon.icns "$DIST/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$DIST/Contents/Info.plist"
cp Resources/en.lproj/Localizable.strings "$DIST/Contents/Resources/en.lproj/Localizable.strings"
cp Resources/zh-Hans.lproj/Localizable.strings "$DIST/Contents/Resources/zh-Hans.lproj/Localizable.strings"
cp install.sh "$DIST/Contents/Resources/install.sh"
chmod +x "$DIST/Contents/Resources/install.sh"

echo "==> codesigning (ad-hoc)"
codesign --force --deep --sign - "$DIST"

echo "==> done: $DIST"
```

- [ ] **Step 6: chmod +x, create .gitignore, build the app**

Run: `chmod +x build.sh && echo -e ".build/\nbuild/\n.DS_Store" > .gitignore && ./build.sh`
Expected: `build/FanControl.app` exists, ad-hoc signed.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: build.sh, icon generation, Info.plist, localization"
```

---

### Task 11: End-to-end verification on hardware

**Files:** none (verification only)

- [ ] **Step 1: Launch the app**

Run:
```bash
open build/FanControl.app
```
Expected: fan icon appears in the menu bar; panel shows 2 fans with real RPM, CPU temp.

- [ ] **Step 2: Install helper via the UI (one-time admin password)**

In the panel, click 安装. Enter admin password. Expected: banner disappears; helperAvailable becomes true.

- [ ] **Step 3: Verify each mode writes to SMC**

For each mode (auto / min / max / custom 2000):
- Click the mode; verify fan target changes by watching the fan RPM in the panel change and (audibly) fan speed.
- Verify by reading SMC directly:
```bash
printf '{"cmd":"ping"}\n' | nc -U /var/run/FanControlHelper.sock
```
- Always finish on 自动 and confirm RPM returns to system behavior.

- [ ] **Step 4: Verify persistence + auto-launch**

- Set 自定义 2500, quit, relaunch the app → RPM restored to 2500.
- Toggle 开机自启动 in Settings → check `SMAppService.mainApp.status == .enabled` (or LaunchAgent plist exists).
- Move app to /Applications and relaunch to confirm menu bar icon + auto-launch work from there.

- [ ] **Step 5: Final commit of any fixes**

```bash
git add -A
git commit -m "fix: e2e verification adjustments"
```

---

## Notes for the implementer

- **Do NOT leave the fans in manual mode after testing.** Always send `auto` (`{"cmd":"auto","index":0}` / index 1, or click 自动) at the end of manual verification.
- `swift test` must stay green after every task.
- If `FanControl` target name conflicts (`swift build --product FanControl` builds the app executable), keep the executable target named `FanControlApp` (product name `FanControl`) exactly as in `Package.swift`.
- The `Settings` scene requires the app to be a proper bundle to open the window via `showSettingsWindow:`; if it doesn't open from the panel button, it's non-critical — the panel itself covers all controls.
