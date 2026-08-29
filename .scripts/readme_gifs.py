#!/usr/bin/env python3
"""Render the README architecture GIFs from deterministic SVG frames."""

from __future__ import annotations

import html
import math
import pathlib
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "docs" / "assets"
WIDTH = 1200
HEIGHT = 620
FPS = 9
FRAMES = 72

INK = "#f5f3ee"
MUTED = "#8d93a1"
PANEL = "#11151d"
PANEL_2 = "#171c26"
LINE = "#2b3240"
ORANGE = "#fd4f00"
PURPLE = "#9b87f5"
CYAN = "#65d9e8"
GREEN = "#75d39b"


def clamp(value: float, low: float = 0.0, high: float = 1.0) -> float:
    return max(low, min(high, value))


def esc(value: object) -> str:
    return html.escape(str(value))


def text(x: float, y: float, value: object, size: int = 16, color: str = INK,
         weight: int = 500, anchor: str = "start", mono: bool = False,
         opacity: float = 1.0, spacing: float = 0.0) -> str:
    family = "'JetBrains Mono', monospace" if mono else "'Liberation Sans', sans-serif"
    return (
        f'<text x="{x}" y="{y}" fill="{color}" font-family="{family}" '
        f'font-size="{size}" font-weight="{weight}" text-anchor="{anchor}" '
        f'letter-spacing="{spacing}" opacity="{opacity:.3f}">{esc(value)}</text>'
    )


def rect(x: float, y: float, width: float, height: float, fill: str = PANEL,
         stroke: str = LINE, radius: float = 18, stroke_width: float = 1,
         opacity: float = 1.0, dash: str | None = None) -> str:
    dashed = f' stroke-dasharray="{dash}"' if dash else ""
    return (
        f'<rect x="{x}" y="{y}" width="{width}" height="{height}" rx="{radius}" '
        f'fill="{fill}" stroke="{stroke}" stroke-width="{stroke_width}" '
        f'opacity="{opacity:.3f}"{dashed}/>'
    )


def line(x1: float, y1: float, x2: float, y2: float, color: str = LINE,
         width: float = 2, opacity: float = 1.0, dash: str | None = None) -> str:
    dashed = f' stroke-dasharray="{dash}"' if dash else ""
    return (
        f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" '
        f'stroke-width="{width}" stroke-linecap="round" opacity="{opacity:.3f}"{dashed}/>'
    )


def dot(x: float, y: float, color: str = ORANGE, radius: float = 7,
        opacity: float = 1.0) -> str:
    return (
        f'<circle cx="{x}" cy="{y}" r="{radius}" fill="{color}" '
        f'opacity="{opacity:.3f}" filter="url(#glow)"/>'
    )


def base(title: str, eyebrow: str, subtitle: str) -> list[str]:
    return [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT}" '
        f'viewBox="0 0 {WIDTH} {HEIGHT}">',
        """
        <defs>
          <pattern id="grid" width="32" height="32" patternUnits="userSpaceOnUse">
            <path d="M32 0H0V32" fill="none" stroke="#202631" stroke-width="1" opacity=".45"/>
          </pattern>
          <filter id="glow" x="-200%" y="-200%" width="400%" height="400%">
            <feGaussianBlur stdDeviation="4" result="blur"/>
            <feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge>
          </filter>
          <linearGradient id="panelGlow" x1="0" x2="1">
            <stop offset="0" stop-color="#171c26"/><stop offset="1" stop-color="#11151d"/>
          </linearGradient>
        </defs>
        <rect width="1200" height="620" fill="#090b10"/>
        <rect width="1200" height="620" fill="url(#grid)"/>
        <circle cx="1080" cy="-40" r="300" fill="#fd4f00" opacity=".035"/>
        """,
        text(64, 55, eyebrow.upper(), 12, ORANGE, 700, mono=True, spacing=2.2),
        text(64, 96, title, 34, INK, 700),
        text(64, 125, subtitle, 15, MUTED, 400),
        text(1136, 60, "OMASHIKI", 13, INK, 800, anchor="end", mono=True, spacing=1.8),
        '<circle cx="1150" cy="56" r="5" fill="#fd4f00"/>',
    ]


