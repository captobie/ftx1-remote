# Relayed straight-key CW messages

Status: **implemented hub → Pi; the hub's WebSocket side not yet.**

The straight key reaches the Mac hub over USB serial from the Arduino
interface (`cw_keyer/cw_keyer.ino`). These messages relay its events
elsewhere, so the Swift, Python and C# sides share one definition:

- **Hub → Pi (implemented, 2026-10-17)**: in Remote mode the rig's keying
  port is on the Pi, so the Mac (`CWRemoteKeyingDriver`) forwards the
  Arduino's events to `Pi/ftx1-cwkey.py` on **TCP 8534**, newline-
  delimited JSON, and the Pi plays them out and keys the line. `t` is the
  Arduino's own `millis()`, passed through.
- **Client → hub WebSocket (not yet)**: a remote client (iPad, iPhone,
  Windows) relaying its own key to the hub, described below as the hub's
  side; nothing accepts these on the WebSocket yet.

Wherever these land, the receiver runs the same playout as the Mac's
local path (`CWStraightKeyEngine` in `Sources/FTX1Core/CWKey/`; the Pi's
Python port follows it).

Each message below maps onto one line of the serial protocol, so a
hub-side `WebSocketCWKeySource` will be just another `CWKeySource`.

## Transport

- To the Pi: TCP 8534, one JSON object per line ("\n"), TCP_NODELAY on
  both ends. One client at a time; a second gets a `cw_status` with
  `holder: false` and is closed.
- To the hub (future): the hub's existing WebSocket (port 8765), JSON objects. Clients may send
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
{"type": "cw_hello", "seq": 0, "id": "Mac", "version": 1,
 "line": "RTS", "inverted": false, "playoutDelayMs": 300,
 "heartbeatTimeoutMs": 1000, "maxKeyDownMs": 5000}
```

Sent when the client's key input starts, after every reconnect, and when
the key interface restarts (its banner). `id`: free-form, for the log/UI.
`version`: this protocol, 1. The receiver resets its clock sync and
releases any key held for this client (serial equivalent: the
`I,FTX1CW,1` banner).

The other fields configure the session; all optional (Pi defaults in
brackets, clamped to the range): `line` "RTS"/"DTR" ["RTS"], `inverted`
[false], `playoutDelayMs` [300, 20–1000], `heartbeatTimeoutMs` [1000,
300–5000], `maxKeyDownMs` [5000, 1000–60000]. The Pi opens its keying port
on `cw_hello` and closes it when the session ends.

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
client is alive: the receiver forces key-up when it has heard nothing
from the keying client for the heartbeat timeout (the Pi: 1 s by default,
for Tailscale's jitter). The Mac forwards the Arduino's own heartbeats, so
a stalled Arduino, Mac or network all end the same way.

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
 "cutoff": null, "latched": null, "error": null, "playoutDelayMs": 300}
```

From the Pi: after `cw_hello` and whenever a field changes. `latched`:
why the current press is held up until the key is released (e.g. "Key
held too long — release the key"), else null. `error`: the keying port
failed or couldn't be opened, else null. The fields below are the hub
WebSocket's version of the same message.

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
cellular), so the playout delay for remote clients needs to be larger:
the Mac's Remote mode defaults to 300 ms and a 1 s heartbeat timeout,
both adjustable in Tools → Straight Key.

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
