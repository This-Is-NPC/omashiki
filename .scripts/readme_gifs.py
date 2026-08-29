#!/usr/bin/env python3
"""Render the README architecture GIFs from deterministic SVG frames.

Two animations, one story. The first follows a tracker event across the
Omashiki boundary and back onto the ticket. The second opens the claimed
attempt and shows what the node actually runs.

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
# 1. Event-driven intake: your tracker -> [ OMASHIKI ] -> your tracker
# ---------------------------------------------------------------------------

SOURCES = [
    ("JIRA", "PROJ-4821 → Ready for agent", AMBER),
    ("GITHUB", "issue #182 labeled agent", VIOLET),
    ("AZURE DEVOPS", "work item 5507 → Active", MAGENTA),
    ("SERVICENOW", "INC0099 → automation", ORANGE),
]

ENVELOPE = [
    (0, 'POST /api/v1/jobs', VIOLET, True),
    (0, '{', MUTED, False),
    (1, '"repo": "acme/checkout",', INK, False),
    (1, '"environment": "review-and-fix",', INK, False),
    (1, '"idempotency_key": "PROJ-4821/1",', INK, False),
    (1, '"payload": {', MUTED, False),
    (2, '"instruction": "Fix the failing…",', INK, False),
    (2, '"context": {"ticket":"PROJ-4821"}', INFO, False),
    (1, '}', MUTED, False),
    (0, '}', MUTED, False),
]

NODES = [
    ("node-a", "2 / 2 busy", "", False),
    ("node-b", "0 / 2 busy", "claims job/4f2a", True),
    ("node-c", "1 / 1 busy", "", False),
]

INTAKE_STEPS = [
    "A tracker event fires — PROJ-4821 moves to Ready for agent. Still entirely your side.",
    "Your handler maps that event to one envelope. This is the last code you write.",
    "Omashiki starts here: admission validates the contract and freezes an immutable snapshot.",
    "The job is durable in PostgreSQL. Every healthy node may claim it — exactly one wins.",
    "Omashiki ends here: a committed branch and one signed terminal webhook leave the boundary.",
    "Back on your side, your handler posts the branch onto PROJ-4821 and the ticket moves on.",
]

BOX_CENTERS = [174, 464, 781, 1022]
ZONE_A = (44, 620)      # your side
ZONE_B = (676, 1156)    # omashiki
GATE = (ZONE_A[1] + ZONE_B[0]) / 2


def intake_frame(frame: int) -> str:
    t = frame / FRAMES
    beat = min(BEATS - 1, int(t * BEATS))
    local = ease((t * BEATS) - beat)
    pulse = 0.55 + 0.45 * math.sin(t * math.tau * 3) ** 2

    svg = base(
        "Event-driven intake",
        "Your tracker fires. Omashiki returns a branch.",
        "The boundary is the HTTP contract: everything green is Omashiki, everything grey stays yours.",
    )

    inside = beat in (2, 3, 4)
    lit = [beat >= index for index in range(4)]
    alpha = [1.0 if on else DIM for on in lit]

    # --- Boundary zones -----------------------------------------------------
    svg += [
        rect(ZONE_A[0], 138, ZONE_A[1] - ZONE_A[0], 440, fill=OUTSIDE_TINT,
             stroke=OUTLINE, dash="5 7"),
        rect(ZONE_B[0], 138, ZONE_B[1] - ZONE_B[0], 440, fill=BRAND_TINT,
             stroke=BRAND if inside else BRAND_DIM, stroke_width=1.5, dash="5 7"),
        tag(332, 138, "YOUR SIDE", OUTLINE, SURFACE),
        tag(916, 138, "OMASHIKI", BRAND, SURFACE),
        text(332, 566, "your event handlers, your ticket updates", 10, FAINT, 600,
             anchor="middle", mono=True),
        text(916, 566, "starts at admission · ends at the signed webhook", 10,
             BRAND_SOFT, 600, anchor="middle", mono=True),
    ]

    # --- The job in flight, coloured by its real status ---------------------
    travel = clamp((t - 1 / BEATS) / (3 / BEATS)) * 3
    index = min(2, int(travel))
    pill_x = mix(BOX_CENTERS[index], BOX_CENTERS[index + 1], ease(travel - index))
    pill_color = AMBER if beat < 2 else (INFO if beat < 4 else BRAND)
    svg += [
        line(BOX_CENTERS[0], 172, BOX_CENTERS[-1], 172, LINE, 2, 0.7, "4 8"),
        line(BOX_CENTERS[0], 172, pill_x, 172, pill_color, 2, 0.85),
        crossing(GATE, 172, BRAND if beat >= 2 else OUTLINE),
        tag(pill_x, 172, "PROJ-4821", pill_color),
    ]

    # --- 01 source systems --------------------------------------------------
    svg += [rect(60, 200, 228, 228, fill=PANEL, stroke=OUTLINE, opacity=alpha[0])]
    svg += panel_head(78, 228, "01", "SOURCE SYSTEM", MUTED, alpha[0])
    for row, (system, change, color) in enumerate(SOURCES):
        y = 250 + row * 44
        selected = row == 0
        row_alpha = alpha[0] * (1.0 if selected else 0.7)
        svg += [
            rect(78, y, 192, 36, fill=INSET, stroke=color if selected else LINE,
                 opacity=row_alpha),
            square(92, y + 18, color, 7,
                   row_alpha * (pulse if selected and beat == 0 else 1.0)),
            text(106, y + 15, system, 9.5, color if selected else MUTED, 800,
                 mono=True, spacing=1.1, opacity=row_alpha),
            text(106, y + 29, change, 9.5, MUTED, 500, mono=True, opacity=row_alpha),
        ]
    svg.append(text(78, 446, "any system that emits events", 10, FAINT, 600,
                    mono=True, opacity=alpha[0]))

    # --- 02 your handler ----------------------------------------------------
    svg += [rect(324, 200, 280, 228, fill=PANEL, stroke=VIOLET if lit[1] else LINE,
                 opacity=alpha[1])]
    svg += panel_head(342, 228, "02", "YOUR HANDLER", VIOLET, alpha[1])
    for row, (indent, content, color, bold) in enumerate(ENVELOPE):
        reveal = clamp((local - row * 0.06) / 0.12) if beat == 1 else float(lit[1])
        svg.append(text(342 + indent * 11, 252 + row * 17, content, 10, color,
                        800 if bold else 600, mono=True, opacity=alpha[1] * reveal))
    svg.append(text(342, 446, "your code · your bearer token", 10, FAINT, 600,
                    mono=True, opacity=alpha[1]))

    # --- 03 admission + durable queue --------------------------------------
    svg += [rect(692, 200, 178, 228, fill=PANEL, stroke=BRAND if lit[2] else BRAND_DIM,
                 opacity=alpha[2])]
    svg += panel_head(708, 228, "03", "ADMISSION", BRAND, alpha[2])
    checks = ["contract valid", "repo + env resolved", "snapshot frozen",
              "idempotency held"]
    for row, label in enumerate(checks):
        reveal = clamp((local - row * 0.1) / 0.14) if beat == 2 else float(lit[2])
        svg += [
            square(712, 250 + row * 21, BRAND, 6, alpha[2] * reveal),
            text(726, 254 + row * 21, label, 9.5, INK, 600, mono=True,
                 opacity=alpha[2] * reveal),
        ]
    svg += [
        rect(708, 340, 146, 74, fill=INSET, stroke=BRAND, opacity=alpha[2]),
        text(781, 363, "PostgreSQL", 16, INK, 700, anchor="middle", opacity=alpha[2]),
        text(781, 381, "one durable queue", 9.5, MUTED, 500, anchor="middle",
             mono=True, opacity=alpha[2]),
        text(781, 401, "queued · attempt 1", 9.5, INFO, 700, anchor="middle",
             mono=True, opacity=alpha[2]),
    ]
    svg.append(text(708, 446, "caller selects nothing else", 10, FAINT, 600,
                    mono=True, opacity=alpha[2]))

    # --- 04 node claim ------------------------------------------------------
    svg += [rect(904, 200, 236, 228, fill=PANEL, stroke=BRAND if lit[3] else BRAND_DIM,
                 opacity=alpha[3])]
    svg += panel_head(922, 228, "04", "ANY HEALTHY NODE", BRAND, alpha[3])
    for row, (name, capacity, note, claims) in enumerate(NODES):
        y = 248 + row * 54
        won = claims and beat >= 3
        svg += [
            rect(922, y, 200, 46, fill=INSET, stroke=INFO if won else LINE,
                 opacity=alpha[3]),
            square(938, y + 16, INFO if won else FAINT, 7,
                   alpha[3] * (pulse if won else 1.0)),
            text(952, y + 20, f"omashiki@{name}", 10, INK if won else MUTED, 700,
                 mono=True, opacity=alpha[3]),
            text(952, y + 36, note if won else capacity, 9.5,
                 INFO if won else FAINT, 700 if won else 500, mono=True,
                 opacity=alpha[3]),
        ]
    svg.append(text(922, 446, "lock + lease + capacity token", 10, FAINT, 600,
                    mono=True, opacity=alpha[3]))

    # --- Flow between the panels -------------------------------------------
    svg += [
        arrow(288, 316, 324, 316, VIOLET if beat >= 1 else LINE, 2,
              1.0 if beat >= 1 else 0.4),
        text(306, 304, "event", 9, MUTED if beat >= 1 else FAINT, 700,
             anchor="middle", mono=True),
        arrow(604, 316, 692, 316, BRAND if beat >= 2 else LINE, 2.5,
              1.0 if beat >= 2 else 0.4),
        text(648, 300, "POST /jobs", 9.5, BRAND if beat >= 2 else FAINT, 800,
             anchor="middle", mono=True),
        crossing(648, 316, BRAND if beat >= 2 else OUTLINE),
        text(648, 340, "ingress", 8.5, FAINT, 700, anchor="middle", mono=True),
        arrow(870, 316, 904, 316, BRAND if beat >= 3 else LINE, 2,
              1.0 if beat >= 3 else 0.4),
        text(887, 304, "claim", 9, MUTED if beat >= 3 else FAINT, 700,
             anchor="middle", mono=True),
    ]

    # --- The return leg, crossing the boundary outward ----------------------
    back = clamp((t - 4 / BEATS) / (2 / BEATS))
    out_alpha = 1.0 if beat >= 4 else DIM
    home_alpha = 1.0 if beat >= 5 else DIM
    svg += [
        rect(700, 470, 436, 72, fill=PANEL, stroke=BRAND if beat >= 4 else BRAND_DIM,
             opacity=out_alpha),
        text(718, 494, "05", 10, BRAND, 800, mono=True, spacing=1.2, opacity=out_alpha),
        text(740, 494, "TERMINAL EVENT", 10, INK, 800, mono=True, spacing=1.3,
             opacity=out_alpha),
        text(718, 514, "job.succeeded · branch feat/proj-4821", 10.5, INK, 700,
             mono=True, opacity=out_alpha),
        text(718, 531, "signed HMAC-SHA256 · at-least-once · retried 24h", 9.5,
             MUTED, 500, mono=True, opacity=out_alpha),
        rect(60, 470, 400, 72, fill=PANEL, stroke=OUTLINE, opacity=home_alpha),
        text(78, 494, "06", 10, MUTED, 800, mono=True, spacing=1.2, opacity=home_alpha),
        text(100, 494, "BACK ON THE TICKET", 10, INK, 800, mono=True, spacing=1.3,
             opacity=home_alpha),
        text(78, 514, "comment: feat/proj-4821 ready for review", 10.5, INK, 700,
             mono=True, opacity=home_alpha),
        text(78, 531, "PROJ-4821 transitions to In review", 9.5, MUTED, 500,
             mono=True, opacity=home_alpha),
        arrow(690, 506, 470, 506, BRAND if beat >= 4 else LINE, 2.5, out_alpha),
        text(648, 490, "webhook", 9.5, BRAND if beat >= 4 else FAINT, 800,
             anchor="middle", mono=True),
        crossing(648, 506, BRAND if beat >= 4 else OUTLINE, out_alpha),
        text(648, 530, "egress", 8.5, FAINT, 700, anchor="middle", mono=True),
    ]
    if beat >= 4:
        svg.append(tag(mix(672, 488, ease(back)), 506, "job.succeeded", BRAND))

    svg += narration(beat + 1, BEATS, INTAKE_STEPS[beat])
    svg.append("</svg>")
    return "".join(svg)


# ---------------------------------------------------------------------------
# 2. Governed job lifecycle: what the claiming node actually runs
# ---------------------------------------------------------------------------

STAGES = [
    ("01", "CLAIM", "lease the job"),
    ("02", "SNAPSHOT", "frozen registry"),
    ("03", "PREPARE", "clean worktree"),
    ("04", "EXECUTE", "one harness turn"),
    ("05", "FINALIZE", "commit + verify"),
    ("06", "RETURN", "event + outbox"),
]

SNAPSHOT = [
    ("ticket", "PROJ-4821", INFO),
    ("repo", "acme/checkout", INK),
    ("base", "main @ 9f2c1ab", INK),
    ("environment", "review-and-fix", INK),
    ("runtime", "docker.runc.debian", INK),
    ("plugin", "claude-code", INK),
    ("image", "omashiki/agent-claude", INK),
]

CONTAINER_BLOCKS = [
    (0, "/workspace", "feat/proj-4821 @ 9f2c1ab", INFO),
    (1, "EGRESS", "declared network policy", VIOLET),
    (2, "LIMITS", "cpu · memory · timeout", VIOLET),
    (3, "TOOL PROXY", "declared MCP servers only", VIOLET),
    (4, "LLM GATEWAY", "short-lived scoped claim", INFO),
    (5, "HARNESS TURN", "instruction + ticket context", BRAND),
]

RESULT = [
    ("branch", "feat/proj-4821", INFO),
    ("base_sha", "9f2c1ab", INK),
    ("head_sha", "4d81e07", INK),
    ("worktree_clean", "true", BRAND),
    ("event", "job.succeeded", BRAND),
]

LIFECYCLE_STEPS = [
    "node-a wins the row lock, takes a fencing lease, and reserves one capacity token.",
    "The snapshot frozen at admission — not the payload — decides runtime, image, plugin, and mounts.",
    "A clean worktree is cut from main @ 9f2c1ab onto feat/proj-4821 before anything runs.",
    "One harness turn runs in the container. Egress, tools, packages, and the gateway are claim-scoped.",
    "Success demands a clean tree and a real commit: base and head revisions, or the attempt fails.",
    "The terminal event and its signed outbox row commit together — the only thing that leaves.",
]


def lifecycle_frame(frame: int) -> str:
    t = frame / FRAMES
    beat = min(BEATS - 1, int(t * BEATS))
    local = ease((t * BEATS) - beat)
    pulse = 0.55 + 0.45 * math.sin(t * math.tau * 3) ** 2

    svg = base(
        "Inside the boundary",
        "The claimed job becomes a governed container run.",
        "Same job as above, now past admission: everything on this frame is Omashiki's side of the line.",
    )

    # --- Boundary strip: what enters, what leaves ---------------------------
    svg += [
        rect(56, 134, 1088, 32, fill=BRAND_TINT, stroke=BRAND_DIM, dash="5 7"),
        square(74, 150, BRAND, 8),
        text(88, 154, "INSIDE OMASHIKI", 10.5, BRAND, 800, mono=True, spacing=1.4),
        text(250, 154, "◀ in · one claimed job from the durable queue", 10, MUTED,
             600, mono=True),
        text(1126, 154, "out · committed branch + signed webhook to your receiver ▶",
             10, BRAND_SOFT, 600, anchor="end", mono=True),
    ]

    # --- Stage rail ---------------------------------------------------------
    rail_y = 200
    first_x, last_x = 120, 1080
    svg.append(line(first_x, rail_y, last_x, rail_y, LINE, 3))
    marker = first_x + (last_x - first_x) * clamp((beat + local) / (BEATS - 1))
    svg.append(line(first_x, rail_y, marker, rail_y, BRAND, 3))
    for index, (number, name, detail) in enumerate(STAGES):
        x = first_x + (last_x - first_x) * index / (len(STAGES) - 1)
        done = index < beat
        active = index == beat
        color = INFO if active else (BRAND if done else LINE)
        svg += [
            square(x, rail_y, color, 15 if active else 10, pulse if active else 1.0),
            text(x, 176, number, 10, color if (done or active) else FAINT, 800,
                 anchor="middle", mono=True, spacing=1.1),
            text(x, 228, name, 11.5, INK if (done or active) else MUTED, 800,
                 anchor="middle", mono=True, spacing=1.0),
            text(x, 244, detail, 9.5, MUTED if (done or active) else FAINT, 500,
                 anchor="middle", mono=True),
        ]

    snapshot_alpha = 1.0 if beat >= 1 else 0.5
    container_alpha = 1.0 if beat >= 2 else DIM
    result_alpha = 1.0 if beat >= 4 else DIM

    # --- Frozen input -------------------------------------------------------
    svg += [rect(56, 268, 240, 248, fill=PANEL, stroke=BRAND_DIM if beat >= 1 else LINE,
                 opacity=snapshot_alpha)]
    svg += panel_head(76, 296, "IN", "FROZEN AT ADMISSION", BRAND_DIM, snapshot_alpha)
    for row, (key, value, color) in enumerate(SNAPSHOT):
        reveal = clamp((local - row * 0.08) / 0.12) if beat == 1 else float(beat >= 1)
        reveal = reveal if beat >= 1 else 0.6
        svg += kv(76, 324 + row * 22, key, value, snapshot_alpha * reveal, color)
    svg.append(text(76, 494, "catalog reloads reach new jobs only", 10, BRAND_SOFT,
                    600, mono=True, opacity=snapshot_alpha))

    # --- The container ------------------------------------------------------
    svg += [
        rect(324, 268, 612, 248, fill=PANEL_2, stroke=BRAND if beat >= 2 else LINE,
             opacity=container_alpha),
        text(344, 296, "RUN", 11, BRAND, 800, mono=True, spacing=1.2,
             opacity=container_alpha),
        text(380, 296, "ONE ATTEMPT, ONE CONTAINER", 11, INK, 800, mono=True,
             spacing=1.4, opacity=container_alpha),
        text(916, 296, "docker.runc.debian", 10, MUTED, 600, anchor="end", mono=True,
             opacity=container_alpha),
    ]
    for slot, label, detail, color in CONTAINER_BLOCKS:
        column, row = slot % 3, slot // 3
        x = 344 + column * 200
        y = 314 + row * 90
        if slot == 0:
            reveal = 0.0 if beat < 2 else (clamp(local / 0.45) if beat == 2 else 1.0)
        elif beat < 3:
            reveal = 0.0
        elif beat == 3:
            reveal = clamp((local - (slot - 1) * 0.13) / 0.18)
        else:
            reveal = 1.0
        svg += [
            rect(x, y, 184, 74, fill=INSET, stroke=color if reveal > 0.6 else LINE,
                 opacity=container_alpha * mix(0.4, 1.0, reveal)),
            text(x + 16, y + 30, label, 10.5, color, 800, mono=True, spacing=1.0,
                 opacity=container_alpha * reveal),
            text(x + 16, y + 49, detail, 9.5, MUTED, 500, mono=True,
                 opacity=container_alpha * reveal),
        ]
    if beat < 2:
        waiting = [
            "node-a: row lock → fencing lease → capacity token 1 of 2",
            "resolving the frozen snapshot — no container started yet",
        ][beat]
        svg += [
            square(630, 372, INFO, 8, pulse),
            text(630, 404, waiting, 12, MUTED, 600, anchor="middle", mono=True),
        ]
    svg.append(text(344, 494,
                    "nothing here came from the payload — no provider, model, credential, or mount",
                    10, FAINT, 600, mono=True, opacity=container_alpha))

    # --- Durable result -----------------------------------------------------
    svg += [rect(964, 268, 180, 248, fill=PANEL, stroke=BRAND if beat >= 4 else LINE,
                 opacity=result_alpha)]
    svg += panel_head(982, 296, "OUT", "DURABLE RESULT", BRAND, result_alpha)
    for row, (key, value, color) in enumerate(RESULT):
        reveal = clamp((local - row * 0.1) / 0.14) if beat == 4 else float(beat >= 4)
        svg += [
            text(982, 326 + row * 32, key, 9.5, MUTED, 600, mono=True,
                 opacity=result_alpha * reveal),
            text(982, 342 + row * 32, value, 10.5, color, 700, mono=True,
                 opacity=result_alpha * reveal),
        ]
    svg.append(text(982, 494, "webhook signed", 10, BRAND_SOFT, 700, mono=True,
                    opacity=result_alpha * (1.0 if beat >= 5 else 0.0)))

    svg += [
        arrow(296, 392, 324, 392, BRAND_DIM if beat >= 1 else LINE, 2,
              1.0 if beat >= 1 else 0.4),
        arrow(936, 392, 964, 392, BRAND if beat >= 4 else LINE, 2,
              1.0 if beat >= 4 else 0.4),
    ]

    svg += [
        line(56, 542, 1144, 542, LINE, 1, 0.8),
        text(56, 566, "FAILURE IS ALSO A RESULT", 10, CORAL, 800, mono=True, spacing=1.3),
        text(258, 566,
             "durable error record · events retained · retry reopens the same job as attempt 2 · the webhook fires either way",
             10.5, MUTED, 500, mono=True),
    ]
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
