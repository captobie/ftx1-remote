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

  A **Version** box (2026-10-06, the Mac's `RigctldVersionBox`; written on
  the Mac, not yet built or run on Windows) follows the tab's unsaved
  fields: **Installed** (Local only) is `rigctld.exe --version`, and
  **Running** is the "Hamlib version:" line of `\dump_caps` from whatever
  answers on port 4532 (127.0.0.1, or the Pi), read over a short-lived
  connection of its own (`RigctldClient.ReadHamlibVersionAsync`), so it
  works while connected too.
- **Audio**: the Local-mode input device and the playback output device
  (see "Audio" below). The Audio on/off switch and the MAIN/SUB mute,
  VOL and SQL stay in the main window.
- **C4FM**: the WPSD hotspot callsign lookup (on/off + hotspot address; a
  pasted "http://" and trailing "/" are stripped).
- **APRS**: Decode APRS (off by default), frequency (144.390 MHz), tolerance
  (±5 kHz), stations/messages to keep (1,000 each), and Clear History —
  armed by its button, carried out on Save (one dialog at a time, so no
  confirmation box like the Mac's). See "APRS decode" below.
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
  was unreliable; its play must pass `TransmitGate` if it's ever enabled).
  PLAY/RECORD are the Mac's repurposed ones — see "Recordings" below.
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
  plan). APRS S.LIST/M.LIST open the decoded lists (see "APRS decode").
  Placeholders: DTMF,
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
- [ ] MESSAGE is disabled.
- [ ] RECORD → ON starts a file named for Main's frequency/mode; OFF saves
      it ("Saved … to Recordings." on the status line) and it plays back in
      PLAY's Recordings window. RECORD is disabled with the audio off.

Hardware checklist, FM/C4FM page:

- [ ] RPT SHIFT, SQL TYPE, BEACON and CH STEP cycle through every value
      and match the rig's display (RPT SHIFT/SQL TYPE only work in FM).
- [ ] TONE FREQ and DCS step through the tables and match the rig
      (e.g. 100.0 → 103.5 Hz; 023 → 025).
- [ ] HOME from 2 m goes to 146.520 MHz, from HF to 29.600 MHz; between
      groups (e.g. 40 MHz) it does nothing.
- [ ] All placeholders are disabled, the six "SOON" buttons with
      their "not built/ported yet" tooltips.

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
- (The waterfall/oscilloscope came with parity plan step 10.)

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
   recorder, done 2026-10-03 — see "Recordings") and FM's APRS
   S.LIST/M.LIST (APRS decoding). FM's Deep
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
   Difference from the Mac: there's no per-band width memory, since this
   app has no `BandMemory`. (The display's audio spectrum came with step
   10.)
   On the fake rigctld these writes matched: `SH0016` (narrower from
   2700 Hz), `IS00+0000` (center), `BP00001` (notch on), `NA01`,
   `CO120000` (APF off on SUB), `SH1011` (wider on SUB), `BP11123`
   (notch to 1230 Hz on SUB). To check on the rig: each control against
   the rig's own filter display on both receivers, N/W in SSB and AM, and
   CONTOUR ↔ APF when switching to and from CW.
10. **Waterfall/oscilloscope — done** (2026-09-30, checked against a fake
   Pi audio stream of test tones through UI Automation; not yet on real
   rig audio). Between the two meters, as on the Mac: Waterfall /
   Oscilloscope / Off buttons under ⇄ / speaker / V/M, zoom arrows beside
   the box. `Services/ScopeProcessor.cs` is the DSP half of the Mac's
   `AudioCaptureEngine`: one 2048-point FFT per 2048-sample chunk (both
   audio sources already chunk that way), Hann window, power in dB scaled
   like vDSP's so the −70 dB auto-gain floor means the same, peak-hold-
   and-decay auto-gain with the Mac's constants; a waterfall row (256
   columns over 0–4 kHz — the Mac's spans 0–Nyquist, ~22 kHz, and leaves
   most of its width dark; user decision), a 256-point trace, and the 0–4 kHz spectrum for the Filter Function Display (Sub's
   own, with its own auto-gain, while SUB is the filter side). It runs on
   the audio thread from the same routed Main/Sub chunks playback gets, so
   it follows a swap. `Controls/ScopeDisplay.cs` draws it: a persistent
   256×150 BGRA buffer scrolled one row per frame into a `WriteableBitmap`,
   and the trace as a `Polyline` in the box's own pixels; frames reach the
   UI through one coalesced dispatcher item at a time. The Filter display
   now shows the spectrum (dim everywhere, bright inside the passband —
   clipped to the passband's flat top, since WinUI clips only to
   rectangles). Off skips the FFT entirely and blanks both. The mode is
   saved (`ScopeDisplayMode` in settings.json); the zooms (0.25–4×) aren't,
   as on the Mac. The VFO section now follows the Mac's layout, mirrored:
   three equal columns — MAIN, the scope, SUB — with each VFO's readout
   (and MAIN's frequency/channel entry) in a black box with a green
   border like the Mac's `VFODisplayBox` (SUB's goes gray in
   single-receive display), the meters under the boxes and the scope
   between the meters, as tall as they are. Each receiver's Mute / SQL /
   VOL (and squelch-open dot) sit right of its meter, the Mac's
   `channelControls`, instead of in the Audio box, which keeps only the
   on/off switch and link status. The meters are the Mac's 190 px wide,
   shrinking in a narrow window so the controls keep 140 px.
   Debug build on the test PC: ~9% of one core with the waterfall on, ~5%
   with it Off (polling + audio). To check on the rig: the waterfall and
   spectrum against the rig's own scope on a busy band, in both Remote
   and Local mode.

