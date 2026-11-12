import Darwin
import Network
import XCTest
@testable import FTX1Core

/// "The Pi can't be reached" vs "rigctld isn't running" vs "the radio
/// isn't answering" (`RigLinkProblem`).
final class RigLinkProblemTests: XCTestCase {
    // MARK: Connect failures, through the real client

    /// A refused port fails at once (NWConnection only *waits* on it), not
    /// after the timeout.
    func testRefusedPortIsRigctldNotRunningAndFailsFast() async throws {
        let port = try Self.closedLocalPort()
        let client = RigctldClient(host: "127.0.0.1", port: port)
        let start = ContinuousClock.now
        do {
            try await client.connect(timeout: .seconds(5))
            XCTFail("connected to a closed port")
        } catch {
            XCTAssertEqual(error as? RigctldError, .connectionRefused)
            XCTAssertEqual(RigLinkProblem(error: error), .rigctldNotRunning)
        }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testUnresolvableNameIsHostNotFound() async throws {
        let client = RigctldClient(host: "no-such-host-ftx1remote.invalid", port: 4532)
        do {
            try await client.connect(timeout: .seconds(5))
            XCTFail("resolved a .invalid name")
        } catch {
            XCTAssertEqual(error as? RigctldError, .hostNotFound)
            XCTAssertEqual(RigLinkProblem(error: error), .hostNotFound)
            XCTAssertTrue(RigLinkProblem(error: error).isHostProblem)
        }
    }

    /// After a failed connect, the next command fails at once instead of
    /// writing to the dead connection.
    func testCommandAfterFailedConnectIsNotConnected() async throws {
        let client = RigctldClient(host: "127.0.0.1", port: try Self.closedLocalPort())
        _ = try? await client.connect(timeout: .seconds(1))
        do {
            _ = try await client.getFrequency()
            XCTFail("read without a connection")
        } catch {
            XCTAssertEqual(error as? RigctldError, .notConnected)
        }
    }

    func testClassification() {
        XCTAssertEqual(RigLinkProblem(error: RigctldError.connectTimedOut), .hostUnreachable)
        XCTAssertEqual(RigLinkProblem(error: RigctldError.connectionLost), .connectionLost)
        XCTAssertEqual(RigLinkProblem(error: RigctldError.notConnected), .connectionLost)
        XCTAssertEqual(RigLinkProblem(error: RigctldError.rawCommandTimedOut), .rigNotResponding)
        XCTAssertEqual(RigLinkProblem(error: RigctldError.replyTimedOut), .rigNotResponding)
        XCTAssertTrue(RigLinkProblem.hostUnreachable.isHostProblem)
        XCTAssertFalse(RigLinkProblem.rigNotResponding.isHostProblem)
        XCTAssertFalse(RigLinkProblem.rigctldNotRunning.isHostProblem)
        XCTAssertEqual(RigctldClient.connectError(for: .posix(.ECONNREFUSED)), .connectionRefused)
        XCTAssertEqual(RigctldClient.connectError(for: .dns(-65554)), .hostNotFound)
        XCTAssertNil(RigctldClient.connectError(for: .posix(.EHOSTUNREACH)))
        XCTAssertNil(RigctldClient.connectError(for: .posix(.ENETDOWN)))
        if case .other = RigLinkProblem(error: CancellationError()) {} else { XCTFail() }
    }

    // MARK: RigResponseMonitor

    func testFirstAnswerReportsAnsweringOnce() {
        var monitor = RigResponseMonitor()
        XCTAssertEqual(monitor.record(answered: true), .answering)
        XCTAssertNil(monitor.record(answered: true))
    }

    func testSilentRigIsReportedAfterThreshold() {
        var monitor = RigResponseMonitor(threshold: 3)
        XCTAssertEqual(monitor.record(answered: true), .answering)
        XCTAssertNil(monitor.record(answered: false))
        XCTAssertNil(monitor.record(answered: false))
        XCTAssertEqual(monitor.record(answered: false), .notResponding)
        XCTAssertNil(monitor.record(answered: false), "reported once, not every tick")
        XCTAssertEqual(monitor.record(answered: true), .answering)
    }

    /// Dropped replies that aren't in a row never trip it.
    func testScatteredFailuresDontTrip() {
        var monitor = RigResponseMonitor(threshold: 3)
        _ = monitor.record(answered: true)
        for _ in 0..<20 {
            XCTAssertNil(monitor.record(answered: false))
            XCTAssertNil(monitor.record(answered: false))
            XCTAssertNil(monitor.record(answered: true))
        }
    }

    /// A rig that's silent from the start (connected to rigctld, the radio
    /// already gone) is reported without ever having answered.
    func testSilentFromConnect() {
        var monitor = RigResponseMonitor(threshold: 2)
        XCTAssertNil(monitor.record(answered: false))
        XCTAssertEqual(monitor.record(answered: false), .notResponding)
        XCTAssertEqual(monitor.record(answered: true), .answering)
    }

    // MARK: Helpers

    /// A localhost port nothing listens on: bound, read, then closed.
    private static func closedLocalPort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw XCTSkip("no socket") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, len) == 0 && Darwin.getsockname(fd, $0, &len) == 0
            }
        }
        guard bound else { throw XCTSkip("couldn't bind") }
        return UInt16(bigEndian: addr.sin_port)
    }
}
