---
name: FTX1Remote
description: A dense native operator's console for the Yaesu FTX-1, with lit instrument readouts on system chrome.
colors:
  lit-green: "#34C759"
  tx-orange: "#FF9500"
  signal-red: "#FF3B30"
  display-black: "#000000"
  glossy-accent-blue: "#4F8EF0"
  glossy-window-top: "#2C2F34"
  glossy-window-bottom: "#1C1D20"
  glossy-vfo-edge: "#9FC7E8"
  glossy-digits: "#E4F2FF"
  glossy-callsign-blue: "#6FB4FF"
  glossy-memory-amber: "#FFA040"
  rose-accent: "#7A453D"
  rose-vfo-bg: "#341E1B"
  mint-accent: "#1FA08B"
  mint-vfo-bg: "#123531"
  secondary-gray: "#8E8E93"
typography:
  vfo-digits:
    fontFamily: "SF Mono, Menlo, DSEG7 Classic, monospace"
    fontSize: "36px"
    fontWeight: 600
  callsign:
    fontFamily: "SF Mono, monospace"
    fontSize: "24px"
    fontWeight: 600
  readout:
    fontFamily: "SF Mono, monospace"
    fontSize: "13px"
    fontWeight: 600
  tag:
    fontFamily: "SF Pro, system-ui"
    fontSize: "10px"
    fontWeight: 400
  body:
    fontFamily: "SF Pro, system-ui"
    fontSize: "13px"
    fontWeight: 400
rounded:
  tag: "3px"
  meter: "6px"
  vfo-box: "8px"
spacing:
  tag-x: "4px"
  tag-y: "1px"
  vfo-x: "14px"
  vfo-y: "10px"
components:
  vfo-box:
    backgroundColor: "{colors.display-black}"
    textColor: "{colors.lit-green}"
    rounded: "{rounded.vfo-box}"
    padding: "10px 14px"
  meter-panel:
    backgroundColor: "{colors.display-black}"
    rounded: "{rounded.meter}"
  tag:
    rounded: "{rounded.tag}"
    padding: "1px 4px"
---

# Design System: FTX1Remote

## Overview

**Creative North Star: "The Rig Bench"**

FTX1Remote is a dense operator's console. Standard system controls (SwiftUI buttons, segmented pickers, sliders, popovers) form the chrome. Black, display-style panels sit inside it and carry the live rig state in lit colors. The chrome is quiet and native; the instruments are what the eye goes to. Mac and iPad show VFO, meters, filters and the MENU grid together, and the iPhone shows one receiver side at a time.

Themes change the chrome and the VFO box together. Default Light/Dark leave the system look as it is. Glossy Black, Dusty Rose and Icy Mint override button faces, window backgrounds and the VFO palette. iPhone and iPad are dark only.

**Key Characteristics:**
- Native controls, compact spacing, little decoration.
- Monospaced readouts for every number the operator reads.
- Lit-segment meters on black panels; color carries meaning (green receive, orange transmit, red over-S9 or hot).
- Inactive receivers dim to 45% instead of disappearing.
- Dense by decision: nothing core is hidden behind tabs on Mac or iPad.

## Colors

A system-native base with a small set of lit instrument colors. Hex values below are the themed presets' own; the default look uses system colors.

