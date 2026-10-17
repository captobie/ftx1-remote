# Raspberry Pi setup

Run the FTX-1 from a Raspberry Pi instead of plugging it into your computer. The
Pi sits next to the radio, connected by USB, and the FTX1Remote apps reach
it over your network (Tailscale works well for access from anywhere):

| Service | Port | What it does |
| --- | --- | --- |
| `rigctld` (Hamlib) | 4532 | Rig control: frequency, mode, menus, PTT |
| `ftx1-audiostream.py` | 8532 | Streams the rig's receive audio (Main = left, Sub = right) |
| `ftx1-txaudio.py` | 8533 | Plays transmit audio from the iPad into the rig; unkeys the rig if a client goes silent |
| `ftx1-cwkey.py` | 8534 | Straight-key CW from the Mac: plays the key's timing out and sets RTS/DTR on the rig's second USB port |

The Mac app uses the Pi in **Remote** mode; the iPad and iPhone apps can also
connect to it directly with **Pi direct**. The Pi sends audio to one client
at a time.

Any Pi that runs Raspberry Pi OS will do (tested on a Pi 2B with Raspberry
Pi OS 13 "trixie"). Use a good power supply: an under-powered Pi drops the
radio's USB connection, which shows up in the apps as timeouts.

## 1. Prepare the Pi

1. Install Raspberry Pi OS (Lite is fine), enable SSH, and log in.
2. Connect the FTX-1 to the Pi with a USB cable and turn the radio on.
3. On the radio, set the CAT-1 baud rate to **115200**.
4. Optional: install Tailscale so you can reach the Pi from anywhere:

   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   sudo tailscale up
   ```

5. Install the packages you need:

   ```bash
   sudo apt update
   sudo apt install -y build-essential python3-alsaaudio netcat-openbsd
   ```

## 2. Install Hamlib 4.7 or newer

The FTX-1 (Hamlib model 1051) needs Hamlib 4.7 or newer. Distribution
packages are often older, so build it from source. This takes a while on an
older Pi.

```bash
cd ~
wget https://github.com/Hamlib/Hamlib/releases/download/4.7.2/hamlib-4.7.2.tar.gz
tar xzf hamlib-4.7.2.tar.gz
cd hamlib-4.7.2
./configure --prefix=/usr/local
make -j"$(nproc)"
sudo make install
sudo ldconfig
```

Check that it knows the FTX-1:

```bash
LD_LIBRARY_PATH=/usr/local/lib /usr/local/bin/rigctld --version
LD_LIBRARY_PATH=/usr/local/lib /usr/local/bin/rigctld -l | grep 1051
```

## 3. Run rigctld as a service

Find the radio's CAT port. The FTX-1 shows up as a CP2105 dual serial
adapter; use the `if00-port0` entry:

```bash
ls -l /dev/serial/by-id/
```

Create a user for the service:

```bash
sudo useradd --system --no-create-home --groups dialout rigctld
```

Create `/etc/systemd/system/rigctld.service`, replacing the `-r` path with
the one you found above:

```ini
[Unit]
Description=Hamlib rigctld for Yaesu FTX-1
After=network.target

[Service]
Type=simple
User=rigctld
Environment=LD_LIBRARY_PATH=/usr/local/lib
ExecStart=/usr/local/bin/rigctld -m 1051 -r /dev/serial/by-id/usb-Silicon_Labs_CP2105_Dual_USB_to_UART_Bridge_Controller_XXXXXXXX-if00-port0 -s 115200 -t 4532 -o
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
```

The `LD_LIBRARY_PATH` line makes sure rigctld uses the Hamlib you just
built, not an older copy another package (such as Direwolf) may have
installed. Keep `-o`: the apps expect it.

Start it and check that it reads the radio's frequency:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now rigctld
printf 'f currVFO\n' | nc -q 1 localhost 4532
```

You should get the frequency in Hz.

## 4. Install the audio services

