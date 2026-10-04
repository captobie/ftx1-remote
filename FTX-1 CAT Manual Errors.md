# FTX-1 CAT Manual Errata

Oct 4, 2026 · @Carl

## Summary

We found 9 places where the FTX-1 CAT Operation Reference Manual disagrees with the real radio, and about a dozen rig behaviors the manual never mentions. Each was found while building FTX1Remote, between 2026-07-11 and 2026-10-03, by sending raw CAT commands through rigctld and checking the reply against the radio's own display.

The errors fall into four kinds:

- **Wrong value mapping**: the manual lists the wrong values, not just mislabeled ones (PR, CW WEIGHT, AC).
- **Wrong digit width**: a field's printed Digits column is too narrow for its own range (AUTO POWER OFF, DCS CODE).
- **Wrong range or step**: MC channel range, VD step size, HF MAX POWER upper bound.
- **Misleading table layout**: EXTENSION SETTING's MY POSITION block sits on the wrong P2 tab.

## Confirmed errors

Every row below was checked against the radio, apart from DCS CODE: that one is wrong on paper, because 104 codes can't fit in 2 digits.

| # | Command / item | Manual says | Radio actually does | How we confirmed it | Found |
| --- | --- | --- | --- | --- | --- |
| 1 | `PR` P1=1, Parametric MIC EQ on/off | P2: 1 = OFF, 2 = ON | Plain 0 = OFF, 1 = ON. A cold read returned `0`, a value the manual doesn't list. | `nc` probe, then toggled `PR10;`/`PR11;` and checked the rig display each time | 2026-08-29 |
| 2 | `AC` antenna tuner control, P1 | P1=0 is the internal tuner (FTX-1 Optima) | On an Optima with the internal tuner, P1=0 does nothing. P1=1 ("External Antenna Tuner") is the one that works. | Front-panel tuner state after each write | Aug 2026 |
| 3 | `EX 02-02-03` CW WEIGHT | P4 = weight × 10 (25–45 for 2.5–4.5) | P4 is an offset from 2.5 in 0.1 steps: 00 = 2.5, 20 = 4.5 | Read returned `05` while the rig's MENU showed 3.0 | 2026-08-15 |
| 4 | `EX 04-01-07` AUTO POWER OFF | Digits = 1. The value cell ("0: OFF 1: 0.5 - 24: 12 (hour)") is too condensed to parse. | 2 digits. 00 = OFF, 01–24 = 0.5–12 h in 0.5 h steps. | Compared against the rig's own display | Aug 2026 |
| 5 | `EX 01-03-22` DCS CODE | Digits = 2 | 104 codes (000–103) need 3 digits | Internal contradiction, caught by a unit test | Aug 2026 |
| 6 | `EX 05-xx` EXTENSION SETTING layout | The MY POSITION block is printed under P2=01 (DATE&TIME), with P3 continuing 08–10 | MY POSITION is its own tab, P2=02, with P3 starting again at 01. SD CARD, SOFT VERSION, CALIBRATION and RESET each move up one, to P2=03–06. | `EX050109` → `?;`, while `EX050201` → `0` and `EX050202`/`03` → latitude and longitude | 2026-08-16 |
| 7 | `MC` memory channel range | 00001–00099 | 1–999. The manual's own `MR`/`MW`/`MZ` entries say 00001–00999. | User's rig has 278 programmed channels, all selectable | 2026-09-29 |
| 8 | `VD` VOX delay step | "10 msec multiples" | 100 ms steps, the same 00–33 code table as `SD` (BK-DELAY) | Stepped VOX DELAY and compared with the rig | Aug 2026 |
| 9 | `EX 03-05-03` HF MAX POWER (TX GENERAL) | Range 005–010 | Upper bound is 100, not 010 | User confirmed on the rig | 2026-08-16 |

On row 9, the unit is whole watts: 100 means 100 W, confirmed by the user on their FTX-1 Optima. That means the document-only audit was wrong to read TX GENERAL rows in 0.1 W units, at least for HF MAX POWER.

## Undocumented behavior

None of these are errors in what the manual says. They are things the radio does that the manual leaves out, and each one cost us a debugging session.