## APRS decode (2026-10-01)

The Mac's APRS decoding, ported after the parity plan. Checked with a
scratch harness running `APRSDecodingTests.swift`'s synthetic cases
against the C# decoder (all pass: position/message/status frames, 512- and
2048-sample chunks, 0.3% clock drift + noise, 44.1 kHz), then end to end in
the built app against a fake Pi (a stand-in rigctld + a 44.1 kHz stereo
stream with AFSK packets on each channel). Rig-tested by the user
2026-10-01 on real off-air traffic, MAIN and SUB in Remote mode, working
well; Local mode not yet tested on the rig.

- `Services/AfskDemodulator.cs`, `Services/Ax25.cs` and
  `Models/AprsPacket.cs` are `AFSKDemodulator.swift`, `AX25Frame.swift` and
  `APRSPacket.swift` line for line (same constants: the 0.05 bit-clock
  damping, the DC blocker, the one-bit EMA), so a tuning change there can
  be copied here. Same scope too: uncompressed positions, status and
  messages; Mic-E, compressed positions, objects, weather etc. still land
  in the station list as a bare "heard".
- Two `Services/AprsDecoder.cs` instances, Main and Sub (the Mac's
  `aprsDecoder`/`aprsDecoderSub`), each on its own worker thread, fed the
  routed Main/Sub chunks from the audio thread (so they follow a swap,
  like the scope) only while that VFO's last polled frequency is within
  the tolerance of the APRS frequency. Gate open/close, each decoded
  frame and a stats heartbeat every ~30 s go to app.log ("aprs-gate:",
  "aprs-decoder (main|sub):"); the heartbeat's flags vs. CRC/destuff
  failures tell "no signal" from "corrupt signal", as on the Mac. Needs
  audio on, Remote or Local.
- `Services/AprsStore.cs` is the Mac's `APRSStore` + `APRSPersistence`:
  stations upserted by callsign (Source = the channel that heard it last),
  every message its own entry, trimmed to the Settings limits, saved after
  each change to `%LOCALAPPDATA%\FTX1RemoteWindows\aprs-history.json`.
