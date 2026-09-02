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
  directly into iOS/iPadOS; mobile clients are network clients only. The Mac
  app also owns launching rigctld itself (`RigctldProcessController`, see
  `Apps/Mac/` below) rather than requiring it pre-started — on launch it
  probes the configured port and adopts an already-running, responsive
  rigctld instead of killing it (another client, e.g. WSJT-X, may be
  mid-session with it); only an unresponsive/stale one gets killed and
  replaced.
- **Mac app exposes a WebSocket server** that iOS/iPadOS clients connect to.
  Mobile apps never talk to rigctld directly.
- **Mac's own local UI calls `HubService` directly** (`hub.send(...)`,
  bypassing `RigWebSocketClient`/`RigWebSocketServer`) rather than
  round-tripping through the WebSocket to itself — the original plan was for
  the Mac's local UI to go through the WebSocket client too, but every
  feature built so far (Menu grid, Deep Settings) uses the direct-call path,
  and it works fine since `HubService` still broadcasts every applied
  command to remote clients regardless of how it was triggered. The
  WebSocket path exists for remote (iOS/iPad) clients only in practice
  today.
- **Views shared across app targets go through a `RigController` protocol**
  (`Sources/FTX1Core/UI/RigController.swift`), not a concrete type — the Mac
  drives them with `HubService` (direct rigctld access), mobile clients
  drive them with `RigClientViewModel` (WebSocket only). `MenuPageView` is
  the first (and so far only) view built this way, generic over
  `RigController`. When adding another view meant to appear on more than
  one app target, follow this pattern rather than duplicating the file per
  target or coupling it to `HubService` directly.
- **`DeepSettingsView` is still Mac-only, deliberately.** It needs
  `HubService.readMenuItem` — a live per-item read only the Mac's direct
  rigctld link supports. The WebSocket wire protocol has no request/
  response mechanism today, only fire-and-forget `RigCommand` and one-way
  `RigStatePush`, so a remote client has no way to fetch a Deep Settings
  item's current value. `RigController.supportsDeepSettings`/
  `deepSettingsDestination` is the seam for this: `HubService` returns a
  real destination, every other conformer defaults to unsupported. Don't
  try to light this up for iOS/iPad without first designing that
  request/response addition (see `Apps/iPad/` note below).