From your computer, in this repository, copy the files to the Pi
(replace `pi@ftx1pi` with your user and the Pi's hostname):

```bash
scp Pi/asound-ftx1.conf Pi/ftx1-audiostream.py Pi/ftx1-audiostream.service Pi/ftx1-txaudio.py Pi/ftx1-txaudio.service pi@ftx1pi:~/
```

Check the radio's sound card number on the Pi:

```bash
arecord -l
```

`asound-ftx1.conf` expects **card 1** (`hw:1,0`). If the radio's "USB Audio
Device" has a different card number, change both `hw:1,0` lines in
`~/asound-ftx1.conf` to match.

Then, on the Pi:

```bash
sudo cp ~/asound-ftx1.conf /etc/asound.conf
sudo useradd --system --no-create-home --groups audio ftx1audio
sudo mkdir -p /opt/ftx1remote
sudo cp ~/ftx1-audiostream.py ~/ftx1-txaudio.py /opt/ftx1remote/
sudo cp ~/ftx1-audiostream.service ~/ftx1-txaudio.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ftx1-audiostream ftx1-txaudio
```

If you already have an `/etc/asound.conf`, append the file's contents to it
instead of replacing it.

## 4b. Install the straight-key service (optional)

For the Mac's Tools → Straight Key in Remote mode. It keys the rig with RTS
or DTR on the radio's *second* USB serial port (CP2105 interface 1, the
"Standard COM Port"); rigctld keeps interface 0. Check the by-id name
(the `-if01-` one):

```bash
ls -l /dev/serial/by-id/
```

If its serial number isn't `01C7A9C5`, set `FTX1_CW_DEVICE` to that path
with an `Environment=` line in the unit. Then copy and install:

```bash
scp Pi/ftx1-cwkey.py Pi/ftx1-cwkey.service pi@ftx1pi:~/
```

```bash
sudo useradd --system --no-create-home --groups dialout ftx1cw
sudo mkdir -p /opt/ftx1remote
sudo cp ~/ftx1-cwkey.py /opt/ftx1remote/
sudo cp ~/ftx1-cwkey.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ftx1-cwkey
journalctl -u ftx1-cwkey -n 5
```

Look for `listening on :8534`. On the radio set CW SETTING → MODE CW →
**PC KEYING** to the line chosen in the Mac's window (RTS by default) and
**RPTT SELECT** to OFF. The port is only opened while the Mac is armed;
opening it briefly raises DTR/RTS before the script clears them. The
script's tests run anywhere: `python3 -m unittest discover -s Pi/tests`.

## 5. Check that everything runs

```bash
systemctl status rigctld ftx1-audiostream ftx1-txaudio
journalctl -u ftx1-audiostream -u ftx1-txaudio -n 20
```

Look for `listening on :8532` and `listening on :8533, playing into
ftx1_tx`. To check that receive audio is flowing, run this from another
machine. It should save about a second of audio:

```bash
nc ftx1pi 8532 | head -c 176400 > test.pcm
```

## 6. Connect the apps

- **Mac:** Settings → rigctld → Remote, enter the Pi's hostname, then restart
  the app when it asks.
- **iPad / iPhone:** choose **Pi direct** and enter the Pi's hostname.

Before you transmit audio from the iPad, set **MOD SOURCE** to **USB** on the
radio for each mode group you use (SSB, AM, FM, DATA), and set the level with
**USB MOD GAIN**, watching ALC.

## Optional: Direwolf

Direwolf can share the radio's audio with these services. In
`/etc/direwolf.conf`, set:

```
ADEVICE ftx1_shared ftx1_tx
```

then `sudo systemctl restart direwolf`. Without this, Direwolf holds the
sound card and the audio services fail with "Device or resource busy". Check
that Direwolf still decodes packets with `journalctl -u direwolf -f`.

## Troubleshooting

- **No reply from rigctld, or timeouts in the apps:** check `systemctl
  status rigctld`, that the radio is on, and the radio's CAT-1 baud rate. If
  the Pi's power supply is weak, `vcgencmd get_throttled` shows something
  other than `0x0` and `journalctl -k` shows USB disconnects. Replace the
  power supply, then power-cycle the radio and run `sudo systemctl restart
  rigctld`.
- **`Device or resource busy`:** another program has the sound card open.
  Point it at `ftx1_shared` (receive) and `ftx1_tx` (transmit) instead of
  `hw:1,0` or `plughw:1,0`.
- **`Permission denied [ftx1_shared]`:** an old ALSA config without
  `ipc_perm` was in use. Install the current `asound-ftx1.conf` and reboot the
  Pi.
- **Transmit audio fails with `unable to initialize sum ring buffer` /
  `Invalid argument [ftx1_tx]`** in `journalctl -u ftx1-txaudio` (the rig
  keys, then unkeys at once): `ftx1_dmix`'s `ipc_key` collides with the
  receive side's while an app holds the audio stream. Use the current
  `asound-ftx1.conf` (`ipc_key 4600`), then `sudo systemctl restart
  ftx1-txaudio` (and Direwolf, if it uses `ftx1_tx`).
- **The app says it's waiting for audio:** another client (Mac, iPad or
  Windows app) already has the audio stream. Disconnect it.
