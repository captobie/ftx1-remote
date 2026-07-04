# FTX1Remote

Native Mac/iOS/iPadOS app to remotely control and monitor a Yaesu FTX-1 amateur
radio transceiver. SwiftUI, shared codebase across platforms. Single-user tool —
no multi-user auth/permissions needed unless explicitly asked for.

## Why

The radio (Yaesu FTX-1) lives at home, connected via USB. This app lets me
monitor and control it from my Mac at the desk, or remotely from iOS/iPadOS
over Tailscale, without needing to be physically near the rig.

## Architecture

- **Mac app = hub/server.** It's the only thing that talks to hardware.
- **rigctld (hamlib)** runs on the Mac at `localhost:4532` and is the single
  source of truth for hardware communication — same as the existing
  `rigctld_control.py` setup it replaces. Do not suggest bridging libhamlib
  directly into iOS/iPadOS; mobile clients are network clients only.
- **Mac app exposes a WebSocket server** that iOS/iPadOS clients connect to.
  Mobile apps never talk to rigctld directly.
- **Mac's own local UI also goes through the WebSocket client** (connecting to
  itself at `localhost`), not a separate direct-to-rigctld UI path. One client
  implementation shared by Mac and mobile.
- **Tailscale** handles remote network routing between Mac and mobile devices
  (already set up and working — don't relitigate this).
- **State sync is push-based**, not polled. The Mac pushes state changes
  (VFO, mode, power, SWR, PTT) to connected clients as they happen.
- **Wire protocol is JSON.** Commands like `{"cmd": "set_freq", "value": ...}`;
  state pushes follow a similar shape.

## Structure

- `FTX1Core/` — Swift Package Manager package: shared rig state model, wire
  protocol (Codable), rigctld TCP client (Network.framework), WebSocket
  client/server logic, command queue actor. Platform-agnostic.
- `Apps/Mac/` — Mac app target. Owns the rigctld connection and WebSocket
  server (`NWListener`). Dense multi-pane UI (VFO, meters, band/mode
  selectors all visible at once).
- `Apps/iOS/` — iPhone app target. WebSocket client only. Focused
  single-rig-control view — don't try to cram the Mac's dense layout in here.
- `Apps/iPad/` (or shared iOS target with size classes) — splits the
  difference between Mac density and iPhone focus.

## Working conventions

- Flag platform-specific UI tradeoffs when relevant instead of picking one
  silently — Mac/iPhone/iPad genuinely want different layouts here.
- Background server layer (rigctld connection + WebSocket server) should stay
  independent of window state — it keeps running whether or not the Mac app's
  window is open.
- When in doubt about wire protocol shape or RigState fields, check
  `FTX1Core/Sources` for the actual Codable types rather than assuming.

## Commands

<!-- Fill in once the Xcode project / SwiftPM setup exists, e.g.: -->
<!-- - Build: `xcodebuild -scheme FTX1RemoteMac build` -->
<!-- - Test:  `swift test` (from FTX1Core/) -->
<!-- - Run:   open in Xcode, Cmd+R -->
