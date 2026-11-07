# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Users

Primary: the owner, an amateur radio operator with a real Yaesu FTX-1 at home, who monitors and controls it from a Mac at the desk or remotely from iPad/iPhone over Tailscale. Secondary: other FTX-1 owners who download the Mac/Windows app or join the iPad beta. Single-user tool: no multi-user auth or permissions unless explicitly requested.

## Product Purpose

Remotely control and monitor a Yaesu FTX-1 transceiver without being next to it. The rig connects by USB (to the Mac or a Raspberry Pi); the Mac app is the hub that talks to hardware, and iPad/iPhone are network clients (via the Mac hub or directly to the Pi). Success is the operator tuning, listening, filtering, logging and transmitting as if at the rig.

## Positioning

A native Mac/iPad/iPhone (plus Windows) remote for the FTX-1 that exposes the rig's own menu grid, deep settings, filters, dual Main/Sub receivers and audio. It also adds digital modes (FT8/FT4, CW, RTTY/PSK, APRS), logbook integration and WebSDR follow. It is built on hamlib's rigctld plus raw CAT.

## Operating Context

Operators work in long sessions, often beside the rig, with the app's windows open together. Remote use over Tailscale and on mobile networks is normal. Transmit actions have real-world and regulatory consequences, so they are gated (Enable Transmit lock, amateur-band and license-class checks). Demo Mode exists for App Review and users without hardware.

## Capabilities and Constraints

- Mac app is the hub (rigctld, WebSocket server on 8765); iPad/iPhone connect through it or directly to the Pi ("Pi direct").
- Views shared across targets go through the `RigController` protocol.
- Separate layouts per device are a settled decision: Mac dense multi-window, iPad dense single screen, iPhone focused single-side view. The iPad and iPhone are separate targets, not size classes.
- High-rate state (audio frames, meters) must not trigger whole-window re-renders.
- Radio terms and rig labels stay in English (MAIN/SUB, PTT, V/M, BK-IN, MENU items); other UI strings are localized (en, es, de). Frequencies never follow the locale.
- Any control that can transmit must pass the shared transmit gate.
- iPhone and iPad are dark only; the Mac has themes (Default Light/Dark, Glossy Black, Dusty Rose, Icy Mint).

## Brand Commitments

Binding constraint: dense, everything-visible layouts on Mac and iPad (VFO, meters, filters and MENU grid on screen together), not hidden behind tabs. No other visual direction is recorded.

## Evidence on Hand

Real FTX-1 hardware, a Pi with rigctld/audio, a Windows test PC, TestFlight and Sparkle release pipelines, and Demo Mode. No testimonials, customer data or usage metrics exist; do not fabricate any.

## Product Principles

1. Safety before convenience for anything that transmits.
2. Show the rig's real state at a glance; dense beats sparse for operators who know the radio.
3. Each device gets the layout that suits it, not a shrunken copy of the Mac.
4. Connect only on explicit user action; never auto-connect to external services.
5. Tell failure causes apart (Pi unreachable vs radio down) rather than showing a generic error.

## Accessibility & Inclusion

No specific standard recorded. UI is localized in English, Spanish and German; native-platform accessibility conventions apply.
