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

**Toolchain note for whoever picks this up next:** the .NET SDK (10.0.400)
is installed on this machine at `C:\Program Files\dotnet` but isn't on
`PATH` in either PowerShell or Git Bash — invoke it by full path, add it to
`PATH`, or just open the project in Visual Studio, which finds it
regardless.

## What this is

A Windows app with the same *kind* of functionality as the Mac app
(`Apps/Mac/FTX1RemoteMac/`), but remote-only: it talks to the Raspberry Pi
directly (rigctld for control, `ftx1-audiostream.py` for audio — see repo
root `CLAUDE.md`'s "Remote rigctld (Option A)" section), never to a
locally-attached radio, and never through the Mac.

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

So architecturally this app is closest to the Mac running permanently in
`.remote` mode, minus the two things that mode doesn't need:

- No `RigctldProcessController` equivalent — the Pi's `rigctld.service` is
  always-on; this app never spawns, adopts, or kills anything.
- No WebSocket *server* — this app is a leaf client, nothing connects
  downstream of it. (The Mac, Windows, and iOS/iPad apps end up as three
  independent consumers of the Pi; the Mac is no longer in the loop for
  Windows sessions at all.)

```
Windows app  ──TCP:4532 (rigctld text protocol)──►  Pi (rigctld.service)
             ──TCP:8532 (raw PCM, phase 2+)──────►  Pi (ftx1-audiostream.py)
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

One field: Pi hostname (Tailscale MagicDNS, e.g. `ftx1-pi`) — port fixed at
4532, not user-configurable, matching `RigctldSettings.remoteHost`
(`Apps/Mac/FTX1RemoteMac/RigctldSettings.swift`). No local/remote mode
picker — this app is remote-only by definition, so there's nothing to pick.
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

## v1 scope

Core rig control only:

- VFO A/B display (frequency, active/inactive indicator, swap)
- Mode selector
- PTT indicator/control
- Power level control + metered SWR
- Band selection
- Connect/disconnect + live connection-state indicator (with the
  unreachable-vs-down distinction above)

## Explicitly deferred (not v1, but not architecturally foreclosed either)

- **MENU grid** (`UI/MenuPageView.swift` port) and **Deep Settings**
  (`MenuSettings/DeepSettingsCatalog.swift` port) — Deep Settings is
  actually *feasible* here, unlike on iPad, because this app has the same
  direct per-item-read capability the Mac's `HubService.readMenuItem` has
  (see "Why direct-to-Pi" above). Not a blocked feature, just not v1.
- **Waterfall/oscilloscope + audio playback** — would reuse the
  direct-to-Pi pattern of `Apps/Mac/FTX1RemoteMac/RemoteAudioStreamClient.swift`:
  a second, independent TCP connection to the Pi's :8532
  (`ftx1-audiostream.py`), decoded the same way (paired Int16 LE samples →
  Float32 at 44100Hz) into an FFT feeding a WinUI 3 `CanvasControl`/Win2D
  waterfall. Its own reconnect loop, independent of the rigctld link's —
  same reasoning as the Mac's version (two separate TCP connections to two
  separate Pi-side services, one can drop while the other stays up).
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
  MainWindow.xaml(.cs)        v1 core-rig-control UI + 1s poll loop
  Models/
    RigMode.cs                 hamlib mode vocabulary — Sources/FTX1Core/RigState/RigState.swift's RigMode
    BandPlan.cs                 band table — Sources/FTX1Core/RigState/BandPlan.swift
    RigState.cs                 v1 subset of RigState.swift's fields
  Services/
    RigctldClient.cs             TCP client for rigctld's text protocol
  Settings/
    AppSettings.cs                Pi hostname, file-based (see its doc comment on why not LocalSettings yet)
```
