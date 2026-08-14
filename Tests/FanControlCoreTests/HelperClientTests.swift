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
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                raw.copyBytes(from: Array(self.serverPath.utf8).prefix(103))
            }
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            chmod(self.serverPath, 0o666)
            Darwin.listen(fd, 4)
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