### Primary
- **Lit Green** (#34C759, system green): VFO digits by default, S-meter bars, receive state.
- **TX Orange** (#FF9500, system orange): transmit state and TX meters, plus the MENU grid's setting values by default (user-selectable among eight colors).
- **Signal Red** (#FF3B30): the hot end of a bar meter (over S9, high SWR).

### Secondary
- **Glossy Accent Blue** (#4F8EF0): toggled buttons and sliders in Glossy Black. Dusty Rose uses a mauve-rose (#7A453D), Icy Mint a teal (#1FA08B).

### Neutral
- **Display Black** (#000000): VFO box and meter panel background in the default look.
- **Secondary Gray** (#8E8E93): captions, tag outlines, inactive borders (system secondary).
- Themed VFO panels: Glossy Black fades from near-black to #050506 with an icy edge (#9FC7E8) and icy digits (#E4F2FF); Dusty Rose uses a dark mauve (#341E1B); Icy Mint a dark teal (#123531). Callsigns are blue (#6FB4FF in Glossy Black), memory channels amber (#FFA040).

### Named Rules
**The Lit Means Live Rule.** Saturated color appears only on live readouts, active toggles and state (TX, scanning, APRS). Static chrome stays neutral.

**The Dim Not Hide Rule.** A receiver that isn't shown dims to 45% opacity; it never vanishes or reflows the box.

## Typography

**Display/Readout Font:** SF Mono (Menlo fallback), or bundled DSEG7 Classic when the 7-segment option is chosen.
**Body Font:** system (SF Pro) for labels, captions and controls.

**Character:** Monospace for anything numeric, system sans for anything verbal. The pairing reads like a rig's front panel: fixed-width digits, small plain labels.

### Hierarchy
- **VFO Digits** (semibold, 36pt, monospaced): the frequency. Fixed size, never scaled.
- **Callsign** (semibold, 24pt, monospaced): decoded C4FM/APRS callsign. Fixed size, never scaled.
- **Readout** (semibold, callout, monospaced): S-meter and TX meter values.
- **Tag** (caption/caption2): MAIN/SUB, TXRX, mode, CH in outlined boxes.
- **Body** (system): control labels and settings.

### Named Rules
**The Fixed Digits Rule.** Frequency and callsign never use `minimumScaleFactor` or flexible frames; a callsign appearing must not shrink the frequency.

**The English Rig Terms Rule.** Radio labels (MAIN, SUB, PTT, V/M, BK-IN, MENU items) stay English in every locale.

## Layout

Mac: several windows (main, CW, APRS, FT8, Memory List, WebSDR) with a dense main window. Iconic rows: VFO boxes side by side (SUB left, MAIN right), meter strips under them, then filters and the MENU grid. iPad: one dense screen that adapts between portrait and landscape (`ViewThatFits`); APRS and CW panes replace the filter block and grid in place. iPhone: single column, one side (MAIN or SUB) at a time with a band/mode/power row.

The VFO box has three fixed rows (tags, indicator line with reserved height, callsign plus frequency) so its size never changes with state. Tight spacing: 14pt horizontal, 10pt vertical box padding.

## Elevation & Depth

Flat and tonal. At rest, surfaces are system materials. Depth comes from dark inset instrument panels against lighter chrome. Only the Glossy Black theme adds lit gradients (a lighter top half stepping down, plus a light top edge) on buttons and windows. There are no drop shadows.

### Named Rules
**The Inset Instrument Rule.** Readouts sit as dark insets in lighter chrome; they are never raised cards.

## Shapes

Small, restrained radii: 3pt for tags, 6pt for meter panels, 8pt for VFO boxes. Tags are outlined 1pt boxes (filled only for TX/RX state). Meters are segmented bars with 1pt rounded segments; unlit segments show at 15% opacity.

## Components

### VFO Box
- **Shape:** 8pt radius, black (or themed) gradient fill, 1pt border that is bright when active and gray when not.
- **Content:** tag row, indicator line, callsign left, frequency right.
- **State:** dims to 45% when its receiver isn't shown.

### Bar S-Meter
- **Style:** segmented bar on a black 6pt panel, S0 to S9 in the first 60%, over-S9 red. Readout in monospace ("S7", "S9+12").
- **TX:** while transmitting, shows the chosen TX meter (PO default) in orange; tap to pick.

### Tags
- **Style:** 3pt-radius outlined box in secondary gray at 50%; filled for TX/RX.

### MENU Grid Button
- **Style:** two-line label: function name in the primary color, current setting in the user-chosen value color (orange default), as on the rig's own display.
- **Controls:** standard bordered buttons; themed faces under Glossy Black, Dusty Rose and Icy Mint. Use `ThemedButtonStyle` for new buttons.

### Pickers and Sliders
- **Style:** system segmented controls and sliders, tinted with the theme accent. Commands go out on drag release, not per tick.

## Do's and Don'ts

### Do:
- **Do** use monospaced type for every number the operator reads.
- **Do** keep core controls visible together on Mac and iPad.
- **Do** use themed button styles and `.themedSecondaryForeground()` for new Mac controls.
- **Do** dim inactive state rather than removing it.
- **Do** route anything that can transmit through the transmit gate and show why a control is disabled.

### Don't:
- **Don't** scale or squeeze the frequency or callsign.
- **Don't** hide primary controls behind tabs on Mac or iPad.
- **Don't** add drop shadows or raised cards for instruments.
- **Don't** theme the TX/RX tags, PTT, meters or status colors.
- **Don't** translate radio terms.