- `Controls/AprsListWindow.cs`: the S.LIST / M.LIST windows (separate
  windows, like the Mac's), newest first, with an All/Main/Sub filter and
  relative "last heard" times (local time on hover). Opened from the
  MENU grid's FM page or from the **APRS** drop-down in the connection bar,
  which also works while disconnected (the grid doesn't) — the Mac's
  View → APRS menu.
- Each VFO box shows "APRS" in the reflector slot while that VFO is on the
  APRS frequency, and the last station decoded on that receiver for 5 s
  (the Mac's `aprsActive`/`aprsLastCallsign`); C4FM's caller display
  takes precedence.
- Not ported: the Mac's APRS Map window (MapKit). A Windows map would need
  WebView2 plus a tile source, which is its own decision.

Still to check on the rig: the same in Local mode (the PC's own sound-card
input).

## WebSDR window (2026-10-01)

The Mac's Tools → WebSDR (root `CLAUDE.md`'s "WebSDR follow" section), ported
whole: a KiwiSDR or classic WebSDR in a WebView2 that follows Main's
frequency/mode, tunes the rig from the page ("Tune rig"), records with the
page's own recorder, mutes the rig's Main audio while it's audible, mutes
itself on TX, and has the Stations list (KiwiSDR directory + websdr.org) and
Favorites. Opened from the **WebSDR** button in the connection bar; works
while disconnected too (it just has no rig frequency to follow).

- Same logic and decisions as the Mac, file for file:
  `Services/WebSdrFollowModel.cs` (WebSDRFollowModel), `Services/SdrPageBridge.cs`
  (SDRPageBridge, with the page JavaScript copied unchanged),
  `Models/SdrUrls.cs` (SDRPlatform + both URL builders), `Models/SdrStations.cs`
  (KiwiSDRStation, WebSDRFavorite, Maidenhead), `Services/KiwiSdrDirectory.cs`
  (same rx.linkfanel.net mirror, 30 min cache, conditional GET; never the
  websdr.org list, which is shown as the site itself for the same licensing
  reason as on the Mac). The Swift files stay the source of truth.
- Rig state comes from MainWindow after every poll (`PushRigStateToWebSdr`),
  not a second poll; the model drops repeats and debounces 400 ms like the
  Mac's `$rigState` pipeline. Click-to-tune goes through the same paths as
  the Set button and the mode picker.
- WebView2 differences from WKWebView, each found while testing:
  - one shared environment (`SdrWebViewEnvironment`) with its profile in
    `%LOCALAPPDATA%\FTX1RemoteWindows\WebView2` and
    `--autoplay-policy=no-user-gesture-required`, so a Kiwi reload after a
    retune keeps playing with no click-to-start overlay;
  - Chromium holds a page's *second* script-made download behind a "download
    multiple files?" prompt WebView2 never shows, so only the first
    recording of a page session was saved (the retune split timed out).
    The window allows `MultipleAutomaticDownloads`, nothing else;
  - closing the window destroys the web view, so a close while recording is
    cancelled, the file saved, then the window closed.
- Recordings go to `%LOCALAPPDATA%\FTX1RemoteWindows\Recordings` with the
  Mac's file names; the Mac's Play is a **Recordings** button that opens
  the Recordings window (the CW page's PLAY, see "Recordings").
- Manage Favorites reorders with up/down buttons instead of the Mac's drag
  (a ListView drag-reorder didn't take with a name box in every row).
- Settings got a **Station** tab with only the grid square, for the
  KiwiSDR list's distance column.
- The automatic Main mute is `AppSettings.MainMutedByWebSdr`, lifted at
  startup if a crash left it set, like the Mac's `mainMutedByWebSDR`.

Tested against a fake rigctld and public receivers (a KiwiSDR and the
University of Twente WebSDR): follow, click-to-tune (mode buttons and
frequency steps on both platforms), platform detection and learned
title/range for a typed WebSDR host, in-place WebSDR retunes, Record with a
split per retune (three files across two retunes), Mute on TX, the
automatic Main mute and its crash recovery, the websdr.org pick, Favorites
(star, menu, rename, reorder), distance sort, and close-while-recording.
Not yet on the rig.

**OpenWebRX (2026-10-02)**, ported from the Mac's 2026-10-01 commits (root
`CLAUDE.md`'s OpenWebRX bullet has the server and every decision):
`SdrPlatform.OpenWebRx` + `OpenWebRxUrlBuilder` in `Models/SdrUrls.cs`, the
page JavaScript in `SdrPageBridge` (detection, profiles from the list box +
`status.json`, in-place retune with profile switching, `toggleMute()`,
tuning reads), the model's always-retune-after-load and no-click-to-tune
during an in-place retune, and the app-side recorder tap
(`Services/SdrAudioFileWriter.cs`, 16-bit mono WAV at the page's 48 kHz).
WebView2 differences:
- The profile read is async JavaScript. The Mac awaits it with
  `callAsyncJavaScript`; `ExecuteScriptAsync` doesn't wait for a promise,
  so the script parks its result in a page global that the bridge polls.
- The tap posts its blocks with `chrome.webview.postMessage` (a WebKit
  message handler on the Mac); the window passes `WebMessageReceived` to
  the bridge.
- No hash-navigation workaround: the Mac cancels OpenWebRX's `location.hash`
  updates because its WebKit turns them into full reloads, but Chromium
  keeps them same-document. Checked: tuning in the page kept the page's Mute,
  its waterfall history and a single client.

Tested against the operator's own server (`100.104.255.14:8073`, K7CMA) with
the fake rigctld: detection with the learned name and 14 profile ranges,
follow in place (145.075 FM), a profile switch (2 m → 70 cm at 438.800 and
back), Mute, click-to-tune from the waterfall (a WFM mode click correctly
left the rig's mode alone), and Record while Muted (a 7 s, 48 kHz WAV
with signal in it). Not yet on the rig.

## CW window (decode + send, 2026-10-03)

The Mac's Tools → CW window, all of it: the receive pane with the classic
decoder (step 1 of the CW port), the send pane (step 2), the neural
decoder (step 3) and the WebSDR window as a third source (step 4). Opened
from the **CW** button in the connection bar.

- `Services/CwClassicDecoder.cs` is CWKit's classic decoder
  (`captobie/cwdecode`, `Sources/CWKit`: `Goertzel`, `ToneDetector`,
  `FrequencyTracker`, `MorseCode`, `MorseDecoder`, `DecoderPipeline`)
  translated line for line, same constants and Float/Double split. CWKit
  stays the source of truth: copy any decoder fix made there. Checked
  with a scratch harness running CWKit's `MorseDecoderTests` and
  `DecoderPipelineTests` cases against the C# code (all pass, same
  tolerances: 8-45 WPM, Farnsworth, noise, auto-tune from 600 to 860 Hz,
  44.1 kHz in 256/1000/44100-sample chunks, silence on pure noise).
- `Services/CwReceiver.cs` is the Mac's `CWReceiver` plus CWKit's
  `PipelineRunner`: MainWindow's audio routing feeds it both receivers'
  routed chunks (so MAIN/SUB follow a swap); it keeps the selected one
  only while the window is open and decodes on its own worker thread.
  Owned by MainWindow, so the text survives closing the window. Settings
  persist (`Cw*` in settings.json: receiver, tone, auto-tune, squelch).
  Decoding pauses (and flushes, starting a new line) while the rig reports
  TX or the PTT button is held. SUB is unselectable while there's no Sub
  audio (a mono Local input delivers exact zeros) or in single-receive
  display. A note says when the selected receiver isn't in CW.
- `Controls/CwWindow.cs` is the Mac's receive pane: MAIN/SUB, Open Audio
  File (Media Foundation, so WAV/MP3/M4A/WMA/FLAC; the picker opens in
  Recordings), Copy (Ctrl+Shift+C), Clear (Ctrl+K), key LED, level, the
  character being received, tone/SNR/WPM, and Auto-tune/Tone/Rig Pitch/
  Squelch. Readouts are sampled from the receiver every 30 ms rather than
  pushed per chunk, so they never touch the text.
- **WebSDR source (step 4)**: MAIN / SUB / **WebSDR** decodes what the
  WebSDR window is playing, through `Services/WebSdrAudioTap.cs` —
  Windows' process-loopback capture (Windows 10 2004+ / 11) of the
  WebView2 browser process and its children, where Chromium's audio
  service runs, so it works for KiwiSDR, classic WebSDR and OpenWebRX
  alike and nothing is added to their pages (the Mac's Core Audio process
  tap, same idea). It never hears this app's own audio (the rig's
  playback). `ActivateAudioInterfaceAsync` is the one piece of interop;
  the rest is NAudio's `AudioClient`. 48 kHz float stereo, mixed to mono,
  2048-frame chunks. Runs only while the CW window is open with WebSDR
  selected; the WebSDR window's browser process and connected/muted state
  are re-read every 2 s, so opening or reconnecting it is picked up.
- **Unlike the Mac, a muted WebSDR can't be decoded** (user decision,
  2026-10-03): Windows has no "silent on the speakers, still captured"
  mute — tested: muting the process's audio session, or setting its volume
  to 0, gives the capture exact zeros, and the page's own mute does the
  same. So the WebSDR has to be audible, and the window's Mute stays on
  the page (no routing like the Mac's `WebSDRAudioRouting`). Mute on TX
  makes no difference, since decoding pauses during TX anyway. The notes:
  "Open the WebSDR window…", "Connect the WebSDR window…", "The WebSDR is
  muted — unmute it to decode…" (only once the capture has gone silent,
  so a page the Mute doesn't reach can't contradict it), "The WebSDR is
  silent…" (below −80 dBFS for 3 s), and capture failures.
- Tested in the built app with a local page playing CW through Web Audio,
  loaded in the WebSDR window: it captured the WebView2 tree and decoded
  "CQ CQ DE W1AW W1AW K" with the neural decoder (SNR 51 dB); every note
  above (silent page, muted, disconnected, window closed). Not yet tried
  against a real KiwiSDR/WebSDR/OpenWebRX or on the rig.
- Tested in the built app against a fake Pi (stand-in rigctld + a 44.1 kHz
  stereo stream with different CW on each channel): MAIN and SUB decode,
  switching starts a new line, the not-in-CW note, the pause while TX
  (fake `t` = 3), Rig Pitch ("KP" → 700 Hz, auto-tune off, persisted), and
  a WAV through the picker (header line, then live resumes). Not yet on
  the rig.

Neural decoder (step 3), CWKit's `Neural/` (`NeuralFeatures`,
`AudioResampler`, `StreamingCTCDecoder`, `CWNetModel`, `NeuralPipeline`):

- **The model is CWKit's own**, converted rather than re-exported (user
  decision, 2026-10-03): `Apps/Windows/Tools/cwnet_to_onnx.py` reads a
  cwdecode release's `CWNet.mlmodelc` (the ML Program text `model.mil` +
  `weights/weight.bin`, whose blobs are a 64-byte header — `0xDEADBEEF`,
  data type, size, data offset — then raw float32) and writes
  `Assets/CWNet.onnx` with the same weights, plus the Core ML metadata
  (vocabulary, feature settings, model version, source). It parses the
  program generically but only accepts CWNet's ops (conv, relu, add,
  reduce_max, transpose, softmax, log — MIL's `log` has an epsilon, so it
  becomes Add + Log) and refuses anything else. To pick up a new model:
  `python cwnet_to_onnx.py --tag <cwdecode tag>` (needs `numpy onnx
  onnxruntime`; a venv is fine), which also checks the result against that
  release's golden file (CWKit's `modelMatchesPython`) and fails if it
  doesn't match. The current file is from cwdecode 0.1.1 (model version
  202609301110): output frames identical, largest probability difference
  4×10⁻⁶ (the test allows 10⁻³).
