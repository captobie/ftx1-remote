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
Connect: a window with the Mac's tabs (`SettingsView.swift`) along
a `SelectorBar`. Since 2026-10-20 it's a resizable `Window` (minimum
860×560, owned by the main window, which is disabled with `EnableWindow`
while it's open — `OverlappedPresenter.IsModal` left the main window
usable), not a `ContentDialog`: that can't be resized and is capped by the
main window's size, which clipped the tab bar ("Appearan…") and the
Logbook tab's Log4OM row. Escape = Cancel. Stored in `settings.json` (`Settings/AppSettings.cs`).
Unlike the Mac, where only the rigctld tab waits for Done, nothing is
written until **Save**, and Cancel discards every tab. What Save changed is
applied at once, also while connected, except the rigctld tab (below).

- **rigctld**: Connection (Remote / Local, `AppSettings.ConnectionMode`,
  defaulting to Remote so a pre-Local settings file behaves as before), then
  - **Remote**: Pi hostname (Tailscale MagicDNS, e.g. `ftx1-pi`) — port
    fixed at 4532, not user-configurable, matching
    `RigctldSettings.remoteHost` (`Apps/Mac/FTX1RemoteMac/
    RigctldSettings.swift`).
  - **Local**: which `rigctld.exe` to run (a picker: **Automatic
    (recommended)**, the default; **Built-in (Hamlib 4.7.2)**; the
    installed copies Automatic would look at; **Browse…** for any other
    path — see "Bundled rigctld" below), hamlib model
    number (1051, the FTX-1), COM port (editable drop-down listing the
    ports in `HKLM\HARDWARE\DEVICEMAP\SERIALCOMM`, refreshed each time it
    opens), and baud rate (default 38400; 4800–115200, plus a hand-set
    value from settings.json).

  Unlike the Mac, switching mode doesn't need a relaunch — this app builds
  a fresh `RigctldClient` on every Connect — but the tab is read-only while
  connected. The connection bar says which connection Connect will use
  ("Disconnected · Remote, ftx1pi"); Connect with no Pi host (Remote), or
  no COM port (Local), points at Settings instead.

  A **Version** box (2026-10-06, the Mac's `RigctldVersionBox`) follows
  the tab's unsaved fields: **Uses** (Local only) resolves the picked
  rigctld the way Connect would and shows its `--version`, the reason
  ("Using built-in Hamlib 4.7.2 — C:\…\rigctld.exe is 4.5.5, too old for
  the FTX-1."), a warning when an explicit choice is too old or lacks the
  model, and what this session's Connect launched if that differs; and
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
- **Appearance**: Theme (Auto, Default Light, Default Dark, Glossy Black,
  Dusty Rose, Icy Mint — see "Themes" below), VFO digits (Theme default / Consolas / Cascadia
  Mono / 7-segment), VFO digit color (Theme default or the button value
  colors' eight; 7-segment unlit cells follow it at the theme's alpha) and
  the MENU grid's button value color (the Mac's eight;
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

- On Connect it probes `127.0.0.1:4532`, first with `\dump_caps`
  (`RigctldClient.ReadRigModelAsync`, answered without rig I/O) and then a
  frequency read. A responsive rigctld for the configured model is
  **adopted** and left running on Disconnect/exit (WSJT-X or another client
  may be using it — its COM port/baud rate are whatever it was started
  with). One started for **another model** is neither adopted nor killed:
  Connect fails with "The rigctld already running on port 4532 is for
  Hamlib Dummy (model 1), not the FTX-1. Quit it (or the program that
  started it, e.g. WSJT-X), then connect again." (2026-10-14, the Mac's
  check). One that accepts the connection but doesn't answer is treated as
  stale and killed. Windows has no port→PID lookup without P/Invoke, so
  this kills processes *named* `rigctld`, unlike the Mac's `lsof` check.
- Otherwise it picks a `rigctld.exe` (below) and spawns `rigctld.exe -m 1051 -r COMx -s <baud> -t 4532
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

### Bundled rigctld (2026-10-14)

Hamlib is no longer a separate install. The FTX-1 (model 1051) first
appears in Hamlib 4.7, and an older rigctld exits at once, so the app
ships Hamlib's **official** Windows build of 4.7.2 (`hamlib-w64-4.7.2.zip`
from the GitHub release, sha256 `8553bc6c…3304c7`), not one built here:
`rigctld.exe` plus exactly the DLLs it loads — `libhamlib-4.dll`,
`libusb-1.0.dll`, `libwinpthread-1.dll` (found with Git Bash's `ldd`; a
copy without `libusb` fails with STATUS_DLL_NOT_FOUND; the zip's
`libgcc_s_seh-1.dll` isn't loaded) — and Hamlib's `COPYING`, `COPYING.LIB`,
`LICENSE` and `README-w64-bin.txt`. 12.3 MB. x64 only (Hamlib has no ARM64
build; it runs under emulation there).

- **Vendoring**: `Apps/Windows/Tools/fetch-rigctld.ps1 -Zip <zip>
  -WinpthreadsCopying <COPYING>` checks the sha256, copies the files (plus
  winpthreads' licence, see Licences) into `FTX1RemoteWindows/Vendor/hamlib/` and
  runs the copy from there with PATH cleared (`--version` must say the
  version, `-l` must list 1051). For a new Hamlib: download the w64 zip,
  check it against the release's `SHA256SUM-w64-<version>`, rerun the
  script with `-Version`/`-Sha256`, re-check the DLL list with `ldd`, and
  commit `Vendor/hamlib/`. Keep the version equal to the Mac's
  (`Scripts/build-rigctld.sh`), since one source tarball on the release
  covers both.
- **Shipping**: `.csproj` Content items copy `Vendor\hamlib\*` to
  `<output>\hamlib\` for both `dotnet build` and `dotnet publish`.
- **Selection** (`Services/RigctldBinary.cs`, a port of the Mac's
  `RigctldBinary.swift`; `AppSettings.RigctldChoice`): **Automatic**
  (default) tries, in order, the `rigctld.exe` on PATH, `C:\Program
  Files[ (x86)]\hamlib*\bin` (newest folder version first) and
  `C:\Tools\hamlib\bin`, and uses the first whose `--version` is ≥ 4.7.0
  *and* whose `-l` lists the configured model; otherwise
  `hamlib\rigctld.exe` next to the app. The probes run off the UI thread,
  capped at 3 s / 5 s (killed on timeout), only when a rigctld has to be
  spawned — never for an adopted one. **Built-in** or an explicit path
  (used as is, with a warning in Settings if too old or missing the model)
  can be picked instead. The choice and why are logged to `app.log`
  ("connection: Using installed C:\Tools\hamlib\bin\rigctld.exe (Hamlib
  4.7.2).").
- **Migration**: the old `RigctldPath` (no default) reads as Automatic
  when empty; any path the user set stays an explicit choice.
- **Testing the fallback** without touching the installed Hamlib: Debug
  builds read `FTX1REMOTE_RIGCTLD_SEARCH_PATHS` (semicolon-separated
  `rigctld.exe` paths instead of the search above; `none` = no installed
  copy) — set it in the shell that launches the app.
- **Licences**: rigctld is GPL-2.0-or-later, libhamlib LGPL-2.1-or-later,
  libusb LGPL-2.1-or-later; the app runs rigctld as a separate program
  over TCP (mere aggregation). The licence files ship in `hamlib\`. The
  combined `v<version>` GitHub release carries Hamlib's exact source
  tarball (`hamlib-4.7.2.tar.gz`, attached by the Mac half's
  `release-mac.sh`), which is the source offer for both apps as long as
  both ship the same Hamlib version.
  - **libusb-1.0.dll** is libusb **1.0.24** (its version resource: build
    11584, the official release build), LGPL-2.1-or-later — the text in
    `COPYING.LIB`. Hamlib's tarball doesn't contain it, so each
    release also carries libusb's own release tarball,
    `libusb-1.0.24.tar.bz2` (sha256 `7efd2685f7b327326dcfb85cee426d9b8
    71fd70e22caa15bb68d595ce2a2b12a`, from libusb's GitHub release; its
    `.asc` checked: good signature from Chris Dickens, key
    `98928A68DEC3549C96F865B04658AEE82B5E6442`). Kept in the gitignored
    `releases/` on the Mac (attached by `release-mac.sh`'s `gh release
    create` line, which refuses to start without it) and on the Windows PC.
  - **libwinpthread-1.dll** is the MinGW-w64 runtime, MIT-style: notice
    only, no source obligation. The zip has no licence text for it, so
    winpthreads' `COPYING` from mingw-w64 **v12.0.0** — the version Debian
    13 (the zip's build host) ships; the DLL says "2010-2023" and GCC 13 —
    is vendored as `COPYING-winpthreads.txt`.
  - For a new Hamlib, re-check both DLLs' versions (file properties /
    `VersionInfo`) and update the tarball and licence to match.
- Tested 2026-10-14 in the built app with Local mode and a non-existent
  COM port (not on the rig): Automatic picks `C:\Tools\hamlib\bin\
  rigctld.exe` (4.7.2) on the test PC; with only a fake 4.5.5 rigctld, or
  none, installed (the override), it picks the built-in copy and Connect
  spawns it from `hamlib\`; an explicit fake 4.5.5 shows the warning; the
  model check refuses the bundled rigctld running the dummy rig (`-m 1`)
  and adopts it with model 1 configured. **Not yet** run against the
  FTX-1 itself, from a release zip on a PC without Hamlib, or on ARM64.

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
Transmit is off, or while the transmitting side (SUB with TX:SUB or split
— MAIN only until 2026-10-25, as on the Mac) is outside a `BandPlan` band
(including before the first frequency read), or outside Settings →
License's privileges (below). The off direction is never gated.

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

## Themes (Settings → Appearance, phase 1, 2026-10-26; unit-tested, then tested by the user the same day)

The Mac has the same themes since 2026-10-26 (CLAUDE.md, "Themes (Mac)"; `ThemeDefinition.swift`, same presets and colour values — keep the two in step). A theme (`Models/ThemeDefinition.cs`,
WinUI-free so `ThemeTests` cover it) is a base (Light/Dark) plus
overrides; whatever it leaves null is the base WinUI theme's own:

- window and panel backgrounds; button background (resting, hover,
  pressed, disabled), border and text; toggle buttons while on; accent
  (sliders, toggle switches); secondary captions (`AppSecondaryTextBrush`,
  the main window's former "Gray" labels); MENU grid value color (null =
  Button value color).
- **VFO boxes** (`VfoTheme`, every field set — the defaults are the boxes
  as they always looked): background, border (and SUB's single-receive
  border), digit colour/font/bold, unlit 7-segment colour, MAIN/SUB label,
  mode text and its border, callsign, memory channel, reflector line.
- Colours are `#RRGGBB`/`#AARRGGBB` strings; a fill is one colour or a
  top-to-bottom gradient (`ThemeFill`, optional offsets) — a sharp step in
  the middle is what reads as glossy. Enums are stored by name, so the JSON
  is ready for custom themes.
- **Not themeable, on purpose**: the TXRX/RX tags, PTT while keyed, the
  squelch light, the meters, and status colours (connected/error).

`Settings/ThemeEngine.cs` turns the theme into a `ResourceDictionary`
(the same keys in its Default/Light/Dark theme dictionaries) merged *last*
into the app's resources, so it beats `XamlControlsResources` in every
window, flyout and dialog: WinUI's lightweight styling, app-wide
(`Button*`, `ToggleButton*`, `RepeatButton*`,
`ApplicationPageBackgroundThemeBrush`, `CardBackgroundFillColorDefaultBrush`,
the accent/slider/toggle-switch keys). Controls only re-read
ThemeResources on a theme change, so `ThemeEngine.ApplyTo(root)` flips
each window root through the other theme and back; every window's
`ApplyTheme` calls it. `ThemeEngine.Load()` runs in `App.OnLaunched`
before `MainWindow` exists, since its XAML refers to
`AppSecondaryTextBrush`. The VFO boxes are drawn in code
(`MainWindow.ApplyVfoTheme`); `Controls/VfoDigits.cs` draws the 7-segment
digits as two non-hit-testable TextBlocks over the (then transparent)
frequency TextBlock, following its Text — so the callers and the VFO
entry flyout are unchanged. DSEG7 has no "—" and its "!" is a
digit-wide blank: `SevenSegmentText` pads MHz to three cells and shows
`---.---.---` before the first read, over `888.888.888` unlit segments.

Saved as `ThemeName` (`"Auto"` or a preset's name) in settings.json; an
older file's `Theme` number (0 Auto, 1 Light, 2 Dark) maps to Auto /
Default Light / Default Dark until the next Save. A name that no longer
exists, or a broken theme, falls back to Auto (logged).

- **Presets**: Default Light and Default Dark (no overrides: the app
  exactly as before), **Glossy Black** (charcoal gradient window, glossy
  grey buttons with a light top edge, blue gloss for toggled buttons and
  the accent, near-black glass VFO boxes with a steel-blue border, ice-white
  7-segment digits over faint unlit segments), **Dusty Rose** (light, colours
  sampled from Visual Studio's Silky Pink: dusty rose window
  `#F0E3E1`, near-white panels, satin buttons with warm near-black text, VS's
  mauve-rose accent `#7A453D` for toggled buttons and sliders, dark mauve
  VFO boxes with a rose border and Consolas digits), **Icy Mint** (light, after Visual Studio's theme of
  that name: frosted mint window, white buttons shading to pale mint with
  deep teal text, teal gloss for toggled buttons and the accent, dark teal
  VFO boxes with a mint border and icy Consolas digits).
- **Checked** (2026-10-26, built app, disconnected): Default Dark looks as
  before; Glossy Black at launch; Settings → Glossy Black → Default Light →
  Glossy Black + Cascadia Mono, all applied live; 367 tests pass. VFO
  digit color Orange on Glossy Black (2026-10-26), applied live. Silky
  Pink and Icy Mint, applied live (2026-10-26).
  Then tested by the user the same day: digits showing a real frequency
  (connected), the secondary windows and Settings in Glossy Black.
  ComboBoxes aren't themed — they stay the base theme's.
- **Phase 2 (planned)**: custom themes — duplicate a theme, edit it,
  save under a name, rename/delete, JSON import/export.

## License-class guardrail (Settings → License, 2026-10-25; unit-tested, then tested live by the user the same day)

Port of the Mac's (CLAUDE.md, "License-class guardrail"): Off (default —
the bands only, as before), a US class (Extra, Advanced, General,
Technician, Novice), an ITU Region 1/2/3 allocation, or Custom. A
transmission passes only if the transmitting side's *occupied spectrum*
(SSB/DATA-U 100–2900 Hz, CW ±100 Hz, RTTY ±300, AM ±3 kHz, FM/DATA-FM
±8 kHz, C4FM ±6.25 kHz) fits inside segments allowing its mode (CW/phone/
data; C4FM is phone); the amateur-band check stays the outer limit.

- `Models/TransmitPrivileges.cs` and `Models/PrivilegePresets.cs` port
  `Sources/FTX1Core/Licensing/` — the Swift files stay the source of
  truth; copy any table correction made there. This app's `RigMode` has
  no C4FM, so the gate's input is a `TransmitSignal` (frequency, mode,
  `IsC4fm`), and `onlyModes` holds Swift's raw mode names ("USB",
  "PKTUSB", "C4FM"). The JSON is the Mac's Codable form, so Export/Import
  files move between the two apps (`TransmitPrivilegesTests` reads a
  Mac-shaped export).
