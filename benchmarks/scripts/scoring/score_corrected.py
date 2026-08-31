#!/usr/bin/env python3
"""Score the raw and corrected text of one completed correction run."""

from __future__ import annotations

import argparse
from datetime import datetime
from hashlib import sha256
import json
import math
import os
from pathlib import Path
import stat
from typing import Any, Sequence

from jsonschema import Draft202012Validator, FormatChecker, ValidationError
from referencing import Registry
from referencing.jsonschema import DRAFT202012

from check_run import validate_completed_run_manifest, validate_segments_document
from check_contracts import _validate_derived_semantics
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
DERIVED_ARTIFACTS = {
    "postprocess/segments.json": "postprocess_segments",
    "postprocess/conflicts.json": "postprocess_conflicts",
}
SOURCE_ARTIFACTS = {
    "primary/raw.txt": "primary_raw",
    "primary/segments.json": "primary_segments",
    "diarization/timeline.json": "diarization_timeline",
    "merged/segments.json": "merged_segments",
    "merged/conflicts.json": "merged_conflicts",
}
SCRIPT_DIR = Path(__file__).resolve().parent
REPOSITORY_ROOT = SCRIPT_DIR.parents[2]


def _load_json(path: Path, *, label: str) -> Any:
    def reject_nonfinite(value: str) -> None:
        raise ValueError(f"non-finite JSON number is forbidden: {value}")

    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            parse_constant=reject_nonfinite,
        )
    except (OSError, ValueError) as error:
        raise ValueError(f"cannot read {label} JSON: {path.name}: {error}") from error