- Run with **ONNX Runtime** (`Microsoft.ML.OnnxRuntime` NuGet, MIT, CPU, one
  thread), loaded on the CW worker the first time the window opens (~90 ms).
  If it can't load, the classic decoder runs, the Neural/Classic picker is
  disabled and its tooltip says why; the saved choice isn't changed.
- `Services/CwNeuralDecoder.cs` is the rest, translated from the Swift:
  the 8 kHz spectrogram (a DFT over just the 33 bins kept, SIMD dot
  products), the streaming CTC decoder (6 s windows every 1 s, 2.5 s of
  context, handoff in the widest gap, reconcile), and the pipeline (the
  classic decoder still runs for the meters; its text is dropped). The
  resampler to 8 kHz is NAudio's WDL sinc resampler instead of
  `AVAudioConverter`, with a flush that pushes silence through until the
  output matches the input length. `CwReceiver` runs either engine
  (`ICwDecoderEngine`); switching flushes the old one, as CWKit's
  `PipelineRunner` does.
- The window: Neural/Classic picker next to MAIN/SUB (persisted as
  `CwDecoder`, Neural by default like the Mac); the neural decoder's
  not-yet-final text is shown dimmed after the committed text (not
  linked); squelch is greyed out with Neural, which doesn't use it; the
  character readout stays empty with Neural.
