#!/usr/bin/env python3
"""Render the README architecture GIFs from deterministic SVG frames.

Two animations, one story, told with glyphs rather than prose. The first
follows a tracker event across the Omashiki boundary — handler, house,
machine — and back onto the ticket as one of three results. The second opens
one offer on one machine: accept into a slot, the frozen snapshot, the
workspace, the sandbox run talking to the house, the verified result, the
signed webhook. Brand marks are Simple Icons (CC0).

Colours come from the product design tokens (server/assets/css/tokens.css):
neon green is the Omashiki signature and is reserved for Omashiki itself, so
the palette alone answers where the boundary is.
"""

from __future__ import annotations

import html
import math
import pathlib
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "docs" / "assets"
WIDTH = 1200
HEIGHT = 640
FPS = 12
BEATS = 6
FRAMES_PER_BEAT = 16
FRAMES = BEATS * FRAMES_PER_BEAT

# --- Design tokens (tokens.css). Sharp corners and neon green are identity. ---
SURFACE = "#0e0e0e"          # neutral-5
PANEL = "#1a1a19"            # neutral-15
PANEL_2 = "#1e1e1d"          # neutral-20
INSET = "#121212"            # neutral-10
LINE = "#353534"             # neutral-30
OUTLINE = "#494543"          # neutral-40
FAINT = "#6f6b69"            # neutral-50
MUTED = "#a8a29e"            # neutral-70
INK = "#e5e2e1"              # neutral-90

BRAND = "#39ff14"            # primary-60  — Omashiki
BRAND_DIM = "#2dcc10"        # primary-40
BRAND_SOFT = "#a0e87a"       # primary-80
BRAND_TINT = "#0f1a0c"       # neon over the dark surface

INFO = "#7ad8ff"             # status running
AMBER = "#ffb347"            # status awaiting
CORAL = "#ff5544"            # status failed
VIOLET = "#9d8aff"           # categorical
MAGENTA = "#fa6dff"          # categorical
ORANGE = "#ff8c4a"           # categorical

OUTSIDE_TINT = "#131312"     # "your side" — deliberately colourless

DIM = 0.3


def clamp(value: float, low: float = 0.0, high: float = 1.0) -> float:
    return max(low, min(high, value))


def ease(value: float) -> float:
    value = clamp(value)
    return value * value * (3.0 - 2.0 * value)


def esc(value: object) -> str:
    return html.escape(str(value))


def mix(low: float, high: float, amount: float) -> float:
    return low + (high - low) * clamp(amount)


def text(x: float, y: float, value: object, size: int = 16, color: str = INK,
         weight: int = 500, anchor: str = "start", mono: bool = False,
         opacity: float = 1.0, spacing: float = 0.0) -> str:
    family = ("'JetBrains Mono', monospace" if mono
              else "'Inter', 'Liberation Sans', sans-serif")
    return (
        f'<text x="{x}" y="{y}" fill="{color}" font-family="{family}" '
        f'font-size="{size}" font-weight="{weight}" text-anchor="{anchor}" '
        f'letter-spacing="{spacing}" opacity="{opacity:.3f}">{esc(value)}</text>'
    )


def rect(x: float, y: float, width: float, height: float, fill: str = PANEL,
         stroke: str = LINE, stroke_width: float = 1, opacity: float = 1.0,
         dash: str | None = None) -> str:
    dashed = f' stroke-dasharray="{dash}"' if dash else ""
    return (
        f'<rect x="{x}" y="{y}" width="{width}" height="{height}" '
        f'fill="{fill}" stroke="{stroke}" stroke-width="{stroke_width}" '
        f'opacity="{opacity:.3f}"{dashed}/>'
    )


def line(x1: float, y1: float, x2: float, y2: float, color: str = LINE,
         width: float = 2, opacity: float = 1.0, dash: str | None = None) -> str:
    dashed = f' stroke-dasharray="{dash}"' if dash else ""
    return (
        f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" '
        f'stroke-width="{width}" opacity="{opacity:.3f}"{dashed}/>'
    )


def dot(x: float, y: float, color: str = BRAND, radius: float = 6,
        opacity: float = 1.0, glow: bool = True) -> str:
    effect = ' filter="url(#glow)"' if glow else ""
    return (
        f'<circle cx="{x}" cy="{y}" r="{radius}" fill="{color}" '
        f'opacity="{opacity:.3f}"{effect}/>'
    )


def square(x: float, y: float, color: str, size: float = 9,
           opacity: float = 1.0) -> str:
    half = size / 2
    return (
        f'<rect x="{x - half}" y="{y - half}" width="{size}" height="{size}" '
        f'fill="{color}" opacity="{opacity:.3f}" filter="url(#glow)"/>'
    )


def arrow(x1: float, y1: float, x2: float, y2: float, color: str = LINE,
          width: float = 2, opacity: float = 1.0, head: float = 6.5,
          dash: str | None = None) -> str:
    angle = math.atan2(y2 - y1, x2 - x1)
    back_x = x2 - head * 1.7 * math.cos(angle)
    back_y = y2 - head * 1.7 * math.sin(angle)
    left = (back_x - head * math.sin(angle), back_y + head * math.cos(angle))
    right = (back_x + head * math.sin(angle), back_y - head * math.cos(angle))
    points = f"{x2},{y2} {left[0]:.2f},{left[1]:.2f} {right[0]:.2f},{right[1]:.2f}"
    return "".join([
        line(x1, y1, back_x, back_y, color, width, opacity, dash),
        f'<polygon points="{points}" fill="{color}" opacity="{opacity:.3f}"/>',
    ])


def tag(cx: float, cy: float, label: str, color: str, fill: str = SURFACE,
        opacity: float = 1.0, size: int = 11) -> str:
    """A hard-cornered chip. Used for zone labels and the in-flight job."""
    width = len(label) * (size * 0.72) + 34
    x = cx - width / 2
    return "".join([
        rect(x, cy - 14, width, 28, fill=fill, stroke=color, stroke_width=1.5,
             opacity=opacity),
        square(x + 15, cy, color, 7, opacity),
        text(x + 26, cy + 4, label, size, INK, 700, mono=True, opacity=opacity),
    ])


def crossing(x: float, y: float, color: str, opacity: float = 1.0) -> str:
    """A gate marker drawn where a flow crosses the Omashiki boundary."""
    return (
        f'<polygon points="{x},{y - 9} {x + 8},{y} {x},{y + 9} {x - 8},{y}" '
        f'fill="{SURFACE}" stroke="{color}" stroke-width="1.6" '
        f'opacity="{opacity:.3f}"/>'
    )


