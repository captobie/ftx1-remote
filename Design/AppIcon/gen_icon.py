import math

def arc_d(cx, cy, r, a0, a1):
    """SVG path 'd' for an arc from angle a0 to a1 (degrees, 0=east, clockwise)."""
    a0r, a1r = math.radians(a0), math.radians(a1)
    x1, y1 = cx + r * math.cos(a0r), cy + r * math.sin(a0r)
    x2, y2 = cx + r * math.cos(a1r), cy + r * math.sin(a1r)
    large_arc = 1 if abs(a1 - a0) > 180 else 0
    sweep = 1 if a1 > a0 else 0
    return f"M {x1:.1f} {y1:.1f} A {r:.1f} {r:.1f} 0 {large_arc} {sweep} {x2:.1f} {y2:.1f}"

def motif(S, cx, cy, palette, tinted=False):
    """Returns SVG markup for the FTX-1-inspired dial motif, centered at (cx,cy),
    sized relative to S (the content box side length)."""
    r = S * 0.30
    dial_cx = cx
    dial_cy = cy - S * 0.06

    bezel_r = r
    glow_r = r * 0.86
    glow_w = r * 0.16
    face_r = r * 0.72

    strip_w = S * 0.60
    strip_h = S * 0.050
    strip_x = cx - strip_w / 2
    strip_y = cy + S * 0.32
    strip_rx = strip_h / 2

    led_r = S * 0.028
    led_cx = dial_cx + bezel_r * 0.72
    led_cy = dial_cy + bezel_r * 0.62

    knurl = []
    n = 32
    for i in range(n):
        a = 2 * math.pi * i / n
        x1 = dial_cx + math.cos(a) * bezel_r * 0.97
        y1 = dial_cy + math.sin(a) * bezel_r * 0.97
        x2 = dial_cx + math.cos(a) * bezel_r * 1.045
        y2 = dial_cy + math.sin(a) * bezel_r * 1.045
        knurl.append(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" stroke="{palette["knurl"]}" stroke-width="{bezel_r*0.018:.1f}" stroke-linecap="round"/>')
    knurl_svg = "\n".join(knurl)

    if tinted:
        strip_fill = palette["strip_tinted"]
    else:
        strip_fill = "url(#waterfall)"

    # Blue light sits in two crescents on the left/right of the dial (like
    # parentheses), cut off at top and bottom -- matches the real FTX-1.
    arc_half_angle = 42
    right_arc = arc_d(dial_cx, dial_cy, glow_r, -arc_half_angle, arc_half_angle)
    left_arc = arc_d(dial_cx, dial_cy, glow_r, 180 - arc_half_angle, 180 + arc_half_angle)
    arcs = [right_arc, left_arc]
    glow_arcs = "\n".join(
        f'<path d="{d}" fill="none" stroke="url(#glowGrad)" stroke-width="{glow_w:.1f}" '
        f'stroke-linecap="round" filter="url(#softBlur)" opacity="0.95"/>'
        for d in arcs
    )
    sharp_arcs = "\n".join(
        f'<path d="{d}" fill="none" stroke="url(#glowGrad)" stroke-width="{glow_w*0.4:.1f}" stroke-linecap="round"/>'
        for d in arcs
    )

    return f'''
  {knurl_svg}
  <circle cx="{dial_cx:.1f}" cy="{dial_cy:.1f}" r="{bezel_r:.1f}" fill="url(#bezelGrad)" stroke="{palette["bezel_stroke"]}" stroke-width="{bezel_r*0.02:.1f}"/>
  {glow_arcs}
  {sharp_arcs}
  <circle cx="{dial_cx:.1f}" cy="{dial_cy:.1f}" r="{face_r:.1f}" fill="url(#faceGrad)"/>
  <ellipse cx="{dial_cx - face_r*0.32:.1f}" cy="{dial_cy - face_r*0.38:.1f}" rx="{face_r*0.42:.1f}" ry="{face_r*0.24:.1f}" fill="{palette['highlight']}" opacity="0.16"/>
  <rect x="{strip_x:.1f}" y="{strip_y:.1f}" width="{strip_w:.1f}" height="{strip_h:.1f}" rx="{strip_rx:.1f}" fill="{strip_fill}"/>
  <circle cx="{led_cx:.1f}" cy="{led_cy:.1f}" r="{led_r:.1f}" fill="url(#ledGrad)"/>
'''

def build_svg(variant):
    W = H = 1024
    cx = cy = 512

    if variant == "mac":
        S = 824
        inset = (1024 - S) / 2
        rx = S * 0.225
        bg_shape = f'<rect x="{inset:.1f}" y="{inset:.1f}" width="{S}" height="{S}" rx="{rx:.1f}" fill="url(#bgGrad)" filter="url(#dropShadow)"/>'
        clip = f'<clipPath id="clip"><rect x="{inset:.1f}" y="{inset:.1f}" width="{S}" height="{S}" rx="{rx:.1f}"/></clipPath>'
        content_S = S
    else:
        S = 1024
        bg_shape = f'<rect x="0" y="0" width="1024" height="1024" fill="url(#bgGrad)"/>'
        clip = ''
        content_S = S

    palette = {
        "bg1": "#2a2d33", "bg2": "#0a0b0d",
        "bezel_stroke": "#4a4d53",
        "knurl": "#000000",
        "highlight": "#ffffff",
        "strip_tinted": "#9aa0a8",
    }

    tinted = variant == "ios-tinted"

    if variant == "ios-dark":
        palette["bg1"] = "#1c1e22"
        palette["bg2"] = "#000000"

    if tinted:
        glow_stops = '<stop offset="0%" stop-color="#e7e9ec"/><stop offset="100%" stop-color="#8b9096"/>'
        led_stops = '<stop offset="0%" stop-color="#d7dade"/><stop offset="100%" stop-color="#7a7f85"/>'
        bezel_stops = '<stop offset="0%" stop-color="#4a4d53"/><stop offset="100%" stop-color="#101114"/>'
        face_stops = '<stop offset="0%" stop-color="#3a3c40"/><stop offset="100%" stop-color="#0e0f11"/>'
        palette["bg1"] = "#3a3c40"
        palette["bg2"] = "#0a0a0b"
    else:
        glow_stops = '<stop offset="0%" stop-color="#5fc3ff"/><stop offset="100%" stop-color="#0060ff"/>'
        led_stops = '<stop offset="0%" stop-color="#3ddc71"/><stop offset="100%" stop-color="#0f7a34"/>'
        bezel_stops = '<stop offset="0%" stop-color="#4a4d53"/><stop offset="100%" stop-color="#101114"/>'
        face_stops = '<stop offset="0%" stop-color="#2c2e33"/><stop offset="100%" stop-color="#0e0f11"/>'

    motif_svg = motif(content_S, cx, cy, palette, tinted=tinted)

    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
  <defs>
    <linearGradient id="bgGrad" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" stop-color="{palette['bg1']}"/>
      <stop offset="100%" stop-color="{palette['bg2']}"/>
    </linearGradient>
    <linearGradient id="bezelGrad" x1="0%" y1="0%" x2="100%" y2="100%">
      {bezel_stops}
    </linearGradient>
    <linearGradient id="glowGrad" x1="0%" y1="0%" x2="100%" y2="100%">
      {glow_stops}
    </linearGradient>
    <radialGradient id="faceGrad" cx="35%" cy="30%" r="75%">
      {face_stops}
    </radialGradient>
    <radialGradient id="ledGrad" cx="35%" cy="30%" r="75%">
      {led_stops}
    </radialGradient>
    <linearGradient id="waterfall" x1="0%" y1="0%" x2="100%" y2="0%">
      <stop offset="0%" stop-color="#2ea1ff"/>
      <stop offset="35%" stop-color="#7d6bff"/>
      <stop offset="65%" stop-color="#ff5fa8"/>
      <stop offset="100%" stop-color="#ff7a3d"/>
    </linearGradient>
    <filter id="softBlur" x="-50%" y="-50%" width="200%" height="200%">
      <feGaussianBlur stdDeviation="{content_S*0.012:.1f}"/>
    </filter>
    <filter id="dropShadow" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="16" stdDeviation="20" flood-color="#000000" flood-opacity="0.4"/>
    </filter>
    {clip}
  </defs>
  {bg_shape}
  <g{' clip-path="url(#clip)"' if clip else ''}>
    {motif_svg}
  </g>
</svg>'''
    return svg

import os
outdir = os.path.dirname(os.path.abspath(__file__))
for variant in ["mac", "ios-light", "ios-dark", "ios-tinted"]:
    svg = build_svg(variant)
    path = os.path.join(outdir, f"{variant}.svg")
    with open(path, "w") as f:
        f.write(svg)
    print("wrote", path)
