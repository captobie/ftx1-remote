#!/usr/bin/env python3
"""Transmit audio for the FTX-1: receives raw 8 kHz mono 16-bit
little-endian PCM from one client at a time on port 8533 and plays it into
the rig's USB audio input (the Pi's USB sound card playback side, card 1).
The counterpart of ftx1-audiostream.py, which streams the rig's receive
audio the other way on 8532.

Clients: the iPad's Pi-direct route while its PTT is held, and the Mac hub
in Remote mode relaying an iPad's PTT (RemoteTXAudioClient.swift in
FTX1Core). One connection per transmission: connect on PTT press, send
audio, close on release.

This never keys the rig — keying stays a rigctld command from the client
("T currVFO 1"). The rig's MOD SOURCE menu (per mode: SSB/AM/FM/DATA) has
to be USB (or AUTO, if that picks USB on a CAT key) for this audio to be
what it transmits.

It does *unkey*, as a watchdog: a client that disappears mid-transmission
(app crashed, network gone, iPad asleep with the socket still open) would
otherwise leave the rig keyed until its time-out timer. So after a
transmission, unless the next one starts within NEXT_CLIENT_GRACE, or when
audio stops arriving for SILENCE_LIMIT while connected, this sends
"T currVFO 0" to rigctld on localhost:4532 (the Pi's rigctld runs with -o,
so verbs take a VFO argument). Unkeying an unkeyed rig is harmless; a
normal release gets unkeyed by the client too, about 300 ms after it stops
sending.

8 kHz mono: the relay format the apps already use for voice
(AudioStreamFormat.swift), ~16 KB/s. The "plug" layer in "ftx1_tx" (see
asound-ftx1.conf) converts to the hardware's 48 kHz stereo, both channels
carrying the same audio. "ftx1_tx" is a dmix, so Direwolf's own TX side can
share the device (point its ADEVICE output at ftx1_tx too); set
FTX1_TX_DEVICE to test against another device, e.g. plughw:1,0.

Playback starts once PREBUFFER_BYTES have arrived, which absorbs network
jitter; after an underrun it reopens the device and re-primes the same way
(this pyalsaaudio raises on an underrun instead of recovering).
"""
import os
import socket
import time

import alsaaudio

DEVICE = os.environ.get("FTX1_TX_DEVICE", "ftx1_tx")
PORT = int(os.environ.get("FTX1_TX_PORT", "8533"))
SAMPLE_RATE = 8000
BYTES_PER_FRAME = 2  # 16-bit mono
PERIOD_FRAMES = 160  # 20 ms
PERIOD_BYTES = PERIOD_FRAMES * BYTES_PER_FRAME
PERIODS = 8  # 160 ms device buffer: room for network jitter
PREBUFFER_BYTES = SAMPLE_RATE * BYTES_PER_FRAME * 120 // 1000  # 120 ms
SILENCE_LIMIT = 1.5  # seconds without audio while connected -> unkey
NEXT_CLIENT_GRACE = 0.5  # seconds to wait for the next transmission before unkeying
RIGCTLD = ("127.0.0.1", 4532)


def log(message):
    print(f"ftx1-txaudio: {message}", flush=True)


def unkey(reason):
    """Best-effort "T currVFO 0" to rigctld; never raises."""
    try:
        with socket.create_connection(RIGCTLD, timeout=2) as rig:
            rig.sendall(b"T currVFO 0\n")
            rig.settimeout(2)
            reply = rig.recv(64).decode(errors="replace").strip()
        log(f"unkeyed ({reason}): rigctld replied {reply!r}")
    except OSError as exc:
        log(f"unkey ({reason}) failed: {exc}")


def open_playback():
    return alsaaudio.PCM(
        alsaaudio.PCM_PLAYBACK,
        alsaaudio.PCM_NORMAL,
        device=DEVICE,
        channels=1,
        rate=SAMPLE_RATE,
        format=alsaaudio.PCM_FORMAT_S16_LE,
        periodsize=PERIOD_FRAMES,
        periods=PERIODS,
    )


def write_periods(pcm, data):
    """Writes whole periods; after an underrun (pyalsaaudio raises
    "Broken pipe" rather than recovering) reopens the device. Returns the
    PCM to keep using and whether an underrun happened."""
    try:
        for offset in range(0, len(data), PERIOD_BYTES):
            pcm.write(data[offset:offset + PERIOD_BYTES])
        return pcm, False
    except alsaaudio.ALSAAudioError as exc:
        log(f"underrun ({exc}), restarting playback")
        pcm.close()
        return open_playback(), True


def play_client(client):
    """Plays one transmission. Returns (whether to unkey afterwards, a
    summary). A client that connected and never sent anything gets no
    unkey on close; one that went quiet while connected always does."""
    client.settimeout(0.1)
    pcm = open_playback()
    pending = b""
    primed = False
    received = 0
    last_audio = time.monotonic()
    try:
        while True:
            try:
                data = client.recv(4096)
            except socket.timeout:
                data = None
            now = time.monotonic()
            if data == b"":
                reason = "client closed"
                break
            if data:
                received += len(data)
                last_audio = now
                pending += data
            elif now - last_audio > SILENCE_LIMIT:
                reason = f"no audio for {SILENCE_LIMIT} s"
                received = max(received, 1)  # unkey even if nothing came
                break

            if not primed and len(pending) >= PREBUFFER_BYTES:
                primed = True
            if primed:
                whole = len(pending) - len(pending) % PERIOD_BYTES
                pcm, underrun = write_periods(pcm, pending[:whole])
                if underrun:
                    # The chunk that hit the underrun is lost; re-prime.
                    pending = pending[whole:]
                    primed = False
                    continue
                pending = pending[whole:]
                if not data and whole == 0:
                    # Nothing to write this round: the buffer will run dry,
                    # so wait for a fresh prebuffer before playing again.
                    primed = False

        # Play out what's left (padded to a whole period), then let ALSA
        # finish the buffer before the device closes.
        if pending:
            pending += b"\x00" * (-len(pending) % PERIOD_BYTES)
            pcm, _ = write_periods(pcm, pending)
        try:
            pcm.drain()
        except alsaaudio.ALSAAudioError:
            # Already underrun (the client went quiet first): nothing
            # left to play out.
            pass
    finally:
        pcm.close()
    return received > 0, f"{reason}, {received} bytes"


def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", PORT))
    server.listen(1)
    log(f"listening on :{PORT}, playing into {DEVICE}")

    next_client = None
    while True:
        if next_client is None:
            server.settimeout(None)
            client, addr = server.accept()
        else:
            client, addr = next_client
            next_client = None
        log(f"transmission from {addr}")
        should_unkey = False
        try:
            should_unkey, summary = play_client(client)
            log(f"transmission ended: {summary}")
        except (OSError, alsaaudio.ALSAAudioError) as exc:
            # alsaaudio.ALSAAudioError isn't an OSError (see
            # ftx1-audiostream.py) — catch both so one bad transmission
            # can't crash the service into a restart loop.
            should_unkey = True
            log(f"transmission failed: {exc}")
        finally:
            client.close()

        if not should_unkey:
            continue
        # A quick re-press opens the next connection right away; don't unkey
        # underneath it.
        server.settimeout(NEXT_CLIENT_GRACE)
        try:
            next_client = server.accept()
        except socket.timeout:
            unkey("transmission over")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
