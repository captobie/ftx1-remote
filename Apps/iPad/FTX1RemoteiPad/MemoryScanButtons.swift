import FTX1Core
import SwiftUI

/// The Mac's Scan/Skip pair (`ContentView.memoryScanButton`/
/// `memoryScanSkipButton`) for both iPad screens' top rows: Scan is a menu
/// (Scan SUB / Scan MAIN, each enabled only in that side's Memory mode —
/// `RigState.canStartMemoryScan`) that turns into "Stop SUB"/"Stop MAIN"
/// while a scan runs; Skip resumes a paused scan past the busy channel.
/// One side at a time, as on the Mac — whoever handles `.setMemoryScan`
/// stops the other side's scan first.
struct MemoryScanButtons: View {
    let state: RigState
    let isConnected: Bool
    let send: (RigCommand) -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let side = activeSide {
                Button {
                    send(.setMemoryScan(.off, side: side))
                } label: {
                    Text("memoryScanButtons.stop \(side.displayName)")
                        .foregroundStyle(Color.white)
                }
                .tint(.accentColor)
                .buttonStyle(.borderedProminent)
                .disabled(!isConnected)
            } else {
                Menu {
                    // SUB first, matching the VFO boxes' left-to-right order.
                    ForEach([FilterSide.sub, .main], id: \.self) { side in
                        Button("common.scanX \(side.displayName)") { send(.setMemoryScan(.up, side: side)) }
                            .disabled(!state.canStartMemoryScan(on: side))
                    }
                } label: {
                    Text("common.scan")
                }
                .buttonStyle(.bordered)
                .disabled(!isConnected || !FilterSide.allCases.contains { state.canStartMemoryScan(on: $0) })
            }

            // Same command again on a paused scan = resume past the busy
            // channel (rig-confirmed on the Mac, 2026-10-06). Upward: the
            // iPad only starts upward scans.
            Button("common.skip") {
                if let side = activeSide { send(.setMemoryScan(.up, side: side)) }
            }
            .buttonStyle(.bordered)
            .disabled(!isConnected || state.memoryScan != .paused)
        }
        // A longer translation ("Überspringen") would otherwise squeeze
        // these to one letter per line; PTT next to them gives way instead.
        .lineLimit(1)
        .fixedSize()
    }

    /// The side whose memory scan is running or paused, nil when none is.
    private var activeSide: FilterSide? {
        state.memoryScan == .scanning || state.memoryScan == .paused ? (state.memoryScanSide ?? .main) : nil
    }
}