- **Tailscale** handles remote network routing between Mac and mobile devices
  (already set up and working — don't relitigate this).
- **State sync is push-based**, not polled. The Mac pushes state changes
  (VFO, mode, power, SWR, PTT) to connected clients as they happen.
- **Wire protocol is JSON.** Commands like `{"cmd": "set_freq", "value": ...}`;
  state pushes follow a similar shape.
- **Raw CAT passthrough for menu-driven settings.** Most of the FTX-1's menu
  items (both the numbered MENU grid and the deeper page-3 SET-mode screens)
  have no hamlib func/level equivalent — they're wired via `RigctldClient`'s
  raw CAT passthrough (`sendRawCommand`/`getRawBool`/`setRawInt`/etc.),
  documented in the CAT Operation Reference Manual, not through rigctld's
  generic get/set verbs. See `Structure` below for where the two menu
  systems live.
- **Waterfall/oscilloscope display is audio-derived, not CAT-derived.**
  `AudioCaptureEngine` (Mac-only) captures from a user-selected sound card
  input device (Settings → Audio tab; the rig's own audio out into the Mac,
  in practice — not a rigctld/CAT feature) and runs an FFT to produce both a
  scrolling waterfall and an oscilloscope trace from the same buffer, with
  auto-gain (peak-hold-and-decay) rather than a fixed dB/amplitude range.
  This is entirely separate from the rig-control data path — no rigctld or
  wire-protocol involvement — and Mac-only today; it isn't broadcast to
  mobile clients.

## Structure

- `Sources/FTX1Core/` — Swift Package Manager package (target `FTX1Core`,
  repo root `Package.swift`): platform-agnostic.
  - `RigState/` — `RigState`/`RigMode` (shared state model), `BandPlan`
    (band table + frequency lookup).
  - `Appearance/` — `AppTheme` (Light/Dark/Auto), `ButtonValueColor` (MENU
    grid button value color), `AppearanceSettings` (the `@AppStorage` keys
    both are read/written through) — shared so any future app target reads
    the same settings the Mac's Settings sheet writes.
  - `Networking/` — `WireMessage` (`RigCommand`/`RigStatePush`, the JSON wire
    protocol), `RigctldClient` (Mac-only, TCP to rigctld, incl. raw CAT
    passthrough), `RigWebSocketClient` (WS client, used by mobile and — for
    now — nothing on the Mac side, see above), `RigClientViewModel`
    (`ObservableObject` wrapping `RigWebSocketClient` for SwiftUI — shared by
    the iOS and iPad app targets so their connection logic can't drift
    apart; conforms to `RigController`, see `UI/` below).
  - `Commands/` — `CommandQueue`, serializes `RigCommand`s into rigctld
    calls one at a time.
  - `MenuSettings/` — `DeepSettingsCatalog`/`DeepSettingItem`/
    `DeepSettingValueType`: the static, table-driven catalog behind the
    page-3 Deep Settings screens (see below).
  - `UI/` — SwiftUI views/protocols shared across more than one app target.
    `RigController` (the protocol `HubService`/`RigClientViewModel` both
    conform to — see Architecture above), `MenuPageView` (the numbered 7×4
    MENU grid, generic over `RigController`, one hand-written button per
    item), `VFODisplayBox` (the dense side-by-side VFO A/B readout used by
    Mac and iPad), `SMeterView` (the analog S/SWR meter face, used by Mac
    and iPad). Only put a view here once it's actually needed on more than
    one target — `FrequencyDisplay` (iOS's single-VFO readout) stays in the
    iOS app target since nothing else uses it.
- `Apps/Mac/FTX1RemoteMac/` — Mac app target source (canonical location;
  the Xcode project at `FTX1RemoteMac/FTX1RemoteMac.xcodeproj` points at
  this directory via a synchronized group, not a separate copy). Owns the
  rigctld connection and WebSocket server (`HubService`, `RigWebSocketServer`,
  `RigctldProcessController`), plus `HubService`'s `RigController`
  conformance (`HubService+RigController.swift` — the only conformer that
  builds a real `DeepSettingsView` destination). Also owns the audio-derived
  waterfall/oscilloscope display (`AudioCaptureEngine`, `ScopeDisplayView`,
  `AudioInputDevice`/`AudioInputSettings`) — Mac-only, see Architecture
  above. Dense multi-pane UI (`ContentView`: VFO, meters, scope display,
  band/mode selectors all visible at once), `SettingsView` (tabbed sheet:
  rigctld connection config, Audio input device, Appearance), plus two menu
  systems: `MenuPageView` (shared, see `Sources/FTX1Core/UI/` above) and
  `DeepSettingsView` (Mac-only — the page-3 category screens, rendered
  generically from `DeepSettingsCatalog`).
- `Apps/iOS/FTX1RemoteiOS/` — iPhone app target. WebSocket client only
  (`RigClientViewModel`/`RigWebSocketClient`), never touches `RigctldClient`
  directly. Focused single-rig-control view (frequency, SWR, PTT, mode grid)
  — don't try to cram the Mac's dense layout or `MenuPageView` in here
  without deciding that's actually wanted; iOS still has no menu-grid UI
  (iPad does — see below). `DeepSettingsView` isn't available to any mobile
  target yet either way (see Architecture above).
- `Apps/iPad/FTX1RemoteiPad/` — iPad app target, separate from iOS (not a
  universal/size-classes target — resolved decision, don't relitigate).
  WebSocket client only, same as iOS. Dense layout modeled on the Mac's
  `ContentView` (VFO A/B side by side via the shared `VFODisplayBox`, SWR,
  PTT, power, band/mode) plus the shared `MenuPageView` grid. The FM page's
  6 Deep Settings buttons render a disabled "SOON" placeholder rather than
  opening `DeepSettingsView` — see the `RigController`/Deep Settings note
  above for why, and don't wire them up without first adding the wire-
  protocol read/response mechanism that unblocks it.

## Working conventions

- Flag platform-specific UI tradeoffs when relevant instead of picking one
  silently — Mac/iPhone/iPad genuinely want different layouts here.
- Background server layer (rigctld connection + WebSocket server) should stay
  independent of window state — it keeps running whether or not the Mac app's
  window is open.
- When in doubt about wire protocol shape or RigState fields, check
  `Sources/FTX1Core` for the actual Codable types rather than assuming.
- When wiring a raw CAT command (numbered MENU button or Deep Settings
  catalog entry), don't guess mnemonics/addressing from other Yaesu rigs'
  conventions or trust the CAT manual's printed values at face value —
  read the manual directly and hardware-test. The manual has been wrong
  in confirmed, varied ways (see git log / commit messages for `MenuPageView`
  and `DeepSettingsCatalog.swift`): wrong parameter labels, wrong digit
  widths, and at least one wrong value *mapping* (not just presentation).
  It's also occasionally missing features entirely if they postdate the
  manual's firmware revision (e.g. WIRES-X).

## Commands

- Build/test the shared package: `swift build`, `swift test` (from repo
  root — `Package.swift` covers only the `FTX1Core` library + test target).
- Build an app target: `xcodebuild -project
  FTX1RemoteMac/FTX1RemoteMac.xcodeproj -scheme
  <FTX1RemoteMac|FTX1RemoteiOS|FTX1RemoteiPad> -destination
  '<platform=macOS|generic/platform=iOS Simulator>' build` — not
  `swift build`, which doesn't cover the app targets at all.
- Run the Mac app: `open` the built `.app` under
  `~/Library/Developer/Xcode/DerivedData/FTX1RemoteMac-*/Build/Products/Debug/`,
  or Cmd+R in Xcode.
