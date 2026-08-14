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

    /// Regression test for a real hardware bug: `sendRawCommand`'s reply
    /// isn't always `\n`-terminated. hamlib's `send_cmd` (tests/
    /// rigctl_parse.c) counts `;` occurrences in the outgoing command to
    /// decide the reply's trailing byte — since our own raw commands are
    /// themselves `;`-terminated (required for Yaesu/Kenwood backends,
    /// which disable hamlib's automatic terminator append), that count
    /// comes out as 2 for what's really a single command, producing a
    /// `\0`-terminated reply instead of `\n`. Confirmed against a real
    /// local `rigctld -m 1` before writing this fake-server version.
    func testRawBoolHandlesNulTerminatedReply() async throws {
        let server = try FakeRigctldServer.start()
        defer { server.stop() }

        let client = RigctldClient(host: "127.0.0.1", port: server.port)
        try await client.connect()

        server.respondRaw(to: "W BI; ;", bytes: Array("BI1;\0".utf8))
        let breakIn = try await client.getRawBool("BI")
        XCTAssertEqual(breakIn, true)

        server.respondRaw(to: "W KR0; ;", bytes: Array("KR0;\0".utf8))
        try await client.setRawBool("KR", false)

        await client.disconnect()
    }

    /// `getMenuItem`/`setMenuItem` are the generic "EX" (MENU) passthrough
    /// behind Deep Settings (see `DeepSettingsCatalog`) — one mechanism
    /// addressing all ~300 Table 3 items via P1/P2/P3, instead of one
    /// dedicated mnemonic per item like `getRawInt`/`setRawBool`. Confirms
    /// the 6-digit P1P2P3 address is built/stripped correctly and that a
    /// non-numeric P4 (ASCII text items exist in Table 3) round-trips as
    /// a raw string, unlike `getRawInt` which assumes P4 is all digits.
    func testMenuItemGenericGetSet() async throws {
        let server = try FakeRigctldServer.start()
        defer { server.stop() }

        let client = RigctldClient(host: "127.0.0.1", port: server.port)
        try await client.connect()

        server.respondRaw(to: "W EX040108; ;", bytes: Array("EX040108020\0".utf8))
        let value = try await client.getMenuItem(p1: 4, p2: 1, p3: 8)
        XCTAssertEqual(value, "020")

        server.respondRaw(to: "W EX050101; ;", bytes: Array("EX050101CARL\0".utf8))
        let text = try await client.getMenuItem(p1: 5, p2: 1, p3: 1)
        // An ASCII-text item's P4 (e.g. Table 3's MY CALL) round-trips as a
        // raw string, unlike getRawInt which assumes an all-digit P4.
        XCTAssertEqual(text, "CARL")

        server.respondRaw(to: "W EX040108020; ;", bytes: [])
        try await client.setMenuItem(p1: 4, p2: 1, p3: 8, rawValue: "020")

        await client.disconnect()
    }

    /// Regression test for the actual reported bug: the real rig sometimes
    /// never replies to a raw Set command at all (the manual doesn't
    /// promise an Answer for those), and `sendRawCommand` had no timeout —
    /// it would wait forever. Because `acquireRoundTrip()` serializes every
    /// round trip on the client, that one hung read permanently jammed
    /// every future command behind it: the first button click after a
    /// fresh connection worked, then everything else silently queued
    /// forever, matching what the user saw ("turn BK-IN on, but not off,
    /// and Keyer does nothing after that").
    func testSendRawCommandTimesOutAndDoesNotWedgeClient() async throws {
        let server = try FakeRigctldServer.start()
        defer { server.stop() }

        let client = RigctldClient(host: "127.0.0.1", port: server.port)
        try await client.connect()

        // Deliberately not scripted — the fake server accepts the command
        // but never writes anything back, simulating a real rig silently
        // ignoring a Set command.
        server.silence(command: "W BI1; ;")

        let start = Date()
        do {
            _ = try await client.sendRawCommand("BI1", timeout: .milliseconds(300))
            XCTFail("expected a timeout error")
        } catch RigctldError.rawCommandTimedOut {
            // expected
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0, "should time out promptly, not hang")

        // The hung round trip must not leave acquireRoundTrip()'s lock
        // stuck — a follow-up call should fail fast (the timeout already
        // tore down the connection) rather than hang waiting for a lock
        // that's never released.
        do {
            _ = try await client.getFrequency()
            XCTFail("expected notConnected after the connection was torn down")
        } catch RigctldError.notConnected {
            // expected
        }
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
    private var rawScripts: [String: [UInt8]] = [:]
    private var silencedCommands: Set<String> = []
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
        if silencedCommands.contains(command) {
            lock.unlock()
            return
        }
        let rawBytes = rawScripts[command]
        let lines = rawBytes == nil ? (scripts[command] ?? ["RPRT -1"]) : nil
        lock.unlock()

        if let rawBytes {
            _ = rawBytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            return
        }
        for line in lines ?? [] {
            let bytes = Array((line + "\n").utf8)
            _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        }
    }

    func respond(to command: String, with lines: [String]) {
        lock.lock()
        scripts[command] = lines
        lock.unlock()
    }

    /// Like `respond(to:with:)`, but writes the exact bytes given with no
    /// automatic `\n` appended — for exercising terminator edge cases
    /// (e.g. a `\0`-terminated reply) that the line-oriented variant can't
    /// express.
    func respondRaw(to command: String, bytes: [UInt8]) {
        lock.lock()
        rawScripts[command] = bytes
        lock.unlock()
    }

    /// Accepts the given command but never writes any reply — simulating a
    /// real rig that silently ignores a command (e.g. a Set command with
    /// no Answer).
    func silence(command: String) {
        lock.lock()
        silencedCommands.insert(command)
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
