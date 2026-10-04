# FTX-1 Manual Errata (document-only audit)

**Sources checked:** CAT Operation Reference Manual 2508-C (CAT), Advanced Manual 2506-B (AM), Operating Manual 2506E (OM, spot checks only).
**Method:** Table 3 (MENU Chart, CAT pp. 10–16), the EX command definition (CAT p. 9), and the command index/detail pages were read end to end and compared with each other and with the AM menu tables.
**Not done:** None of this has been checked against the radio. Every item below is a document-vs-document finding. The "Hardware check" column says how to confirm each one with `readMenuItem` or a front-panel toggle.

Page numbers are the printed page numbers in each manual.

Confidence key: **High** = the manual contradicts itself or another Yaesu manual in a way that can't both be right. **Medium** = very likely wrong but the correct value is a guess. **Low** = ambiguous or possibly intentional.

---

## 1. Digit-width and range errors (these affect `EX` encoding)

| # | Item | What the manual says | Problem | Likely correct | Conf. | Hardware check |
|---|------|----------------------|---------|----------------|-------|----------------|
| 1 | EX command definition (CAT p. 9) | P1 = 01–07, P3 = 01–26 | Table 3 uses P1 up to 11 (BLUETOOTH) and P3 up to 37 (MODE FM → DTMF MEMORY10). P1 = 10 is never used. | P1 01–11 (sparse), P3 01–37 | High | Don't clamp P1/P3 to the printed ranges. Read `EX110101;`. |
| 2 | 04-01-07 AUTO POWER OFF (CAT p. 13) | `0: OFF 1: 0.5 - 24: 12 (hour)`, Digits = **1** | Value 24 needs two digits. AM says "OFF / 0.5–12 hour, 0.5 h/step" = 25 values (0–24). | Digits = 2 | High | Set 12 h on the radio, read back: expect `24`. |
| 3 | 03-05-03 HF MAX POWER (TX GENERAL; CAT p. 12) | `005 - 010` | Every other TX GENERAL row is in 0.1 W units (70M `005-060` = 6.0 W, AM `005-025` = 2.5 W, 144M/430M `005-100` = 10.0 W). AM says HF is 0.5–10.0 W. `005-010` would be 0.5–1.0 W. It looks copied from the PC command's field-head range (`005-010` W). | `005 - 100` | High | Read at the 10 W setting: expect `100`. |
| 4 | 03-05-04 50M MAX POWER (CAT p. 12) | `005 - 010` | Same as above; AM says 0.5–10.0 W. | `005 - 100` | High | Same as above. |
| 5 | 01-03-16/17/18/19 RPT SHIFT (28/50/144/430 MHz; CAT p. 10) | 28 M `0–1000 kHz (P4 0000–1000, 10 kHz/step)`; 144/430 M `0 - 100MHz (P4 = 0000 - 0100, 50 kHz/step)` | 144/430 M row is internally impossible: 100 MHz shift, and P4 0100 at 50 kHz/step would be 5 MHz. AM repeats the "100 (MHz)" text (and AM's 430 MHz default is 5.00 MHz). Units are inconsistent between the 28/50 rows (kHz) and the 144/430 rows. | Unknown. Probably P4 in 10 kHz units, so 0100 = 1.00 MHz, or 50 kHz steps up to 5.00 MHz. | Medium | Read at a known shift (e.g. 600 kHz on 144, 5.00 MHz default on 430) and see what P4 comes back. |
| 6 | MY POSITION LATITUDE/LONGITUDE (CAT p. 13) | Digits `-`, format `x xx°xx' xx"` | No usable encoding given. AM shows `N 00° 00.00'(00")`. | Unknown | Low | Read and log the raw string. |
| 7 | Device Name : Status (BLUETOOTH, P1=11; CAT p. 16) | Digits `1`, P4 `-` | A device name can't be one character; this is probably a read-only text field. | Unknown | Low | Read and log. |

---

## 2. Value-mapping errors (enumerations)

| # | Item | Manual says | Problem | Conf. | Hardware check |
|---|------|-------------|---------|-------|----------------|
| 8 | SPEED UNIT (CAT p. 13) | `0: km/h 1: knot 3: mph` | Skips 2. AM lists exactly three options (km/h / knot / mph). | High that the numbering is wrong. Medium that mph = 2. | Toggle each unit, read the index. |
| 9 | WIND UNIT (CAT p. 13) | `0: m/s 2: mph` | Skips 1. AM lists only two options (m/s / mph). Same pattern as SPEED UNIT, so the radio's enum may be shared and the manual may be printing real internal values. | Medium | Toggle and read. If mph really returns 2, then the manual is right and the gap is by design. |
| 10 | ANT2 OPERATION (CAT p. 13) | `0: TRX 1: TX-ANT1, RX-ANT2 2: TRX-ANT1, RX-ANT2` | Option 2 reads like option 1 with "TX" changed to "TRX". The AM list for this item ends in a dangling `/`, which suggests a fourth value was dropped in print. | Medium | Cycle all options on a radio with ANT2 and count them. |
| 11 | RF/SQL VR (CAT p. 12) | `0: RF 1: SQL 2: SQL (FM MODE only)` | AM says `RF / SQL / AUTO`. Option 2 is named AUTO in one manual and "SQL (FM only)" in the other. | High that labels disagree | Toggle and read. |
| 12 | TUN/LIN PORT SELECT (CAT p. 12) | `0: EXT-TUNER 1: LINEAR 2: CAT-3 3: GPO` | AM says `OPTION / BAND DATA / CAT-3 / GPO`. The CAT manual's own GP command page says the factory setting is "OPTION", a value that does not exist in its own table. | High | Read the factory value, expect `0`. Cycle and note the labels. |
| 13 | TUNER SELECT (CAT p. 12) | 4 values: `INT / INT(FAST) / EXT / ATAS` | AM lists only `OPTION / ATAS` here, but lists the 4-value set under OPTION → TUNER TYPE SEL ANT1/ANT2. P1/P2/P3 = 03-01-04 may be a different menu item with the same 4-value list. | Medium | Compare reads of 03-01-04 and 03-07-01. |
| 14 | MOD SOURCE and RPTT SELECT in PRESET1–5 (CAT p. 15) vs. per-mode MOD SOURCE (CAT pp. 10–11) | Presets: `2: REAR (RTTY/DATA Jack)`, RPTT adds `3: DAKY`. Modes: `2: Bluetooth`. | Same menu name, different value 2. It may be legitimate (presets cover the rear jack), but AM only documents the per-mode list. | Low | Read both after selecting each option. |
| 15 | MIC P1–P4 / MIC UP / MIC DOWN (CAT p. 12) | One shared list: `02:>/<` | AM calls this function `A/B`. The shared list is also laid out as one row for six menu items; the P3 numbers (08–13) are ambiguous in print. | Medium | Read 03-06-08…13. |
| 16 | FM DIAL STEP (AM) vs. CAT | AM: `5 / 10 / 20 / Auto (Hz)`. CAT: `0: 5 1: 6.25 2: 10 3: 12.5 4: 20 5: 25 (kHz) 6: Auto`. | AM has the wrong unit (Hz, should be kHz) and drops 6.25, 12.5 and 25. | High | Read all 7 values. |
| 17 | DTMF MEMORY count | CAT: DTMF MEMORY1–10 (P3 = 28–37). AM: "DTMF MEMORY1 - 9". | Count disagrees. | Medium | Read P3 = 37 on FM (01-03-37). If it answers, CAT is right. |

---

## 3. Command index and detail page problems

| # | Item | Problem | Conf. |
|---|------|---------|-------|
| 18 | `VM` (index CAT p. 5; detail section near the end of the command pages) | Index lists `VM` twice with different flags (`O X X X` and `O O O O`). The detail section also has two entries: the first is titled "MAIN-SIDE TO MEMORY CHANNEL", has no parameters and no Answer format, and looks like a copy of the `AM` entry. The second ("VFO / MEMORY CHANNEL", P1 side, P2 mode) is the real one. | High |
| 19 | `EO` ENCODER OFFSET (CAT p. 9) | Has a full detail page but is **absent from the command index**. | High |
| 20 | Command titles differ between index and detail pages | e.g. `SD` "SEMI BREAK-IN DELAY TIME" vs "CW BREAK-IN DELAY TIME"; `SF` "SUB DIAL" vs "FUNC KNOB FUNCTION"; `KM` "KEYER MEMORY" vs "KEYING MEMORY"; `CT` "CTCSS" vs "SQL TYPE"; `CF` "CLAR (Clarifier)" vs "CLAR ON/OFF"; `VX` "VOX" vs "VOX STATUS"; `DN`/`UP` "DOWN"/"UP" vs "MIC DOWN"/"MIC UP". | High (labels only) |
| 21 | `GT` AGC FUNCTION | Set takes P1 P2 (value 0–4), Answer returns P1 P3 (value 0–6, with AUTO-FAST/MID/SLOW). May be real asymmetry. | Low. Worth one read/write round-trip. |
| 22 | `RM` READ METER | Index says Set = X, but the detail page shows a "Set" row with `P1=0`. The `P1=0` variant (both meters) is documented only in that row. | Low |

---

## 4. Hardware and wording inconsistencies

| # | Item | Problem | Conf. |
|---|------|---------|-------|
| 23 | USB jack location | The CAT manual's overview section says the CAT USB jack is on the **side panel**. AM p. 40 (MOD SOURCE) says "USB jack on the field head" for USB and "USB jack on the **rear panel**" for the AUTO entries (CAT/RTS/DTR) in the same paragraph. Repeated in the AM's other MOD SOURCE sections. | High |
| 24 | USB audio omitted from the CAT manual | The CAT manual describes the USB port only as a dual-UART bridge and never mentions that it also carries USB audio, which the app and WSJT-X use. | High (omission) |
| 25 | WIRES-X and other post-firmware features | Not present in any of the three CAT revisions (2306, 2507, 2508) we've seen. CAT requires MAIN firmware ≥ 1.08. | High (omission) |
| 26 | Settings units differ across menu groups | TX GENERAL max power rows are in **0.1 W** units. OPTION max power rows (SPA-1/100 W amp) are in **whole watts** (`005-100` = 5–100 W). The `PC` command is also whole watts (`005-010` field head, `005-100` SPA-1). This is not an error but it's an easy encoding trap. | Note |

---

## 5. Typos (cosmetic, no behavior impact)

- `QSK DELAY TIME`: "25 **mesc**" (CAT p. 11)
- `MY SYNBOL` for MY SYMBOL (CAT p. 14)
- `Bycycle` in Table 4 (CAT p. 16)
- `17 ATT` missing colon in the MIC key list (CAT p. 12)
- `MY POSITION LONGTUDE` (AM)
- Not errors: Table 4 lists some symbols twice (`/U` and `/u` both "Bus", `/V` and `/v` both "ATV"). Those are normal APRS symbol-table aliases.

---

## 6. Suggested hardware verification order (cheapest first)

1. **Read-only, no front-panel changes needed:** #1 (EX P1/P3 ranges), #17 (DTMF MEMORY10), #6, #7, #22 (log raw strings).
2. **One toggle each:** #2 (AUTO POWER OFF 12 h → expect `24`), #3/#4 (set max power to 10.0 W → expect `100`), #8/#9 (unit enums), #11/#12/#13/#16 (cycle options, record numbers).
3. **Needs the right radio state:** #5 (set a known repeater shift), #10 (ANT2 radio), #15 (MIC keys).

Treat anything in sections 1–2 as "documented value, unverified" in `DeepSettingsCatalog.swift` until it's been read back from the radio. A per-item `verified: true/false` flag in the catalog would let the UI hide or warn on unverified entries.

---

## 7. Snippet for CLAUDE.md

```
## FTX-1 CAT manual (2508-C) is unreliable. Do not treat as authoritative.
Known/suspected errors are listed in docs/ftx1-cat-manual-errata.md.
- Do not clamp EX P1/P3 to the printed ranges (01-07 / 01-26). Real values go to P1=11, P3=37.
- AUTO POWER OFF needs 2 digits (values to 24), not 1.
- TX GENERAL HF/50M MAX POWER: the printed 005-010 is almost certainly 005-100 (0.1 W units).
  OPTION max-power rows and the PC command are whole watts.
- SPEED UNIT / WIND UNIT enums skip values (mph = 3 / 2 in print). Verify on hardware.
- RPT SHIFT 144/430 MHz range text is self-contradictory. Verify before exposing.
- Menu labels in the CAT manual and Advanced Manual sometimes disagree (RF/SQL VR, TUN/LIN PORT SELECT).
  Prefer labels observed on the radio.
- Any Deep Settings item not read back from hardware is unverified.
```
