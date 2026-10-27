# Spanish/German translation review

Phase 2 of localization (2026-10-27) added `es` and `de` to every String
Catalog. The translations were machine-written and haven't been reviewed by a
native speaker yet. This list covers the choices a native speaker
(ideally a ham) should check first. Everything else is a straight
translation.

Conventions used throughout:

- **No Sie/du, no tú/usted.** German uses the infinitive ("Rufzeichen
  eintragen", "Zum Senden gedrückt halten"). Spanish uses the infinitive
  or an impersonal form ("Introducir el indicativo…"). "Your callsign"
  became "Eigenes Rufzeichen" / "Indicativo propio".
- **Radio terms stay English**: MAIN/SUB, VFO, PTT, MOX, BK-IN, CW, SSB,
  APRS, QSO, WPM, CAT, SWR, ALC, RF, Notch, Shift, Contour, APF, Squelch,
  Break-in, Keyer, Paddle, the rig's own menu labels (CW SETTING → MODE CW
  → PC KEYING …), and product names (Wavelog, MacLoggerDX, KiwiSDR,
  WebSDR, OpenWebRX, PSK Reporter, Tailscale, rigctld, Hamlib).
- **"Settings"** = "Einstellungen" / "Ajustes" (Apple's own words on
  macOS and iOS). The Settings tabs are translated, and every "Settings →
  X" path in other strings uses the translated tab name.
- Frequencies always stay in dotted form (`FrequencyFormat`), whatever
  the language.

## Terms used throughout — check these first

| English | German | Spanish | Why it's a judgment call |
|---|---|---|---|
| rig | Gerät / Funkgerät | equipo | de: "Gerät" in running text, "Funkgerät" where it stands alone. es: "equipo" is the usual ham word in Spain; Latin America also says "radio" or "rig". |
| Their call | Gegenstation | Corresponsal | A short field label. es "corresponsal" is the QSO partner; "Indicativo del corresponsal" would be clearer but long. |
| grid square | Locator | cuadrícula | de hams say "Locator" (QTH-Locator). es: Spain often says "locator", the Americas "grid"; "cuadrícula" is neutral but less common. |
| Logbook (Settings tab) | Logbuch | Libro de guardia | es: "libro de guardia" is the traditional term but long for a tab; "Log" or "Registro" are alternatives. |
| log (verb) | loggen | registrar | de "loggen" is ham slang; "eintragen" is the formal alternative. |
| keyer | Keyer | keyer | Kept English in both. Alternatives: de "Elbug", es "manipulador (electrónico)". |
| keying / keying port | Tastung / Tastport | manipulación / puerto de manipulación | |
| key interface | Tasten-Interface | interfaz de llave | |
| straight key | Handtaste | llave vertical | |
| armed / disarm | scharf / entschärfen | armado / desarmar | de "scharf schalten" sounds like weapons; "aktiviert/deaktiviert" is a softer option. |
| sidetone | Mithörton | tono local | |
| Monitor (send-pane button) | Mithören | Monitor | |
| Transmit / Enable Transmit | Senden / Senden erlauben | transmisión / Permitir transmisión | |
| Transmit disabled | Senden gesperrt | Transmisión desactivada | |
| memory scan / Scan | Speicherscan / Scan | exploración de memorias / Explorar | es "exploración" vs "escaneo". |
| Skip | Überspringen | Saltar | |
| Memory mode | Speichermodus | modo memoria | |
| Waterfall | Wasserfall | Cascada | |
| Hub (Mac/desktop hub) | Mac-Hub / Desktop-Hub | hub del Mac / hub de escritorio | Kept "hub". |
| Pi direct | Pi direkt | Pi directo | |
| Phone / Data (emissions) | Sprechfunk / Daten | Fonía / Datos | |
| Privileges (license) | Berechtigungen | Privilegios | |
| Custom (license table) | Eigene | Personalizado | |
| Polling (Settings tab) | Abfrage | Sondeo | |
| prosigns | Betriebszeichen | prosignos | |
| Done (sheet button) | Fertig | OK | Apple's macOS/iOS Spanish uses "OK" for Done; "Listo" is the alternative. |

