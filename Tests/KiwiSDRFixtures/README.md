# KiwiSDR protocol fixtures

Binary WebSocket frames captured 2026-11-10 from a KiwiSDR 2, firmware
v1.902, by a scratch probe (phase 0 of the Local SDR feature). For the
parser tests of the native KiwiSDR client. Frames only: no server
messages, no configuration.

Sound stream (`/<timestamp>/SND`): `"SND"`, flags (1 byte), sequence
(UInt32 LE), S-meter (UInt16 BE; dBm = 0.1 × value − 127), then samples.

| File | Flags | Contents |
|---|---|---|
| `snd-pcm-1-newfreq.bin` | 0x05 (LPF, NEW_FREQ) | first frame, 512 Int16 BE samples, 14074 kHz USB |
| `snd-pcm-2.bin` | 0x00 | next frame |
| `snd-pcm-retune.bin` | 0x05 | first frame after `SET mod=lsb … freq=7074.000` |
| `snd-adpcm-1…3.bin` | 0x15, 0x10, 0x10 | three consecutive IMA ADPCM frames, 1024 bytes = 2048 samples each |

Waterfall stream (`/<timestamp>/W/F`): `"W/F"`, one byte, x_bin (UInt32
LE), flags << 16 | zoom (UInt32 LE), sequence (UInt32 LE), then 1024
bytes (uncompressed, `SET wf_comp=0`; dBm = byte − 255 + wf_cal).

| File | Contents |
|---|---|
| `wf-zoom0.bin` | zoom 0, x_bin 0 (0–30 MHz) |
| `wf-zoom8.bin` | zoom 8, x_bin 3923300 (7015.4–7132.6 kHz; bin 512 = 7074.0 kHz) |

x_bin counts bins at the maximum zoom (14): Hz = x_bin × 30 MHz /
(1024 × 2^14). One displayed bin at zoom z is 2^(14 − z) of them.
