#!/usr/bin/env python3
"""Straight-key CW for the FTX-1 in Remote mode: receives key events from
one client at a time on TCP port 8534 and keys the rig by setting RTS or
DTR on its second USB serial port (CP2105 interface 1, the "Standard COM
Port"). rigctld keeps interface 0 (CAT); this never touches it.

The client is the Mac hub in Remote mode, relaying the operator's Arduino
key interface (cw_keyer/cw_keyer.ino). Messages are newline-delimited JSON,
the ones in docs/cw-protocol.md:

  client -> Pi  {"type":"cw_hello","seq":0,"id":"Mac","version":1,
                 "line":"RTS","inverted":false,"playoutDelayMs":300,
                 "heartbeatTimeoutMs":1000,"maxKeyDownMs":5000}
                {"type":"cw","seq":n,"t":<ms>,"state":"down"|"up"}
                {"type":"cw_hb","seq":n,"t":<ms>}
                {"type":"cw_bye","seq":n}
  Pi -> client  {"type":"cw_status","armed":..,"keyed":..,"holder":..,
                 "cutoff":..,"latched":..,"error":..,"playoutDelayMs":..}

`t` is the key interface's own millisecond clock (uint32, wraps), passed
through untouched, so the playout here measures the whole path — Arduino
USB, the Mac, Tailscale — and plays every transition at
t + offset + playout delay. The same rules as the Mac's local path
(Sources/FTX1Core/CWKey/, the source of truth for the logic):
  * clock offset = min over the last 2 s of (arrival - t); network delay
    only ever adds, so the smallest sample is the closest
  * a transition arriving late still keeps its keyed distance from the
    previous one; only spaces longer than 0.3 s shrink to catch up; never
    held more than 0.25 s past now + delay
  * key-up at once when the client disconnects or says bye, when nothing
    arrives for the heartbeat timeout, when the key stays down past the
    maximum, or when the port fails; each cutoff holds the line up until
    the operator's next key-up

The keying port is opened when a session starts (cw_hello) and closed when
it ends. HUPCL is set, so if this process dies the kernel drops the lines —
key-up with normal polarity. Opening a tty raises DTR/RTS until we clear
them a moment later; the rig's PC KEYING must be set to the line in use.

Run as a user in the dialout group. Environment: FTX1_CW_PORT (8534),
FTX1_CW_DEVICE (the CP2105's if01 by-id path).
"""
import fcntl
import json
import os
import select
import signal
import socket
import struct
import sys
import termios
import time

PORT = int(os.environ.get("FTX1_CW_PORT", "8534"))
DEVICE = os.environ.get(
    "FTX1_CW_DEVICE",
    "/dev/serial/by-id/usb-Silicon_Labs_CP2105_Dual_USB_to_UART_Bridge_Controller_01C7A9C5-if01-port0",
)
PROTOCOL_VERSION = 1

SYNC_WINDOW = 2.0
CATCH_UP_SPACE = 0.3
MAX_EXTRA_HOLD = 0.25
# Clamps for what a client may ask for.
PLAYOUT_RANGE = (0.02, 1.0)
HEARTBEAT_RANGE = (0.3, 5.0)
MAX_KEY_DOWN_RANGE = (1.0, 60.0)
DEFAULT_PLAYOUT = 0.3
DEFAULT_HEARTBEAT = 1.0
DEFAULT_MAX_KEY_DOWN = 5.0
MAX_LINE_BYTES = 512


def log(message):
    print(f"ftx1-cwkey: {message}", flush=True)


def clamp(value, bounds):
    return min(max(value, bounds[0]), bounds[1])


# ---------------------------------------------------------------- keyer

