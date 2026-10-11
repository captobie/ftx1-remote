import XCTest
@testable import FTX1Core

/// `SpectrumFFT`/`SpectrumAutoGain`/`FilterSpectrum` (shared by the Mac's
/// waterfall and both platforms' Filter Function Display) and the iPad's
/// `FilterSpectrumStore`, against synthesized tones.
final class FilterSpectrumTests: XCTestCase {
    private func tone(hz: Double, sampleRate: Double, count: Int, amplitude: Float = 0.5) -> [Float] {
        (0..<count).map { amplitude * Float(sin(2 * .pi * hz * Double($0) / sampleRate)) }
    }

    private func peakIndex(_ values: [Float]) -> Int {
        values.indices.max { values[$0] < values[$1] }!
    }

    func testToneLandsInItsBin() {
        let fft = SpectrumFFT(size: 512)
        let db = fft.powerDb(tone(hz: 1000, sampleRate: 8000, count: 512))
        XCTAssertEqual(db.count, 256)
        XCTAssertEqual(Double(peakIndex(db)) * fft.binHz(sampleRate: 8000), 1000, accuracy: 16)
    }

    /// The level scaling: the same tone reads the same peak dB at 512 and
    /// 2048 points, so the auto-gain's absolute minimum means the same.
    func testPeakLevelIndependentOfSize() {
        let small = SpectrumFFT(size: 512).powerDb(tone(hz: 1000, sampleRate: 8000, count: 512))
        let large = SpectrumFFT(size: 2048).powerDb(tone(hz: 1000, sampleRate: 8000, count: 2048))
        XCTAssertEqual(small.max()!, large.max()!, accuracy: 1)
    }

    func testNormalizedCoversFourKilohertz() {
        let fft = SpectrumFFT(size: 2048)
        let db = fft.powerDb(tone(hz: 1500, sampleRate: 44100, count: 2048))
        var gain = SpectrumAutoGain()
        let window = gain.update(db: db)
        let spectrum = FilterSpectrum.normalized(db: db, floorDb: window.floorDb, ceilingDb: window.ceilingDb, binHz: fft.binHz(sampleRate: 44100))
        XCTAssertEqual(spectrum.count, 185)
        XCTAssertTrue(spectrum.allSatisfy { (0...1).contains($0) })
        XCTAssertEqual(Double(peakIndex(spectrum)) * fft.binHz(sampleRate: 44100), 1500, accuracy: 22)
    }

    func testAutoGainHoldsThenDecays() {
        var gain = SpectrumAutoGain()
        _ = gain.update(db: [-20])
        XCTAssertEqual(gain.peakDb, -20)
        _ = gain.update(db: [-60])
        XCTAssertEqual(gain.peakDb, -20 - SpectrumAutoGain.peakDecayPerFrameDb)
        _ = gain.update(db: [-200])
        XCTAssertGreaterThanOrEqual(gain.peakDb, SpectrumAutoGain.minimumPeakDb)
    }

    private func pcm(_ samples: [Float]) -> Data {
        var ints = samples.map { Int16(max(-1, min(1, $0)) * Float(Int16.max)) }
        return Data(bytes: &ints, count: ints.count * MemoryLayout<Int16>.size)
    }

    @MainActor
    func testStoreUsesOnlyTheSelectedSideOnceEnabled() {
        let store = FilterSpectrumStore()
        let chunk = pcm(tone(hz: 1000, sampleRate: 8000, count: 400))

        store.ingest(pcm: chunk, side: .main)
        store.ingest(pcm: chunk, side: .main)
        XCTAssertTrue(store.spectrum.isEmpty, "nothing while disabled")

        store.isEnabled = true
        store.ingest(pcm: chunk, side: .main)
        XCTAssertTrue(store.spectrum.isEmpty, "waits for a full 512-sample block")
        store.ingest(pcm: chunk, side: .main)
        XCTAssertEqual(store.spectrum.count, 256)
        XCTAssertEqual(Double(peakIndex(store.spectrum)) * 8000 / 512, 1000, accuracy: 16)

        store.selectedSide = .sub
        XCTAssertTrue(store.spectrum.isEmpty, "a side switch starts over")
        store.ingest(pcm: chunk, side: .main)
        store.ingest(pcm: chunk, side: .main)
        XCTAssertTrue(store.spectrum.isEmpty, "the other side's audio is ignored")
        store.ingest(pcm: chunk, side: .sub)
        store.ingest(pcm: chunk, side: .sub)
        XCTAssertFalse(store.spectrum.isEmpty)

        store.isEnabled = false
        XCTAssertTrue(store.spectrum.isEmpty)
    }
}

/// `FilterStateReads`' `RigState` helpers, shared by the hub and Pi direct.
final class FilterStateApplyTests: XCTestCase {
    func testSnapshotKeepsUnreadFields() {
        var state = RigState()
        state.filterWidthIndex = 10
        state.ifShiftHz = 200
        var snapshot = FilterSnapshot()
        snapshot.shiftHz = -100
        snapshot.notchRaw = 1
        state.applyFilterSnapshot(snapshot, mode: .usb)
        XCTAssertEqual(state.filterWidthIndex, 10)
        XCTAssertEqual(state.ifShiftHz, -100)
        XCTAssertEqual(state.notchEnabled, true)
    }

    func testNarrowPresetClearedForModeWithoutOne() {
        var state = RigState()
        state.narrowWidthHz = 1800
        state.applyFilterSnapshot(FilterSnapshot(), mode: .usb)
        XCTAssertEqual(state.narrowWidthHz, 1800, "kept where the mode has a preset")
        state.applyFilterSnapshot(FilterSnapshot(), mode: .fm)
        XCTAssertNil(state.narrowWidthHz)
    }

    func testFilterCommandsOnly() {
        var state = RigState()
        XCTAssertTrue(state.applyFilterCommand(.setNarrow(true)))
        XCTAssertEqual(state.narrowEnabled, true)
        XCTAssertTrue(state.applyFilterCommand(.setIFShift(hz: 207)))
        XCTAssertEqual(state.ifShiftHz, IFShift.snapped(207))
        XCTAssertFalse(state.applyFilterCommand(.setFilterSide(.sub)))
        XCTAssertFalse(RigCommand.setFilterSide(.sub).isFilterSideCommand)
        XCTAssertTrue(RigCommand.setFilterWidth(5).isFilterSideCommand)
        state.clearFilterFields()
        XCTAssertNil(state.narrowEnabled)
        XCTAssertNil(state.ifShiftHz)
    }
}
