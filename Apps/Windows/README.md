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
  direct rigctld link can, the same way the Mac's `HubService` does
  (done in parity plan step 8).

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

`SettingsDialog.xaml(.cs)`, opened by the **Settings** button next to
Connect: a `ContentDialog` with the Mac's tabs (`SettingsView.swift`) along
a `SelectorBar`. Stored in `settings.json` (`Settings/AppSettings.cs`).
Unlike the Mac, where only the rigctld tab waits for Done, nothing is
written until **Save**, and Cancel discards every tab. What Save changed is
applied at once, also while connected, except the rigctld tab (below).

- **rigctld**: Connection (Remote / Local, `AppSettings.ConnectionMode`,
  defaulting to Remote so a pre-Local settings file behaves as before), then
  - **Remote**: Pi hostname (Tailscale MagicDNS, e.g. `ftx1-pi`) — port
    fixed at 4532, not user-configurable, matching
    `RigctldSettings.remoteHost` (`Apps/Mac/FTX1RemoteMac/
    RigctldSettings.swift`).
  - **Local**: path to `rigctld.exe` (with a Browse button; no default,
    since hamlib's installer uses a version-numbered folder), hamlib model
    number (1051, the FTX-1), COM port (editable drop-down listing the
    ports in `HKLM\HARDWARE\DEVICEMAP\SERIALCOMM`, refreshed each time it
    opens), and baud rate (default 38400; 4800–115200, plus a hand-set
    value from settings.json).

  Unlike the Mac, switching mode doesn't need a relaunch — this app builds
  a fresh `RigctldClient` on every Connect — but the tab is read-only while
  connected. The connection bar says which connection Connect will use
  ("Disconnected · Remote, ftx1pi"); Connect with no Pi host (Remote), or
  no rigctld.exe or COM port (Local), points at Settings instead.
- **Audio**: the Local-mode input device and the playback output device
  (see "Audio" below). The Audio on/off switch and the MAIN/SUB mute,
  VOL and SQL stay in the main window.
- **C4FM**: the WPSD hotspot callsign lookup (on/off + hotspot address; a
  pasted "http://" and trailing "/" are stripped).
- **APRS**: a placeholder until APRS decoding is ported.
- **Home Freq**: the MENU grid HOME button's frequency per band group
  (`HomeBand`, `AppSettings.HomeFrequencyHz`), in MHz. Must lie inside
  its group; empty restores the factory frequency, and only frequencies
  that differ from the factory one are stored.
- **Polling**: the poll interval (default 500 ms, 100–5000), how often the
  slow tier runs (every 10th poll, 1–60 — the Mac spreads its slow reads
  over every tick instead, so its setting is "reads per tick"), and the
  WPSD caller/reflector lookup intervals (3 s / 30 s, the Mac's defaults
  and ranges), with Restore Defaults. Every value is clamped on read, so a
  hand-edited 0 in settings.json can't make a loop spin.
- **Appearance**: Theme (Auto / Light / Dark, set on the window's root
  element) and the MENU grid's button value color (the Mac's eight;
  `Settings/Appearance.cs`).
- Not ported: the Mac's Station tab (nothing here uses a callsign or grid
  yet) and Updates (Sparkle is Mac-only).
- No Ctrl+, shortcut: WinUI 3 crashed at startup (in Microsoft.UI.Xaml.dll)
  with a `KeyboardAccelerator` on VK_OEM_COMMA (188), which isn't a
  defined `VirtualKey` value.