- Checked with a scratch harness running CWKit's `NeuralDecoderTests`
  against the C# code with CWKit 0.1.1's golden files: spectrogram (largest
  difference 1.8×10⁻⁵, limit 2×10⁻³), model (4×10⁻⁶), streaming on all four
  golden clips (text identical to the Python reference, its mistakes
  included), handoff/reconcile, the resampler (700 Hz tone level and pitch,
  48 and 44.1 kHz), and the whole pipeline at 48 and 44.1 kHz plus silence
  on noise. About 13 ms of CPU per second of audio. Then in the built app
  against the fake Pi: live decoding on MAIN, the dimmed tentative text,
  switching Neural ↔ Classic mid-stream, the missing-model fallback, and
  that the saved choice survives it. Whole-app CPU in the Debug build:
  ~12% of a core with the CW window closed, ~20% decoding Classic, ~24%
  Neural. Not yet on the rig.

Send pane (step 2), the Mac's `CWSendPane`/`CWSender` (its doc comments
and CLAUDE.md's "v2: CW send pane" have the rig facts this relies on):

- `Services/CwSender.cs`: lines are keyed by the rig's own keyer through
  one CW TEXT keyer memory (default slot 1, Memory 1-5 picker, persisted;
  whatever is stored there is overwritten). Each ≤50-character chunk is
  written with `RigctldClient.WriteKeyerMemoryAsync` (lowercase `w KM<n>…;`
  plus a `KM<n>` read in the same write, since `w` waits ~2 s for a reply
  an accepted write never gets; "?;" = rejected), then played with "KY0n"
  behind `TransmitGate` (`TransmitAction.PlayCwTextMemory`). The slot's
  CW MEMORY menu item ("EX" 02 02 05+n) is set to TEXT once per
  connection. Finish detection as on the Mac: ≥90% of the PARIS duration
  at the rig's WPM and PTT off for ≥1 s, capped at 1.5× + 5 s. Stop (Esc)
  sends "KY00" (never gated) and drops the queue; turning Enable Transmit
  off stops it too. Owned by MainWindow, so closing the window doesn't
  stop a queued line.
- Sending waits (shown in the status line) while the rig isn't connected,
  transmit is blocked (Enable Transmit, out of band), Main isn't in CW
  (C4FM included), or BK-IN is off ("Turn On BK-IN" button) — the rig only
  keys its memory with BK-IN on. The decoder pauses while a line is being
  sent (`CwReceiver.SetSenderActive`) as well as during TX.
- `Controls/CwSendPane.cs`: keyer speed −/+ and BK-IN (through the MENU
  grid's own send path, `MenuGrid.SetCwSpeed`/`SetBreakIn`, so the CW page
  follows), the slot, Macros… / Clear / Stop, the macro buttons (Ctrl+1–9;
  a macro fills the send line, it doesn't send — the Mac's 2026-10-03
  decision), the log (queued, keying with chunk n/m, sent, stopped,
  failed, and characters left out), the status line, Their call and the
  send line (Enter queues). Text prep is the Mac's `CWText`: uppercase,
  `<BT>`/`<AR>`/`<KN>` → `=`/`+`/`(`, anything the keyer can't send
  dropped and listed.
- Macros: `{MYCALL}`/`{MYGRID}` from Settings → Station (a **Callsign**
  field was added there for this; the grid square was already there),
  `{CALL}` from Their call; edited in a dialog (label, text, reorder,
  remove, add, Restore Defaults), saved as `CwMacros` in settings.json.