class ModemLineKeyer:
    """RTS or DTR on a tty, via TIOCMBIS/TIOCMBIC. The other line is held
    cleared so it can't act as PTT (RPTT SELECT)."""

    BITS = {"RTS": termios.TIOCM_RTS, "DTR": termios.TIOCM_DTR}

    def __init__(self, path, line, inverted):
        self.path = path
        self.bit = self.BITS[line]
        self.other = self.BITS["DTR" if line == "RTS" else "RTS"]
        self.inverted = inverted
        self.fd = None

    def open(self):
        fd = os.open(self.path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        try:
            fcntl.ioctl(fd, termios.TIOCEXCL)
            attrs = termios.tcgetattr(fd)
            attrs[2] |= termios.HUPCL | termios.CLOCAL
            termios.tcsetattr(fd, termios.TCSANOW, attrs)
            self.fd = fd
            self._lines(self.other, False)
            self.set_keyed(False)
        except OSError:
            os.close(fd)
            self.fd = None
            raise

    def _lines(self, bits, asserted):
        request = termios.TIOCMBIS if asserted else termios.TIOCMBIC
        fcntl.ioctl(self.fd, request, struct.pack("I", bits))

    def set_keyed(self, keyed):
        self._lines(self.bit, keyed != self.inverted)

    def close(self):
        if self.fd is None:
            return
        try:
            self.set_keyed(False)
        except OSError:
            pass
        os.close(self.fd)
        self.fd = None


# ---------------------------------------------------------------- logic

class Playout:
    """Clock sync + jitter buffer + safety for one session. Pure: times
    are passed in (seconds, monotonic). `keyed` is what the line should be."""

    def __init__(self, playout_delay, heartbeat_timeout, max_key_down):
        self.playout_delay = playout_delay
        self.heartbeat_timeout = heartbeat_timeout
        self.max_key_down = max_key_down
        self.samples = []          # (arrival, offset)
        self.last_device = None    # last raw uint32 t
        self.extended = 0          # unwrapped ms
        self.pending = []          # (play_at, down)
        self.last = None           # (down, play_at, device_ms) last accepted
        self.last_heard = None
        self.requested = False
        self.keyed = False
        self.keyed_since = None
        self.latch = None          # why the current hold is refused
        self.keyer_ok = True

    # -- clock
    def unwrap(self, t):
        if self.last_device is None:
            self.extended = t
        else:
            step = (t - self.last_device) & 0xFFFFFFFF
            if step >= 0x80000000:
                step -= 0x100000000
            if step < -1000:       # device restarted: rebase
                self.restart()
                self.extended = t
            else:
                self.extended += step
        self.last_device = t
        return self.extended

    def offset(self):
        return min(o for _, o in self.samples) if self.samples else None

    def restart(self):
        self.samples = []
        self.pending = []
        self.last = None
        self.last_device = None
        self.release()

    def release(self):
        """The operator's key counts as up (device restart, bad message)."""
        self.requested = False
        self.latch = None

    # -- input
    def heard(self, t, arrival, now):
        ms = self.unwrap(t)
        self.samples.append((arrival, arrival - ms / 1000.0))
        cutoff = arrival - SYNC_WINDOW
        self.samples = [s for s in self.samples if s[0] >= cutoff]
        self.last_heard = arrival if self.last_heard is None else max(self.last_heard, arrival)
        return ms

    def key_event(self, down, t, arrival, now):
        ms = self.heard(t, arrival, now)
        if self.last is not None and self.last[0] == down:
            return
        play_at = ms / 1000.0 + self.offset() + self.playout_delay
        if self.last is not None:
            spacing = max(0.0, (ms - self.last[2]) / 1000.0)
            if down:
                spacing = min(spacing, CATCH_UP_SPACE)
            spaced = min(self.last[1] + spacing, now + self.playout_delay + MAX_EXTRA_HOLD)
            play_at = max(play_at, spaced, self.last[1])
        play_at = max(play_at, now)
        self.pending.append((play_at, down))
        self.last = (down, play_at, ms)

    # -- time
    def tick(self, now):
        while self.pending and self.pending[0][0] <= now:
            play_at, down = self.pending.pop(0)
            self.requested = down
            if not down:
                self.latch = None
            self._update(play_at)
        self._update(now)

    def cutoff(self, now):
        if not self.keyer_ok:
            return "Keying port failed"
        if self.last_heard is None or now - self.last_heard >= self.heartbeat_timeout:
            return "Nothing from the hub (heartbeat timeout)"
        return None

    def _update(self, now):
        if self.requested and self.latch is None:
            reason = self.cutoff(now)
            if reason is None and self.keyed and now - self.keyed_since >= self.max_key_down:
                reason = "Key held too long — release the key"
            self.latch = reason
        should = self.requested and self.latch is None
        if should != self.keyed:
            self.keyed = should
            self.keyed_since = now if should else None

    def next_deadline(self):
        deadlines = []
        if self.pending:
            deadlines.append(self.pending[0][0])
        if self.last_heard is not None and (self.keyed or self.requested):
            deadlines.append(self.last_heard + self.heartbeat_timeout)
        if self.keyed:
            deadlines.append(self.keyed_since + self.max_key_down)
        return min(deadlines) if deadlines else None


# ---------------------------------------------------------------- server

class Session:
    def __init__(self, sock, addr, make_keyer, clock):
        self.sock = sock
        self.addr = addr
        self.make_keyer = make_keyer
        self.clock = clock
        self.buffer = b""
        self.keyer = None
        self.playout = None
        self.expected_seq = None
        self.error = None
        self.line_keyed = False
        self.last_status = None
        self.greeted = False   # no status until the client's cw_hello

    def send(self, message):
        try:
            self.sock.sendall((json.dumps(message) + "\n").encode())
        except OSError:
            pass

    def status(self, force=False):
        if not self.greeted:
            return
        now = self.clock()
        p = self.playout
        message = {
            "type": "cw_status",
            "armed": p is not None,
            "keyed": self.line_keyed,
            "holder": True,
            "cutoff": None if p is None else p.cutoff(now),
            "latched": None if p is None else p.latch,
            "error": self.error,
            "playoutDelayMs": None if p is None else round(p.playout_delay * 1000),
        }
        if force or message != self.last_status:
            self.last_status = message
            self.send(message)

    def apply(self):
        """Sets the line to the playout's state; a port error ends keying."""
        if self.playout is None:
            return
        want = self.playout.keyed
        if want == self.line_keyed or self.keyer is None:
            return
        try:
            self.keyer.set_keyed(want)
            self.line_keyed = want
        except OSError as exc:
            self.error = f"Keying port failed: {exc}"
            log(self.error)
            self.close_keyer()
            self.playout.keyer_ok = False
            self.playout.tick(self.clock())

    def close_keyer(self):
        if self.keyer is not None:
            self.keyer.close()
            self.keyer = None
        self.line_keyed = False

    def hello(self, message, now):
        self.greeted = True
        self.close_keyer()
        self.error = None
        line = message.get("line", "RTS")
        if line not in ("RTS", "DTR") or message.get("version") != PROTOCOL_VERSION:
            self.error = "Unsupported cw_hello (line or version)"
            self.playout = None
            self.status(force=True)
            return
        self.playout = Playout(
            clamp(message.get("playoutDelayMs", DEFAULT_PLAYOUT * 1000) / 1000.0, PLAYOUT_RANGE),
            clamp(message.get("heartbeatTimeoutMs", DEFAULT_HEARTBEAT * 1000) / 1000.0, HEARTBEAT_RANGE),
            clamp(message.get("maxKeyDownMs", DEFAULT_MAX_KEY_DOWN * 1000) / 1000.0, MAX_KEY_DOWN_RANGE),
        )
        self.playout.last_heard = now
        keyer = self.make_keyer(line, bool(message.get("inverted", False)))
        try:
            keyer.open()
            self.keyer = keyer
        except OSError as exc:
            self.error = f"Can't open the keying port: {exc}"
            self.playout.keyer_ok = False
        log(f"session from {self.addr[0]} ({message.get('id', '?')}): {line}"
            f"{' inverted' if message.get('inverted') else ''}, delay"
            f" {self.playout.playout_delay * 1000:.0f} ms"
            + (f" — {self.error}" if self.error else ""))
        self.expected_seq = (message.get("seq", 0) + 1) & 0xFFFFFFFF
        self.status(force=True)

    def handle(self, message, arrival):
        """Returns False when the session should end."""
        now = self.clock()
        kind = message.get("type")
        if kind == "cw_hello":
            self.hello(message, arrival)
            return True
        if kind == "cw_bye":
            return False
        if self.playout is None or kind not in ("cw", "cw_hb"):
            return True
        seq = message.get("seq")
        if not isinstance(seq, int):
            self.playout.release()
            return True
        if seq != self.expected_seq:
            log(f"seq gap ({self.expected_seq} expected, got {seq}): releasing")
            self.playout.restart()
        self.expected_seq = (seq + 1) & 0xFFFFFFFF
        t = message.get("t")
        if not isinstance(t, int) or not 0 <= t <= 0xFFFFFFFF:
            self.playout.release()
            return True
        if kind == "cw_hb":
            self.playout.heard(t, arrival, now)
        else:
            state = message.get("state")
            if state not in ("down", "up"):
                self.playout.release()
                return True
            self.playout.key_event(state == "down", t, arrival, now)
        return True

    def receive(self, data, arrival):
        self.buffer += data
        while b"\n" in self.buffer:
            line, self.buffer = self.buffer.split(b"\n", 1)
            if not line.strip():
                continue
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if not isinstance(message, dict):
                continue
            try:
                if not self.handle(message, arrival):
                    return False
            except (TypeError, ValueError, KeyError) as exc:
                # A malformed field: ignore the message, and the key is up.
                log(f"bad message ignored: {exc}")
                if self.playout is not None:
                    self.playout.release()
        if len(self.buffer) > MAX_LINE_BYTES:
            self.buffer = b""
        return True

    def tick(self):
        if self.playout is not None:
            self.playout.tick(self.clock())
        self.apply()
        self.status()

    def next_deadline(self):
        return None if self.playout is None else self.playout.next_deadline()

    def end(self, reason):
        if self.playout is not None:
            self.playout.release()
            self.playout.tick(self.clock())
            self.apply()          # key-up explicitly, then close
        self.close_keyer()
        self.playout = None
        log(f"session from {self.addr[0]} ended: {reason}")


def make_modem_keyer(line, inverted):
    return ModemLineKeyer(DEVICE, line, inverted)


def serve(listener, make_keyer=make_modem_keyer, clock=time.monotonic, should_stop=lambda: False):
    """Serves one client at a time on `listener` until should_stop()."""
    session = None
    while not should_stop():
        timeout = 0.5
        if session is not None:
            deadline = session.next_deadline()
            if deadline is not None:
                timeout = max(0.0, min(timeout, deadline - clock()))
        readable = [listener] + ([session.sock] if session else [])
        ready, _, _ = select.select(readable, [], [], timeout)
        if listener in ready:
            sock, addr = listener.accept()
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            if session is None:
                session = Session(sock, addr, make_keyer, clock)
                log(f"client {addr[0]} connected")
            else:
                busy = Session(sock, addr, make_keyer, clock)
                busy.send({"type": "cw_status", "armed": False, "keyed": False, "holder": False,
                           "cutoff": "Another client holds the key", "latched": None,
                           "error": None, "playoutDelayMs": None})
                sock.close()
                log(f"refused {addr[0]}: key busy")
        if session is not None and session.sock in ready:
            try:
                data = session.sock.recv(4096)
            except OSError:
                data = b""
            arrival = clock()
            keep = bool(data) and session.receive(data, arrival)
            if not keep:
                session.end("bye" if data else "disconnected")
                session.sock.close()
                session = None
                continue
        if session is not None:
            session.tick()
    if session is not None:
        session.end("shutting down")
        session.sock.close()


def main():
    stopping = []
    signal.signal(signal.SIGTERM, lambda *_: stopping.append(True))
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("0.0.0.0", PORT))
    listener.listen(2)
    log(f"listening on :{PORT}, keying {DEVICE}")
    try:
        serve(listener, should_stop=lambda: bool(stopping))
    except KeyboardInterrupt:
        pass
    log("stopped")


if __name__ == "__main__":
    sys.exit(main())