def panel_head(x: float, y: float, index: str, label: str, color: str,
               opacity: float) -> list[str]:
    return [
        text(x, y, index, 11, color, 800, mono=True, spacing=1.2, opacity=opacity),
        text(x + len(index) * 8.4 + 10, y, label, 11, INK, 800, mono=True,
             spacing=1.4, opacity=opacity),
    ]


def kv(x: float, y: float, key: str, value: str, opacity: float,
       value_color: str = INK, key_width: float = 84) -> list[str]:
    return [
        text(x, y, key, 10.5, MUTED, 600, mono=True, opacity=opacity),
        text(x + key_width, y, value, 10, value_color, 700, mono=True, opacity=opacity),
    ]


def base(eyebrow: str, title: str, subtitle: str) -> list[str]:
    return [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT}" '
        f'viewBox="0 0 {WIDTH} {HEIGHT}">',
        f"""
        <defs>
          <pattern id="grid" width="32" height="32" patternUnits="userSpaceOnUse">
            <path d="M32 0H0V32" fill="none" stroke="#1e1e1d" stroke-width="1" opacity=".6"/>
          </pattern>
          <filter id="glow" x="-200%" y="-200%" width="400%" height="400%">
            <feGaussianBlur stdDeviation="4" result="blur"/>
            <feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge>
          </filter>
        </defs>
        <rect width="{WIDTH}" height="{HEIGHT}" fill="{SURFACE}"/>
        <rect width="{WIDTH}" height="{HEIGHT}" fill="url(#grid)"/>
        <circle cx="1090" cy="-60" r="300" fill="{BRAND}" opacity=".030"/>
        """,
        text(56, 50, eyebrow.upper(), 12, BRAND, 700, mono=True, spacing=2.2),
        text(56, 90, title, 31, INK, 700),
        text(56, 116, subtitle, 14, MUTED, 400),
        text(1132, 55, "OMASHIKI", 13, INK, 800, anchor="end", mono=True, spacing=1.8),
        f'<rect x="1140" y="45" width="10" height="10" fill="{BRAND}"/>',
    ]


def narration(step: int, total: int, message: str) -> list[str]:
    return [
        line(56, 592, 1144, 592, LINE, 1, 0.8),
        square(62, 613, BRAND, 8),
        text(78, 617, f"{step}/{total}", 11, BRAND, 800, mono=True, spacing=1.2),
        text(118, 617, message, 13, INK, 500),
    ]


# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Brand glyphs (Simple Icons, CC0). 24x24 view boxes, drawn as flat marks.
# ---------------------------------------------------------------------------