def _file_sha256(path: Path) -> str:
    digest = sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _require_mapping(value: object, *, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{label} must be a JSON object")
    return value


def _require_nonempty_string(value: object, *, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{label} must be a non-empty string")
    return value


def _validate_sha256(value: object, *, label: str) -> str:
    if not isinstance(value, str) or len(value) != 64 or any(
        character not in "0123456789abcdef" for character in value
    ):
        raise ValueError(f"{label} must be a lowercase SHA-256")
    return value


def _validate_selected_derived_id(derived_id: object) -> str:
    value = _require_nonempty_string(derived_id, label="selected derived ID")
    if value in {".", ".."} or Path(value).name != value or "/" in value or "\\" in value:
        raise ValueError("selected derived ID must be one path component")
    return value


def _validate_completed_source_coverage(manifest: dict[str, Any]) -> None:
    coverage = _require_mapping(manifest.get("coverage"), label="source coverage")
    boundaries = manifest.get("chunk_boundaries")
    if not isinstance(boundaries, list):
        raise ValueError("source chunk boundaries must be an array")
    strategy = coverage.get("strategy")
    planned = coverage.get("chunks_planned")
    completed = coverage.get("chunks_completed")
    input_duration = coverage.get("input_duration_s")
    processed_duration = coverage.get("processed_duration_s")
    if (
        strategy not in {"full", "chunked"}
        or coverage.get("truncated") is not False
        or not isinstance(planned, int)
        or isinstance(planned, bool)
        or planned <= 0
        or completed != planned
        or len(boundaries) != planned
        or (strategy == "full" and planned != 1)
        or (strategy == "chunked" and planned <= 1)
        or not isinstance(input_duration, (int, float))
        or isinstance(input_duration, bool)
        or not isinstance(processed_duration, (int, float))
        or isinstance(processed_duration, bool)
        or not math.isfinite(float(input_duration))
        or not math.isfinite(float(processed_duration))
    ):
        raise ValueError("source run does not have complete non-truncated chunk coverage")
    if any(boundary.get("status") != "succeeded" for boundary in boundaries):
        raise ValueError("source chunk coverage contains a non-succeeded boundary")
    numeric_boundaries: list[tuple[float, float]] = []
    for index, boundary in enumerate(boundaries):
        start = boundary.get("start_s")
        end = boundary.get("end_s")
        if (
            not isinstance(start, (int, float))
            or isinstance(start, bool)
            or not isinstance(end, (int, float))
            or isinstance(end, bool)
            or not math.isfinite(float(start))
            or not math.isfinite(float(end))
        ):
            raise ValueError(f"source chunk boundary {index} has a non-finite time")
        numeric_boundaries.append((float(start), float(end)))
    tolerance = 0.01
    first_start = numeric_boundaries[0][0]
    last_end = numeric_boundaries[-1][1]
    if (
        abs(first_start) > tolerance
        or abs(last_end - float(input_duration)) > tolerance
        or abs(last_end - float(processed_duration)) > tolerance
    ):
        raise ValueError("source chunk coverage does not span the complete input")
    for previous, current in zip(numeric_boundaries, numeric_boundaries[1:]):
        if abs(current[0] - previous[1]) > tolerance:
            raise ValueError("source chunk coverage has a gap or overlap")
    covered_duration = sum(
        end - start for start, end in numeric_boundaries
    )
    if abs(covered_duration - float(processed_duration)) > tolerance:
        raise ValueError("source chunk coverage duration is incomplete or overlapping")
    glossary = _require_mapping(manifest.get("glossary"), label="source glossary")
    if glossary.get("provided") is True and glossary.get("applied") is not True:
        raise ValueError("a succeeded source run did not apply its provided glossary")


def _validate_canonical_source_artifacts(
    manifest: dict[str, Any], artifact_paths: set[str]
) -> None:
    if not set(SOURCE_ARTIFACTS).issubset(artifact_paths):
        raise ValueError("source run is missing a canonical derivation artifact")
    artifacts = manifest.get("artifacts", [])
    for path, kind in SOURCE_ARTIFACTS.items():
        matches = [artifact for artifact in artifacts if artifact.get("kind") == kind]
        if len(matches) != 1 or matches[0].get("path") != path:
            raise ValueError(
                f"source run must seal exactly one canonical {kind} artifact at {path}"
            )


def _validate_reference_document(reference: dict[str, Any]) -> dict[str, Any]:
    projected = dict(reference)
    values = reference.get("segments")
    if not isinstance(values, list):
        raise ValueError("reference transcript segments must be an array")
    projected_segments: list[dict[str, Any]] = []
    for index, value in enumerate(values):
        if not isinstance(value, dict):
            raise ValueError(f"reference transcript segment {index} must be an object")
        scorable = value.get("scorable", True)
        if not isinstance(scorable, bool):
            raise ValueError(
                f"reference transcript segment {index} scorable must be a boolean"
            )
        projected_segments.append(
            {key: item for key, item in value.items() if key != "scorable"}
        )
    projected["segments"] = projected_segments
    validate_segments_document(projected, label="reference transcript")
    return reference


def _regular_files(root: Path) -> set[str]:
    files: set[str] = set()
    for directory, directory_names, file_names in os.walk(root, followlinks=False):
        current = Path(directory)
        for name in directory_names:
            path = current / name
            if path.is_symlink():
                raise ValueError(
                    f"derived directory contains a symbolic link: {path.relative_to(root)}"
                )
        for name in file_names:
            path = current / name
            relative = path.relative_to(root).as_posix()
            if path.is_symlink() or not path.is_file():
                raise ValueError(f"derived artifact is not a regular file: {relative}")
            files.add(relative)
    return files


def _safe_source_artifact_path(run_root: Path, relative: object) -> Path:
    if (
        not isinstance(relative, str)
        or not relative
        or relative.startswith("/")
        or "\\" in relative
        or any(part in {"", ".", ".."} for part in relative.split("/"))
    ):
        raise ValueError(f"unsafe source artifact path: {relative!r}")
    path = run_root.joinpath(*relative.split("/"))
    root_resolved = run_root.resolve()
    if not path.resolve(strict=False).is_relative_to(root_resolved):
        raise ValueError(f"source artifact path escapes its run: {relative}")
    current = run_root
    for part in relative.split("/"):
        current = current / part
        try:
            mode = current.lstat().st_mode
        except OSError as error:
            raise ValueError(f"source artifact is missing: {relative}") from error
        if stat.S_ISLNK(mode):
            raise ValueError(f"source artifact path contains a symbolic link: {relative}")
    if not stat.S_ISREG(path.lstat().st_mode):
        raise ValueError(f"source artifact is not a regular file: {relative}")
    return path


def _validate_source_root(run_root: Path) -> None:
    try:
        root_mode = run_root.lstat().st_mode
    except OSError as error:
        raise ValueError("source run root is missing") from error
    if stat.S_ISLNK(root_mode) or not stat.S_ISDIR(root_mode):
        raise ValueError("source run root must be a real directory")
    manifest_path = run_root / "manifest.json"
    try:
        manifest_mode = manifest_path.lstat().st_mode
    except OSError as error:
        raise ValueError("source manifest is missing") from error
    if stat.S_ISLNK(manifest_mode) or not stat.S_ISREG(manifest_mode):
        raise ValueError("source manifest must be a regular file")


def _validate_source_tree_seal(run_root: Path, manifest: dict[str, Any]) -> None:
    _validate_source_root(run_root)

    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, list):
        raise ValueError("source manifest artifacts must be an array")
    declared: set[str] = set()
    for index, value in enumerate(artifacts):
        artifact = _require_mapping(value, label=f"source artifact {index}")
        relative = artifact.get("path")
        _safe_source_artifact_path(run_root, relative)
        if relative in declared:
            raise ValueError(f"duplicate source artifact path: {relative}")
        declared.add(relative)

    actual: set[str] = set()
    for directory, directory_names, file_names in os.walk(
        run_root, followlinks=False
    ):
        current = Path(directory)
        kept_directories: list[str] = []
        for name in directory_names:
            path = current / name
            relative = path.relative_to(run_root).as_posix()
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode) or not stat.S_ISDIR(mode):
                raise ValueError(f"source tree contains an unsafe directory: {relative}")
            if relative == "derived":
                continue
            kept_directories.append(name)
        directory_names[:] = kept_directories
        for name in file_names:
            path = current / name
            relative = path.relative_to(run_root).as_posix()
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode) or not stat.S_ISREG(mode):
                raise ValueError(f"source tree contains a non-regular file: {relative}")
            if relative == "manifest.json" or name == ".DS_Store":
                continue
            actual.add(relative)
    if actual != declared:
        raise ValueError(
            "source artifact inventory differs from its sealed manifest: "
            f"unlisted={sorted(actual - declared)}, missing={sorted(declared - actual)}"
        )


