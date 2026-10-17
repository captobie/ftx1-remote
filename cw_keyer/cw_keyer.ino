/*
  FTX-1 Remote CW key interface - v0.1 (Arduino UNO R3 prototype)

  Role: operator-side input device. Reads a paddle and/or a straight key,
  runs an iambic keyer, plays a local sidetone, and reports key-down/key-up
  events with device timestamps over USB serial. It does NOT key a radio;
  the hub app does that.

  Wiring (all inputs active-low, internal pull-ups, no external parts needed):
    D2   paddle dit      (3.5 mm TRS tip, assumed)
    D3   paddle dah      (3.5 mm TRS ring, assumed)
    D4   straight key    (mono jack tip)
    D8   sidetone        (piezo, or small speaker via ~100 ohm, to GND)
    A0   speed pot       (optional; wiper to A0, ends to 5V and GND; USE_POT 1)
    GND  paddle sleeve, straight key sleeve, sidetone return
    D13  on-board LED follows key state

  If the paddle sides feel backwards, send R1 (or swap the D2/D3 wires).

  Serial: 115200 8N1, newline-terminated ASCII lines.

  Device -> host:
    I,FTX1CW,1                              boot banner (id, protocol version)
    D,<ms>                                  key down (device millis, wraps at 2^32)
    U,<ms>                                  key up
    H,<ms>                                  heartbeat every 250 ms
    S,<wpm>,<A|B>,<rev>,<sidetone>,<ms>     status (after boot and any command)

  Host -> device:
    W<5..50>    set speed in WPM (a pot movement overrides it again)
    MA / MB     iambic mode A or B
    R0 / R1     paddle reverse off / on
    T0 / T1     local sidetone off / on
    ?           request status
*/

#include <Arduino.h>

#ifndef USE_POT
#define USE_POT 0                    // 1 = read a speed pot on A0
#endif

// ---------- Configuration ----------
const uint8_t  PIN_DIT      = 2;
const uint8_t  PIN_DAH      = 3;
const uint8_t  PIN_STRAIGHT = 4;
const uint8_t  PIN_SIDETONE = 8;
const uint8_t  PIN_POT      = A0;
const uint16_t SIDETONE_HZ  = 600;
const uint32_t DEBOUNCE_US  = 3000;  // lockout after an accepted edge
const uint8_t  WPM_MIN      = 5;
const uint8_t  WPM_MAX      = 50;
const uint32_t HEARTBEAT_MS = 250;

// ---------- Debounced input (zero added latency: first edge passes, bounces are ignored) ----------
struct Input {
  uint8_t  pin = 0;
  bool     pressed = false;
  uint32_t lastEdgeUs = 0;

  void begin(uint8_t p) {
    pin = p;
    pinMode(pin, INPUT_PULLUP);
    pressed = (digitalRead(pin) == LOW);
    lastEdgeUs = micros() - DEBOUNCE_US;
  }

  void update(uint32_t nowUs) {
    if ((uint32_t)(nowUs - lastEdgeUs) < DEBOUNCE_US) return;
    bool p = (digitalRead(pin) == LOW);
    if (p != pressed) {
      pressed = p;
      lastEdgeUs = nowUs;
    }
  }
};

Input ditIn, dahIn, keyIn;

// ---------- Keyer state ----------
enum Phase : uint8_t { IDLE, ELEMENT, GAP };

Phase    phase      = IDLE;
bool     curIsDit   = false;   // element being sent
bool     lastWasDit = false;   // last completed element
bool     memDit     = false;   // Mode B paddle memory
bool     memDah     = false;
bool     keyerKey   = false;   // keyer's own output
bool     outKey     = false;   // combined output (keyer OR straight key)
uint32_t phaseEnd   = 0;       // micros() when current element/gap ends

uint8_t  wpm        = 20;
bool     modeB      = true;
bool     reversed   = false;
bool     sidetoneOn = true;

// ---------- Helpers ----------
static inline bool reached(uint32_t now, uint32_t t) { return (int32_t)(now - t) >= 0; }
static inline uint32_t unitUs() { return 1200000UL / wpm; }   // dit length: 1.2 s / WPM

void sendStatus() {
  Serial.print(F("S,"));
  Serial.print(wpm);
  Serial.print(',');
  Serial.print(modeB ? 'B' : 'A');
  Serial.print(',');
  Serial.print(reversed ? 1 : 0);
  Serial.print(',');
  Serial.print(sidetoneOn ? 1 : 0);
  Serial.print(',');
  Serial.println(millis());
}

void applySidetone() {
  if (sidetoneOn && outKey) tone(PIN_SIDETONE, SIDETONE_HZ);
  else noTone(PIN_SIDETONE);
}