- `TransmitGate.BlockReason(action, transmitEnabled, transmitter,
  privileges)`; `MainWindow.TransmitBlockReason` is the one gate for PTT,
  the MENU grid's MOX/ANT TUNE (`MenuGrid.GateReason`), the CW send pane
  and, through `IHubRigHost.Transmitter`/`Privileges`, every hub command.
- **Mid-transmission**: with privileges on, after every poll (and every
  local keying change) while PTT/MOX is on, leaving them unkeys once (CW
  sender stop, "KY00", PTT and MOX off, the hub's keyer stop) —
  `EnforcePrivilegesWhileKeyed`. Off = no such check. Only as fast as the
  poll sees a front-panel tune.
- Unlike the Mac, it **applies on Save** like every other tab here (the
  Mac's applies at once). The Custom table is a draft until then; Save
  refuses a frequency that doesn't parse. Copy to Custom / Start From
  confirm before replacing a non-empty table. Stored in `settings.json` as
  `LicensePrivileges` (the Mac's choice raw values) and
  `LicenseCustomProfile`.
- No CW key window on Windows, so nothing to wire there.

Checklist (tested live by the user, 2026-10-25): US General, 14.200 USB → PTT dimmed
with the reason; 14.250 → works; TX:SUB on a CW frequency with MAIN in
USB → the SUB side decides; key, then tune out of the privileges → unkeys;
the iPad's PTT refused with the same reason.

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
each write; sets go out as `W <cmd>; 0` since 2026-10-06 and read
rigctld's empty reply, because `; ;` made rigctld wait ~2 s for an answer
a set never gets). Tested against the fake Pi (app swap, no double flip on the
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
- **APRS map (2026-10-21)**: the APRS drop-down's **Map**
  (`Controls/AprsMapWindow.cs`), the Mac's APRS Map on OpenStreetMap
  instead of Apple Maps: every station in the history with a position,
  blue for Main and orange for Sub, labelled with its callsign; a click
  shows position, symbol, source, last heard and comment. All/Main/Sub
  filter, Fit All; fits once when opened (or at the first position heard
  while open), never by itself after that. The page is
  `Assets/AprsMap/index.html` with [Leaflet](https://leafletjs.com) 1.9.4
  (BSD-2-Clause, `leaflet.js`/`leaflet.css` from the npm tarball, integrity
  checked against the registry, licence as `LICENSE-leaflet.txt`), served
  from the app folder through a WebView2 virtual host
  (`aprs-map.ftx1remote.example`) in the shared WebView2 profile; the
  window posts the stations to it as JSON. Only the tiles come from the
  network (`tile.openstreetmap.org`; its tile usage policy wants an
  identifying user agent, so this web view's ends in
  `FTX1RemoteWindows/<version>`, plus the attribution the page shows —
  heavy use would need another tile provider). Tested against the PC's
  saved history (5 positioned stations, popups, the Sub/Main filter)
  through the DevTools protocol (`WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=
  --remote-debugging-port=…`), then tested by the user the same day,
  working.

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
  failed, and characters left out), the status line, and the send line
  (Enter queues). Their call moved to the Log QSO pane (below) on
  2026-10-09, as on the Mac. Text prep is the Mac's `CWText`: uppercase,
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
- **Monitor (2026-10-22, tested on the air by the user the same day)**:
  the Mac's CW monitor. A switch in the send pane's header
  (`CwMonitor` in settings.json, off by default) plays a local sidetone
  for each chunk on the audio output (Settings → Audio, Windows' default
  when unset). `Services/CwMonitor.cs` renders the chunk from
  `CwText.Keying` (PARIS timing, also behind `CwText.Duration` now) at the
  rig's KS and KP (700 Hz until read) when `CwSender.Keying` fires at the
  "KY0n", and plays it through its own `WasapiOut`. So it runs a network
  hop ahead of the rig and ignores the rig's weighting. Stop cuts it off.
  It never plays into the rig's own USB audio (the same check as
  Recordings).

## Logbook — HRD Logbook (CW window Log QSO pane, 2026-10-09)

The Mac's MacLoggerDX logbook (CLAUDE.md's "Logbook — MacLoggerDX"), with
Ham Radio Deluxe's logbook in its place: a Log QSO pane at the bottom of
the CW window, worked-before colors on the decoded callsigns, and
Settings → **Logbook**. Everything about HRD was worked out against HRD
Logbook 6.9.0.18083 on the user's PC, not from documentation:

- **QSOs go in as ADIF text over UDP**, to HRD's ADIF receiver: Tools →
  Configure → QSO Forwarding → "Receive QSO notifications using UDP9/ADIF
  from other logging programs (eg. WSJT-X)" (`UDPReceiveSection9Enable` in
  its settings; off by default, so the user has to turn it on once; it
  listens on 127.0.0.1:2339 on that PC). One datagram = `AdifRecord.File`
  (header, `<EOH>`, one record), the form WSJT-X's secondary "ADIF
  broadcast" server sends. Tested with one QSO (TE5T, every field right).
  HRD fills in the station callsign and looks the call up (name,
  country) itself. **The Mac's WSJT-X binary route doesn't work here**:
  HRD's UDP 2237 listener is its WSJT-X ALERT (decodes) dock, and neither a
  "QSO Logged" nor a "Logged ADIF" message sent there was logged.
- **No Lookup button**: unlike MacLoggerDX, HRD has no way found to be
  asked for a lookup from outside (the 2237 dock ignores Status messages);
  it looks the call up itself when the QSO arrives.
- **Reading the log**: HRD's database list is in
  `%APPDATA%\HRDLLC\HRD Logbook\LogbookDatabases*.xml` (newest file;
  `LogbookDatabases8.xml` in 6.9); the receiver's target database
  (`UDPTargetDB9` in `LogbookUserSettings.xml`) picks which. A "Local/
  SQLite" log is a `.hrdsql` SQLite file (Access/MySQL/SQL Server logs
  aren't read — the tab says so). One table, `TABLE_HRD_CONTACTS_V07` (the
  code takes the newest `TABLE_HRD_CONTACTS_V%`): `COL_CALL`, `COL_BAND`
  ("40m", sometimes "40M"), `COL_MODE`, `COL_FREQ` (Hz), `COL_QSO_DATE`
  ("yyyy-MM-dd") and `COL_TIME_ON` ("HH:mm:ss.fff"), UTC; WAL journal.
  Opened read-only and unpooled (Microsoft.Data.Sqlite), never written.
  1,477 QSOs read in ~0.2 s.
