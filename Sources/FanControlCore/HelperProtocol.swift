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
        try JSONEncoder().encode(value)
    }
    public static func decode<T: Decodable>(_ data: Data) throws -> T {
        try JSONDecoder().decode(T.self, from: data)
    }
    public static func encodeLine<T: Encodable>(_ value: T) -> String {
        ((try? String(data: encode(value), encoding: .utf8)) ?? "") + "\n"
    }
    public static func decodeLine<T: Decodable>(_ line: String) throws -> T {
        try decode(Data(line.utf8))
    }
    public static func decodeLine<T: Decodable>(_ type: T.Type, from line: String) throws -> T {
        try decode(Data(line.utf8))
    }
}
