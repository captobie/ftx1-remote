"""Tests for ftx1-cwkey.py — run on any machine (no serial port needed):

    python3 -m unittest discover -s Pi/tests

The playout logic is checked with made-up times; the server end to end over
a real local TCP socket with a fake keyer.
"""
import importlib.util
import json
import os
import socket
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("ftx1_cwkey", os.path.join(HERE, "..", "ftx1-cwkey.py"))
cwkey = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cwkey)


def playout(delay=0.3, heartbeat=1.0, max_down=5.0):
    return cwkey.Playout(delay, heartbeat, max_down)


class PlayoutTests(unittest.TestCase):
    def run_until(self, p, end, step=0.001, start=0.0):
        """Ticks from start to end; returns the (time, keyed) changes."""
        changes, keyed, t = [], p.keyed, start
        while t <= end:
            p.tick(t)
            if p.keyed != keyed:
                keyed = p.keyed
                changes.append((round(t, 3), keyed))
            t += step
        return changes

    def test_plays_at_keyed_spacing_despite_jitter(self):
        p = playout(delay=0.3)
        # Device clock 100 s behind; arrivals delayed 5-60 ms.
        p.heard(0, 100.005, 100.005)
        p.key_event(True, 1000, 101.060, 101.060)
        p.heard(1050, 101.055, 101.060)     # a heartbeat that came through fast
        p.key_event(False, 1060, 101.070, 101.070)
        changes = self.run_until(p, 102.0, start=101.07)
        # offset = min sample = 100.005 → down at 101.305, up 60 ms later.
        self.assertEqual(len(changes), 2)
        self.assertAlmostEqual(changes[0][0], 101.305, delta=0.0015)
        self.assertAlmostEqual(changes[1][0] - changes[0][0], 0.060, delta=0.0015)

    def test_unwraps_device_clock(self):
        p = playout()
        top = 0xFFFFFFFF - 29
        p.heard(top, 10.0, 10.0)
        p.key_event(True, top, 10.001, 10.001)
        p.key_event(False, 30, 10.062, 10.062)     # 60 ms later, after the wrap
        self.assertAlmostEqual(p.pending[1][0] - p.pending[0][0], 0.060, places=6)

    def test_late_burst_keeps_spacing(self):
        p = playout(delay=0.3)
        p.heard(0, 0.0, 0.0)
        p.key_event(True, 1000, 1.6, 1.6)       # 300 ms later than its slot
        p.key_event(False, 1060, 1.6, 1.6)
        self.assertAlmostEqual(p.pending[0][0], 1.6)
        self.assertAlmostEqual(p.pending[1][0], 1.66)

    def test_heartbeat_timeout_cuts_off_and_latches(self):
        p = playout(heartbeat=1.0)
        p.heard(0, 0.0, 0.0)
        p.key_event(True, 100, 0.1, 0.1)
        p.tick(0.5)
        self.assertTrue(p.keyed)
        p.tick(1.1)        # last heard 0.1 → timeout at 1.1
        self.assertFalse(p.keyed)
        self.assertIsNotNone(p.latch)
        p.heard(1200, 1.2, 1.2)   # heard again, still held: stays up
        p.tick(1.2)
        self.assertFalse(p.keyed)
        p.key_event(False, 1300, 1.3, 1.3)
        p.key_event(True, 1400, 1.4, 1.4)
        p.heard(1600, 1.6, 1.6)
        p.tick(1.9)
        self.assertTrue(p.keyed)

    def test_max_key_down_cuts_off_and_latches(self):
        p = playout(delay=0.1, max_down=2.0)
        p.heard(0, 0.0, 0.0)
        p.key_event(True, 0, 0.0, 0.0)
        t = 0.0
        while t < 2.5:
            t += 0.25
            p.heard(int(t * 1000), t, t)
            p.tick(t)
        self.assertFalse(p.keyed)
        self.assertIn("too long", p.latch)

    def test_device_restart_releases(self):
        p = playout()
        p.heard(5_000_000, 0.0, 0.0)
        p.key_event(True, 5_000_100, 0.1, 0.1)
        p.tick(0.5)
        self.assertTrue(p.keyed)
        p.heard(20, 0.6, 0.6)          # clock jumped back: restarted
        p.tick(0.6)
        self.assertFalse(p.keyed)
        self.assertEqual(p.pending, [])

    def test_repeat_state_ignored(self):
        p = playout()
        p.heard(0, 0.0, 0.0)
        p.key_event(True, 10, 0.01, 0.01)
        p.key_event(True, 20, 0.02, 0.02)
        self.assertEqual(len(p.pending), 1)


class FakeKeyer:
    instances = []

    def __init__(self, line, inverted, fail_open=False):
        self.line, self.inverted, self.fail_open = line, inverted, fail_open
        self.calls, self.opened, self.closed = [], False, False
        self.lock = threading.Lock()
        FakeKeyer.instances.append(self)

    def open(self):
        if self.fail_open:
            raise OSError("no such device")
        self.opened = True

    def set_keyed(self, keyed):
        with self.lock:
            self.calls.append((keyed, time.monotonic()))

    def close(self):
        self.closed = True

    @property
    def keyed(self):
        with self.lock:
            return bool(self.calls) and self.calls[-1][0]