ICONS = {
    "jira": "M11.571 11.513H0a5.218 5.218 0 0 0 5.232 5.215h2.13v2.057A5.215 5.215 0 0 0 12.575 24V12.518a1.005 1.005 0 0 0-1.005-1.005zm5.723-5.756H5.736a5.215 5.215 0 0 0 5.215 5.214h2.129v2.058a5.218 5.218 0 0 0 5.215 5.214V6.758a1.001 1.001 0 0 0-1.001-1.001zM23.013 0H11.455a5.215 5.215 0 0 0 5.215 5.215h2.129v2.057A5.215 5.215 0 0 0 24 12.483V1.005A1.001 1.001 0 0 0 23.013 0Z",
    "github": "M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12",
    "gitlab": "m23.6004 9.5927-.0337-.0862L20.3.9814a.851.851 0 0 0-.3362-.405.8748.8748 0 0 0-.9997.0539.8748.8748 0 0 0-.29.4399l-2.2055 6.748H7.5375l-2.2057-6.748a.8573.8573 0 0 0-.29-.4412.8748.8748 0 0 0-.9997-.0537.8585.8585 0 0 0-.3362.4049L.4332 9.5015l-.0325.0862a6.0657 6.0657 0 0 0 2.0119 7.0105l.0113.0087.03.0213 4.976 3.7264 2.462 1.8633 1.4995 1.1321a1.0085 1.0085 0 0 0 1.2197 0l1.4995-1.1321 2.4619-1.8633 5.006-3.7489.0125-.01a6.0682 6.0682 0 0 0 2.0094-7.003z",
    "linear": "M2.886 4.18A11.982 11.982 0 0 1 11.99 0C18.624 0 24 5.376 24 12.009c0 3.64-1.62 6.903-4.18 9.105L2.887 4.18ZM1.817 5.626l16.556 16.556c-.524.33-1.075.62-1.65.866L.951 7.277c.247-.575.537-1.126.866-1.65ZM.322 9.163l14.515 14.515c-.71.172-1.443.282-2.195.322L0 11.358a12 12 0 0 1 .322-2.195Zm-.17 4.862 9.823 9.824a12.02 12.02 0 0 1-9.824-9.824Z",
    "postgresql": "M23.5594 14.7228a.5269.5269 0 0 0-.0563-.1191c-.139-.2632-.4768-.3418-1.0074-.2321-1.6533.3411-2.2935.1312-2.5256-.0191 1.342-2.0482 2.445-4.522 3.0411-6.8297.2714-1.0507.7982-3.5237.1222-4.7316a1.5641 1.5641 0 0 0-.1509-.235C21.6931.9086 19.8007.0248 17.5099.0005c-1.4947-.0158-2.7705.3461-3.1161.4794a9.449 9.449 0 0 0-.5159-.0816 8.044 8.044 0 0 0-1.3114-.1278c-1.1822-.0184-2.2038.2642-3.0498.8406-.8573-.3211-4.7888-1.645-7.2219.0788C.9359 2.1526.3086 3.8733.4302 6.3043c.0409.818.5069 3.334 1.2423 5.7436.4598 1.5065.9387 2.7019 1.4334 3.582.553.9942 1.1259 1.5933 1.7143 1.7895.4474.1491 1.1327.1441 1.8581-.7279.8012-.9635 1.5903-1.8258 1.9446-2.2069.4351.2355.9064.3625 1.39.3772a.0569.0569 0 0 0 .0004.0041 11.0312 11.0312 0 0 0-.2472.3054c-.3389.4302-.4094.5197-1.5002.7443-.3102.064-1.1344.2339-1.1464.8115-.0025.1224.0329.2309.0919.3268.2269.4231.9216.6097 1.015.6331 1.3345.3335 2.5044.092 3.3714-.6787-.017 2.231.0775 4.4174.3454 5.0874.2212.5529.7618 1.9045 2.4692 1.9043.2505 0 .5263-.0291.8296-.0941 1.7819-.3821 2.5557-1.1696 2.855-2.9059.1503-.8707.4016-2.8753.5388-4.1012.0169-.0703.0357-.1207.057-.1362.0007-.0005.0697-.0471.4272.0307a.3673.3673 0 0 0 .0443.0068l.2539.0223.0149.001c.8468.0384 1.9114-.1426 2.5312-.4308.6438-.2988 1.8057-1.0323 1.5951-1.6698zM2.371 11.8765c-.7435-2.4358-1.1779-4.8851-1.2123-5.5719-.1086-2.1714.4171-3.6829 1.5623-4.4927 1.8367-1.2986 4.8398-.5408 6.108-.13-.0032.0032-.0066.0061-.0098.0094-2.0238 2.044-1.9758 5.536-1.9708 5.7495-.0002.0823.0066.1989.0162.3593.0348.5873.0996 1.6804-.0735 2.9184-.1609 1.1504.1937 2.2764.9728 3.0892.0806.0841.1648.1631.2518.2374-.3468.3714-1.1004 1.1926-1.9025 2.1576-.5677.6825-.9597.5517-1.0886.5087-.3919-.1307-.813-.5871-1.2381-1.3223-.4796-.839-.9635-2.0317-1.4155-3.5126zm6.0072 5.0871c-.1711-.0428-.3271-.1132-.4322-.1772.0889-.0394.2374-.0902.4833-.1409 1.2833-.2641 1.4815-.4506 1.9143-1.0002.0992-.126.2116-.2687.3673-.4426a.3549.3549 0 0 0 .0737-.1298c.1708-.1513.2724-.1099.4369-.0417.156.0646.3078.26.3695.4752.0291.1016.0619.2945-.0452.4444-.9043 1.2658-2.2216 1.2494-3.1676 1.0128zm2.094-3.988-.0525.141c-.133.3566-.2567.6881-.3334 1.003-.6674-.0021-1.3168-.2872-1.8105-.8024-.6279-.6551-.9131-1.5664-.7825-2.5004.1828-1.3079.1153-2.4468.079-3.0586-.005-.0857-.0095-.1607-.0122-.2199.2957-.2621 1.6659-.9962 2.6429-.7724.4459.1022.7176.4057.8305.928.5846 2.7038.0774 3.8307-.3302 4.7363-.084.1866-.1633.3629-.2311.5454zm7.3637 4.5725c-.0169.1768-.0358.376-.0618.5959l-.146.4383a.3547.3547 0 0 0-.0182.1077c-.0059.4747-.054.6489-.115.8693-.0634.2292-.1353.4891-.1794 1.0575-.11 1.4143-.8782 2.2267-2.4172 2.5565-1.5155.3251-1.7843-.4968-2.0212-1.2217a6.5824 6.5824 0 0 0-.0769-.2266c-.2154-.5858-.1911-1.4119-.1574-2.5551.0165-.5612-.0249-1.9013-.3302-2.6462.0044-.2932.0106-.5909.019-.8918a.3529.3529 0 0 0-.0153-.1126 1.4927 1.4927 0 0 0-.0439-.208c-.1226-.4283-.4213-.7866-.7797-.9351-.1424-.059-.4038-.1672-.7178-.0869.067-.276.1831-.5875.309-.9249l.0529-.142c.0595-.16.134-.3257.213-.5012.4265-.9476 1.0106-2.2453.3766-5.1772-.2374-1.0981-1.0304-1.6343-2.2324-1.5098-.7207.0746-1.3799.3654-1.7088.5321a5.6716 5.6716 0 0 0-.1958.1041c.0918-1.1064.4386-3.1741 1.7357-4.4823a4.0306 4.0306 0 0 1 .3033-.276.3532.3532 0 0 0 .1447-.0644c.7524-.5706 1.6945-.8506 2.802-.8325.4091.0067.8017.0339 1.1742.081 1.939.3544 3.2439 1.4468 4.0359 2.3827.8143.9623 1.2552 1.9315 1.4312 2.4543-1.3232-.1346-2.2234.1268-2.6797.779-.9926 1.4189.543 4.1729 1.2811 5.4964.1353.2426.2522.4522.2889.5413.2403.5825.5515.9713.7787 1.2552.0696.087.1372.1714.1885.245-.4008.1155-1.1208.3825-1.0552 1.717-.0123.1563-.0423.4469-.0834.8148-.0461.2077-.0702.4603-.0994.7662zm.8905-1.6211c-.0405-.8316.2691-.9185.5967-1.0105a2.8566 2.8566 0 0 0 .135-.0406 1.202 1.202 0 0 0 .1342.103c.5703.3765 1.5823.4213 3.0068.1344-.2016.1769-.5189.3994-.9533.6011-.4098.1903-1.0957.333-1.7473.3636-.7197.0336-1.0859-.0807-1.1721-.151zm.5695-9.2712c-.0059.3508-.0542.6692-.1054 1.0017-.055.3576-.112.7274-.1264 1.1762-.0142.4368.0404.8909.0932 1.3301.1066.887.216 1.8003-.2075 2.7014a3.5272 3.5272 0 0 1-.1876-.3856c-.0527-.1276-.1669-.3326-.3251-.6162-.6156-1.1041-2.0574-3.6896-1.3193-4.7446.3795-.5427 1.3408-.5661 2.1781-.463zm.2284 7.0137a12.3762 12.3762 0 0 0-.0853-.1074l-.0355-.0444c.7262-1.1995.5842-2.3862.4578-3.4385-.0519-.4318-.1009-.8396-.0885-1.2226.0129-.4061.0666-.7543.1185-1.0911.0639-.415.1288-.8443.1109-1.3505.0134-.0531.0188-.1158.0118-.1902-.0457-.4855-.5999-1.938-1.7294-3.253-.6076-.7073-1.4896-1.4972-2.6889-2.0395.5251-.1066 1.2328-.2035 2.0244-.1859 2.0515.0456 3.6746.8135 4.8242 2.2824a.908.908 0 0 1 .0667.1002c.7231 1.3556-.2762 6.2751-2.9867 10.5405zm-8.8166-6.1162c-.025.1794-.3089.4225-.6211.4225a.5821.5821 0 0 1-.0809-.0056c-.1873-.026-.3765-.144-.5059-.3156-.0458-.0605-.1203-.178-.1055-.2844.0055-.0401.0261-.0985.0925-.1488.1182-.0894.3518-.1226.6096-.0867.3163.0441.6426.1938.6113.4186zm7.9305-.4114c.0111.0792-.049.201-.1531.3102-.0683.0717-.212.1961-.4079.2232a.5456.5456 0 0 1-.075.0052c-.2935 0-.5414-.2344-.5607-.3717-.024-.1765.2641-.3106.5611-.352.297-.0414.6111.0088.6356.1851z",
    "docker": "M13.983 11.078h2.119a.186.186 0 00.186-.185V9.006a.186.186 0 00-.186-.186h-2.119a.185.185 0 00-.185.185v1.888c0 .102.083.185.185.185m-2.954-5.43h2.118a.186.186 0 00.186-.186V3.574a.186.186 0 00-.186-.185h-2.118a.185.185 0 00-.185.185v1.888c0 .102.082.185.185.185m0 2.716h2.118a.187.187 0 00.186-.186V6.29a.186.186 0 00-.186-.185h-2.118a.185.185 0 00-.185.185v1.887c0 .102.082.185.185.186m-2.93 0h2.12a.186.186 0 00.184-.186V6.29a.185.185 0 00-.185-.185H8.1a.185.185 0 00-.185.185v1.887c0 .102.083.185.185.186m-2.964 0h2.119a.186.186 0 00.185-.186V6.29a.185.185 0 00-.185-.185H5.136a.186.186 0 00-.186.185v1.887c0 .102.084.185.186.186m5.893 2.715h2.118a.186.186 0 00.186-.185V9.006a.186.186 0 00-.186-.186h-2.118a.185.185 0 00-.185.185v1.888c0 .102.082.185.185.185m-2.93 0h2.12a.185.185 0 00.184-.185V9.006a.185.185 0 00-.184-.186h-2.12a.185.185 0 00-.184.185v1.888c0 .102.083.185.185.185m-2.964 0h2.119a.185.185 0 00.185-.185V9.006a.185.185 0 00-.184-.186h-2.12a.186.186 0 00-.186.186v1.887c0 .102.084.185.186.185m-2.92 0h2.12a.185.185 0 00.184-.185V9.006a.185.185 0 00-.184-.186h-2.12a.185.185 0 00-.184.185v1.888c0 .102.082.185.185.185M23.763 9.89c-.065-.051-.672-.51-1.954-.51-.338.001-.676.03-1.01.087-.248-1.7-1.653-2.53-1.716-2.566l-.344-.199-.226.327c-.284.438-.49.922-.612 1.43-.23.97-.09 1.882.403 2.661-.595.332-1.55.413-1.744.42H.751a.751.751 0 00-.75.748 11.376 11.376 0 00.692 4.062c.545 1.428 1.355 2.48 2.41 3.124 1.18.723 3.1 1.137 5.275 1.137.983.003 1.963-.086 2.93-.266a12.248 12.248 0 003.823-1.389c.98-.567 1.86-1.288 2.61-2.136 1.252-1.418 1.998-2.997 2.553-4.4h.221c1.372 0 2.215-.549 2.68-1.009.309-.293.55-.65.707-1.046l.098-.288Z",
    "git": "M13.09 23.549a1.54 1.54 0 0 1-2.18 0L.451 13.089a1.54 1.54 0 0 1 0-2.179l7.191-7.19 2.733 2.733a1.85 1.85 0 0 0 .964 2.326v6.66a1.849 1.849 0 1 0 1.54 0V8.957l2.508 2.508a1.85 1.85 0 1 0 1.09-1.09l-2.634-2.634a1.85 1.85 0 0 0-2.378-2.377L8.73 2.63 10.91.451a1.54 1.54 0 0 1 2.179 0l10.459 10.46a1.54 1.54 0 0 1 0 2.179z",
}