- `Services/HrdLogbook.cs` (settings, running/listening checks, log
  reads), `Services/QsoLogger.cs` (send, then confirm by finding the QSO
  in the log within 5 s, since UDP gets no reply — the Mac's flow),
  `Services/WorkedStationsStore.cs` (index rebuilt when the log or its
  `-wal` file changes, checked every 5 s, and after a confirmed log; owned
  by the CW window), `Models/LoggedQso.cs` (+ `AdifMode`, `AdifRecord`),
  `Models/WorkedStations.cs`, `Controls/CwLogPane.cs`. The models are the
  Swift `FTX1Core/Logbook/` files translated; those stay the source of
  truth for the rules (base call, band compare, ADIF fields).
- **Log QSO pane** (the Mac's `CWLogPane`): Their call (still
  `CwSender.TheirCall`, so `{CALL}` and click-to-fill are unchanged), time
  on (set when the call goes from empty to filled; reset button), the
  worked-before line, RST sent/rcvd (599), name, comment, the transmitting
  side's frequency/mode/power (SUB's with TX:SUB or split — the TXRX tags'
  rule, `MainWindow.CwTransmitterNow`), and Log QSO (Ctrl+L). Data modes
  are refused; C4FM logs as DIGITALVOICE/C4FM. Fields clear only once the
  QSO is found in the log.
- **Worked-before colors**: green worked on the band the rig transmits on,
  orange worked only on other bands (or no band known — disconnected),
  blue never; a legend row under the decoded text. A fixed blue, not the
  accent color, which (salmon on the user's PC) was too close to orange.
- **Settings → Logbook**: None / Ham Radio Deluxe Logbook, the log file
  (HRD's own by default, Browse… / Use HRD's), host/port overrides (empty
  = HRD's receiver settings, shown as placeholders), and a status card:
  HRD running, receiver on/listening (`GetActiveUdpListeners`), the log's
  QSO/station counts.
- Tested 2026-10-09: the logging route by script against the running HRD
  (above); the models and HRD reader in a scratch harness against the
  real log, read-only (ADIF text identical to what HRD accepted, TE5T
  found to the second, K6NA this band/other band); in the built app,
  disconnected: the Logbook tab's status card, Their call → time on and
  "Worked 1× · last 2026-10-04 40m CW", the not-connected refusal, and a
  synthesized CW recording decoded with K6NA/JJ0PKS/W1AW/0 orange and
  JA1XYZ/ZL2AB uncolored. **Not yet done**: logging a QSO from the app
  with the rig connected, and the green this-band case on the air.

## Logbook — Log4OM (2026-10-20)

A second choice in Settings → Logbook, beside HRD. Same Log QSO pane,
worked-before colors and send-then-confirm flow; both programs go through
`ILogbookProgram` (`Services/LogbookProgram.cs`, with the shared read-only
SQLite helper `LogbookDatabase`), so `QsoLogger` and `WorkedStationsStore`
don't care which. Worked out against Log4OM 2.42.1.0 on the user's PC — its
settings file, its assemblies' enum/type names (reflection only) and live
tests — not from documentation:

- **QSOs go in as ADIF text over UDP**, the same datagram as HRD's, to a
  Log4OM **UDP inbound connection of type ADIF_MESSAGE** (Settings →
  Program Configuration → Software Integration → Connections). There is
  none until the user adds one (port 2236 on that PC); it listens on
  0.0.0.0. A QSO was in the log within a second, every field right; Log4OM
  replaces `programid` with its own and looks the call up itself.
- **Lookup button** (Log4OM only, left of Their call, as on the Mac):
  Log4OM's **remote control** (UDP, port 2241, on by default) takes an XML
  `RemoteControlRequest` (`MessageId` GUID, `RemoteControlMessage`,
  `Callsign`, …) and answers the sender with a `RemoteControlResponse`
  (`Done`, `ErrorMessage`) — so unlike UDP logging, a lookup is
  confirmed. `SetCallsign` fills Log4OM's call field; `Alive` is used by the
  Settings status card. Its `WorkedBefore` request also works
  (`WorkedSameBandMode`/`WorkedSameMode`/`Undefined`) but answers one call
  at a time, so worked-before reads the log file like HRD's. The other
  requests (`SetTxFrequency`, `SetMode`, `ClearUI`, …) aren't used.
- **Settings**: `%APPDATA%\Log4OM2\user\config.json`, the running
  configuration (`RunningConfigurationId` → `UserConfigs[]`):
  `DbConfiguration` (`DatabaseType` 1 SQLite / 2 MySQL / 3 MariaDB,
  `Path`), `Connections[]` (`NetworkConnectionType` 1 = UDP inbound,
  `NetworkInboundMessageType` 1 = ADIF_MESSAGE, `SourcePort`, `Enabled`),
  `RemoteControlEnabled`/`RemoteControlPort`. The file also holds service
  passwords: read only the keys above. Process name `L4ONG`.
- **Reading the log**: SQLite, table `Log`: `callsign` (COLLATE NOCASE),
  `band` ("40m"), `mode`, `freq` in **kHz** (7030.5), `qsodate` UTC text
  ("2026-10-20 14:05:13Z"). Rollback journal, not WAL. MySQL/MariaDB logs
  aren't read (the tab says so).
- **Settings → Logbook**: the log file (Log4OM's open log by default,
  Browse… / Use Log4OM's), host/port overrides (empty = this PC and the
  ADIF_MESSAGE connection's port; the host also applies to Lookup), and a
  status card: running, receiving, remote control answering, the log's
  QSO/station counts. `Services/Log4OmLogbook.cs`.
- Tested 2026-10-20 against the running Log4OM: by script, the ADIF route
  and the remote-control requests; in a scratch harness compiling the
  app's own logbook files (with a stand-in `AppSettings`): the config read,
  the log read (QSO count, this band / other band / `/P` / never), a QSO
  logged and confirmed (14.0453 MHz → 14045.3, 20m), the unconfirmed reason
  for a port with nothing listening, `Alive`, and Lookup answered
  `Done`. The Windows app builds clean. **Not yet done**: the Settings tab
  and the CW window's Lookup button in the built app, and logging from the
  app with the rig connected.

## Logbook — Wavelog (2026-10-25)

The Mac's Wavelog integration (CLAUDE.md, "Logbook — MacLoggerDX", the
Wavelog bullets), all three parts, through Wavelog's **API v2** (3.1 or
newer; v1 keys are refused, and Settings says so). The Swift files
(`Sources/FTX1Core/Logbook/Wavelog.swift`, `WavelogTuneRequest.swift`) stay
the source of truth for the request and reply shapes.

- **Logging**: every Log QSO also goes to Wavelog, beside HRD or Log4OM (or
  with Logbook = None), both at once (`QsoLogger.LogAsync` →
  `QsoLogOutcomes`). `Services/Wavelog.cs` posts the ADIF record to
  `index.php/api/v2/qso` with `Authorization: Bearer wl2_…`; a duplicate
  comes back as `skipped` and counts as logged. The Log pane clears only
  when both confirm; if the primary took the QSO and Wavelog didn't,
  "Retry Wavelog (<call>)" resends it to Wavelog alone until it works or is
  dismissed (✕). Worked-before and Lookup stay with HRD/Log4OM.
- **CAT** (`Services/WavelogRadioReporter.cs`, off by default; needs
  `radio:write`): `MainWindow.Wavelog.cs` hands it the transmitting side
  (the Log pane's rule) after every poll, MAIN as RX when split/TX:SUB and
  different, and the RF POWER setting in watts. Posted to `api/v2/radio`
  under the Radio name (default FTX-1) on a change, at most every 2 s,
  every 60 s while unchanged, nothing while disconnected, 30 s pause after
  a failure. Modes per Wavelog's `radiohelpers.js` (DATA-U → PKTUSB,
  DATA-FM and C4FM → FM).
- **Tune from Wavelog** (`Services/WavelogTuneListener.cs`, off by
  default): Wavelog's DX cluster/bandmap `fetch` `GET <cat_url>/<Hz>/<mode>`
  from the browser, `http://127.0.0.1:54321` unless the radio's CAT URL is
  set in Wavelog — WaveLogGate's port, so only one of the two can listen
  (Settings says "in use — is WaveLogGate running?"). A `TcpListener` on
  127.0.0.1 only (exclusive bind); only a request whose `Origin` is the
  Settings URL's origin is obeyed, with CORS headers and Chrome's
  private-network preflight answered. Tuning runs on the UI thread with
  the WebSDR click-to-tune rules (MAIN, not while transmitting, not in
  Memory mode, not disconnected); a refusal is a 409 with the reason
  (Wavelog only shows its generic "not responding" toast; Settings shows
  the last request). Wavelog sends "rtty" for most digital spots, FT8
  included.
- **Settings → Logbook → Wavelog**: the three switches, URL, API token,
  station location (Refresh = `GET api/v2/station`; picked automatically
  the first time logging is on with a URL and token), Test (the API's dry
  run: token, scope and location checked, nothing written), a warning when
  Settings → Station's callsign isn't the location's (v2 files the QSO
  under the location's callsign), Radio name, the listen port, and live
  CAT/tune status lines. Like every other tab, nothing applies until Save.
- **The token** is in Windows Credential Manager (`Services/
  WavelogToken.cs`, generic credential "FTX1Remote/Wavelog", this user),
  not `settings.json` — the Mac keeps it in the keychain. Debug builds read
  `FTX1REMOTE_WAVELOG_TOKEN` first, to test without touching the stored
  one.
- Tested 2026-10-25: `FTX1RemoteWindows.Tests/WavelogTests.cs` (the Mac's
  WavelogTests/WavelogTuneRequestTests cases, a QSO over local HTTP, and
  the listener over loopback: preflight, tune, foreign/missing Origin,
  409, 404, port in use); Credential Manager write/overwrite/read/delete
  in a scratch harness (another target name); the built app through UI
  Automation against a stand-in Wavelog server (disconnected): Refresh,
  Test, the mismatch warning, Save, the listener answering curl (204
  preflight, 409 "the rig isn't connected", 403 for other origins) with
  Settings' status following, and the listener closed with the window.
  Then tested live by the user the same day against their Wavelog with the
  rig connected: working.

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
as-is. Built and tested on the rig by the user on Windows, 2026-10-06, all
working. The Mem List button sits under Waterfall and opens
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

## Memory scan (MAIN and SUB, 2026-10-06)

The Mac's memory scan (repo root CLAUDE.md, "Memory scan"), ported. Written
on the Mac, then built and tested on the rig by the user on Windows,
2026-10-06: working. Everything about the rig's behavior was probed on the real rig for the
Mac and is the same here; `MainWindow.MemoryScan.cs`'s header comment
lists it.

- **Controls**: Scan and Skip next to Mem List under Waterfall. Scan opens
  a menu (Scan SUB / Scan MAIN, each enabled only in that side's Memory
  mode, SUB not in single-receive display) and turns into "Stop MAIN"/"Stop
  SUB" while a scan runs; Skip resumes a paused scan past the busy channel.
  The Mem List window's toolbar has a MAIN/SUB picker with Scan Down/Up,
  then Skip and Stop Scan while one runs.
- **Rig commands**: `RigctldClient.SetMemoryScanAsync` ("SC<side><n>": 0
  off, 1 up, 2 down — any stop stops both sides), `GetRadioInformationAsync`
  ("RI0": P7 is the scan state for the whole radio, `Models/MemoryScan.cs`),
  `GetMemoryScanSideAsync` ("SC;" reads back the side last told to scan,
  for a front-panel scan).
- **Polling**: while the rig scans, `PollFieldsAsync` hands over to
  `MemoryScanTickAsync` and the poll timer drops to 250 ms: "RI0", plus the
  side that isn't scanning kept live (MAIN's "FA"/"MD0" during a SUB scan,
  SUB's "MC1" and that channel's "MR" during a MAIN scan). The scanning
  box shows "—", SCANNING and SCAN; on a pause or stop
  `PublishMemoryScanStopAsync` reads the channel (SUB's frequency/mode from
  its "MR" entry), checks the number again, and shows it with SCAN PAUSED.
  In Memory mode every normal poll starts with an "RI0" read, which is how
  a front-panel scan or a BUSY resume is picked up before the poll reads a
  random channel.
