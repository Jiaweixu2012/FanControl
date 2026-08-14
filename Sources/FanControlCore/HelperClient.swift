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
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: Array(socketPath.utf8).prefix(103))
        }
        let c = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if c == 0 { return fd }
        close(fd)
        return nil
    }

    private func sendRequest(_ req: HelperRequest, fd: Int32) -> HelperResponse? {
        let line = HelperWire.encodeLine(req)
        guard let data = line.data(using: .utf8) else { return nil }
        var sent = 0
        data.withUnsafeBytes { raw in
            sent = Darwin.write(fd, raw.baseAddress, raw.count)
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