def icon(name: str, cx: float, cy: float, size: float, color: str,
         opacity: float = 1.0, glow: bool = False) -> str:
    scale = size / 24
    effect = ' filter="url(#glow)"' if glow else ""
    return (
        f'<g transform="translate({cx - size / 2:.2f},{cy - size / 2:.2f}) scale({scale:.4f})" '
        f'opacity="{opacity:.3f}"{effect}><path d="{ICONS[name]}" fill="{color}"/></g>'
    )


def glyph_branch(cx: float, cy: float, size: float, color: str, opacity: float = 1.0) -> str:
    """A git branch: two commits and a fork. Result sink `git`."""
    s = size / 24
    return (
        f'<g transform="translate({cx - size / 2:.2f},{cy - size / 2:.2f}) scale({s:.4f})" '
        f'opacity="{opacity:.3f}" fill="none" stroke="{color}" stroke-width="2.2" '
        f'stroke-linecap="round">'
        f'<circle cx="6" cy="4" r="2.4"/><circle cx="6" cy="20" r="2.4"/><circle cx="18" cy="8" r="2.4"/>'
        f'<path d="M6 6.5v11M18 10.5c0 4-12 3-12 7"/></g>'
    )


def glyph_bundle(cx: float, cy: float, size: float, color: str, opacity: float = 1.0) -> str:
    """A stack of files. Result sink `files`."""
    s = size / 24
    return (
        f'<g transform="translate({cx - size / 2:.2f},{cy - size / 2:.2f}) scale({s:.4f})" '
        f'opacity="{opacity:.3f}" fill="none" stroke="{color}" stroke-width="2" stroke-linejoin="round">'
        f'<path d="M8 3h7l4 4v11H8z"/><path d="M15 3v4h4"/><path d="M5 7v13h10"/></g>'
    )


def glyph_actions(cx: float, cy: float, size: float, color: str, opacity: float = 1.0) -> str:
    """A bolt: side effects through the house. Result sink `none`."""
    s = size / 24
    return (
        f'<g transform="translate({cx - size / 2:.2f},{cy - size / 2:.2f}) scale({s:.4f})" '
        f'opacity="{opacity:.3f}"><path d="M13 2 4 14h7l-1 8 9-12h-7z" fill="{color}"/></g>'
    )


def glyph_box(cx: float, cy: float, size: float, color: str, opacity: float = 1.0) -> str:
    """A sandbox container."""
    s = size / 24
    return (
        f'<g transform="translate({cx - size / 2:.2f},{cy - size / 2:.2f}) scale({s:.4f})" '
        f'opacity="{opacity:.3f}" fill="none" stroke="{color}" stroke-width="2" stroke-linejoin="round">'
        f'<path d="M12 2 3 7v10l9 5 9-5V7z"/><path d="M3 7l9 5 9-5M12 12v10"/></g>'
    )


