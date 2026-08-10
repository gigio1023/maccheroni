# /// script
# requires-python = ">=3.11"
# dependencies = ["matplotlib>=3.9"]
# ///
"""Render the README benchmark figures as SVG.

Regenerate with:

    uv run benchmarks/scripts/figures/render_readme_figures.py

Outputs (light and dark variants for each figure) are written to
docs/assets/. Both figures read benchmarks/published-results.json, which records
the measured values and their provenance. This script holds presentation only,
never new measurements.

Text is exported as paths (svg.fonttype=none would depend on viewer fonts),
so the rendered files look identical on any host.
"""

from __future__ import annotations

import argparse
import pathlib
from typing import Sequence

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, Rectangle

from published_results import (
    DATA_PATH,
    display_path,
    leaf_cap_decimal,
    leaf_cap_text,
    load_results,
    metric_decimal,
    metric_text,
    setting_decimal,
    setting_text,
)

REPO = pathlib.Path(__file__).resolve().parents[3]
DEFAULT_OUT = REPO / "docs" / "assets"

MONO = "Menlo"
SANS = "Helvetica Neue"

PALETTES = {
    "light": {
        "ink": "#0D0D0D",
        "muted": "#6E7076",
        "hairline": "#C9C9CE",
        "blue": "#5477C4",
        "blue_chip": "#A3BEFA",
        "coral": "#CC6F47",
        "coral_line": "#FF9365",
    },
    "dark": {
        "ink": "#ECECF1",
        "muted": "#9CA1A8",
        "hairline": "#4A4A55",
        "blue": "#6E8FDD",
        "blue_chip": "#A3BEFA",
        "coral": "#FF9365",
        "coral_line": "#FF9365",
    },
}

NUMBER_WORDS = (
    "zero", "one", "two", "three", "four", "five",
    "six", "seven", "eight", "nine", "ten",
)

matplotlib.rcParams["svg.fonttype"] = "path"


def style_axis(ax, pal, ymax, yticks, ytick_labels):
    ax.set_ylim(0, ymax)
    ax.set_yticks(yticks)
    ax.set_yticklabels(ytick_labels, font=MONO, fontsize=11, color=pal["ink"])
    ax.tick_params(axis="y", direction="out", length=5, width=1, color=pal["ink"])
    ax.tick_params(axis="x", length=0)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(pal["ink"])
        ax.spines[side].set_linewidth(1)
    ax.set_facecolor("none")


def header(fig, pal, title, subtitle):
    fig.patch.set_alpha(0.0)
    fig.text(0.045, 0.925, title, font=SANS, fontsize=21, weight="bold", color=pal["ink"])
    fig.text(0.045, 0.868, subtitle, font=SANS, fontsize=12.5, color=pal["muted"])


def chip(fig, pal, x, y, color, label):
    fig.patches.append(
        FancyBboxPatch(
            (x, y), 0.008, 0.017,
            boxstyle="round,pad=0,rounding_size=0.004",
            transform=fig.transFigure, facecolor=color, edgecolor="none",
        )
    )
    fig.text(x + 0.013, y + 0.002, label, font=MONO, fontsize=10.5, color=pal["ink"])


def value_label(ax, pal, x, y, text):
    ax.text(x, y, text, font=MONO, fontsize=11.5, color=pal["ink"], ha="center", va="bottom")


def category_label(ax, pal, x, main, sub):
    ax.text(x, -0.055, main, font=SANS, fontsize=12, color=pal["ink"],
            ha="center", va="top", transform=ax.get_xaxis_transform())
    ax.text(x, -0.115, sub, font=SANS, fontsize=10.5, color=pal["muted"],
            ha="center", va="top", transform=ax.get_xaxis_transform())


