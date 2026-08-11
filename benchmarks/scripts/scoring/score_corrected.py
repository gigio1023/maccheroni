#!/usr/bin/env python3
"""Score the raw and corrected text of one completed correction run."""

from __future__ import annotations

import argparse
from hashlib import sha256
import json
from pathlib import Path
from typing import Any, Sequence

from check_run import validate_completed_run_manifest, validate_segments_document
from metrics import term_recall, text_error_rate, utterance_omissions


IMMUTABLE_SEGMENT_FIELDS = (
    "speaker",
    "start_s",
    "end_s",
    "language",
    "confidence",
)
CONFLICT_FIELDS = {
    "segment_index",
    "original_text",
    "candidate_text",
    "reason",
}


def _load_json(path: Path, *, label: str) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read {label} JSON: {path.name}: {error}") from error


def _file_sha256(path: Path) -> str:
    digest = sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _segments(document: object, *, label: str) -> list[dict[str, object]]:
    if not isinstance(document, dict):
        raise ValueError(f"{label} must be a JSON object")
    values = document.get("segments")
    if not isinstance(values, list):
        raise ValueError(f"{label} segments must be an array")
    for index, value in enumerate(values):
        if not isinstance(value, dict):
            raise ValueError(f"{label} segment {index} must be an object")
        for field in ("start_s", "end_s", "text"):
            if field not in value:
                raise ValueError(f"{label} segment {index} is missing field {field}")
    return values


def _joined_text(document: dict[str, object], *, label: str) -> str:
    values = _segments(document, label=label)
    ordered = sorted(
        values,
        key=lambda value: (float(value["start_s"]), float(value["end_s"])),
    )
    return " ".join(str(value["text"]) for value in ordered)


def _score_document(
    reference: dict[str, object],
    hypothesis: dict[str, object],
    terms: Sequence[dict[str, object]],
) -> dict[str, object]:
    reference_text = _joined_text(reference, label="reference")
    hypothesis_text = _joined_text(hypothesis, label="hypothesis")
    return {
        "cer": text_error_rate(
            reference_text, hypothesis_text, unit="character"
        ).as_dict(),
        "wer": text_error_rate(reference_text, hypothesis_text, unit="word").as_dict(),
        "terms": term_recall(terms, hypothesis_text),
        "omissions": utterance_omissions(
            _segments(reference, label="reference"),
            _segments(hypothesis, label="hypothesis"),
        ),
    }


def _validate_manifest(manifest: object) -> dict[str, object]:
    if not isinstance(manifest, dict):
        raise ValueError("manifest must be a JSON object")
    if manifest.get("status") != "succeeded":
        raise ValueError(
            f"correction run is not succeeded: status={manifest.get('status')!r}"
        )
    postprocess = manifest.get("postprocess")
    if not isinstance(postprocess, dict):
        raise ValueError("succeeded run has no correction postprocess metadata")
    mode = postprocess.get("mode", "correction")
    if mode == "translation":
        raise ValueError("translation run cannot be scored as corrected output")
    if mode != "correction":
        raise ValueError(f"unsupported postprocess mode: {mode!r}")
    return manifest


def _validate_correction_structure(
    raw: dict[str, object],
    corrected: dict[str, object],
) -> tuple[list[dict[str, object]], list[dict[str, object]]]:
    if raw.get("source") != corrected.get("source"):
        raise ValueError(
            "postprocess source metadata differs from merged transcript: "
            f"raw={raw.get('source')!r}, corrected={corrected.get('source')!r}"
        )
    if raw.get("num_speakers") != corrected.get("num_speakers"):
        raise ValueError(
            "postprocess num_speakers differs from merged transcript: "
            f"raw={raw.get('num_speakers')!r}, "
            f"corrected={corrected.get('num_speakers')!r}"
        )

    raw_segments = _segments(raw, label="merged transcript")
    corrected_segments = _segments(corrected, label="postprocess transcript")
    if len(raw_segments) != len(corrected_segments):
        first_difference = min(len(raw_segments), len(corrected_segments))
        if len(corrected_segments) < len(raw_segments):
            detail = "is missing from the postprocess transcript"
        else:
            detail = "is extra in the postprocess transcript"
        raise ValueError(
            f"postprocess segment {first_difference} {detail}; segment count "
            f"raw={len(raw_segments)}, corrected={len(corrected_segments)}"
        )

    for index, (original, candidate) in enumerate(
        zip(raw_segments, corrected_segments, strict=True)
    ):
        for field in IMMUTABLE_SEGMENT_FIELDS:
            if candidate.get(field) != original.get(field):
                raise ValueError(
                    f"postprocess segment {index} changed immutable field {field}: "
                    f"raw={original.get(field)!r}, corrected={candidate.get(field)!r}"
                )
    return raw_segments, corrected_segments