def glyph_house(cx: float, cy: float, size: float, color: str, opacity: float = 1.0) -> str:
    s = size / 24
    return (
        f'<g transform="translate({cx - size / 2:.2f},{cy - size / 2:.2f}) scale({s:.4f})" '
        f'opacity="{opacity:.3f}" fill="none" stroke="{color}" stroke-width="2" stroke-linejoin="round">'
        f'<path d="M3 11 12 3l9 8"/><path d="M5 10v11h14V10"/><path d="M10 21v-6h4v6"/></g>'
    )


def glyph_handler(cx: float, cy: float, size: float, color: str, opacity: float = 1.0) -> str:
    """Curly braces: your handler, your code."""
    return text(cx, cy + size * 0.36, "{ }", int(size), color, 800, anchor="middle",
                mono=True, opacity=opacity)


def label(cx: float, y: float, value: str, color: str = MUTED, opacity: float = 1.0,
          size: float = 10) -> str:
    return text(cx, y, value, size, color, 700, anchor="middle", mono=True,
                opacity=opacity, spacing=1.2)


def framed(cx: float, cy: float, w: float, h: float, stroke: str, opacity: float,
           fill: str = PANEL, dash: str | None = None) -> str:
    return rect(cx - w / 2, cy - h / 2, w, h, fill=fill, stroke=stroke, stroke_width=1.5,
                opacity=opacity, dash=dash)


def curve(x1: float, y1: float, x2: float, y2: float, color: str, width: float = 2,
          opacity: float = 1.0, head: float = 6.5) -> str:
    """A horizontal-tangent bezier with an arrowhead, core -> worker style."""
    c1, c2 = x1 + (x2 - x1) * 0.45, x2 - (x2 - x1) * 0.45
    points = f"{x2},{y2} {x2 - head * 1.7},{y2 - head} {x2 - head * 1.7},{y2 + head}"
    return (
        f'<path d="M{x1},{y1} C{c1},{y1} {c2},{y2} {x2 - head * 1.2},{y2}" fill="none" '
        f'stroke="{color}" stroke-width="{width}" opacity="{opacity:.3f}"/>'
        f'<polygon points="{points}" fill="{color}" opacity="{opacity:.3f}"/>'
    )


def node_box(cx: float, cy: float, w: float, h: float, name: str, color: str,
             opacity: float, fill: str = INSET, size: float = 10.5) -> list[str]:
    """A named Omashiki node: hard-cornered box, brand square, mono label."""
    return [
        rect(cx - w / 2, cy - h / 2, w, h, fill=fill, stroke=color, stroke_width=1.5,
             opacity=opacity),
        square(cx - w / 2 + 14, cy, color, 7, opacity),
        text(cx - w / 2 + 26, cy + 4, name, size, INK, 700, mono=True, opacity=opacity),
    ]


def container_tree(x: float, y: float, count: int, reveal: float, color: str,
                   opacity: float, spread: float = 26) -> list[str]:
    """Small Docker marks fanned out to the right of a worker, joined like a tree."""
    out = []
    for i in range(count):
        show = clamp((reveal - i * (1.0 / count)) * count)
        if show <= 0:
            continue
        cy = y + (i - (count - 1) / 2) * spread
        cx = x + 34
        out += [
            line(x, y, x + 14, y, color, 1.2, opacity * show * 0.8),
            line(x + 14, y, x + 14, cy, color, 1.2, opacity * show * 0.8),
            line(x + 14, cy, cx - 10, cy, color, 1.2, opacity * show * 0.8),
            icon("docker", cx, cy, 16, color, opacity * show),
        ]
    return out


def beat_of(frame: int) -> tuple[int, float, float, float]:
    t = frame / FRAMES
    beat = min(BEATS - 1, int(t * BEATS))
    local = ease((t * BEATS) - beat)
    pulse = 0.55 + 0.45 * math.sin(t * math.tau * 3) ** 2
    return beat, local, pulse, t


def travel(x1: float, x2: float, y: float, amount: float, color: str,
           chip: str | None = None) -> list[str]:
    """A lit segment plus a glowing dot moving from x1 to x2."""
    x = mix(x1, x2, ease(amount))
    out = [line(x1, y, x, y, color, 2.5, 0.9)]
    out.append(dot(x, y, color, 6))
    if chip:
        out.append(tag(x, y - 26, chip, color, SURFACE, size=10))
    return out


# ---------------------------------------------------------------------------
# 1. Event-driven intake: your tracker -> [ house ] -> [ machine ] -> back
# ---------------------------------------------------------------------------

SOURCE_ICONS = [("jira", AMBER), ("github", INK), ("gitlab", ORANGE), ("linear", VIOLET)]
ACTIVE_SOURCE = 1  # GitHub

INTAKE_STEPS = [
    "An issue is labelled on GitHub.",
    "Your handler sends one envelope.",
    "Omashiki-Core admits it and freezes the snapshot.",
    "A worker with a free slot takes it and runs the container.",
    "The result returns to the core: branch, files, or actions.",
    "A signed webhook closes the loop on GitHub.",
]

SRC_X, HANDLER_X = 150, 345
CORE_X, CORE_Y = 615, 350
WORKER_X, WORKER_Y = 985, [250, 350, 450]
ACTIVE_WORKER = 1
ROW_Y = 350
DIVIDERS = (440, 800)               # machine boundaries you may or may not have
OUTER = (250, 150, 1156, 560)       # where everything runs
OMASHIKI = (470, 186, 1140, 548)    # core + workers
YOURS = (44, 190, 400, 470)


def box_zone(z: tuple, title: str, color: str, fill: str, opacity: float = 1.0,
             dash: str | None = None, title_anchor: str = "middle") -> list[str]:
    x1, y1, x2, y2 = z
    tx = (x1 + x2) / 2 if title_anchor == "middle" else x1 + 16
    return [
        rect(x1, y1, x2 - x1, y2 - y1, fill=fill, stroke=color, stroke_width=1.5,
             opacity=opacity, dash=dash),
        text(tx, y1 + 20, title, 10, color, 700, anchor=title_anchor, mono=True,
             opacity=opacity, spacing=1.2),
    ]


