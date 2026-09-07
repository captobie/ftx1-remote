#!/usr/bin/env python3
"""Captures the FTX-1's audio-out (via the Pi's USB sound card) and streams
it as raw mono 16-bit little-endian PCM at 44100Hz to a single connected
client — the Mac app, in .remote mode (see
Apps/Mac/FTX1RemoteMac/RemoteAudioStreamClient.swift).

Deliberately dumb: no framing, no compression, no negotiation. This is a
dedicated audio-only connection, so unlike the Mac->iPad relay (see
FTX1Core's AudioStreamFormat, fixed at 8kHz — a deliberately different,
lower-bandwidth wire format for that separate hop) there's no shared
constant to match here, just this file and RemoteAudioStreamClient's own
default agreeing on the number directly.

44100Hz, not 8kHz: raised 2026-09-07 after 8kHz (the original choice, kept
deliberately low-bandwidth) turned out to leave AFSKDemodulator too little
timing resolution to reliably decode APRS (~6.7 samples/bit at 8kHz vs ~37
at 44100Hz for 1200-baud Bell 202 — see AFSKDemodulator.swift's
bitPhaseIncrement). 44100 specifically matches Direwolf's own AFSK
demodulation rate on this exact hardware (see /etc/direwolf.conf), already
proven to decode real APRS traffic — same physical audio, same demodulation
task, high confidence the same rate works here too. Raises Pi->Mac bandwidth
from ~16KB/s to ~86KB/s, trivial for any real network link.

Shares the physical capture device with Direwolf (which also captures it,
for APRS decode) via the "ftx1_shared" ALSA device defined in
asound-ftx1.conf — confirmed on 2026-09-07 that opening the raw
"plughw:1,0" directly, which this used before, genuinely conflicts with
Direwolf's own already-open handle ("Device or resource busy"), not just a
theoretical risk. See asound-ftx1.conf for the dsnoop/plug setup this
depends on; that file must be installed and both direwolf.conf's ADEVICE
and this script's DEVICE below must point at "ftx1_shared" together, or
this goes right back to the same conflict.

The "plug" layer in "ftx1_shared" handles any sample-rate conversion needed
to reach 44100Hz here, independent of whatever rate Direwolf's own reader of
the same shared device asks for (also 44100 in practice, but not a
requirement — plug would handle it either way) — so this script still
doesn't need its own resampler.
"""
import alsaaudio
import socket

DEVICE = "ftx1_shared"
SAMPLE_RATE = 44100
CHANNELS = 1
PERIOD_SIZE = 1024  # frames per ALSA read, ~23ms at 44100Hz
PORT = 8532


def stream_to_client(client):
    capture = alsaaudio.PCM(
        alsaaudio.PCM_CAPTURE,
        alsaaudio.PCM_NORMAL,
        device=DEVICE,
        channels=CHANNELS,
        rate=SAMPLE_RATE,
        format=alsaaudio.PCM_FORMAT_S16_LE,
        periodsize=PERIOD_SIZE,
    )
    try:
        while True:
            length, data = capture.read()
            if length <= 0:
                continue
            client.sendall(data)
    finally:
        capture.close()


def main():
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("0.0.0.0", PORT))
    server.listen(1)
    print(f"ftx1-audiostream: listening on :{PORT}", flush=True)

    while True:
        client, addr = server.accept()
        print(f"ftx1-audiostream: client connected from {addr}", flush=True)
        try:
            stream_to_client(client)
        except (BrokenPipeError, ConnectionResetError, OSError, alsaaudio.ALSAAudioError) as exc:
            # alsaaudio.ALSAAudioError isn't an OSError subclass, so it was
            # missing here originally — meant a busy/unavailable device (see
            # the dsnoop note above) crashed the whole process instead of
            # just failing this one client's connection attempt, and
            # systemd's Restart=always turned that into a tight crash loop
            # that could never succeed until the underlying device
            # contention was fixed anyway.
            print(f"ftx1-audiostream: client disconnected ({exc})", flush=True)
        finally:
            client.close()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