def _validate_conflicts(
    conflicts: object,
    raw_segments: Sequence[dict[str, object]],
    corrected_segments: Sequence[dict[str, object]],
) -> list[dict[str, object]]:
    if not isinstance(conflicts, list):
        raise ValueError("postprocess conflicts must be an array")

    seen: set[int] = set()
    validated: list[dict[str, object]] = []
    for conflict_index, conflict in enumerate(conflicts):
        if not isinstance(conflict, dict):
            raise ValueError(f"conflict {conflict_index} must be an object")
        if set(conflict) != CONFLICT_FIELDS:
            missing = sorted(CONFLICT_FIELDS - set(conflict))
            extra = sorted(set(conflict) - CONFLICT_FIELDS)
            raise ValueError(
                f"conflict {conflict_index} has invalid fields; "
                f"missing={missing}, extra={extra}, expected candidate_text, "
                "original_text, reason, and segment_index"
            )

        segment_index = conflict["segment_index"]
        if not isinstance(segment_index, int) or isinstance(segment_index, bool):
            raise ValueError(
                f"conflict {conflict_index} segment_index must be an integer"
            )
        if segment_index < 0 or segment_index >= len(raw_segments):
            raise ValueError(
                f"conflict {conflict_index} targets segment {segment_index} "
                f"outside the valid range 0..{len(raw_segments) - 1}"
            )
        if segment_index in seen:
            raise ValueError(f"duplicate conflict for segment {segment_index}")
        seen.add(segment_index)

        for field in ("original_text", "candidate_text", "reason"):
            if not isinstance(conflict[field], str):
                raise ValueError(
                    f"conflict {conflict_index} for segment {segment_index} "
                    f"field {field} must be a string"
                )
        if not str(conflict["candidate_text"]).strip():
            raise ValueError(
                f"conflict {conflict_index} for segment {segment_index} "
                "field candidate_text must not be empty"
            )

        raw_text = str(raw_segments[segment_index].get("text", ""))
        corrected_text = str(corrected_segments[segment_index].get("text", ""))
        if conflict["original_text"] != raw_text:
            raise ValueError(
                f"conflict {conflict_index} for segment {segment_index} "
                "original_text differs from the merged transcript"
            )
        if corrected_text != raw_text:
            raise ValueError(
                f"conflict {conflict_index} for segment {segment_index} was flagged "
                "for review but changed the corrected text"
            )

        flags = corrected_segments[segment_index].get("flags", [])
        if not isinstance(flags, list):
            raise ValueError(
                f"conflict {conflict_index} for segment {segment_index} flags "
                "must be an array"
            )
        missing_flags = {"uncertain", "conflict"} - set(flags)
        if missing_flags:
            raise ValueError(
                f"conflict {conflict_index} for segment {segment_index} is missing "
                f"review flags: {sorted(missing_flags)}"
            )
        validated.append(conflict)

    review_flags = {"uncertain", "conflict"}
    reviewed_segments: set[int] = set()
    for segment_index, (original, candidate) in enumerate(
        zip(raw_segments, corrected_segments, strict=True)
    ):
        flags = candidate.get("flags", [])
        if not isinstance(flags, list):
            raise ValueError(
                f"postprocess segment {segment_index} flags must be an array"
            )
        present = review_flags.intersection(flags)
        if not present:
            continue
        missing = review_flags - set(flags)
        if missing:
            raise ValueError(
                f"postprocess segment {segment_index} has incomplete review flags: "
                f"missing={sorted(missing)}"
            )
        reviewed_segments.add(segment_index)
        if candidate.get("text") != original.get("text"):
            raise ValueError(
                f"postprocess segment {segment_index} is flagged for review but "
                "changed the source text"
            )

    missing_conflicts = reviewed_segments - seen
    if missing_conflicts:
        segment_index = min(missing_conflicts)
        raise ValueError(
            f"postprocess segment {segment_index} has review flags but no "
            "conflict record"
        )
    unexpected_conflicts = seen - reviewed_segments
    if unexpected_conflicts:
        segment_index = min(unexpected_conflicts)
        raise ValueError(
            f"conflict record targets segment {segment_index} without review flags"
        )
    return validated


def _metric_delta(
    raw: int | float | None,
    corrected: int | float | None,
    *,
    better_when: str,
) -> dict[str, object]:
    if raw is None or corrected is None:
        difference = None
        outcome = "not_comparable"
    else:
        difference = corrected - raw
        if corrected == raw:
            outcome = "unchanged"
        elif (better_when == "lower" and corrected < raw) or (
            better_when == "higher" and corrected > raw
        ):
            outcome = "improved"
        else:
            outcome = "regressed"
    return {
        "raw": raw,
        "corrected": corrected,
        "corrected_minus_raw": difference,
        "better_when": better_when,
        "outcome": outcome,
    }


