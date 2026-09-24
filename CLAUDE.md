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
  systems live. One trap: some commands carry an on/off state as a
  multi-digit field ("BP"'s manual-notch on/off is 000/001, "CO"'s
  CONTOUR/APF on/off is 0000/0001) — `getRawBool` looks only at the first
  character after the prefix and would read those as always-off, so such
  fields go through `getRawInt` (`!= 0`) / `setRawInt(digits:)` with the
  documented width (see `IFNotch`). The filter commands (`SH`/`IS`/`BP`/
  `CO`/`NA`) take P1 = the receiver (0 MAIN, 1 SUB; Sub replies hardware-
  confirmed to mirror Main's shapes, 2026-09-19). The app addresses one
  side at a time (`RigState.filterSide`, set by `RigCommand.setFilterSide`):
  `CommandQueue` holds the selected `FilterSide` and builds the mnemonics
  from it (FIFO, so a switch followed by a control change can't race; a
  command can also be pinned to a side with `enqueue(_:filterSide:)` — the
  band-memory width replay is pinned to MAIN), the ten filter fields in
  `RigState` hold the *selected* side's values, and `HubService` clears and
  re-reads them on a switch (`refreshFilterState`) and polls only the
  selected side. Every filter view gates on `RigState.filterMode` (the
  selected side's mode), not `mode`.
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
  broadcast to mobile clients); only the raw audio is. Since 2026-09-13
  the same FFT also yields `AudioCaptureFrame.spectrum` (0–4 kHz bins,
  normalized through the waterfall's auto-gain window), published through
  `ScopeFrameStore` to the Mac-only `FilterDisplayHost`, which feeds the
  shared `FilterDisplayView` (the app's Filter Function Display) — same
  leaf-only observation rule as the scope. While SUB is the selected filter
  side, `AudioCaptureEngine` also computes a Sub-channel spectrum for that
  display (`onSubSpectrum` → `ScopeFrameStore.subSpectrum`, enabled only
  then via `setSubSpectrumEnabled`, with its own auto-gain; the FFT step is
  shared with Main's path via `fftPowerDb`/`normalizedSpectrum`). Still no
  Sub waterfall/oscilloscope (see the dual-waterfall decision below).
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
  - **Dual Main/Sub audio channels (in progress, started 2026-09-18)**: the
    FTX-1's USB audio-out is genuinely stereo whenever dual-VFO display is
    active — Main on the left channel, Sub on the right, confirmed both
    locally (2026-09-07, Loopback + Audio MIDI Setup on the Mac's own audio
    device) and directly against the Pi's raw hardware (2026-09-18,
    `arecord -D hw:1,0 -c 2` plus a channel-swap test that showed the
    separation tracks VFO reassignment, not a fixed/stuck channel). The
    app's audio pipeline was mono everywhere, and in `.remote` mode
    specifically that mono-ness wasn't even clean: `asound-ftx1.conf`'s
    `ftx1_dsnoop` slave requested `channels 1` against the 2-channel
    hardware, and that negotiation turned out to *sum* Main+Sub rather than
    cleanly pick one channel (the user reported hearing two simultaneous
    signals — NOAA weather radio + APRS bursts — in live "mono" remote
    audio). **Milestone 1 (Remote mode capture only, complete pending
    hardware validation)**: `asound-ftx1.conf`'s dsnoop slave now requests
    `channels 2`; `Pi/ftx1-audiostream.py` sends interleaved-stereo Int16LE
    (`CHANNELS = 2`); `RemoteAudioStreamClient.swift` de-interleaves it into
    two parallel `[Float]` streams; `AudioCaptureEngine.beginRemoteCapture()`
    feeds Main into the exact same `process(samples:sampleRate:bitmap:
    gain:)` entry point as before (every existing consumer — waterfall,
    APRS, FT8, Mac-local playback, iPad relay — is unchanged, now fed a
    genuinely isolated Main channel instead of a possibly-summed one) and
    logs a throttled Main/Sub RMS comparison via `os.Logger` (subsystem
    "com.ftx1remote.mac", category "audio-capture") for hardware
    verification, since nothing consumes Sub yet. Local mode
    (`AVAudioEngine` tap reading `floatChannelData?[0]`) is untouched.
    **Real risk flagged, not yet hardware-confirmed**: Direwolf's own APRS
    capture shares `ftx1_shared` (the `plug` layer over `ftx1_dsnoop`) —
    moving the dsnoop slave to a real 2-channel source means `plug` now has
    to actually downmix/select down to whatever Direwolf asks for, instead
    of trivially passing through a 1-channel source; this is untested ALSA
    behavior on this setup and needs a real APRS-decode check after
    deploying (`journalctl -u direwolf -f`), not just "service started." See
    `Pi/README.md`'s "Updating to stereo (Main/Sub) capture" for the deploy/
    verify steps. Hardware-confirmed the same day via the RMS log (Main
    dropping to near-silence while Sub held steady, and both swapping when
    `swapActiveVFO` was sent) and, separately, that Direwolf's APRS decode
    survived the `channels 2` change.
    **Milestone 2 (Sub playback, `.remote` mode only)**: Sub now has its
    own independent local-playback path on the Mac, mirroring Main's exactly
    but staying deliberately narrower in scope — capture → encode →
    playback only, no iPad relay and no APRS/FT8/`AudioRecorder` (those
    stay Main-only). `AudioCaptureEngine.onSubChannelSamples` is a new
    closure (mirrors `onAudioSamples`, `.remote`-only, hops to the main
    actor the same way) feeding a second, fully independent pair —
    `HubService.subAudioStreamEncoder`/`subAudioPlayback` (own
    `AudioStreamEncoder`/`AudioPlaybackEngine` instances, not shared with
    Main's) — with their own persisted settings
    (`AudioPlaybackSettings.subVolume`/`subSquelchThreshold`/`subIsMuted`,
    new keys, not shared with iPad). Main's equivalents were renamed for
    symmetry (`audioVolume`→`mainAudioVolume`, `squelchThreshold`→
    `mainSquelchThreshold`, `isAudioMuted`→`isMainAudioMuted`,
    `toggleAudioMuted()`→`toggleMainAudioMuted()`, `audioPlayback`→
    `mainAudioPlayback`, `audioStreamEncoder`→`mainAudioStreamEncoder`) —
    confined to `HubService.swift`/`ContentView.swift`, no ripple into
    iPad (which reaches its own `AudioPlaybackEngine` directly, never
    through `HubService`). Mute is per-channel as decided (two independent
    toggles, `isMainAudioMuted`/`isSubAudioMuted`). `ContentView` shows Sub's
    mute button and SQL/VOL sliders — originally `.remote` mode only, since
    extended to `.local` too (see "Local mode Main/Sub parity" below). Both
    playback engines write to the same Mac output device
    (`AudioOutputSettings.deviceUID`); running two independent
    `AVAudioEngine` instances against one device simultaneously is ordinary
    macOS behavior, not new territory.
    **Deliberately not yet built** (future milestones, each independently
    committable/testable like the six filter controls were): no
    `RigController` protocol changes, no FT8 decoding or frequency-gating
    from the Sub channel. (The Mac→iPad wire-protocol stereo extension
    originally listed here is done — see "Mac→iPad Sub audio relay"
    below.)
    **Dual waterfall/oscilloscope — decided against for now (2026-09-18)**,
    not just deferred: the FTX-1's own physical display only ever shows a
    waterfall/scope for the Main VFO, even in dual-VFO mode — there's no
    rig-side precedent for a Sub-channel one, so adding one here would be
    inventing a display the actual hardware doesn't have, not achieving
    parity with it (unlike everything else in this section, which mirrors
    real rig behavior). Still one shared `ScopeFrameStore`, Main-only.
    Noted as a possible future enhancement if ever wanted, but not planned
    — don't pick this up without being asked again.
  - **Sub-channel APRS decoding (2026-09-18, hardware-confirmed)**: a
    second, fully independent `APRSDecoder` instance
    (`HubService.aprsDecoderSub`) is now fed from `onSubChannelSamples`,
    gated on `rigState.secondaryFrequencyHz` against the same global
    `APRSSettings` frequency/tolerance the Main gate uses (no separate
    Sub frequency setting — real use is one calling frequency, parked on
    whichever VFO). Safe to run alongside the Main decoder since
    `AFSKDemodulator`/`AX25FrameDecoder` (`Sources/FTX1Core/APRS/`) are
    value-type structs with no shared state. Decoded stations/messages
    stay in the single shared `APRSStore` rather than forking into a
    second store/window set — `APRSStation`/`APRSMessage` gained a
    `source: APRSSource` (`.main`/`.sub`) field instead, upserted (not
    part of the upsert key — a station heard on both channels is one row,
    tagged with whichever channel heard it most recently) and surfaced as
    a Source column + segmented filter in `APRSStationListView`/
    `APRSMessageListView`, and as marker tint (blue/orange) in
    `APRSMapView`. `APRSStation`/`APRSMessage` decode `source` via
    `decodeIfPresent(...) ?? .main` specifically so pre-existing
    `aprs-history.json` files (all genuinely Main-only) keep loading
    rather than getting silently dropped by `APRSPersistence.load()`'s
    `try?` on a newly-required field. `RigState` gained `aprsSubActive`/
    `aprsSubLastCallsign` (mirroring the pre-existing Main-only
    `aprsActive`/`aprsLastCallsign`), computed in `refreshFastTier` against
    a second, independent `aprsLastCallsignHeardSub` tracker (same 5-second
    expiry as Main's) and gated on `secondaryFrequencyHz` rather than
    `frequencyHz`. `RigStatePush` needed no wire-format change since it
    already serializes the whole `RigState`. The shared `VFODisplayBox`
    (`Sources/FTX1Core/UI/`) already supported an `aprsActive`/`callsign`
    indicator — added earlier for Main only, never wired to the SUB box —
    so both Mac's and iPad's `ContentView` SUB `VFODisplayBox` call sites
    just needed the same `aprsSubActive ? aprsSubLastCallsign : nil`
    pattern Main's MAIN box already used.
  - **Local mode Main/Sub parity (2026-09-18, hardware-confirmed)**:
    `.local` mode's `AVAudioEngine` tap now extracts a genuine Sub channel
    too, same as `.remote` already did — `process(buffer:bitmap:gain:)`
    reads `buffer.floatChannelData[1]` and calls `deliverSubChannelSamples`
    whenever `buffer.format.channelCount >= 2`. A mono input device just
    never triggers this — no separate "is Sub actually available" flag
    anywhere, every downstream consumer (`subAudioPlayback`,
    `aprsDecoderSub`) is already written to sit idle rather than assume Sub
    exists. Because `HubService`'s entire Sub-channel wiring (playback,
    squelch/volume/mute, independent APRS decode/gate) was already keyed
    off `AudioCaptureEngine.onSubChannelSamples` firing at all — not off
    `RigctldSettings.connectionMode` — none of that code needed to change;
    only `AudioCaptureEngine`'s local-tap extraction and `ContentView`'s
    `.remote`-only UI gates (removed — Sub's mute button and SQL/VOL
    sliders now always show, same "harmless if inert" reasoning as the
    playback engine) did.
    **Real bug hit and fixed during hardware validation**: first pass
    landed with `installTap(..., format: nil)` unchanged (as `.remote`'s
    equivalent extraction pattern implied it should stay), and Sub came
    back silent even with the correct 2-channel device ("FTX-1 Audio", a
    Rogue Amoeba Loopback device) genuinely selected in Settings — traced
    with two rounds of diagnostic `os.Logger` lines (device resolution +
    `AudioUnitSetProperty` status, then `inputFormat(forBus:)` vs.
    `outputFormat(forBus:)` channel counts) to a real `AVAudioEngine`
    quirk: `inputNode.inputFormat(forBus: 0)` correctly tracked the
    switched-to device (2 channels), but `outputFormat(forBus: 0)` — the
    side `installTap`'s `format: nil` actually binds to — stayed pinned at
    1 channel, apparently inherited from whatever the engine's graph was
    originally built against (this Mac's system-default input, the mono
    built-in mic) and never updated by the `kAudioOutputUnitProperty_
    CurrentDevice` switch. Fixed by passing `inputNode.inputFormat(forBus:
    0)` to `installTap` explicitly instead of relying on `nil` —
    `AVAudioEngine` inserts its own conversion as needed, same as any other
    explicit tap format. Confirmed fixed: Console showed `channels=2` after
    the fix (vs. `channels=1` before, both with the identical device
    selected and `AudioUnitSetProperty` reporting success both times), and
    the user confirmed Sub audibly independent. Worth remembering for any
    future `AVAudioEngine` input-device work in this app: `outputFormat
    (forBus:)`/`format: nil` cannot be trusted to reflect a `CurrentDevice`
    switch — always read `inputFormat(forBus:)` after `prepare()` and pass
    it explicitly.
    **Not yet done**: FT8/AudioRecorder still
    Main-only in both modes (unchanged scope, not a Local-mode gap), and
    the "not yet built" list above (`RigController` protocol) applies
    equally to both modes now.
  - **Mac→iPad Sub audio relay + mute buttons (2026-09-18, build-verified
    on iPad Simulator, not yet hardware-tested against a real Mac↔iPad
    link)**: extends the existing Main-only Mac→iPad audio relay to carry
    Sub too, and adds mute buttons to iPad's audio controls for the first
    time (there were none before this, Main included). `AudioStreamFormat`
    (`Sources/FTX1Core/Audio/`) gained a second tag byte, `subAudioTag =
    0x01`, alongside the existing `audioTag = 0x00` — two independently-
    tagged mono 8kHz frame streams, not one interleaved-stereo stream like
    the Pi's wire format, deliberately: reusing `AudioStreamEncoder`/
    `AudioPlaybackEngine` twice (both already hardcoded mono) is far lower
    risk than rewriting either to handle real stereo, and mirrors the
    capture side's own "two fully parallel mono pipelines" shape. `RigWebSocketServer.broadcastSubAudio(_:)` (Mac) mirrors
    `broadcastAudio(_:)`; `HubService`'s `onSubChannelSamples` now relays
    unconditionally, same as the Main tap. `RigWebSocketClient` gained
    `onSubAudioData`/`setOnSubAudioData` and an `isSubAudioFrame` check in
    `handle(_:)`, both mirroring the Main equivalents exactly.
    `RigClientViewModel` (shared by iOS/iPadOS) gained a second
    `subAudioEngine: AudioPlaybackEngine` instance and
    `isMainAudioMuted`/`isSubAudioMuted` (`@Published private(set)` +
    `toggleMainAudioMuted()`/`toggleSubAudioMuted()`, same shape as
    `HubService`'s Mac-side properties, persisted via the same
    `AudioPlaybackSettings.isMuted`/`subIsMuted` keys `HubService` already
    established — each device's `UserDefaults` is independent, per that
    enum's own doc comment, so this is "same key names," not literal
    cross-device sync) — mute gates whether `setOnAudioData`/
    `setOnSubAudioData`'s closures push into the relevant engine, doesn't
    stop/start it, same reasoning as the Mac-side toggle methods. No
    `RigController` protocol changes needed: like the Mac's `HubService`
    audio properties, these are reached directly via the concrete
    `RigClientViewModel` type from iPad's `ContentView`, never through the
    protocol.
    iPad's `ContentView.swift` `audioControls` now renders two
    `channelAudioControls(...)` columns, Sub-then-Main left-to-right
    (matching the SUB/MAIN `VFODisplayBox` row above it, same convention as
    the Mac's own audio-controls row), each with a mute button + volume/
    squelch sliders; volume/squelch stay `@AppStorage`-bound (renamed
    `audioVolume`/`audioSquelchThreshold` → `mainAudioVolume`/
    `mainAudioSquelchThreshold` for symmetry with the new `subAudioVolume`/
    `subAudioSquelchThreshold`), only mute reaches into `viewModel`.
    Verified in the iOS Simulator (iPad Pro 11-inch, built via `xcodebuild
    -scheme FTX1RemoteiPad`, driven via `mcp__Claude_Code_iOS_Simulator__
    control`): layout renders correctly, both mute buttons toggle
    independently. Not yet tested against a live Mac connection — that
    needs a real device or a Mac-side rebuild plus a live WebSocket link,
    neither available in that verification pass. All three app targets
    (Mac, iPad, iOS) build clean against the shared `RigClientViewModel`/
    `AudioStreamFormat` changes.

  - **Swap tracking — audio follows the swap (2026-09-19, hardware-tested,
    one known gap)**: user-reported bug — after a Main/Sub swap
    (the app's `SV` swap button, or the rig's front-panel swap) the
    frequencies/modes followed but the audio did not: the rig's L/R USB
    channels evidently stay with the physical receiver, so the Main-role
    audio (waterfall, Main mute/volume/squelch, the Main APRS gate, FT8's
    dial frequency, the iPad relay) kept playing the *other* VFO's signal.
    Fix: `HubService.audioChannelsSwapped` (persisted via
    `AudioPlaybackSettings.channelsSwapped`) tracks the L/R↔Main/Sub
    parity and is pushed to `AudioCaptureEngine.setChannelsSwapped`, which
    exchanges the two channels *before* anything downstream sees them, in
    both the `.local` tap and the `.remote` client closure — so every
    consumer follows automatically and none needed to change. The flag
    flips on (1) `applyOptimistically(.swapActiveVFO)`, (2)
    `trackExternalSwap`, a heuristic for front-panel swaps: both polled
    frequencies exchange at once relative to the last pair where they
    differed (baseline reset by app tuning commands and Memory-mode polls;
    equal-frequency swaps are unobservable), and (3) a manual override
    button (speaker icon next to the swap button, orange while swapped).
    The rig exposes no readout of the true mapping, hence the heuristic and
    the override; a swap made while the app wasn't running is why the flag
    persists across launches. Each flip logs to Console (subsystem
    "com.ftx1remote.mac", category "audio-routing"), and the `stereo check`
    line now includes `swapped=`. **Hardware results (user, 2026-09-19)**:
    dual-VFO swap via the app, dual-VFO swap on the radio, and single-VFO
    swap on the radio all worked with no intervention. **Single-VFO gap, fixed and confirmed
    (2026-09-19)**: the app's `SV` swap doesn't move the L/R audio while the
    rig is in single-receive display (a front-panel swap does, and is
    caught by `trackExternalSwap`), so `applyOptimistically` skips the flip
    then. The display mode comes from the raw "FR" (FUNCTION RX) CAT
    command — 00 dual, 01 single, hardware-confirmed to match the rig —
    read in the slow tier into `RigState.singleReceive` (`nil` until read,
    treated as dual); each change logs `FR reply …` under
    "audio-routing". **Still unverified**: that the mapping really is a simple parity flipped by each
    swap; that `VS` (active-side select) doesn't move the audio; and how
    the rig routes audio in single-VFO display while swapped.

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

## Sparkle updates (Mac only, in progress, 2026-09-22)

Mac-app auto-update via [Sparkle](https://sparkle-project.org). Mac-only —
iOS/iPadOS ship through the App Store (or TestFlight/sideloading), which
manage their own updates; Sparkle doesn't apply there and isn't linked into
those targets.

- **Distribution: Developer ID + notarization, not the Mac App Store.**
  Team `9MAKNY2JX8` has a paid Apple Developer Program membership, so
  releases are signed with a "Developer ID Application" certificate and
  notarized via `notarytool`, not sandboxed/submitted through App Store
  Connect. `Scripts/ExportOptions.plist` (`method: developer-id`) is the
  export config; `ENABLE_APP_SANDBOX = NO` on the Mac target (see
  Architecture above) was already the case for unrelated reasons and is a
  prerequisite here too — a sandboxed app can't self-replace the way
  Sparkle needs to without an XPC helper, which this setup deliberately
  avoids.
- **Hosting: GitHub Releases**, since the repo (`captobie/ftx1-remote`) is
  already public. `appcast.xml` lives at the repo root and is committed to
  `main`; `SUFeedURL` (an `INFOPLIST_KEY_SUFeedURL` build setting on the Mac
  target only, both Debug/Release configs) points at
  `raw.githubusercontent.com/captobie/ftx1-remote/main/appcast.xml`. The
  notarized `.zip` for each version is a GitHub Release asset (not
  committed to git — `/releases/` and `/build/` are gitignored), referenced
  from `appcast.xml`'s `<enclosure url>` by its stable release-download URL.
- **`Scripts/release-mac.sh`** does the whole release: `xcodebuild archive`
  → export (Developer ID) → zip → `notarytool submit --wait` → staple →
  re-zip → `generate_appcast` (Sparkle's own tool; finds the EdDSA key in
  Keychain and signs each appcast entry itself, no key material in the
  script or repo) → moves the regenerated `appcast.xml` to the repo root.
  Prints the two manual follow-ups it deliberately doesn't automate:
  committing/pushing `appcast.xml`, and `gh release create` to upload the
  zip (kept manual so release notes are always hand-written, not
  templated).
- **`CheckForUpdatesView`/`CheckForUpdatesViewModel`**
  (`Apps/Mac/FTX1RemoteMac/CheckForUpdatesView.swift`) is Sparkle's own
  documented SwiftUI pattern — bridges `SPUUpdater.canCheckForUpdates`
  (KVO, not `@Published`) into a view model so the menu item's disabled
  state follows it. Wired into `FTX1RemoteMacApp`'s `.commands` via
  `CommandGroup(after: .appInfo)`. `AppDelegate` owns the
  `SPUStandardUpdaterController` (`startingUpdater: true` — background
  checks start automatically on launch, gated by Sparkle's own first-run
  permission prompt, not app code) alongside `hub`, matching the existing
  "AppDelegate owns the long-lived services" shape.
- **Done since scaffolding, 2026-09-22** (see chat history for the full
  walkthrough): `generate_keys` run, real public key
  (`Xu1kV/OxMn0Yx53Wslwdo7zjYDUyiOqjK1a84j33YSk=`) is in
  `INFOPLIST_KEY_SUPublicEDKey` on both Mac configs; `notarytool
  store-credentials` done for the `ftx1remote-notary` profile
  `Scripts/release-mac.sh` expects; Developer ID Application certificate
  confirmed present in Keychain. **`brew install sparkle` doesn't work —
  Homebrew disabled that cask 2026-09-01 (fails Gatekeeper) — don't retry
  it.** Instead `generate_appcast`/`sign_update`/`BinaryDelta` came from
  Sparkle's own release zip (same one `generate_keys` was extracted from),
  relocated from `~/Downloads` to
  `~/Library/Application Support/Sparkle-CLI/Sparkle-2.10.0/` (a stable,
  non-cleaned-up path), quarantine-cleared, and symlinked into
  `/opt/homebrew/bin` so they're on PATH for `Scripts/release-mac.sh`.
- **Sparkle SPM package added 2026-09-22**, with one wrinkle: adding it via
  Xcode's File → Add Package Dependencies only created the
  `XCRemoteSwiftPackageReference` at the project level — it did *not*
  attach the `Sparkle` product to the `FTX1RemoteMac` target (Xcode UI
  quirk, not user error; the target's `packageProductDependencies` stayed
  `FTX1Core`/`FT8Kit` only, hence the initial "Unable to resolve module
  dependency: 'Sparkle'" build failure). Fixed by hand-adding the missing
  `XCSwiftPackageProductDependency` + `PBXBuildFile` + Frameworks-phase +
  `packageProductDependencies` entries, mirroring the existing
  `FTX1Core`/`FT8Kit` pattern exactly (safe to do by hand once the
  `XCRemoteSwiftPackageReference` itself already exists and just needs
  wiring to a target — the earlier caution above was about fabricating the
  package reference/checksum from scratch, which is the part that
  genuinely needs Xcode). Also needed two explicit imports the project's
  `MemberImportVisibility` upcoming-feature flag requires: `import Combine`
  in `CheckForUpdatesView.swift` (for `@Published`) and `import Sparkle` in
  `FTX1RemoteMacApp.swift` itself (for `.updaterController.updater`), even
  though both were already transitively visible. `Sparkle.framework`
  confirmed embedded in the built `.app`'s `Contents/Frameworks/`. Full Mac
  target build (`xcodebuild ... -scheme FTX1RemoteMac`) green.
- **First `Scripts/release-mac.sh` run, two real issues hit (2026-09-22):**
  1. **Keychain kept re-prompting for the Developer ID Application private
     key during export**, even after entering the correct login password
     repeatedly. Not a wrong password — it's macOS asking fresh
     authorization for a signing identity being used from this
     non-interactive `xcodebuild`-driven path for the first time; clicking
     **Always Allow** (not just Allow) on the prompt resolved it for that
     and subsequent runs. If it recurs, the fix is
     `security set-key-partition-list -S apple-tool:,apple:,codesign: -s
     ~/Library/Keychains/login.keychain-db`, which grants `codesign`
     standing access to the key without prompting.
  2. **Notarization returned `status: Invalid`** (`statusCode: 4000`,
     `xcrun notarytool log <submission-id> --keychain-profile
     ftx1remote-notary` showed `"The executable does not have the hardened
     runtime enabled."` for both architectures) — `ENABLE_HARDENED_RUNTIME`
     was never set anywhere in `project.pbxproj`. This is a distinct
     setting from `ENABLE_APP_SANDBOX` (deliberately `NO`, see
     Architecture above) — Apple requires Hardened Runtime specifically
     for Developer ID notarization, independent of sandboxing. Fixed by
     adding `ENABLE_HARDENED_RUNTIME = YES` to the Mac target's Debug and
     Release configs (iOS/iPad untouched, same scoping approach as the
     `SUFeedURL`/`SUPublicEDKey` keys above). No entitlements file was
     needed on top of that — `Sparkle.framework` is embedded via Xcode's
     own "Embed & Sign" step, which re-signs it under the app's own
     Developer ID identity, so Hardened Runtime's library-validation
     requirement (loaded code must share the host app's Team ID) is
     already satisfied without `com.apple.security.cs.disable-library-
     validation`.
  3. **`generate_appcast` silently produced an unsigned `<enclosure>`**
     (no `sparkle:edSignature` at all, no error) even though `sign_update`
     run standalone against the same zip worked fine and the EdDSA key was
     confirmed present and matching in Keychain. Root cause:
     `INFOPLIST_KEY_SUFeedURL`/`INFOPLIST_KEY_SUPublicEDKey` — the build
     settings the first Sparkle scaffolding pass added — never actually
     reached the compiled `Info.plist` (`PlistBuddy -c "Print
     :SUPublicEDKey" .../FTX1RemoteMac.app/Contents/Info.plist` came back
     empty), so `generate_appcast` correctly saw the app as not requesting
     signed updates and skipped signing. This target's
     `GENERATE_INFOPLIST_FILE = YES` is paired with a real physical
     `INFOPLIST_FILE` (`FTX1RemoteMac-Info.plist`, holding the
     `NSAppTransportSecurity` exception) — Xcode's `INFOPLIST_KEY_*`
     build-setting synthesis only merges its own "blessed" keys (the ones
     with dedicated Xcode Info-tab UI, e.g. `NSMicrophoneUsageDescription`,
     which *did* make it through) on top of a physical base file; arbitrary
     custom keys like `SUFeedURL`/`SUPublicEDKey` are silently dropped in
     that combination. Fixed by moving both keys directly into
     `FTX1RemoteMac-Info.plist` itself (same file `NSAppTransportSecurity`
     already lives in) and removing the now-dead
     `INFOPLIST_KEY_SUFeedURL`/`INFOPLIST_KEY_SUPublicEDKey` build
     settings from `project.pbxproj` so they don't mislead a future reader
     into thinking that's the source of truth. **Lesson for any future
     custom (non-Apple-standard) Info.plist key on this target**: don't
     add it as an `INFOPLIST_KEY_*` build setting — add it to
     `FTX1RemoteMac-Info.plist` directly, and verify with
     `PlistBuddy -c "Print :<Key>" <built .app>/Contents/Info.plist`
     against the actual built product, not just `-showBuildSettings`
     (which shows the setting as "set" even when it never reaches the
     compiled plist).

  Confirmed clean end-to-end after all three fixes: built `Info.plist` has
  both keys, notarization `status: Accepted`, stapling succeeded, and
  `appcast.xml`'s `<enclosure>` carries a real `sparkle:edSignature`.

## Digital modes — FT8 (2026-09-14)

First digital mode, built with more (FT4 most likely next) explicitly in
mind. Mac-only, like the waterfall — audio-derived, and the iOS/iPadOS
targets don't need the extra C dependency this pulls in. Opened via a new
top-level **Digital** menu bar item (`CommandMenu`, a genuine sibling of
File/Edit/View — not nested under an existing menu the way the APRS
submenu is) → **FT8**, which opens its own `Window(id: "ft8")`, same
pattern as the APRS windows.

- **Decode engine: vendored `kgoba/ft8_lib` (MIT) + kissfft (BSD-3-Clause)
  as a C target**, not a from-scratch Swift LDPC/Costas implementation —
  deliberate: LDPC(174,91) belief-propagation decode and Costas-array sync
  are the same class of problem WSJT-X spent years maturing, not something
  worth re-deriving. `Sources/CFT8Lib/` mirrors upstream's `ft8/`/`common/`/
  `fft/` tree exactly (decode-only subset — no `encode.c`, no
  PortAudio/WAV demo I/O); `Sources/FT8Kit/` is the Swift wrapper
  (`FT8Decoder`, `FT8Mode`, `FT8Message`, `FT8CallsignHashStub`), a new SPM
  product alongside `FTX1Core` in the same `Package.swift`, kept as a
  *separate* target/product specifically so the iOS/iPadOS builds (which
  also depend on `FTX1Core`) don't carry it. Licenses preserved at
  `Sources/CFT8Lib/LICENSE-ft8lib.txt` and
  `Sources/CFT8Lib/fft/LICENSE-kissfft.txt`; see the repo README's
  "Third-party code" section.
  - `CFT8Lib`'s `publicHeadersPath` had to be set to `"."` explicitly —
    SwiftPM's default C-target convention expects a separate `include/`
    dir, which upstream's tree doesn't have (headers sit next to their
    `.c` files, and `common/monitor.c` includes `<ft8/decode.h>`
    root-relative while `ft8/decode.c` includes `"constants.h"`
    same-directory — both need the whole target dir on the header path).
  - `common/monitor.c` hardcodes `#define LOG_LEVEL LOG_INFO` before
    including its own `debug.h`, so upstream always logs "Block size = …"
    etc. to stderr on every `monitor_init` (harmless for ft8_lib's own CLI
    demo, not for a decoder running every 15s here). Silenced via a build
    flag (`-DLOG_PRINTF(...)=` in `CFT8Lib`'s `cSettings`), not by editing
    the vendored source.
  - **12000 Hz mono is the sample rate ft8_lib actually expects**
    (confirmed by hex-dumping a real reference WAV header, not assumed) —
    this app captures at 44100 Hz (see Audio-over-Pi above), so
    `Apps/Mac/FTX1RemoteMac/FT8Resampler.swift` wraps one long-lived
    `AVAudioConverter`, reused across chunks so its internal filter state
    doesn't discontinuity at chunk boundaries — validated in
    `Tests/FT8KitTests/FT8ResampleFidelityTests.swift` by streaming a
    44100 Hz-upsampled reference vector back through the same
    resample-in-2048-sample-chunks approach and confirming it still
    decodes.
  - `monitor_process()` requires exactly `sample_rate × FT8_SYMBOL_PERIOD`
    (1920 at 12000 Hz) samples per call — `FT8DecodeCoordinator` buffers
    resampled audio and slices off exact blocks, remainder carried to the
    next `ingest` call.
- **Decode trigger: tied to the Digital/FT8 window's lifecycle, not
  always-on.** Unlike `APRSDecoder` (always running, gated by VFO
  frequency matching one configured APRS frequency), FT8 has no single
  fixed frequency to gate on — `FT8DecodeCoordinator.start()`/`stop()` are
  called from `FT8ListView`'s `.onAppear`/`.onDisappear`
  (`HubService.startFT8Decoding()`/`stopFT8Decoding()`), not from
  `HubService.start()`/`init` the way `aprsDecoder` is wired.
  `HubService.stop()` also calls `stopFT8Decoding()` as a safety net if
  the app quits with the window open. `FT8DecodeCoordinator.ingest(...)` is
  always called from `HubService`'s audio tap (no frequency gate), but
  it's a cheap no-op whenever not running.
- **UTC 15-second slot scheduling** — a `DispatchSourceTimer` ticking
  every ~0.5s detects crossing a `:00/:15/:30/:45` boundary
  (`Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 15)`
  wrapping back down), finalizes the just-completed slot's decode, and
  starts a fresh `FT8Decoder` for the next slot. Assumes the Mac's clock
  is NTP-synced (same assumption WSJT-X itself makes) — not verified by
  the app; flagged for the real-hardware validation pass below.
- **`FT8Spot`** (`Apps/Mac/FTX1RemoteMac/FT8Spot.swift`) carries the
  frequency (dial-at-slot-start + audio offset), SNR (explicitly
  doc-commented as ft8_lib's own `score × 0.5` approximation, not a
  calibrated noise-floor SNR — its own upstream source marks this exact
  computation `// TODO: compute better approximation of SNR`), and
  parsed callsign/grid/report fields, plus `reporterCallsign`/
  `reporterGrid` from the new `StationSettings` (`Sources/FTX1Core/Station/`
  — the operator's own callsign/grid, which nothing in the app stored
  before this) — carried specifically for a **future PSK Reporter
  uploader, not built yet**. `FT8Store` (session-only, no disk
  persistence unlike `APRSStore`) is a separate `ObservableObject`
  exposed as a plain `let` on `HubService`, same "don't `@Published` it
  on `HubService` itself" isolation as `ScopeFrameStore`/`APRSStore` —
  spots arrive in bursts of up to a few dozen per ~15s cycle.
- **Extensibility for FT4/future modes deliberately minimal, not
  speculative**: upstream already shares the same LDPC(174,91) code and
  `ftx_protocol_t`/slot-timing constants between FT4 and FT8
  (`FT8Kit.Mode` wraps both), so adding FT4 later is parameterizing
  `FT8DecodeCoordinator`/widening `FT8Store` and adding a sibling
  `Window(id: "ft4")` + `CommandMenu` button — not a redesign. Names stay
  FT8-specific today rather than a premature `DigitalMode`/`DigitalStore`
  abstraction for a single mode.
- **Verification status**: `Tests/FT8KitTests/FT8ReferenceVectorTests.swift`
  passes real off-air FT8 captures (vendored from ft8_lib's own
  `test/wav/`) through the real wrapper and checks against what ft8_lib's
  own reference `decode_ft8` demo (built standalone from the same upstream
  checkout, to get real ground truth) decodes from the same files — not
  against the vendored `.txt` truth files verbatim, since those include a
  couple of weak-signal messages this library's default candidate search
  doesn't reach either (a library sensitivity limit, not a wrapper bug;
  see that test file's doc comment). `FT8ResampleFidelityTests.swift`
  covers the 44100→12000 streaming resample path. The full Mac app target
  builds clean via `xcodebuild` with `FT8Kit` linked (iOS target
  unaffected, confirmed by also building it). **Not yet done**: real FT8
  sub-band hardware validation against live traffic (compare against
  WSJT-X on the same audio, soak test, confirm NTP-clock assumption,
  check `.remote`/Pi audio timing specifically) — same shape as every
  other CAT/audio feature's hardware-validation step in this project.

## WebSDR follow (v1, KiwiSDR only, 2026-09-24)

Digital → **WebSDR** opens `Window(id: "websdr-follow")` (Mac-only): an
embedded KiwiSDR (`KiwiWebView`, a `WKWebView` `NSViewRepresentable`) that
retunes to follow the rig's Main VFO. One direction only (rig → Kiwi).

- **Follows `hub.$rigState`**, not a new poll path — the same value every
  `server.broadcast(rigState)` sends to WebSocket clients (there's no
  separate publisher; broadcasts are imperative calls after mutating the
  `@Published` `rigState`). `WebSDRFollowModel` maps it to (frequencyHz,
  mode), `removeDuplicates`, 400 ms `debounce` — which also absorbs the fast
  tier's separate frequency/mode writes. Own `ObservableObject`, so it never
  re-renders `ContentView`.
- **URL shape verified against a live Kiwi's `kiwisdr.min.js` (v1.578)**:
  `/?f=<kHz with 2 decimals><mode token>` — the Kiwi's own "copy frequency
  link" format. Omitting the mode falls back to the Kiwi's stored
  `last_mode` (live-tested), which is how unmapped modes (RTTY, DATA-FM,
  C4FM) leave the mode unchanged. Zoom is never sent. DATA-U → `usb`
  (user decision), FM → `nbfm`. Logic + mapping in `KiwiSDRURLBuilder`.
- Every retune is a full page reload (Kiwi reconnect, brief audio gap);
  identical URLs are skipped. Above 30 MHz, not retuned — status line says
  so. `mediaTypesRequiringUserActionForPlayback = []` + WebKit's default
  persistent store: confirmed a reload keeps the Kiwi's saved name and
  shows no click-to-start overlay, and that a Kiwi which rejects a second
  connection from the same IP accepted the reload (only a genuinely
  concurrent session, e.g. a browser tab, trips that).
- **Connect/Disconnect button; the window always opens disconnected** (public
  Kiwis have few listener slots). Disconnect and window close both set
  `pageRequest` to nil, which navigates the `WKWebView` to about:blank —
  that page unload is what closes the Kiwi's WebSockets. Closing the window
  runs `.onDisappear(perform: model.disconnect)`; `dismantleNSView` does the
  same unload as a backstop. The `onDisappear` path is the one that
  matters: SwiftUI reuses the `Window` scene's NSWindow on reopen (same
  window ID), so dismantling can't be relied on. Verified with `netstat`
  against the Kiwi's IP (`lsof` can't see WebKit's networking process): 2
  ESTABLISHED sockets while connected, none after Disconnect or close;
  minimizing correctly keeps them open.
- **Hardware-confirmed on the real rig (user, 2026-09-24)**: retunes
  follow the FTX-1. v1.1 seams are noted in comments: click-to-tune back, JS-injection retune, mute-on-TX,
  Sub following, other WebSDR platforms, favorites, per-Kiwi range from
  `/status`.

## Structure

- `Sources/FTX1Core/` — Swift Package Manager package (target `FTX1Core`,
  repo root `Package.swift`): platform-agnostic.
  - `RigState/` — `RigState`/`RigMode` (shared state model), `BandPlan`
    (band table + frequency lookup), `FilterWidthTable` (CAT manual Table
    5: the raw "SH" WIDTH index → Hz mapping, keyed by `RigMode` since the
    same index means a different bandwidth per mode), `IFShift` (the raw
    "IS" IF SHIFT value space, ±1200 Hz in 20 Hz steps: clamp/snap +
    label), `IFNotch` (the raw "BP" manual-notch value space, 10-3200 Hz
    in 10 Hz steps, wire-code ↔ Hz conversion), `FilterPassbandModel` (the
    Filter Function Display's geometry: passband/notch/contour/APF on a
    fixed 0–4 kHz span from `RigState`, with per-mode center conventions
    documented as an illustration, not a CAT readback), `IFContour` (the raw "CO"
    CONTOUR + APF value spaces — CONTOUR 10-3200 Hz, APF −250…+250 Hz as a
    0000-0050 code — plus `face(for:)`, which picks CONTOUR or APF for a
    mode since the manual says they're mutually exclusive: APF CW-only,
    CONTOUR not in CW), `FilterSide` (MAIN/SUB — the CAT P1 digit the
    filter commands take; `RigState.filterSide`/`filterMode` say which
    receiver the filter fields, controls and display currently address).
  - `Appearance/` — `AppTheme` (Light/Dark/Auto), `ButtonValueColor` (MENU
    grid button value color), `AppearanceSettings` (the `@AppStorage` keys
    both are read/written through) — shared so any future app target reads
    the same settings the Mac's Settings sheet writes.
  - `Station/` — `StationSettings`: the operator's own callsign/grid
    square, `UserDefaults`-backed same as `AppearanceSettings`. Added for
    FT8 (`FT8Spot`'s `reporterCallsign`/`reporterGrid`, for a future PSK
    Reporter uploader), lives here rather than the Mac app target on the
    same "future app target will want it too" reasoning as `Appearance/`.
  - `Networking/` — `WireMessage` (`RigCommand`/`RigStatePush`, the JSON wire
    protocol), `RigctldClient` (Mac-only, TCP to rigctld, incl. raw CAT
    passthrough — note `getRawInt` is digit-only, so signed CAT values like
    "IS" get their own dedicated get/set pair, `getIFShiftHz`/
    `setIFShiftHz`, following the `getSpectrumScopeLevel` precedent), `RigWebSocketClient` (WS client, used by mobile and — for
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
    Mac and iPad), laid out as three fixed rows so nothing can resize the box or
    move the frequency: (1) tag row — MAIN/SUB, TXRX/RX, then (Memory mode
    only) a separate "CH n TAG" box, with the mode box at the right edge;
    (2) reflector/APRS indicator line, height reserved even when empty;
    (3) decoded callsign on the left (24pt, fixed size, never scaled) and
    the frequency on the right (36pt, fixed size, never scaled; shows
    `-- . --- . ---` when nil or 0, i.e. before the first read). Don't add
    `minimumScaleFactor`/flexible frames to the callsign or frequency — an
    earlier version did, and a callsign appearing squeezed the tags and
    shrank the frequency. SUB's memory channel/tag come from
    `RigState.subVfoMemoryMode`/`subMemoryChannel`/`subMemoryChannelTag`
    (read via "VM1"/"MC1", display-only; P1=1 addressing hardware-confirmed
    2026-09-20 when SUB showed "CH 1 Pi-STAR"), `SMeterView` (the analog S/SWR meter face, used by Mac
    and iPad), `FilterWidthControl` (IF WIDTH picker + narrower/wider
    steppers), `IFShiftControl` (IF SHIFT slider + center button,
    command sent on drag release, not per tick) and `IFNotchControl`
    (manual-notch on/off button + frequency slider; dragging while off
    also turns it on), `ContourAPFControl` (one slot that shows CONTOUR
    or APF depending on mode, same toggle + slider shape) and
    `NarrowControl` (the N/W narrow on/off button; the only width control that
    works in AM/FM, and `HubService` re-reads "SH0" right after a NAR
    write so the Width readout follows within ~2 s — note that in SSB/CW/
    RTTY/DATA the rig's "SH" index does *not* change with NARROW, the real
    bandwidth is the mode's NAR WIDTH menu preset, which the slow tier reads
    via `NarrowWidthPreset` into `RigState.narrowWidthHz` for the display),
    and `FilterDisplayView`
    (the Filter Function Display: `Canvas` drawing of `FilterPassbandModel`
    over an optional normalized spectrum, `[]` on targets without audio) and
    `FilterSideSelector` (the MAIN/SUB buttons just left of the display
    that pick which receiver the controls and the display address; SUB is
    disabled in single-receive display) —
    all generic
    over `RigController` like `MenuPageView`, all living in the Mac
    `ContentView`'s two "Filter" rows under the Band/Mode pickers
    (WIDTH/SHIFT on the first, CONTOUR-or-APF, N/W and NOTCH on the
    second, with `FilterDisplayHost` — Mac-only, `Apps/Mac/` — on the right
    spanning both rows, the `FilterSideSelector` between the two) (the rig
    keeps these on the MAIN-knob function menu, not the MENU grid, so
    they're not `MenuPageView` buttons), placed only on the Mac so far but
    deliberately built shared because the iPad is the planned next
    placement. Only put
    a view here once it's actually needed on more than one target — `FrequencyDisplay` (iOS's single-VFO readout) stays in the
    iOS app target since nothing else uses it.
- `Sources/CFT8Lib/` — vendored decode-only subset of `kgoba/ft8_lib` (MIT)
  + kissfft (BSD-3-Clause), a separate SPM C target (own `Package.swift`
  entry, `publicHeadersPath: "."`) — see "Digital modes — FT8" above.
  Mirrors upstream's `ft8/`/`common/`/`fft/` tree exactly; not hand-edited
  (build-flag workarounds instead, e.g. the `LOG_PRINTF` no-op — see
  above) so future re-vendoring from upstream stays a straight file copy.
- `Sources/FT8Kit/` — Swift wrapper around `CFT8Lib` (`FT8Decoder`,
  `FT8Mode`, `FT8Message`, `FT8CallsignHashStub`), a separate SPM product
  from `FTX1Core` specifically so iOS/iPadOS builds don't carry it.
  `Tests/FT8KitTests/` (reference-vector + resample-fidelity tests, plus
  vendored WAV fixtures in `Resources/`) is the only automated coverage
  for the FT8 feature — everything downstream of this (the Mac app's
  `FT8DecodeCoordinator`/`FT8Resampler`/`FT8Store`/`FT8Spot`/`FT8ListView`)
  lives in the Xcode-project Mac target, which — like the rest of this
  project — has no unit test target; verify that layer via hardware
  validation, same as every other CAT/audio feature.
- `Apps/Mac/FTX1RemoteMac/` — Mac app target source (canonical location;
  the Xcode project at `FTX1RemoteMac/FTX1RemoteMac.xcodeproj` points at
  this directory via a synchronized group, not a separate copy). Owns the
  rigctld connection and WebSocket server (`HubService`, `RigWebSocketServer`,
  `RigctldProcessController`), plus `HubService`'s `RigController`
  conformance (`HubService+RigController.swift` — the only conformer that
  builds a real `DeepSettingsView` destination). Also owns the audio-derived
  waterfall/oscilloscope display (`AudioCaptureEngine`, `ScopeDisplayView`,
  `AudioInputDevice`/`AudioInputSettings`, and — `.remote`-mode only —
  `RemoteAudioStreamClient`) — Mac-only, see Architecture above. Also owns
  FT8 decoding (`FT8DecodeCoordinator`, `FT8Resampler`, `FT8Store`,
  `FT8Spot`, `FT8ListView`) — see "Digital modes — FT8" above. Dense
  multi-pane UI (`ContentView`: VFO, meters, scope display,
  band/mode selectors all visible at once), `SettingsView` (tabbed sheet:
  rigctld connection config, Audio input device, Station, Appearance),
  plus two menu systems: `MenuPageView` (shared, see `Sources/FTX1Core/UI/`
  above) and `DeepSettingsView` (Mac-only — the page-3 category screens,
  rendered generically from `DeepSettingsCatalog`).
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
