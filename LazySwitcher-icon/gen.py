# -*- coding: utf-8 -*-
import math, os
OUT = "/root/icon/src"; os.makedirs(OUT, exist_ok=True)

def squircle(cx, cy, a, n=5.0, steps=720):
    pts=[]
    for i in range(steps):
        t=2*math.pi*i/steps; ct,st=math.cos(t),math.sin(t)
        pts.append((cx+a*math.copysign(abs(ct)**(2.0/n),ct),
                    cy+a*math.copysign(abs(st)**(2.0/n),st)))
    return "M %.2f %.2f "%pts[0] + " ".join("L %.2f %.2f"%p for p in pts[1:]) + " Z"

SQ = squircle(512,512,412)

def arrows(scale=1.0):
    def S(x,y): return (512+(x-512)*scale, 512+(y-512)*scale)
    top=[(296,424),(690,424)]; toph=[(618,352),(690,424),(618,496)]
    bot=[(728,600),(334,600)]; both=[(406,528),(334,600),(406,672)]
    def seg(pts):
        p=[S(*q) for q in pts]
        return "M %.1f %.1f "%p[0] + " ".join("L %.1f %.1f"%q for q in p[1:])
    return " ".join([seg(top),seg(toph),seg(bot),seg(both)])

PAL = {
 "indigo":  dict(c0="#C0A9FF", c1="#6D53EF", c2="#2A1580", deep="#170A46",
                 glow="#C7B4FF", cool="#E9E2FF", warm="#FFE9F4"),
 "ocean":   dict(c0="#8BEBFB", c1="#2470EE", c2="#0B2270", deep="#04113D",
                 glow="#A5EEFF", cool="#E4FBFF", warm="#FFF0E6"),
 "graphite":dict(c0="#98A3B5", c1="#2E3A4E", c2="#0D1420", deep="#04070D",
                 glow="#9FC9FF", cool="#EAF3FF", warm="#FFF1E8"),
}

