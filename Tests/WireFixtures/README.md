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
- `windows/*.json` are pushes produced by the Windows hub's C# code,
  committed from the Windows PC. `swift test --filter HubWireFixtureTests`
  on the Mac decodes each one the way the iPad does.

Shapes that are easy to get wrong in C#:

- `lastUpdated`: a number of **seconds since 2001-01-01T00:00:00Z**
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