def render_benchmarks(theme: str, results: dict, output_dir: pathlib.Path) -> None:
    pal = PALETTES[theme]
    fig = plt.figure(figsize=(15.6, 7.0), dpi=100)
    header(
        fig, pal,
        "Measured on public and synthetic fixtures",
        "Pinned models, decode-time glossary injection on. Evaluation IDs and artifact hashes are recorded in docs/.",
    )
    chip(fig, pal, 0.262, 0.767, pal["blue"], "CER")
    chip(fig, pal, 0.297, 0.767, pal["blue_chip"], "WER")

    panels = [fig.add_axes([0.065, 0.17, 0.24, 0.60]),
              fig.add_axes([0.40, 0.17, 0.24, 0.60]),
              fig.add_axes([0.735, 0.17, 0.24, 0.60])]

    ax = panels[0]
    style_axis(ax, pal, 0.16, [0.05, 0.10, 0.15], ["0.05", "0.10", "0.15"])
    bw = 0.34
    error_fixtures = ("hike-tech", "italian-dialogue")
    for i, fixture in enumerate(error_fixtures):
        cer = float(metric_decimal(results, fixture, "cer", "figure"))
        wer = float(metric_decimal(results, fixture, "wer", "figure"))
        ax.bar(i - bw / 2, cer, bw, color=pal["blue"])
        ax.bar(i + bw / 2, wer, bw, color=pal["blue_chip"])
        value_label(ax, pal, i - bw / 2, cer + 0.004,
                    metric_text(results, fixture, "cer", "figure"))
        value_label(ax, pal, i + bw / 2, wer + 0.004,
                    metric_text(results, fixture, "wer", "figure"))
    ax.set_xlim(-0.75, 2.75)
    ax.set_xticks([])
    category_label(ax, pal, 0, "Korean", "VibeVoice")
    category_label(ax, pal, 1, "Italian", "MOSS INT8")
    # unmeasured roadmap slot: no bar, no value — just a reserved place
    ax.text(2.1, 0.055, "···", font=MONO, fontsize=18,
            color=pal["muted"], ha="center", va="center")
    category_label(ax, pal, 2.1, "Next languages", "in progress")
    ax.set_title("Error rate (lower is better)", font=SANS, fontsize=14,
                 color=pal["ink"], loc="left", pad=14)

    ax = panels[1]
    style_axis(ax, pal, 1.0, [0.25, 0.50, 0.75, 1.00], ["0.25", "0.50", "0.75", "1.00"])
    for i, fixture in enumerate(error_fixtures):
        v = float(metric_decimal(results, fixture, "term_recall", "figure"))
        ax.bar(i, v, 0.42, color=pal["blue"])
        value_label(ax, pal, i, v + 0.025,
                    metric_text(results, fixture, "term_recall", "figure"))
    term_recall_gate = float(setting_decimal(results, "term_recall_gate", "figure"))
    ax.axhline(term_recall_gate, color=pal["muted"], linewidth=1,
               linestyle=(0, (5, 4)))
    ax.text(0.5, 0.715,
            f"GATE {setting_text(results, 'term_recall_gate', 'figure')}",
            font=MONO, fontsize=10, color=pal["muted"],
            ha="center", va="top")
    ax.set_xlim(-0.75, 1.75)
    ax.set_xticks([])
    category_label(ax, pal, 0, "Korean", "20-term glossary")
    category_label(ax, pal, 1, "Italian", "9-term glossary")
    ax.set_title("Glossary term recall (higher is better)", font=SANS, fontsize=14,
                 color=pal["ink"], loc="left", pad=14)

    ax = panels[2]
    style_axis(ax, pal, 0.20, [0.05, 0.10, 0.15, 0.20], ["0.05", "0.10", "0.15", "0.20"])
    diarization_fixtures = ("italian-dialogue", "voxconverse-ppgjx-78m")
    for i, fixture in enumerate(diarization_fixtures):
        v = float(metric_decimal(results, fixture, "der", "figure"))
        ax.bar(i, v, 0.42, color=pal["blue"])
        value_label(ax, pal, i, v + 0.005,
                    metric_text(results, fixture, "der", "figure"))
    ax.set_xlim(-0.75, 1.75)
    ax.set_xticks([])
    category_label(ax, pal, 0, "Italian synthetic", "10 min, 2 speakers")
    category_label(ax, pal, 1, "VoxConverse", "78 min, public")
    ax.set_title("Diarization error rate (lower is better)", font=SANS, fontsize=14,
                 color=pal["ink"], loc="left", pad=14)

    stability = metric_text(
        results, "voxconverse-ppgjx-78m", "speaker_stability", "figure"
    )
    fig.text(0.045, 0.052,
             f"Chunk-boundary speaker stability on the 78-minute sample: {stability} for both reference speakers across all root boundaries.",
             font=SANS, fontsize=11, color=pal["muted"])
    fig.text(0.045, 0.020,
             "Korean and Italian are the first two language profiles; new language fixtures join this matrix as they are measured.",
             font=SANS, fontsize=11, color=pal["muted"])

    fig.savefig(output_dir / f"benchmarks-{theme}.svg")
    plt.close(fig)


