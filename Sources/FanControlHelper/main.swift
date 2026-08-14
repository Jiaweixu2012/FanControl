import Foundation
import FanControlCore

// Root daemon: listens on /var/run/FanControlHelper.sock for commands
// and performs privileged SMC writes.

final class HelperDaemon {
    private let socketPath: String
    private let smc = SMCConnection()

    init(socketPath: String = "/var/run/FanControlHelper.sock") {
        self.socketPath = socketPath
    }

    func run() throws {
        try smc.open()
        try serve()
    }

    private func serve() throws {
        // remove stale socket
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { fatalError("socket() failed errno=\(errno)") }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: Array(socketPath.utf8))
        }

        let bindRes = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindRes == 0 else { fatalError("bind() failed errno=\(errno)") }

        // allow the unprivileged app to connect
        chmod(socketPath, 0o666)

        guard Darwin.listen(fd, 8) == 0 else { fatalError("listen() failed errno=\(errno)") }

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
                let resp = process(line)   // already ends with '\n'
                if let data = resp.data(using: .utf8) {
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

// Parse args: --socket <path> overrides default (mainly for testing)
var socketPath = "/var/run/FanControlHelper.sock"
let args = CommandLine.arguments
if let idx = args.firstIndex(of: "--socket"), args.indices.contains(idx + 1) {
    socketPath = args[idx + 1]
}

try HelperDaemon(socketPath: socketPath).run()