- **One side at a time** (user decision, as on the Mac): starting a scan on
  one side stops the other first.
- **TX side**: a scan moves the rig's TX/RX side to the scanning side ("VS"
  = "FT"). The side from before is put back ("FT0"/"FT1" right after the
  stop) when the app stops the scan — Stop, or a tune/recall that stops it
  — not before a transmit, not after a front-panel stop, not once TX:MAIN/
  SUB is clicked.
- **Stopped first** (`StopMemoryScanForAsync`): main-frequency entry, mode,
  band, ⇄ and MAIN's channel step stop either side's scan ("F currVFO",
  "M currVFO" and "CH" follow the active side, so the TX side is restored
  first); V/M, MAIN channel entry and MAIN recall stop a MAIN scan; SUB
  frequency, channel entry/step and SUB recall stop a SUB scan. PTT, MOX,
  ANT TUNE (`MenuGrid.BeforeTransmitAsync`) and each CW chunk
  (`CwRigLink.BeforeKeyAsync`) stop it but keep the TX side.
- **Fixed with this — the poll read the boxes by hamlib's active VFO**:
  MAIN was "f currVFO"/"m currVFO" and SUB a `v`-based read, so with TX on
  SUB the two boxes traded places. The poll now reads MAIN with raw "FA"/
  "MD0" and SUB with "f Sub" (`GetMainFrequencyAsync`/`GetSubFrequencyAsync`),
  like the Mac's fast tier; "MD0" also reads C4FM, which "m" couldn't.
  Unchanged: `SetFrequencyAsync`/`SetModeAsync` ("F/M currVFO"), MAIN's
  "CH" step and the MAIN S-meter ("l currVFO STRENGTH") still follow the
  active side, and `SetSecondaryFrequencyAsync` picks its side with `v`.
- Checklist used for that test: Scan MAIN and Scan SUB from the menu (box blanked,
  TXRX moving to the scanning side, the other box live), a pause on a busy
  channel, Skip, Stop (TX back to MAIN), Scan Down/Up from the Mem List
  picker, switching sides mid-scan, a Mem List recall mid-scan, a scan
  started from the front panel, and both boxes with TX:SUB and no scan.

## Desktop hub for the iPad (complete 2026-10-18: phase 1 done 2026-10-15, phase 2 built 2026-10-15, phase 3 built 2026-10-16, phase 4 built 2026-10-16, phase 5 built 2026-10-16, phase 6 built 2026-10-18)

**Status**: all six phases built and tested from a real iPad in Remote
mode. Untested across the plan: Local mode for every phase, the iPad's CW
pane *decoding* on this route, a ~10-minute audio run, a long PTT press
with PO and the tail checked on the rig, Wi-Fi loss/backgrounding during
a PTT press, several iPads at once. Known gaps: Wi-Fi loss noticed after
~20 s, and no keyer lease (both in "Phase 6 status").

Goal: the iPad's hub route (renamed "Desktop hub" on 2026-10-15, raw
`connectionRoute` value still `macHub`) can connect to this app the way it
connects to the Mac's `HubService` today. **The iPad stays unchanged on the
wire.** This app speaks the Mac hub's existing protocol
(`WireMessage.swift`, `AudioStreamFormat`) as a WebSocket *server*. That
reverses "This app is a leaf client only" for this one feature. Direct-to-Pi
control stays the same: the hub sits on top of whichever rigctld this app is
already using, Local or Remote.

### What the iPad expects (the contract to match)

- `ws://<host>:8765`, plain WebSocket, no path, no TLS
  (`RigClientViewModel.init(port: 8765)`). The client sends WebSocket
  pings as its heartbeat, so the server must answer them with pongs (any
  RFC 6455 stack does this).
- **Text frames, server → client**, decoded by trying each type in turn
  (`RigWebSocketClient.handle`):
  - `{"type":"state","state":{…}}`: the whole `RigState`. Swift decodes it
    with synthesized `Codable`, so **`frequencyHz`, `mode`, `ptt`,
    `lastUpdated`, `aprsActive`, `aprsSubActive` and `transmitEnabled`
    are required**. The optional fields can be left out. `lastUpdated` uses
    `JSONEncoder`'s default date format: **seconds since
    2001-01-01T00:00:00Z as a Double**, not Unix time and not ISO-8601.
    Modes use `RigMode`'s raw values (`USB`, `PKTUSB`, `FM-D`…), and
    `vfoMemoryMode`/`memoryScan`/`filterSide`/`txMeters` use their Swift
    enum/struct encodings. Copy the shapes from Swift. Don't guess them.
  - `memory_list` (`MemoryListPush`), `aprs_list` (`APRSListPush`),
    `menu_item` (`MenuItemPush`), `cw_keyer_reply` (`CWKeyerReply`).
- **JSON frames, client → server** (the iPad sends them as *binary* frames, `URLSessionWebSocketTask` `.data`; a binary frame is TX audio only when it starts with 0x02): `{"cmd": "...", "value": ...}`
  (`RigCommand`, ~75 commands), `read_menu_item` (`MenuItemReadRequest`),
  `cw_keyer` (`CWKeyerRequest`, incl. `acquire`/`release`).
- **Binary frames**: 1 tag byte + 8 kHz mono Int16LE PCM. `0x00` MAIN and
  `0x01` SUB go server → client. `0x02` is TX audio, client → server, and
  is accepted only from the PTT holder.
- Behaviour the iPad relies on: a state push on connect and after every
  change. Memory/APRS lists go out on connect and on change (APRS throttled
  to one per 2 s, memory to one per 1 s). Commands and TX frames from one
  client are handled in arrival order. Menu reads and keyer writes are
  answered to the asking client only, outside that order. A dropped PTT
  holder is unkeyed. "KY00" is sent if the last keyer player drops. TX
  audio has a 1.5 s silence watchdog.

### Phase 1 status (2026-10-15: built, tested on the PC, then from a real iPad by the user)

- `Services/Hub/HubServer.cs` (Kestrel, `ListenAnyIP(8765)`, dual-mode,
  path "/"), `Services/Hub/HubAddressFilter.cs` (the address rule below,
  IPv4-mapped IPv6 unwrapped first; refusals logged as "hub: refused …"
  with a 403 before the upgrade), `Services/Hub/WireModels.cs`
  (`RigStatePushWire`/`RigStateWire`, `HubWire`, `RigStateWireMapper`),
  `MainWindow.Hub.cs` and Settings → **Hub** (`AppSettings.HubEnabled`,
  off by default; the switch applies on Save like the other tabs, the
  listening state and client list are live).
- **Pushes**: one 100 ms timer on the UI thread serializes the state and
  publishes it when the JSON changed. Each poll stamps
  `RigState.LastUpdated` (it was never updated before), so every poll is
  pushed, and a UI action that changes `_lastState` goes out within
  100 ms; at most 10/s. Each client keeps only the newest unsent push
  (bounded channel of 1, drop oldest) and gets the latest one on connect.
  The hub runs whether or not the rig is connected; disconnected it pushes
  the last known state.
- **Mapping differences** from the plan's "field for field": `mode` is
  `C4FM` while `MainIsC4fm`, else the mode, else `UNKNOWN` (Swift's own
  placeholder; the field is required). `band` comes from
  `BandPlan.BandContaining`. `singleReceive`/`splitEnabled`/`txSide` come
  from MainWindow's slow-tier fields, `aprsActive`/`aprsLastCallsign` from
  the same rule as the VFO boxes' APRS line (callsign only while active and
  heard < 5 s ago). Never sent, since this app doesn't have them:
  `cwMessageStatus` (the CW page's PLAY/RECORD are the app's recorder, not
  the rig's "RI" P3) and `txwEnabled`.
- **Inbound frames** are logged ("hub: client N sent (ignored, read-only
  hub)") and dropped.
- **Tests**: `Apps/Windows/FTX1RemoteWindows.Tests` (xUnit, net8.0,
  compiles `WireModels.cs`, `HubAddressFilter.cs` and the models they need
  as linked files; run with `dotnet test` from that folder, the .NET 10
  SDK by full path on the test PC). Every Swift fixture decodes and
  re-encodes to equal JSON (key order ignored, numbers by value); the C#
  property set equals `full`'s keys both ways; the address filter's
  allow/refuse lists; and `WritesWindowsFixture` writes
  `Tests/WireFixtures/windows/windows-state-push.json` from the real
  mapper (re-run it after any mapper change and commit the file).
  The Mac's `HubWireFixtureTests` decodes that file (passed 2026-10-15).
- **Tested here** (Remote mode, rig on the Pi): the push arrives on
  connect and after every poll at ws://localhost:8765 (~25 pushes in 20 s,
  live frequency/mode/meters/MENU/filter values), a client ping gets a
  pong, a non-"/" path gets 400, Settings → Hub shows listening and the
  client appearing and leaving, and turning the switch off/on through Save
  stops and restarts the listener. Then the user connected a real iPad's
  Desktop hub route to it, 2026-10-15, working. Not tested: a refusal from
  a real outside address (unit-tested only), Local mode.

### Phase 2 status (2026-10-15: built, tested on the PC, then from a real iPad by the user in Remote mode; Local mode not yet)

- **Parsing**: `Services/Hub/RigCommandWire.cs` turns a client's text
  frame into one C# record per Swift `RigCommand` case (71), or says it's
  `read_menu_item`/`cw_keyer` (logged and ignored until phases 4 and 6),
  an unknown command (logged and ignored, as an older Mac hub does) or
  invalid (wrong value shape, not JSON — logged, the connection stays up).
  Binary frames are still logged and ignored (TX audio is phase 5).