- Callsigns in the decoded text are links (the Mac's `CWCallsigns`, same
  pattern; your own call isn't linked); a click fills Their call. The text
  is rendered incrementally from the last word break, so a growing text
  doesn't rebuild every link.
- While the CW window is open, the slow tier also reads BI/KS/KP for it
  (`MenuGrid.RefreshKeyerAsync`) unless the CW page is on screen.
- Tested in the built app against a fake rigctld that models the keyer
  (2 s silent `w` writes, "?;" over 50 characters, `KY0n` keying for the
  PARIS time with PTT reading 3, "KY00"): BK-IN-off block and Turn On
  BK-IN, the MESSAGE→TEXT slot fix, a 67-character line as two chunks
  (1/2, 2/2), lines sent in order, Stop mid-line, `<BT>` mapping and a
  dropped "É", a macro refused for an empty callsign, AGN? filling the
  line, and clicking a decoded W1AW filling Their call. Not yet on the
  rig.

## Recordings (the CW page's PLAY/RECORD, 2026-10-03)

The Mac's `AudioRecorder` + `RecordingsListView`. Like the Mac, the CW
page's PLAY/RECORD aren't the rig's CW MESSAGE memory: RECORD records the
app's own Main audio, PLAY opens a window of everything recorded.

- `Services/AudioRecorder.cs` is fed Main from `MainWindow`'s audio route
  (the same routed channel as the scope, APRS and CW, so it follows a
  swap), and writes it through `SdrAudioFileWriter` under a lock, from the
  audio thread. 16-bit mono PCM at the source's rate (44.1 kHz from the
  Pi), not the Mac's 32-bit float: plenty for receive audio, half the
  size (~5.3 MB/min). File name = the Mac's, with Main's frequency/mode
  when RECORD was pressed ("Recording 2026-10-03 14.57.32 14.074.000
  USB.wav"); created on the first audio block, and nothing is left if
  none arrived.
- Differences from the Mac: RECORD is disabled while there's no audio
  source (Audio off, or Local mode without an input), and a recording
  stops when the audio does (Disconnect, the Audio switch, a new Local
  input device) — so one file never spans two sources or sample rates.
  The Mac's keeps recording across a reconnect.
- `Controls/RecordingsWindow.cs`: newest first, each row with a check
  box, play/stop, name + date · length, rename and delete; Export
  Selected (a folder picker, " (2)"-style suffix on a name clash) and
  Delete Selected appear while something's checked; Delete All (both
  confirmed); Refresh. Windows additions: Open Folder, and the file being
  recorded shows "Recording…" with play/rename/delete off (Delete All
  spares it). Reloads on open/activation, on Refresh, when RECORD starts
  or stops, and on file name changes in the folder (a
  `FileSystemWatcher`), so a WebSDR recording shows up while it's open.
  The WebSDR window's Recordings button opens this window too (it used to
  open the folder in Explorer).
- `Services/RecordingPlayer.cs` plays one file at a time on its own
  WASAPI stream (over the live audio, not instead of it), on the output
  chosen in Settings → Audio or Windows' default, resampled to the
  device's mix rate like `AudioPlayback`. It refuses the radio's own USB
  audio as output (same adapter as the Local input), for the same reason
  live playback does.
- Checked 2026-10-03 with a console harness built from the same source
  files: a 2 s recording fed from another thread (format, length, clipping
  at full scale), Stop with no audio leaving nothing, listing, rename
  (empty refused, invalid characters, a clash refused, case-only rename),
  export twice giving " (2)", delete. Tested in the app by the user the
  same day, working.

## Memory list (Mem List, 2026-10-06)

The Mac's memory list window (repo root CLAUDE.md, "Memory list"), ported
as-is. Not built on Windows yet — written on the Mac, which has no .NET SDK;
not yet run on the rig. The Mem List button sits under Waterfall and opens
`Controls/MemoryListWindow.cs`: the rig's programmed channels (channel, tag,
frequency, mode, shift, tone type), a search box, and MAIN/SUB buttons per
row. The button for the channel a receiver is on uses the accent style.

- **Reading** (`Services/MemoryListStore.cs`): CAT has no list command, so a
  Refresh reads channel by channel with `RigctldClient.
  ReadMemoryChannelAsync` ("MR", then "MT" for a programmed channel's tag;
  a blank channel answers "?;" at once). The scan stops after 100 blank
  channels in a row, the same as the Mac. It's cached in
  `%LOCALAPPDATA%\FTX1RemoteWindows\memory-channels.json`, and the
  window only re-reads on Refresh, except the first time it opens with no
  cache. `Models/MemoryChannelEntry.cs` parses "MR". The Swift parser is
  the source of truth: its offsets are unit-tested against real rig
  answers.
