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
            s.append(String(UnicodeScalar(byte)!))
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