def chip(x: float, y: float, label: str, color: str, opacity: float = 1.0) -> str:
    width = max(76, len(label) * 8 + 24)
    return "".join([
        rect(x, y, width, 30, fill="#0d1118", stroke=color, radius=15, opacity=opacity),
        dot(x + 14, y + 15, color, 3.5, opacity),
        text(x + 25, y + 20, label, 11, INK, 600, mono=True, opacity=opacity),
    ])


def distribution_frame(frame: int) -> str:
    t = frame / FRAMES
    pulse = 0.6 + 0.4 * math.sin(t * math.tau * 3) ** 2
    svg = base(
        "One queue. Any healthy node.",
        "Distributed execution",
        "PostgreSQL coordinates claims while every node enforces local capacity.",
    )

    svg += [
        rect(64, 180, 250, 306, fill="url(#panelGlow)"),
        text(88, 215, "SUBMISSION", 11, MUTED, 700, mono=True, spacing=1.5),
        text(88, 247, "Batch / feature-rollout", 17, INK, 700),
        text(88, 273, "4 governed coding jobs", 13, MUTED),
        line(88, 294, 288, 294),
        chip(88, 318, "job/4f2a", ORANGE),
        chip(88, 360, "job/91bc", PURPLE),
        chip(88, 402, "job/a73e", CYAN),
        chip(88, 444, "job/c510", GREEN),
        rect(390, 244, 250, 180, fill=PANEL_2, stroke=ORANGE, radius=24, stroke_width=1.5),
        text(515, 283, "DURABLE QUEUE", 11, ORANGE, 800, anchor="middle", mono=True, spacing=1.4),
        text(515, 323, "PostgreSQL", 25, INK, 700, anchor="middle"),
        text(515, 353, "claim + lease + retry", 12, MUTED, 500, anchor="middle", mono=True),
        text(515, 388, "single attempt owner", 11, GREEN, 700, anchor="middle", mono=True),
        line(314, 334, 390, 334, ORANGE, 2, 0.75),
        text(352, 322, "admit", 10, MUTED, 600, anchor="middle", mono=True),
    ]

    nodes = [
        (760, 170, "node-a", "2 / 2 slots", ORANGE),
        (760, 307, "node-b", "1 / 2 slots", PURPLE),
        (760, 444, "node-c", "1 / 1 slot", CYAN),
    ]
    for x, y, name, capacity, color in nodes:
        svg += [
            rect(x, y, 376, 106, fill=PANEL, stroke=color, radius=18, opacity=0.98),
            dot(x + 25, y + 26, color, 5, pulse),
            text(x + 44, y + 31, f"omashiki@{name}", 15, INK, 700, mono=True),
            text(x + 350, y + 31, "HEALTHY", 10, GREEN, 700, anchor="end", mono=True),
            text(x + 24, y + 62, capacity, 12, MUTED, 600, mono=True),
            rect(x + 24, y + 76, 328, 8, fill="#242b37", stroke="#242b37", radius=4),
        ]

    assignments = [
        (0.16, 0, "4f2a", ORANGE, 0),
        (0.27, 1, "91bc", PURPLE, 0),
        (0.38, 2, "a73e", CYAN, 0),
        (0.49, 0, "c510", GREEN, 1),
    ]
    node_jobs: dict[int, list[tuple[str, str, float]]] = {0: [], 1: [], 2: []}
    for start, node_index, job_id, color, slot in assignments:
        progress = clamp((t - start) / 0.12)
        end_x = 790 + slot * 146
        end_y = nodes[node_index][1] + 88
        if 0 < progress < 1:
            x = 640 + (end_x - 640) * progress
            y = 334 + (end_y - 334) * progress
            svg.append(dot(x, y, color, 7, 1.0))
        if progress >= 1:
            node_jobs[node_index].append((job_id, color, end_x))

    for index, jobs in node_jobs.items():
        y = nodes[index][1] + 74
        for job_id, color, x in jobs:
            svg += [
                rect(x, y, 128, 28, fill="#0c1016", stroke=color, radius=8),
                text(x + 12, y + 19, job_id, 10, INK, 700, mono=True),
                text(x + 116, y + 19, "RUN", 9, color, 800, anchor="end", mono=True),
            ]

    for _, y, _, _, _ in nodes:
        svg.append(line(640, 334, 760, y + 56, LINE, 1.5, 0.8, "5 7"))

    incoming = clamp((t - 0.04) / 0.1)
    if 0 < incoming < 1:
        svg.append(dot(314 + 76 * incoming, 334, ORANGE, 7))

    svg += [
        line(64, 565, 1136, 565, LINE),
        text(64, 596, "CLAIM SAFETY", 10, ORANGE, 800, mono=True, spacing=1.4),
        text(176, 596, "row lock", 11, INK, 600, mono=True),
        text(310, 596, "+", 11, MUTED, 600, mono=True),
        text(338, 596, "attempt lease", 11, INK, 600, mono=True),
        text(486, 596, "+", 11, MUTED, 600, mono=True),
        text(514, 596, "capacity token", 11, INK, 600, mono=True),
        text(1136, 596, "No double execution", 11, GREEN, 700, anchor="end", mono=True),
        "</svg>",
    ]
    return "".join(svg)


