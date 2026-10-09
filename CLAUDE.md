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
  Mobile apps never talk to rigctld directly — except the iPhone/iPad
  Pi-direct proof of concept (see "Pi-direct proof of concept (iPhone,
  iPad)" below).
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
  from `RigctldSettings.connectionMode`/`.remoteHost`). When Done saves a
  different mode (or, in `.remote`, a different host), Settings offers
  "Restart Now"/"Later" (2026-09-27, confirmed working by the user; `AppDelegate.relaunch()` waits for the
  old process to exit, then `open`s the bundle). Everything that runs after
  launch reads `RigctldSettings.activeConnectionMode`/`.activeRemoteHost`
  (snapshotted at launch), never the saved values, so "Later" can't mix
  the two modes in one session.
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
- **Hamlib-verb reply timeout (2026-09-29, rig-confirmed by the user the same
  day, incl. recovery from a Pi rigctld stop/start)**: `RigctldClient.send`/`queryOrError` had no reply timeout
  (only raw CAT did), so a silent rigctld — or the Pi dropping off
  Tailscale without closing the TCP connection — held the round-trip lock
  forever and queued every later command behind it (hit on Windows with a
  2-line read answered by a 1-line "RPRT -8"; the Mac already routed every
  multi-line read through `queryOrError`, and the unused, unchecked
  `query(_:lines:)` is gone). Both now share `sendRawCommand`'s
  bounded read (`withReplyTimeout`: cancel, reconnect at once, throw) with
  `hamlibReplyTimeout` = 5 s — longer than Windows' 3 s because the Pi's
  rigctld may run hamlib's default 1000 ms × 3 retries, and cutting off a
  reply that's still coming costs a reconnect. Only a timeout reconnects:
  an error reply, `.connectionLost` or `.notConnected` are rethrown as
  before, so the hub's own reconnect handling is unchanged. A hamlib
  timeout logs at notice ("rawcat" category, "no reply in 5.0 seconds —
  reconnecting"); raw-CAT ones stay at debug, since e.g. "GT0" goes
  unanswered every poll in C4FM. `readLine` now only tears down the
  connection it was reading from, so the cancelled read's late error
  can't close the freshly reconnected one.
- **Raw CAT sets go out as `W <cmd>; 0` (2026-10-06)**: with `; ;`
  ("read up to a ';'") rigctld waited out its serial timeout for the
  answer a set never gets, holding every later command ~2.1 s over the Pi
  (~300 ms in local mode). `; 0` ("expect 0 bytes") gets an empty `\0`
  reply in ~55 ms with the set still applied; a rejected set's "?;" is
  flushed by rigctld, not left for the next read (probed with `nc`-style
  scripts against the Pi; rig-confirmed by the user the same day on Mac
  and Windows — filters, MENU grid, V/M). The client reads that empty reply inside the
  round-trip lock (`sendRawCommandFireAndForget`, Windows'
  `WriteRawSetAsync`). `writeKeyerMemory`'s lowercase `w` (needed for
  spaces) has no such option and still takes ~2 s.
- **Pi under-voltage drops the rig's USB (found 2026-10-02, not fixed —
  hardware)**: the "sometimes an error" reports traced to the Pi 2B's
  supply, not the app: `journalctl -k` showed "Undervoltage detected!"
  and `usb 1-1.2: USB disconnect` (the FTX-1's built-in hub: CP2105 +
  audio codec) 2–3 times a day since the 2026-09-27 boot, then 13 in a
  burst that ended in "unable to enumerate USB device"; `vcgencmd
  get_throttled` = 0x50000. With the rig's USB gone, rigctld still
  accepts TCP but never answers — so to the app it looks like timeouts
  (and, in the CW send pane before `RigctldError` got descriptions,
  "RigctldError error 3" = `rawCommandTimedOut`). Recovery: replug or
  power-cycle the rig, then restart `rigctld.service`. Fix: a proper
  5.1 V/2.5 A supply and short cable, or a powered hub for the rig. To
  check: SSH (`~/.ssh/id_direwolf_monitor`, `captobie@ftx1pi`), then
  `vcgencmd get_throttled` (want 0x0) and the `journalctl -k` lines
  above. This is the "rigctld/radio down but the Pi itself is fine" case
  the planned UI distinction above is about.
- **Audio-over-Pi (2026-09-07)**: implemented and hardware-confirmed
  working — waterfall/oscilloscope, iPad relay, and Mac-local playback all
  functioning against the real Pi. In `.remote` mode, `AudioCaptureEngine`
  no longer taps a Mac-local sound card — it connects to
  `Pi/ftx1-audiostream.py` (a small Python + `pyalsaaudio` script, run as
  its own systemd service on the Pi alongside `rigctld.service`/`direwolf.
  service`, listening on port 8532) via the new `RemoteAudioStreamClient`
  (originally Mac-only; in `Sources/FTX1Core/Audio/` since 2026-10-05,
  shared with the iPhone/iPad Pi-direct proof of concept). This piggybacks on the same
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
  - **APRS list search + filters (2026-10-01, Mac-only, tested in the
    built app against saved history, not live traffic)**: both list
    windows have a toolbar `.searchable` field (Stations: callsign +
    comment; Messages: from/to/text) and a Filter menu beside the Source
    picker — a heard/received-within window (`APRSHeardWindow`) on both,
    "With Position Only" on Stations, and on Messages "Addressed to
    <callsign>" (any SSID of `StationSettings.callsign`, disabled while
    unset), Hide Bulletins (`BLN…` addressees) and Hide Telemetry
    Definitions (`PARM.`/`UNIT.`/`EQNS.`/`BITS.` text — most of the real
    message history turned out to be these). The shared bits (time
    windows, matching, the Source picker) are in `APRSListFilter.swift`.
    Filter state is per-window `@State`, not persisted; the time window is
    only re-checked when the list re-renders (on a new packet).
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
    differed (baseline reset by app tuning commands; equal-frequency swaps
    are unobservable; Memory mode included since 2026-09-28 — it used to
    reset the baseline too, which missed every front-panel swap between a
    VFO and a memory channel, and the rig was confirmed on the Windows app
    to keep L/R with the physical receiver for those as well; the fix is
    rig-confirmed by the user the same day on both Windows and the Mac),
    and (3) a manual override
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
    **V/M after a swap (2026-09-29, rig-confirmed by the user the same day)**:
    `HubService.lastVFOState` (Main's last VFO-mode frequency/mode,
    replayed after `.setVFOMemoryMode(memory: false)`) is now cleared by
    both the app swap (`applyOptimistically(.swapActiveVFO)`, including
    single-receive display, where `SV` still exchanges the VFOs even though
    the audio isn't flipped) and a `trackExternalSwap` detection — not by
    the manual audio override. Before, after a swap the replay put the
    *other* receiver's VFO on Main (found on the Windows app: a C4FM memory
    channel swapped onto Main, then V/M tried to restore Sub's old CW
    frequency). Leaving Memory then sends a bare "VM000" until the next
    VFO-mode poll relearns it.

## Pi-direct proof of concept (iPhone, iPad) (started 2026-10-05)