- **Running**: `Services/Hub/RigCommandDispatcher.cs` puts every client's
  commands through one FIFO (like the Mac's `RigWebSocketServer`) and runs
  each to completion on the UI thread before the next. Each goes through
  the code the window's own control uses, so the window shows what the
  iPad changed: MainWindow's methods behind the VFO entry, ⇄, TX:MAIN/SUB,
  V/M, mode and band pickers, power slider, PTT release, Enable Transmit
  switch, speaker override, memory list recall and Scan/Skip/Stop
  (reached through `IHubRigHost`, implemented in `MainWindow.Hub.cs`);
  `MenuGrid`'s and `FilterPanel`'s public setters, which their buttons
  and sliders now call too (pulled out of the click handlers); the Deep
  Settings dialog's `SetMenuItemAsync`. Where the window has no control,
  the Mac's `CommandQueue` mapping: `set_secondary_mode` (raw "MD1<code>",
  shown at once), C4FM on `set_mode` (raw "MD<active side>H"), `set_txw`
  ("TS"), CW MESSAGE select/record/play ("LM0n"/"LM1"/"KY1n"),
  `play_cw_text_memory` ("KY0n").
- **Before a command runs** (`Services/Hub/HubCommandPolicy.cs`, pure and
  unit-tested): `TransmitGate.BlockReason` for MOX on, ANT TUNE,
  `play_cw_text_memory` 1-5 and `play_cw_message` 1-5 (stops never gated);
  PTT on was refused until phase 5 (now gated like MOX, see "Phase 5
  status"), PTT off always goes through; values
  the rig shouldn't get (outside the MENU grid control's range, a delay
  that isn't one of the rig's, a ";" in a Deep Settings value, an unknown
  band) are refused. Then the Mac's `memoryScanStop(for:scanSide:)` rule,
  through MainWindow's own scan stop (restore the TX side, or keep it
  before anything that transmits). Refusals are logged as "hub: client N:
  <command> — refused: <reason>". With the rig not connected, commands
  are dropped (logged) except Enable Transmit and the speaker override.
