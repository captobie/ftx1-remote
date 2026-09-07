# Pi-side audio streaming (Option A, Remote mode)

`ftx1-audiostream.py` captures the FTX-1's audio-out (via the Pi's USB
sound card, the same `plughw:1,0` device Direwolf already uses) and streams
it as raw 44100Hz mono 16-bit PCM to whichever Mac client connects — see
`Apps/Mac/FTX1RemoteMac/RemoteAudioStreamClient.swift` for the consumer.
Runs alongside `rigctld.service` and `direwolf.service` as its own systemd
unit, same pattern.

Raised from an original 8kHz to 44100Hz on 2026-09-07 — 8kHz left the Mac's
APRS demodulator too little timing resolution to reliably decode packets
(see `ftx1-audiostream.py`'s own doc comment for the full reasoning); 44100
matches what Direwolf itself already uses successfully on this exact
hardware.

## Install

From the Mac (this repo checkout), copy the two files to the Pi first:

```bash
scp Pi/ftx1-audiostream.py Pi/ftx1-audiostream.service captobie@ftx1pi:~/
```

Then on the Pi:

```bash
sudo apt install python3-alsaaudio
sudo useradd --system --group audio --no-create-home ftx1audio
sudo mkdir -p /opt/ftx1remote
sudo cp ftx1-audiostream.py /opt/ftx1remote/
sudo cp ftx1-audiostream.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ftx1-audiostream.service
```

## Verify

```bash
sudo systemctl status ftx1-audiostream
journalctl -u ftx1-audiostream -f
```

A quick manual test without the Mac app at all — from another machine (or
the Pi itself), raw PCM should start flowing the moment you connect:

```bash
nc ftx1pi 8532 | head -c 88200 > /tmp/test.pcm   # ~1s of audio at 44100Hz/16-bit mono
```

## Sharing the device with Direwolf

**Confirmed conflict (2026-09-07)**, not just a theoretical risk: Direwolf
holds `plughw:1,0` open continuously for its own APRS decode, so this
script opening the same raw device fails immediately with `Device or
resource busy` the moment a Mac client connects.

Fix: `asound-ftx1.conf` sets up an ALSA `dsnoop`+`plug` device
(`ftx1_shared`) that lets both processes read the same physical capture
device at once, each with their own sample rate.

```bash
scp Pi/asound-ftx1.conf captobie@ftx1pi:~/
```

On the Pi:

```bash
# Append to /etc/asound.conf (create it if it doesn't exist)
cat asound-ftx1.conf | sudo tee -a /etc/asound.conf

# Confirm what rate Direwolf is already successfully using, and match it
# in asound-ftx1.conf's "rate 48000" line if different, before proceeding
grep -i arate /etc/direwolf.conf

# Point Direwolf's *capture* side at the shared device, but keep its
# playback/TX side on the raw device directly — dsnoop (which ftx1_shared
# is built on) only supports capture streams at all, and TX doesn't need
# sharing anyway since ftx1-audiostream.py never does playback. Direwolf's
# ADEVICE takes two arguments for exactly this asymmetric case: <input>
# <output>. Confirmed necessary 2026-09-07 — a single-argument "ADEVICE
# ftx1_shared" makes Direwolf try (and fail) to open the capture-only
# dsnoop device for output too.
sudo sed -i 's/^ADEVICE .*/ADEVICE ftx1_shared plughw:1,0/' /etc/direwolf.conf

# Update this script's own DEVICE constant the same way (already done in
# the repo as of this fix — re-copy ftx1-audiostream.py if you deployed it
# before this change)
scp Pi/ftx1-audiostream.py captobie@ftx1pi:~/
sudo cp ~/ftx1-audiostream.py /opt/ftx1remote/

sudo systemctl restart direwolf
sudo systemctl restart ftx1-audiostream
sudo systemctl status direwolf ftx1-audiostream
```

**Second confirmed conflict (2026-09-07)**: `Permission denied [ftx1_shared]`
— `direwolf` and `ftx1audio` are different Unix accounts, and dsnoop's IPC
semaphore/shared-memory objects default to permissions that only let the
*creating* user attach, so whichever of the two processes gets there second
fails. Fixed by adding `ipc_perm 0666` to `asound-ftx1.conf`'s dsnoop block
— already in the repo version, but if you deployed the file before this fix,
you need the corrected copy. Since `/etc/asound.conf`'s entire content is
just this one file's contents (nothing else was ever appended to it),
**overwrite** rather than append this time:

```bash
scp Pi/asound-ftx1.conf captobie@ftx1pi:~/
```

On the Pi:

```bash
sudo tee /etc/asound.conf < asound-ftx1.conf
sudo systemctl restart direwolf
sudo systemctl restart ftx1-audiostream
sudo systemctl status direwolf ftx1-audiostream
journalctl -u ftx1-audiostream -f
```

If `ftx1-audiostream` still fails after this, the next most likely culprit
is the dsnoop slave's `rate 48000` not matching what the hardware/Direwolf
actually use — adjust `asound-ftx1.conf`'s `rate` to match `grep -i arate
/etc/direwolf.conf`'s output (or the hardware's native rate) and re-run the
`tee`/restart steps above.
