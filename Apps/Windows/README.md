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
  Stopping the app any other way (Ctrl+C on `dotnet run`, Task Manager)
  skips that and leaves it running; the next Connect adopts it.
- Not ported: the Mac's separate PTT-port option (`RigctldSettings.pttPort`,
  itself unconfirmed on hardware); PTT goes over CAT on the main port.
- COM port box: the saved port is shown by *selecting* it in the list
  (added to the list if it isn't currently there), once the box has
  loaded. Setting an editable ComboBox's `Text` from code doesn't display
  in WinUI 3, which left the box blank on every launch (only the "COM3"
  placeholder showing) and made Connect save an empty port (fixed
  2026-09-27).
- **COM number clash on the test PC (2026-09-27)**: the list comes from
  `HKLM\HARDWARE\DEVICEMAP\SERIALCOMM`, which holds one entry per COM
  name. A Bluetooth serial link took COM4, the CP2105 Enhanced (CAT) port
  also numbered COM4 failed to start (Device Manager: code 31), and no
  listed port could reach the radio — COM3–5 were Bluetooth, COM6 is the
  CP2105 *Standard* port, which doesn't carry CAT. Fixed by renumbering the
  Enhanced port to COM7 in Device Manager (Port Settings → Advanced) and
  replugging. If every port fails to connect, check Device Manager for a
  warning on the Enhanced port first.

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

## Transmit gate (Enable Transmit, 2026-09-27)

Port of the Mac's safety cutoff (`HubService.transmitEnabled` + the
out-of-band check in `HubService.send`). `Services/TransmitGate.cs` is the
one check every transmit-capable action must pass: PTT on, MOX on, CW
MESSAGE play, ANT TUNE start (same set as the Mac's `isTransmitCapable`;
PTT and the MENU grid's MOX and ANT TUNE use it so far — CW MESSAGE play
must call `TransmitGate.BlockReason` too if it's ever enabled). Blocked while Enable
Transmit is off, or while the Main VFO is outside a `BandPlan` band
(including before the first frequency read). The off direction is never
gated.

- The "Enable Transmit" switch sits next to PTT, applies at once, and is
  persisted in `settings.json` (`TransmitEnabled`, default on so older
  settings files keep working).
- Switching it off sends PTT off and MOX off ("MX0") straight away,
  unconditionally, rather than only if the last poll saw them on.
- PTT is momentary (hold to transmit, release to unkey), like the Mac and
  iPad — it was a click-on/click-off toggle before. A `Border`, not a
  `Button`, so the red "TRANSMITTING" background isn't overridden by the
  Button template's hover/pressed states. It dims to 0.4 while blocked,
  with the reason as its tooltip, but stays pressable: every release sends
  PTT off (as the Mac's `onEnded` does), so it can also unkey a TX started
  elsewhere. The press handler checks the gate again. Disconnect or window
  close while held unkeys first.
- Not done, same as the Mac: nothing unkeys a TX started elsewhere (front
  panel, WSJT-X through the same rigctld) while the switch is already off.

Hardware checklist (not yet run):

- [ ] Switch off → PTT dimmed, tooltip "Transmit disabled"; on → PTT works.
- [ ] Key the rig, then switch off → it unkeys at once. With PTT now
      momentary a mouse can't hold it and click the switch, so key from
      the front panel or WSJT-X (the force-unkey is unconditional, so it
      unkeys those too), or hold PTT by touch.
- [ ] Tune outside a band (e.g. 15.000 MHz) → PTT dimmed with the
      out-of-band tooltip.
- [ ] Setting survives an app restart.
- [ ] Hold PTT → keys, button red "TRANSMITTING"; release → unkeys. Also
      release outside the button/window, and a quick tap.

## MENU grid (2026-09-28, SSB and CW pages)

Port of `Sources/FTX1Core/UI/MenuPageView.swift`, one page at a time.
`Controls/MenuGrid.cs` is a code-built `UserControl` (7×4 `Button`s, the
rig's own item numbers) hosted under the audio row; the window now scrolls
so it fits a smaller window. Each button sends the same raw CAT command the
Mac's `CommandQueue.swift` does, straight to rigctld, and the page's
settings are read in the slow poll tier (every 5th poll, ~5 s) with the
same reads as `HubService.refreshSlowTier` — but only the page on screen,
and a page switch reads the new page at once (the Mac reads every page
every tier; this keeps the tier from growing as pages are added). Pages
are picked from a tab bar above the grid (the Mac's segmented picker) or
the ◀/▶ buttons (22/28), which keep each other in step. New `RigctldClient` helpers
mirror the Swift ones: `GetRawBool`/`SetRawBool`/`SetRawInt`/
`GetRawDigit`/`SetRawPackedDigit`, the "SS04" signed dB pair, "AC" tuner
read, "DA" triple, and `GetMenuItem`/`SetMenuItem` ("EX").

- Button kinds as on the Mac: toggles flip on a tap, small choice sets
  cycle on a tap, numeric ranges open a flyout stepper (− value +, sends
  on every step, hold to repeat), RF POWER a flyout slider that sends on
  release. A set updates the button at once and bumps a command generation;
  a slow-tier read that overlapped a set is discarded, like the Mac's.
- MOX and ANT TUNE go through `TransmitGate` (disabled while it would
  block, and checked again on click). MOX stays clickable while on, so it
  can always be turned off.
- AGC/MIC EQ ("GT0"/"PR1") aren't read while the mode reads back as
  unrecognized (this app's `RigMode` has no C4FM): the rig doesn't answer
  them in C4FM and each miss costs a 1 s timeout plus a reconnect.
- Values are cleared on each Connect; the grid is disabled while
  disconnected. SSB: D-COLOR and TXW are disabled placeholders, 17 is
  empty. CW: MESSAGE is a disabled placeholder (as on the Mac, where it
  was unreliable; its play must pass `TransmitGate` if it's ever enabled),
  and PLAY/RECORD are too, since this app has no audio recorder yet (on
  the Mac they record the app's own audio and open the Recordings window).
  CW's empty items (3-7, 15-18, 23-27) are left out. The FM/C4FM tab and
  CW's ▶ FM are disabled until that page is ported.
- Checked against a fake rigctld (logs every line, answers raw reads in the
  FTX-1's reply shapes): every read parses, and every write matched the
  Mac's bytes — e.g. `RA00`, `PA02`, `GT00` (from AUTO's read-back 6),
  `SS0130000`, `SS04+04.5`, `AC100`, `AC103`, `EX0307040`, `PR11`, `MX1`,
  `NL0004`, `RL004`, `VD11`, and `DA00091512` with the other two "DA"
  fields preserved. RF POWER's slider wasn't driven by that test. CW, same
  test: `ML1061`, `KR0`, `BI1`, `KS021`, `KP41`/`KP42` (700 → 710 → 720 Hz),
  `SD05` (300 → 250 ms), `ZI0`, `CS1`, and each page switch read only the
  new page's settings, straight away.

Hardware checklist, SSB page (not yet run):

- [ ] Every button shows the rig's current value within ~5 s of Connect
      (compare with the rig's MENU page 1).
- [ ] Each toggle/cycle changes the rig and the button, and changing it
      on the rig's front panel shows up here within ~5 s.
- [ ] D-LEVEL steps in 0.5 dB, including below 0 (e.g. −0.5, sent as
      `SS04-00.5`); D-CONTRAST/DIMMER don't disturb each other.
- [ ] AGC shows AUTO while the rig is in AUTO, and tapping it from AUTO
      goes to OFF.
- [ ] VOX DELAY steps 30, 50, 100 … 250, 300, 400 ms, matching the rig.
- [ ] RF POWER flyout slider sets power on release; the main power slider
      follows (and vice versa).
- [ ] MOX and ANT TUNE: disabled with Enable Transmit off or out of band;
      MOX on keys, MOX off unkeys; switching Enable Transmit off while MOX
      is on unkeys.
- [ ] Switch to C4FM: AGC/MIC EQ keep their last values and polling
      doesn't stall or reconnect.

Hardware checklist, CW page (not yet run):

- [ ] ▶ CW (or the CW tab) shows the rig's CW values within a second or
      two, not after the next ~5 s poll; ◀ SSB goes back the same way.
- [ ] KEYER, BK-IN and CW SPOT change the rig; front-panel changes show
      up here within ~5 s.
- [ ] CW SPEED 4-60 WPM; CW PITCH 300-1050 Hz in 10 Hz steps; both match
      the rig's display.
- [ ] BK-DELAY steps 30, 50, 100 … 250, 300, 400 ms, matching the rig.
- [ ] MONI LEVEL 0 shows OFF and the rig's monitor is off at 0.
- [ ] ZIN zero-ins the MAIN side on a CW signal.
- [ ] MESSAGE, PLAY and RECORD are disabled, PLAY/RECORD with a "not built
      on Windows yet" tooltip.

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
  if the output playback would use (the "Out" choice, or Windows' default)
  is the same adapter as the input (the rig's own codec), playback is
  refused — it would feed the rig's TX audio input. Windows makes a freshly
  plugged USB audio device the default output, so with "Windows default"
  this happens after every replug of the radio; while blocked, the app
  rechecks every 2 s and starts playback once the output isn't the radio.
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
  `WasapiOut` (shared mode), resampled to the device's mix rate with
  NAudio's WDL resampler. Both channels play centered, like the Mac. The
  device is the Audio row's **Out** picker (both modes): "Windows default"
  or a specific output, saved by endpoint ID. A chosen device that isn't
  plugged in stays listed as "(not connected)" and playback falls back to
  the default output with a note. Changing it restarts only playback, not
  the audio source. Playback stays on the device it opened even if Windows'
  default changes mid-session. Tested 2026-09-27 (by which endpoint held
  the app's audio session): default, a specific device, the radio's own
  output (refused), an unplugged device (fallback), and live switching.
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
- Local mode: no automatic check that the input device is really the
  rig's (it only pre-selects by name).
- Waterfall/oscilloscope from the same samples (the chunking already
  matches the Mac's 2048-sample FFT size).

## Mac parity plan (2026-09-27)

The order for bringing this app up to the Mac's feature set. Each step is
meant to be its own change, built, committed and hardware-checked before
the next one starts.

1. **Transmit safety gate — done** (`bc4f5f8`, build-verified, not yet
   hardware-tested; see "Transmit gate" above). Port the Mac's Enable
   Transmit: gate exactly PTT on, MOX on, CW MESSAGE play and ANT TUNE
   start; force-unkey at once if it's switched off mid-transmit; dim the
   controls while it's off. It came first because it's the one gap with
   Part 97 consequences: nothing else that can transmit gets added before
   it.
2. **PTT press-and-hold — done** (`89c5aa8`, build-verified, not yet
   hardware-tested). PTT is momentary, like the Mac and iPad, instead of a
   click toggle.
3. **The 28-item MENU grid — in progress, one page per change.** Port the
   CAT mappings `MenuPageView.swift`/`RigState.swift` already use to C#,
   sent straight to rigctld the way the Mac does. This copies command logic
   that already works; it doesn't need new reverse-engineering. Its MOX,
   ANT TUNE and CW MESSAGE play buttons must go through `TransmitGate`
   (step 1). Pages 1 (SSB) and 2 (CW) done 2026-09-28, build- and
   fake-rigctld-verified, not yet hardware-tested (see "MENU grid" above);
   FM/C4FM next.
4. **Graphical S-meter.** The same analog meter the Mac and iPad draw
   (`UI/SMeterView.swift`). The plan called this replacing a text-only
   S-meter, but this app has no S-meter readout yet (only power out and
   SWR as text), so the signal-strength read is new here too, not just
   drawing.
5. **V/M memory toggle and channel stepping.** The memory-mode toggle, get/
   set/step of the channel number, and the channel tag. The Mac has these;
   iPad doesn't have the button wired yet, so Windows can get ahead here.
   Reuse the Mac's read-then-set toggle that fixed its "backwards toggle"
   bug.
6. **C4FM callsign display.** Port the WPSD hotspot-page scrape (an HTTP
   GET and parse, no CAT or rigctld involved) that the Mac and iPad use to
   show the active C4FM callsign and reflector.
7. **Full Settings UI.** Give it the Mac's tab layout: rigctld connection
   (host, model, serial port, baud), per-band home frequency, Appearance,
   plus Audio and APRS tabs as placeholders until those features exist.
   The plan's "Pi host only" starting point is out of date: the main
   window already has the Local-mode fields (rigctld path, COM port, baud)
   and the audio device pickers, which would move into Settings.
8. **Deep Settings (the 341-item catalog).** Port `DeepSettingsCatalog`'s
   table-driven EX P1/P2/P3 passthrough to C#, straight to rigctld. This is
   what talking to rigctld directly (not through the Mac's hub) pays for:
   iPad can't have it until the wire protocol gets request/response, but
   this app doesn't need to wait. The biggest item, so it goes last, once
   steps 3–6 have proven the direct-rigctld command patterns.

## Explicitly deferred (not v1, but not architecturally foreclosed either)

- **Deep Settings**
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
  Controls/
    MenuGrid.cs                  MENU grid (port of MenuPageView.swift), SSB and CW pages so far
  Models/
    RigMode.cs                 hamlib mode vocabulary — Sources/FTX1Core/RigState/RigState.swift's RigMode
    BandPlan.cs                 band table — Sources/FTX1Core/RigState/BandPlan.swift
    RigState.cs                 subset of RigState.swift's fields (core + MENU grid pages)
    RigDelayCode.cs             "SD"/"VD" 00-33 delay code ↔ ms
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