- **Recall** (`RigctldClient.RecallMemoryChannelAsync`): "MC<side>", then
  "VM<side>11" unless that side already reads 11. Both writes go under
  one lock hold, like `SetVfoMemoryModeAsync`'s MC-before-VM
  precondition. `MainWindow.RecallMemoryChannelAsync` shows the channel at
  once and leaves `_lastVfoState` alone, so V/M still returns MAIN to its
  VFO. Leaving Memory mode isn't offered from the list.
- To test on the rig: Refresh (how long, how many channels), MAIN and SUB
  recall from VFO mode, a recall while already in Memory mode, V/M back to
  the VFO, and the highlight following front-panel channel changes.

## Explicitly deferred (not v1, but not architecturally foreclosed either)

- **APRS map** — see "APRS decode" above.

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
Apps/Windows/Tools/
  cwnet_to_onnx.py             CWKit's CWNet.mlmodelc → Assets/CWNet.onnx, checked against its golden file
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
    ScopeDisplay.cs              waterfall/oscilloscope box (port of ScopeDisplayView.swift + AudioCaptureEngine's drawing)
    AprsListWindow.cs            APRS S.LIST / M.LIST windows (ports of APRSStationListView/APRSMessageListView.swift)
    WebSdrWindow.cs              WebSDR window (port of WebSDRFollowView.swift + KiwiWebView.swift)
    WebSdrStationsWindow.cs      Stations window: KiwiSDR table + websdr.org tab (KiwiSDRDirectoryView/WebSDROrgBrowserView.swift)
    WebSdrFavoritesDialog.cs     Manage Favorites (WebSDRFavoritesView.swift)
    CwWindow.cs                  CW window + receive pane (CWWindowView.swift)
    CwSendPane.cs                CW send pane + macro editor (CWSendPane.swift)
    MemoryListWindow.cs          Mem List: memory channels with MAIN/SUB recall (MemoryListView.swift)
    RecordingsWindow.cs          the CW page's PLAY: browse/play/rename/export/delete recordings (RecordingsListView.swift)
  Models/
    RigMode.cs                 hamlib mode vocabulary — Sources/FTX1Core/RigState/RigState.swift's RigMode
    BandPlan.cs                 band table — Sources/FTX1Core/RigState/BandPlan.swift
    RigState.cs                 subset of RigState.swift's fields (core + MENU grid pages + V/M memory + filter)
    RigDelayCode.cs             "SD"/"VD" 00-33 delay code ↔ ms
    RigToneTables.cs            CTCSS/DCS tables ("CN" indexes) and HOME band groups
    MeterScale.cs               needle mapping + METER selection — SMeterView.swift's SMeterScale, MeterSelection.swift
    DeepSettingsCatalog.cs      the 341 "EX" items — MenuSettings/DeepSettingsCatalog.swift, translated mechanically
    FilterModels.cs             filter value spaces + display geometry — FilterWidthTable/IFShift/IFNotch/IFContour/FilterPassbandModel.swift, NarrowWidthPreset.swift
    AprsPacket.cs               APRS info-field parser — APRS/APRSPacket.swift
    AprsModels.cs               AprsStation/AprsMessage/AprsSource — APRS/APRSModels.swift
    SdrUrls.cs                  SdrPlatform + KiwiSDR/WebSDR/OpenWebRX URL builders — SDRPlatform + the three *URLBuilder.swift
    MemoryChannelEntry.cs       one "MR"/"MT" memory channel — RigState/MemoryChannelEntry.swift
    SdrStations.cs              KiwiSdrStation, WebSdrFavorite, Maidenhead — KiwiSDRStation/WebSDRFavorite.swift
  Services/
    RigctldClient.cs             TCP client for rigctld's text protocol
    RigctldProcessController.cs  Local mode: spawns/adopts rigctld.exe (port of the Mac's)
    RemoteAudioStreamClient.cs   TCP client for ftx1-audiostream.py (:8532), Main/Sub split
    ChannelPlayer.cs             per-receiver jitter buffer + squelch/volume/mute
    SquelchGate.cs               port of SquelchGate.swift
    AudioPlayback.cs             NAudio WASAPI output mixing Main + Sub
    WpsdCallsignMonitor.cs       C4FM caller/reflector from a WPSD hotspot (port of WPSDCallsignMonitor.swift)
    ScopeProcessor.cs            FFT + auto-gain for the scope and filter spectrum (AudioCaptureEngine's DSP)
    AfskDemodulator.cs           Bell 202 AFSK demodulator — APRS/AFSKDemodulator.swift
    Ax25.cs                      AX.25 frame/FCS/frame decoder — APRS/AX25Frame.swift
    AprsDecoder.cs               per-receiver decode worker (port of the Mac's APRSDecoder.swift)
    MemoryListStore.cs           memory channel scan + memory-channels.json (MemoryListStore.swift)
    AprsStore.cs                 decoded station/message history + aprs-history.json (APRSStore/APRSPersistence.swift)
    WebSdrFollowModel.cs         WebSDR window logic: follow, click-to-tune, record, mute (WebSDRFollowModel.swift)
    SdrPageBridge.cs             calls into the KiwiSDR/WebSDR page + the shared WebView2 environment (SDRPageBridge.swift)
    KiwiSdrDirectory.cs          public KiwiSDR list from rx.linkfanel.net, cached (KiwiSDRDirectory.swift)
    Recordings.cs                Recordings folder, file naming, list/rename/delete/export (AudioRecorder.swift's statics)
    AudioRecorder.cs             the CW page's RECORD: Main audio to a WAV (AudioRecorder.swift)
    RecordingPlayer.cs           plays a recording for the Recordings window (RecordingsListView.swift's RecordingPlayer)
    SdrAudioFileWriter.cs        16-bit mono WAV writer: the OpenWebRX recorder tap and AudioRecorder (SDRAudioFileWriter.swift)
    CwClassicDecoder.cs          CWKit's classic CW decoder (captobie/cwdecode DSP/ + Morse/)
    CwNeuralDecoder.cs           CWKit's neural CW decoder: spectrogram, resampler, streaming CTC, ONNX model, pipeline (Neural/)
    CwReceiver.cs                CW decode worker + window state (CWReceiver.swift + CWKit's PipelineRunner)
    CwSender.cs                  CW send queue via the rig's keyer memory, CwText, macros, callsign finder (CWSender/CWCallsigns.swift)
    WebSdrAudioTap.cs            process-loopback capture of the WebSDR window's audio for the CW window (WebSDRAudioTap.swift)
  Assets/
    CWNet.onnx                    CWKit's neural CW model, converted by ../Tools/cwnet_to_onnx.py
  Settings/
    AppSettings.cs                every setting (connection, audio, WPSD, APRS, station, WebSDR, CW, HOME, polling, appearance); file-based (see its doc comment on why not LocalSettings yet)
    Appearance.cs                 AppTheme / ButtonValueColor (ports of the FTX1Core Appearance enums)
```

## Updates (Settings → About, 2026-10-03)

Notify-only: `Services/UpdateChecker.cs` reads the repo's GitHub Releases and
looks for the newest non-draft, non-prerelease tag `windows-v<version>`
(e.g. `windows-v0.8`; the Mac's `v0.x` tags are ignored). A newer one than the
`.csproj`'s `<Version>` (kept equal to the Mac's) shows its notes and a
Download button that opens the release page. "Check for updates when the app
starts" (default on) does the same silently at launch, with a dialog only if
there's an update. Build-verified only; the first real Windows release
(`windows-v0.8`) exists now, but nothing older has checked against it yet.

## Releasing

The release is a zip of the `dotnet publish` folder: unpackaged and
self-contained (.NET + Windows App SDK included), so no installer and nothing
else to install. Users unzip it anywhere and run `FTX1RemoteWindows.exe`.
It isn't code-signed, so SmartScreen warns on first run ("More info → Run
anyway"). Local mode still needs hamlib's `rigctld.exe` on the PC.

1. Bump `<Version>` in `FTX1RemoteWindows.csproj` (kept equal to the Mac's),
   commit and push — the update checker compares against this.
2. Publish to an empty folder, so no stale files end up in the zip. The
   `.csproj`'s `CopyXamlResourcesToPublish` target copies the app's `.pri`
   and `.xbf` files, which `dotnet publish` leaves out (without them the exe
   dies silently at startup, 0xc000027b in `Microsoft.UI.Xaml.dll`):

   ```powershell
   Remove-Item -Recurse -Force C:\Tools\FTX1Remote-release
   & "C:\Program Files\dotnet\dotnet.exe" publish FTX1RemoteWindows.csproj -c Release -r win-x64 --self-contained -o C:\Tools\FTX1Remote-release
   ```

   Run `C:\Tools\FTX1Remote-release\FTX1RemoteWindows.exe` once to check it
   opens.
3. Zip it:

   ```powershell
   Compress-Archive -Path C:\Tools\FTX1Remote-release\* -DestinationPath C:\Tools\FTX1Remote-Windows-<version>-x64.zip -Force
   ```

4. Create the release (GitHub CLI, installed at `C:\Program Files\GitHub
   CLI\gh.exe` on the user's PC). The tag must be `windows-v<version>`, and
   `--latest=false` keeps the Mac's release as the repo's "Latest" (Sparkle
   doesn't use that badge, but the releases page does):

   ```powershell
   gh release create windows-v<version> C:\Tools\FTX1Remote-Windows-<version>-x64.zip --repo captobie/ftx1-remote --target main --title "Windows <version>" --notes "..." --latest=false
   ```

   Write the notes by hand (what changed, plus the install/SmartScreen/
   rigctld lines from `windows-v0.8`'s notes). The update dialog shows them.
