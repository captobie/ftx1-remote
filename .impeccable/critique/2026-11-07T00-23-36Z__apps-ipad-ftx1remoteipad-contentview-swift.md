---
target: iPad hub screen
total_score: 24
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 2
target_identity: "file:/Users/carlobermeier/ftx1-remote/Apps/iPad/FTX1RemoteiPad/ContentView.swift"
target_fingerprint: "sha256:0926259ddadcd80234b83381d548c1443e2b8c90a7c16eb6d736040660aa9b8e"
target_path: /Users/carlobermeier/ftx1-remote/Apps/iPad/FTX1RemoteiPad/ContentView.swift
timestamp: 2026-11-07T00-23-36Z
slug: apps-ipad-ftx1remoteipad-contentview-swift
---
Method: design review only (detector not applicable, native platform). Target: iPad hub screen (HubControlView in ContentView.swift), source review only.

Score 24/40 (Acceptable). H1 3, H2 3, H3 3, H4 2, H5 3, H6 2, H7 2, H8 3, H9 2, H10 1.

Priority issues:
- [P1] PTT scrolls out of reach (top row inside ScrollView). Fix: pin connection/PTT/lock row outside scroll. /impeccable layout
- [P1] PTT undersized and quiet (~34pt pill matching Connected; 0.4 opacity when blocked). Fix: >=44pt, visible locked treatment. /impeccable adapt
- [P2] Top row has eleven controls at equal weight. Fix: group by purpose. /impeccable distill
- [P2] Speaker icon means two things (strip mute vs audio-channel override). /impeccable clarify
- [P2] Small touch targets (mute 40x34) and fixed 9-10pt meter fonts. /impeccable audit