class ServerTests(unittest.TestCase):
    def setUp(self):
        FakeKeyer.instances = []
        self.listener = socket.socket()
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(2)
        self.port = self.listener.getsockname()[1]
        self.stop = threading.Event()
        self.thread = threading.Thread(target=cwkey.serve, args=(self.listener,),
                                       kwargs={"make_keyer": FakeKeyer, "should_stop": self.stop.is_set},
                                       daemon=True)
        self.thread.start()
        self.start = time.monotonic()
        self.seq = 0

    def tearDown(self):
        self.stop.set()
        self.thread.join(2)
        self.listener.close()

    def device_ms(self):
        return int((time.monotonic() - self.start) * 1000) & 0xFFFFFFFF

    def connect(self, **hello):
        client = socket.create_connection(("127.0.0.1", self.port))
        client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.seq = 0
        message = {"type": "cw_hello", "seq": 0, "id": "test", "version": 1, "line": "RTS",
                   "inverted": False, "playoutDelayMs": 100, "heartbeatTimeoutMs": 500, "maxKeyDownMs": 5000}
        message.update(hello)
        self.send(client, message)
        return client

    def send(self, client, message):
        client.sendall((json.dumps(message) + "\n").encode())

    def next(self, client, kind, **fields):
        self.seq += 1
        message = {"type": kind, "seq": self.seq, **fields}
        self.send(client, message)
        return message

    def key(self, client, down):
        return self.next(client, "cw", t=self.device_ms(), state="down" if down else "up")

    def heartbeat(self, client):
        self.next(client, "cw_hb", t=self.device_ms())

    def read_status(self, client, timeout=1.0):
        client.settimeout(timeout)
        data = b""
        while not data.endswith(b"\n"):
            data += client.recv(4096)
        return [json.loads(line) for line in data.decode().splitlines()]

    def wait(self, condition, timeout=2.0):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if condition():
                return True
            time.sleep(0.002)
        return condition()

    def test_keys_with_keyed_spacing(self):
        client = self.connect()
        status = self.read_status(client)[0]
        self.assertTrue(status["armed"])
        self.assertTrue(FakeKeyer.instances[0].opened)
        self.heartbeat(client)
        down = self.key(client, True)["t"]
        time.sleep(0.06)
        up = self.key(client, False)["t"]
        keyer = FakeKeyer.instances[0]
        self.assertTrue(self.wait(lambda: len(keyer.calls) >= 2))
        (k1, t1), (k2, t2) = keyer.calls[:2]
        self.assertEqual((k1, k2), (True, False))
        self.assertAlmostEqual(t2 - t1, (up - down) / 1000, delta=0.004)
        client.close()

    def test_disconnect_releases_at_once(self):
        client = self.connect()
        self.heartbeat(client)
        self.key(client, True)
        keyer = self.wait(lambda: FakeKeyer.instances and FakeKeyer.instances[0].keyed) and FakeKeyer.instances[0]
        self.assertTrue(keyer)
        closed_at = time.monotonic()
        client.close()
        self.assertTrue(self.wait(lambda: not keyer.keyed and keyer.closed))
        self.assertLess(keyer.calls[-1][1] - closed_at, 0.05)

    def test_silence_releases(self):
        client = self.connect(heartbeatTimeoutMs=500)
        self.heartbeat(client)
        self.key(client, True)
        self.assertTrue(self.wait(lambda: FakeKeyer.instances and FakeKeyer.instances[0].keyed))
        keyer = FakeKeyer.instances[0]
        stopped = time.monotonic()
        self.assertTrue(self.wait(lambda: not keyer.keyed))
        self.assertLess(keyer.calls[-1][1] - stopped, 0.6)
        client.close()

    def test_bye_releases_and_closes_port(self):
        client = self.connect()
        self.heartbeat(client)
        self.key(client, True)
        self.assertTrue(self.wait(lambda: FakeKeyer.instances and FakeKeyer.instances[0].keyed))
        keyer = FakeKeyer.instances[0]
        self.next(client, "cw_bye")
        self.assertTrue(self.wait(lambda: keyer.closed and not keyer.keyed))
        client.close()

    def test_second_client_refused(self):
        first = self.connect()
        self.read_status(first)
        second = socket.create_connection(("127.0.0.1", self.port))
        status = self.read_status(second)[0]
        self.assertFalse(status["holder"])
        self.assertEqual(len(FakeKeyer.instances), 1)
        first.close()
        second.close()

    def test_garbage_is_ignored_and_releases(self):
        client = self.connect()
        self.heartbeat(client)
        self.key(client, True)
        self.assertTrue(self.wait(lambda: FakeKeyer.instances and FakeKeyer.instances[0].keyed))
        keyer = FakeKeyer.instances[0]
        client.sendall(b"not json\n")
        self.next(client, "cw", t="soon", state="down")
        self.assertTrue(self.wait(lambda: not keyer.keyed))
        # Still serving: a fresh press keys again.
        self.heartbeat(client)
        self.key(client, False)
        self.key(client, True)
        self.assertTrue(self.wait(lambda: keyer.keyed))
        client.close()

    def test_port_open_failure_reported(self):
        original = cwkey.ModemLineKeyer
        client = socket.create_connection(("127.0.0.1", self.port))
        FakeKeyer.instances = []
        # Swap the factory for one that fails: restart the server thread.
        self.stop.set()
        self.thread.join(2)
        self.stop.clear()
        self.thread = threading.Thread(
            target=cwkey.serve, args=(self.listener,),
            kwargs={"make_keyer": lambda line, inv: FakeKeyer(line, inv, fail_open=True),
                    "should_stop": self.stop.is_set}, daemon=True)
        self.thread.start()
        client.close()
        client = self.connect()
        statuses = self.read_status(client)
        self.assertIn("Can't open", statuses[0]["error"])
        self.heartbeat(client)
        self.key(client, True)
        time.sleep(0.3)
        self.assertEqual(FakeKeyer.instances[-1].calls, [])
        self.assertIs(cwkey.ModemLineKeyer, original)
        client.close()


if __name__ == "__main__":
    unittest.main()