- **Optimistic state**: as the Windows UI already does — MENU grid,
  filter, RF power, TX side, V/M, a list recall, the scan state, Enable
  Transmit, the speaker override — plus SUB's mode (the Mac does). The
  push timer sends it within 100 ms, which is how the iPad's controls
  update (it doesn't apply its own). MAIN/SUB frequency, MAIN's mode and
  channel set/step wait for the next poll (≤ the poll interval), as they
  do for the window's own controls.
- **Fix from the phase 1 review**: `HubServer` serializes every send-side
  call per client (`Client.SendLock`): the push loop, the receive loop's
  close-handshake reply (bounded at 5 s) and `StopAsync`'s close. Before,
  a close during a push threw `InvalidOperationException`.
- **Different from the Mac hub**:
  - `set_band`: the amateur bands only, at the band's default frequency;
    no band memory (last frequency/mode/width) and no general-coverage
    segments (refused as an unknown band). `set_freq` doesn't pick a mode
    when entering a general-coverage segment either.
  - `set_mode` goes through this app's "M currVFO <mode> 0", whose
    passband 0 lets hamlib reset the width on a mode change (the Mac sends
    -1, keeping the rig's own last width). Same as the window's mode picker.
  - The MENU grid's slow-tier read covers only the page shown in *this*
    window, so a front-panel change on another page reaches the iPad only
    once that page is shown here; the iPad's own changes show at once
    (optimistic).
  - `play_cw_message 0` (stop) isn't gated; the Mac gates every
    `play_cw_message`.
  - Stricter value checks than the Mac (above).
  - `refresh_memory_list` is logged and ignored until phase 4 (now handled, see "Phase 4 status").
- **Tests** (`FTX1RemoteWindows.Tests/HubCommandTests.cs`, with
  `RigCommandWire.cs`, `HubCommandPolicy.cs`, `TransmitGate.cs` and
  `RigDelayCode.cs` linked in): every entry of `rig-commands.json` parses
  to the expected record and re-serializes to equal JSON, and the
  fixture, the type table and the parser all have the same 71 names; bad
  frames (wrong types, missing fields, out-of-range sides, not JSON)
  classify as invalid without throwing; the gate, value and scan-stop
  decisions. 187 tests pass.
- **Tested here** (2026-10-15, a scripted WebSocket client on the PC):
  rig not connected — `set_transmit_enabled` off/on moving the switch,
  the push and the saved setting; PTT, MOX and ANT TUNE refused while
  locked; unknown, invalid and `read_menu_item` frames logged with the
  connection kept; the speaker override pushed both ways; a clean close.
  Remote mode against the rig — ATT on/off, filter side SUB/MAIN (with
  the re-read), MAIN and SUB mode re-set to their current values, each
  in the next push, no errors. Nothing was keyed.
- **Tested from a real iPad by the user, Remote mode (2026-10-15)**, each
  command confirmed in app.log: the lock button both ways (Enable
  Transmit, the switch and the saved setting following, PTT/MOX forced
  off on lock); PTT, MOX and ANT TUNE while locked (the iPad blocks them
  itself and sends nothing, so the hub's refusal is covered by the tests
  and the scripted check above); MAIN and SUB frequency and mode; the
  band picker (30 m and back); swap both ways (audio flag following) and
  the speaker button both ways; V/M in and out (VFO restored); MAIN
  channel set (a list tap sends `set_memory_channel` — the iPad never
  sends `recall_memory_channel`) and step, SUB channel step; Scan MAIN,
  pause, Skip (the same scan again), Stop; WIDTH, SHIFT, N/W, NOTCH
  (toggle and drag) and APF (toggle and drag) on MAIN, N/W on SUB, the
  MAIN/SUB switch; MENU grid RF POWER (PC slider following), TUNER, ATT,
  CW SPEED, TONE FREQ, RPT SHIFT. All working, nothing keyed.
  - Found on the way and fixed (1437f38): the iPad sends its JSON as
    **binary** frames, which the first build dropped as TX audio.
  - Deep Settings: the iPad can't show or change values until its reads
    work (phase 4), so writes from it are untested too (tested with
    phase 4).
  - Not tried: Local mode, a SUB channel picked from the list, CONTOUR
    (MAIN was in CW), the iPad's Scan SUB.

### Phase 3 status (2026-10-16: built, tested on the PC, then from a real iPad by the user in Remote mode; Local mode, CW decoding and a long run not yet)

- **Tap**: `Route` in `MainWindow.xaml.cs` (the audio source's callback,
  never the UI thread) calls `RelayHubAudio` (`MainWindow.Hub.cs`) with
  MAIN and SUB as roles, i.e. after `AudioChannelSwapTracker`, and before
  this app's own mute/volume/squelch (`ChannelPlayer.Push` only reads the
  samples), for both sources. SUB goes out only when the source really
  has a second channel (`IAudioSource.HasSubChannel`: always for the Pi,
  from the capture format in Local mode), so a mono input sends MAIN only,
  as on the Mac. Nothing is encoded while no client is connected
  (`HubServer.HasClients`).
- **Encoder**: `Services/Hub/HubAudioEncoder.cs`, one per channel,
  long-lived (rebuilt on an input-rate change): float → 8000 Hz mono
  Int16LE, one frame per incoming 2048-sample chunk (~46 ms at 44.1 kHz,
  ~43 ms at 48 kHz). NAudio's `WdlResampler` in windowed-sinc mode, 512
  taps: flat to 3.5 kHz (±0.05 dB) and ≥45 dB down at 4.4 kHz at both
  44.1 and 48 kHz input. Its default IIR mode (what
  `WdlResamplingSampleProvider` uses, and what the plan above suggested)
  measured −2 dB already at 2 kHz, too soft for the iPad's CW decoder and
  0–4 kHz spectrum. Filter latency ~45 output samples (~6 ms).
- **Sending**: binary frames, tag 0x00 MAIN / 0x01 SUB, broadcast to
  every client (`HubServer.BroadcastAudio`). Each client has its own audio
  queue beside the state outbox: 24 frames (~0.5 s of both channels),
  dropping the **oldest** when a slow client falls behind ("hub: client N
  is behind on audio — dropped …", at most every 5 s per client), sent
  through the same per-client `SendLock`.
- **Remote mode**: this app is the Pi's one audio client, so the iPad
  hears audio only while this app's Audio is on (unchanged); Settings →
  Hub says "Audio is off on this PC, so the iPad hears nothing" when it
  isn't running (as of opening the dialog).
- **Tests** (`FTX1RemoteWindows.Tests/HubAudioTests.cs`, encoder linked
  in, NAudio.Core 2.2.1 referenced): output rate, per-frame length, tone
  (1000 ± 1 Hz) and level (−6 dBFS in, peak within 3 %) from a sine at
  44100 and 48000 Hz in 2048-sample chunks; passband and alias rejection;
  a rate change; the tag. `WritesWindowsAudioFixture` writes
  `Tests/WireFixtures/windows/audio-main-1000hz-from44100.bin` (7954
  samples) and `audio-sub-1000hz-from48000.bin` (7957) through the real
  encoder — re-run and commit after any encoder change. 196 tests pass.
- **Tested here** (Remote mode, rig on the Pi): a scripted client over
  20 s got 431 MAIN and 430 SUB frames (21.5/s each, ~8000 samples/s each)
  alongside the state pushes. **CPU** (Debug build, 12-core PC, % of one
  core): 4.7–5.1 % with no client, 6.6 % with one local scripted client,
  6.6 % with the real iPad connected over Tailscale.
- **Tested from a real iPad by the user, Remote mode (2026-10-16)**: MAIN
  and SUB both heard; per-channel mute/VOL/SQL; audio following an app
  swap and the speaker swap button; the filter spectrum moving on MAIN and
  SUB. All working. **Not tried yet**: the iPad's CW pane decoding on this
  route, a ~10-minute run for growing delay, Local mode.
- **Different from the Mac**: frames are ~43–46 ms (the sources' 2048-
  sample chunks) — the Mac's are the same size; the plan's "~20 ms" was
  wrong. The audio queue's drop-oldest bound is new (the Mac's
  `broadcastAudio` hands every frame to `NWConnection.send` with no queue limit of its own).

### Phase 4 status (2026-10-16: built, tested on the PC, then from a real iPad by the user in Remote mode; Local mode not yet)

- **Wire**: `Services/Hub/HubListWire.cs` — `MemoryListPushWire`
  (`memory_list`: entries `channel`/`frequencyHz`/`modeCode`/`toneMode`/
  `shift`/`tag`, plus `scanned` = when the last full read finished and
  `scanningChannel` while a read runs), `AprsListPushWire` (`aprs_list`,
  the whole history, `source` "main"/"sub", the message `id` is
  `AprsMessage.Id`, stored with the message so it's the same in every
  push), `MenuItemReadRequestWire`/`MenuItemPushWire`, and
  `HubListWireMapper` from the stores' own models. Dates are 2001-seconds,
  nil fields left out, a blank tag sent as none.
- **Pushes**: `MainWindow.Hub.cs` marks a `HubPushThrottle` dirty on
  `MemoryListStore.EntriesChanged`/`StatusChanged` (so read progress goes
  out too) and `AprsStore.Changed`; the 100 ms hub timer sends each when
  due, the first change at once and later ones coalesced: memory at most
  once a second, APRS every 2 s, the Mac's rates. A push identical to the
  last one isn't re-sent. Both are sent when the hub starts and to each
  client on connect. `HubServer` gives each client a newest-wins slot per
  list beside the state slot, so one kind can't replace another, and an
  ordered reply queue (256, then dropped and logged) for menu answers.
- **`refresh_memory_list`** starts the Mem List window's Refresh
  (`MemoryListStore.Refresh`); while a read runs it's logged as "already
  reading the list" and not started twice, and disconnected it's dropped.
  The window, if open, shows the progress.
- **`read_menu_item`**: parsed by `RigCommandWire` (p1–p3 must be
  integers, else invalid and logged), answered by `HubServer` straight off
  the receive loop — not through the command FIFO — to the asking client
  only, with `RigctldClient.GetMenuItemAsync` (the Deep Settings dialog's
  read; the client's round-trip lock still orders the I/O). P outside
  0–99, no rig, a failed read or a reply without the prefix: answered
  with no `value` key. Successful reads aren't logged; failures are.
- APRS decoding stays as Settings → APRS sets it on this PC.
- **Tests** (`FTX1RemoteWindows.Tests/HubListTests.cs`; `HubServer.cs`,
  `HubListWire.cs`, `MemoryChannelEntry.cs`, `AprsModels.cs` linked in,
  ASP.NET Core referenced, `TestAppLog.cs` standing in for `AppLog` so
  tests don't write to app.log): the six Swift fixtures round-trip;
  malformed and out-of-range reads; the throttles; the real `HubServer` on
  loopback — a read answered to the asker only (a second client gets
  nothing), out-of-range and throwing reads unreadable, and list pushes
  surviving state pushes on connect and in a burst. Writes
  `Tests/WireFixtures/windows/memory-list-push.json`, `aprs-list-push.json`,
  `menu-item-push.json`, `menu-item-push.unreadable.json` from the real
  mappers (stores not used: they read and write the user's own files) —
  re-run and commit after any change to `HubListWire.cs`. 218 tests pass.
- **Tested here** (scripted client, rig not connected): memory and APRS
  lists and the state on connect, a read answered unreadable (incl. out of
  range), `refresh_memory_list` dropped while disconnected.
- **Tested from a real iPad by the user, Remote mode (2026-10-16)**: the
  memory list in the MAIN and SUB popovers; Refresh (app.log: "reading the
  list", then 278 channels in 65 s); SUB channel picks from the list
  (`set_sub_memory_channel`) tuning the rig; S.LIST/M.LIST filled with the
  right Source; Deep Settings values on the tabs and writes on four pages,
  incl. APRS AF MUTE (EX06 01 03) on then off read back on the iPad and in
  this app's dialog. All working. **Not tried**: Local mode, a MAIN
  channel picked from the list on this route (none in the log; MAIN
  channel set was tested in phase 2).
- **Different from the Mac**: memory/APRS pushes go out on the hub's
  100 ms tick rather than straight from the store, so a change can wait up
  to 100 ms longer; identical pushes are skipped; the menu reply queue is
  bounded.

### Phase 5 status (2026-10-16: built and tested on the PC against a fake Pi; 2026-10-17: transmit audio into a dummy load from a real iPad, Remote mode)

- **PTT from the hub**: `ptt true` goes through `HubCommandPolicy`'s
  transmit gate like MOX (this app's Enable Transmit, MAIN in an amateur
  band — the window's own PTT check), stops a running memory scan first
  (keeping the TX side), then keys with the window PTT button's
  `SetPttAsync(true)`. `ptt false` always goes through, from any client,
  as on the Mac.
- **PTT holder** (`HubServer`, the Mac's `pttHolder`): a client's
  `ptt true` makes it the holder (also when the gate then refuses it);
  only its own `ptt false` clears it; when it disconnects, `HubServer`
  raises `PttHolderDisconnected` and the rig is unkeyed. 0x02 frames from
  anyone else are dropped in the receive loop ("TX audio dropped (not the
  PTT holder)", at most every 5 s per client).
- **Order**: the holder's frames are raised from its receive loop
  (`TxAudioReceived`) into `RigCommandDispatcher`'s one FIFO beside the
  commands, so a `ptt true` has keyed the rig before that client's first
  frame is looked at.
- **TX audio state** (`Services/Hub/HubTransmitAudio.cs`, UI thread, time
  passed in): "keyed through the hub" is set when this app keys for a
  client, not by the poll; frames go on only from that client while it's
  set, else they're dropped (and an open sink closed). One sink per
  transmission, opened on its first frame, finished on any unkey.
  - **Remote**: `Services/RemoteTxAudioClient.cs`, a port of
    `RemoteTXAudioClient.swift`: raw PCM to `<Pi host>:8533`, one TCP
    connection per transmission, up to 0.5 s (8000 bytes, the newest)
    held while connecting, `Shutdown(Send)` on finish so the Pi plays out
    and its own 0.5 s grace applies; finished before connecting = dropped.
    Writes go out from a background task, never the UI thread.
  - **Local**: `Services/LocalTxAudioPlayer.cs` on Settings → Audio →
    **Transmit audio output** (`AppSettings.TxAudioOutputDeviceId`; "None"
    = nothing sent, never Windows' default): WASAPI shared, 8 kHz → the
    device's mix rate, no squelch or volume, starts after a 60 ms
    prebuffer, plays out (≤1 s) after the unkey. No device or unplugged:
    "hub: transmit audio dropped: no Transmit audio output device set
    (Settings → Audio)", once per transmission.
- **Watchdog** (checked on the hub's 100 ms timer, so up to 100 ms
  late): from the key, the first frame may take up to 5 s — the iPad
  keys first and starts its microphone after, ~0.3–1 s later — else
  unkey ("watchdog: no transmit audio within 5 s of the key —
  unkeying"); from the first frame on, no frame for 1.5 s → unkey
  ("watchdog: transmit audio stopped while keyed — unkeying").
- **Other unkeys** end the sink too: Enable Transmit off (the PC's switch
  or the iPad's lock), this window's PTT release, disconnecting from the
  rig, turning the hub off, closing the window.
- **Log** ("hub: …"): `key — client N (holder press) at <Hz>`; `unkey —
  client N, holder release` / `release from client N` / `holder
  disconnect` / `watchdog: …` / `(lock: Enable Transmit turned off)` /
  `(disconnecting from the rig)` / `(hub turned off)`; `transmit audio →
  Pi host:8533`; the sink's `tx-audio: connected …` / `finish — N bytes
  sent`.
- **Tests** (`FTX1RemoteWindows.Tests/HubTransmitTests.cs`;
  `HubTransmitAudio.cs` and `RemoteTxAudioClient.cs` linked in): frames
  while unkeyed or from another client dropped, one sink per
  transmission, one open attempt when there's no sink; the watchdog:
  no unkey 1.5 s after the key before a first frame (nor for a first
  frame at 4.9 s), unkey at 5 s with no frame, after a first frame unkey
  once 1.5 s after the last one, a new press waiting for its own first
  frame, steady frames never unkeying;
  through the real `HubServer` on loopback, the holder rules (another
  client's release passes but doesn't clear the holder, holder disconnect
  raised, a non-holder's isn't), non-holder frames dropped, `ptt
  true`/20 frames/`ptt false` arriving in order with frames after the
  release dropped; the Remote sink against a local listener (pending
  audio flushed on connect, only the newest 8000 bytes held, one
  connection per transmission, finish before connect = no connection).
  `PttOnIsGatedByEnableTransmitAndBand` replaces the phase 2 refusal
  test. 235 tests pass.
- **Tested here** (2026-10-16, the app pointed at a fake Pi on 127.0.0.1 —
  a scripted rigctld answering the poll with MAIN on 14.074 MHz and
  logging `T`, plus a :8533 sink counting bytes — and a scripted client
  sending 20 ms frames in real time; nothing reached the radio): a normal
  press (key 2 ms after `ptt true` arrived, one connection, 32000 bytes =
  2.00 s, closed on release, then the unkey); audio stopping with the
  socket open (watchdog unkey 1.505 s after the last frame); a second
  client's frames dropped while the first held; another client's release
  unkeying (the holder's later frames then dropped); the lock while keyed;
  the holder dropping its TCP connection (unkey within 1 ms); `ptt true`
  while locked (refused, frames dropped). Every press opened exactly one
  Pi connection.
- **With the iPad** (user, Remote mode): Enable Transmit off blocks PTT on
  the iPad (it sends nothing). The first real presses (2026-10-16) found
  two problems outside this app, both fixed since:
  - **The Pi reset :8533** ~80 ms after each connect: `ftx1_dmix`'s
    `ipc_key` in `Pi/asound-ftx1.conf` collided with the receive
    dsnoop's whenever an app held :8532 (this app always does in Remote
    mode), so every transmission failed with "unable to initialize sum
    ring buffer" and the Pi unkeyed. Fixed with `ipc_key 4600` (dc4ad4a),
    installed on the Pi.
  - **The iPad keyed late and sent no frames**: it started the
    microphone, freezing its main thread (3.9 s a press on an iPad Air),
    before the queued key went out. It now sends the key first (a76b7ea)
    and starts the microphone off the main thread with one shared
    `.playAndRecord` session (65c84c5); TestFlight 0.9 (8). The key now
    arrives ahead of the first frame, hence the watchdog's 5 s
    first-frame allowance (it counted 1.5 s from the key before).
- **Retested 2026-10-17** (user, iPad 0.9 (8), dummy load, USB with MOD
  SOURCE USB, this app holding the :8532 receive stream): two presses,
  each keyed 1 ms after `ptt true` arrived, the first frame ~0.17 s
  later, one connection to `ftx1pi:8533` with no reset, 11152 and 20676
  bytes (0.70 s and 1.29 s of speech) sent, finished on the holder
  release; unkeyed on release, locked afterwards. **Not done**: a long
  press, PO and the ~300 ms tail checked on the rig, Wi-Fi pull and
  backgrounding mid-press, Local mode.
- **Different from the Mac**: a client that keys and never sends audio is
  unkeyed 5 s after the key (the Mac arms its watchdog on the first
  frame only, so it never unkeys that case). A front-panel unkey mid-press doesn't
  end the sink (the Mac drops it on the next frame once a poll reads PTT
  off; the poll's occasional spurious 0 during TX would cut a
  transmission here). "No device" is logged once per transmission, not
  per frame. The Pi connection's writes run off the UI thread.

### Phase 6 status (2026-10-18: built, tested on the PC, then from a real iPad into a dummy load by the user, Remote mode)

- **`cw_keyer`** (`Services/Hub/HubKeyer.cs`, `HubServer.AnswerCwKeyerAsync`):
  parsed by `RigCommandWire` (`id`/`slot` integers, `text` a string or
  absent, `action` acquire/release or absent; anything else invalid and
  logged), answered off the receive loop and the command FIFO, like a
  menu read, to the asking client alone with its `id`.
  - **Write** (slot + text): `HubKeyerPolicy.RequestRefusal` first —
    slot 1–5, text non-empty, ≤50 characters, every one in
    `AllowedCharacters` (= Swift's `CWText.allowed` and `CwText.Allowed`,
    a test compares all three; lowercase is refused, as on the Mac — the
    iPad uppercases first). Refusals never reach the rig: "Keyer memory 9
    doesn't exist (1–5)", "The keyer can't send ";" (allowed: …)", "Too
    long for the keyer memory: 51 characters (50 at most)", "Nothing to
    write: the text is empty". Then `RigctldClient.WriteKeyerMemoryAsync`
    (this app's own `CwSender` write), reply `stored` = the rig's "KM"
    read-back, or `error` = the exception's message.
  - **Check** (no text): `CwSender.EnsureTextMemoryAsync` (EX 02 02 05+slot
    → 0 TEXT), plain reply or `error`.
  - **Acquire/release**: no keyer lease (user decision) — acquire always
    granted (no `busy`), release does nothing, both logged.
  - No rig connected: `error` "Not connected to the rig".
- **Keyer player** (`HubServer`, the Mac's `keyerPlayer`): the client whose
  `play_cw_text_memory` 1–5 came last; its own play 0 clears it. On its
  disconnect `KeyerPlayerDisconnected` → a confirmed stop through the
  command FIFO (behind its last command).
- **Confirmed stops** (`HubKeyerStop`, the straight key's lesson): every
  "KY00" the hub sends on its own — the player's disconnect, and, if any
  hub client played since the last stop (`HubKeyerTracker.PlayedSinceStop`),
  the lock (this PC's switch or the iPad's), hub off and disconnecting
  from the rig (before the client is disposed). "KY00", ~1 s, read PTT
  (`t currVFO`); still transmitting → "KY00" again, 5 tries in all ~1 s
  apart, then `T currVFO 0` and one last read. Logged as "hub: keyer stop
  (KY00) try N — <reason>", "hub: keyer stop confirmed (try N)", "hub:
  keyer still transmitting after N tries", "… sent PTT off", and a
  failure as "KEYER STILL TRANSMITTING …" / "COULDN'T CONFIRM …" (also
  on the status line). An unreadable state never counts as stopped. A
  client's own Stop (play 0) is forwarded as is, not confirmed.
- **Not over another transmitter**: a client's play 1–5 is refused
  (`HubKeyerPolicy.PlayRefusal`, logged "refused: …") while this window's
  PTT is held, MOX is on, a hub client is keyed with PTT, or the last poll
  read TX that isn't the hub's own keyer play (`HubKeyerTracker.Active`:
  from the play until PTT has read off for 1 s, after a 2 s start grace —
  rides out the rig's odd spurious 0). That covers a straight key through
  the Pi's ftx1-cwkey and this PC's own CW window while it's keying, but
  only as fresh as the poll.
- **Pushed state**: `ptt` is the poll's `t currVFO` (any nonzero = on, so
  keyer TX 3 counts). BK-IN/keyer speed/pitch are now read when a hub
  client connects and on every slow poll while one is connected (before,
  only while the CW page or this PC's CW window was open, so a fresh iPad
  could see `breakIn` missing and not block on it).
- **Tests** (`FTX1RemoteWindows.Tests/HubKeyerTests.cs`, `HubKeyer.cs`
  linked in): the eight Swift `cw-keyer-*` fixtures round-trip, the four
  requests parse; malformed requests invalid; the write checks (slot 0/6/9,
  empty, 51, ";", lowercase, newline, "<"); the allowed set against Swift
  and `CwSender.cs`; the play refusal and the tracker; the stop
  (confirmed at once, retried, five failures → PTT off, still transmitting,
  dead link → unconfirmed); through the real server: replies to the asker
  only with its id, acquire granted to two clients at once, no rig and a
  throwing write as `error`, the player's disconnect raised (not a
  non-player's, not after its own stop). `WritesWindowsKeyerReplyFixtures`
  writes `Tests/WireFixtures/windows/cw-keyer-reply.stored.json`,
  `.checked.json`, `.error.json` from the real server's replies — re-run
  and commit after any change to the reply code. 287 tests pass.
- **Tested here** (scripted client, rig connected through the Pi, Enable
  Transmit off, nothing played): TEXT check answered in 0.16 s; a write
  stored and read back in 2.2 s; slot 9 and ";" refused with their
  messages; acquire/release plain; pushes with `breakIn`, `cwSpeedWpm`,
  `mode` CW.
- **Tested from a real iPad by the user** (TestFlight 0.9 (8), dummy
  load, 20 m CW, BK-IN on): locked — the pane blocks, nothing keyed;
  unlocked — short lines keyed and the next waited; a 66-character line
  as two chunks (50 + 18) back to back; Stop mid-line; the lock mid-line
  (T 0/MX0, then KY00 confirmed on try 1, 1.8 s after the lock); BK-IN off
  — no write or play; iPad Wi-Fi off mid-line (see below). Locked
  afterwards.
- **Known gaps**:
  - **Wi-Fi loss is noticed late** (~20 s): a dropped Wi-Fi doesn't close
    the connection, and .NET answers the iPad's pings itself, so the hub
    only sees the client gone when TCP gives up. In the test the rig
    finished the (≤50-character) message on its own; KY00 then went out
    and was confirmed on try 1. A stalled-send check was considered and
    left out (user decision).
  - **Not coordinated with this PC's CW window**: no keyer lease, so both
    sending at once can overwrite the slot or restart each other's line
    (the play refusal above only catches it while the rig reads TX).
  - Not tried: Local mode, several iPads at once.
- **Different from the Mac**: no lease (`busy` never sent); the
  self-sent stops are confirmed and retried (the Mac sends one "KY00");
  the play refusal over another transmitter is new; refusal messages are
  per reason rather than the Mac's one "refused the text".

**Windows Firewall.** The app is unpackaged, so Windows asks "Allow
FTX1RemoteWindows to communicate on these networks?" the first time the
hub listens. Tick **Public** as well as Private: Tailscale's adapter is
usually classed as a Public network, and a LAN adapter may be too. If the
prompt was dismissed, or to add the rule by hand (admin PowerShell, with
the path of the exe you run):

```powershell
New-NetFirewallRule -DisplayName "FTX1Remote hub (TCP 8765)" -Direction Inbound -Protocol TCP -LocalPort 8765 -Action Allow -Profile Any -Program "C:\path\to\FTX1RemoteWindows.exe"
```

The app's own address filter still refuses anything outside loopback,
Tailscale and the private ranges, whatever the firewall allows.

### Where this app's gap is

All the rig logic lives in `MainWindow`'s code-behind and in `MenuGrid`'s
click handlers, and they call `RigctldClient` directly. There is no
`RigCommand`, no command queue and no single "apply a command" path, unlike
the Mac's `HubService.send(_:)` + `CommandQueue`. The C# `RigState`
already has almost every field the wire needs (MENU grid, filters, V/M,
scan, C4FM, meters), so the mapping is mostly renaming. Most of the work is
the command path.

### Phases (each one built, tested against the iPad and committed on its own)

1. **Server + state push (read-only iPad).** `Services/Hub/HubServer.cs`
   on ASP.NET Core Kestrel (`<FrameworkReference
   Include="Microsoft.AspNetCore.App" />`, `app.UseWebSockets()`), on
   `0.0.0.0:8765`. Kestrel is recommended over `HttpListener`, which needs
   a `netsh http add urlacl` (admin) to bind anything but localhost, and
   over a hand-rolled server. `Services/Hub/WireModels.cs` holds
   `System.Text.Json` DTOs that copy `RigState`/`RigStatePush` field for
   field, plus a `RigStateWire.From(RigState, …)` mapper. Push the state
   after each `PollOnceAsync` and after each applied command (coalesced, at
   most ~10/s). Add **Settings → Hub**: "Allow iPad connections" (off by
   default), the port (8765), the listening state and the connected
   clients. **Who may connect** (user decision): Tailscale and the local
   network only. Kestrel binds every interface, and the server refuses any
   connection whose remote address is outside loopback, Tailscale
   (100.64.0.0/10, fd7a:115c:a1e0::/48) or the private ranges (10/8,
   172.16/12, 192.168/16, 169.254/16, fc00::/7, fe80::/10), before the
   WebSocket upgrade. Log every refusal. Windows Firewall asks the first time the app listens, and
   Tailscale's adapter is often a *Public* network, so the README needs a
   firewall note. Test: the iPad's Desktop hub shows the Windows app's
   VFOs, meters and MENU values, and controls do nothing yet.
   Tests both ways, through `Tests/WireFixtures/` (its README lists the
   shapes that are easy to get wrong): a C# test that decodes the Swift-
   made `rig-state-push.*.json` and re-encodes them to the same JSON
   (ignoring key order), and C#-made pushes committed to
   `Tests/WireFixtures/windows/`, which `HubWireFixtureTests` on the Mac
   decodes the way the iPad does — so a missing required field fails a
   test instead of leaving the iPad on "Connecting…".
2. **Command path.** `Services/Hub/RigCommandDispatcher.cs`: parse
   `RigCommand` JSON and run each command through the *same* methods the
   Windows UI uses (`SetMainFrequencyAsync`, swap, V/M, memory channel,
   mode/band, filter, MENU grid setters). Pull those methods out of the
   click handlers where needed, so the UI and the hub share one
   implementation. Gates: `TransmitGate.BlockReason` for anything that
   transmits (PTT, MOX, ANT TUNE, `playCWTextMemory`), and the memory-scan
   stop-before rules from `MainWindow.MemoryScan.cs`. Unknown commands are
   logged and ignored, which is how an older Mac hub behaves.
   `setTransmitEnabled` sets this app's Enable Transmit switch (unkey + CW
   stop when turned off), and `setAudioChannelsSwapped` sets
   `AudioChannelSwapTracker`. Apply optimistically, then push. Test every
   iPad control on both of this app's modes.
3. **Receive audio relay** (done, see "Phase 3 status"). Tap the samples `ChannelPlayer` already gets
   from `RemoteAudioStreamClient`/`LocalAudioCapture`, after the swap
   tracker, so MAIN/SUB are roles. Downsample to 8 kHz Int16 (NAudio's
   `WdlResamplingSampleProvider`, one per channel, long-lived) and
   broadcast 0x00/0x01 frames, ~20 ms chunks like the Mac. Mute and
   squelch stay on the iPad. Same rule as the Mac: one Pi audio client, so
   in Remote mode this app has to hold the stream (the iPad gets it
   through here, not from the Pi). Test: both channels heard, across a
   swap, with the filter spectrum on the iPad.
4. **Lists and Deep Settings** (done, see "Phase 4 status"). `memory_list` from `MemoryListStore`
   (`refreshMemoryList` triggers a re-read). `aprs_list` from `AprsStore`
   (same JSON as Swift's `APRSStation`/`APRSMessage`, incl. `source`).
   `read_menu_item` → `RigctldClient` raw "EX" read, answered off the
   ordered stream.
5. **Transmit audio.** PTT holder tracking, so 0x02 frames are accepted
   only from the client that keyed. Remote mode forwards them to the Pi's
   `ftx1-txaudio.py` (:8533, a C# port of `RemoteTXAudioClient`, one
   connection per transmission). Local mode plays them to a Settings →
   Audio "Transmit audio output" device (empty = none, never the default
   device). Add the 1.5 s silence watchdog and unkey when the holder
   disconnects. Dummy load first.
6. **CW keyer** (done, see "Phase 6 status"). `cw_keyer` write/check (≤50 chars,
   `CWText.allowed`, slot 1–5, refused before reaching the rig) through
   `RigctldClient.WriteKeyerMemoryAsync`; "KY00" if the last player
   drops. **No keyer lease in v1** (user decision): `acquire` is always
   granted and `release` is a no-op, as on Pi direct, so this app's own CW
   window and an iPad sending at the same time aren't coordinated (one can
   overwrite the slot or restart the other's line). The Mac's lease
   (`.windows`/`.client(id)`, 30 s timeout, shared with `CwSender`) is the
   follow-up if that ever matters.

### iPad-side follow-ups (small, no wire change)

- Done 2026-10-15: segment label "Desktop hub", hostname field "Desktop
  hostname (Tailscale)", Pi-direct footer "no desktop hub".
- Still say "Mac" and become wrong once phase 1 lands: the lock button's
  accessibility text and `transmitBlockReason` ("Transmit disabled on the
  Mac"), `RigClientViewModel+CWKeyerLink` ("locked on the Mac"),
  `CWKeyerRequestError` ("Not connected to the Mac", "update the Mac
  app"), `APRSListPane` ("Decoded by the Mac"), and the keyer-busy text
  "the Mac's CW window". Either reword them to "the desktop app", or add
  an optional `hubName` to `RigState` ("Mac"/"Windows PC", absent from an
  older hub = "desktop app") and build the text from it. The second option
  is recommended: it's one optional field and reads better.
- The iPhone's route switch still says "Mac hub". It's out of scope here,
  but it's the same rename if wanted.

### Decisions (user, 2026-10-15)

- **Hub off by default**, behind Settings → Hub's "Allow iPad
  connections" toggle (anyone who can reach the port can key the rig).
- **Tailscale and local network only** — see phase 1 for the address
  ranges. Public addresses are refused.
- **No shared CW keying in v1** — see phase 6.

## Localization (Spanish and German, 2026-10-27)

The Mac/iPad's es/de port (see CLAUDE.md's "Localization"). The app follows
Windows' display language (`CurrentUICulture`); no in-app picker. Key
checks run by script; not yet built or run in Spanish/German on the PC.

- **Strings**: `Localization/Strings.resx` (English), `Strings.es.resx`,
  `Strings.de.resx` — the same keys in each, sorted case-insensitively.
  Keys are namespaced like the Mac's (`mainWindow.connectFailedX`,
  `common.cancel`), wording reused from the Mac/iPad catalogs. Code uses
  `Loc.S(key)`, `Loc.F(key, args…)` (arguments as `{0}`, `{1}`… so a
  translation can move them — never concatenate a sentence) and
  `Loc.P(key, count)` (`<key>.one`/`<key>.other`); XAML uses
  `{l:Str Key=…}` (`xmlns:l="using:FTX1RemoteWindows.Localization"`). A
  missing key shows as the key. **A new string needs all three files.**
  Keep the key a literal in the call (`Loc.S("x.y")`, not built with `+`),
  or `LocalizationTests` can't check it.
- **Stays English**: radio terms and rig labels (modes, MAIN/SUB, PTT,
  the MENU grid, `DeepSettingsCatalog`), unit-only formats, wire values
  and everything on the hub's wire, log text, saved IDs (theme names are
  stored in English, `ThemePresets.DisplayName` is the label), HRD/Log4OM/
  Wavelog program names.
- **Numbers**: `Loc.ApplyNumberFormat()` (App startup) keeps the regional
  format but with "." as the decimal separator, so es/de don't show
  "14,074"; `Loc.OsCulture` is Windows' own, for parsing what the user typed.
- **Satellite assemblies**: the build puts `es\` and `de\`
  (`FTX1RemoteWindows.resources.dll`) next to the exe — the release zip
  must keep those folders.
- **Checking**: `LocalizationTests` (same keys/placeholders in the three
  files, every `Loc.*`/`l:Str` key exists, every formatted string
  formats). Debug builds: set `FTX1REMOTE_UI_LANGUAGE=es` (or `de`, `en`)
  before launching to see a language whatever Windows uses (WinUI's own
  control strings still follow Windows).

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
  methods directly instead. (Superseded in part by "Desktop hub for the
  iPad": the hub speaks it as a server; `RigCommand` arrives in phase 2.)
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
Apps/Windows/FTX1RemoteWindows.Tests/
  HubWireTests.cs              hub wire fixtures + address filter (xUnit; links the app's wire files)
Apps/Windows/FTX1RemoteWindows/
  FTX1RemoteWindows.csproj   unpackaged WinUI 3, net8.0-windows10.0.19041.0
  app.manifest               DPI-awareness manifest (unpackaged apps need this)
  App.xaml(.cs)               standard WinUI 3 application entry point
  MainWindow.xaml(.cs)        v1 core-rig-control UI + poll loop + audio controls
  MainWindow.MemoryScan.cs    the rig's memory scan, MAIN/SUB (HubService.swift's scan parts)
  MainWindow.Hub.cs           starts/stops the hub, pushes state (coalesced, ≤10/s), hub PTT and CW keyer
  Services/Hub/               the hub: HubServer, RigCommandWire/Dispatcher, HubCommandPolicy, wire models,
                              audio encoder, TX audio, HubKeyer (cw_keyer checks, confirmed keyer stop)
  SettingsDialog.xaml(.cs)    Settings window (the Mac's SettingsView tabs)
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
    CwLogPane.cs                 CW window's Log QSO pane + worked-before colors (CWLogPane.swift)
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
    MemoryScan.cs               MemoryScanState + the "RI0" parse — RigState/MemoryScan.swift
    LoggedQso.cs                LoggedQso + AdifMode + AdifRecord — Logbook/LoggedQSO, ADIFMode, ADIFRecord.swift
    WorkedStations.cs           worked-before index by base call — Logbook/WorkedStations.swift
    SdrStations.cs              KiwiSdrStation, WebSdrFavorite, Maidenhead — KiwiSDRStation/WebSDRFavorite.swift
  Services/
    RigctldClient.cs             TCP client for rigctld's text protocol
    RigctldProcessController.cs  Local mode: spawns/adopts rigctld.exe (port of the Mac's)
    RigctldBinary.cs             which rigctld.exe to spawn: Automatic/Built-in/path — RigctldBinary.swift
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
    CwMonitor.cs                 CW send pane's local sidetone (CWMonitor.swift)
    HrdLogbook.cs                HRD Logbook: its settings, ADIF receiver, SQLite log reads (MacLoggerDX.swift's counterpart)
    QsoLogger.cs                 Sends a QSO to HRD as ADIF over UDP, confirms it in the log (QSOLogger.swift)
    WorkedStationsStore.cs       Worked-before index for the CW window (WorkedStationsStore.swift)
    WebSdrAudioTap.cs            process-loopback capture of the WebSDR window's audio for the CW window (WebSDRAudioTap.swift)
    Hub/HubServer.cs             the iPad's Desktop hub: Kestrel WebSocket server on 8765 (RigWebSocketServer.swift)
    Hub/HubAddressFilter.cs      who may connect: loopback, Tailscale, private ranges
    Hub/WireModels.cs            RigStatePush/RigState wire types + the RigState mapper (WireMessage.swift, RigState.swift)
  Assets/
    CWNet.onnx                    CWKit's neural CW model, converted by ../Tools/cwnet_to_onnx.py
  Settings/
    AppSettings.cs                every setting (connection, audio, WPSD, APRS, station, WebSDR, CW, HOME, polling, appearance); file-based (see its doc comment on why not LocalSettings yet)
    Appearance.cs                 AppTheme / ButtonValueColor (ports of the FTX1Core Appearance enums)
    ThemeEngine.cs                a theme → WinUI resource overrides, applied app-wide (see "Themes")
```

## Updates (Settings → About, 2026-10-03)

Notify-only: `Services/UpdateChecker.cs` reads the repo's GitHub Releases and
looks for the newest non-draft, non-prerelease one tagged `v<version>` or
`windows-v<version>` **that has a `FTX1Remote-Windows-*-x64.zip` attached**.
Since 0.9 one release (`v0.9`) carries both apps; 0.8 was a separate
Windows-only `windows-v0.8`, and older Mac-only `v0.x` releases have no
Windows zip, so they're skipped. Requiring the zip also covers the gap
between the Mac half going up and the Windows zip being uploaded. Windows
0.8 itself only looks for `windows-v` tags, so 0.9 also has a one-time
bridge release, `windows-v0.9` (same zip, Windows-only notes, not marked
Latest, same commit as `v0.9`), which 0.8 finds and links to. 0.9 and later
see it as 0.9 and ignore it. Don't make `windows-v` releases for later
versions: from 0.9 on, the combined `v<version>` release is enough. A newer release than the
`.csproj`'s `<Version>` (kept equal to the Mac's) shows its notes and a
Download button that opens the release page. Only the notes' `## ` sections
whose heading names Windows are shown ("## Mac and Windows", "## Windows"),
or all of them if none does. "Check for updates when the app
starts" (default on) does the same silently at launch, with a dialog only if
there's an update. Build-verified only; the first real Windows release
(`windows-v0.8`) exists now, but nothing older has checked against it yet.

## Releasing

The release is a zip of the `dotnet publish` folder: unpackaged and
self-contained (.NET + Windows App SDK included), so no installer and nothing
else to install. Users unzip it anywhere and run `FTX1RemoteWindows.exe`.
It isn't code-signed, so SmartScreen warns on first run ("More info → Run
anyway"). Local mode no longer needs Hamlib installed: the publish folder
has Hamlib's `rigctld.exe`, its DLLs and licence files in `hamlib\` (see
"Bundled rigctld"). Before zipping, check `hamlib\rigctld.exe --version`
in the publish folder, and that the release has `hamlib-<version>.tar.gz`
for the same Hamlib version.

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

4. Upload the zip to the combined `v<version>` release, which the Mac half
   creates first (the `gh release create` step `Scripts/release-mac.sh`
   prints). GitHub CLI is at `C:\Program Files\GitHub CLI\gh.exe` on the
   user's PC:

   ```powershell
   gh release upload v<version> C:\Tools\FTX1Remote-Windows-<version>-x64.zip --repo captobie/ftx1-remote
   ```

   libusb's source tarball (LGPL source offer for the bundled
   `libusb-1.0.dll`, see "Bundled rigctld") is attached by the Mac half's
   `gh release create` line, from the Mac's `releases/`; check it's on the
   release. Only if it isn't, upload this PC's copy from the repo root:

   ```powershell
   gh release upload v<version> releases\libusb-1.0.24.tar.bz2 --repo captobie/ftx1-remote
   ```

   The release notes are shared (`releases/notes-<version>.md` on the Mac,
   not in git): a "## Mac and Windows" section, then "## Mac" and
   "## Windows". Keep the Windows install/SmartScreen/rigctld lines in the
   Windows section; the update dialog shows only the sections whose heading
   names Windows.
