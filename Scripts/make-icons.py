#!/usr/bin/env python3
"""Иконки Odin's Eye из одного описания — без графического редактора.

    pip3 install pillow cairosvg
    python3 Scripts/make-icons.py

Пишет Resources/AppIcon.icns — иконку приложения.
"""
import io
import pathlib

import cairosvg
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Ворон в профиль, клювом влево, в квадрате 100×100. Последний подпуть перед
# лапами — глаз: из силуэта он убран,
# на иконке приложения закрашен золотом.
RAVEN = (
 # beak tip -> culmen -> forehead
 "M8,35 C14,31 20,27.5 27,26 "
 # crown and back of head
 "C30,20 38,17.5 44,21 C47.5,23 49,27 49.5,31 "
 # back, sloping to the tail
 "C58,34 68,40 77,50 C84,58 90,67 96,79 "
 # wedge tail
 "L90,82 L87,79 "
 # under the tail, belly
 "C80,74 73,72 67,72 C57,72 48,67 43,59 "
 # shaggy throat hackles up to the chin
 "L40,58.5 L41,55 L37.5,54.5 L38.5,51 L35,50.5 L36,47 L32,46 L33,42.5 L29,41 "
 # lower mandible back to the tip
 "C22,39 15,37.5 8,35 Z "
 # eye (cut out)
 "M33,27.6 a1.7,1.7 0 1,0 0.01,0 Z "
 # legs and toes
 "M58,71 L60,71 L60,84 L63,86 L62.2,87.3 L59.2,85.5 L56,87.5 L55.2,86.2 L58,84.2 Z "
 "M65,72 L67,72 L67,84 L70,86 L69.2,87.3 L66.2,85.5 L63,87.5 L62.2,86.2 L65,84.2 Z"
)
EYE = "M33,27.6 a1.7,1.7 0 1,0 0.01,0 Z "
BODY = RAVEN.replace(EYE, "")


def app_icon_svg(size: int) -> str:
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 1024 1024">
<defs>
  <linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#26304a"/><stop offset="0.55" stop-color="#121726"/><stop offset="1" stop-color="#07080d"/>
  </linearGradient>
  <radialGradient id="moon" cx="0.42" cy="0.38" r="0.62">
    <stop offset="0" stop-color="#fff6dc"/><stop offset="0.7" stop-color="#e9d9ad"/><stop offset="1" stop-color="#c9b27a"/>
  </radialGradient>
  <radialGradient id="halo" cx="0.5" cy="0.5" r="0.5">
    <stop offset="0.55" stop-color="#e9d9ad" stop-opacity="0.35"/><stop offset="1" stop-color="#e9d9ad" stop-opacity="0"/>
  </radialGradient>
  <clipPath id="body"><rect x="100" y="100" width="824" height="824" rx="185" ry="185"/></clipPath>
</defs>
<g clip-path="url(#body)">
  <rect x="100" y="100" width="824" height="824" fill="url(#sky)"/>
  <circle cx="585" cy="455" r="370" fill="url(#halo)"/>
  <circle cx="585" cy="455" r="285" fill="url(#moon)"/>
  <g transform="translate(150,190) scale(7.2)">
    <path d="{BODY}" fill="#0a0b10" fill-rule="evenodd" stroke="#e9d9ad" stroke-opacity="0.45" stroke-width="0.55" stroke-linejoin="round"/>
    <circle cx="33" cy="27.6" r="2.1" fill="#f5c451"/>
  </g>
  <rect x="100" y="100" width="824" height="824" rx="185" ry="185" fill="none" stroke="#ffffff" stroke-opacity="0.08" stroke-width="4"/>
</g>
</svg>'''


def main() -> None:
    sizes = [16, 32, 64, 128, 256, 512, 1024]
    images = [
        Image.open(io.BytesIO(cairosvg.svg2png(bytestring=app_icon_svg(s).encode()))).convert("RGBA")
        for s in sizes
    ]
    icns = ROOT / "Resources" / "AppIcon.icns"
    images[-1].save(icns, append_images=images[:-1])
    print(f"wrote {icns.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