def render_leaf_cap(
    theme: str, results: dict, output_dir: pathlib.Path
) -> None:
    pal = PALETTES[theme]
    fig = plt.figure(figsize=(15.6, 6.4), dpi=100)
    preferred_leaf_seconds = leaf_cap_text(
        results, "leaf_seconds", "figure", "candidate-120"
    )
    header(
        fig, pal,
        f"Why ASR leaves are capped at {preferred_leaf_seconds} seconds",
        f"Canonical end-of-sequence leaves per configuration on the same {leaf_cap_text(results, 'input_duration_seconds', 'figure')}-second synthetic Italian input, MOSS 0.9B INT8 at the pinned revision.",
    )

    ax = fig.add_axes([0.065, 0.20, 0.91, 0.55])
    style_axis(ax, pal, 5.6, [1, 2, 3, 4, 5], ["1", "2", "3", "4", "5"])

    case_ids = results["leaf_cap"]["case_order"]
    values = [
        int(leaf_cap_decimal(results, "valid_eos_leaves", "figure", case_id))
        for case_id in case_ids
    ]
    for x, v in enumerate(values):
        if v > 0:
            ax.bar(x, v, 0.34, color=pal["blue"])
            value_label(ax, pal, x, v + 0.12, str(v))
        else:
            ax.add_patch(Rectangle((x - 0.17, 0), 0.34, 0.42, fill=False,
                                   edgecolor=pal["coral_line"], linewidth=1.2,
                                   linestyle=(0, (4, 3))))
            ax.text(x, 0.62, "invalid_eos_output", font=MONO, fontsize=11,
                    color=pal["coral"], ha="center", va="bottom")
    ax.set_xlim(-0.7, 3.7)
    ax.set_xticks([])
    category_label(
        ax, pal, 0,
        f"{leaf_cap_text(results, 'leaf_seconds', 'figure', 'candidate-120')} s leaves",
        f"pass: CER {leaf_cap_text(results, 'cer', 'figure', 'candidate-120')}, term recall {leaf_cap_text(results, 'term_recall', 'figure', 'candidate-120')}",
    )
    category_label(
        ax, pal, 1,
        f"{leaf_cap_text(results, 'leaf_seconds', 'figure', 'candidate-240')} s leaves",
        f"{leaf_cap_text(results, 'valid_eos_leaves', 'figure', 'candidate-240')} valid leaves: typed failure, never promoted",
    )
    category_label(
        ax, pal, 2,
        f"{leaf_cap_text(results, 'leaf_seconds', 'figure', 'candidate-300')} s leaves",
        f"{leaf_cap_text(results, 'valid_eos_leaves', 'figure', 'candidate-300')} valid leaves: typed failure, never promoted",
    )
    category_label(
        ax, pal, 3,
        f"{leaf_cap_text(results, 'leaf_seconds', 'figure', 'forced-recovery-240-1024')} s + forced recovery",
        f"recovered as {NUMBER_WORDS[values[3]]} {leaf_cap_text(results, 'recovery_leaf_seconds', 'figure', 'forced-recovery-240-1024')} s children: CER {leaf_cap_text(results, 'cer', 'figure', 'forced-recovery-240-1024')}",
    )

    fig.text(0.045, 0.030,
             "Truncated output is never promoted: a leaf that stops without end-of-sequence is a typed failure, not a shorter transcript. Full matrix and seals: docs/moss-long-audio-verdict.md.",
             font=SANS, fontsize=11, color=pal["muted"])

    fig.savefig(output_dir / f"leaf-cap-{theme}.svg")
    plt.close(fig)


def parse_arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data", type=pathlib.Path, default=DATA_PATH)
    parser.add_argument("--output-dir", type=pathlib.Path, default=DEFAULT_OUT)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> None:
    arguments = parse_arguments(argv)
    results = load_results(arguments.data)
    arguments.output_dir.mkdir(parents=True, exist_ok=True)
    for theme in ("light", "dark"):
        render_benchmarks(theme, results, arguments.output_dir)
        render_leaf_cap(theme, results, arguments.output_dir)
    print(
        f"wrote 4 figures to {arguments.output_dir} "
        f"using {display_path(arguments.data, REPO)}"
    )


if __name__ == "__main__":
    main()
