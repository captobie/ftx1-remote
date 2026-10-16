# Hub wire fixtures

Shared between the Swift package and the Windows app's hub (see
`Apps/Windows/README.md`, "Desktop hub for the iPad").

- `rig-state-push.*.json` are `RigStatePush`es (`{"type":"state","state":{…}}`)
  encoded by `FTX1Core` itself. `HubWireFixtureTests` checks they still
  match `RigState`; regenerate after any `RigState` change with
  `REGENERATE_WIRE_FIXTURES=1 swift test --filter HubWireFixtureTests`.
  - `full`: every field set once.
  - `minimal`: only the required fields — `frequencyHz`, `mode`, `ptt`,
    `lastUpdated`, `aprsActive`, `aprsSubActive`, `transmitEnabled`.
  - `vfo`: the enum shapes `full` can't show at the same time.
- `memory-list-push.json`, `memory-list-push.scanning.json` (while the
  hub is still reading the list: `scanningChannel`, no `scanned`),
  `aprs-list-push.json`, `menu-item-read-request.json` (iPad → hub),
  `menu-item-push.json` and `menu-item-push.unreadable.json` (no `value`
  key at all when the item can't be read): phase 4's messages, made by
  `FTX1Core`.
- `rig-commands.json`: one of every `RigCommand` (`{"cmd": …, "value": …}`)
  as the iPad sends it. `HubWireFixtureTests` fails if a command is
  added to `WireMessage.swift` without an example here.
- `windows/*.json` are pushes produced by the Windows hub's C# code,
  committed from the Windows PC. `swift test --filter HubWireFixtureTests`
  on the Mac checks each one is read by the iPad as the kind its `type`
  says (the iPad tries state, memory_list, aprs_list, menu_item,
  cw_keyer_reply in that order and silently drops what none takes), then
  decodes it strictly as that type.
- `windows/audio-<main|sub>-<tone>hz-<label>.bin` (phase 3): one receive
  audio frame each, exactly as the hub sends it (tag `0x00` MAIN / `0x01`
  SUB, then Int16LE mono PCM at 8 kHz), made by the hub's real
  downsampler from 1 s of a −6 dBFS sine at `<tone>` Hz at the input
  rate named in `<label>` (e.g. `audio-main-1000hz-from44100.bin`). The
  Swift test checks the tag, ~8000 samples, the tone within 1 % and a
  peak near half scale.

Shapes that are easy to get wrong in C#:

- `lastUpdated` (and every other date: `scanned`, `lastHeardAt`,
  `receivedAt`): a number of **seconds since 2001-01-01T00:00:00Z**
  (Swift's default `Date` encoding), not Unix time, not a string.
  813758400 = 2026-10-15T12:00:00Z; Unix seconds − 978307200.
- `vfoMemoryMode`/`subVfoMemoryMode`: `{"vfo":{}}`, `{"memory":{}}` or
  `{"other":{"rawP2":2}}` (Swift's synthesized enum-with-payload coding).
- `mode`/`secondaryMode`: `RigMode` raw values (`USB`, `PKTUSB`, `FM-D`,
  `C4FM`, …), not display names.
- `filterSide`/`txSide`/`memoryScanSide`: numbers (0 MAIN, 1 SUB).
- `memoryScan`: `"stopped"`/`"scanning"`/`"paused"`.
- `cwMessageStatus`: number (0 stopped, 1 recording, 2 playing).
- Leave a nil optional field out (Swift writes nothing); `null` also
  decodes.