def _metric_deltas(
    raw: dict[str, object], corrected: dict[str, object]
) -> dict[str, dict[str, object]]:
    return {
        "cer.error_rate": _metric_delta(
            raw["cer"]["error_rate"],
            corrected["cer"]["error_rate"],
            better_when="lower",
        ),
        "wer.error_rate": _metric_delta(
            raw["wer"]["error_rate"],
            corrected["wer"]["error_rate"],
            better_when="lower",
        ),
        "terms.term_recall": _metric_delta(
            raw["terms"]["term_recall"],
            corrected["terms"]["term_recall"],
            better_when="higher",
        ),
        "omissions.omitted_utterances": _metric_delta(
            raw["omissions"]["omitted_utterances"],
            corrected["omissions"]["omitted_utterances"],
            better_when="lower",
        ),
        "omissions.omission_rate": _metric_delta(
            raw["omissions"]["omission_rate"],
            corrected["omissions"]["omission_rate"],
            better_when="lower",
        ),
    }


def _classify_change(
    raw_cer_errors: int,
    raw_wer_errors: int,
    corrected_cer_errors: int,
    corrected_wer_errors: int,
) -> str:
    cer_delta = corrected_cer_errors - raw_cer_errors
    wer_delta = corrected_wer_errors - raw_wer_errors
    if cer_delta == 0 and wer_delta == 0:
        return "unchanged"
    if cer_delta <= 0 and wer_delta <= 0:
        return "closer"
    if cer_delta >= 0 and wer_delta >= 0:
        return "further"
    return "mixed"


def _correction_directions(
    raw_segments: Sequence[dict[str, object]],
    corrected_segments: Sequence[dict[str, object]],
    reference: dict[str, object],
    applied_indices: Sequence[int],
) -> dict[str, object]:
    references_by_interval: dict[
        tuple[float, float], list[tuple[int, dict[str, object]]]
    ] = {}
    for reference_index, reference_segment in enumerate(
        _segments(reference, label="reference")
    ):
        if reference_segment.get("scorable", True) is False:
            continue
        interval = (
            float(reference_segment["start_s"]),
            float(reference_segment["end_s"]),
        )
        references_by_interval.setdefault(interval, []).append(
            (reference_index, reference_segment)
        )

    evaluated: list[dict[str, object]] = []
    unevaluated: list[dict[str, object]] = []
    counts = {"closer": 0, "further": 0, "mixed": 0, "unchanged": 0}
    correct_to_incorrect = 0
    for segment_index in applied_indices:
        original = raw_segments[segment_index]
        candidate = corrected_segments[segment_index]
        interval = (float(original["start_s"]), float(original["end_s"]))
        references = references_by_interval.get(interval, [])
        if len(references) != 1:
            if references:
                reason = (
                    "no unique reference segment has the exact interval; "
                    f"found {len(references)} matches"
                )
            else:
                reason = "no unique reference segment has the exact interval"
            unevaluated.append({"segment_index": segment_index, "reason": reason})
            continue

        reference_index, reference_segment = references[0]
        reference_text = str(reference_segment["text"])
        original_text = str(original["text"])
        candidate_text = str(candidate["text"])
        raw_cer = text_error_rate(reference_text, original_text, unit="character")
        raw_wer = text_error_rate(reference_text, original_text, unit="word")
        corrected_cer = text_error_rate(
            reference_text, candidate_text, unit="character"
        )
        corrected_wer = text_error_rate(reference_text, candidate_text, unit="word")
        if raw_cer.reference_units == 0 or raw_wer.reference_units == 0:
            unevaluated.append(
                {
                    "segment_index": segment_index,
                    "reason": "unique reference segment normalizes to empty text",
                }
            )
            continue

        classification = _classify_change(
            raw_cer.errors,
            raw_wer.errors,
            corrected_cer.errors,
            corrected_wer.errors,
        )
        counts[classification] += 1
        is_correct_to_incorrect = (
            raw_cer.errors == 0
            and raw_wer.errors == 0
            and classification == "further"
        )
        correct_to_incorrect += int(is_correct_to_incorrect)
        evaluated.append(
            {
                "segment_index": segment_index,
                "reference_segment_index": reference_index,
                "raw": {
                    "cer_errors": raw_cer.errors,
                    "wer_errors": raw_wer.errors,
                },
                "corrected": {
                    "cer_errors": corrected_cer.errors,
                    "wer_errors": corrected_wer.errors,
                },
                "classification": classification,
                "correct_to_incorrect": is_correct_to_incorrect,
            }
        )

    observed_worse = counts["further"]
    return {
        "alignment_method": "unique_reference_segment_with_exact_interval",
        "classification_method": "pareto_cer_and_wer_edit_errors",
        "evaluated_applied_text_changes": len(evaluated),
        "unevaluated_applied_text_changes": len(unevaluated),
        **counts,
        "correct_to_incorrect": correct_to_incorrect,
        "observed_correction_made_worse_count": observed_worse,
        "correction_made_worse_count": (
            None if unevaluated else observed_worse
        ),
        "segments": evaluated,
        "unevaluated_segments": unevaluated,
    }