| Command / area | What the radio does | Found |
| --- | --- | --- |
| `VM0` to Memory mode | `VM011` fails silently unless `MC0` is written just before it, even if it's written back to the channel it already holds | 2026-09-08 |
| `MR00000` ("read VFO") | In Memory mode it returns the *active memory channel's* contents, not the parked VFO | 2026-09-08 |
| `SH` WIDTH with NARROW | In SSB/CW/RTTY/DATA the `SH` index doesn't change when NAR is on. The real bandwidth is that mode's NAR WIDTH menu preset. | 2026-09-13 |
| `KM` keyer memory | Holds exactly 50 characters and appends the `}` end marker itself. More than 50 gets `?;` and leaves the memory unchanged. `KM<n>;` alone is a read, so a slot can't be emptied. | 2026-10-02 |
| `KY` keyer playback | Transmits only with BK-IN on. With BK-IN off you get a brief mute, no TX and no sidetone. A second `KY` during playback restarts the message, and `KY00` stops it at once. | 2026-10-02 |
| `KM` character set | Keys A–Z, 0–9 and `/ ? , . = + - ( ) @ :`. Prosigns go in as `=` (BT), `+` (AR), `(` (KN). | 2026-10-02 |
| `MD` in C4FM | Answers `H` (C4FM-DN). The manual lists `H` and `I` (C4FM-VW) but not how they differ. | 2026-09-04 |
| `GT0` in C4FM | Goes unanswered on every read | Sept 2026 |
| `BP1` (Sub notch frequency) | In a mode without a notch, Sub can answer a non-numeric value such as `F35` | 2026-09-19 |
| USB audio | Stereo in dual receive: Main on the left channel, Sub on the right. The channels stay with the physical receiver across a front-panel swap. An `SV` swap moves them in dual receive but not in single receive. | 2026-09-18/19 |
| `RM` meters | Raw 0–255 with no calibration to S-units, dB, amps or volts | Sept 2026 |

**No CAT command at all**, checked against the full CAT manual, Table 3, the WIRES-X Edition manual and hamlib's Yaesu backend:

- D-COLOR (SSB MENU page)
- DG-ID TX, DG-ID RX, HRI MODE (FM/C4FM MENU page)
- HOME channels: they can't be read or recalled, so the app keeps its own copy
- MAG, Memory Auto Grouping
- Any WIRES-X setting, a feature newer than the manual's firmware revision

## Suspected, not yet verified

These look wrong on paper but haven't been read back from the radio. Most come from the document-only audit (`ftx1-cat-manual-errata.md`, pushed 2026-10-04), which compares CAT manual 2508-C with Advanced Manual 2506-B.

- **`EX` P1/P3 ranges**: the command page says P1 01–07 and P3 01–26. Table 3 itself goes up to P1=11 and P3=37.
- **`EX 03-05-04` 50M MAX POWER**: printed 005–010, the same pattern as confirmed error 9.
- **`EX 01-03-18/19` RPT SHIFT (144/430 MHz)**: "0–100 MHz" with P4 0000–0100 at 50 kHz/step. That can't all be true. The app shows a raw step count for now.
- **`OS` repeater shift order**: the `OS` page gives 0 Simplex, 1 +, 2 −, 3 ARS. Table 3 gives 0 −, 1 Simplex, 2 +, 3 ARS. The app follows the `OS` page.
- **SPEED UNIT / WIND UNIT**: the enums skip values (mph = 3 and 2).
- **RF/SQL VR and TUN/LIN PORT SELECT**: option labels differ between the CAT and Advanced manuals. The `GP` page names a factory value, "OPTION", that isn't in the table.
- **MIC UP / MIC DOWN (`EX 03-06`)**: the value column is blank, so the encoding is unknown.
- **`VM` listed twice**: the second detail entry is the real one. The first, "MAIN-SIDE TO MEMORY CHANNEL", looks like a copy-paste.
- **`EO` ENCODER OFFSET**: has a detail page but is missing from the command index.

## Method and sources

We sent each command as raw CAT through rigctld's `W` passthrough, mostly by hand with `nc` against port 4532. We then compared the reply, or the effect of a write, with the radio's front-panel display. Two apparent gaps in Table 3, at APRS DESTINATION (`EX060106`) and MSG FIL. (`EX0805`), turned out to be our own misreadings of a dense scan, not manual errors. They're left out above.

The Deep Settings catalog was transcribed from the 2507-A CAT manual. The audit used 2508-C. CAT control needs MAIN firmware 1.08 or later.

The evidence lives in code comments next to each fix:

- `Sources/FTX1Core/MenuSettings/DeepSettingsCatalog.swift`: CW WEIGHT, AUTO POWER OFF, DCS CODE, MY POSITION, HF MAX POWER
- `Sources/FTX1Core/Commands/CommandQueue.swift`: PR, AC, VM/MC
- `Sources/FTX1Core/RigState/RigState.swift`: MC range, VD step
- `Apps/Mac/FTX1RemoteMac/HubService.swift`: MR00000
- `Sources/FTX1Core/UI/MenuPageView.swift`: commands that don't exist
- `CLAUDE.md`, "Digital modes — CW": KM/KY behavior