def intake_frame(frame: int) -> str:
    beat, local, pulse, t = beat_of(frame)
    svg = base(
        "Event-driven intake",
        "Your tracker fires. A result comes back.",
        "Handler, core and workers each run where you put them: one box or many.",
    )
    lit = [beat >= i for i in range(6)]
    a = [1.0 if on else DIM for on in lit]

    # one outer box for everything that runs, split by dashed machine boundaries
    svg += box_zone(OUTER, "", OUTLINE, OUTSIDE_TINT)
    cols = [(OUTER[0], DIVIDERS[0], "any machine", VIOLET if lit[1] else OUTLINE),
            (DIVIDERS[0], DIVIDERS[1], "your machine", BRAND_DIM if lit[2] else OUTLINE),
            (DIVIDERS[1], OUTER[2], "your machine · a vps · anything you enrol",
             INFO if lit[3] else OUTLINE)]
    for x1, x2, title, color in cols:
        svg.append(label((x1 + x2) / 2, OUTER[1] + 20, title, color, 1.0, 10))
    svg += box_zone(OMASHIKI, "omashiki", BRAND if lit[2] else BRAND_DIM, BRAND_TINT,
                    title_anchor="start")
    for dx in DIVIDERS:
        svg.append(line(dx, OUTER[1], dx, OUTER[3], OUTLINE, 1.2, 0.9, "5 6"))
    svg += box_zone(YOURS, "yours", OUTLINE, "none")

    # 01 sources: four trackers, GitHub fires
    positions = [(SRC_X - 45, 265), (SRC_X + 45, 265), (SRC_X - 45, 361), (SRC_X + 45, 361)]
    for i, (name, color) in enumerate(SOURCE_ICONS):
        cx, cy = positions[i]
        active = i == ACTIVE_SOURCE
        op = a[0] * (1.0 if active else 0.45)
        svg += [
            framed(cx, cy, 72, 72, color if active and lit[0] else LINE, op, INSET),
            icon(name, cx, cy, 34, color if active else FAINT, op,
                 glow=active and beat in (0, 5)),
        ]
    gx, gy = positions[ACTIVE_SOURCE]
    if beat == 0:
        svg.append(dot(gx + 30, gy - 30, BRAND, 5 + 3 * pulse))
    svg.append(label(SRC_X, 440, "tracker event", MUTED, a[0]))
    elbow = BRAND if lit[1] else LINE
    svg += [line(gx + 36, gy, SRC_X + 95, gy, elbow, 2, 0.6 if lit[1] else 0.35),
            line(SRC_X + 95, gy, SRC_X + 95, ROW_Y, elbow, 2, 0.6 if lit[1] else 0.35)]

    # 02 handler, in the overlap of yours and your machine
    svg += [
        framed(HANDLER_X, ROW_Y, 96, 96, VIOLET if lit[1] else LINE, a[1], INSET),
        glyph_handler(HANDLER_X, ROW_Y, 30, VIOLET if lit[1] else FAINT, a[1]),
        label(HANDLER_X, 440, "your handler", MUTED, a[1]),
    ]

    # 03 Omashiki-Core
    core_color = BRAND if lit[2] else BRAND_DIM
    svg += node_box(CORE_X, CORE_Y, 150, 60, "Omashiki-Core", core_color, a[2], PANEL, 11)
    svg.append(glyph_house(CORE_X, CORE_Y - 58, 26, core_color, a[2]))
    if beat == 2:
        svg.append(dot(CORE_X + 62, CORE_Y - 18, BRAND, 4 + 2 * pulse))

    # 04 workers: a tree off the core; the one that took the job gets its containers
    for i, wy in enumerate(WORKER_Y):
        won = i == ACTIVE_WORKER and lit[3]
        op = a[3] * (1.0 if won or not lit[3] else 0.45)
        color = INFO if won else (BRAND_DIM if lit[2] else LINE)
        if won:
            svg.append(rect(878, wy - 34, 254, 68, fill=INSET, stroke=INFO, opacity=a[3], dash="3 5"))
        svg.append(curve(CORE_X + 75, CORE_Y, WORKER_X - 95, wy, color, 1.6, op * 0.9))
        svg += node_box(WORKER_X, wy, 190, 40, f"Omashiki-Worker:Node-00{i + 1}", color, op, INSET, 9.5)
        if won:
            grow = local if beat == 3 else 1.0
            svg += container_tree(WORKER_X + 95, wy, 3, grow, INFO, a[3], 22)
    svg += [crossing(DIVIDERS[1], ROW_Y, INFO if lit[3] else OUTLINE),
            label(DIVIDERS[1], ROW_Y - 18, "network", INFO if lit[3] else FAINT, 1.0, 8)]

    # the travelling job; segments light only as the job passes
    if lit[1]:
        svg.append(line(SRC_X + 95, ROW_Y, HANDLER_X - 48, ROW_Y, VIOLET, 2, 0.5))
    if lit[2]:
        svg.append(line(HANDLER_X + 48, ROW_Y, CORE_X - 75, ROW_Y, BRAND, 2, 0.5))
    if beat == 1:
        svg += travel(SRC_X + 95, HANDLER_X - 48, ROW_Y, local, VIOLET)
    elif beat == 2:
        svg += travel(HANDLER_X + 48, CORE_X - 75, ROW_Y, local, BRAND, "POST /jobs")
    elif beat == 3:
        wy = WORKER_Y[ACTIVE_WORKER]
        x = mix(CORE_X + 75, WORKER_X - 95, local)
        svg += [dot(x, wy, INFO, 6), tag(x, wy - 26, "offer", INFO, SURFACE, size=10)]

    # 05 result glyphs under the workers, one of three lit, back to the core
    results = [("git", glyph_branch), ("files", glyph_bundle), ("none", glyph_actions)]
    for i, (name, fn) in enumerate(results):
        cx = WORKER_X + (i - 1) * 60
        chosen = i == 0
        op = a[4] * (1.0 if chosen or not lit[4] else 0.35)
        svg += [fn(cx, 500, 26, BRAND if chosen and lit[4] else FAINT, op),
                label(cx, 528, name, BRAND_SOFT if chosen and lit[4] else FAINT, op, 9)]
    if lit[4]:
        amt = local if beat == 4 else 1.0
        svg += [line(WORKER_X - 100, 500, CORE_X + 40, 500, BRAND, 2.5, 0.9),
                crossing(DIVIDERS[1], 500, BRAND),
                arrow(CORE_X + 40, 500, CORE_X + 40, CORE_Y + 34, BRAND, 2.5, 0.9),
                dot(mix(WORKER_X - 100, CORE_X + 40, amt), 500, BRAND, 6)]

    # 06 webhook from the core back to GitHub
    if lit[5]:
        x = mix(CORE_X - 40, SRC_X + 95, local if beat == 5 else 1.0)
        svg += [
            line(CORE_X - 40, CORE_Y + 30, CORE_X - 40, 512, BRAND, 2.5, 0.9),
            line(CORE_X - 40, 512, x, 512, BRAND, 2.5, 0.9),
            dot(x, 512, BRAND, 6),
            tag(x, 486, "webhook", BRAND, SURFACE, size=10),
        ]
        if beat == 5 and local > 0.95:
            svg.append(line(SRC_X + 95, 512, SRC_X + 95, ROW_Y, BRAND, 2, 0.6))

    svg.append(text(703, 578, "dashed lines are machine boundaries you may or may not have · one box or a fleet, same picture",
                    9, FAINT, 600, anchor="middle", mono=True))

    svg += narration(beat + 1, BEATS, INTAKE_STEPS[beat])
    svg.append("</svg>")
    return "".join(svg)


