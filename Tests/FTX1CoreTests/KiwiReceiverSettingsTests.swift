import XCTest
@testable import FTX1Core

/// The Local SDR window's AGC, noise blanker and noise filter commands,
/// against what the Kiwi's own page sends (v1.902).
final class KiwiReceiverSettingsTests: XCTestCase {
    func testDefaultsSendWhatANewConnectionAlwaysSent() {
        XCTAssertEqual(KiwiReceiverSettings().agcCommand,
                       "SET agc=1 hang=0 thresh=-100 slope=6 decay=1000 manGain=50")
        XCTAssertEqual(KiwiProtocol.setupCommands(identUser: "x", compression: false), [
            "SET squelch=0 max=0",
            "SET genattn=0",
            "SET gen=0 mix=-1",
            "SET agc=1 hang=0 thresh=-100 slope=6 decay=1000 manGain=50",
            "SET compression=0",
            "SET ident_user=x",
        ])
    }

    func testManualGain() {
        var settings = KiwiReceiverSettings()
        settings.agc = false
        settings.manualGain = 72
        settings.threshold = -90
        settings.decay = 500
        XCTAssertEqual(settings.agcCommand, "SET agc=0 hang=0 thresh=-90 slope=6 decay=500 manGain=72")
    }

    func testBlankerOff() {
        XCTAssertEqual(KiwiReceiverSettings().noiseBlankerCommands,
                       ["SET nb algo=0", "SET nb type=0 en=0", "SET nb type=1 en=0"])
    }

    func testStandardBlanker() {
        var settings = KiwiReceiverSettings()
        settings.noiseBlanker = .standard
        settings.gate = 300
        settings.blankerThreshold = 25
        XCTAssertEqual(settings.noiseBlankerCommands, [
            "SET nb algo=1",
            "SET nb type=0 param=0 pval=300",
            "SET nb type=0 param=1 pval=25",
            "SET nb type=0 en=1",
            "SET nb type=1 en=1",
        ])
    }

    func testWildBlanker() {
        var settings = KiwiReceiverSettings()
        settings.noiseBlanker = .wild
        settings.wildThreshold = 1.2
        XCTAssertEqual(settings.noiseBlankerCommands, [
            "SET nb algo=2",
            "SET nb type=0 param=0 pval=1.2",
            "SET nb type=0 param=1 pval=10",
            "SET nb type=0 param=2 pval=7",
            "SET nb type=0 en=1",
            "SET nb type=1 en=1",
        ])
    }

    func testFilterOffSendsOnlyTheAlgorithm() {
        XCTAssertEqual(KiwiReceiverSettings().noiseFilterCommands, ["SET nr algo=0"])
    }

    func testWDSPMatchesThePagesDefaults() {
        var settings = KiwiReceiverSettings()
        settings.noiseFilter = .wdsp
        settings.denoise = true
        XCTAssertEqual(settings.noiseFilterCommands, [
            "SET nr algo=1",
            "SET nr type=0 param=0 pval=64",
            "SET nr type=0 param=1 pval=16",
            "SET nr type=0 param=2 pval=8e-05",
            "SET nr type=0 param=3 pval=0.125",
            "SET nr type=0 en=1",
            "SET nr type=1 param=0 pval=64",
            "SET nr type=1 param=1 pval=16",
            "SET nr type=1 param=2 pval=8e-05",
            "SET nr type=1 param=3 pval=0.125",
            "SET nr type=1 en=0",
        ])
    }

    func testLMSParametersDifferByFilter() {
        var settings = KiwiReceiverSettings()
        settings.noiseFilter = .lms
        settings.autonotch = true
        let commands = settings.noiseFilterCommands
        XCTAssertTrue(commands.contains("SET nr type=0 param=1 pval=0.05"))
        XCTAssertTrue(commands.contains("SET nr type=1 param=0 pval=48"))
        XCTAssertTrue(commands.contains("SET nr type=1 param=2 pval=0.99915"))
        XCTAssertTrue(commands.contains("SET nr type=0 en=0"))
        XCTAssertTrue(commands.contains("SET nr type=1 en=1"))
    }

    func testSpectral() {
        var settings = KiwiReceiverSettings()
        settings.noiseFilter = .spectral
        XCTAssertTrue(settings.noiseFilterCommands.contains("SET nr type=0 param=2 pval=1000"))
        XCTAssertTrue(settings.noiseFilterCommands.contains("SET nr type=0 param=0 pval=1"))
    }

    func testSelectingAFilterWithBothSwitchesOffTurnsDenoiseOn() {
        var settings = KiwiReceiverSettings()
        settings.select(noiseFilter: .wdsp)
        XCTAssertTrue(settings.denoise)
        var autonotchOnly = KiwiReceiverSettings()
        autonotchOnly.autonotch = true
        autonotchOnly.select(noiseFilter: .lms)
        XCTAssertFalse(autonotchOnly.denoise)
        var spectral = KiwiReceiverSettings()
        spectral.select(noiseFilter: .spectral)
        XCTAssertFalse(spectral.denoise)
    }

    func testOnlyChangedGroupsAreSent() {
        let old = KiwiReceiverSettings()
        XCTAssertEqual(old.commands(changedFrom: old), [])
        var agc = old
        agc.decay = 500
        XCTAssertEqual(agc.commands(changedFrom: old), [agc.agcCommand])
        var blanker = old
        blanker.noiseBlanker = .standard
        XCTAssertEqual(blanker.commands(changedFrom: old), blanker.noiseBlankerCommands)
        var filter = old
        filter.select(noiseFilter: .wdsp)
        XCTAssertEqual(filter.commands(changedFrom: old), filter.noiseFilterCommands)
    }

    func testSetupOnlySendsNoiseCommandsWhenOn() {
        var settings = KiwiReceiverSettings()
        settings.noiseBlanker = .standard
        settings.select(noiseFilter: .spectral)
        settings.agc = false
        let setup = KiwiProtocol.setupCommands(identUser: "x", compression: false, receiver: settings)
        XCTAssertTrue(setup.contains(settings.agcCommand))
        for command in settings.noiseBlankerCommands + settings.noiseFilterCommands {
            XCTAssertTrue(setup.contains(command), command)
        }
        XCTAssertFalse(KiwiProtocol.setupCommands(identUser: "x", compression: false).contains { $0.hasPrefix("SET nb") })
        XCTAssertFalse(KiwiProtocol.setupCommands(identUser: "x", compression: false).contains { $0.hasPrefix("SET nr") })
    }

    func testClampedStaysInTheKiwisRanges() {
        var settings = KiwiReceiverSettings()
        settings.manualGain = 500
        settings.threshold = 20
        settings.decay = 1
        settings.gate = 9
        settings.blankerThreshold = -3
        settings.wildThreshold = 8
        let clamped = settings.clamped
        XCTAssertEqual(clamped.manualGain, 120)
        XCTAssertEqual(clamped.threshold, 0)
        XCTAssertEqual(clamped.decay, 20)
        XCTAssertEqual(clamped.gate, 100)
        XCTAssertEqual(clamped.blankerThreshold, 0)
        XCTAssertEqual(clamped.wildThreshold, 3)
    }
}
