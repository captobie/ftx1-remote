import Darwin
import Foundation
import XCTest
@testable import FTX1Core

final class RigctldClientTests: XCTestCase {
    func testQueryParsesLinesAcrossPartialChunks() async throws {
        let server = try FakeRigctldServer.start()
        defer { server.stop() }

        let client = RigctldClient(host: "127.0.0.1", port: server.port)
        try await client.connect()

        // rigctld runs with -o in the real app (see RigctldProcessController),
        // which requires every command to carry an explicit VFO argument —
        // "currVFO" is what RigctldClient sends for the active-VFO calls.
        server.respond(to: "f currVFO", with: ["14074000"])
        let frequency = try await client.getFrequency()
        XCTAssertEqual(frequency, 14_074_000)

        server.respond(to: "m currVFO", with: ["USB", "2400"])
        let mode = try await client.getMode()
        XCTAssertEqual(mode.mode, "USB")
        XCTAssertEqual(mode.passband, 2400)

        server.respond(to: "t currVFO", with: ["1"])
        let ptt = try await client.getPTT()
        XCTAssertTrue(ptt)

        server.respond(to: "l currVFO SWR", with: ["1.20"])
        let swr = try await client.getLevel("SWR")
        XCTAssertEqual(swr, 1.20)

        // Unsupported level: rigctld replies with an RPRT error line, not
        // a number — getLevel should return nil rather than throw.
        server.respond(to: "l currVFO RFPOWER_METER_WATTS", with: ["RPRT -11"])
        let power = try await client.getLevel("RFPOWER_METER_WATTS")
        XCTAssertNil(power)

        await client.disconnect()
    }
}

/// Minimal stand-in for rigctld, built on raw POSIX sockets (not
/// Network.framework's `NWListener`) so it can run in restricted
/// sandboxes where `NWListener` isn't permitted to bind. `RigctldClient`
/// itself uses `NWConnection` (an outgoing client connection, not a
/// listener), which those same sandboxes do permit.
private final class FakeRigctldServer: @unchecked Sendable {
    private let socketFD: Int32
    let port: UInt16

    private let lock = NSLock()
    private var scripts: [String: [String]] = [:]
    private var clientFD: Int32 = -1
    private var acceptThread: Thread?

    private init(socketFD: Int32, port: UInt16) {
        self.socketFD = socketFD
        self.port = port
    }

    static func start() throws -> FakeRigctldServer {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FakeServerError.socketSetupFailed }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0 // ask the OS for an ephemeral port

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw FakeServerError.socketSetupFailed }
        guard listen(fd, 1) == 0 else { throw FakeServerError.socketSetupFailed }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getNameResult = withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard getNameResult == 0 else { throw FakeServerError.socketSetupFailed }

        let server = FakeRigctldServer(socketFD: fd, port: UInt16(bigEndian: boundAddr.sin_port))
        server.acceptLoop()
        return server
    }

    private func acceptLoop() {
        let thread = Thread { [weak self] in
            guard let self else { return }
            let fd = accept(self.socketFD, nil, nil)
            guard fd >= 0 else { return }
            self.clientFD = fd
            self.readLoop(fd: fd)
        }
        thread.start()
        acceptThread = thread
    }

    private func readLoop(fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while true {
            let bytesRead = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard bytesRead > 0 else { break }
            buffer.append(contentsOf: chunk[0..<bytesRead])
            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                let line = String(data: lineData, encoding: .utf8) ?? ""
                buffer.removeSubrange(buffer.startIndex...newlineIndex)
                respond(to: line, fd: fd)
            }
        }
    }

    private func respond(to command: String, fd: Int32) {
        lock.lock()
        let lines = scripts[command] ?? ["RPRT -1"]
        lock.unlock()
        for line in lines {
            let bytes = Array((line + "\n").utf8)
            _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        }
    }

    func respond(to command: String, with lines: [String]) {
        lock.lock()
        scripts[command] = lines
        lock.unlock()
    }

    func stop() {
        close(socketFD)
        if clientFD >= 0 { close(clientFD) }
    }
}

private enum FakeServerError: Error {
    case socketSetupFailed
}