def build(p, small=False):
    c = PAL[p]
    AR = arrows(1.07 if small else 1.0)
    W  = 90 if small else 78
    frost = 6 if small else 20
    # величины кромок: на мелких размерах кант толще, иначе исчезнет
    rim_out   = W-16 if small else W-11     # ширина внутреннего чёрного штриха → толщина канта
    edge_shift = 11 if small else 11

    softpat = "" if small else f'''
    <g opacity="0.30">
      <ellipse cx="250" cy="205" rx="330" ry="250" fill="url(#blob1)"/>
      <ellipse cx="820" cy="850" rx="380" ry="300" fill="url(#blob2)"/>
    </g>'''

    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
  <linearGradient id="bg" x1="0.06" y1="-0.05" x2="0.9" y2="1.05">
    <stop offset="0"    stop-color="{c['c0']}"/>
    <stop offset="0.40" stop-color="{c['c1']}"/>
    <stop offset="1"    stop-color="{c['c2']}"/>
  </linearGradient>
  <radialGradient id="lamp" cx="0.24" cy="0.10" r="0.9">
    <stop offset="0"   stop-color="#FFFFFF" stop-opacity="0.40"/>
    <stop offset="0.45" stop-color="#FFFFFF" stop-opacity="0.08"/>
    <stop offset="1"   stop-color="#FFFFFF" stop-opacity="0"/>
  </radialGradient>
  <radialGradient id="blob1" cx="0.5" cy="0.5" r="0.5">
    <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.22"/>
    <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></radialGradient>
  <radialGradient id="blob2" cx="0.5" cy="0.5" r="0.5">
    <stop offset="0" stop-color="{c['deep']}" stop-opacity="0.55"/>
    <stop offset="1" stop-color="{c['deep']}" stop-opacity="0"/></radialGradient>
  <radialGradient id="vig" cx="0.46" cy="0.38" r="0.80">
    <stop offset="0.5" stop-color="{c['deep']}" stop-opacity="0"/>
    <stop offset="1"   stop-color="{c['deep']}" stop-opacity="0.62"/></radialGradient>
  <linearGradient id="tileSheen" x1="0" y1="0" x2="0.25" y2="1">
    <stop offset="0"    stop-color="#FFFFFF" stop-opacity="0.20"/>
    <stop offset="0.38" stop-color="#FFFFFF" stop-opacity="0.03"/>
    <stop offset="0.55" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>

  <!-- стекло -->
  <linearGradient id="body" x1="0.15" y1="0" x2="0.7" y2="1">
    <stop offset="0"    stop-color="#FFFFFF" stop-opacity="0.88"/>
    <stop offset="0.30" stop-color="#FFFFFF" stop-opacity="0.46"/>
    <stop offset="0.68" stop-color="#FFFFFF" stop-opacity="0.26"/>
    <stop offset="1"    stop-color="#FFFFFF" stop-opacity="0.60"/></linearGradient>
  <linearGradient id="sweep" x1="0.05" y1="0" x2="0.45" y2="0.9">
    <stop offset="0"    stop-color="#FFFFFF" stop-opacity="0.85"/>
    <stop offset="0.26" stop-color="#FFFFFF" stop-opacity="0.16"/>
    <stop offset="0.5"  stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>
  <linearGradient id="edgeTop" x1="0" y1="0" x2="1" y2="0.4">
    <stop offset="0"   stop-color="{c['cool']}" stop-opacity="1"/>
    <stop offset="0.55" stop-color="#FFFFFF" stop-opacity="0.92"/>
    <stop offset="1"   stop-color="{c['warm']}" stop-opacity="0.80"/></linearGradient>
  <linearGradient id="edgeBot" x1="0" y1="1" x2="1" y2="0.3">
    <stop offset="0"   stop-color="#FFFFFF" stop-opacity="0.70"/>
    <stop offset="1"   stop-color="{c['glow']}" stop-opacity="0.42"/></linearGradient>
  <linearGradient id="rimAll" x1="0.1" y1="0" x2="0.9" y2="1">
    <stop offset="0"    stop-color="#FFFFFF" stop-opacity="0.95"/>
    <stop offset="0.35" stop-color="{c['cool']}" stop-opacity="0.42"/>
    <stop offset="0.66" stop-color="#FFFFFF" stop-opacity="0.22"/>
    <stop offset="1"    stop-color="#FFFFFF" stop-opacity="0.78"/></linearGradient>

  <filter id="frost" x="-30%" y="-30%" width="160%" height="160%">
    <feGaussianBlur stdDeviation="{frost}"/>
    <feColorMatrix type="saturate" values="1.7"/>
    <feComponentTransfer>
      <feFuncR type="linear" slope="1.05" intercept="0.16"/>
      <feFuncG type="linear" slope="1.05" intercept="0.16"/>
      <feFuncB type="linear" slope="1.05" intercept="0.18"/></feComponentTransfer>
  </filter>
  <filter id="sh" x="-45%" y="-45%" width="190%" height="190%">
    <feGaussianBlur stdDeviation="{14 if small else 22}"/></filter>
  <filter id="glowB" x="-60%" y="-60%" width="220%" height="220%">
    <feGaussianBlur stdDeviation="52"/></filter>
  <filter id="sparkB" x="-60%" y="-60%" width="220%" height="220%">
    <feGaussianBlur stdDeviation="{4 if small else 9}"/></filter>
  <filter id="drop" x="-25%" y="-25%" width="150%" height="150%">
    <feGaussianBlur stdDeviation="24"/></filter>
  <filter id="edgeSoft" x="-30%" y="-30%" width="160%" height="160%">
    <feGaussianBlur stdDeviation="{1.2 if small else 2.6}"/></filter>

  <clipPath id="sq"><path d="{SQ}"/></clipPath>

  <mask id="mBody" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">
    <rect width="1024" height="1024" fill="#000"/>
    <path d="{AR}" fill="none" stroke="#fff" stroke-width="{W}" stroke-linecap="round" stroke-linejoin="round"/>
  </mask>
  <!-- сплошной кант по всему контуру -->
  <mask id="mRim" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">
    <rect width="1024" height="1024" fill="#000"/>
    <path d="{AR}" fill="none" stroke="#fff" stroke-width="{W}" stroke-linecap="round" stroke-linejoin="round"/>
    <path d="{AR}" fill="none" stroke="#000" stroke-width="{rim_out}" stroke-linecap="round" stroke-linejoin="round"/>
  </mask>
  <!-- световая кромка только сверху: форма минус форма, сдвинутая вниз -->
  <mask id="mEdgeTop" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">
    <rect width="1024" height="1024" fill="#000"/>
    <path d="{AR}" fill="none" stroke="#fff" stroke-width="{W}" stroke-linecap="round" stroke-linejoin="round"/>
    <path d="{AR}" fill="none" stroke="#000" stroke-width="{W}" stroke-linecap="round" stroke-linejoin="round"
          transform="translate(0,{edge_shift})"/>
  </mask>
  <!-- и снизу: отражённый свет -->
  <mask id="mEdgeBot" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">
    <rect width="1024" height="1024" fill="#000"/>
    <path d="{AR}" fill="none" stroke="#fff" stroke-width="{W}" stroke-linecap="round" stroke-linejoin="round"/>
    <path d="{AR}" fill="none" stroke="#000" stroke-width="{W}" stroke-linecap="round" stroke-linejoin="round"
          transform="translate(0,-{edge_shift-3})"/>
  </mask>

  <g id="bgArt">
    <rect width="1024" height="1024" fill="url(#bg)"/>
    <rect width="1024" height="1024" fill="url(#lamp)"/>{softpat}
    <rect width="1024" height="1024" fill="url(#vig)"/>
  </g>