void setOutput(bool k) {
  if (k == outKey) return;
  outKey = k;
  digitalWrite(LED_BUILTIN, k ? HIGH : LOW);
  applySidetone();                       // sidetone first: lowest local latency
  Serial.print(k ? 'D' : 'U');
  Serial.print(',');
  Serial.println(millis());
}

// ---------- Iambic keyer ----------
void startElement(bool isDit, uint32_t startUs) {
  phase = ELEMENT;
  curIsDit = isDit;
  phaseEnd = startUs + (isDit ? 1UL : 3UL) * unitUs();
  keyerKey = true;
  if (isDit) memDit = false; else memDah = false;
}

void keyerUpdate(uint32_t now, bool ditP, bool dahP) {
  switch (phase) {
    case IDLE:
      // A squeeze from idle starts with a dit.
      if (ditP || dahP) startElement(ditP, now);
      break;

    case ELEMENT:
      if (modeB) {                       // Mode B latches the opposite paddle
        if (curIsDit && dahP) memDah = true;
        if (!curIsDit && ditP) memDit = true;
      }
      if (reached(now, phaseEnd)) {
        keyerKey = false;
        lastWasDit = curIsDit;
        phase = GAP;
        phaseEnd += unitUs();            // chain from the scheduled end: no drift
      }
      break;

    case GAP:
      if (modeB) {
        if (lastWasDit && dahP) memDah = true;
        if (!lastWasDit && ditP) memDit = true;
      }
      if (reached(now, phaseEnd)) {
        bool go = false, nextDit = false;
        if (lastWasDit) {                // prefer the opposite element, else repeat
          if (memDah || dahP)      { go = true; nextDit = false; }
          else if (ditP)           { go = true; nextDit = true;  }
        } else {
          if (memDit || ditP)      { go = true; nextDit = true;  }
          else if (dahP)           { go = true; nextDit = false; }
        }
        if (go) {
          startElement(nextDit, phaseEnd);
        } else {
          phase = IDLE;
          memDit = memDah = false;
        }
      }
      break;
  }
}

// ---------- Host commands ----------
void execCmd(const char* s) {
  switch (s[0]) {
    case 'W': {
      int v = atoi(s + 1);
      if (v >= WPM_MIN && v <= WPM_MAX) wpm = (uint8_t)v;
      break;
    }
    case 'M':
      if (s[1] == 'A') modeB = false;
      else if (s[1] == 'B') modeB = true;
      break;
    case 'R': reversed = (s[1] == '1'); break;
    case 'T': sidetoneOn = (s[1] != '0'); applySidetone(); break;
    case '?': break;
    default: return;                     // unknown command: ignore
  }
  sendStatus();
}

void readSerial() {
  static char buf[16];
  static uint8_t len = 0;
  while (Serial.available()) {
    char c = (char)Serial.read();
    if (c == '\n' || c == '\r') {
      if (len) { buf[len] = 0; execCmd(buf); len = 0; }
    } else if (len < sizeof(buf) - 1) {
      buf[len++] = c;
    }
  }
}

// ---------- Arduino entry points ----------
void setup() {
  Serial.begin(115200);
  ditIn.begin(PIN_DIT);
  dahIn.begin(PIN_DAH);
  keyIn.begin(PIN_STRAIGHT);
  pinMode(PIN_SIDETONE, OUTPUT);
  pinMode(LED_BUILTIN, OUTPUT);
  Serial.println(F("I,FTX1CW,1"));
  sendStatus();
}

void loop() {
  uint32_t now = micros();
  ditIn.update(now);
  dahIn.update(now);
  keyIn.update(now);

  bool ditP = reversed ? dahIn.pressed : ditIn.pressed;
  bool dahP = reversed ? ditIn.pressed : dahIn.pressed;

  keyerUpdate(now, ditP, dahP);
  setOutput(keyerKey || keyIn.pressed);
  readSerial();

  uint32_t ms = millis();

  static uint32_t lastHb = 0;
  if (ms - lastHb >= HEARTBEAT_MS) {
    lastHb = ms;
    Serial.print(F("H,"));
    Serial.println(ms);
  }

#if USE_POT
  static uint32_t lastPotMs = 0;
  static int potRef = -1000;             // forces an initial read
  if (ms - lastPotMs >= 50) {
    lastPotMs = ms;
    int raw = analogRead(PIN_POT);
    if (abs(raw - potRef) > 12) {        // deadband so a host W command sticks
      potRef = raw;
      wpm = (uint8_t)map(raw, 0, 1023, WPM_MIN, 40);
      sendStatus();
    }
  }
#endif
}