def lifecycle_frame(frame: int) -> str:
    t = frame / FRAMES
    progress = clamp((t - 0.08) / 0.72)
    svg = base(
        "A job becomes a governed attempt.",
        "Inside one job",
        "Admission freezes intent; the node prepares a worktree and runs the selected plugin in Docker.",
    )

    stages = [
        (105, "01", "ADMIT", "validate contract"),
        (300, "02", "SNAPSHOT", "freeze runtime"),
        (495, "03", "CLAIM", "lease attempt"),
        (690, "04", "PREPARE", "clean worktree"),
        (885, "05", "EXECUTE", "Docker / Debian"),
        (1080, "06", "RETURN", "commit or failure"),
    ]
    path_y = 245
    svg.append(line(stages[0][0], path_y, stages[-1][0], path_y, LINE, 4, 1.0))

    active_index = min(len(stages) - 1, int(progress * len(stages)))
    for index, (x, number, title_value, detail) in enumerate(stages):
        visited = progress >= index / (len(stages) - 1)
        color = ORANGE if index == active_index else (GREEN if visited else LINE)
        svg += [
            dot(x, path_y, color, 10 if index == active_index else 7, 1.0),
            text(x, 195, number, 10, color, 800, anchor="middle", mono=True),
            text(x, 290, title_value, 12, INK if visited else MUTED, 800, anchor="middle", mono=True, spacing=1.0),
            text(x, 311, detail, 10, MUTED, 500, anchor="middle", mono=True),
        ]

    packet_x = stages[0][0] + (stages[-1][0] - stages[0][0]) * progress
    svg.append(dot(packet_x, path_y, ORANGE, 7, 1.0))

    snapshot_visible = clamp((t - 0.20) / 0.08)
    docker_visible = clamp((t - 0.50) / 0.08)
    result_visible = clamp((t - 0.78) / 0.08)

    svg += [
        rect(64, 352, 330, 164, fill=PANEL, stroke=PURPLE, opacity=0.35 + 0.65 * snapshot_visible),
        text(88, 384, "IMMUTABLE ADMISSION", 10, PURPLE, 800, mono=True, spacing=1.2,
             opacity=snapshot_visible),
        text(88, 416, "runtime", 11, MUTED, 600, mono=True, opacity=snapshot_visible),
        text(188, 416, "docker.runc.debian", 12, INK, 700, mono=True, opacity=snapshot_visible),
        text(88, 445, "plugin", 11, MUTED, 600, mono=True, opacity=snapshot_visible),
        text(188, 445, "opencode", 12, INK, 700, mono=True, opacity=snapshot_visible),
        text(88, 474, "image", 11, MUTED, 600, mono=True, opacity=snapshot_visible),
        text(188, 474, "omashiki/agent", 12, INK, 700, mono=True, opacity=snapshot_visible),
        text(88, 497, "catalog reloads affect new jobs only", 10, GREEN, 600, mono=True,
             opacity=snapshot_visible),
        rect(430, 352, 470, 164, fill=PANEL_2, stroke=ORANGE,
             opacity=0.35 + 0.65 * docker_visible),
        text(454, 384, "CURRENT RUNTIME", 10, ORANGE, 800, mono=True, spacing=1.2,
             opacity=docker_visible),
        text(876, 384, "DOCKER", 10, ORANGE, 800, anchor="end", mono=True,
             opacity=docker_visible),
        rect(454, 404, 126, 84, fill="#0d1118", stroke=LINE, radius=10, opacity=docker_visible),
        rect(596, 404, 126, 84, fill="#0d1118", stroke=LINE, radius=10, opacity=docker_visible),
        rect(738, 404, 138, 84, fill="#0d1118", stroke=LINE, radius=10, opacity=docker_visible),
        text(517, 438, "WORKTREE", 10, CYAN, 800, anchor="middle", mono=True,
             opacity=docker_visible),
        text(517, 462, "isolated Git", 10, MUTED, 500, anchor="middle", mono=True,
             opacity=docker_visible),
        text(659, 438, "POLICY", 10, PURPLE, 800, anchor="middle", mono=True,
             opacity=docker_visible),
        text(659, 462, "net + limits", 10, MUTED, 500, anchor="middle", mono=True,
             opacity=docker_visible),
        text(807, 438, "PLUGIN", 10, ORANGE, 800, anchor="middle", mono=True,
             opacity=docker_visible),
        text(807, 462, "governed turn", 10, MUTED, 500, anchor="middle", mono=True,
             opacity=docker_visible),
        rect(936, 352, 200, 164, fill=PANEL, stroke=GREEN,
             opacity=0.35 + 0.65 * result_visible),
        text(960, 384, "DURABLE RESULT", 10, GREEN, 800, mono=True, spacing=1.2,
             opacity=result_visible),
        text(960, 424, "branch ready", 17, INK, 700, opacity=result_visible),
        text(960, 451, "feat/4f2a", 12, CYAN, 700, mono=True, opacity=result_visible),
        text(960, 483, "events + logs retained", 10, MUTED, 500, mono=True,
             opacity=result_visible),
        line(64, 553, 1136, 553, LINE),
        text(64, 584, "RUNTIME OPTIONS", 10, MUTED, 800, mono=True, spacing=1.2),
        text(220, 584, "docker.runc.debian", 10, MUTED, 500, mono=True, opacity=0.55),
        text(410, 584, "docker.kata.debian", 10, MUTED, 500, mono=True, opacity=0.55),
        text(1136, 584, "KATA HOST GATE PENDING", 10, MUTED, 600, anchor="end", mono=True),
        "</svg>",
    ]
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
                "[0:v]split[a][b];[a]palettegen=max_colors=128:stats_mode=diff[p];"
                "[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle",
                "-loop", "0", str(destination),
            ],
            check=True,
        )
        print(f"rendered {destination.relative_to(ROOT)}")


def main() -> None:
    render("distributed-execution.gif", distribution_frame)
    render("governed-job-lifecycle.gif", lifecycle_frame)


if __name__ == "__main__":
    main()
