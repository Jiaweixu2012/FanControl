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
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
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
        let type = try readKey("F\(index)Tg").dataType   // use key's own type (flt/fpe2)
        let bytes = SMCCodec.encode(rpm: rpm, dataType: type)
        try writeKey("F\(index)Tg", bytes: bytes, dataType: type)
    }

    public func setAuto(_ index: Int) throws { try setManualMode(index, enabled: false) }
    public func setManualTarget(_ index: Int, rpm: Double) throws {
        try setManualMode(index, enabled: true)
        try setTargetSpeed(index, rpm: rpm)
    }
}
