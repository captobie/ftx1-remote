# Straight-key CW over the hub WebSocket (draft, not implemented)

Status: **schema only.** Today the straight key reaches the hub over USB
serial from the Arduino interface (`cw_keyer/cw_keyer.ino`). This document
fixes the WebSocket messages a remote client (iPad, iPhone, Windows) will
use later to relay the same key events to the hub, so the C# and Swift
clients can be written against one definition. Nothing here is sent or
accepted yet.

The hub plays remote key events through exactly the same path as the
serial ones (`CWStraightKeyEngine` in `Sources/FTX1Core/CWKey/`): clock
sync, jitter buffer, safety cutoffs, then the RTS/DTR keying line. Each
message below maps onto one line of the serial protocol, so a hub-side
`WebSocketCWKeySource` is just another `CWKeySource`.

## Transport

- The hub's existing WebSocket (port 8765), JSON objects. Clients may send
  them as text or binary frames (the iPad already sends JSON as binary);
  only a binary frame starting with a tag byte `0x00`–`0x02` is audio
  (`AudioStreamFormat`), so a JSON frame always starts with `{`.
- Send every key message the moment it happens — no batching, no
  coalescing timer. Timing comes from `t`, not from arrival, but late
  arrival eats into the playout delay.
- Don't confuse with `cw_keyer` / `cw_keyer_reply`, the existing pair for
  the rig's own keyer memory (text sending). These are different messages.

## Client → hub

All three carry `seq` and, except `cw_hello`, `t`.

- `seq`: unsigned 32-bit counter, one sequence shared by all three
  message types of a key session, +1 per message, starting at 0 with
  `cw_hello`. TCP doesn't lose messages, so a gap means the client
  restarted its session without a hello; the hub treats that like a new
  hello (key released).
- `t`: the client's **monotonic** clock in milliseconds, unsigned 32-bit,
  wrapping at 2^32 (like the Arduino's `millis()`). Never wall-clock
  time: NTP steps would move it. Any epoch; only differences matter.
  (iOS: `DispatchTime.now().uptimeNanoseconds / 1_000_000`, truncated to
  UInt32; Windows: `Stopwatch.GetTimestamp()` scaled to ms, truncated.)

### `cw_hello` — start of a key session

```json
{"type": "cw_hello", "seq": 0, "id": "iPad", "version": 1}
```

Sent when the client's key input starts (and after every reconnect).
`id`: free-form, for the hub's log/UI. `version`: this protocol, 1. The
hub resets its clock sync and releases any key held for this client
(serial equivalent: the `I,FTX1CW,1` banner).

### `cw` — key down / up

```json
{"type": "cw", "seq": 17, "t": 4012345, "state": "down"}
{"type": "cw", "seq": 18, "t": 4012405, "state": "up"}
```

`t` is when the key changed, read as close to the input as possible
(serial equivalent: `D,<ms>` / `U,<ms>`). A repeat of the current state
is ignored.

### `cw_hb` — heartbeat

```json
{"type": "cw_hb", "seq": 19, "t": 4012500}
```

Every 250 ms for as long as the session is open, key up or down (serial:
`H,<ms>`). It feeds the clock sync while the key is idle and proves the
client is alive: the hub forces key-up when it has heard nothing from the
keying client for 500 ms (on a WAN link this will likely need to be
longer, see below).

### `cw_bye` — end of session (optional)

```json
{"type": "cw_bye", "seq": 40}
```

Releases at once instead of waiting for the heartbeat timeout. A closed
WebSocket does the same.

## Hub → client

### `cw_status`

```json
{"type": "cw_status", "armed": true, "keyed": false, "holder": true,
 "cutoff": null, "playoutDelayMs": 400}
```

Sent to a client after its `cw_hello`, and whenever any field changes.
`armed`: the hub's Arm toggle. `keyed`: the keying line (for an on-screen
indicator; never for sidetone — clients play their own sidetone locally,
from the key itself). `holder`: this client owns the key (see below).
`cutoff`: null, or why keying is refused/stopped, as display text
(`CWKeyingSafety.Cutoff.description`, e.g. "Not armed", "Key held too
long — release the key"). `playoutDelayMs`: the delay the hub applies.

## Clock sync (hub side)

Same as serial: for every message carrying `t`, the hub takes `offset =
hostReceived − t` and keeps the **minimum** over the last 2 s — network
delay only ever adds, so the smallest sample is the closest to the truth.
Each transition plays at `t + offset + playoutDelay`. A transition late
for its slot still keeps its keyed distance from the previous one; only
word-length spaces (> 0.3 s) shrink to catch up.

Over Tailscale the delay varies far more than over USB (tens of ms, more on
cellular), so the playout delay for remote clients needs to be larger —
probably 300–500 ms, chosen per source — and the heartbeat timeout will
need to be longer than 500 ms. To be settled when the relay is built.

## Safety rules the relay must keep

- One keying client at a time (like the PTT holder and the CW keyer
  lease): the first `cw_hello` while nobody holds the key takes it; others
  get `holder: false` and their `cw` messages are ignored.
- Every cutoff of the serial path applies: Arm off, Enable Transmit off or
  outside an amateur band, heartbeat timeout, client disconnect, key-down
  past the maximum (5 s default) — each forces key-up and latches until
  that client's next `up`.
- Unknown `version`, malformed or out-of-order messages: ignore the
  message, and if it's a `cw`, release the key.