def _reject_output_within_inputs(output: Path, inputs: Sequence[Path]) -> None:
    resolved_output = Path(output).resolve(strict=False)
    for root in inputs:
        resolved_root = Path(root).resolve(strict=False)
        if resolved_output == resolved_root or resolved_output.is_relative_to(
            resolved_root
        ):
            raise ValueError(
                f"output path must be outside immutable input tree: {resolved_root.name}"
            )


def _validate_derived_manifest(
    run_root: Path,
    source_manifest: dict[str, Any],
    source_manifest_sha256: str,
    source_segments_sha256: str,
    selected_derived_id: str,
) -> tuple[Path, dict[str, Any], dict[str, str]]:
    derived_container = run_root / "derived"
    if derived_container.is_symlink():
        raise ValueError("source derived directory must not be a symbolic link")
    derived_root = run_root / "derived" / selected_derived_id
    if derived_root.is_symlink():
        raise ValueError("selected derived directory must not be a symbolic link")
    manifest_path = derived_root / "manifest.json"
    manifest = _require_mapping(
        _load_json(manifest_path, label="derived manifest"),
        label="derived manifest",
    )
    manifest_schema = _load_json(
        REPOSITORY_ROOT / "docs/contracts/manifest.schema.json",
        label="manifest schema",
    )
    derived_schema = _load_json(
        REPOSITORY_ROOT / "docs/contracts/derived-manifest.schema.json",
        label="derived manifest schema",
    )
    registry = Registry().with_resources(
        [
            (str(manifest_schema["$id"]), DRAFT202012.create_resource(manifest_schema)),
            (str(derived_schema["$id"]), DRAFT202012.create_resource(derived_schema)),
        ]
    )
    try:
        Draft202012Validator(
            derived_schema,
            format_checker=FormatChecker(),
            registry=registry,
        ).validate(manifest)
    except ValidationError as error:
        location = ".".join(str(component) for component in error.absolute_path)
        suffix = f" at {location}" if location else ""
        raise ValueError(
            f"derived manifest schema violation{suffix}: {error.message}"
        ) from error
    _validate_derived_semantics(manifest)
    if manifest.get("derived_id") != selected_derived_id:
        raise ValueError(
            "selected derived ID differs from the sealed derived manifest"
        )
    if manifest.get("status") != "succeeded" or manifest.get("failure") is not None:
        raise ValueError("selected derived correction is not succeeded")

    source = _require_mapping(manifest.get("source"), label="derived source lineage")
    expected_source = {
        "run_id": source_manifest.get("run_id"),
        "manifest_sha256": source_manifest_sha256,
        "segments_path": "merged/segments.json",
        "segments_sha256": source_segments_sha256,
    }
    if source != expected_source:
        raise ValueError("derived source lineage does not match the sealed source run")

    operation = _require_mapping(
        manifest.get("operation"), label="derived operation profile"
    )
    _require_nonempty_string(
        operation.get("profile_name"), label="derived operation profile_name"
    )
    if operation.get("mode") != "correction" or operation.get("target_language") is not None:
        raise ValueError("selected derived output is not a correction")
    if operation.get("glossary_semantics") not in {"current-profile", "source-run"}:
        raise ValueError("derived operation glossary semantics are unsupported")
    glossary_hash = operation.get("glossary_sha256")
    glossary_count = operation.get("glossary_item_count")
    if (
        not isinstance(glossary_count, int)
        or isinstance(glossary_count, bool)
        or glossary_count < 0
    ):
        raise ValueError("derived operation glossary item count is invalid")
    if glossary_hash is None:
        if glossary_count != 0:
            raise ValueError("derived operation has glossary items without a hash")
    else:
        _validate_sha256(glossary_hash, label="derived operation glossary hash")
        if glossary_count == 0:
            raise ValueError("derived operation has a glossary hash with zero items")
    if operation.get("glossary_semantics") == "source-run":
        source_glossary = _require_mapping(
            source_manifest.get("glossary"), label="source glossary"
        )
        expected_hash = source_glossary.get("sha256") if source_glossary.get("provided") else None
        expected_count = source_glossary.get("item_count") if source_glossary.get("provided") else 0
        if (glossary_hash, glossary_count) != (expected_hash, expected_count):
            raise ValueError("source-run glossary provenance differs from the source manifest")

    postprocess = _require_mapping(
        manifest.get("postprocess"), label="derived postprocess provenance"
    )
    if postprocess.get("mode") != "correction":
        raise ValueError("derived postprocess mode must explicitly be correction")
    backend = _require_mapping(postprocess.get("backend"), label="postprocess backend")
    _require_nonempty_string(backend.get("name"), label="postprocess backend name")
    _require_nonempty_string(backend.get("version"), label="postprocess backend version")
    _require_nonempty_string(postprocess.get("model_id"), label="postprocess model_id")
    for field in ("model_revision", "quantization"):
        if postprocess.get(field) is not None and not isinstance(postprocess.get(field), str):
            raise ValueError(f"postprocess {field} must be a string or null")
    if postprocess.get("input_mode") != "text-only":
        raise ValueError("derived postprocess input mode must be text-only")
    if postprocess.get("glossary_sha256") != glossary_hash:
        raise ValueError("derived operation and postprocess glossary hashes differ")
    if postprocess.get("target_language") is not None:
        raise ValueError("correction postprocess target language must be null")
    if postprocess.get("source_segments_sha256") is not None:
        raise ValueError("correction postprocess source_segments_sha256 must be null")
    batching = _require_mapping(
        postprocess.get("batching"), label="derived postprocess batching evidence"
    )
    positive_fields = (
        "maximum_prompt_utf8_bytes",
        "maximum_segments_per_batch",
        "output_token_planning_budget",
        "output_tokens_per_input_utf8_byte_permille",
        "batches_planned",
        "maximum_observed_prompt_utf8_bytes",
        "maximum_observed_estimated_output_tokens",
    )
    nonnegative_fields = (
        "base_output_token_reserve",
        "per_segment_output_token_reserve",
        "maximum_observed_input_text_utf8_bytes",
        "maximum_observed_output_text_utf8_bytes",
        "maximum_observed_response_utf8_bytes",
        "maximum_observed_accepted_output_token_upper_bound",
    )
    for field in (*positive_fields, *nonnegative_fields):
        value = batching.get(field)
        minimum = 1 if field in positive_fields else 0
        if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
            raise ValueError(f"derived postprocess batching field {field} is invalid")
    if batching["maximum_observed_prompt_utf8_bytes"] > batching["maximum_prompt_utf8_bytes"]:
        raise ValueError("derived postprocess observed prompt exceeds its batch limit")
    if (
        batching["maximum_observed_estimated_output_tokens"]
        > batching["output_token_planning_budget"]
    ):
        raise ValueError("derived postprocess estimated output exceeds its planning budget")
    if (
        batching["maximum_observed_accepted_output_token_upper_bound"]
        > batching["output_token_planning_budget"]
    ):
        raise ValueError("derived postprocess accepted output exceeds its planning budget")
    if (
        batching["maximum_observed_response_utf8_bytes"]
        < batching["maximum_observed_output_text_utf8_bytes"]
    ):
        raise ValueError("derived postprocess response evidence is smaller than output text")
    output_status = batching.get("output_token_limit_status")
    maximum_output_tokens = batching.get("maximum_output_tokens")
    if output_status == "configured":
        if not isinstance(maximum_output_tokens, int) or isinstance(maximum_output_tokens, bool):
            raise ValueError("configured output token limit is missing")
        if batching["output_token_planning_budget"] > maximum_output_tokens:
            raise ValueError("output planning budget exceeds the configured token limit")
    elif output_status == "service-managed-unavailable":
        if maximum_output_tokens is not None:
            raise ValueError("service-managed output token limit must be null")
    else:
        raise ValueError("derived postprocess output token limit status is invalid")

    timing = _require_mapping(manifest.get("timing"), label="derived timing")
    started = _require_nonempty_string(timing.get("started_at"), label="derived started_at")
    finished = _require_nonempty_string(timing.get("finished_at"), label="derived finished_at")
    wall_time = timing.get("wall_time_s")
    if (
        not isinstance(wall_time, (int, float))
        or isinstance(wall_time, bool)
        or not math.isfinite(float(wall_time))
        or float(wall_time) < 0
    ):
        raise ValueError("derived wall_time_s must be a finite non-negative number")
    try:
        started_at = datetime.fromisoformat(started.replace("Z", "+00:00"))
        finished_at = datetime.fromisoformat(finished.replace("Z", "+00:00"))
        if finished_at < started_at:
            raise ValueError("derived timing finishes before it starts")
        elapsed = (finished_at - started_at).total_seconds()
        tolerance = max(1.0, elapsed * 0.05)
        if abs(elapsed - float(wall_time)) > tolerance:
            raise ValueError("derived wall_time_s does not match its timestamps")
    except ValueError as error:
        if str(error) == "derived timing finishes before it starts":
            raise
        raise ValueError("derived timing is invalid") from error

    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, list) or len(artifacts) != len(DERIVED_ARTIFACTS):
        raise ValueError("derived correction artifact set is incomplete")
    observed: dict[str, str] = {}
    kinds: set[str] = set()
    for index, value in enumerate(artifacts):
        artifact = _require_mapping(value, label=f"derived artifact {index}")
        relative = artifact.get("path")
        if relative not in DERIVED_ARTIFACTS:
            raise ValueError(f"derived correction has an unexpected artifact: {relative}")
        if relative in observed or artifact.get("kind") in kinds:
            raise ValueError("derived correction has a duplicate artifact path or kind")
        if artifact.get("kind") != DERIVED_ARTIFACTS[relative]:
            raise ValueError(f"derived artifact kind does not match its path: {relative}")
        expected_hash = _validate_sha256(
            artifact.get("sha256"), label=f"derived artifact hash for {relative}"
        )
        path = derived_root / relative
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"derived artifact is missing or not regular: {relative}")
        actual_hash = _file_sha256(path)
        if actual_hash != expected_hash:
            raise ValueError(f"derived artifact hash mismatch: {relative}")
        observed[relative] = actual_hash
        kinds.add(str(artifact.get("kind")))
    inventory = _regular_files(derived_root)
    expected_inventory = {"manifest.json", *DERIVED_ARTIFACTS}
    if inventory != expected_inventory:
        raise ValueError(
            "derived correction file inventory differs from its sealed artifact set"
        )
    return derived_root, manifest, observed


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
        if not str(conflict["reason"]).strip():
            raise ValueError(
                f"conflict {conflict_index} for segment {segment_index} "
                "field reason must not be empty"
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

    for segment_index, (original, candidate) in enumerate(
        zip(raw_segments, corrected_segments, strict=True)
    ):
        original_flags = original.get("flags")
        if segment_index not in seen:
            if candidate.get("flags") != original_flags:
                raise ValueError(
                    f"postprocess segment {segment_index} changed immutable flags "
                    "without a derived conflict record"
                )
            continue
        expected_flags = list(original_flags) if isinstance(original_flags, list) else []
        for flag in ("uncertain", "conflict"):
            if flag not in expected_flags:
                expected_flags.append(flag)
        if candidate.get("flags") != expected_flags:
            raise ValueError(
                f"postprocess segment {segment_index} review flags differ from "
                "the source-plus-conflict contract"
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
    *,
    derived_id: str | None = None,
    allow_legacy_root_postprocess: bool = False,
) -> dict[str, object]:
    """Validate and score a selected immutable correction derived from a source run."""

    run_root = Path(run_root)
    reference_path = Path(reference_path)
    terms_path = Path(terms_path)
    raw_path = run_root / "merged" / "segments.json"

    if derived_id is not None:
        _validate_source_root(run_root)
    prevalidated_manifest = _require_mapping(
        _load_json(run_root / "manifest.json", label="source manifest"),
        label="source manifest",
    )
    if derived_id is not None:
        _validate_source_tree_seal(run_root, prevalidated_manifest)
    manifest, artifact_paths = validate_completed_run_manifest(run_root)
    if manifest.get("run_id") != run_root.name:
        raise ValueError("source run ID differs from its directory name")
    if "merged/segments.json" not in artifact_paths:
        raise ValueError("source merged transcript is unlisted in manifest")
    source_manifest_sha256 = _file_sha256(run_root / "manifest.json")
    source_segments_sha256 = _file_sha256(raw_path)
    derived_manifest: dict[str, Any] | None
    selected_derived_id: str | None
    if derived_id is not None and allow_legacy_root_postprocess:
        raise ValueError(
            "derived selection and legacy root postprocess mode are mutually exclusive"
        )
    if derived_id is not None:
        if manifest.get("postprocess") is not None:
            raise ValueError("D39 source run must not contain root postprocess metadata")
        legacy_postprocess = run_root / "postprocess"
        if legacy_postprocess.exists() or legacy_postprocess.is_symlink():
            raise ValueError("D39 source run must not contain root postprocess output")
        _validate_completed_source_coverage(manifest)
        _validate_canonical_source_artifacts(manifest, artifact_paths)
        selected_derived_id = _validate_selected_derived_id(derived_id)
        derived_root, derived_manifest, _ = _validate_derived_manifest(
            run_root,
            manifest,
            source_manifest_sha256,
            source_segments_sha256,
            selected_derived_id,
        )
        corrected_path = derived_root / "postprocess" / "segments.json"
        conflicts_path = derived_root / "postprocess" / "conflicts.json"
    else:
        if not allow_legacy_root_postprocess:
            raise ValueError(
                "selected derived ID is required; legacy root postprocess reads "
                "require allow_legacy_root_postprocess=True"
            )
        selected_derived_id = None
        derived_manifest = None
        manifest = _validate_manifest(manifest)
        for relative in (
            "postprocess/segments.json",
            "postprocess/conflicts.json",
        ):
            if relative not in artifact_paths:
                raise ValueError(f"scored artifact is unlisted in manifest: {relative}")
        corrected_path = run_root / "postprocess" / "segments.json"
        conflicts_path = run_root / "postprocess" / "conflicts.json"
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
    raw_source = raw.get("source")
    expected_source = {
        "file_name": manifest.get("input", {}).get("file_name"),
        "sha256": manifest.get("input", {}).get("sha256"),
        "duration_s": raw_source.get("duration_s") if isinstance(raw_source, dict) else None,
    }
    if not isinstance(raw_source, dict) or (
        raw_source.get("file_name"),
        raw_source.get("sha256"),
    ) != (expected_source["file_name"], expected_source["sha256"]):
        raise ValueError("merged transcript source identity differs from its manifest")
    input_duration = manifest.get("coverage", {}).get("input_duration_s")
    if (
        not isinstance(input_duration, (int, float))
        or isinstance(input_duration, bool)
        or abs(float(raw_source["duration_s"]) - float(input_duration)) > 0.01
    ):
        raise ValueError("merged transcript source duration differs from its manifest")
    reference = _validate_reference_document(reference)
    if reference.get("source") != raw.get("source"):
        raise ValueError("reference source identity differs from the verified source run")
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
            "source_manifest_sha256": source_manifest_sha256,
            "merged_segments_sha256": _file_sha256(raw_path),
            "derived_id": selected_derived_id,
            "derived_manifest_sha256": (
                _file_sha256(run_root / "derived" / selected_derived_id / "manifest.json")
                if selected_derived_id is not None
                else None
            ),
            "operation": (
                derived_manifest.get("operation")
                if derived_manifest is not None
                else None
            ),
            "postprocess_identity": (
                derived_manifest.get("postprocess")
                if derived_manifest is not None
                else manifest.get("postprocess")
            ),
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
    parser.add_argument("--derived-id")
    parser.add_argument(
        "--allow-legacy-root-postprocess",
        action="store_true",
        help="read a pre-D39 root-level postprocess artifact explicitly",
    )
    parser.add_argument("--reference", required=True, type=Path)
    parser.add_argument("--terms", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parse_arguments(argv)
    immutable_inputs = [arguments.run_root]
    if arguments.derived_id is not None:
        immutable_inputs.append(
            arguments.run_root / "derived" / arguments.derived_id
        )
    _reject_output_within_inputs(arguments.output, immutable_inputs)
    result = score_corrected_run(
        arguments.run_root,
        arguments.reference,
        arguments.terms,
        derived_id=arguments.derived_id,
        allow_legacy_root_postprocess=arguments.allow_legacy_root_postprocess,
    )
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    with arguments.output.open("x", encoding="utf-8") as output:
        json.dump(result, output, ensure_ascii=False, indent=2, sort_keys=True)
        output.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