## Individual strings

| Key | English | Choice | Note |
|---|---|---|---|
| `cwLogPane.on` | On (the QSO's start time) | de "Beginn", es "Inicio" | The English means "time on". |
| `settings.homeFreq` | Home Freq | de "HOME-Freq.", es "Frec. HOME" | Kept the rig's HOME key name. |
| `content.memList` | Mem List | de "Speicherliste", es "Lista mem." | A narrow button; check that it fits on the Mac. |
| `common.utility` | Utility (band-segment kind) | de "Funkdienste", es "Servicios" | Means non-amateur, non-broadcast services. |
| `memoryList.shift` | Shift (repeater offset column) | de "Ablage", es "Desplaz." | de "Ablage" is the usual repeater term. Not the IF-shift control, which stays "Shift". |
| `filterWidthControl.width` / `ifShiftControl.center` | Width / Center | de "Breite"/"Mitte", es "Ancho"/"Centro" | Translated, while Notch/Shift/Contour stay English. Maybe keep these English too, to match the rig's front panel. |
| `cwReceiverControls.rigPitch` | Rig Pitch | de "Pitch des Geräts", es "Tono del equipo" | de keeps "Pitch" (the rig's KEY PITCH). |
| `straightKey.invertedPolarityLineCleared` | line cleared = key down | de "Leitung inaktiv", es "línea desactivada" | RTS/DTR "cleared". |
| `straightKey.holdingTheLineUp` | Holding the line up | de "Leitung wird offen gehalten", es "Manteniendo la línea liberada" | Means "kept un-keyed". |
| `licenseSettingsTab.blocksPttMoxAntenna` | …you remain responsible… | de "bleibt der Funkamateur verantwortlich", es "sigue siendo del operador" | Changed to the third person to avoid addressing the reader. |
| `licenseSettingsTab.47Cfr97301` | Line A exclusion | de "Ausschluss nach Line A", es "exclusión de la Línea A" | A US legal term. |
| `cwWindow.webSDRIsSilentCheck` | macOS privacy pane path | de "Datenschutz & Sicherheit → Bildschirm- & Systemaudioaufnahme", es "Privacidad y seguridad → Grabación de pantalla y audio del sistema" | Check against the current macOS wording in each language. |
| `privilegePresets.us*` | US Extra/General/… | "USA …" / "EE. UU. …" | License class names kept in English. |
| `themePresets.*` | Dusty Rose, Icy Mint, Glossy Black | de "Altrosa", "Eisminze", "Glanzschwarz"; es "Rosa empolvado", "Menta helada", "Negro brillante" | Free renderings of the theme names. |
| `settings.appearanceSettings.themeDefault` | Theme Default | de "Wie im Thema", es "Predeterminado del tema" | |
| `ft8List.idle` | Idle | de "Untätig", es "Inactivo" | de "Bereit" is an alternative. |
| `pttButton.pushToTalk` | Push to talk (accessibility) | de "Sprechtaste", es "Pulsar para hablar" | |
| `settings.macLoggerDX.logSummary` | N QSOs, N calls | es plural "QSO" unchanged | Spanish usually leaves acronyms unchanged in the plural. de "QSOs". |
| `common.readyMemoryRigKeyer` | Ready — rig keyer, memory N | de "Bereit – Keyer des Geräts, Speicher N", es "Listo: keyer del equipo, memoria N" | Shown until the rig's keyer speed has been read; `common.readyMemoryWpm` once it has. |

## Not translated, on purpose

Format-only keys (`%lld Hz`, `%@ · %@`, …) are copied unchanged. The Mac's
`CFBundleName` stays "FTX1RemoteMac". The logbook target line ("To
MacLoggerDX + Wavelog") gets a translated "To %@" ("An %@" / "A %@").
