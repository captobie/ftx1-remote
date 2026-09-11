# Known Issues

A running list of known bugs, rig limitations, and open gaps across the Mac,
iOS, iPad, and Windows apps, pulled together from `CLAUDE.md`, the `README.md`
files, and in-code comments/TODOs. There's no GitHub issue tracker in use for
this repo — this file is the tracker. Update it as items are fixed or new ones
are found; don't let it drift from `CLAUDE.md`'s own "still open" notes.

## Confirmed bugs / unreliable behavior (hardware-tested, not fixed)

1. **CW MESSAGE/PLAY/RECORD buttons** (CW page items 19–21) — wired to real
   CAT commands and `CommandQueue`, but behaved unreliably against the real
   rig. Deprioritized and left visible-but-disabled rather than debugged
   further; the commands and `RigState.cwMessageStatus` plumbing are kept in
   place to reconnect later.
   (`Sources/FTX1Core/UI/MenuPageView.swift`, `disabledCWMessageButton`)
2. **`stepMemoryChannel` (CH0/CH1) targets an unverified VFO side** — unlike
   every other raw menu command, the "CH" (CHANNEL UP/DOWN) CAT command
   documents no MAIN/SUB P1 selector, so which side it actually steps on
   real hardware hasn't been confirmed. If hardware testing shows it hits
   the wrong side, replace it with a read-modify-write via "MC0" instead.
   (`Sources/FTX1Core/Commands/CommandQueue.swift`, `.stepMemoryChannel`)
3. **Command failures are dropped silently** — `CommandQueue.drain()`
   swallows any error thrown by `apply(command)` with no callback to the
   app layer. Open `TODO` to surface failures via a dedicated error
   callback instead of dropping them.
   (`Sources/FTX1Core/Commands/CommandQueue.swift`, `drain()`)
4. **PTT port's `-P RIG` keying-type assumption** hasn't been stress-tested
   against a real separate PTT interface — only validated with the setup
   on hand.

## Rig limitations (no CAT command exists — not fixable in-app)

Confirmed via a full CAT Operation Reference Manual search plus the hamlib
source, not just "not yet wired." Rendered permanently visible-but-disabled
in `MenuPageView`:

- SSB **D-COLOR**
- FM/C4FM **DG-ID TX**, **DG-ID RX**, **HRI MODE**
- FM **T-CALL**, **REV** (repeater reverse), **BCN-TX** (momentary "send
  beacon now" — no Table 3 entry either, since momentary actions never
  appear there)
- FM **DTMF** (opens an on-rig entry screen this app can't drive over CAT,
  and would be TX-triggering to guess at)

## Open UI / architecture gaps

1. **"Pi unreachable" vs. "rigctld/radio down but the Pi is fine"** — not
   yet distinguished in `.remote` mode's connection-state UI, for either
   the rig-control link or the audio link; both currently surface as one
   generic failed state. `RigctldError`/the connect catch site don't carry
   enough information yet to tell TCP-level unreachability apart from a
   bad or absent CAT reply.
2. **No request/response mechanism in the wire protocol** — only
   fire-and-forget `RigCommand` and one-way `RigStatePush` exist today, so
   a remote client has no way to fetch a Deep Settings item's current
   value. Blocks bringing `DeepSettingsView` to iOS/iPad; iPad's Deep
   Settings buttons currently show a disabled "SOON" placeholder.
3. **iOS has no numbered MENU grid UI yet** (iPad does).
4. **No full state diffing / reconnect-and-resync logic** for
   `RigWebSocketClient`.
5. **MENU grid is still growing** — SSB page 1 items 2–27 are wired (or
   deliberately disabled placeholders), the rest of the grid's buttons are
   still unwired numbered placeholders, wired one at a time as needed.
6. **Waterfall/oscilloscope display is Mac-only** — not exposed to mobile
   clients and not part of the wire protocol.
7. **WSJT-X's "Hamlib NET rigctl" setup must be repointed by hand**
   whenever `.local`/`.remote` mode changes (localhost vs. the Pi) — this
   app doesn't manage that.
8. **Deep Settings gaps**: RADIO SETTING's WIRES-X tab (no CAT manual
   source yet — postdates the manual's firmware revision), KEY/DIAL's MIC
   UP/MIC DOWN (unknown shape, deliberately deferred), and the manual's
   P1=09 PRESET category (5 full radio-setting presets — no page-3 button
   maps to it, out of scope until decided).

## Windows app (v1 skeleton, not yet hardware-tested)

- Build-verified only (`dotnet build -r win-x64 --self-contained`) —
  **never run against real hardware yet**.
- MENU grid, Deep Settings, waterfall/audio, and APRS decode are all
  deferred — not architecturally blocked (direct-to-Pi gives this app the
  same live per-item-read capability the Mac has, unlike iPad), just not
  in v1 scope.
- **C4FM mode is not wired up** in v1's `RigMode`/
  `RigctldClient.SetModeAsync` — needs the same raw-CAT-passthrough special
  case the Mac's `setActiveModeC4FM()` uses.
- **No per-band "last used frequency" memory** yet — band selection always
  jumps to the band's default calling frequency; there's no C# equivalent
  of the Mac's `BandMemory`.
- App icon / MSIX packaging identity (publisher, package name) undecided —
  the project deliberately builds unpackaged for now.
- Whether v1's raw commands (mode, band, PTT, power) need independent
  hardware verification against the CAT manual, the way `MenuPageView`/
  `DeepSettingsCatalog` needed on the Mac, is still an open question.

## Outstanding validation (Remote rigctld / Pi work)

- WSJT-X coexistence testing not done.
- Soak testing not done.
- Timeout re-tuning under sustained real Tailscale network conditions not
  done.
- `RigctldClient.sendRawCommand`'s 1s raw-command timeout is flagged for
  re-validation over a real Tailscale hop, not yet confirmed adequate.

## Resolved (kept here for context, not currently open)

- `HubService.refreshState()`'s `getFrequency()` read wasn't wrapped in
  `try?` like every other poll-cycle field, so an occasional bad CAT reply
  tore down and reconnected the whole session instead of falling back to
  the last known value. Fixed.
- Pi's `rigctld.service` was missing `-o`, causing wrong secondary-VFO
  reads. Pi-config fix, not an app bug.
- A stale hamlib 4.6 pulled in as a Direwolf dependency on the Pi was
  shadowing the working 4.7 install, causing a full day of "no CAT
  response at all." Pi-config fix, not an app bug.
- Audio-over-Pi device sharing with Direwolf hit two conflicts, both
  fixed: `Device or resource busy` (fixed via `Pi/asound-ftx1.conf`'s
  `dsnoop`+`plug` chain) and `Permission denied [ftx1_shared]` (fixed via
  `ipc_perm 0666` in the dsnoop config, plus a Pi reboot to clear stale IPC
  objects). See `Pi/README.md` for detail.
- APRS decode was unreliable at 8kHz capture rate (too little timing
  resolution for AFSK demodulation); raised to 44100Hz and confirmed
  working against real traffic.
