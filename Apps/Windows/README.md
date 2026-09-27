# FTX1Remote for Windows — plan

Status (2026-09-07): **v1 skeleton scaffolded and building.**
`Apps/Windows/FTX1RemoteWindows/` has a working unpackaged WinUI 3 project
— `RigctldClient`/`RigMode`/`BandPlan`/`RigState` ported per the table
below, and a `MainWindow` wiring up the full v1 checklist (VFO A/B, mode,
band, PTT, power, SWR, connect/disconnect with a 1s poll loop). Verified
with a real `dotnet build -r win-x64 --self-contained` on this machine
(produces `FTX1RemoteWindows.exe`) — not yet run against a live Pi, since
this session has no radio/Tailscale access. Still missing: app icon/MSIX
packaging (see "Open items"), and everything in "Explicitly deferred"
below.

Update (2026-09-27): **Local (direct USB) connection mode added**, the
Windows counterpart of the Mac's `.local` mode — see "Local mode" below.
Written without a Windows machine at hand; **built and run on the user's
Windows PC the same day** (`dotnet run`, .NET 10 SDK) and reported working
as expected. The individual items of the checklist under "Local mode"
haven't been reported one by one yet.

Building needs the .NET 8 SDK or newer — that PC only had the .NET 5 SDK
at first, which fails with `NETSDK1045` ("does not support targeting .NET
8.0"); `winget install Microsoft.DotNet.SDK.10` fixed it. It also keeps the
repo under OneDrive, which can lock `bin\`/`obj\` files mid-build — pause
syncing or clone outside OneDrive if a build hits "file in use".

**Audio playback added 2026-09-27** — see "Audio" below. Tested end to end
against a local fake Pi (a stand-in rigctld plus a copy of
`ftx1-audiostream.py`'s single-client accept loop streaming test tones), not
yet against the real Pi/rig. Local mode (the PC's own sound-card input)
followed the same day and was tested capturing the real FTX-1's USB audio
on the user's test PC — see "Audio".

**Toolchain note for whoever picks this up next:** the .NET SDK (10.0.400)
is installed on this machine at `C:\Program Files\dotnet` but isn't on
`PATH` in either PowerShell or Git Bash — invoke it by full path, add it to
`PATH`, or just open the project in Visual Studio, which finds it
regardless.

## What this is

A Windows app with the same *kind* of functionality as the Mac app
(`Apps/Mac/FTX1RemoteMac/`). It started remote-only: it talks to the
Raspberry Pi directly (rigctld for control, `ftx1-audiostream.py` for audio
— see repo root `CLAUDE.md`'s "Remote rigctld (Option A)" section and
`Pi/README.md` for the Pi side), never through the Mac. Since 2026-09-27 it
can also drive a radio plugged into the Windows PC's own USB port, by
launching hamlib's `rigctld.exe` locally — same Local/Remote split as the
Mac (see "Local mode" below). The repo root [`README.md`](../../README.md) also summarizes this app
in its Architecture section — this file is the detailed plan/status.

## Why direct-to-Pi, not through the Mac hub

Considered and rejected: making this app a `RigWebSocketClient` of the
Mac's hub, like iOS/iPad. Rejected because:

- It would require the Mac app to be running for the Windows app to work at
  all — direct-to-Pi has no such dependency, matching how the Mac itself
  works when `RigctldSettings.connectionMode == .remote`.
- The WebSocket wire protocol (`Sources/FTX1Core/Networking/WireMessage.swift`)
  has no request/response mechanism, only fire-and-forget `RigCommand` and
  one-way `RigStatePush` — a WebSocket client can never support Deep
  Settings (see `RigController.supportsDeepSettings`'s doc comment). A
  direct rigctld link *can*, later, the same way the Mac's `HubService`
  does today.

So architecturally this app is closest to the Mac's own local/remote
split, minus:

- In Remote mode, no process management — the Pi's `rigctld.service` is
  always-on; this app never spawns, adopts, or kills anything there. (Local
  mode does, see below.)
- No WebSocket *server* — this app is a leaf client, nothing connects
  downstream of it. (The Mac, Windows, and iOS/iPad apps end up as three
  independent consumers of the Pi; the Mac is no longer in the loop for
  Windows sessions at all.)

```
Remote:  Windows app  ──TCP:4532 (rigctld text protocol)──►  Pi (rigctld.service)
                      ──TCP:8532 (raw PCM, phase 2+)──────►  Pi (ftx1-audiostream.py)

Local:   Windows app  ──TCP 127.0.0.1:4532──►  rigctld.exe (spawned or adopted)
                                                   └──COMx──►  FTX-1 (USB)
```

## Tech stack

- **C# + WinUI 3**, MSIX-packaged (single-project MSIX via
  `<WindowsPackageType>MSIX</WindowsPackageType>`, no separate packaging
  project needed on modern .NET).
- Minimum Windows 10 1809 (WinUI 3 / Windows App SDK's floor) — acceptable
  per user, not Windows 11-only.
- No code is shared with the Swift targets — Swift/SwiftUI isn't viable on
  Windows, so this is a clean C# implementation. Where Swift types are the
  source of truth for a protocol or model shape, port the *shape*, not the
  code — see the table below.
- Lives in this repo at `Apps/Windows/FTX1RemoteWindows/` (decided
  2026-09-07 over a separate repo, since despite sharing no code it's
  conceptually the same product and should version alongside the Mac/Pi
  sides).

## What gets ported (shape, not code) from `Sources/FTX1Core`

| Concern | Swift source of truth | C# equivalent |
|---|---|---|
| rigctld wire protocol | `Networking/RigctldClient.swift` — plain-text TCP, one write+read round trip at a time via an actor-held lock (`roundTripBusy`/`roundTripWaiters`) | `RigctldClient` over `System.Net.Sockets.TcpClient`; a `SemaphoreSlim(1,1)` around each write+read pair for the same reason — rigctld's protocol is strictly request/response, and this app has more than one caller issuing commands (poll loop + user-triggered sets) |
| State model | `RigState/RigState.swift` | POCO with just the v1 fields: `frequencyHz`, `mode`, `band`, `powerWatts`, `swr`, `ptt`, `secondaryFrequencyHz`, `secondaryMode`, `powerLevel` — not the full ~40-field struct, most of which is CW/menu/display state out of v1 scope |
| Poll loop | `HubService.refreshState()` (Mac app target) | Timer-driven poll; **each field read wrapped so a single bad/garbled CAT reply falls back to the last-known value instead of tearing down the connection.** This is not optional polish — it's a hard-learned lesson: the 2026-09-07 Option A validation found exactly this bug (`getFrequency()` was the one unwrapped call in the whole cycle, and an occasional bad reply over the Tailscale hop was tearing down and reconnecting the whole session). Build it in from the start rather than rediscovering it. |
| Commands issued | Subset of `Networking/WireMessage.swift`'s `RigCommand` cases: `setFrequency`, `setSecondaryFrequency`, `swapActiveVFO`, `setMode`, `setPTT`, `setBand`, `setPowerLevel` | Direct method calls on the C# `RigctldClient` (e.g. `SetFrequencyAsync(hz)`). No need to reconstruct `RigCommand`'s JSON shape at all — this app never speaks the WebSocket protocol, so skip `WireMessage.swift`'s design entirely. |
| VFO/S-meter UI | `UI/VFODisplayBox.swift`, `UI/SMeterView.swift` | WinUI 3 `UserControl`s, visually modeled on these (side-by-side VFO A/B; analog-style S/SWR meter face) |

## Settings

A "Radio:" mode picker (Remote / Local, `AppSettings.ConnectionMode`,
defaulting to Remote so a pre-Local settings file behaves as before), then:

- **Remote**: Pi hostname (Tailscale MagicDNS, e.g. `ftx1-pi`) — port fixed
  at 4532, not user-configurable, matching `RigctldSettings.remoteHost`
  (`Apps/Mac/FTX1RemoteMac/RigctldSettings.swift`).
- **Local**: path to `rigctld.exe` (with a Browse button; no default, since
  hamlib's installer uses a version-numbered folder), COM port (editable
  drop-down listing the ports in `HKLM\HARDWARE\DEVICEMAP\SERIALCOMM`,
  refreshed each time it opens), and baud rate (default 38400). The hamlib
  model number (1051) is stored but not shown.

Unlike the Mac, switching mode doesn't need a relaunch — this app builds a
fresh `RigctldClient` on every Connect — but the settings are locked while
connected. Persist via `ApplicationData.Current.LocalSettings` (available for free
once MSIX-packaged).

## Reconnect / connection-state UI

Mirror the Mac's `.remote`-mode timeout tuning (single shared constant
sized for a Tailscale hop; no "fresh start" grace period, since nothing is
ever locally spawned here — same reasoning as `HubService`'s `.remote`
branch skipping `isFreshStart`).

Do one thing *better* than the Mac from day one, since this is new code
with no legacy shape to preserve: the Mac's CLAUDE.md flags an open TODO to
distinguish "Pi/Tailscale unreachable" vs. "rigctld/radio down but the Pi
itself is fine" as two different UI states, since they point to different
fixes, but `RigctldError`/the Mac's connect catch site don't carry enough
information to tell them apart yet. Design the Windows connection-error
type with that split from the start — a TCP-connect-level failure is a
different case from a TCP-connected-but-malformed-or-absent-CAT-reply
failure.

## Local mode

`Services/RigctldProcessController.cs` is a port of the Mac's
`RigctldProcessController.swift`, same behavior:

- On Connect it probes `127.0.0.1:4532`. A responsive rigctld is
  **adopted** and left running on Disconnect/exit (WSJT-X or another client
  may be using it — its COM port/baud rate are whatever it was started
  with). One that accepts the connection but doesn't answer is treated as
  stale and killed. Windows has no port→PID lookup without P/Invoke, so
  this kills processes *named* `rigctld`, unlike the Mac's `lsof` check.
- Otherwise it spawns `rigctld.exe -m 1051 -r COMx -s <baud> -t 4532
  -T 127.0.0.1 -o -C timeout=300,retry=0` (the Mac's arguments, same
  reasons — see its comments) with no console window, stderr captured.
- A spawned rigctld gets a 10 s grace period to open the port. Connect only
  succeeds once a frequency read works: hamlib 4.x's rigctld keeps listening
  even when it couldn't open the rig, so "port open" alone would show
  Connected with nothing updating. Failures quote rigctld's last stderr
  lines (e.g. `rig_open: error = IO error`).
- A spawned rigctld is killed on Disconnect and when the window closes. If
  it exits on its own mid-session, the app disconnects and shows why.
- Not ported: the Mac's separate PTT-port option (`RigctldSettings.pttPort`,
  itself unconfirmed on hardware); PTT goes over CAT on the main port.

WSJT-X on the same PC can share the radio by pointing its "Hamlib NET
rigctl" at `localhost:4532` — or start rigctld yourself and this app adopts
it.

Hardware checklist (user, on the rig, 2026-09-27) — all passed:

- [x] Builds (.NET 10 SDK) and connects with the right COM port.
- [x] Wrong COM port → "Connect failed: …" error.
- [x] Disconnect leaves no `rigctld.exe` running (`tasklist | findstr
      rigctld`).
- [x] Closing the window while connected leaves none either.
- [x] Radio off → "rigctld is running but the radio isn't answering…".
      First try (2026-09-27) failed correctly but said "couldn't reach
      rigctld … (The operation was canceled)": each timed-out read
      reset the connected flag, so the final message picked the wrong
      branch. Fixed, and re-tested correct.
- [x] An already-running rigctld is adopted ("Connected to
      already-running rigctld on localhost:4532") and still runs after
      Disconnect. The first try failed only because the radio was still
      off from the previous test: with no reply the probe judged it stale,
      killed it and spawned its own — by design, same as the Mac, though
      killing a user-started rigctld whose radio is merely off is
      debatable.
- [x] PTT keys the rig.

## v1 scope

Core rig control only:

- VFO A/B display (frequency, active/inactive indicator, swap)
- Mode selector
- PTT indicator/control
- Power level control + metered SWR
- Band selection
- Connect/disconnect + live connection-state indicator (with the
  unreachable-vs-down distinction above)

## Audio (Main/Sub playback)

Two sources behind one interface (`Services/IAudioSource.cs`), picked by
the connection mode — the Windows counterpart of the Mac feeding one
`process()` from both its local tap and its remote client. Both deliver
Main (left) / Sub (right) float chunks of 2048 samples, so everything
downstream (squelch, swap routing, playback, levels) is shared.

- **Remote**: a second TCP connection to the Pi's `ftx1-audiostream.py` on
  :8532, next to the rigctld link. Wire format: raw interleaved-stereo
  Int16 LE, 44100 Hz, Main on the left channel and Sub on the right, no
  framing (see that script's doc comment).
- **Local** (`Services/LocalAudioCapture.cs`): NAudio `WasapiCapture`
  (shared mode) on the input chosen under **Audio in** in the Local
  settings row, at the device's own rate (48 kHz for the FTX-1's codec on
  the test PC, which shows up as "Microphone (2- USB Audio Device)"). The
  picker lists active recording devices; with nothing saved it pre-selects
  the only one named "USB Audio", if there's exactly one. It stays enabled
  while connected (a change restarts capture), and a saved device that
  isn't plugged in stays listed as "(not connected)". A missing/removed
  device or a capture error shows "Audio input unavailable" and retries
  every 3 s; a microphone-privacy denial says which Windows setting to
  turn on. A mono device gives Main only and says so. **Feedback guard**:
  if Windows' default output is the same adapter as the input (the rig's
  own codec), playback is refused — it would feed the rig's TX audio input.
  Tested 2026-09-27 against the real rig's audio with the fake rigctld
  (so CAT never touched the radio): capture at 48 kHz, playback reaching
  the output device, the missing-device message and picker entry. Sub read
  near-silent (right-channel peak ~0.0001) during that test, most likely
  single-receive display or a quiet Sub — not yet confirmed with the rig
  in dual-VFO display.

- `Services/RemoteAudioStreamClient.cs`: port of the Mac's
  `RemoteAudioStreamClient.swift`. Has its own reconnect loop (3 s), splits
  the stream into Main/Sub float chunks of 2048 samples, and reports
  `AudioLinkPhase`: Connecting / Unreachable (the TCP connect failed) /
  WaitingForStream / Streaming.
- **The Pi serves one audio client at a time** (`listen(1)` and a serial
  accept loop — left that way on purpose, user decision 2026-09-27). If the
  Mac already has the stream, our connect still completes into the Pi's
  listen backlog and then no data arrives. The client treats "connected, no
  bytes for 2 s" as WaitingForStream, keeps the socket open, and picks the
  stream up as soon as the other client disconnects (tested against the
  fake Pi). The window's **Audio** switch (persisted) closes the link, so
  the Mac can have the stream while this app keeps rig control.
- `Services/ChannelPlayer.cs`: one per receiver. A 120 ms prime jitter
  buffer (it re-primes after an underrun and caps at 500 ms, dropping the
  oldest audio, since the Pi's and this PC's sound-card clocks drift), the
  quieting-dip squelch (`Services/SquelchGate.cs`, a straight port of
  `SquelchGate.swift`), volume, and mute, with ~10 ms gain ramps.
- `Services/AudioPlayback.cs`: mixes both channels into one NAudio
  `WasapiOut` (shared mode, default output device), resampled to the
  device's mix rate with NAudio's WDL resampler. Both channels play
  centered, like the Mac.
- UI: under the mode row there's MAIN and SUB, each with Mute, VOL, SQL
  (inverted, same 0-0.05 range as the Mac's) and a squelch-open light, plus
  the link state and per-channel RMS (a quick L/R separation check).
  Settings are in `settings.json` with the Mac's `AudioPlaybackSettings`
  defaults (volume 0.8, threshold 0.015).
- Audio runs only while the rig link is connected (it starts on Connect and
  stops on Disconnect or window close).

**Swap tracking (2026-09-27)**: after a Main/Sub swap, the rig's L/R audio
stays with the physical receiver (see root `CLAUDE.md`'s "Swap tracking").
`Services/AudioChannelSwapTracker.cs` ports the Mac's logic. The flag flips
on the app's ⇄ (except in single-receive display, read from raw "FR" every
5th poll), when the polled Main/Sub frequencies exchange (a front-panel
swap; only in VFO mode, from raw "VM0" each poll), or with the speaker
toggle under ⇄ (the manual override, highlighted while swapped). When
swapped, L goes to the SUB player and R to MAIN. The flag is persisted, as
on the Mac. A poll that saw an app VFO command land mid-cycle skips
tracking (`_commandGeneration`, like the Mac's `commandGeneration`), and
polls no longer overlap when one outlasts the 1 s tick.

This also fixed ⇄ itself: it sent hamlib `V <other VFO>`, which this rig
maps to "VS" (VFO SELECT, changes the active side), not a swap. That's the
same mistake the Mac fixed on 2026-09-17. It now sends raw "SV".
`RigctldClient` gained the raw CAT passthrough this needs
(`SendRawCommandAsync`/`SendRawFireAndForgetAsync`/`GetRawIntAsync`,
ported from the Swift client: `W <cmd>; ;`, reply terminated by `\n` or
`\0`, 1 s timeout followed by a reconnect, and stale bytes dropped before
each write). Tested against the fake Pi (app swap, no double flip on the
following polls, front-panel swap, both in single-receive, manual override,
persisted state on relaunch, an unanswered raw command not wedging the
poll loop), not yet on the rig.

Not done yet:
- Output device picker (always the default device).
- Local mode: no automatic check that the input device is really the
  rig's (it only pre-selects by name).
- Waterfall/oscilloscope from the same samples (the chunking already
  matches the Mac's 2048-sample FFT size).

## Explicitly deferred (not v1, but not architecturally foreclosed either)

- **MENU grid** (`UI/MenuPageView.swift` port) and **Deep Settings**
  (`MenuSettings/DeepSettingsCatalog.swift` port) — Deep Settings is
  actually *feasible* here, unlike on iPad, because this app has the same
  direct per-item-read capability the Mac's `HubService.readMenuItem` has
  (see "Why direct-to-Pi" above). Not a blocked feature, just not v1.
- **Waterfall/oscilloscope** — an FFT over the Main samples the audio
  client already delivers (see "Audio" above), drawn with a WinUI 3
  `CanvasControl`/Win2D waterfall.
- **APRS decode** — the AFSK/AX.25 stack (`APRS/AFSKDemodulator.swift`,
  `AX25Frame.swift`, `APRSPacket.swift`) is the most DSP-heavy piece to
  port; leave until audio capture itself is working.

## Open items still to settle before/at implementation start

- Whether wiring/CAT-mnemonic correctness for v1's raw commands (mode,
  band, PTT, power) needs independent hardware verification against the
  CAT Operation Reference Manual the way `MenuPageView`/
  `DeepSettingsCatalog` did on the Mac — the working conventions in root
  `CLAUDE.md` about not trusting the manual at face value apply equally
  here, even though v1's command set is small and mostly already
  hamlib-standard (frequency/mode/PTT) rather than raw CAT passthrough.
- App icon / MSIX packaging identity (publisher, package name) — not
  decided yet. The scaffolded project deliberately builds unpackaged
  (`WindowsPackageType=None` in the `.csproj`, see its comment) specifically
  so `dotnet build` works without these; flip to `MSIX` once there's a real
  icon.
- CW/menu/display fields, `WireMessage.swift`'s full `RigCommand` set, and
  the WebSocket wire protocol were deliberately *not* ported — this app
  never speaks WebSocket (see "Why direct-to-Pi" above), so `RigCommand`'s
  JSON shape is irrelevant here; v1's C# `RigctldClient` calls rigctld
  methods directly instead.
- C4FM mode is not wired up in v1's `RigMode`/`RigctldClient.SetModeAsync`
  — it needs the same raw-CAT-passthrough special case
  `RigctldClient.swift`'s `setActiveModeC4FM()` uses, left out of this pass
  since it isn't one of hamlib's generic `M` command's mode strings.
- Band selection always jumps to the band's default calling frequency —
  there's no C# equivalent yet of the Mac's `BandMemory` (per-band "last
  used frequency"); add it if that turns out to matter in practice.

## Current file layout

```
Apps/Windows/FTX1RemoteWindows/
  FTX1RemoteWindows.csproj   unpackaged WinUI 3, net8.0-windows10.0.19041.0
  app.manifest               DPI-awareness manifest (unpackaged apps need this)
  App.xaml(.cs)               standard WinUI 3 application entry point
  MainWindow.xaml(.cs)        v1 core-rig-control UI + 1s poll loop + audio controls
  Models/
    RigMode.cs                 hamlib mode vocabulary — Sources/FTX1Core/RigState/RigState.swift's RigMode
    BandPlan.cs                 band table — Sources/FTX1Core/RigState/BandPlan.swift
    RigState.cs                 v1 subset of RigState.swift's fields
  Services/
    RigctldClient.cs             TCP client for rigctld's text protocol
    RigctldProcessController.cs  Local mode: spawns/adopts rigctld.exe (port of the Mac's)
    RemoteAudioStreamClient.cs   TCP client for ftx1-audiostream.py (:8532), Main/Sub split
    ChannelPlayer.cs             per-receiver jitter buffer + squelch/volume/mute
    SquelchGate.cs               port of SquelchGate.swift
    AudioPlayback.cs             NAudio WASAPI output mixing Main + Sub
  Settings/
    AppSettings.cs                connection mode, Pi hostname, Local rigctld settings, audio settings; file-based (see its doc comment on why not LocalSettings yet)
```