# ---------------------------------------------------------------------------
# 2. Governed job lifecycle: what one machine does with one offer
# ---------------------------------------------------------------------------

LIFECYCLE_STEPS = [
    "The worker polls; the core offers one queued job; the worker accepts into a free slot.",
    "The snapshot frozen at admission travels with the offer. The worker runs exactly that.",
    "The worker cuts a clean workspace for the sink.",
    "One agent turn runs on the worker. Model, tools and identity are served by the core.",
    "The worker verifies the result and completes back to the core.",
    "The core records the event and signs the webhook.",
]

STAGE_X = [150, 330, 510, 690, 870, 1050]
STAGE_LABEL = ["accept", "snapshot", "workspace", "run", "result", "return"]
CORE_LANE = (56, 140, 1144, 296)
WORKER_LANE = (56, 348, 1144, 562)
CY, WY = 226, 462          # box centres in each lane
TL_Y = 322                 # timeline between the lanes


def lane(z: tuple, title: str, color: str) -> list[str]:
    x1, y1, x2, y2 = z
    return [
        rect(x1, y1, x2 - x1, y2 - y1, fill=OUTSIDE_TINT, stroke=color, stroke_width=1.5,
             opacity=0.95, dash="5 7"),
        square(x1 + 18, y1 + 18, color, 8),
        text(x1 + 32, y1 + 22, title, 10.5, color, 800, mono=True, spacing=1.4),
    ]


def down(x: float, y1: float, y2: float, color: str, amount: float, chip: str | None = None) -> list[str]:
    """A vertical hand-off between the lanes with a moving dot."""
    y = mix(y1, y2, ease(amount))
    out = [line(x, y1, x, y2, color, 1.5, 0.5, "3 6"), dot(x, y, color, 5)]
    if chip:
        # labels sit in the gap between the lanes, beside the crossing, never on a title
        out.append(text(x + 12, 313, chip, 9, color, 800, mono=True, spacing=1.0))
    return out


