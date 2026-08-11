#!/usr/bin/env python3
"""Validate one completed benchmark or application run against the v1 contracts."""

from __future__ import annotations

import argparse
from datetime import datetime
import hashlib
import json
import math
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker, ValidationError

from check_contracts import _validate_manifest_semantics, _validate_segments_semantics
from rttm import read_rttm


SCRIPT_DIR = Path(__file__).resolve().parent
REPOSITORY_ROOT = SCRIPT_DIR.parents[2]
REQUIRED_SUCCESS_ARTIFACTS = (
    "primary/raw.txt",
    "primary/segments.json",
    "diarization/timeline.json",
    "merged/segments.json",
    "merged/conflicts.json",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-root", required=True, type=Path)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--kind", required=True, choices=("asr", "diarization", "full"))
    return parser.parse_args()


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as stream:
        return json.load(stream)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def parse_datetime(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def validate_timing(manifest: dict[str, Any]) -> None:
    timing = manifest["timing"]
    started = parse_datetime(timing["started_at"])
    finished = parse_datetime(timing["finished_at"])
    elapsed = (finished - started).total_seconds()
    if elapsed < 0:
        raise ValueError("manifest timing finishes before it starts")
    tolerance = max(1.0, elapsed * 0.05)
    if abs(elapsed - float(timing["wall_time_s"])) > tolerance:
        raise ValueError("manifest wall_time_s does not match its timestamps")


def validate_chunks(manifest: dict[str, Any]) -> None:
    duration = float(manifest["coverage"]["input_duration_s"])
    boundaries = manifest["chunk_boundaries"]
    if len(boundaries) != manifest["coverage"]["chunks_planned"]:
        raise ValueError("chunk_boundaries count does not match chunks_planned")
    previous = (-1.0, -1.0)
    for index, chunk in enumerate(boundaries):
        key = (float(chunk["start_s"]), float(chunk["end_s"]))
        if key < previous:
            raise ValueError(f"chunk {index}: boundaries are not time-sorted")
        if key[0] < 0 or key[1] > duration + 0.01:
            raise ValueError(f"chunk {index}: boundary lies outside the input")
        previous = key


def validate_segments(
    path: Path,
    *,
    schema_validator: Draft202012Validator,
    input_path: Path,
    duration: float,
) -> dict[str, Any]:
    document = load_json(path)
    validate_segments_document(
        document,
        label=str(path),
        schema_validator=schema_validator,
    )
    source = document["source"]
    if source["file_name"] != input_path.name:
        raise ValueError(f"{path}: source file name does not match input")
    if source["sha256"] != sha256_file(input_path):
        raise ValueError(f"{path}: source hash does not match input")
    if abs(float(source["duration_s"]) - duration) > 0.01:
        raise ValueError(f"{path}: source duration does not match manifest")
    return document


def validate_segments_document(
    document: object,
    *,
    label: str,
    schema_validator: Draft202012Validator | None = None,
    validate_semantics: bool = True,
) -> dict[str, Any]:
    """Validate one in-memory segment document with the canonical contract."""

    validator = schema_validator
    if validator is None:
        schema = load_json(REPOSITORY_ROOT / "docs/contracts/segments.schema.json")
        Draft202012Validator.check_schema(schema)
        validator = Draft202012Validator(schema, format_checker=FormatChecker())
    try:
        validator.validate(document)
    except ValidationError as error:
        location = ".".join(str(component) for component in error.absolute_path)
        suffix = f" at {location}" if location else ""
        raise ValueError(
            f"{label} failed segments schema{suffix}: {error.message}"
        ) from error
    if validate_semantics:
        try:
            _validate_segments_semantics(document)
        except ValueError as error:
            raise ValueError(f"{label} failed segments semantics: {error}") from error
    return document


def validate_timeline(path: Path, *, duration: float) -> list[dict[str, Any]]:
    timeline = load_json(path)
    if not isinstance(timeline, list):
        raise ValueError(f"{path}: timeline must be an array")
    previous = (-1.0, -1.0)
    for index, entry in enumerate(timeline):
        if not isinstance(entry, dict):
            raise ValueError(f"{path}: timeline entry {index} must be an object")
        if not {"speaker", "start_s", "end_s"}.issubset(entry):
            raise ValueError(f"{path}: timeline entry {index} is incomplete")
        if not isinstance(entry["speaker"], str) or not entry["speaker"]:
            raise ValueError(f"{path}: timeline entry {index} has no speaker")
        start, end = float(entry["start_s"]), float(entry["end_s"])
        if not all(math.isfinite(value) for value in (start, end)):
            raise ValueError(f"{path}: timeline entry {index} has non-finite time")
        if start < 0 or end <= start or end > duration + 0.01:
            raise ValueError(f"{path}: timeline entry {index} is outside the input")
        if (start, end) < previous:
            raise ValueError(f"{path}: timeline is not time-sorted")
        if "confidence" in entry and not 0 <= float(entry["confidence"]) <= 1:
            raise ValueError(f"{path}: timeline entry {index} confidence is invalid")
        previous = (start, end)
    return timeline


def validate_conflicts(path: Path) -> None:
    conflicts = load_json(path)
    if not isinstance(conflicts, list):
        raise ValueError(f"{path}: conflicts must be an array")


def validate_postprocess_identity(
    merged: dict[str, Any],
    corrected: dict[str, Any],
) -> None:
    if corrected["source"] != merged["source"]:
        raise ValueError("postprocess source metadata differs from merged transcript")
    if corrected["num_speakers"] != merged["num_speakers"]:
        raise ValueError("postprocess speaker count differs from merged transcript")
    if len(corrected["segments"]) != len(merged["segments"]):
        raise ValueError("postprocess segment count differs from merged transcript")
    immutable_keys = ("speaker", "start_s", "end_s", "language", "confidence")
    for index, (original, candidate) in enumerate(
        zip(merged["segments"], corrected["segments"], strict=True)
    ):
        for key in immutable_keys:
            if candidate.get(key) != original.get(key):
                raise ValueError(
                    f"postprocess segment {index} changed immutable field {key}"
                )


def validate_scores(path: Path, *, kind: str) -> None:
    scores = load_json(path)
    if not isinstance(scores, dict):
        raise ValueError(f"{path}: scores must be an object")
    for key in ("wer", "cer", "omissions"):
        if key not in scores or not isinstance(scores[key], dict):
            raise ValueError(f"{path}: missing {key} score")
    if kind == "diarization" and not isinstance(scores.get("diarization"), dict):
        raise ValueError(f"{path}: missing diarization score")


def validate_artifacts(run_root: Path, manifest: dict[str, Any]) -> set[str]:
    paths: set[str] = set()
    for artifact in manifest["artifacts"]:
        relative = artifact["path"]
        if relative in paths:
            raise ValueError(f"duplicate artifact path: {relative}")
        paths.add(relative)
        path = run_root / relative
        if not path.is_file():
            raise ValueError(f"missing artifact: {relative}")
        if sha256_file(path) != artifact["sha256"]:
            raise ValueError(f"artifact hash mismatch: {relative}")
    return paths


def validate_completed_run_manifest(
    run_root: Path,
) -> tuple[dict[str, Any], set[str]]:
    """Validate canonical completion semantics and every declared artifact seal."""

    run_root = run_root.resolve()
    manifest_path = run_root / "manifest.json"
    manifest = load_json(manifest_path)
    schema = load_json(REPOSITORY_ROOT / "docs/contracts/manifest.schema.json")
    Draft202012Validator.check_schema(schema)
    try:
        Draft202012Validator(schema, format_checker=FormatChecker()).validate(
            manifest
        )
    except ValidationError as error:
        location = ".".join(str(component) for component in error.absolute_path)
        suffix = f" at {location}" if location else ""
        raise ValueError(
            f"manifest schema violation{suffix}: {error.message}"
        ) from error
    _validate_manifest_semantics(manifest)
    validate_timing(manifest)
    validate_chunks(manifest)
    if manifest["status"] != "succeeded":
        raise ValueError(f"run is not succeeded: {manifest['status']}")
    return manifest, validate_artifacts(run_root, manifest)


def validate_run(run_root: Path, input_path: Path, kind: str) -> dict[str, Any]:
    run_root = run_root.resolve()
    input_path = input_path.resolve()
    manifest, artifact_paths = validate_completed_run_manifest(run_root)

    checker = FormatChecker()
    segments_schema = load_json(REPOSITORY_ROOT / "docs/contracts/segments.schema.json")
    Draft202012Validator.check_schema(segments_schema)

    if not input_path.is_file():
        raise ValueError(f"input is missing: {input_path}")
    if input_path.name != manifest["input"]["file_name"]:
        raise ValueError("manifest input basename does not match")
    if input_path.stat().st_size != manifest["input"]["size_bytes"]:
        raise ValueError("manifest input size does not match")
    input_hash = sha256_file(input_path)
    if input_hash != manifest["input"]["sha256"]:
        raise ValueError("manifest input hash does not match")
    if manifest["glossary"]["provided"] and not manifest["glossary"]["applied"]:
        raise ValueError("provided glossary was not applied")
    identities = {
        (model["role"], model["hf_model_id"], model["revision"], model["quantization"])
        for model in manifest["models"]
    }
    if len(identities) != len(manifest["models"]):
        raise ValueError("manifest contains a duplicate model identity")

    for relative in REQUIRED_SUCCESS_ARTIFACTS:
        if relative not in artifact_paths:
            raise ValueError(f"required successful artifact is unlisted: {relative}")
    if "scores.json" not in artifact_paths:
        raise ValueError("scores.json is not listed as an artifact")
    if not (run_root / "primary/raw.txt").read_text(encoding="utf-8").strip():
        raise ValueError("primary/raw.txt is empty")

    duration = float(manifest["coverage"]["input_duration_s"])
    segments_validator = Draft202012Validator(segments_schema, format_checker=checker)
    validate_segments(
        run_root / "primary/segments.json",
        schema_validator=segments_validator,
        input_path=input_path,
        duration=duration,
    )
    merged = validate_segments(
        run_root / "merged/segments.json",
        schema_validator=segments_validator,
        input_path=input_path,
        duration=duration,
    )
    validate_timeline(run_root / "diarization/timeline.json", duration=duration)
    validate_conflicts(run_root / "merged/conflicts.json")
    validate_scores(run_root / "scores.json", kind=kind)

    if kind == "diarization":
        relative = "diarization/hypothesis.rttm"
        if relative not in artifact_paths:
            raise ValueError("diarization run does not list hypothesis RTTM")
        turns = read_rttm(run_root / relative)
        if not turns:
            raise ValueError("diarization hypothesis RTTM is empty")
        if any(turn.end_s > duration + 0.01 for turn in turns):
            raise ValueError("diarization hypothesis RTTM exceeds input duration")

    postprocess_path = run_root / "postprocess/segments.json"
    postprocess_metadata = manifest.get("postprocess")
    if postprocess_path.exists() or postprocess_metadata is not None:
        for relative in ("postprocess/segments.json", "postprocess/conflicts.json"):
            if relative not in artifact_paths:
                raise ValueError(f"postprocess artifact is unlisted: {relative}")
        if postprocess_metadata is None:
            raise ValueError("postprocess artifacts exist without manifest metadata")
        corrected = validate_segments(
            postprocess_path,
            schema_validator=segments_validator,
            input_path=input_path,
            duration=duration,
        )
        validate_postprocess_identity(merged, corrected)
        validate_conflicts(run_root / "postprocess/conflicts.json")
        if postprocess_metadata["backend"]["name"] == "mlx-vlm":
            identity = (
                "postprocess",
                postprocess_metadata["model_id"],
                postprocess_metadata["model_revision"],
                postprocess_metadata["quantization"],
            )
            if identity not in identities:
                raise ValueError("local postprocess metadata has no matching HF model tuple")
    return manifest


def main() -> int:
    args = parse_args()
    manifest = validate_run(args.run_root, args.input, args.kind)
    models = ", ".join(
        f"{entry['hf_model_id']}@{entry['revision']}:{entry['quantization']}"
        for entry in manifest["models"]
    )
    print(f"PASS run {manifest['run_id']} ({args.kind}; {models})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