</defs>

<g opacity="0.22"><path d="{SQ}" transform="translate(0,20)" fill="{c['deep']}" filter="url(#drop)"/></g>

<g clip-path="url(#sq)">
  <use href="#bgArt"/>
  <rect width="1024" height="1024" fill="url(#tileSheen)"/>

  <!-- свечение под стеклом -->
  <g filter="url(#glowB)" opacity="0.5">
    <path d="{AR}" fill="none" stroke="{c['glow']}" stroke-width="{W+40}"
          stroke-linecap="round" stroke-linejoin="round" opacity="0.55"/>
  </g>

  <!-- тень -->
  <g opacity="0.5" filter="url(#sh)" transform="translate(0,28)">
    <path d="{AR}" fill="none" stroke="{c['deep']}" stroke-width="{W-4}"
          stroke-linecap="round" stroke-linejoin="round"/>
  </g>

  <!-- тело стекла -->
  <g mask="url(#mBody)">
    <g transform="translate(512,512) scale(1.42) translate(-512,-512)">
      <use href="#bgArt" filter="url(#frost)"/>
    </g>
    <rect width="1024" height="1024" fill="url(#body)"/>
    <rect width="1024" height="1024" fill="url(#sweep)"/>
  </g>

  <!-- кромки -->
  <g filter="url(#edgeSoft)">
    <rect width="1024" height="1024" fill="url(#rimAll)"  mask="url(#mRim)"/>
    <rect width="1024" height="1024" fill="url(#edgeTop)" mask="url(#mEdgeTop)" opacity="0.78"/>
    <rect width="1024" height="1024" fill="url(#edgeBot)" mask="url(#mEdgeBot)" opacity="0.5"/>
  </g>

  <!-- искры-блики -->
  <g mask="url(#mBody)" filter="url(#sparkB)" opacity="{0.55 if small else 0.9}">
    <ellipse cx="352" cy="404" rx="72" ry="13" fill="#FFFFFF" transform="rotate(-9 352 404)"/>
    <ellipse cx="640" cy="378" rx="30" ry="10" fill="#FFFFFF" transform="rotate(38 640 378)"/>
    <ellipse cx="470" cy="580" rx="56" ry="10" fill="#FFFFFF" transform="rotate(-6 470 580)" opacity="0.7"/>
  </g>
</g>
</svg>
'''

for k in PAL:
    open(f"{OUT}/icon-{k}.svg","w").write(build(k))
    open(f"{OUT}/icon-{k}-small.svg","w").write(build(k, small=True))
print("ok")
