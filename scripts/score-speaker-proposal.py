#!/usr/bin/env python3
"""Score speaker attribution and a speaker-proposal derived run against a reference RTTM.

The scorer reads one source run (``merged/segments.json``, ``merged/conflicts.json``,
``diarization/timeline.json``), a reference RTTM with per-speaker turns, and optionally
one ``speaker-proposal`` derived set. It maps the run's global speaker namespace onto
the reference speakers by maximal whole-file overlap, derives a per-segment reference
truth from the reference turns clipped to each merged segment, and then reports:

- the accuracy of the merge's acoustic ``speaker_attribution`` on the segments it
  attributed;
- the accuracy of the ``top_ranked_candidate`` on the segments the merge left
  unattributed, split by evidence state;
- for a derived set: confirmation precision, decline correctness by cause, and what
  the model answered on every decline the constraint decided, so the reader can see
  what the language layer added or cost against the acoustic baseline.

Every number is derived from the artifacts; nothing is trusted from a report. The
script uses the standard library only and prints Markdown; ``--json`` writes the full
per-segment ledger beside the summary.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass, field
from functools import lru_cache


UNATTRIBUTED_LABELS = frozenset({"UNASSIGNED", "UNKNOWN"})

# Mirrors `SpeakerProposalConstraint.topRankedMarginS` in
# Sources/MaccheroniPostprocess/Postprocess.swift: two candidates whose overlaps
# differ by no more than this are a tie, and a tie has no top-ranked candidate.
TOP_RANKED_MARGIN_S = 1e-9

# Mirrors `TimelineMerger` `dominantSpeakerShare`; the reference truth reuses the
# same bar so "clear" means what the merger would have called dominant.
DEFAULT_DOMINANT_SHARE = 0.60
DEFAULT_NEAR_TIE_MARGIN = 0.05

TRUTH_CLASSES = ("clear", "ambiguous", "no_reference_speech")
EVIDENCE_STATES = (
    "no_candidates",
    "exact_tie",
    "near_tie",
    "lead",
    "dominant_low_coverage",
    "single_candidate",
)
DECLINE_CAUSES = (
    "model_disagreed_with_top_ranked_candidate",
    "no_acoustic_candidates",
    "no_top_ranked_candidate",
    "model_declined",
    "no_decision",
    "unrecorded",
)


@dataclass(frozen=True)
class Turn:
    speaker: str
    start_s: float
    end_s: float


@dataclass(frozen=True)
class Candidate:
    speaker: str
    overlap_s: float
    share: float


@dataclass(frozen=True)
class Truth:
    """Reference evidence for one merged segment interval."""

    classification: str
    top: str | None
    top_share: float
    coverage: float
    speech_s: float
    present: tuple[str, ...]
    overlaps: Mapping[str, float]


@dataclass
class Tally:
    """Correctness counts for one family of claimed speakers."""

    n: int = 0
    strict_defined: int = 0
    strict_correct: int = 0
    lenient_defined: int = 0
    lenient_correct: int = 0
    present: int = 0
    unmapped: int = 0
    truth_classes: dict[str, int] = field(
        default_factory=lambda: {name: 0 for name in TRUTH_CLASSES}
    )

    def add(self, verdict: Mapping[str, object]) -> None:
        self.n += 1
        self.truth_classes[str(verdict["truth_class"])] += 1
        if verdict["mapped"] is None:
            self.unmapped += 1
        if verdict["strict"] is not None:
            self.strict_defined += 1
            self.strict_correct += int(bool(verdict["strict"]))
        if verdict["lenient"] is not None:
            self.lenient_defined += 1
            self.lenient_correct += int(bool(verdict["lenient"]))
        self.present += int(bool(verdict["present"]))

    def as_dict(self) -> dict[str, object]:
        return {
            "n": self.n,
            "strict_defined": self.strict_defined,
            "strict_correct": self.strict_correct,
            "strict_precision": ratio(self.strict_correct, self.strict_defined),
            "strict_precision_ci95": wilson_interval(self.strict_correct, self.strict_defined),
            "lenient_defined": self.lenient_defined,
            "lenient_correct": self.lenient_correct,
            "lenient_precision": ratio(self.lenient_correct, self.lenient_defined),
            "lenient_precision_ci95": wilson_interval(self.lenient_correct, self.lenient_defined),
            "present_in_reference": self.present,
            "unmapped_speaker": self.unmapped,
            "truth_classes": dict(self.truth_classes),
        }


def ratio(numerator: int, denominator: int) -> float | None:
    if denominator <= 0:
        return None
    return numerator / denominator


def wilson_interval(successes: int, trials: int, z: float = 1.96) -> list[float] | None:
    """Wilson score interval for a proportion, so small denominators show their width."""

    if trials <= 0:
        return None
    proportion = successes / trials
    centre = (proportion + z * z / (2 * trials)) / (1 + z * z / trials)
    half_width = (
        z
        * ((proportion * (1 - proportion) / trials + z * z / (4 * trials * trials)) ** 0.5)
        / (1 + z * z / trials)
    )
    return [round(max(0.0, centre - half_width), 4), round(min(1.0, centre + half_width), 4)]


def sha256_of(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_json(path: pathlib.Path) -> object:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def read_rttm(path: pathlib.Path) -> list[Turn]:
    turns: list[Turn] = []
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split()
        if len(fields) < 8 or fields[0] != "SPEAKER":
            raise SystemExit(f"{path}:{line_number}: expected an RTTM SPEAKER row")
        start = float(fields[3])
        duration = float(fields[4])
        if start < 0 or duration <= 0:
            raise SystemExit(f"{path}:{line_number}: invalid start or duration")
        turns.append(Turn(fields[7], start, start + duration))
    if not turns:
        raise SystemExit(f"{path}: the reference RTTM has no turns")
    return turns


def read_timeline(path: pathlib.Path) -> list[Turn]:
    document = read_json(path)
    entries = document["segments"] if isinstance(document, Mapping) else document
    if not isinstance(entries, list):
        raise SystemExit(f"{path}: the timeline is not a list of turns")
    turns: list[Turn] = []
    for entry in entries:
        start = float(entry["start_s"])
        end = float(entry["end_s"])
        if end <= start:
            raise SystemExit(f"{path}: a timeline turn has a non-positive duration")
        turns.append(Turn(str(entry["speaker"]), start, end))
    return turns


def intersection_s(a0: float, a1: float, b0: float, b1: float) -> float:
    return max(0.0, min(a1, b1) - max(a0, b0))


def union_duration_s(intervals: Iterable[tuple[float, float]]) -> float:
    total = 0.0
    current: tuple[float, float] | None = None
    for start, end in sorted(intervals):
        if current is None:
            current = (start, end)
        elif start <= current[1]:
            current = (current[0], max(current[1], end))
        else:
            total += current[1] - current[0]
            current = (start, end)
    if current is not None:
        total += current[1] - current[0]
    return total


# MARK: - Cluster-to-reference mapping


def overlap_matrix(
    hypothesis: Sequence[Turn], reference: Sequence[Turn]
) -> dict[str, dict[str, float]]:
    matrix: dict[str, dict[str, float]] = {}
    for turn in hypothesis:
        row = matrix.setdefault(turn.speaker, {})
        for other in reference:
            seconds = intersection_s(turn.start_s, turn.end_s, other.start_s, other.end_s)
            if seconds > 0:
                row[other.speaker] = row.get(other.speaker, 0.0) + seconds
    return matrix


def optimal_mapping(
    matrix: Mapping[str, Mapping[str, float]],
    hypothesis_speakers: Sequence[str],
    reference_speakers: Sequence[str],
) -> dict[str, str]:
    """One-to-one hypothesis-to-reference assignment of maximal total overlap.

    Exact search over reference subsets, the same shape as the DER mapping in
    ``benchmarks/scripts/scoring/rttm.py``; ties resolve to the lexicographically
    smallest assignment so the result is deterministic.
    """

    if len(reference_speakers) > 16:
        raise SystemExit("the exact mapping supports at most 16 reference speakers")
    hypotheses = list(hypothesis_speakers)
    references = list(reference_speakers)

    @lru_cache(maxsize=None)
    def solve(index: int, used: int) -> tuple[float, tuple[int, ...]]:
        if index == len(hypotheses):
            return 0.0, ()
        best_score, best_assignment = solve(index + 1, used)
        best_assignment = (-1,) + best_assignment
        row = matrix.get(hypotheses[index], {})
        for reference_index, reference in enumerate(references):
            bit = 1 << reference_index
            if used & bit:
                continue
            downstream_score, downstream_assignment = solve(index + 1, used | bit)
            score = row.get(reference, 0.0) + downstream_score
            assignment = (reference_index,) + downstream_assignment
            if score > best_score or (
                score == best_score and assignment < best_assignment
            ):
                best_score = score
                best_assignment = assignment
        return best_score, best_assignment

    _, assignment = solve(0, 0)
    return {
        hypotheses[index]: references[reference_index]
        for index, reference_index in enumerate(assignment)
        if reference_index >= 0
    }


# MARK: - Per-segment reference truth


def reference_truth(
    start_s: float,
    end_s: float,
    reference: Sequence[Turn],
    dominant_share: float,
) -> Truth:
    overlaps: dict[str, float] = {}
    intervals: list[tuple[float, float]] = []
    for turn in reference:
        seconds = intersection_s(start_s, end_s, turn.start_s, turn.end_s)
        if seconds <= 0:
            continue
        overlaps[turn.speaker] = overlaps.get(turn.speaker, 0.0) + seconds
        intervals.append((max(start_s, turn.start_s), min(end_s, turn.end_s)))
    speech = sum(overlaps.values())
    duration = end_s - start_s
    coverage = union_duration_s(intervals) / duration if duration > 0 else 0.0
    if speech <= 0:
        return Truth("no_reference_speech", None, 0.0, coverage, 0.0, (), {})
    ranked = sorted(overlaps.items(), key=lambda item: (-item[1], item[0]))
    top_overlap = ranked[0][1]
    tied = [name for name, seconds in ranked if top_overlap - seconds <= TOP_RANKED_MARGIN_S]
    top = ranked[0][0] if len(tied) == 1 else None
    top_share = top_overlap / speech
    classification = (
        "clear" if top is not None and top_share >= dominant_share else "ambiguous"
    )
    return Truth(
        classification,
        top,
        top_share,
        coverage,
        speech,
        tuple(name for name, _ in ranked),
        dict(ranked),
    )


def verdict_for(
    claimed: str | None,
    truth: Truth,
    mapping: Mapping[str, str],
) -> dict[str, object]:
    """How one claimed hypothesis speaker fares against the segment's truth.

    ``strict`` is defined only on ``clear`` segments and asks whether the mapped
    speaker is the reference's dominant speaker. ``lenient`` is defined whenever the
    reference has a unique leading speaker at any share. ``present`` asks only
    whether the mapped speaker spoke inside the interval at all.
    """

    mapped = mapping.get(claimed) if claimed is not None else None
    strict = (mapped == truth.top) if truth.classification == "clear" else None
    lenient = (mapped == truth.top) if truth.top is not None else None
    present = mapped is not None and mapped in truth.present
    return {
        "claimed": claimed,
        "mapped": mapped,
        "truth_class": truth.classification,
        "truth_top": truth.top,
        "truth_top_share": truth.top_share,
        "strict": strict,
        "lenient": lenient,
        "present": present,
    }


# MARK: - Acoustic evidence


def parse_candidates(entries: Sequence[Mapping[str, object]]) -> list[Candidate]:
    return [
        Candidate(str(entry["speaker"]), float(entry["overlap_s"]), float(entry["share"]))
        for entry in entries
    ]


def top_ranked_candidate(candidates: Sequence[Candidate]) -> str | None:
    if not candidates:
        return None
    top = max(candidate.overlap_s for candidate in candidates)
    leaders = [c for c in candidates if top - c.overlap_s <= TOP_RANKED_MARGIN_S]
    return leaders[0].speaker if len(leaders) == 1 else None


def evidence_state(
    candidates: Sequence[Candidate],
    dominant_share: float,
    near_tie_margin: float,
) -> str:
    if not candidates:
        return "no_candidates"
    if top_ranked_candidate(candidates) is None:
        return "exact_tie"
    if len(candidates) == 1:
        return "single_candidate"
    shares = sorted((candidate.share for candidate in candidates), reverse=True)
    if shares[0] >= dominant_share:
        return "dominant_low_coverage"
    if shares[0] - shares[1] < near_tie_margin:
        return "near_tie"
    return "lead"


def unattributed_evidence(
    conflicts: Sequence[Mapping[str, object]],
    unattributed: Iterable[int],
) -> dict[int, dict[str, object]]:
    """Reproduce the CLI's `speakerEvidence`: one record per unattributed segment.

    An ``ambiguous_speaker`` conflict wins over an ``overlapping_speech`` conflict
    for the same segment; a segment with no attribution record is reported as
    ``no_acoustic_record`` with no candidates.
    """

    by_index: dict[int, Mapping[str, object]] = {}
    for conflict in conflicts:
        attribution = conflict.get("speaker_attribution")
        if not isinstance(attribution, Mapping):
            continue
        index = int(conflict["segment_index"])
        if conflict.get("kind") == "ambiguous_speaker" or index not in by_index:
            by_index[index] = attribution
    evidence: dict[int, dict[str, object]] = {}
    for index in unattributed:
        attribution = by_index.get(index)
        if attribution is None:
            evidence[index] = {
                "outcome": "no_acoustic_record",
                "candidates": [],
                "timeline_coverage": 0.0,
            }
            continue
        evidence[index] = {
            "outcome": str(attribution["outcome"]),
            "candidates": parse_candidates(attribution.get("candidates", [])),
            "timeline_coverage": float(attribution.get("timeline_coverage", 0.0)),
        }
    return evidence


# MARK: - Scoring


def score(
    reference: Sequence[Turn],
    timeline: Sequence[Turn],
    segments: Sequence[Mapping[str, object]],
    conflicts: Sequence[Mapping[str, object]],
    proposal: Mapping[str, object] | None,
    *,
    dominant_share: float = DEFAULT_DOMINANT_SHARE,
    near_tie_margin: float = DEFAULT_NEAR_TIE_MARGIN,
) -> dict[str, object]:
    hypothesis_speakers = sorted({turn.speaker for turn in timeline})
    reference_speakers = sorted({turn.speaker for turn in reference})
    matrix = overlap_matrix(timeline, reference)
    mapping = optimal_mapping(matrix, hypothesis_speakers, reference_speakers)
    hypothesis_seconds = {
        speaker: sum(t.end_s - t.start_s for t in timeline if t.speaker == speaker)
        for speaker in hypothesis_speakers
    }
    reference_seconds = {
        speaker: sum(t.end_s - t.start_s for t in reference if t.speaker == speaker)
        for speaker in reference_speakers
    }
    mapping_report = {
        "hypothesis_speakers": hypothesis_speakers,
        "reference_speakers": reference_speakers,
        "mapping": {speaker: mapping.get(speaker) for speaker in hypothesis_speakers},
        "overlap_matrix_s": {
            speaker: {
                other: round(matrix.get(speaker, {}).get(other, 0.0), 3)
                for other in reference_speakers
            }
            for speaker in hypothesis_speakers
        },
        "hypothesis_speech_s": {k: round(v, 3) for k, v in hypothesis_seconds.items()},
        "reference_speech_s": {k: round(v, 3) for k, v in reference_seconds.items()},
        "hypothesis_purity": {
            speaker: ratio_float(
                matrix.get(speaker, {}).get(mapping.get(speaker, ""), 0.0),
                hypothesis_seconds[speaker],
            )
            for speaker in hypothesis_speakers
        },
        "mapped_overlap_s": round(
            sum(
                matrix.get(speaker, {}).get(target, 0.0)
                for speaker, target in mapping.items()
            ),
            3,
        ),
    }

    truths = [
        reference_truth(
            float(segment["start_s"]),
            float(segment["end_s"]),
            reference,
            dominant_share,
        )
        for segment in segments
    ]
    unattributed = [
        index
        for index, segment in enumerate(segments)
        if str(segment["speaker"]) in UNATTRIBUTED_LABELS
    ]
    attributed = [index for index in range(len(segments)) if index not in set(unattributed)]
    evidence = unattributed_evidence(conflicts, unattributed)

    ledger: list[dict[str, object]] = []
    attribution_tally = Tally()
    for index in attributed:
        verdict = verdict_for(str(segments[index]["speaker"]), truths[index], mapping)
        attribution_tally.add(verdict)
        ledger.append(
            {
                "segment_index": index,
                "start_s": segments[index]["start_s"],
                "end_s": segments[index]["end_s"],
                "family": "attributed",
                **verdict,
            }
        )

    top_tally = Tally()
    top_by_state = {state: Tally() for state in EVIDENCE_STATES}
    top_by_outcome: dict[str, Tally] = {}
    state_counts = {state: 0 for state in EVIDENCE_STATES}
    outcome_counts: dict[str, int] = {}
    truth_counts_unattributed = {name: 0 for name in TRUTH_CLASSES}
    top_by_index: dict[int, str | None] = {}
    state_by_index: dict[int, str] = {}
    for index in unattributed:
        record = evidence[index]
        candidates = record["candidates"]
        state = evidence_state(candidates, dominant_share, near_tie_margin)
        state_by_index[index] = state
        state_counts[state] += 1
        outcome = str(record["outcome"])
        outcome_counts[outcome] = outcome_counts.get(outcome, 0) + 1
        truth_counts_unattributed[truths[index].classification] += 1
        top = top_ranked_candidate(candidates)
        top_by_index[index] = top
        row: dict[str, object] = {
            "segment_index": index,
            "start_s": segments[index]["start_s"],
            "end_s": segments[index]["end_s"],
            "family": "unattributed",
            "acoustic_outcome": outcome,
            "evidence_state": state,
            "timeline_coverage": record["timeline_coverage"],
            "candidates": [
                {"speaker": c.speaker, "overlap_s": c.overlap_s, "share": c.share}
                for c in candidates
            ],
            "top_ranked_candidate": top,
            "truth_class": truths[index].classification,
            "truth_top": truths[index].top,
            "truth_top_share": truths[index].top_share,
            "truth_coverage": truths[index].coverage,
        }
        if top is not None:
            verdict = verdict_for(top, truths[index], mapping)
            top_tally.add(verdict)
            top_by_state[state].add(verdict)
            top_by_outcome.setdefault(outcome, Tally()).add(verdict)
            row["top_ranked"] = verdict
        ledger.append(row)

    report: dict[str, object] = {
        "parameters": {
            "dominant_share": dominant_share,
            "near_tie_margin": near_tie_margin,
            "top_ranked_margin_s": TOP_RANKED_MARGIN_S,
        },
        "mapping": mapping_report,
        "segments": {
            "total": len(segments),
            "attributed": len(attributed),
            "unattributed": len(unattributed),
            "truth_classes_all": count_truths(truths),
            "truth_classes_unattributed": truth_counts_unattributed,
            "evidence_states_unattributed": state_counts,
            "acoustic_outcomes_unattributed": dict(sorted(outcome_counts.items())),
        },
        "acoustic_attribution": attribution_tally.as_dict(),
        "top_ranked_candidate": {
            "overall": top_tally.as_dict(),
            "by_evidence_state": {
                state: tally.as_dict() for state, tally in top_by_state.items() if tally.n
            },
            "by_acoustic_outcome": {
                outcome: tally.as_dict() for outcome, tally in sorted(top_by_outcome.items())
            },
        },
    }
    if proposal is not None:
        report["proposal"] = score_proposal(
            proposal,
            truths,
            mapping,
            evidence,
            top_by_index,
            state_by_index,
            unattributed,
            ledger,
            top_tally,
        )
    report["ledger"] = ledger
    return report


def ratio_float(numerator: float, denominator: float) -> float | None:
    if denominator <= 0:
        return None
    return round(numerator / denominator, 4)


def count_truths(truths: Sequence[Truth]) -> dict[str, int]:
    counts = {name: 0 for name in TRUTH_CLASSES}
    for truth in truths:
        counts[truth.classification] += 1
    return counts


def score_proposal(
    proposal: Mapping[str, object],
    truths: Sequence[Truth],
    mapping: Mapping[str, str],
    evidence: Mapping[int, Mapping[str, object]],
    top_by_index: Mapping[int, str | None],
    state_by_index: Mapping[int, str],
    unattributed: Sequence[int],
    ledger: list[dict[str, object]],
    top_tally: Tally,
) -> dict[str, object]:
    proposals = list(proposal.get("proposals", []))
    declines = list(proposal.get("declined", []))
    covered = {int(p["segment_index"]) for p in proposals} | {
        int(d["segment_index"]) for d in declines
    }
    if covered != set(unattributed):
        raise SystemExit(
            "the proposal artifact does not cover exactly the run's unattributed segments"
        )
    ledger_by_index = {int(row["segment_index"]): row for row in ledger}

    confirmations = Tally()
    confirmations_by_state = {state: Tally() for state in EVIDENCE_STATES}
    confirmations_by_outcome: dict[str, Tally] = {}
    declined_top = Tally()
    unconstrained = Tally()
    for entry in proposals:
        index = int(entry["segment_index"])
        proposed = str(entry["proposed_speaker"])
        candidates = parse_candidates(entry.get("acoustic_candidates", []))
        artifact_top = top_ranked_candidate(candidates)
        if artifact_top != proposed or artifact_top != top_by_index.get(index):
            raise SystemExit(
                f"segment {index}: the proposal does not confirm the run's top-ranked candidate"
            )
        verdict = verdict_for(proposed, truths[index], mapping)
        confirmations.add(verdict)
        unconstrained.add(verdict)
        confirmations_by_state[state_by_index[index]].add(verdict)
        confirmations_by_outcome.setdefault(str(entry["acoustic_outcome"]), Tally()).add(
            verdict
        )
        row = ledger_by_index[index]
        row["proposal"] = {"disposition": "confirmed", "proposed_speaker": proposed, **verdict}

    causes: dict[str, dict[str, object]] = {}
    for entry in declines:
        index = int(entry["segment_index"])
        cause = str(entry.get("cause") or "unrecorded")
        bucket = causes.setdefault(
            cause,
            {
                "n": 0,
                "top_ranked": Tally(),
                "justified": 0,
                "overcautious": 0,
                "undetermined": 0,
                "model_answer": Tally(),
                "model_declined_too": 0,
                "model_versus_top": {
                    "both_correct": 0,
                    "model_only": 0,
                    "top_only": 0,
                    "neither": 0,
                    "undefined": 0,
                },
            },
        )
        bucket["n"] += 1
        top = top_by_index.get(index)
        row = ledger_by_index[index]
        record: dict[str, object] = {"disposition": "declined", "cause": cause}
        top_verdict = None
        if top is not None:
            top_verdict = verdict_for(top, truths[index], mapping)
            bucket["top_ranked"].add(top_verdict)
            declined_top.add(top_verdict)
            record["top_ranked"] = top_verdict
        classification = classify_decline(top_verdict, truths[index])
        bucket[classification] += 1
        record["classification"] = classification
        answer = entry.get("model_answer")
        if isinstance(answer, Mapping):
            if answer.get("disposition") == "propose" and answer.get("proposed_speaker"):
                model_verdict = verdict_for(
                    str(answer["proposed_speaker"]), truths[index], mapping
                )
                bucket["model_answer"].add(model_verdict)
                unconstrained.add(model_verdict)
                record["model_answer"] = model_verdict
                head_to_head = compare_verdicts(model_verdict, top_verdict)
                bucket["model_versus_top"][head_to_head] += 1
                record["model_versus_top"] = head_to_head
            else:
                bucket["model_declined_too"] += 1
        row["proposal"] = record

    baseline = top_tally.as_dict()
    confirmed = confirmations.as_dict()
    return {
        "artifact": {
            "constraint": proposal.get("constraint"),
            "layer": proposal.get("layer"),
            "source_segments_sha256": proposal.get("source_segments_sha256"),
            "proposals": len(proposals),
            "declined": len(declines),
            "unattributed": len(unattributed),
            "confirmation_coverage": ratio(len(proposals), len(unattributed)),
        },
        "confirmations": confirmed,
        "confirmations_by_evidence_state": {
            state: tally.as_dict()
            for state, tally in confirmations_by_state.items()
            if tally.n
        },
        "confirmations_by_acoustic_outcome": {
            outcome: tally.as_dict()
            for outcome, tally in sorted(confirmations_by_outcome.items())
        },
        "declines_by_cause": {
            cause: {
                "n": bucket["n"],
                "justified": bucket["justified"],
                "overcautious": bucket["overcautious"],
                "undetermined": bucket["undetermined"],
                "top_ranked": bucket["top_ranked"].as_dict(),
                "model_answer": bucket["model_answer"].as_dict(),
                "model_declined_too": bucket["model_declined_too"],
                "model_versus_top": bucket["model_versus_top"],
            }
            for cause, bucket in sorted(causes.items())
        },
        "declined_top_ranked": declined_top.as_dict(),
        "language_layer": {
            "top_ranked_baseline_strict_precision": baseline["strict_precision"],
            "confirmed_strict_precision": confirmed["strict_precision"],
            "declined_top_ranked_strict_precision": declined_top.as_dict()["strict_precision"],
            "top_ranked_baseline_lenient_precision": baseline["lenient_precision"],
            "confirmed_lenient_precision": confirmed["lenient_precision"],
            "declined_top_ranked_lenient_precision": declined_top.as_dict()[
                "lenient_precision"
            ],
            "confirmed_strict_wrong": confirmed["strict_defined"] - confirmed["strict_correct"],
            "unconstrained_model_answers": unconstrained.as_dict(),
        },
    }


def classify_decline(top_verdict: Mapping[str, object] | None, truth: Truth) -> str:
    """Was declining right?

    ``justified``: there was no top-ranked candidate to confirm, the reference has
    no clear speaker for the interval, or the top-ranked candidate was wrong.
    ``overcautious``: the top-ranked candidate was the reference's clear speaker.
    ``undetermined``: a top-ranked candidate existed but its speaker is unmapped.
    """

    if top_verdict is None:
        return "justified"
    if truth.classification != "clear":
        return "justified"
    if top_verdict["mapped"] is None:
        return "undetermined"
    return "overcautious" if top_verdict["strict"] else "justified"


def compare_verdicts(
    model: Mapping[str, object], top: Mapping[str, object] | None
) -> str:
    if model["strict"] is None:
        return "undefined"
    model_right = bool(model["strict"])
    top_right = bool(top["strict"]) if top is not None and top["strict"] is not None else False
    if model_right and top_right:
        return "both_correct"
    if model_right:
        return "model_only"
    if top_right:
        return "top_only"
    return "neither"


# MARK: - Rendering


def fmt(value: object) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, float):
        return f"{value:.3f}"
    return str(value)


def fmt_interval(value: object) -> str:
    if not isinstance(value, list):
        return "n/a"
    return f"[{value[0]:.2f}, {value[1]:.2f}]"


def tally_row(name: str, tally: Mapping[str, object]) -> str:
    return (
        f"| {name} | {tally['n']} | {tally['strict_correct']}/{tally['strict_defined']}"
        f" | {fmt(tally['strict_precision'])} | {fmt_interval(tally['strict_precision_ci95'])}"
        f" | {tally['lenient_correct']}/{tally['lenient_defined']}"
        f" | {fmt(tally['lenient_precision'])} | {tally['truth_classes']['ambiguous']}"
        f" | {tally['truth_classes']['no_reference_speech']} |"
    )


TALLY_HEADER = (
    "| family | n | strict correct | strict precision | strict 95 % CI | lenient correct"
    " | lenient precision | ambiguous | no reference speech |\n"
    "| --- | ---: | ---: | ---: | --- | ---: | ---: | ---: | ---: |"
)


def render_markdown(report: Mapping[str, object]) -> str:
    lines: list[str] = []
    mapping = report["mapping"]
    lines.append("## Cluster-to-reference mapping (maximal whole-file overlap, one-to-one)")
    lines.append("")
    references = mapping["reference_speakers"]
    lines.append("| hypothesis | " + " | ".join(references) + " | mapped to | purity |")
    lines.append("| --- | " + " | ".join("---:" for _ in references) + " | --- | ---: |")
    for speaker in mapping["hypothesis_speakers"]:
        row = mapping["overlap_matrix_s"][speaker]
        lines.append(
            f"| {speaker} | "
            + " | ".join(f"{row[other]:.1f}" for other in references)
            + f" | {fmt(mapping['mapping'][speaker])} | {fmt(mapping['hypothesis_purity'][speaker])} |"
        )
    lines.append("")
    segments = report["segments"]
    lines.append("## Segments")
    lines.append("")
    lines.append(
        f"- total {segments['total']}, attributed {segments['attributed']},"
        f" unattributed {segments['unattributed']}"
    )
    lines.append(f"- reference truth over all segments: {segments['truth_classes_all']}")
    lines.append(
        f"- reference truth over unattributed segments: {segments['truth_classes_unattributed']}"
    )
    lines.append(
        f"- evidence states over unattributed segments: {segments['evidence_states_unattributed']}"
    )
    lines.append(
        f"- acoustic outcomes over unattributed segments: {segments['acoustic_outcomes_unattributed']}"
    )
    lines.append("")
    lines.append("## Acoustic accuracy")
    lines.append("")
    lines.append(TALLY_HEADER)
    lines.append(tally_row("merge speaker_attribution (attributed segments)", report["acoustic_attribution"]))
    top = report["top_ranked_candidate"]
    lines.append(tally_row("top_ranked_candidate (unattributed segments)", top["overall"]))
    for state, tally in top["by_evidence_state"].items():
        lines.append(tally_row(f"top_ranked_candidate, state {state}", tally))
    for outcome, tally in top["by_acoustic_outcome"].items():
        lines.append(tally_row(f"top_ranked_candidate, outcome {outcome}", tally))
    lines.append("")
    proposal = report.get("proposal")
    if proposal is None:
        return "\n".join(lines) + "\n"
    artifact = proposal["artifact"]
    lines.append("## Speaker proposal (derived run)")
    lines.append("")
    lines.append(
        f"- constraint {artifact['constraint']}, proposals {artifact['proposals']},"
        f" declined {artifact['declined']}, unattributed {artifact['unattributed']},"
        f" confirmation coverage {fmt(artifact['confirmation_coverage'])}"
    )
    lines.append("")
    lines.append(TALLY_HEADER)
    lines.append(tally_row("confirmations", proposal["confirmations"]))
    for state, tally in proposal["confirmations_by_evidence_state"].items():
        lines.append(tally_row(f"confirmations, state {state}", tally))
    for outcome, tally in proposal["confirmations_by_acoustic_outcome"].items():
        lines.append(tally_row(f"confirmations, outcome {outcome}", tally))
    lines.append(tally_row("top_ranked_candidate on declined segments", proposal["declined_top_ranked"]))
    lines.append("")
    lines.append("### Declines by cause")
    lines.append("")
    lines.append(
        "| cause | n | justified | overcautious | undetermined"
        " | top-ranked strict | model answer strict | model declined too"
        " | model vs top (both/model/top/neither/undef) |"
    )
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |")
    for cause, bucket in proposal["declines_by_cause"].items():
        top_tally = bucket["top_ranked"]
        model_tally = bucket["model_answer"]
        versus = bucket["model_versus_top"]
        lines.append(
            f"| {cause} | {bucket['n']} | {bucket['justified']} | {bucket['overcautious']}"
            f" | {bucket['undetermined']}"
            f" | {top_tally['strict_correct']}/{top_tally['strict_defined']}"
            f" | {model_tally['strict_correct']}/{model_tally['strict_defined']}"
            f" | {bucket['model_declined_too']}"
            f" | {versus['both_correct']}/{versus['model_only']}/{versus['top_only']}"
            f"/{versus['neither']}/{versus['undefined']} |"
        )
    lines.append("")
    layer = proposal["language_layer"]
    lines.append("### What the language layer added or cost")
    lines.append("")
    lines.append("| quantity | strict | lenient |")
    lines.append("| --- | ---: | ---: |")
    lines.append(
        f"| top_ranked_candidate precision, all unattributed with a top candidate"
        f" | {fmt(layer['top_ranked_baseline_strict_precision'])}"
        f" | {fmt(layer['top_ranked_baseline_lenient_precision'])} |"
    )
    lines.append(
        f"| confirmed subset precision | {fmt(layer['confirmed_strict_precision'])}"
        f" | {fmt(layer['confirmed_lenient_precision'])} |"
    )
    lines.append(
        f"| declined subset, top_ranked_candidate precision"
        f" | {fmt(layer['declined_top_ranked_strict_precision'])}"
        f" | {fmt(layer['declined_top_ranked_lenient_precision'])} |"
    )
    unconstrained = layer["unconstrained_model_answers"]
    lines.append(
        f"| model answers applied without the constraint (n={unconstrained['n']})"
        f" | {fmt(unconstrained['strict_precision'])}"
        f" | {fmt(unconstrained['lenient_precision'])} |"
    )
    lines.append("")
    return "\n".join(lines) + "\n"


# MARK: - Entry point


def locate_proposal(path: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path | None]:
    if path.is_dir():
        artifact = path / "speaker" / "proposals.json"
        manifest = path / "manifest.json"
        return artifact, manifest if manifest.is_file() else None
    manifest = path.parent.parent / "manifest.json"
    return path, manifest if manifest.is_file() else None


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="score-speaker-proposal.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--reference-rttm",
        required=True,
        type=pathlib.Path,
        help="reference RTTM with per-speaker turns (e.g. the AMI fixture's reference.rttm)",
    )
    parser.add_argument(
        "--run",
        required=True,
        type=pathlib.Path,
        help="source run directory containing merged/ and diarization/",
    )
    parser.add_argument(
        "--proposal",
        type=pathlib.Path,
        help="derived set directory or its speaker/proposals.json; omit for the acoustic-only measurement",
    )
    parser.add_argument(
        "--dominant-share",
        type=float,
        default=DEFAULT_DOMINANT_SHARE,
        help="reference share above which a segment's truth is 'clear' (default: the merger's 0.60)",
    )
    parser.add_argument(
        "--near-tie-margin",
        type=float,
        default=DEFAULT_NEAR_TIE_MARGIN,
        help="share lead below which a unique top-ranked candidate counts as a near tie (default 0.05)",
    )
    parser.add_argument(
        "--json",
        type=pathlib.Path,
        help="write the full report, including the per-segment ledger, as JSON",
    )
    parser.add_argument(
        "--markdown",
        type=pathlib.Path,
        help="write the Markdown summary to this path in addition to stdout",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = build_parser().parse_args(argv)
    run = arguments.run
    segments_path = run / "merged" / "segments.json"
    conflicts_path = run / "merged" / "conflicts.json"
    timeline_path = run / "diarization" / "timeline.json"
    for path in (arguments.reference_rttm, segments_path, conflicts_path, timeline_path):
        if not path.is_file():
            print(f"missing input: {path}", file=sys.stderr)
            return 2

    reference = read_rttm(arguments.reference_rttm)
    timeline = read_timeline(timeline_path)
    segments_document = read_json(segments_path)
    segments = segments_document["segments"]
    conflicts = read_json(conflicts_path)
    inputs: dict[str, object] = {
        "reference_rttm": {"path": str(arguments.reference_rttm), "sha256": sha256_of(arguments.reference_rttm)},
        "merged_segments": {"path": str(segments_path), "sha256": sha256_of(segments_path)},
        "merged_conflicts": {"path": str(conflicts_path), "sha256": sha256_of(conflicts_path)},
        "diarization_timeline": {"path": str(timeline_path), "sha256": sha256_of(timeline_path)},
    }
    manifest_path = run / "manifest.json"
    if manifest_path.is_file():
        manifest = read_json(manifest_path)
        inputs["run"] = {
            "run_id": manifest.get("run_id"),
            "status": manifest.get("status"),
            "manifest_sha256": sha256_of(manifest_path),
            "models": manifest.get("models"),
            "backend": manifest.get("backend"),
        }

    proposal = None
    if arguments.proposal is not None:
        artifact_path, derived_manifest_path = locate_proposal(arguments.proposal)
        if not artifact_path.is_file():
            print(f"missing input: {artifact_path}", file=sys.stderr)
            return 2
        proposal = read_json(artifact_path)
        if proposal.get("source_segments_sha256") != inputs["merged_segments"]["sha256"]:
            print(
                "the proposal artifact was not made over this run's merged/segments.json",
                file=sys.stderr,
            )
            return 2
        inputs["speaker_proposals"] = {
            "path": str(artifact_path),
            "sha256": sha256_of(artifact_path),
        }
        if derived_manifest_path is not None:
            derived_manifest = read_json(derived_manifest_path)
            inputs["derived"] = {
                "derived_id": derived_manifest.get("derived_id"),
                "status": derived_manifest.get("status"),
                "manifest_sha256": sha256_of(derived_manifest_path),
                "postprocess": derived_manifest.get("postprocess"),
                "source": derived_manifest.get("source"),
            }

    report = score(
        reference,
        timeline,
        segments,
        conflicts,
        proposal,
        dominant_share=arguments.dominant_share,
        near_tie_margin=arguments.near_tie_margin,
    )
    report = {"inputs": inputs, **report}
    markdown = render_markdown(report)
    sys.stdout.write(markdown)
    if arguments.markdown is not None:
        arguments.markdown.write_text(markdown, encoding="utf-8")
    if arguments.json is not None:
        arguments.json.write_text(
            json.dumps(report, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
            encoding="utf-8",
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