def score_corrected_run(
    run_root: Path,
    reference_path: Path,
    terms_path: Path,
) -> dict[str, object]:
    """Validate and score one succeeded run's merged and corrected transcripts."""

    run_root = Path(run_root)
    reference_path = Path(reference_path)
    terms_path = Path(terms_path)
    raw_path = run_root / "merged" / "segments.json"
    corrected_path = run_root / "postprocess" / "segments.json"
    conflicts_path = run_root / "postprocess" / "conflicts.json"

    manifest, artifact_paths = validate_completed_run_manifest(run_root)
    manifest = _validate_manifest(manifest)
    for relative in (
        "merged/segments.json",
        "postprocess/segments.json",
        "postprocess/conflicts.json",
    ):
        if relative not in artifact_paths:
            raise ValueError(f"scored artifact is unlisted in manifest: {relative}")
    raw = _load_json(raw_path, label="merged segments")
    corrected = _load_json(corrected_path, label="postprocess segments")
    reference = _load_json(reference_path, label="reference segments")
    terms = _load_json(terms_path, label="terms")
    conflicts = _load_json(conflicts_path, label="postprocess conflicts")
    if not isinstance(raw, dict) or not isinstance(corrected, dict):
        raise ValueError("merged and postprocess segments must be JSON objects")
    if not isinstance(reference, dict):
        raise ValueError("reference segments must be a JSON object")
    if not isinstance(terms, list):
        raise ValueError("terms must be a JSON array")

    raw = validate_segments_document(raw, label="merged transcript")
    corrected = validate_segments_document(
        corrected,
        label="postprocess transcript",
        validate_semantics=False,
    )

    raw_segments, corrected_segments = _validate_correction_structure(raw, corrected)
    validate_segments_document(corrected, label="postprocess transcript")
    validated_conflicts = _validate_conflicts(
        conflicts, raw_segments, corrected_segments
    )
    applied_indices = [
        index
        for index, (original, candidate) in enumerate(
            zip(raw_segments, corrected_segments, strict=True)
        )
        if original.get("text") != candidate.get("text")
    ]

    raw_scores = _score_document(reference, raw, terms)
    corrected_scores = _score_document(reference, corrected, terms)
    observable_total = len(applied_indices) + len(validated_conflicts)
    correction_outcomes = {
        "applied_text_changes": len(applied_indices),
        "flagged_for_review": len(validated_conflicts),
        "observable_proposal_outcomes": observable_total,
        "applied_fraction": (
            len(applied_indices) / observable_total if observable_total else None
        ),
        "review_fraction": (
            len(validated_conflicts) / observable_total if observable_total else None
        ),
        "applied_count_basis": "raw_corrected_text_difference",
    }
    return {
        "schema_version": "1.0.0",
        "run": {
            "run_id": manifest.get("run_id"),
            "merged_segments_sha256": _file_sha256(raw_path),
            "corrected_segments_sha256": _file_sha256(corrected_path),
            "conflicts_sha256": _file_sha256(conflicts_path),
        },
        "reference": {
            "file_name": reference_path.name,
            "sha256": _file_sha256(reference_path),
        },
        "terms": {
            "file_name": terms_path.name,
            "sha256": _file_sha256(terms_path),
        },
        "scores": {"raw": raw_scores, "corrected": corrected_scores},
        "metric_deltas": _metric_deltas(raw_scores, corrected_scores),
        "correction_outcomes": correction_outcomes,
        "applied_correction_direction": _correction_directions(
            raw_segments,
            corrected_segments,
            reference,
            applied_indices,
        ),
    }


def _parse_arguments(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Score raw and corrected output from one completed correction run"
    )
    parser.add_argument("--run-root", required=True, type=Path)
    parser.add_argument("--reference", required=True, type=Path)
    parser.add_argument("--terms", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parse_arguments(argv)
    result = score_corrected_run(
        arguments.run_root,
        arguments.reference,
        arguments.terms,
    )
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    with arguments.output.open("x", encoding="utf-8") as output:
        json.dump(result, output, ensure_ascii=False, indent=2, sort_keys=True)
        output.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
