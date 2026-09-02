# FTX1Core

Shared Swift package for the FTX-1 remote control app (Mac hub + iOS/iPadOS clients).

## Architecture

- **Mac app is the hub.** It owns the `RigctldClient` connection to rigctld
  (hamlib) on `localhost:4532`, holds live rig state, and runs
  `RigWebSocketServer` (Mac-only, in the app target — via `Network.framework`
  `NWListener`/`NWProtocolWebSocket`, since `URLSessionWebSocketTask` is
  client-only) that broadcasts state and accepts commands.
- **Mobile apps never talk to rigctld directly.** iOS/iPadOS use
  `RigWebSocketClient` (via the shared `RigClientViewModel`) to connect to
  `<mac-tailscale-hostname>:PORT`. The iPhone app (`Apps/iOS/FTX1RemoteiOS`)
  is a focused single-rig-control view — no attempt to mirror the Mac's
  dense layout. The iPad app (`Apps/iPad/FTX1RemoteiPad`) is a separate
  Xcode target (resolved decision, not a shared iOS target with size
  classes) that *does* mirror the Mac's dense layout — VFO A/B side by
  side, SWR/PTT/power/band/mode, plus the numbered MENU grid, all shared
  with the Mac via a `RigController` protocol rather than duplicated (see
  Module layout below). The Deep Settings screens are still Mac-only on
  every mobile target, iPad included — see below for why.
- **The Mac's own local UI calls `HubService` directly**, not through
  `RigWebSocketClient` round-tripping to itself — see the repo root
  `CLAUDE.md` for why this diverged from the original plan. The WebSocket
  path is exercised by remote (iOS/iPad) clients only today.
- **State sync is push-based.** The Mac broadcasts a `RigStatePush` whenever
  rigctld reports a change; clients don't poll. This only covers live
  telemetry (VFO, mode, power, SWR, PTT) and the numbered MENU grid's
  fields — Deep Settings values are fetched on-demand instead (see below),
  not part of this broadcast.
- **Commands are serialized** through `CommandQueue` on the Mac side, since
  rigctld handles one request/response cycle at a time.
- **The Mac also launches rigctld itself** (`RigctldProcessController`)
  rather than requiring it pre-started — adopting an already-running,
  responsive instance instead of killing it on launch, since another client
  (e.g. WSJT-X) may be mid-session with it.
- **The waterfall/oscilloscope display is audio-derived, not CAT-derived**
  (`AudioCaptureEngine`, Mac-only): it captures from a user-selected sound
  card input device and runs an FFT, entirely separate from the rig-control
  data path above — no rigctld or wire-protocol involvement, and not
  broadcast to mobile clients.
- **Two menu systems, both driven by raw CAT passthrough** (most FTX-1 menu
  items have no hamlib func/level equivalent, per the CAT Operation
  Reference Manual):
  - The numbered **MENU grid** (`MenuPageView`, `Sources/FTX1Core/UI/` —
    shared by Mac and iPad) — one `RigCommand` case, `RigState` field, and
    hand-written button per item, wired individually as needed. Generic
    over a `RigController` protocol (`rigState`/`send`/...) so it can be
    driven by either `HubService` (Mac) or `RigClientViewModel` (mobile)
    without duplicating the file per target.
  - The page-3 **Deep Settings** screens (`DeepSettingsView`, Mac app
    target only) — Radio/CW/Operation/Display/Extension/APRS Setting, a
    different, much larger part of the rig's menu system (addressed via
    the single "EX" CAT command's P1/P2/P3 category/tab/item scheme, per
    the manual's "Table 3"). Driven generically by `DeepSettingsCatalog`
    (`Sources/FTX1Core/MenuSettings/`) plus one generic `RigCommand` case
    (`.setMenuItem`) and one generic `RigctldClient` method pair
    (`getMenuItem`/`setMenuItem`) — adding an item is a catalog entry, not
    a new case/field/branch. All six categories are populated (~254 items
    total) as of the commit history in `DeepSettingsCatalog.swift`.
    **Not available on mobile** (iOS or iPad): it needs
    `HubService.readMenuItem`, a live per-item read only the Mac's direct
    rigctld link can do, and the WebSocket wire protocol has no
    request/response mechanism today — only fire-and-forget `RigCommand`
    and one-way `RigStatePush`. On iPad, `MenuPageView`'s FM page shows a
    disabled "SOON" placeholder for these 6 buttons instead of opening a
    broken screen (`RigController.supportsDeepSettings`).

## Module layout

```
Sources/FTX1Core/
├── RigState/       RigState, RigMode, BandPlan — shared state model + band table
├── Appearance/      AppTheme, ButtonValueColor, AppearanceSettings — shared
│                    app-appearance settings (theme, MENU grid button color)
├── Networking/      WireMessage (JSON protocol: RigCommand/RigStatePush),
│                    RigctldClient (Mac-only, TCP to rigctld, incl. raw CAT
│                    passthrough), RigWebSocketClient (WS client, used by
│                    mobile — see Architecture above re: the Mac's own UI),
│                    RigClientViewModel (ObservableObject wrapping
│                    RigWebSocketClient, shared by iOS + iPad)
├── Commands/        CommandQueue — serializes RigCommands into rigctld calls
├── MenuSettings/    DeepSettingsCatalog — static, table-driven catalog
│                    behind the Deep Settings screens (see Architecture)
└── UI/              RigController (protocol HubService/RigClientViewModel
                     both conform to), MenuPageView (numbered MENU grid,
                     generic over RigController, shared by Mac + iPad),
                     VFODisplayBox (dense VFO A/B readout, shared by Mac +
                     iPad), SMeterView (analog S/SWR meter face, shared by
                     Mac + iPad)
```

Mac-only, not part of the shared package: `AudioCaptureEngine` (captures a
selected sound card input, runs an FFT) and `ScopeDisplayView` (renders the
resulting waterfall/oscilloscope frames) — see Architecture above. Neither
is wired into the wire protocol or `RigController`, so they aren't shared
with mobile targets the way the rest of this layout is.

## Not yet built / open

- Full state diffing / reconnect-and-resync logic for `RigWebSocketClient`.
- A wire-protocol request/response mechanism for Deep Settings reads on
  mobile (see Architecture above) — blocks bringing `DeepSettingsView` to
  iOS or iPad; iPad's Deep Settings buttons show a "SOON" placeholder until
  this exists.
- iOS UI for the numbered MENU grid (iPad has it; iOS doesn't yet).
- PTT port's `-P RIG` keying-type assumption not stress-tested against a
  real separate PTT interface.
- The numbered MENU grid is still growing — SSB page 1 items 2-27 are wired
  (or deliberately disabled placeholders, e.g. TXW/CW MESSAGE pending
  hardware issues), the rest of the grid's buttons are still unwired
  placeholders (wired one at a time as needed — see `MenuPageView.swift`
  for the current state). Deep Settings, a separate/larger system, is
  fully populated — see above.
- Waterfall/oscilloscope display is Mac-only; not exposed to mobile clients
  and not part of the wire protocol (see Architecture above).
- Deep Settings: RADIO SETTING's WIRES-X tab (no CAT manual source yet —
  postdates the manual's firmware revision), KEY/DIAL's MIC UP/MIC DOWN
  (unknown shape, deliberately deferred), and the manual's P1=09 "PRESET"
  category (5 full radio-setting presets — no page-3 button maps to it,
  out of scope until that's decided).

## Mac UI scope (resolved)

The Mac app has a single dense multi-pane window (VFO, meters, band/mode
selectors all visible at once) — no menu bar extra. Real control happens
in that window as well as from mobile; the Mac isn't monitor-only.