Persist via `ApplicationData.Current.LocalSettings` (available for free
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

## MENU grid (2026-09-28, all three pages)

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
  CW's empty items (3-7, 15-18, 23-27) are left out.
- FM/C4FM: RPT SHIFT ("OS0"), BEACON (Table 3 "EX" 07/01/01 — an APRS item
  but a plain rig setting, so it's wired), CH STEP ("EX" 03/06/06), SQL
  TYPE ("CT0"), TONE FREQ/DCS ("CN00"/"CN01", indexes into
  `Models/RigToneTables.cs`' 50-tone and 104-code tables), and HOME. The
  rig's HOME channels aren't reachable over CAT, so HOME tunes Main to the
  current band group's home frequency itself (`HomeBand`), through the
  same path as the Set button so swap tracking resets; the frequencies are
  set in Settings → Home Freq (factory defaults until changed).
  Buttons 23-28 open the Deep Settings screens (step 8 of the parity
  plan). Placeholders: APRS S.LIST/M.LIST (need APRS decoding), and DTMF,
  T-CALL, REV, DG-ID TX/RX, HRI MODE and BCN-TX (no CAT path; disabled on
  the Mac too). 4, 5, 16 and 17 are left out.
- Checked against a fake rigctld (logs every line, answers raw reads in the
  FTX-1's reply shapes): every read parses, and every write matched the
  Mac's bytes — e.g. `RA00`, `PA02`, `GT00` (from AUTO's read-back 6),
  `SS0130000`, `SS04+04.5`, `AC100`, `AC103`, `EX0307040`, `PR11`, `MX1`,
  `NL0004`, `RL004`, `VD11`, and `DA00091512` with the other two "DA"
  fields preserved. RF POWER's slider wasn't driven by that test. CW, same
  test: `ML1061`, `KR0`, `BI1`, `KS021`, `KP41`/`KP42` (700 → 710 → 720 Hz),
  `SD05` (300 → 250 ms), `ZI0`, `CS1`, and each page switch read only the
  new page's settings, straight away. FM, same test: `OS01`, `EX0701011`,
  `EX0306063`, `CT02`, `CN00013`, `CN01001`/`CN01002`, and HOME sent
  `F currVFO 29600000` from 14.074 MHz (HF group).
- **Spot-tested on the rig by the user, 2026-09-28: all three pages, every
  item tried worked.** A spot test, not a run through every line of the
  checklists below, so their boxes are left unticked; they're what to
  check if a specific item ever misbehaves.

Hardware checklist, SSB page:

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

Hardware checklist, CW page:

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

Hardware checklist, FM/C4FM page:

- [ ] RPT SHIFT, SQL TYPE, BEACON and CH STEP cycle through every value
      and match the rig's display (RPT SHIFT/SQL TYPE only work in FM).
- [ ] TONE FREQ and DCS step through the tables and match the rig
      (e.g. 100.0 → 103.5 Hz; 023 → 025).
- [ ] HOME from 2 m goes to 146.520 MHz, from HF to 29.600 MHz; between
      groups (e.g. 40 MHz) it does nothing.
- [ ] All placeholders are disabled, APRS S.LIST/M.LIST and the six
      "SOON" buttons with their "not built/ported yet" tooltips.

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
  (shared mode) on the input chosen in **Settings → Audio**, at the
  device's own rate (48 kHz for the FTX-1's codec on
  the test PC, which shows up as "Microphone (2- USB Audio Device)"). The
  picker lists active recording devices; with nothing saved, Settings
  pre-selects (and Connect uses) the only one named "USB Audio", if there's
  exactly one. Saving another device while connected restarts capture, and
  a saved device that isn't plugged in stays listed as "(not connected)". A missing/removed
  device or a capture error shows "Audio input unavailable" and retries
  every 3 s; a microphone-privacy denial says which Windows setting to
  turn on. A mono device gives Main only and says so. **Feedback guard**:
  if the output playback would use (the Settings output choice, or Windows' default)
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
  device is **Settings → Audio**'s output picker (both modes): "Windows default"
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
3. **The 28-item MENU grid — done.** Port the
   CAT mappings `MenuPageView.swift`/`RigState.swift` already use to C#,
   sent straight to rigctld the way the Mac does. This copies command logic
   that already works; it doesn't need new reverse-engineering. Its MOX,
   ANT TUNE and CW MESSAGE play buttons must go through `TransmitGate`
   (step 1). All three pages done 2026-09-28 (`ed9a7e6`, `d0eac20`,
   `f511da3`), checked against a fake rigctld and spot-tested on the rig
   by the user the same day, all working (see "MENU grid" above).
   Left as placeholders for later steps: CW's PLAY/RECORD (audio
   recorder) and FM's APRS S.LIST/M.LIST (APRS decoding). FM's Deep
   Settings buttons came with step 8, HOME's per-band frequencies with
   step 7.
4. **Graphical S-meter — done** (2026-09-28, build-verified and checked
   against a fake rigctld, not yet hardware-tested). The same analog meter
   the Mac and iPad draw (`UI/SMeterView.swift`), one under each VFO like
   the Mac's layout: `Controls/SMeter.cs` draws it with plain XAML shapes
   in SMeterView's 280×120 design space (no Win2D), and
   `Models/MeterScale.cs` ports `SMeterScale`/`MeterSelection` with the
   same anchors. The reads are new here (this app had only power out and
   SWR as text): Main from hamlib's STRENGTH, Sub from raw "RM2" (STRENGTH
   only reads the active side), COMP/ALC/ID/VDD from raw "RM3/4/7/8" only
   while transmitting — the Mac's refreshFastTier set. Clicking a meter
   opens the METER picker (PO/COMP/ALC/VDD/ID/SWR, remembered per side in
   settings.json); the Sub needle stays on the S scale during TX, as on
   the Mac. The poll went from 1 s to 500 ms (the Mac's fast-tier
   default) the same day so the needles move live, with the slow tier
   kept at ~5 s (every 10th poll) — performance over Tailscale still to
   be evaluated by the user. To check on the rig: the needle against the rig's
   own meter on a strong signal (the RM2 table is hamlib's FT-991 one),
   and PO/SWR while transmitting into a dummy load.
5. **V/M memory toggle and channel stepping — done** (2026-09-29,
   checked against a fake rigctld that models the rig's quirks, then
   tested on the rig by the user the same day: V/M both ways, swapping a
   memory channel onto Main and back). A V/M toggle button under the ⇄/audio
   buttons (checked whenever Main isn't in plain VFO mode), a "CH n TAG"
   label beside each VFO heading ("VM nn" for the rig's other VM
   sub-modes: PMS, 5 MHz band, EMG...), and, while Main is in Memory mode,
   a channel box + Set + ▼/▲ in place of the frequency entry. Same CAT as
   the Mac: "VM0"/"VM1" every poll, "MC"/"MT" only while that side is in
   Memory (so +2 round trips per poll in VFO mode, up to +6 in Memory);
   set with "MC0" (5 digits, channels 1–999 like the Mac since
   `adaf51a`: the manual's "MC" entry says 99, its MR/MW/MZ say 999),
   step with "CH0" up / "CH1" down. No guessed channel number after a set
   or step, also like the Mac: the rig ignores a set to a blank channel,
   so the display waits for the poll's read-back. The toggle
   is the Mac's explicit read-then-set, compared against plain VFO so any
   sub-mode exits to VFO (the Mac's 2026-09-17 fix). Entering Memory
   re-writes "MC0" immediately before "VM011" — here both under one client
   lock hold, so a poll read can't slip between them. Leaving it sends
   "VM000" and then restores the last VFO-mode frequency and mode
   (`_lastVfoState`, the Mac's `lastVFOState`); mode is skipped in C4FM,
   which this app's RigMode can't represent, and the exit is a bare
   "VM000" if the session started in Memory mode, or after a swap (⇄ or a
   detected front-panel swap): the remembered VFO then belongs to the
   other receiver. Sub is display-only, as on the Mac.
   The first rig test froze the app: with a C4FM memory channel on Main,
   hamlib answers "m currVFO" with a single "RPRT -8" line, and the client
   waited for a second line with no timeout, holding the round-trip lock
   so every later command queued behind it. Hamlib-verb reads now time out
   after 3 s (with the raw reads' reconnect), and an "RPRT" first line
   fails the read at once. Still open: with Main on that C4FM channel each
   poll takes ~2.5 s instead of ~0.5 s, without any read failing. Some
   read after the mode read answers slowly there, not yet identified
   (per-read timing in the log would find it). Not yet checked on the rig:
   ▲/▼ at the ends of the programmed channels and across empty ones, and
   the button exiting from a 5 MHz or PMS sub-mode.
6. **C4FM callsign display — done** (2026-09-29, tested against the real
   hotspot and rig by the user the same day, working as expected). `Services/WpsdCallsignMonitor.cs` ports the Mac's
   `WPSDCallsignMonitor`: `caller_details_table.php` every 3 s for the live
   caller (Src "Net" + a live "TX" cell) and `repeaterinfo.php` every 30 s
   for the linked YSF reflector, the Mac's default intervals (adjustable in
   Settings → Polling since step 7), 10 s HTTP timeout, a failed fetch
   leaves the display alone. On/off + hotspot address in Settings → C4FM
   since step 7, under the connection bar before that (settings.json
   `WpsdEnabled`/`WpsdHost`, applied at once, no reconnect). It runs only while either side is in C4FM, and each VFO
   shows the caller and reflector under its frequency only while that side
   is. C4FM comes from raw "MD0"/"MD1" (P2 "H"/"I"), read in the slow tier
   (~5 s) since hamlib's "m" can't report it; the same flag now also skips
   the MENU grid's GT0/PR1 in C4FM and clears the Mode box instead of
   leaving the last analog mode showing. "MD0"/"MD1" assume Main is the
   active side (VFO A), as the rest of this app does.
7. **Settings UI — done** (2026-09-29, build-verified; the dialog was
   opened, every tab shown and a Save applied, driven through UI
   Automation on the test PC while disconnected; not yet used against the
   rig). A Settings dialog with the Mac's tabs — see "Settings" above:
   rigctld (mode, Pi host, rigctld.exe, model, COM port, baud), Audio
   (input/output devices), C4FM (WPSD), APRS (placeholder), Home Freq,
   Polling, Appearance. The connection fields, audio device pickers and
   WPSD row moved there out of the main window, whose connection bar is now
   Connect, the state line and Settings. To check on the rig: Connect in
   both modes after setting them only in the dialog, HOME with an edited
   frequency, a poll interval change taking effect while connected, and
   Save with a new output device mid-session.
8. **Deep Settings (the 341-item catalog) — done** (2026-09-29, checked
   against a fake rigctld through UI Automation; not yet used on the rig).
   What talking to rigctld directly pays for: iPad can't have it until the
   wire protocol gets request/response. FM's bottom-row buttons (RADIO, CW,
   OPERATION, DISPLAY, EXTENSION, APRS SETTING) open
   `Controls/DeepSettingsDialog.cs`, the Mac's `DeepSettingsView`: tabs
   (P2) on the left, the tab's items (P3) as rows, each with an editor
   picked from its type — toggle switch, drop-down, spin box (clamped and
   snapped to the item's step) or text box. APRS spans categories 6-8,
   like the rig's button. `Models/DeepSettingsCatalog.cs` is
   `DeepSettingsCatalog.swift` translated mechanically (a script, not
   retyped), and a dump of all 341 items was compared against the Swift
   source: addresses, labels, types, digits, ranges and case lists all
   match. The Swift file stays the source of truth, so a hardware
   correction there needs copying here.
   Same CAT as the Mac: showing a tab reads each item with "EX" P1P2P3
   (here one after another, so rows fill in top to bottom; "—" until
   read, and a count of items that didn't answer); a change sends "EX"
   P1P2P3 + P4 at once. Differences from the Mac: text fields send on
   Enter or when they lose focus, not on every keystroke; momentary items
   (resets, SD card, calibration, firmware update) are neither read nor
   sent (the Mac reads them, then shows them disabled); a value missing
   from an item's list shows as "(raw)" in the drop-down instead of a
   blank. Disconnecting closes the screen. On the fake rigctld these writes
   matched the expected bytes: `EX010101-04`/`-03` (AF TREBLE −5 → −3 dB),
   `EX0101040040` (AGC FAST 20 → 40 ms), `EX0101100` (HCUT SLOPE),
   `EX0106020` (LOCATION SERVICE off), `EX010328123A` (DTMF MEMORY 1),
   and opening SD CARD read only INFORMATIONS. To check on the rig: a few
   values against the rig's own SET-mode screens (reads), one reversible
   change of each editor kind, the time to fill a long tab (MODE FM, 37
   items) over Tailscale, and that the MENU grid's CH STEP/BEACON/ANT
   follow a change made here on their next slow-tier read.
9. **Filter rows — done** (2026-09-30, checked against a fake rigctld
   through UI Automation; not yet used on the rig). The Mac's two Filter
   rows under Mode/Band, in `Controls/FilterPanel.cs`: WIDTH (picker +
   narrower/wider) and SHIFT (slider + center) on the first; CONTOUR or
   APF (APF in CW), N/W and NOTCH on the second; then the MAIN/SUB
   selector and the Filter Function Display. `Models/FilterModels.cs`
   ports `FilterWidthTable`, `IFShift`, `IFNotch`, `IFContour`,
   `NarrowWidthPreset` and `FilterPassbandModel` (a null mode stands for
   the Swift C4FM/unknown). Same CAT as the Mac, with the selected side as
   P1: "SH", "IS", "BP" (3-digit fields), "CO" (4-digit), "NA", plus the
   mode's NAR WIDTH "EX" item for the display, and "KP" in CW. The
   selected side is read in the slow tier; a MAIN/SUB switch clears and
   re-reads at once, as do ⇄ and a detected front-panel swap; N/W re-reads
   the width right behind the write. SUB is disabled in single-receive
   display ("FR"), with a fall back to MAIN. Sub's mode now comes from
   "MD1" in the slow tier (and on each SUB read) — it used to be read only
   for C4FM. Sliders send on release, or at once for keyboard changes.
   Differences from the Mac: the display draws the shape only, with no
   audio spectrum behind it (no FFT here yet, see "Explicitly deferred");
   there's no per-band width memory, since this app has no `BandMemory`.
   On the fake rigctld these writes matched: `SH0016` (narrower from
   2700 Hz), `IS00+0000` (center), `BP00001` (notch on), `NA01`,
   `CO120000` (APF off on SUB), `SH1011` (wider on SUB), `BP11123`
   (notch to 1230 Hz on SUB). To check on the rig: each control against
   the rig's own filter display on both receivers, N/W in SSB and AM, and
   CONTOUR ↔ APF when switching to and from CW.

## Explicitly deferred (not v1, but not architecturally foreclosed either)

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
  MainWindow.xaml(.cs)        v1 core-rig-control UI + poll loop + audio controls
  SettingsDialog.xaml(.cs)    Settings dialog (the Mac's SettingsView tabs)
  Controls/
    MenuGrid.cs                  MENU grid (port of MenuPageView.swift), all three pages
    SMeter.cs                    analog S/TX meter (port of SMeterView.swift) + METER picker
    DeepSettingsDialog.cs        Deep Settings screens (port of DeepSettingsView.swift)
    FilterPanel.cs               Filter rows + Filter Function Display (ports of the Filter-row views in FTX1Core/UI)
  Models/
    RigMode.cs                 hamlib mode vocabulary — Sources/FTX1Core/RigState/RigState.swift's RigMode
    BandPlan.cs                 band table — Sources/FTX1Core/RigState/BandPlan.swift
    RigState.cs                 subset of RigState.swift's fields (core + MENU grid pages + V/M memory + filter)
    RigDelayCode.cs             "SD"/"VD" 00-33 delay code ↔ ms
    RigToneTables.cs            CTCSS/DCS tables ("CN" indexes) and HOME band groups
    MeterScale.cs               needle mapping + METER selection — SMeterView.swift's SMeterScale, MeterSelection.swift
    DeepSettingsCatalog.cs      the 341 "EX" items — MenuSettings/DeepSettingsCatalog.swift, translated mechanically
    FilterModels.cs             filter value spaces + display geometry — FilterWidthTable/IFShift/IFNotch/IFContour/FilterPassbandModel.swift, NarrowWidthPreset.swift
  Services/
    RigctldClient.cs             TCP client for rigctld's text protocol
    RigctldProcessController.cs  Local mode: spawns/adopts rigctld.exe (port of the Mac's)
    RemoteAudioStreamClient.cs   TCP client for ftx1-audiostream.py (:8532), Main/Sub split
    ChannelPlayer.cs             per-receiver jitter buffer + squelch/volume/mute
    SquelchGate.cs               port of SquelchGate.swift
    AudioPlayback.cs             NAudio WASAPI output mixing Main + Sub
    WpsdCallsignMonitor.cs       C4FM caller/reflector from a WPSD hotspot (port of WPSDCallsignMonitor.swift)
  Settings/
    AppSettings.cs                every setting (connection, audio, WPSD, HOME, polling, appearance); file-based (see its doc comment on why not LocalSettings yet)
    Appearance.cs                 AppTheme / ButtonValueColor (ports of the FTX1Core Appearance enums)
```
