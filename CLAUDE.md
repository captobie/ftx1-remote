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
  `AudioCaptureEngine` (Mac-only) captures audio, runs an FFT to produce
  both a scrolling waterfall and an oscilloscope trace from the same
  buffer, with auto-gain (peak-hold-and-decay) rather than a fixed
  dB/amplitude range, and separately hands the same raw samples out for
  `HubService`'s APRS decode gate and the Mac→iPad audio relay
  (`AudioStreamEncoder`/`RigWebSocketServer.broadcastAudio`) — entirely
  separate from the rig-control data path, no rigctld or wire-protocol
  involvement. Where the audio actually comes from depends on
  `RigctldSettings.connectionMode`, same toggle as rig control: `.local`
  taps a user-selected Mac sound card input (Settings → Audio tab; the
  rig's own audio out into the Mac, in practice); `.remote` connects to
  `Pi/ftx1-audiostream.py` over the network via `RemoteAudioStreamClient`
  instead (see "Audio-over-Pi" below) — both feed the exact same
  downstream FFT/relay code, which can't tell them apart. The
  waterfall/oscilloscope display itself is Mac-only either way (not
  broadcast to mobile clients); only the raw audio is.
- **Scope frames deliberately bypass `HubService`'s `@Published` state.**
  `AudioCaptureEngine` hands `HubService` a frame ~21 times a second
  (44100 Hz / 2048-sample chunks); `HubService` stores it in a separate
  `ScopeFrameStore` (`ObservableObject`, a plain `let` on the hub) that
  only `ScopeDisplayView` observes. Until 2026-09-09 the frames were
  `@Published` on `HubService` itself, and since `ObservableObject`
  invalidation is per object, every frame re-evaluated all of
  `ContentView` — the 28-button `MenuPageView` grid and two `.segmented`
  pickers included, whose `NSSegmentedControl` relayout alone pinned the
  main thread at ~50% of a core in a Release build (~120-200% total in the
  Debug build Xcode runs, once the Debug-only palette cost below stacked on
  top). Diagnosed with `sample` on the live process, not by reading code;
  the same measurement recipe (launch the built app, connect, `top -pid`,
  `ps -M -p`, `sample <pid> 5`) is the way to check any future "app is hot"
  report. Three related fixes landed together (commits `a277504`, `e9cc1bb`,
  `f5401ee`): the store above; `WaterfallBitmap` now keeps one persistent
  pixel buffer scrolled by a single `memmove` per frame and colors the new
  row through a precomputed 256-entry `WaterfallPalette.lut` (the old
  per-pixel `zip(stops, stops.dropFirst())` search allocated per pixel in
  `-Onone` and cost ~0.75 of a core in Debug, ~nothing in Release); and the
  scope column's "Off" now really is off — `AudioCaptureEngine.
  displayEnabled` skips FFT/bitmap/oscilloscope/frame publish entirely
  while still delivering raw samples to APRS, playback, and the iPad relay
  (before, "Off" only drew nil and saved no CPU). Measured after all three:
  Debug ~26% total with the scope on / ~10% off, Release ~22% / ~8%; what's
  left with the scope on is the genuine live redraw of the scope `Canvas`
  plus the FFT.

## Remote rigctld (Option A) — in progress

Moving the FTX-1's USB/serial connection off the Mac and onto a headless
Raspberry Pi 2B on the same Tailscale tailnet, so the Mac doesn't need to be
physically near the rig. rigctld runs directly on the Pi against the CP210x
ports; everything else (WebSocket server, `CommandQueue`, state-push to
iOS/iPad clients) stays on the Mac unchanged. Deliberately minimal — not a
re-architecture.

- **Both Local (direct USB) and Remote (Pi) stay supported** — implemented —
  not a one-way migration: the radio's USB cable may be plugged into the Mac
  or the Pi depending on where/how the operator is using it. Selected by
  `RigctldSettings.connectionMode` (`.local`/`.remote`). `.remote` adds
  `RigctldSettings.remoteHost` (a Tailscale MagicDNS hostname; port stays
  fixed at 4532, not user-configurable). `SettingsView`'s rigctld tab has a
  mode picker, with the Local fields (binary path, device path, baud rate,
  PTT port) and the Remote host field shown/hidden based on the selection.
- **Changing the mode requires an app relaunch to take effect** — implemented
  — no runtime teardown/rebuild of `RigctldClient`/`CommandQueue` (both are
  fixed for `HubService`'s lifetime, resolved once in `AppDelegate.init`
  from `RigctldSettings.connectionMode`/`.remoteHost`). Settings shows a
  "restart to apply" caption under the mode picker.
- **`RigctldProcessController` stays, but only runs in `.local` mode** —
  implemented. `HubService.startRigctld()`/`stopRigctld()` branch on
  `connectionMode`: in `.remote`, they skip `RigctldProcessController`
  entirely and just connect/disconnect `RigctldClient` against
  `remoteHost:4532` (the host `AppDelegate` resolved at launch) — the Mac
  never spawns, adopts, or kills anything in that mode. `.remote` also skips
  `connectRigctld`'s `isFreshStart` grace period (nothing was "just
  spawned"). Since `rigctldProcessState` has nothing to report in `.remote`
  (nothing was ever started), `HubService.isActive` is a new
  mode-independent flag (true from `startRigctld()` to `stopRigctld()`)
  driving the connect/disconnect button instead, and `ContentView` hides the
  process-state label entirely in `.remote` mode.
- **Timeouts**: plan is a single shared constant (not per-mode) sized for the
  Tailscale-hop case, since slack time costs nothing in `.local`.
  `HubService`'s `isFreshStart`/startup-grace-period reconnect logic no
  longer applies in `.remote` (implemented — see above, there's no "just
  spawned, still binding its port" case for a rigctld the Mac never
  started). Still flagged for re-validation on real hardware rather than
  assumed unchanged: `RigctldClient.sendRawCommand`'s 1s raw-command
  timeout, and general reconnect-delay tuning over an actual Tailscale hop.
- **Planned UI distinction** (not yet designed in detail): "Pi/Tailscale
  unreachable" vs. "rigctld/radio down but the Pi itself is fine" as two
  different `.failed` states in `.remote` mode, since they point to
  different fixes. Needs `RigctldError`/the connect catch site to carry
  enough information to tell TCP-level unreachability apart from a bad or
  absent reply.
- **WSJT-X's "Hamlib NET rigctl" setup has to be pointed at whichever host
  this app is currently using** (localhost in `.local`, the Pi in
  `.remote`). This app does not manage that — repoint it manually whenever
  the mode changes (and the app relaunches).
- **Status as of 2026-09-07**: mode picker, `HubService`'s local/remote
  branching, and real-hardware validation against the Pi all working and
  confirmed by the user — stable connection (no more connect/disconnect
  cycling) and both VFO A/B reading correctly. Two bugs found and fixed
  during that validation:
  `HubService.refreshState()`'s `getFrequency()` read was the one call in
  the whole poll cycle not wrapped in `try?`, so an occasional bad CAT reply
  (rare enough over the Mac's old dedicated local link to never surface) was
  tearing down and reconnecting the whole session instead of just falling
  back to the last known value like every other field — now fixed the same
  way as everything else. Also added a `connectionLogger` (`os.Logger`,
  category "connection") since `connectionState`'s `.failed(String)` wasn't
  surfaced anywhere before — check Console.app when debugging future
  connection-loop issues. (The Pi's own `rigctld.service` missing `-o`,
  causing wrong secondary-VFO reads, was a Pi-config fix, not an app bug —
  fixed by adding `-o` to the systemd unit's `ExecStart`. The original "no
  CAT response at all" outage that blocked this validation for most of a day
  turned out to be a stale hamlib 4.6 pulled in as a Direwolf dependency on
  the Pi, shadowing the working 4.7 install — also not an app bug.) Still
  open: the
  Pi/Tailscale-unreachable UI distinction above, and the rest of the
  validation-plan checklist (WSJT-X coexistence, soak testing, timeout
  re-tuning under sustained real-network conditions).
- **Audio-over-Pi (2026-09-07)**: implemented and hardware-confirmed
  working — waterfall/oscilloscope, iPad relay, and Mac-local playback all
  functioning against the real Pi. In `.remote` mode, `AudioCaptureEngine`
  no longer taps a Mac-local sound card — it connects to
  `Pi/ftx1-audiostream.py` (a small Python + `pyalsaaudio` script, run as
  its own systemd service on the Pi alongside `rigctld.service`/`direwolf.
  service`, listening on port 8532) via the new `RemoteAudioStreamClient`
  (Mac-only, `Apps/Mac/FTX1RemoteMac/`). This piggybacks on the same
  `RigctldSettings.connectionMode`/`.remoteHost` the rig-control work
  already added — deliberately no separate audio setting, since the rig's
  audio-out cable physically moves with wherever the USB/serial connection
  is. Python, not Swift, on the Pi side: the Pi is a 32-bit ARMv7 2B, which
  the official Swift toolchain doesn't support. Raw TCP, not the
  WebSocket/JSON protocol `RigWebSocketClient` uses — this is a dedicated,
  audio-only connection separate from the rigctld link, so there's no need
  for `AudioStreamFormat`'s tag-byte framing (that exists only to
  disambiguate audio from JSON `RigStatePush` frames on the *shared*
  Mac→iPad connection). `AudioCaptureEngine.process(buffer:bitmap:gain:)`'s
  FFT/oscilloscope core was refactored into a shared `process(samples:
  sampleRate:bitmap:gain:)` entry point so both the local `AVAudioEngine`
  tap and the new remote network path feed the exact same downstream code
  — waterfall, oscilloscope, APRS decode gating, and the Mac→iPad relay are
  all unchanged and can't tell the two sources apart.
  - **Capture rate: 44100Hz, not 8kHz.** Started at 8kHz (matching
    `AudioStreamFormat.sampleRate`, the Mac→iPad relay's own separate wire
    format) as a deliberate low-bandwidth choice, but that left
    `AFSKDemodulator` too little timing resolution to reliably decode APRS
    (~6.7 samples/bit at 8kHz vs ~37 at 44100Hz for 1200-baud Bell 202 —
    confirmed via real APRS heartbeat logs showing `decoded:0` throughout
    a session with flags detected but never successfully framed). Raised to
    44100Hz on 2026-09-07 to match Direwolf's own AFSK demodulation rate on
    this same hardware, already proven to decode real traffic. This is
    intentionally decoupled from `AudioStreamFormat.sampleRate` (which
    stays 8kHz, governing only the separate Mac→iPad hop) —
    `RemoteAudioStreamClient`'s `sampleRate` parameter has its own default
    now, not inherited from that constant. Raises Pi→Mac bandwidth from
    ~16KB/s to ~86KB/s, trivial for any real network link. The
    `Pi/ftx1-audiostream.py` doc comment has the full reasoning.
  - **Mac-local playback + squelch/volume UI, added 2026-09-07**:
    `HubService` now owns an `AudioPlaybackEngine` (reused as-is from the
    existing iPad code — already cross-platform), started/stopped alongside
    `audioCapture`, fed the same PCM chunks already sent to iPad. New
    `HubService.audioVolume`/`.squelchThreshold` (persisted via
    `AudioPlaybackSettings`, shared with iPad though iPad has no UI for
    them) are bound to two vertical sliders in `ContentView`, positioned
    right of the Waterfall/Oscilloscope/Off/Mute button column (the
    waterfall narrows automatically since it already fills remaining
    space). Added specifically because the default squelch threshold (0.02)
    left real, quiet-but-legitimate audio gated silent with no way to
    adjust it on the Mac before this existed.
  - **Device-sharing with Direwolf, two real conflicts hit and fixed**: (1)
    `Device or resource busy` — Direwolf holds the raw capture device open
    continuously; fixed via `Pi/asound-ftx1.conf`'s `dsnoop`+`plug` chain
    (`ftx1_shared`), letting both processes read the same hardware capture
    at once, each at their own rate. Direwolf's `ADEVICE` needed its
    two-argument form (`ftx1_shared plughw:1,0`) since `dsnoop` only
    supports capture, not its playback/TX side. (2) `Permission denied
    [ftx1_shared]` — `direwolf` and `ftx1audio` are different Unix accounts,
    and dsnoop's IPC semaphore/shared-memory objects default to permissions
    that only let the *creating* user attach; fixed via `ipc_perm 0666` in
    the dsnoop config, plus a Pi reboot to clear stale IPC objects created
    before that fix existed. Both documented in detail in `Pi/README.md`.
  - **Concurrency note**: this target builds with `-default-isolation=
    MainActor`. `process()` and everything it touches (`AutoGainState`,
    `WaterfallBitmap`, `LockedFloat`, `OscilloscopeRenderer`,
    `WaterfallPalette`) are explicitly `nonisolated`/`nonisolated(unsafe)`
    now — they always ran off the main actor in practice (the class's own
    doc comments already said so), but this was previously unchecked only
    because `AVAudioEngine`'s tap closure isn't a Sendable-audited API.
    `RemoteAudioStreamClient`'s use of `actor`/`@Sendable`/`NWConnection`
    (all properly audited) is what surfaced this gap — worth keeping in
    mind for any future code added to this file, since the class's default
    isolation does NOT match what most of it actually needs.
  - APRS decode confirmed working at the new 44100Hz rate against real
    traffic (2026-09-07) — the sample-rate fix resolved it.
  - **Still open**: the "Pi/Tailscale unreachable" UI distinction (same
    open item as rig control's, not yet extended to cover the audio link
    too).
  - **`RemoteAudioStreamClient`'s "received N bytes so far" heartbeat is
    scaled to `sampleRate`** (one line per ~30s of audio, commit `fb2221e`)
    — it was a fixed 32,000-byte threshold left over from 8kHz, which at
    44.1kHz fired every ~0.37s and buried the rest of this subsystem's
    Console output. Any future per-chunk diagnostic here should be sized
    the same way, not with a byte constant.

## Windows app (v1 skeleton scaffolded, 2026-09-07)

A Windows app with the same kind of functionality as the Mac app, but
remote-only: talks directly to the Pi (rigctld + `ftx1-audiostream.py`),
never to a locally-attached radio, and never through the Mac's WebSocket
hub — the Mac is not required to be running. Architecturally closest to the
Mac permanently in `.remote` mode, minus `RigctldProcessController`
(nothing to spawn — the Pi's `rigctld.service` is always-on) and minus the
WebSocket *server* (this app is a leaf client only). C# + WinUI 3,
MSIX-packaged, lives in this repo at `Apps/Windows/FTX1RemoteWindows/`
despite sharing no code with the Swift targets (Swift/SwiftUI isn't viable
on Windows). v1 scope is core rig control only (VFO A/B, mode, PTT, power,
SWR, band) — MENU grid, Deep Settings, waterfall/audio, and APRS decode are
deferred but not architecturally blocked (direct-to-Pi means this app,
unlike iPad, actually has the live per-item-read capability Deep Settings
needs). Full plan, protocol/model porting notes, and open items:
`Apps/Windows/README.md`. `Apps/Windows/FTX1RemoteWindows/` has a
build-verified (`dotnet build -r win-x64 --self-contained`, not yet
run against real hardware) unpackaged WinUI 3 skeleton covering the full
v1 checklist.

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
  `AudioInputDevice`/`AudioInputSettings`, and — `.remote`-mode only —
  `RemoteAudioStreamClient`) — Mac-only, see Architecture above. Dense
  multi-pane UI (`ContentView`: VFO, meters, scope display,
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
- `Apps/Windows/` — Windows app (C# + WinUI 3, remote-only, direct to the
  Pi). `FTX1RemoteWindows/` has a build-verified v1 skeleton (core rig
  control only) — see `Apps/Windows/README.md` for the full plan, porting
  notes, and the "Windows app" section above. Not built via `xcodebuild`/
  `swift build` like the other `Apps/*` targets — use `dotnet build`
  from within `Apps/Windows/FTX1RemoteWindows/` instead.
- `Pi/` — deployable Pi-side pieces, not part of any Xcode target
  (`ftx1-audiostream.py` + its systemd unit + install/verify instructions —
  see "Audio-over-Pi" above). Nothing here is built by `xcodebuild`/`swift
  build`; deploy by copying it to the Pi per `Pi/README.md`. `rigctld.
  service`/`direwolf.service` (the Pi's other two systemd units) aren't
  tracked here — they were set up directly on the Pi outside this repo.

## Working conventions

- Flag platform-specific UI tradeoffs when relevant instead of picking one
  silently — Mac/iPhone/iPad genuinely want different layouts here.
- Background server layer (rigctld connection + WebSocket server) should stay
  independent of window state — it keeps running whether or not the Mac app's
  window is open.
- When in doubt about wire protocol shape or RigState fields, check
  `Sources/FTX1Core` for the actual Codable types rather than assuming.
- Don't add high-rate state (anything updated many times a second —
  audio frames, meter samples) as `@Published` on `HubService`. It's the
  one object nearly every Mac view observes, so each publish re-renders
  the whole window; give such state its own small `ObservableObject`
  observed by exactly the leaf view that draws it (`ScopeFrameStore` is
  the precedent — see Architecture). Likewise, when adding a per-buffer
  audio path, remember Xcode runs the Debug build: a loop that's free
  under `-O` can cost a full core under `-Onone` (the palette lookup did),
  so prefer table lookups / vDSP over per-sample generic Swift in anything
  that runs 21+ times a second.
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
- Build the Windows app: from `Apps/Windows/FTX1RemoteWindows/`, `dotnet
  build -r win-x64 --self-contained` (or open the `.csproj` in Visual
  Studio). Not part of `Package.swift`/`xcodebuild` at all — separate
  toolchain, see `Apps/Windows/README.md`.
