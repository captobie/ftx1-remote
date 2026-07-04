# FTX1Core

Shared Swift package for the FTX-1 remote control app (Mac hub + iOS/iPadOS clients).

## Architecture

- **Mac app is the hub.** It owns the `RigctldClient` connection to rigctld
  (hamlib) on `localhost:4532`, holds live rig state, and runs
  `RigWebSocketServer` (Mac-only, in the app target — via `Network.framework`
  `NWListener`/`NWProtocolWebSocket`, since `URLSessionWebSocketTask` is
  client-only) that broadcasts state and accepts commands.
- **Mobile apps never talk to rigctld directly.** iOS/iPadOS use
  `RigWebSocketClient` to connect to `<mac-tailscale-hostname>:PORT`.
- **State sync is push-based.** The Mac broadcasts a `RigStatePush` whenever
  rigctld reports a change; clients don't poll.
- **Commands are serialized** through `CommandQueue` on the Mac side, since
  rigctld handles one request/response cycle at a time.

## Module layout

```
Sources/FTX1Core/
├── RigState/       RigState, RigMode — the shared state model
├── Networking/      WireMessage (JSON protocol), RigctldClient (Mac-only,
│                    TCP to rigctld), RigWebSocketClient (WS client, used
│                    by mobile and optionally the Mac's own UI)
└── Commands/        CommandQueue — serializes RigCommands into rigctld calls
```

## Not yet built

- Full state diffing / reconnect-and-resync logic for `RigWebSocketClient`.
- Band → frequency table for `CommandQueue.setBand`.
- Real `NWConnection` state-handling (`connect()` in `RigctldClient` has a
  TODO for waiting on `.ready` with a timeout).

## Mac UI scope (resolved)

The Mac app has a single dense multi-pane window (VFO, meters, band/mode
selectors all visible at once) — no menu bar extra. Real control happens
in that window as well as from mobile; the Mac isn't monitor-only.