def lifecycle_frame(frame: int) -> str:
    beat, local, pulse, t = beat_of(frame)
    svg = base(
        "Inside the boundary",
        "One offer becomes one governed sandbox run.",
        "What the core does stays on the core. What the worker does stays on the worker.",
    )
    lit = [beat >= i for i in range(6)]
    a = [1.0 if on else DIM for on in lit]

    svg += lane(CORE_LANE, "OMASHIKI-CORE", BRAND)
    svg += lane(WORKER_LANE, "OMASHIKI-WORKER:NODE-002", INFO)

    # timeline between the lanes
    svg.append(line(STAGE_X[0], TL_Y, STAGE_X[-1], TL_Y, LINE, 2, 0.7))
    if beat < 5:
        svg.append(line(STAGE_X[0], TL_Y, mix(STAGE_X[beat], STAGE_X[beat + 1], local), TL_Y, BRAND, 2.5))
    else:
        svg.append(line(STAGE_X[0], TL_Y, STAGE_X[-1], TL_Y, BRAND, 2.5))
    for i, x in enumerate(STAGE_X):
        svg += [square(x, TL_Y, BRAND if lit[i] else OUTLINE, 10 if beat == i else 8,
                       1.0 if lit[i] else 0.6),
                label(x, TL_Y + 22, STAGE_LABEL[i],
                      BRAND if beat == i else (INK if lit[i] else FAINT), 1.0, 10)]

    # ---- 01 accept: core holds the queue, worker takes a slot -----------------
    x = STAGE_X[0]
    svg.append(framed(x, CY, 130, 100, BRAND if lit[0] else LINE, a[0], INSET))
    for i in range(3):
        on = lit[0] and i == 0
        svg.append(rect(x - 45 + i * 30, CY - 14, 24, 28, fill=PANEL,
                        stroke=BRAND if on else OUTLINE, opacity=a[0]))
        if on:
            svg.append(square(x - 33, CY, BRAND, 8, a[0] * (pulse if beat == 0 else 1.0)))
    svg.append(label(x, CY + 36, "queue", BRAND_SOFT if lit[0] else FAINT, a[0], 9))

    svg.append(framed(x, WY, 130, 150, INFO if lit[0] else LINE, a[0], INSET))
    svg.append(square(x - 30, WY - 30, INFO if lit[0] else FAINT, 12, a[0]))
    svg += container_tree(x - 30, WY - 30, 2, 1.0 if lit[0] else 0.0, INFO, a[0], 26)
    svg.append(label(x, WY + 40, "slot 1 / 2", INFO if lit[0] else FAINT, a[0], 10))
    for i in range(2):
        svg.append(square(x - 10 + i * 20, WY + 56, INFO if (i == 0 and lit[0]) else OUTLINE, 9, a[0]))
    if beat == 0:
        if local < 0.5:
            svg += down(x, WY - 75, CY + 50, INFO, local * 2, "poll")
        else:
            svg += down(x, CY + 50, WY - 75, BRAND, (local - 0.5) * 2, "offer")

    # ---- 02 snapshot: frozen on the core, carried down to the worker ----------
    x = STAGE_X[1]
    rows = [("git", "repo"), ("box", "runtime"), ("github", "identity"), ("jira", "context")]

    def snapshot_card(cy: float, h: float, color: str, op: float, reveal_all: bool) -> list[str]:
        out = [framed(x, cy, 130, h, color, op, INSET)]
        for r, (ic, lab) in enumerate(rows):
            ry = cy - h / 2 + 22 + r * 24
            reveal = 1.0 if reveal_all else clamp((local - r * 0.15) / 0.3)
            mark = (glyph_box(x - 38, ry, 16, INK, op * reveal) if ic == "box"
                    else icon(ic, x - 38, ry, 16, INK, op * reveal))
            out += [mark, text(x - 22, ry + 4, lab, 9.5, INK, 600, mono=True, opacity=op * reveal)]
        return out

    svg += snapshot_card(CY, 110, BRAND if lit[1] else LINE, a[1], beat != 1 or True)
    svg.append(label(x, CY + 66, "frozen at admission", BRAND_SOFT if lit[1] else FAINT, a[1], 8.5))
    if lit[1]:
        arrived = 1.0 if beat > 1 else clamp((local - 0.5) * 2)
        svg += snapshot_card(WY, 120, INFO, a[1] * max(arrived, 0.15), beat > 1)
        svg.append(label(x, WY + 72, "the worker runs this", INFO, a[1] * arrived, 8.5))
        if beat == 1:
            svg += down(x, CY + 55, WY - 60, BRAND, min(1.0, local * 2))
    else:
        svg.append(framed(x, WY, 130, 120, LINE, a[1], INSET))

    # ---- 03 workspace: worker only --------------------------------------------
    x = STAGE_X[2]
    svg += [
        framed(x, WY, 130, 150, INFO if lit[2] else LINE, a[2], INSET),
        glyph_branch(x, WY - 12, 56, INFO if lit[2] else FAINT, a[2]),
        label(x, WY + 46, "clean tree", INFO if lit[2] else FAINT, a[2], 9),
    ]

    # ---- 04 run: sandbox on the worker, served by the core ---------------------
    x = STAGE_X[3]
    svg += [
        framed(x, WY, 150, 150, BRAND if lit[3] else LINE, a[3], INSET),
        glyph_box(x, WY - 12, 64, BRAND if lit[3] else FAINT, a[3]),
        label(x, WY + 50, "sandbox", BRAND_SOFT if lit[3] else FAINT, a[3], 9),
    ]
    services = [("model", -64, "gateway"), ("tools", 0, "proxy"), ("identity", 64, "broker")]
    svg.append(framed(x, CY, 216, 100, BRAND if lit[3] else LINE, a[3], INSET))
    for i, (lab, dx, sub) in enumerate(services):
        on = lit[3] and (beat > 3 or local > 0.2 + i * 0.25)
        svg += [rect(x + dx - 30, CY - 34, 60, 46, fill=PANEL, stroke=BRAND if on else OUTLINE,
                     opacity=a[3]),
                label(x + dx, CY - 16, lab, BRAND_SOFT if on else FAINT, a[3], 7.5),
                label(x + dx, CY + 1, sub, MUTED if on else FAINT, a[3], 6.5),
                line(x + dx, WY - 75, x + dx, CY + 50, BRAND if on else LINE, 1.5,
                     0.8 if on else 0.25, "3 6")]
        if on and beat == 3:
            svg.append(dot(x + dx, mix(WY - 75, CY + 50, (local * 1.6 + i * 0.33) % 1.0), BRAND, 4))
    svg.append(label(x, CY + 36, "served by the core", BRAND_SOFT if lit[3] else FAINT, a[3], 8.5))

    # ---- 05 result: verified on the worker, completed to the core --------------
    x = STAGE_X[4]
    svg.append(framed(x, WY, 130, 150, BRAND if lit[4] else LINE, a[4], INSET))
    for i, fn in enumerate([glyph_branch, glyph_bundle, glyph_actions]):
        chosen = i == 0
        op = a[4] * (1.0 if chosen or not lit[4] else 0.3)
        svg.append(fn(x + (i - 1) * 38, WY - 14, 32, BRAND if chosen and lit[4] else FAINT, op))
    svg.append(label(x, WY + 46, "verified", BRAND_SOFT if lit[4] else FAINT, a[4], 9))
    if lit[4]:
        svg.append(square(x + 50, WY - 60, BRAND, 9 * (pulse if beat == 4 else 1.0)))
        svg += down(x, WY - 75, CY + 50, BRAND, 1.0 if beat > 4 else local, "complete")
    svg.append(framed(x, CY, 130, 100, BRAND if lit[4] else LINE, a[4], INSET))
    svg += [label(x, CY - 12, "attempt 1", INK if lit[4] else FAINT, a[4], 9),
            label(x, CY + 6, "succeeded" if lit[4] else "running",
                  BRAND_SOFT if lit[4] else FAINT, a[4], 9),
            label(x, CY + 36, "job row", BRAND_SOFT if lit[4] else FAINT, a[4], 9)]

    # ---- 06 return: core only, webhook leaves the core --------------------------
    x = STAGE_X[5]
    svg += [
        framed(x, CY, 130, 100, BRAND if lit[5] else LINE, a[5], INSET),
        glyph_house(x, CY - 8, 40, BRAND if lit[5] else FAINT, a[5]),
        label(x, CY + 36, "event + outbox", BRAND_SOFT if lit[5] else FAINT, a[5], 9),
    ]
    if beat == 5:
        out = clamp((local - 0.3) / 0.7)
        svg += [arrow(x + 65, CY, 1178, CY, BRAND, 2.5, 0.35 + 0.65 * out),
                crossing(CORE_LANE[2], CY, BRAND, 0.4 + 0.6 * out)]
        if out > 0:
            svg += [dot(mix(x + 65, 1170, out), CY, BRAND, 6),
                    text(1152, CY - 14, "webhook", 8.5, BRAND, 800, anchor="middle",
                         mono=True, opacity=out, spacing=1.0)]

    svg.append(text(600, 578, "failure is also a result · retry reopens the same job",
                    9.5, FAINT, 600, anchor="middle", mono=True))

    svg += narration(beat + 1, BEATS, LIFECYCLE_STEPS[beat])
    svg.append("</svg>")
    return "".join(svg)


def render(name: str, frame_builder) -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    destination = OUTPUT / name

    with tempfile.TemporaryDirectory(prefix="omashiki-gif-") as temp:
        frames = pathlib.Path(temp)
        for frame in range(FRAMES):
            (frames / f"{frame:03d}.svg").write_text(frame_builder(frame), encoding="utf-8")

        subprocess.run(
            [
                "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                "-framerate", str(FPS), "-i", str(frames / "%03d.svg"),
                "-filter_complex",
                "[0:v]split[a][b];[a]palettegen=max_colors=96:stats_mode=diff[p];"
                "[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle",
                "-loop", "0", str(destination),
            ],
            check=True,
        )
        print(f"rendered {destination.relative_to(ROOT)}")


def main() -> None:
    render("event-driven-intake.gif", intake_frame)
    render("governed-job-lifecycle.gif", lifecycle_frame)


if __name__ == "__main__":
    main()