A deliberate, contained exception to "mobile apps never talk to rigctld":
the iPhone app (2026-10-05) and the iPad app (2026-10-06) can connect
straight to the Pi's rigctld over Tailscale, without the Mac hub (user
decision). Picked with a "Mac hub / Pi direct" segmented control at the
top of each app's `ContentView` (`@AppStorage "connectionRoute"`);
switching disconnects the side being left. The Mac-hub path
(`RigClientViewModel`, now in each app's `HubControlView`) is unchanged.
`PiDirectViewModel` and `PiAudioDownsampler` live in `FTX1Core`
(`Networking/`, `Audio/`; moved out of the iOS target 2026-10-06 when the
iPad needed them — explicitly `@MainActor public`, since the package
doesn't have the app targets' MainActor default); each app has its own
`PiDirectView`. The iPhone/iPad differences are init options:
`PiDirectViewModel(logSubsystem:playsSubAudio:readsSMeter:)` — the iPhone
passes `"com.ftx1remote.ios"` and neither option, the iPad
`"com.ftx1remote.ipad"`, `playsSubAudio: true`, `readsSMeter: true`.

- **Milestone 1, control (2026-10-05, Simulator against the real Pi)**:
  `PiDirectViewModel` owns a `RigctldClient` (`<piHost>:4532`, host
  `@AppStorage "piHost"`, default `ftx1pi`) and a `CommandQueue`; polls
  every 1 s for MAIN frequency ("FA"), MAIN/SUB mode ("MD0"/"MD1"), SUB
  frequency and PTT, best-effort like `HubService`; only
  `.connectionLost`/`.notConnected` ends the session (retry after 3 s).
  Logs under subsystem "com.ftx1remote.ios", category "pi-direct".
  Accepts only `.setFrequency`/`.setMode`. Verified: connect, live
  read, mode change confirmed independently with a raw "MD0;" read
  (USB, then back to CW), Disconnect. Not yet tried on a real iPhone or
  over cellular; the frequency-entry tune path wasn't exercised.
- **Receive only, on purpose**: the Enable Transmit and amateur-band gates
  live in `HubService.send(_:)`, which this path bypasses — port a gate
  (like Windows' `TransmitGate`) before adding PTT or anything else that
  transmits.
- Milestone 1 confirmed on a real iPhone by the user, 2026-10-05.
- **Milestone 2, Main audio (2026-10-05, Simulator against the real Pi)**:
  `RemoteAudioStreamClient` moved from the Mac target to
  `FTX1Core/Audio/` (now `public`, takes a `logSubsystem` — the Mac passes
  "com.ftx1remote.mac"; cancelling it now also cancels the
  `NWConnection`, so a stopped client can't sit in the Pi's listen
  backlog). `PiDirectViewModel` runs one alongside the rigctld link (own
  retry loop), downsamples the **left** channel with `PiAudioDownsampler`
  (44.1 kHz float → 8 kHz Int16, one long-lived `AVAudioConverter`) on
  the client's actor, and pushes into an `AudioPlaybackEngine` on the
  main actor. `audioState` (off/waiting/playing, "waiting" = no samples
  for 2 s) is sampled once a second, not published per chunk. Mute and
  VOL/SQL sliders use the same `AudioPlaybackSettings` keys as the iPad's
  Main controls (squelch slider inverted the same way). The quieting-
  based `SquelchGate` stays shut on HF band noise (~0.02 RMS vs the 0.015
  default), so SQL has to go left to hear SSB/CW. Verified: samples at
  real-time rate (~21.5 chunks/s), gate opening with SQL left, "waiting"
  while another client (`nc`) held :8532 with rig control unaffected, and
  automatic pickup once it let go. Audio confirmed on a real iPhone by
  the user the same day; not yet tried over cellular. Known gaps: left channel = Main only until a swap (the
  Mac's `audioChannelsSwapped` isn't ported); no background audio
  (`UIBackgroundModes`); accepted limit (user decision) — the Pi serves
  one audio client at a time, so the Mac must not hold the stream.
- **iPad port (2026-10-06, Simulator against the real Pi; confirmed on a
  real iPad by the user the same day)**: same model, plus Sub audio — the **right** channel through
  a second downsampler (each `AVAudioConverter` keeps its own filter
  state) into a second `AudioPlaybackEngine`, muted via the same
  `isMuted`/`subIsMuted` keys as the iPad's hub columns (the model's mutes
  are now `isMainAudioMuted`/`isSubAudioMuted`, and the engines are public
  `mainAudioEngine`/`subAudioEngine` so the views set VOL/SQL on them
  directly, as the hub screen does) — and one more read per 1 s tick,
  `l currVFO STRENGTH`, for the S-meter (5 → 6 rigctld round trips). The
  iPad `PiDirectView` is a cut-down hub screen: SUB/MAIN `VFODisplayBox`es
  (MAIN tunable, SUB read-only, no TX/RX tags or memory channel — not
  polled), `SMeterView` (RX only), Sub + Main `ChannelAudioControls`
  (pulled out of the hub screen so both share it; its `onChange(initial:
  true)` also fixed the hub's Sub engine starting on *Main's* volume/
  squelch, since `AudioPlaybackEngine.init` loads the Main settings), and
  the segmented mode picker. No PTT, power, band picker, VFO swap (would
  also break left = Main) or `MenuPageView`. Verified: connect, live
  frequency/mode/S-meter read, mode change confirmed with a raw "MD0;"
  read (USB, then back to CW), both channels at ~21.5 chunks/s (Main on
  14 MHz HF noise gated shut until SQL went left; Sub on a quiet UHF
  carrier open), per-channel mute and SQL, "waiting" while `nc` held
  :8532 and automatic pickup after, and switching to "Mac hub" freeing
  the Pi's audio slot. Note for `nc` checks against the Pi: its rigctld
  runs with `-o`, so verbs need a VFO argument (`l currVFO STRENGTH`, not
  `l STRENGTH` — the latter just hangs, read as VFO "STRENGTH").
- **iPad meters + audio as compact strips (2026-10-09, Simulator against
  the real Pi; hub screen layout-checked only)**: user request, to save
  space. Both iPad screens replace the analog `SMeterView` + the two tall
  `ChannelAudioControls` columns with one `ChannelStrip`
  (`Apps/iPad/`) under each VFO box: a segmented bar S-meter (S0–S9 in
  the first 60%, over-S9 red) with an "S7"/"S9+12" readout and a mute
  icon on the top row, SQL and VOL side by side below — about half the
  old height. MAIN *and* SUB now have meters: the hub screen uses the
  `subSmeterDb` the Mac already broadcasts ("RM2"); the Pi-direct model
  (`readsSMeter`) reads "RM2" too (7 rigctld round trips per tick) and
  no longer carries either meter forward on a failed read. While
  transmitting (hub only), MAIN's bar shows the TX meter picked by
  tapping it (shared `MeterSettings.key`, PO default), with the SWR under
  the readout; the old standalone "SWR" label is gone. SUB's meter
  confirmed by the user on HF band noise, and probed against the Pi on a
  147 MHz FM repeater ("RM2" ~100–108 ≈ S8 with a carrier). On V/UHF FM
  with no carrier the rig reports exactly 0 ("RM2"/"SM1", STRENGTH -54)
  even though static is heard — USB audio is unsquelched — so a still
  SUB bar there is correct. Unclear whether the rig reports SUB's meter
  in C4FM (one 15 s probe read 0, maybe between transmissions). Not yet
  tried: the TX display on the rig, a real iPad.
- **iPad VFO boxes at Mac parity (2026-10-09, Simulator against the real
  Pi and WPSD hotspot)**: `PiDirectViewModel(readsVFODetails: true)` (iPad
  only; the iPhone is unchanged) adds the rest of what the Mac's
  `VFODisplayBox`es show — "VM0"/"MC0"/"MT" and the memory scan ("RI0",
  "SC" while running, only in Memory mode) every tick; "FR", "ST", "FT"
  and "VM1"/"MC1"/"MT" every 5th tick (the Mac's slow-tier reads) — and
  the C4FM callsign/reflector: `WPSDCallsignMonitor`/`WPSDSettings` moved
  from the Mac target to `FTX1Core/WPSD/` (poll intervals now injected;
  the Mac passes `PollingSettings`), and the iPad polls the hotspot itself,
  host from a "WPSD hotspot" field next to the Pi host (`wpsd.host` in the
  iPad's own defaults; empty = off). Display only: SUB tuning and memory
  channel set/step stay unsupported on this route, and there's no APRS
  (user decision — no decoder here). The Simulator can't resolve the bare
  MagicDNS name "wpsd" for `URLSession` (-1003; `NWConnection` to "ftx1pi"
  is fine), so test there with the full `wpsd.<tailnet>.ts.net`. Fixed on
  the way, in the shared box: the indicator line reserved a fixed 14 pt,
  shorter than iPad's caption2, so a reflector appearing grew the box; it
  now reserves one hidden caption2 line. Verified: SUB's "CH 1 Pi-STAR",
  RX/TXRX tags, the reflector, equal box heights. Confirmed on the real
  iPad by the user the same day, all fields showing.

## Windows app (v1 skeleton scaffolded, 2026-09-07)

A Windows app with the same kind of functionality as the Mac app. Talks
directly to the Pi (rigctld + `ftx1-audiostream.py`), never through the
Mac's WebSocket hub — the Mac is not required to be running. Since
2026-09-27 it also has a Local mode (a "Radio:" Remote/Local picker, like
the Mac's `connectionMode`): the radio's USB on the Windows PC, driven by a
`rigctld.exe` the app spawns or adopts on `127.0.0.1:4532` via
`Services/RigctldProcessController.cs`, a port of the Mac's — still
rigctld-only, never CAT over the serial port directly. Built and run on
the user's Windows PC 2026-09-27 (.NET 10 SDK; the .NET 5 SDK that PC had
first can't target net8.0) and hardware-confirmed by the user the
same day: every item of `Apps/Windows/README.md`'s "Local mode" checklist
passed (connect, wrong-port and radio-off errors, rigctld cleanup on
Disconnect/close, adopting a user-started rigctld, PTT). No WebSocket *server* (this app is
a leaf client only).

**The user's Windows test PC** — use these values in any commands given
for it instead of placeholders: the FTX-1 is on **COM7** (COM4 before 2026-09-28) at **115200**
baud; hamlib's binaries are in `C:\Tools\hamlib\bin`; the .NET 10 SDK is
at `C:\Program Files\dotnet\dotnet.exe` (the bare `dotnet` there was an old
.NET 5 SDK — call it by full path); the repo clone is under the user's
OneDrive Documents folder (`...\Documents\ftx1-remote`). So e.g. a
manual rigctld is `.\rigctld.exe -m 1051 -r COM7 -s 115200 -t 4532 -T
127.0.0.1 -o`, run from `C:\Tools\hamlib\bin`.

C# + WinUI 3,
MSIX-packaged, lives in this repo at `Apps/Windows/FTX1RemoteWindows/`
despite sharing no code with the Swift targets (Swift/SwiftUI isn't viable
on Windows). v1 scope is core rig control (VFO A/B, mode, PTT, power, SWR,
band); Main/Sub audio playback from the Pi's :8532 stream was added
2026-09-27 (NAudio; Remote from the Pi's stream, Local from a PC sound-card
input, tested against a local fake Pi and the real rig's USB audio; swap tracking ported from
the Mac the same day, which also fixed the Windows ⇄ to send raw "SV"
instead of hamlib's "V"/VS; the Pi still serves one audio client at a time, so the Windows app
shows "waiting" while the Mac has the stream; see the README's "Audio"
section). The Mac's Enable Transmit gate was ported 2026-09-27
(`Services/TransmitGate.cs`, build-verified, not yet hardware-tested):
any future transmit-capable control (MOX, CW MESSAGE play, ANT TUNE) must
pass `TransmitGate.BlockReason` before keying. The order for the rest of
the Mac-parity work is the "Mac parity plan" section of
`Apps/Windows/README.md` (all ten steps done; step 3, the MENU grid, has all
three pages in `Controls/MenuGrid.cs` as of 2026-09-28, spot-tested on the
rig by the user the same day, all working — CW's PLAY/RECORD were
placeholders until 2026-10-03, now the Mac's recorder + Recordings window
(`Services/AudioRecorder.cs`, `Controls/RecordingsWindow.cs`; tested by
the user the same day, working; see the README's "Recordings"), and
FM's APRS S.LIST/M.LIST came with APRS decode; step 4, the
analog Main/Sub meters in `Controls/SMeter.cs`, 2026-09-28, checked
against a fake rigctld only, not yet on the rig; step 5, the V/M memory
toggle + channel set/step/tag, 2026-09-29, tested on the rig by the user
the same day; hamlib-verb reads there now time out after 3 s, since a
C4FM memory channel's "RPRT -8" mode reply once hung the whole client;
step 6, the WPSD C4FM callsign/reflector display, 2026-09-29, tested
against the real hotspot by the user the same day, with C4FM read from
raw "MD0"/"MD1"; step 7, a Settings dialog with the Mac's tabs
(`SettingsDialog.xaml`: connection, audio devices, WPSD, HOME
frequencies, polling, appearance — the connection/audio/WPSD fields moved
out of the main window), 2026-09-29, UI-tested through UI Automation
while disconnected, not yet on the rig; step 8, Deep Settings, 2026-09-29
— `Models/DeepSettingsCatalog.cs` is `DeepSettingsCatalog.swift`
translated by script and checked item-for-item against it (the Swift file
stays the source of truth: copy any hardware correction made there), and
`Controls/DeepSettingsDialog.cs` is the Mac's `DeepSettingsView`, opened
from the FM page's bottom row; checked against a fake rigctld through UI
Automation, not yet on the rig; step 9, the Filter rows, 2026-09-30 —
`Controls/FilterPanel.cs` + `Models/FilterModels.cs`, the Mac's WIDTH/
SHIFT/CONTOUR-APF/N/W/NOTCH, MAIN/SUB selector and Filter Function
Display, checked against a fake rigctld through UI Automation, not yet
on the rig; step 10, the waterfall/oscilloscope, 2026-09-30 —
`Services/ScopeProcessor.cs` (the Mac's `AudioCaptureEngine` DSP, same
constants) + `Controls/ScopeDisplay.cs`, between the meters, also feeding
the Filter display's spectrum, checked against a fake Pi audio stream,
not yet on real rig audio). The .csproj has to be named when
building (`dotnet build FTX1RemoteWindows.csproj -r win-x64
--self-contained`) since Visual Studio added a `.slnx` next to it, and
a solution build rejects `-r`; Visual Studio's own builds land in
`bin\x64\Debug\…`, the CLI's in `bin\Debug\…`, so launch the one just
built).
APRS decode was ported 2026-10-01 (Main + Sub decoders, S.LIST/M.LIST
windows, Settings → APRS; the Swift `APRS/` files stay the source of truth
for the DSP, see the README's "APRS decode"), checked against synthetic
vectors and a fake Pi stream, then rig-tested by the user the same day in
Remote mode (MAIN and SUB), working well; Local mode not yet rig-tested;
the Mac's APRS map is not ported.
The WebSDR window was ported 2026-10-01 (`Controls/WebSdrWindow.cs`,
`Services/WebSdrFollowModel.cs` + `SdrPageBridge.cs`, WebView2): everything
the Mac's has, checked against a fake rigctld and public KiwiSDR/WebSDR
servers, not yet on the rig. The Swift WebSDR files stay the source of
truth; see the README's "WebSDR window" for the WebView2 differences
(shared environment, the multiple-downloads permission, Recordings folder).
OpenWebRX followed 2026-10-02 (profiles, in-place retune, the recorder
tap), tested against the operator's own server with a fake rigctld, not
yet on the rig; WebView2 needs no hash-navigation workaround (Chromium
keeps OpenWebRX's hash updates same-document).
The CW window was ported 2026-10-03: decode with both of CWKit's decoders
translated to C# — cwdecode stays the source of truth for both
(`Services/CwClassicDecoder.cs`, `Services/CwNeuralDecoder.cs`,
`Services/CwReceiver.cs`, `Controls/CwWindow.cs`), checked against
CWKit's own tests and golden files in a harness and a fake Pi; and the
send pane (`Services/CwSender.cs`, `Controls/CwSendPane.cs`,
`RigctldClient.WriteKeyerMemoryAsync`, a Callsign field in Settings →
Station), checked against a fake rigctld that models the keyer. None of
it yet on the rig. The neural model is CWKit's `CWNet.mlmodelc` converted
to `Assets/CWNet.onnx` (same weights) by `Apps/Windows/Tools/
cwnet_to_onnx.py` and run with ONNX Runtime: rerun the script with the new
tag whenever CWKit ships a new model (it checks against the release's
golden file). The WebSDR window is a third CW source
(`Services/WebSdrAudioTap.cs`, process-loopback capture of the WebView2
browser process tree), tested with a local CW page, not yet against a real
WebSDR; unlike the Mac, a muted WebSDR can't be decoded (Windows has no
mute that keeps the capture fed — user decision).
The memory scan (MAIN and SUB, Scan/Skip next to Mem List) was ported
2026-10-06 (`MainWindow.MemoryScan.cs`, `Models/MemoryScan.cs`), with the
same read-by-side poll fix as the Mac (the boxes traded places with TX on
SUB); built and rig-tested by the user on Windows the same day, working.
See the README's "Memory scan".
The memory list (Mem List under Waterfall) was ported 2026-10-06
(`Controls/MemoryListWindow.cs`, `Services/MemoryListStore.cs`,
`Models/MemoryChannelEntry.cs`). The user built it and tested it on the
rig the same day, and everything worked. See the README's "Memory list".
Full plan, protocol/model porting notes, and open items:
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
  templated). Keep earlier releases' zips in `releases/`: `generate_appcast`
  builds delta updates from them (upload the `*.delta` files it makes to the
  new release too). It also re-points every archive it finds at the new
  `--download-url-prefix` — v0.6's first run rewrote 0.5's link to `v0.6/`
  — so the script seeds `releases/` with the committed `appcast.xml` and
  then restores the original URL of every file that appcast already listed.
  Create the GitHub release *before* pushing `appcast.xml`, or updating
  clients see the new version while its download still 404s.
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
- **Settings → Updates tab (2026-09-29)**: "Automatically check for
  updates" and "Automatically download and install updates" checkboxes
  (`UpdaterSettingsViewModel`, a KVO bridge like `CheckForUpdatesViewModel`,
  so they follow Sparkle's own prompts too) plus a Check for Updates…
  button. Sparkle stores both settings itself, with no app-side storage. Automatic checks
  default to on via `SUEnableAutomaticChecks = YES` in
  `FTX1RemoteMac-Info.plist`, which also skips Sparkle's first-run
  permission prompt; an install that already answered that prompt keeps
  its saved choice. Auto-download defaults to off.
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
     validation`. **But** Hardened Runtime also silently denies audio
     input without `com.apple.security.device.audio-input` — no prompt,
     `AVCaptureDevice.requestAccess` just returns false — which left
     `.local` mode with no audio at all in 0.5/0.6 (2026-09-26; `.remote`
     was unaffected). Fixed with `ENABLE_RESOURCE_ACCESS_AUDIO_INPUT = YES`
     on the Mac target (Xcode synthesizes the entitlement, same as
     `ENABLE_USER_SELECTED_FILES`); check with `codesign -d --entitlements
     - <app>`.
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
top-level **Tools** menu bar item (named **Digital** until 2026-09-30) (`CommandMenu`, a genuine sibling of
File/Edit/View; since 2026-10-01 it also holds the APRS List/Messages/Map
submenu, moved there from the View menu) → **FT8**, which opens its own `Window(id: "ft8")`, same
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
- **Decode trigger: tied to the Tools/FT8 window's lifecycle, not
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

## Digital modes — CW (decode v1 + send v2, 2026-10-02)

Tools → **CW** opens `Window(id: "cw")` (Mac-only): live CW decoding of the
rig's MAIN or SUB audio or of the WebSDR window's audio, plus decoding an
audio file. The decoders come
from the user's own CWDecode app (`captobie/cwdecode`, public, MIT) — not
vendored here.

- **CWKit, a Swift package in the cwdecode repo**, is the source of truth
  (user decision, 2026-10-02, over absorbing or vendoring): the neural
  decoder (CNN + CTC Core ML model, `CWNet.mlmodelc`) and the classic one
  (Goertzel + timing rules), with their Python training/export (`ml/`) and
  golden tests in the same repo. The Mac target depends on it by git URL,
  `upToNextMinorVersion` from `0.1.1`, wired into the pbxproj the same way
  as Sparkle (hand-added, then `xcodebuild -resolvePackageDependencies`).
  To pick up a retrained model or decoder fix: tag a new CWKit release in
  cwdecode, then bump/resolve here. The model ships *compiled* in the
  package (`.copy("Resources/CWNet.mlmodelc")`) because SwiftPM compiles an
  `.mlpackage` resource's inner `model.mlmodel` instead and fails;
  cwdecode's `export.py` compiles it with `coremlcompiler`. Built Mac app:
  `Contents/Resources/CWKit_CWKit.bundle/.../CWNet.mlmodelc`.
- **`CWReceiver`** (`Apps/Mac/FTX1RemoteMac/CWReceiver.swift`) is a plain
  `let` on `HubService` (like `ft8Store`), fed by *both* audio taps
  unconditionally (before the APRS gates); it keeps only the selected
  channel (`CWAudioChannel`, persisted `cw.channel`) and drops everything
  while the window is closed (`start()`/`stop()` from `CWWindowView`'s
  onAppear/onDisappear; `HubService.stop()` also calls `stop()`). MAIN/SUB
  are roles, so they follow swaps via `audioChannelsSwapped` upstream.
  Decoding runs on CWKit's `PipelineRunner` queue; the Core ML model loads
  on the first `start()`, not at launch. Per-chunk meters live in a
  separate `CWMeterStore` (published at most every 0.1 s, key/element
  changes at once) so they never re-render the decoded text. Settings are
  `cw.*` UserDefaults keys. Switching channel flushes the decoder and
  starts a new line.
- **Open Audio File** (file dialog opens in the Recordings folder) pauses
  live decoding, decodes into the same text under a "— filename —" header,
  then live resumes. `pendingFlushes` counts `.finished` events from
  flushes so only the file's own one ends the file decode (the standalone
  app clears `isDecodingFile` on any `.finished`, so opening a file while
  listening ends its "decoding" state early — not fixed there yet).
- SUB is disabled when no Sub audio has arrived for 2 s (mono input) or the
  rig is in single-receive display (`RigState.singleReceive`).
- **WebSDR source (2026-10-02, tested in the built app against a live
  Kiwi)**: a third picker segment decodes what the WebSDR window is
  playing, via `WebSDRAudioTap` (Core Audio process tap + private aggregate
  device, `CATapDescription(stereoMixdownOfProcesses:)`, `muteBehavior
  .unmuted`) — chosen over per-page JS taps so it works for KiwiSDR,
  classic WebSDR and OpenWebRX without injecting anything into Kiwi/WebSDR
  pages. A `WKWebView` plays audio from WebKit's helper processes
  (`com.apple.WebKit.GPU`, one per app), not this one; they're found by
  `responsibility_get_pid_responsible_for_pid` (not in the SDK headers,
  loaded via `dlsym` — if a macOS update drops it, the source just stays at
  "waiting") matching our PID, and re-resolved every 2 s so a relaunched
  helper (or connecting after picking the source) is picked up. Runs only
  while the CW window is open with WebSDR selected. Needs
  `NSAudioCaptureUsageDescription` (in `FTX1RemoteMac-Info.plist`) and the
  user's "System Audio Recording" permission, prompted on first use —
  denied delivers silence. The tap hears the page's *output*, so while it
  runs the WebSDR window's Mute (and Mute on TX) is moved off the page and
  onto the tap (`muteBehavior .muted`: speakers silent, tap still fed) via
  `WebSDRAudioRouting` (a `let` on `HubService`: `WebSDRFollowModel` sets
  `muteRequested` and mutes the page only while `!captureActive`;
  `CWReceiver` sets `captureActive` once the tap is attached — already
  muted, so there's no audible gap — and clears it before stopping the tap,
  which holds its mute 0.3 s while the page re-mutes). A muted page or a
  denied permission shows as "WebSDR is silent" (below -80 dBFS for 3 s —
  a muted Kiwi isn't exact zeros). Tested 2026-10-02: decoding with the
  window Muted (Kiwi page's own icon unmuted), and the page re-muting on
  switching the CW source away. Kiwi page audio arrives at 48 kHz
  stereo here, mixed to mono. Not tried yet: classic WebSDR, OpenWebRX.
- **Cost**: CWKit measured at ~7% of a core (neural, Debug/-Onone) and ~1%
  (Release) for 44.1 kHz audio — no vDSP rework needed.
- **Verified 2026-10-02**: CWKit tests (19, incl. the Python golden checks)
  via `swift test` in cwdecode; Mac target builds; in the built app, a
  real CW recording decoded through the window matched CWKit's offline
  decode exactly; Clear and the Neural/Classic switch work. **Not yet
  done**: live decoding on the rig (MAIN, SUB, and across a swap).
- **v2: CW send pane (2026-10-02, tested on the rig into a dummy load by
  the user)**: `CWSendPane` below the receive pane (`VSplitView`), driven
  by `CWSender` (a `lazy var` on `HubService`, sibling of `cwReceiver`).
  Line at a time (Return queues), 6 editable macros that fill the send
  line rather than send (user decision 2026-10-03, so they can be edited
  first; appended after a space if the line has text; cursor left at the
  end via `TextField(text:selection:)`, set after focus since macOS
  selects the whole field on focus) (`CWMacro`, JSON in
  `cw.macros`; `{MYCALL}`/`{MYGRID}` from `StationSettings`, `{CALL}` from
  the pane's "Their call" field (session-only, not persisted); ⌘1–9), Stop (Esc: "KY00" + drop the queue), the
  rig's keyer speed (`KS`) and BK-IN, and a log of queued/keying/sent
  lines. Sending is the rig's own keyer, not real-time keying: each ≤50-
  character chunk is written to one dedicated CW TEXT keyer memory
  (`cw.keyerSlot`, default 1 — the user's slots 4/5 hold their own
  messages; slot 1 is overwritten every send) with
  `RigctldClient.writeKeyerMemory`, then played with the transmit-gated
  `RigCommand.playCWTextMemory(slot:)` ("KY0n"). `HubService.
  ensureCWTextMemory` sets the slot's menu type to TEXT (EX 02 02 05+n)
  once per session. All user-chosen design decisions (dedicated slot,
  line-based, macros now, pause decoding on TX).
  - **Rig facts, probed with `nc` against the Pi's rigctld, 2026-10-02**:
    `W` splits on whitespace, so the write goes through lowercase `w`
    (whole line), which then waits out rigctld's timeout (~2 s) for a reply
    a set never gets — `writeKeyerMemory` follows it with a "KM<n>;" read
    in the same write and returns once that answers (also confirms what was
    stored). The rig appends the "}" end marker itself; it keeps exactly 50
    characters and answers "?;" to more (memory unchanged); it keyed every
    character in `CWText.allowed` (A-Z 0-9 / ? , . = + - ( ) @ :), so
    `<BT>`/`<AR>`/`<KN>` are sent as `=`/`+`/`(` (other prosigns as their
    letters); it **only transmits with BK-IN on** (off: a brief mute, no
    TX, no sidetone), so the pane blocks sending with "Turn On BK-IN"
    rather than switch it silently; a second "KY" during playback
    *restarts* the message, so chunks go strictly one after another;
    "KY00" stops at once; "KM<n>;" alone is a read, so a slot can't be
    emptied (" " is the closest). PTT reads 3 throughout keying incl. word
    gaps, with the odd spurious 0.
  - **Finish detection** (`CWSender.waitUntilKeyed`): ≥90% of the PARIS-
    timed duration at the rig's WPM has passed and PTT has read off for
    ≥1 s; capped at 1.5× + 5 s. Gap between chunks heard as ~1–2 s.
  - Blocks (queue waits, shown in the pane): not connected, Enable
    Transmit off, Main not in CW, outside an amateur band, BK-IN off.
    Turning Enable Transmit off also stops the sender. Closing the window
    doesn't stop a queued line.
  - Receive side, same change: decoding pauses while the sender runs or
    the rig reports TX (`CWReceiver.isPausedForTransmit`, flushes the
    decoder first); a "Rig Pitch" button sets the manual tone to the rig's
    CW pitch (`KP`); a note when the selected receiver isn't in CW.
    `HubService` forwards only `CWRigInfo` changes (TX, pitch, modes —
    modes only while connected, since `rigState.mode` is a USB placeholder
    before the first read).
  - **Click-to-fill (2026-10-02, user-confirmed)**: callsigns in the
    committed decoded text are underlined links (`CWCallsigns`: 1–2
    letters / digit+letter / letter+digit, a digit, 1–4 letters, `/`
    parts judged on the longest — excludes `5NN`, `599`, `73`, Q-codes;
    the operator's own call isn't linked, nor the tentative text). A click
    fills Their call through an `OpenURLAction` on the custom
    `ftx1-cw-call:` scheme, so the system never sees it. Background
    (computer-use) clicks don't activate these links — test by hand.
  - Verified: line, 66-character line (2 chunks, complete, short pause),
    Stop mid-line (cut off at once), AGN? macro, `{CALL}` missing refused;
    `CWText` checked in a scratch harness. Not tried: SUB as the TX side
    (sending always keys whatever the rig transmits on), WebSDR source
    while sending.

## Logbook — MacLoggerDX (started 2026-10-07)

Goal: log QSOs made with the CW window, and flag stations already worked.
Mac-only for now. Step 1 (done, tested in the built app): Settings →
**Logbook** tab (`LogbookSettings`, `MacLoggerDX.swift`): Logger picker
(None/MacLoggerDX), the MacLoggerDX log file (auto-detected, Choose…
override) with a read-only summary, UDP host/port, and whether MacLoggerDX
is running and listening.

- **Logging goes over WSJT-X's UDP protocol** (user decision, over
  AppleScript `importADIF`) — step 2, done 2026-10-07: `QSOLogger` (Mac)
  sends a `LoggedQSO` (`FTX1Core/Logbook/`) as WSJT-X's "QSO Logged" +
  "Logged ADIF" datagrams (`WSJTXMessage`, `ADIFRecord`; layout from
  WSJT-X's `Network/NetworkMessage.hpp`, unit-tested in
  `WSJTXMessageTests`) to UDP 2237, then confirms by finding the QSO in
  the log file within 5 s (`MacLoggerDX.containsQSO`) — UDP gets no reply.
  Tested against the user's running MacLoggerDX 6.62 with one QSO (TE5T,
  logged once, every field right; MacLoggerDX fills in my call/grid
  itself when they're empty). What the binary's strings show: MacLoggerDX
  acts on "QSO Logged" when its `wsjt_log_adif` checkbox is off and on
  "Logged ADIF" when it's on — never both — and checks the sender Id
  against "WSJT-X"/"JTDX" (Id used: "WSJT-X - FTX1Remote", the form a
  second named WSJT-X instance uses). **Never send it a Heartbeat with an
  empty version**: that crashed MacLoggerDX twice (uncaught
  `substringWithRange:` in `-[WsjtDecoder messageHeartBeat:]`), so
  `QSOLogger` sends no Heartbeat at all. Only the checkbox-off path is
  tested.
- **Reading the log**: SQLite, path in MacLoggerDX's own prefs
  (`qso_data_source_sql_db_path`, read with `CFPreferencesCopyAppValue`),
  default `~/Documents/MLDX_Logs/MacLoggerDX.sql`. One table,
  `qso_table_v008` (code takes the newest `qso_table_v%`), `qso_start` in
  Unix seconds, `call`/`band_rx`/`mode`/`tx_frequency` (MHz). Read on
  MacLoggerDX 6.62. Always opened `mode=ro`, never written.
- **CW window Log QSO pane (step 3, 2026-10-07)**: `CWLogPane`, a third
  section of the CW window's `VSplitView` (user decision, over a strip in
  the send pane). "Their call" moved there from the send pane — still
  `CWSender.theirCall`, so `{CALL}` and click-to-fill are unchanged. RST
  sent/rcvd (default 599), name, comment; frequency/mode/power from the
  transmitting side when Log QSO (⌘L) is clicked (SUB's when TX:SUB or
  split, the VFO boxes' TXRX rule), mode through `ADIFMode` (data modes
  refused: the rig can't say which one). Time on is set when the call
  goes from empty to filled (reset button next to it); time off at Log.
  Fields clear only after MacLoggerDX confirms (user decision).
  Their call and the send pane's line uppercase as they're typed (user
  request, `UppercaseEdit` in `CWLogPane.swift`), keeping the cursor
  in place: worked out from the edit, never by measuring the field's
  `TextSelection` index against the string — that index can belong to
  another copy of the string, and `String.distance` trapped (crashed the
  app) the first time.
  UI-tested in the built app with the rig disconnected (time on, the
  not-connected refusal); not yet logged a real QSO from it.
- **Lookup button (2026-10-07)**, left of Their call: `QSOLogger.lookUp`
  sends WSJT-X's Status message (`WSJTXMessage.status`) with the call as
  its DX call — what WSJT-X sends when its DX Call changes, and what
  makes MacLoggerDX fill its call field from QRZ and show its "<call>
  Worked <date> on <band> <mode>" line. Tested against the running
  MacLoggerDX with a scratch sender (W1AW, K6NA) and from the app's
  button (disconnected refusal). Found by testing: MacLoggerDX only acts
  on a *changed* DX call (an empty one is sent first, so a repeat lookup
  works), and **ignores the whole Status at a 0 Hz dial frequency** — so
  Lookup needs the rig connected; it fills MacLoggerDX's MHz/band/mode
  from the transmitting side too. The lookup shows up a few seconds
  later (QRZ). Status parsing has no `substringWithRange:` (checked in
  the disassembly) unlike the Heartbeat that crashed it.
- **Worked-before (2026-10-07)**: `WorkedStations` (`FTX1Core/Logbook/`,
  unit-tested) indexes the log by base call — the longest `/` part, the
  later one on a tie (K6NA/P, VP2E/K6NA → K6NA; so W1AW/0 counts as
  W1AW) — and answers this band / other band / never, bands compared
  case-insensitively ("40M" in the log, "40m" in `BandPlan`).
  `WorkedStationsStore` (`lazy var` on `HubService`, runs while the CW
  window is open) builds it from `MacLoggerDX.readWorkedQSOs`, re-reads
  when the log file's date changes (checked every 5 s; MacLoggerDX's
  `journal_mode` is `delete`, so a new QSO changes the main file) and
  right after Log QSO confirms, and tracks the transmitting side's band
  (`RigState.transmitter`, shared with the Log pane). Shown as colors on
  the decoded callsigns (green this band, orange other band, link blue
  never — user decision: call then band, mode ignored) with a legend,
  and as a "Worked N× · last … · new on <band>" / "New station" line
  next to Their call. The legend has its own row under the decoded text
  (a `VStack`; an overlay covered the newest line, and a `safeAreaInset`
  left the last lines unscrollable). **Every file access to the log runs off the main
  actor**: it's in ~/Documents, and the first access blocks on macOS's
  Documents-folder permission prompt — a `FileManager` date check on the
  main thread froze the whole app until the prompt was answered (also
  re-asked after Debug rebuilds). Tested in the built app with a
  synthesized CW recording (K6NA, JJ0PKS, W1AW/0 orange with no band
  known; JA1XYZ, ZL2AB blue) and the pane lines; the green/this-band
  case only in unit tests so far (needs the rig connected).

## Memory list (2026-10-06, rig-confirmed by the user the same day)

A "Mem List" button under the Waterfall button (Mac `ContentView`) opens
`Window(id: "memory-list")` (`MemoryListView`, Mac-only): the rig's
programmed memory channels (channel, tag, frequency, mode, shift, tone
type), searchable, with MAIN/SUB buttons per row. The button for the
channel a receiver is on is highlighted.

- **Reading**: CAT has no list command, so `MemoryListStore` (a `lazy
  var` on `HubService`, like `cwSender`) reads channel by channel with
  `RigctldClient.readMemoryChannel` (raw "MR", then "MT" for the tag of a
  programmed channel). A blank channel answers "MR" with "?;" at once
  (checked with `nc` against the Pi, 2026-10-06). The scan stops after
  `blankRunLimit` (100) blank channels in a row, so a gap that long hides
  the channels after it. The result is cached in
  `~/Library/Application Support/FTX1Remote/memory-channels.json`. The
  window shows the cache and re-reads only on Refresh, except the first
  time it opens with no cache. `MemoryChannelEntry` (`FTX1Core/RigState/`)
  parses "MR". Field offsets are unit-tested against real answers.
- **Recall**: `RigCommand.recallMemoryChannel(channel:sub:)` sends
  "MC<side>" and then "VM<side>11" unless that side already reads
  VM=11. MC first also covers the undocumented MC-before-VM precondition
  (see `.setVFOMemoryMode`). The hub reads back afterward rather than
  guessing: `refreshAfterEnteringMemory` for MAIN (which keeps
  `lastVFOState`, so V/M still goes back to the VFO) and
  `refreshMemoryChannel(sub: true)` for SUB. Leaving Memory mode isn't
  offered from the list. There's still no SUB V/M control in the app.
- Tested on the rig by the user, 2026-10-06, all working: the scan,
  recall on MAIN and SUB from VFO mode, a recall while already in Memory
  mode, and V/M back to the VFO afterward.

## Memory scan (MAIN and SUB, 2026-10-06, rig-confirmed by the user)

The rig's own memory scan on MAIN or SUB, started from the app — not an
app-side stepper (the rig does ~9–10 channels/s; stepping from the app
over the Pi would manage ~3–4 even with the poll paused, so an app-side
scan is only worth building later, for custom scan lists). Under
Waterfall (`ContentView`): Mem List, Scan, Skip. Scan is a menu (Scan
SUB / Scan MAIN, each enabled only in that side's Memory mode — user
decision, one button rather than one per side) that turns into "Stop
SUB"/"Stop MAIN" while a scan runs; Skip works on whichever side is
paused. The Mem List toolbar has a MAIN/SUB picker with Scan Down/Up,
then Skip and Stop Scan while one runs (shown only when they apply).

- **CAT, probed with a scratch script against the Pi first**: raw
  "SC<side><n>" (side 0 MAIN / 1 SUB; n 0 off, 1 up, 2 down). Bare "SC;"
  reads back the last command, e.g. "SC11;" — "SC0;"/"SC1;" answer "?;".
  In Memory mode it's a memory scan; in VFO mode a VFO scan, so
  `HubService.send` refuses to start one outside that side's Memory mode
  (and SUB's in single-receive display). "RI0" P7 is the scan state (0
  stopped, 1 scanning, 2 paused) **for the whole radio**, SUB scans
  included ("RI1" answers "?;"); P8 the squelch. Parsed by
  `RadioInformation` (`FTX1Core/RigState/MemoryScan.swift`, unit-tested
  against real answers). Sending the same "SC<side>1" again while paused
  resumes past the busy channel — that's Skip. None of the fast tier's
  reads stop the scan. SCAN RESUME (EX030204) is BUSY on the user's rig.
- **Both sides can scan at once on the rig, and any stop ("SC00" or
  "SC10") stops both** — so the app runs one side at a time (user
  decision): starting one side's scan stops the other first
  (`RigState.memoryScanSide` says which).
- **A scan moves the rig's TX/RX side to the scanning side**: "SC11" sets
  "VS1", "SC01" "VS0". "VS" and "FT" (TX side, the app's TX:MAIN/SUB
  button) are the same setting — writing either changes both. User
  decision: the app remembers the TX side from before its scan
  (`txSideBeforeMemoryScan`, recorded whenever none is remembered yet, so
  a quick Stop-then-Scan or a side switch keeps the original) and puts it
  back ("FT0"/"FT1" right after "SC…0") when the app stops the scan —
  Stop, or a tune/recall that stops it. Not on a stop before something
  that transmits (that keys the side the display shows as TX now), not
  after a front-panel stop (mirrors the rig), and not once the operator
  picks a TX side themselves.
- **Fixed with this: the fast tier read MAIN/SUB by hamlib's `v`**, which
  answers "Sub" whenever VS/FT is SUB (TX:SUB, or a SUB scan) — the MAIN
  box then showed SUB's mode and the SUB box MAIN's frequency. It now
  reads by side ("FA"/"MD0" for MAIN, `f Sub`/"MD1" for SUB) and no
  longer sends `v` at all. Still following the active side, unchanged:
  `.setFrequency` ("F currVFO"), `.setMode` ("M currVFO"),
  `.stepMemoryChannel` ("CH") and the MAIN S-meter ("l currVFO STRENGTH")
  — so with TX:SUB those address SUB. The scan's own stop-before rules
  restore the TX side first, so this doesn't bite during a scan.
- **`FB`/`f Sub` are unreliable while MAIN sits on a 6 m channel**: they
  read 0 or a wrong ~51 MHz value in the probes (and `f Sub` a stale
  cached one). The scan code reads SUB's frequency/mode from the channel's
  own "MR" entry instead; the regular fast tier still uses `f Sub`
  (pre-existing, not fixed).
- **"SC" is an ordinary raw set** (`setRawInt("SC<side>", n, digits:
  1)`), answered at once since every raw set moved to the `W <cmd>; 0`
  form the same day (see `sendRawCommandFireAndForget`). Multi-command raw
  writes (`W A;B; ;`) run only the first command.
- **Latency handling**: while scanning, the scanning side's channel and
  frequency samples are random and can even belong to different channels,
  so `RigState.memoryScan(on:)` hides that box's channel, frequency, mode,
  callsign and reflector in `VFODisplayBox` (SCAN on the indicator line,
  SCANNING in the channel box), and `pollLoop` runs `memoryScanTick`
  instead of the fast/slow tiers: "RI0" every 250 ms, plus the other side
  kept live — MAIN's "FA"/"MD0" during a SUB scan, SUB's "MC1" (and that
  channel's "MR" when it changes) during a MAIN scan. On pause/stop,
  `publishMemoryScanStop` reads the channel (MAIN: MC0/FA/MD0/MT; SUB:
  MC1/MR/MT), checks the channel number again (retrying if it moved, and
  re-reading rather than giving up if a command lands mid-read — the
  TX-side restore right behind the app's own stop did, which left the
  pre-scan channel/tag next to the new frequency until the slow tier's
  next pass) and publishes at once. Measured in the app: ~0.65 s (MAIN) / ~0.3 s (SUB,
  after the "RI0" answer) from the rig pausing to the channel on screen.
  The fast tier reads "RI0" last, only while either side is in Memory
  mode (or a scan was last seen running), and drops the scanning side's
  values that tick if it finds the rig scanning — which is also how a
  front-panel scan or a BUSY auto-resume is picked up ("SC;" then gives
  the side). The slow tier's SUB channel/tag step skips its write during
  a SUB scan.
- **Stopped before anything that would fight it**
  (`HubService.memoryScanStop(for:scanSide:)`): tuning, band/mode, swap,
  CH step and anything transmit-capable stop either side's scan; MAIN's
  V/M, channel set and recall stop a MAIN scan; SUB's frequency, channel
  set/step and recall stop a SUB scan. Settings commands leave it running.
- `RigCommand.setMemoryScan(_:side:)` ("set_memory_scan", value
  `{direction, side}`) and `RigState.memoryScan`/`memoryScanSide` are on
  the wire, so the iPad's boxes show SCANNING/SCAN PAUSED too; the iPad
  has no scan controls yet. Windows port: see `Apps/Windows/README.md`'s
  "Memory scan".
- Tested 2026-10-06 in the built app against the rig: MAIN — Scan,
  display while scanning, pause on busy channels, Skip, Scan Down (rig
  read "SC02;"), Stop Scan, a Mem List recall while scanning (rig-confirmed
  by the user). SUB — Scan (TXRX moved to SUB, MAIN box live), pause
  (CH 100 shown), Skip, switching to a MAIN scan (SUB box caught up to
  where SUB stopped), a SUB recall from Mem List mid-scan ("SC10", "FT0",
  then the recall), the Mem List picker's Scan Up + Stop Scan ("SC10",
  "FT0"), the Scan menu → Scan SUB → Stop SUB (box right after the stop
  matched the rig), and the boxes under TX:SUB. Not tried: front-panel skip flags
  (channels 101–114 looked skipped; "MR" has no skip field), a scan
  started from the front panel.
## WebSDR follow (KiwiSDR 2026-09-24, classic WebSDR 2026-09-25, OpenWebRX 2026-10-01)

Tools → **WebSDR** opens `Window(id: "websdr-follow")` (Mac-only): an
embedded KiwiSDR, classic WebSDR or OpenWebRX (`KiwiWebView`, a `WKWebView`
`NSViewRepresentable`, despite the name) that retunes to follow the rig's
Main VFO, and (click-to-tune, "Tune rig") tunes the rig when the user tunes
in the page. Most bullets below were written for the Kiwi; the classic
WebSDR differences are in their own bullet at the end.

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
- **Station directory ("Stations…" sheet, `KiwiSDRDirectory`/
  `KiwiSDRDirectoryView`)**: source is `rx.linkfanel.net/kiwisdr_com.js`,
  the community mirror behind the "dyatlov" receiver map. The official
  kiwisdr.com/public list is deliberately gated (click-to-show +
  `x-kiwi-auth` header), so don't imitate it. The file is a JS array that's
  JSON apart from a trailing comma, ~900 KB, all values strings. Fetched
  only when the sheet opens with a cache older than 30 min, or on Refresh
  — never polled; conditional GET + app User-Agent; raw file cached at
  `~/Library/Application Support/FTX1Remote/kiwisdr_com.js`. Picking a
  station only fills the host (`WebSDRFollowModel.select`) and never
  connects (user decision); picking a different one while connected
  disconnects. A picked station's own `bands` replace the fixed 0–30 MHz
  check (persisted with the host it belongs to). Those ranges already
  include `freq_offset`, so converter-fed Kiwis (e.g. 110–142 MHz airband)
  follow the rig above 30 MHz with `?f=` in displayed kHz — built from the
  Kiwi's own link code, not yet tried against a real converter Kiwi.
  Distance sort uses `StationSettings.gridSquare` (`Maidenhead`); with no
  grid set it sorts by name and shows a hint.
- **Record/Play (2026-09-24, `KiwiPageBridge`)**: Record drives the
  Kiwi page's *own* recorder, `toggle_or_set_rec(true/false)` (its "r"
  key), via `evaluateJavaScript` — the one place the app calls into the
  page (user decision; it only calls the page's own function, nothing is
  patched). That recorder captures the decoded 12 kHz Int16 mono audio
  before the page's volume/mute, and saves by clicking a hidden
  `<a download>` blob link; `KiwiWebView`'s navigation delegate turns that
  into a `WKDownload` saved to `AudioRecorder.recordingsDirectory`, named
  like the rig's recordings plus "KiwiSDR" (`AudioRecorder.
  newRecordingURL`/`label` are now shared). The name comes from the page's
  own `freq_displayed_kHz_str_with_freq_offset`/`cur_mode`, so it's right
  with Follow off too. Saving is async, so anything that would reload or
  unload the page (retune, Return, Disconnect, window close, picking
  another station) first stops the recording and waits (≤5 s) for the
  file; a retune then starts a new file once the reloaded page's audio is
  running (user decision: one file per frequency). If the Kiwi ends a
  recording itself (its `owrx_close_cb` on connection close), the file is
  still saved and the window says so. Play opens the existing Recordings
  window (`openWindow(id: "recordings")`), same as the CW page's PLAY.
  Tested against a public Kiwi: Stop and Disconnect both save a playable
  file, which is listed in Recordings. The retune split (one file per
  frequency) was hardware-confirmed on the rig by the user, 2026-09-24.
- **Mute + automatic Main mute (2026-09-25)**: while the Kiwi is audible
  (connected and not muted by the window's Mute button) the rig's Main
  Mac playback is muted, so the two don't play over each other; muting the
  WebSDR, disconnecting or closing the window brings Main back.
  `HubService.setWebSDRAudioActive` owns this and only undoes a mute it
  made itself (`mainMutedByWebSDR`): if Main was already muted it's left
  alone, and pressing Main's own Mute hands control back to the user. The
  flag is persisted and cleared in `HubService.init` (the WebSDR window
  always opens disconnected), so a quit mid-session can't leave Main
  stuck muted — note `didSet` doesn't fire inside `init`, hence the
  explicit write there. Gates Mac playback only (iPad relay, APRS, FT8,
  recording unaffected). The Kiwi page is muted via its own
  `toggle_or_set_mute` (`KiwiPageBridge.setPageMuted`, renamed from
  `KiwiRecordingBridge`), after the page has applied its initial mute
  (`muted_until_freq_set`), and via the Kiwi's own `mute=1` URL parameter
  on each load so it survives retune reloads; `mute=` is kept out of
  `lastIssuedURL` so toggling never reloads. Kiwi recordings are taken
  before the page's mute, so muting doesn't silence a recording. Tested
  against a public Kiwi via the saved settings: each transition, the
  already-muted case, window close, and quit recovery; confirmed working
  by the user on the rig, 2026-09-25. Not synced: using
  the Kiwi page's own speaker icon doesn't update the window's Mute.
- **Click-to-tune (Kiwi → rig, 2026-09-25, hardware-confirmed by the
  user on the rig)**: "Tune rig" toggle (persisted, default on, independent
  of Follow). While a page is loaded, `KiwiPageBridge.readTuning` reads the
  page's own globals ~4×/s — `freq_displayed_Hz + kiwi.freq_offset_Hz` and
  `cur_mode`, read-only — and returns nil until `muted_until_freq_set` goes
  false (the page clears it right after applying its first frequency,
  whatever its `mute=`). The first settled reading of each page is the
  baseline and is never sent (so a bare-host page load can't retune the
  rig); after that, a change that holds for one poll sends
  `setFrequency` (+ `setMode` when `KiwiSDRURLBuilder.rigMode(forKiwiMode:
  current:)` maps it — DATA-U stays DATA-U under a Kiwi in USB, and a rig
  mode with no Kiwi token (RTTY/DATA-FM/C4FM) is never changed). Not sent
  while transmitting, in Memory mode, or with no rig frequency. Echo
  suppression in `evaluate`: no reload when the page is already at the
  rig's frequency/mode family (`kiwiAlreadyAt`; a Kiwi mode with no rig
  equivalent, IQ/DRM, counts as matching), and for 3 s after a send the
  rig's not-yet-updated value is ignored (`pendingRigTune`), re-evaluated
  when that expires. The poll restarts on each page's `didFinish` and
  stops on every new request/unload. JS read verified against a live Kiwi
  (v1.902) in a browser: initial `?f=` value, then an in-page tune.
  Tuning inside the page while recording doesn't split the file (no
  reload happens).
- **Hardware-confirmed on the real rig (user, 2026-09-24)**: retunes
  follow the FTX-1. v1.1 seams are noted in comments: JS-injection retune
  for the Kiwi, Sub following, further platforms (OpenWebRX),
  and the range of a hand-typed Kiwi host (only directory picks and
  favorites carry their own range; a WebSDR learns its range from its page).
- **Mute on TX (2026-09-26, rig-confirmed by the user)**: a
  "Mute on TX" toggle (persisted, default on) mutes the page itself while
  `rigState.ptt` is true (own undebounced `$rigState.map(\.ptt)`
  subscription), through the same `setPageMuted`/Kiwi `mute=1` paths as
  Mute (`pageShouldBeMuted` = Mute || TX). It doesn't touch `isMuted` or
  the rig's Main audio, and the page unmutes by itself after TX. Only as
  fast as the fast tier sees PTT, so a front-panel/CW-keyed TX mutes after
  a short delay; app-initiated PTT is applied at once. Testing this found
  that `getPTT` had never seen a front-panel TX: hamlib reports the
  FTX-1's TX2 state as `t` = 3 (PTT_ON_DATA), and the check was `== "1"`;
  any nonzero value now counts (Windows client fixed the same way).
- **Favorites (2026-09-25, `WebSDRFavorite`/`WebSDRFavoritesView`)**: a
  star next to the host field adds/removes the current host; the Stations
  sheet has a star column and a "Favorites only" filter; the toolbar's
  Favorites menu picks one (checkmark on the current host) and opens
  "Manage Favorites…" (rename in place, drag to reorder, per-row remove).
  Picking a favorite goes through the same `select` as a directory pick —
  fills the host and its saved ranges, never connects. Stored as JSON in
  `UserDefaults` (`webSDR.favorites`), keyed by a normalized host
  (`WebSDRFavorite.key`). The last pick is `webSDR.pickedStation` (JSON,
  replaces the old `stationBands`/`stationBandsHost` pair, migrated on
  read); it's what lets the star save a directory pick's name/location/
  ranges. A favorite saved from a typed host is named after the host until
  the directory loads, then `fillInFavorites` gives it the directory's
  name/location/ranges (a renamed one keeps its name). Manage's list has no
  row selection on purpose: in a selectable macOS `List` a click selects
  the row instead of focusing the name `TextField`. Even unselectable, a
  `List` row's plain `TextField` only takes clicks on its text, so a
  clear overlay (present only while not editing) plus a row tap gesture
  set a `@FocusState` — any click in the row except the trash button
  edits the name. Done is Escape, not
  Return, so Return only commits a rename. UI-tested in the built app,
  2026-09-25.
- **Classic WebSDR (PA3FWM's software, websdr.org; 2026-09-25)**:
  `SDRPlatform` (`.kiwiSDR`/`.webSDR`) is stored per station
  (`WebSDRFavorite.platform`, optional so older saved JSON still loads) and
  picks the URL builder (`KiwiSDRURLBuilder`/`WebSDRURLBuilder`) and the
  page JS (`SDRPageBridge`, renamed from `KiwiPageBridge`). Everything was
  checked against live servers' own `websdr-base.js`/`websdr-sound.js`
  (Twente, Maasbree), not docs:
  - First load `?tune=<kHz><mode>`; every later retune is **in place** via
    the page's own `setfreqtune()` (user decision, the same function as its
    `postMessage("tune …")` interface): no reload, no reconnect.
    `WebSDRFollowModel.retuneInPlace` handles this, and while recording
    saves the file and starts a new one (one file per frequency, user
    decision, same as Kiwi).
  - Reads `nominalfreq()` (kHz) + `mode` once `allloadeddone`. Ranges come
    from the page's `bandinfo` (centerfreq ± samplerate/2, kHz) on the first
    connect; many WebSDRs are ~200–400 kHz slices. Mute is the page's
    `#mutecheckbox` + `setmute()`, set once `did_read_settings` (no URL
    parameter; `bodyonload` resets the checkbox, and audio start applies
    it). Record is `record_click()`; its stop only leaves a "save" link
    (`#reccontrol a`), which the bridge clicks, and that save goes through
    the same `WKDownload` path as the Kiwi's.
  - **Platform detection from the page**: a host with no known platform is
    loaded Kiwi-style (`?f=`, ignored by a WebSDR). On `didFinish`,
    `detectPlatform()` checks the globals (`setfreqtune`+`bandinfo` vs
    `kiwi`), and `learnStation` records the platform, ranges and page title
    (quotes stripped) on the pick and any matching favorite. A WebSDR is
    then retuned in place, so there's no second session and no HTTP probe.
  - **Directory = websdr.org itself, embedded** (Stations sheet → WebSDR
    tab, `WebSDROrgBrowserView`). websdr.org's list JSON
    (`/~~websdrlistk`) opens with "this data may not be re-used in another
    website or automated system without prior permission –
    pa3fwm@websdr.org", so the app must never fetch or parse it (user
    decision). A main-frame navigation off websdr.org /
    websdr.ewi.utwente.nl:80 (the site's own station links) is cancelled
    and becomes the pick (`selectWebSDR`), which fills the host and never
    connects. `target=_blank`/mailto go to the default browser.
    rx.linkfanel.net mirrors only 3 WebSDRs (`static_rx.js`), so it isn't
    a usable alternative.
  - Testing note: WebKit content doesn't show in background (app_*)
    window captures; use full-screen screenshots to see the pages.
  - Tested in the built app 2026-09-25: websdr.org tab + pick,
    connect/detect/learn (Twente, and Maasbree typed by hand), Record →
    WAV, Disconnect closes the sockets. Rig-confirmed by the user the same
    day (follow in place, click-to-tune, recording split on retune).
    Some skins (Maasbree) keep the standard element IDs but hide the
    checkbox behind their own Mute button, which then won't reflect the
    app's mute state visually.
- **OpenWebRX (2026-10-01, `OpenWebRXURLBuilder`, `SDRPlatform.
  openWebRX`)**: for the operator's own receiver — an RTL-SDR (R820T,
  ~24–1766 MHz, so VHF/UHF only, no HF) on a second Pi, `raspberrypi`
  (100.104.255.14, Pi 4B), running the official `jketterl/openwebrx:stable`
  (v1.2.2) in Docker: Compose file in `~/openwebrx` on that Pi (not
  `/opt/stacks`, which is root-owned), UI at `http://raspberrypi:8073`,
  admin user created by the user. Not part of this repo. Everything below
  was checked against that server's own `receiver.js`/`owrx/*.py`:
  - Loaded once, **without** a `#freq=` hash, then always tuned in place
    (`SDRPageBridge.retuneInPlace` → the demodulator panel's `setMode` +
    the demodulator's `set_offset_frequency`). The page ignores a hash
    outside the profile the SDR is currently on, and the profile is shared
    server state, so `pageDidLoad` always retunes an OpenWebRX after load.
  - **Profiles**: a frequency outside the current profile switches to the
    first one covering it via the page's own list box +
    `sdr_profile_changed()`, then retries until the page's restarted
    demodulator has the new center (≤15 s). Profile ids come from the list
    box, ranges from `status.json` (center ± samp_rate/2), joined on
    "<SDR name> <profile name>" — the same string the server builds both
    from. `status.json` lists every *enabled* SDR, present or not, so a
    stock config's placeholder Airspy/SDRplay show up as HF coverage the
    server can't tune (the retune then times out and the status line says
    so). Remove placeholders in the OpenWebRX settings.
  - **WebKit reloads on hash changes**: OpenWebRX writes its tuning into
    `location.hash` on every change, and this WebKit (macOS 27) turns that
    fragment navigation into a full reload in a new web process ("Process
    swap due to EnhancedSecurity change" in Console) — every tune in the
    page reconnected it and dropped the window's Mute. `KiwiWebView`
    cancels OpenWebRX navigations that differ from the current URL only by
    the hash; the page works the same, its URL just isn't updated.
  - Mute is the page's `toggleMute()` (state = the button's `muted` class),
    no URL parameter. Click-to-tune reads `center_freq + offset` and the
    modulation (`readTuning`); reads are ignored while an in-place retune
    (incl. a profile switch) is running. Rig FM ↔ `nfm`; WFM, digital voice
    and DRM have no rig equivalent. No public directory — the Stations
    sheet is still KiwiSDR/WebSDR only; type the host or use a favorite.
  - **Record is app-side (2026-10-01)**, since OpenWebRX has no recorder of
    its own — the one place the window adds code to a page (user-approved
    plan; additive only, nothing patched): `SDRPageBridge.start()` connects
    a `ScriptProcessorNode` to the page's `audioEngine.audioNode` (decoded
    audio, *before* its volume/mute `gainNode`, so Mute doesn't silence a
    recording), which posts base64 Int16 blocks to the `ftx1SDRAudio`
    message handler `KiwiWebView` registers; `SDRAudioFileWriter` writes
    them as 16-bit mono WAV at the page's `AudioContext` rate (48 kHz,
    ~5.6 MB/min; not decimated, WFM needs it). The rest of the recording
    flow (timer, one file per retune, save on Disconnect/close) is the
    shared one. Tested in the built app: WFM broadcast recorded while
    Muted (real program audio, not noise), saved on Stop and on
    Disconnect; one file per retune rig-confirmed by the user the same
    day.
  - Tested in the built app 2026-10-01 against the real server with the
    rig connected on 2m: platform detection + learned name/ranges, follow
    in place (145.075 FM), profile switch on reconnect (70cm → 2m), Mute,
    in-page tuning without reload, Disconnect freeing the client slot;
    click-to-tune rig-confirmed by the user the same day.

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
    2026-09-20 when SUB showed "CH 1 Pi-STAR"), `SMeterView` (the analog S/SWR meter face, used by the Mac;
    the iPad switched to its own bar `ChannelStrip` 2026-10-09), `FilterWidthControl` (IF WIDTH picker + narrower/wider
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
  the shared `FTX1Core` `RemoteAudioStreamClient`) — Mac-only, see Architecture above. Also owns
  FT8 decoding (`FT8DecodeCoordinator`, `FT8Resampler`, `FT8Store`,
  `FT8Spot`, `FT8ListView`) — see "Digital modes — FT8" above. Also
  owns CW decoding and sending (`CWReceiver`, `CWSender`, `CWWindowView`,
  `CWSendPane`, `WebSDRAudioTap`, on CWKit) — see "Digital
  modes — CW" above. Dense
  multi-pane UI (`ContentView`: VFO, meters, scope display,
  band/mode selectors all visible at once), `SettingsView` (tabbed sheet:
  rigctld connection config, Audio input device, Station, Polling —
  `PollingSettings`, read live by the poll loops, with Restore Defaults —,
  Appearance),
  plus two menu systems: `MenuPageView` (shared, see `Sources/FTX1Core/UI/`
  above) and `DeepSettingsView` (Mac-only — the page-3 category screens,
  rendered generically from `DeepSettingsCatalog`).
- `Apps/iOS/FTX1RemoteiOS/` — iPhone app target. WebSocket client
  (`RigClientViewModel`/`RigWebSocketClient`, in `HubControlView`), except
  the receive-only "Pi direct" route (`PiDirectView` over the shared
  `PiDirectViewModel` — see "Pi-direct proof of concept" above). Focused single-rig-control view (frequency, SWR, PTT, mode grid)
  — don't try to cram the Mac's dense layout or `MenuPageView` in here
  without deciding that's actually wanted; iOS still has no menu-grid UI
  (iPad does — see below). `DeepSettingsView` isn't available to any mobile
  target yet either way (see Architecture above).
- `Apps/iPad/FTX1RemoteiPad/` — iPad app target, separate from iOS (not a
  universal/size-classes target — resolved decision, don't relitigate).
  WebSocket client, same as iOS, except the same receive-only "Pi direct"
  route (since 2026-10-06: `ContentView` is the Mac hub / Pi direct
  switch, `HubControlView` the hub screen, `PiDirectView` the Pi-direct
  one, `ChannelStrip` the per-receiver meter + mute/SQL/VOL strip both
  use — see "Pi-direct proof of concept" above). The hub screen is a dense
  layout modeled on the Mac's `ContentView` (VFO A/B side by side via the
  shared `VFODisplayBox`, PTT, power, band/mode) plus the shared
  `MenuPageView` grid. The FM page's
  6 Deep Settings buttons render a disabled "SOON" placeholder rather than
  opening `DeepSettingsView` — see the `RigController`/Deep Settings note
  above for why, and don't wire them up without first adding the wire-
  protocol read/response mechanism that unblocks it.
- `Apps/Windows/` — Windows app (C# + WinUI 3, Remote direct to the
  Pi, or Local via a spawned `rigctld.exe`). `FTX1RemoteWindows/` has a
  build-verified v1 skeleton (core rig control only; Local mode added
  after, hardware-confirmed on the user's PC 2026-09-27) — see `Apps/Windows/README.md` for the full plan, porting
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
