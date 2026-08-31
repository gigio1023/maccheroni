"""Zero-cost overlap and backend-speaker evidence for the DiCoW lane.

The module deliberately uses only the Python standard library.  Public inputs are
read without mutation and remain hash-bound in ``evidence.json``.  Optional private
review rows are reduced to the frozen aggregate before anything is written.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import math
import os
import re
import stat
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


SCHEMA_VERSION = "dicow-zero-cost-v1"
PRIVATE_SCHEMA_VERSION = "dicow-private-correction-review-v1"
EXPECTED_VOXCONVERSE_CONFLICTS = 45
CORRECTION_BURDEN_STOP_BELOW_RATIO = 0.05
CANONICAL_CONFLICT_SEGMENT_INDICES = (
    43, 46, 59, 60, 61, 108, 111, 123, 124, 125, 171, 174, 187, 188, 189,
    236, 239, 251, 252, 253, 298, 301, 314, 315, 316, 360, 363, 376, 377,
    378, 425, 428, 442, 443, 444, 490, 493, 506, 507, 508, 554, 557, 570,
    571, 572,
)
ALLOWED_CAUSES = (
    "missed_target_in_overlap",
    "other_speaker_intrusion",
    "duplicate_overlap",
)
BACKEND_DISCLAIMER = (
    "VibeVoice speaker labels are backend evidence only and are not transcript truth."
)
_SHA256 = re.compile(r"^[0-9a-f]{64}$")

ZERO_COST_INPUT_ROOT_ENV = "MACCHERONI_ZERO_COST_INPUT_ROOT"
_CANONICAL_REPO_FILES = {
    "ami_rttm": (
        "benchmarks/samples/public/acceptance-pack-v1/prepared/ami-in1009-ihm-mix-v1/reference.rttm",
        "516e4185f5dd852aa0dbdba11ed7d5f33406c9e4a4c8c63dc40e92f8f523eb25",
    ),
}
_CANONICAL_EXTERNAL_FILES = {
    "vox_rttm": (
        "voxconverse-ppgjx-78m/reference.rttm",
        "9cc1034614cd26e98beafd8e84b996f9ee9b66628e7131af4e06d8aeb8f7567e",
    ),
    "vox_timeline": (
        "voxconverse-ppgjx-78m/diarization/timeline.json",
        "24d646052672e3cda77df590d65e51a84f3119f925f7e5c24a84ca988996db4b",
    ),
    "conflicts": (
        "voxconverse-ppgjx-78m/merged/conflicts.json",
        "c55172def7638bd0228b7858c9e2b71108f44c1a27fdddbe65b83e23e886e7b1",
    ),
    "merged_segments": (
        "voxconverse-ppgjx-78m/merged/segments.json",
        "133b8b06f4e50c3f379bd50eab4042477b7c3bbffe906cd3e1bded6fb3c39a11",
    ),
    "manifest": (
        "voxconverse-ppgjx-78m/manifest.json",
        "bdb402948b4f59ca9191ab5cea4801ddc63e500d43fdc5ad24178586e1875485",
    ),
}
_CANONICAL_BACKEND_RECORDS = (
    ("voxconverse-ppgjx-78m/backend-records/asr-3be3d203-d621-4598-a235-76e3948d2436.json", "b1bb076dd16ee5a00c2793583d81094c5fd8a8b70d5857c1d4114a34d9103bdd"),
    ("voxconverse-ppgjx-78m/backend-records/asr-3f600773-3633-491d-9c84-26251f1a7ac5.json", "6e04f9e2e49007a612631c9bfe1cea259a36362e0135f3cba36aac0f612ff272"),
    ("voxconverse-ppgjx-78m/backend-records/asr-427843dc-c738-411a-99f7-78b82698f81c.json", "0aeb99df4d8dd3ee351a64e2b379b257dd19309a0e9f160fd36836c6a24b25ce"),
    ("voxconverse-ppgjx-78m/backend-records/asr-46aff3a0-6bac-4eb8-80e7-04496ff7cb76.json", "2d5aad74e5c1ab34883fed36c0b9cecaa34ed808a24ded5db681059c9751a9a7"),
    ("voxconverse-ppgjx-78m/backend-records/asr-c9caf5c9-02dc-49bc-91f1-3fc531a63fd1.json", "f32eac943725e7b6caaf24715f8b2463ad514a74b006a31978fc7af3ae74556e"),
)


@dataclass(frozen=True)
class PublicInputs:
    """Fully named public inputs; production obtains this only from frozen pins."""

    overlap_sources: tuple[tuple[str, Path], ...]
    conflicts: Path
    merged_segments: Path
    manifest: Path
    backend_records: tuple[Path, ...]
    conflict_segment_indices: tuple[int, ...]


class VerificationError(RuntimeError):
    """Raised when a zero-cost input or artifact fails closed."""


def _fail(message: str) -> None:
    raise VerificationError(message)


def _json_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            _fail("duplicate JSON key: {}".format(key))
        result[key] = value
    return result


def _absolute_without_symlinks(path: Path, field: str) -> Path:
    """Return a lexical absolute path after rejecting every existing symlink component."""
    absolute = path.absolute()
    current = Path(absolute.anchor)
    for component in absolute.parts[1:]:
        current = current / component
        try:
            info = current.lstat()
        except FileNotFoundError:
            continue
        except OSError as exc:
            _fail("cannot inspect {} path component {}: {}".format(field, current, exc))
        if stat.S_ISLNK(info.st_mode):
            _fail("{} may not contain a symlink component: {}".format(field, current))
    return absolute


def _read_regular_bytes(path: Path) -> bytes:
    path = _absolute_without_symlinks(path, "input")
    try:
        info = path.lstat()
    except OSError as exc:
        _fail("cannot inspect input {}: {}".format(path, exc))
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        _fail("input must be a regular non-symlink file: {}".format(path))
    try:
        return path.read_bytes()
    except OSError as exc:
        _fail("cannot read input {}: {}".format(path, exc))


def _load_json(path: Path) -> Any:
    raw = _read_regular_bytes(path)
    try:
        return json.loads(raw.decode("utf-8"), object_pairs_hook=_json_object)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        _fail("cannot parse JSON {}: {}".format(path, exc))


def _fingerprint(path: Path) -> dict[str, Any]:
    resolved = _absolute_without_symlinks(path, "input")
    raw = _read_regular_bytes(resolved)
    info = resolved.stat()
    return {
        "path": str(resolved),
        "sha256": hashlib.sha256(raw).hexdigest(),
        "bytes": len(raw),
        "mode": "0{:03o}".format(stat.S_IMODE(info.st_mode)),
    }


def _repo_root() -> Path:
    root = _absolute_without_symlinks(Path(__file__).parents[4], "repository root")
    if not (root / "PROJECT.md").is_file():
        _fail("cannot derive repository root from zero_cost.py")
    return root


def _canonical_inputs() -> PublicInputs:
    repo_root = _repo_root()
    external_value = os.environ.get(ZERO_COST_INPUT_ROOT_ENV)
    if not external_value:
        _fail("{} must name the sealed external public-input tree".format(ZERO_COST_INPUT_ROOT_ENV))
    external_root = _absolute_without_symlinks(
        Path(external_value), "canonical public input root"
    )
    if not external_root.is_dir():
        _fail("canonical public input root is unavailable")

    def checked(base: Path, table: Mapping[str, tuple[str, str]], role: str) -> Path:
        relative, expected_sha = table[role]
        candidate = _absolute_without_symlinks(base / relative, "canonical public input")
        try:
            candidate.relative_to(base)
        except ValueError:
            _fail("canonical public input escapes repository root: {}".format(relative))
        observed = _fingerprint(candidate)
        if observed["sha256"] != expected_sha or observed["path"] != str(candidate):
            _fail("canonical public input pin mismatch: {}".format(relative))
        return candidate

    backend_records: list[Path] = []
    for relative, expected_sha in _CANONICAL_BACKEND_RECORDS:
        candidate = _absolute_without_symlinks(external_root / relative, "canonical backend record")
        try:
            candidate.relative_to(external_root)
        except ValueError:
            _fail("canonical backend record escapes repository root: {}".format(relative))
        observed = _fingerprint(candidate)
        if observed["sha256"] != expected_sha or observed["path"] != str(candidate):
            _fail("canonical backend record pin mismatch: {}".format(relative))
        backend_records.append(candidate)
    return PublicInputs(
        overlap_sources=(
            ("ami-rttm", checked(repo_root, _CANONICAL_REPO_FILES, "ami_rttm")),
            ("voxconverse-rttm", checked(external_root, _CANONICAL_EXTERNAL_FILES, "vox_rttm")),
            ("voxconverse-timeline", checked(external_root, _CANONICAL_EXTERNAL_FILES, "vox_timeline")),
        ),
        conflicts=checked(external_root, _CANONICAL_EXTERNAL_FILES, "conflicts"),
        merged_segments=checked(external_root, _CANONICAL_EXTERNAL_FILES, "merged_segments"),
        manifest=checked(external_root, _CANONICAL_EXTERNAL_FILES, "manifest"),
        backend_records=tuple(backend_records),
        conflict_segment_indices=CANONICAL_CONFLICT_SEGMENT_INDICES,
    )


def _verify_unchanged(before: Mapping[str, Any]) -> None:
    after = _fingerprint(Path(_string(before.get("path"), "source.path")))
    if dict(before) != after:
        _fail("named input changed while it was being analyzed: {}".format(before["path"]))


def _mapping(value: Any, field: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        _fail("{} must be an object".format(field))
    return value


def _array(value: Any, field: str) -> list[Any]:
    if not isinstance(value, list):
        _fail("{} must be an array".format(field))
    return value


def _string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value:
        _fail("{} must be a non-empty string".format(field))
    return value


def _number(value: Any, field: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        _fail("{} must be a finite number".format(field))
    result = float(value)
    if not math.isfinite(result):
        _fail("{} must be a finite number".format(field))
    return result


def _integer(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        _fail("{} must be an integer".format(field))
    return value


def _interval(start: Any, end: Any, field: str) -> tuple[float, float]:
    left = _number(start, field + ".start")
    right = _number(end, field + ".end")
    if left < 0 or right <= left:
        _fail("{} must have 0 <= start < end".format(field))
    return left, right


def _parse_rttm(path: Path) -> list[tuple[float, float, str]]:
    raw = _read_regular_bytes(path)
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeDecodeError as exc:
        _fail("RTTM is not UTF-8 {}: {}".format(path, exc))
    intervals: list[tuple[float, float, str]] = []
    for line_number, line in enumerate(lines, 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split()
        if len(fields) != 10 or fields[0] != "SPEAKER":
            _fail("invalid RTTM row at {}:{}".format(path, line_number))
        start = _number_text(fields[3], "RTTM start at line {}".format(line_number))
        duration = _number_text(fields[4], "RTTM duration at line {}".format(line_number))
        if start < 0 or duration <= 0:
            _fail("RTTM row must have non-negative start and positive duration at line {}".format(line_number))
        speaker = fields[7]
        if not speaker or speaker == "<NA>":
            _fail("RTTM row has no speaker at line {}".format(line_number))
        intervals.append((start, start + duration, speaker))
    if not intervals:
        _fail("RTTM contains no speaker intervals: {}".format(path))
    return intervals


def _number_text(value: str, field: str) -> float:
    try:
        result = float(value)
    except ValueError:
        _fail("{} must be numeric".format(field))
    if not math.isfinite(result):
        _fail("{} must be finite".format(field))
    return result


def _parse_timeline(path: Path) -> list[tuple[float, float, str]]:
    value = _load_json(path)
    if isinstance(value, dict):
        rows = _array(value.get("segments"), "timeline.segments")
    else:
        rows = _array(value, "timeline")
    intervals: list[tuple[float, float, str]] = []
    for index, raw_row in enumerate(rows):
        row = _mapping(raw_row, "timeline[{}]".format(index))
        start_key = "start_s" if "start_s" in row else "start"
        end_key = "end_s" if "end_s" in row else "end"
        speaker_key = "speaker" if "speaker" in row else "speaker_id"
        if start_key not in row or end_key not in row or speaker_key not in row:
            _fail("timeline[{}] lacks start, end, or speaker".format(index))
        start, end = _interval(row[start_key], row[end_key], "timeline[{}]".format(index))
        speaker_value = row[speaker_key]
        if isinstance(speaker_value, bool) or not isinstance(speaker_value, (str, int)):
            _fail("timeline[{}].speaker must be a string or integer".format(index))
        speaker = str(speaker_value)
        if not speaker:
            _fail("timeline[{}].speaker must not be empty".format(index))
        intervals.append((start, end, speaker))
    if not intervals:
        _fail("timeline contains no speaker intervals: {}".format(path))
    return intervals


def overlap_measure(intervals: Iterable[tuple[float, float, str]]) -> dict[str, Any]:
    """Measure unique-speaker overlap over active speech time."""
    events: dict[float, list[tuple[str, int]]] = collections.defaultdict(list)
    minimum: float | None = None
    maximum: float | None = None
    interval_count = 0
    for start, end, speaker in intervals:
        if start < 0 or end <= start or not speaker:
            _fail("invalid interval passed to overlap_measure")
        events[start].append((speaker, 1))
        events[end].append((speaker, -1))
        minimum = start if minimum is None else min(minimum, start)
        maximum = end if maximum is None else max(maximum, end)
        interval_count += 1
    if interval_count == 0 or minimum is None or maximum is None:
        _fail("overlap measurement needs at least one interval")
    active: collections.Counter[str] = collections.Counter()
    previous: float | None = None
    speech_seconds = 0.0
    overlap_seconds = 0.0
    for current in sorted(events):
        if previous is not None:
            duration = current - previous
            active_speakers = sum(count > 0 for count in active.values())
            if active_speakers >= 1:
                speech_seconds += duration
            if active_speakers >= 2:
                overlap_seconds += duration
        for speaker, delta in events[current]:
            active[speaker] += delta
            if active[speaker] < 0:
                _fail("speaker interval sweep became negative")
            if active[speaker] == 0:
                del active[speaker]
        previous = current
    if speech_seconds <= 0:
        _fail("speaker intervals have no active duration")
    return {
        "interval_count": interval_count,
        "span_seconds": _rounded(maximum - minimum),
        "speech_union_seconds": _rounded(speech_seconds),
        "overlap_seconds": _rounded(overlap_seconds),
        "overlap_share_of_speech": overlap_seconds / speech_seconds,
        "denominator": "speaker_active_union_seconds",
    }


def _rounded(value: float) -> float:
    return round(value, 9)


def _measure_source(source_id: str, path: Path) -> dict[str, Any]:
    kind = "rttm" if path.suffix.lower() == ".rttm" else "timeline"
    intervals = _parse_rttm(path) if kind == "rttm" else _parse_timeline(path)
    return {
        "source_id": source_id,
        "kind": kind,
        "source": _fingerprint(path),
        "measure": overlap_measure(intervals),
    }


def _segments_document(path: Path, field: str) -> list[Mapping[str, Any]]:
    value = _load_json(path)
    document = _mapping(value, field)
    return [_mapping(row, "{}.segments[]".format(field)) for row in _array(document.get("segments"), field + ".segments")]


def _backend_probe(
    conflicts_path: Path,
    merged_segments_path: Path,
    manifest_path: Path,
    backend_record_paths: Sequence[Path],
    expected_conflict_segment_indices: Sequence[int],
) -> dict[str, Any]:
    conflicts_value = _load_json(conflicts_path)
    conflicts = [_mapping(row, "conflicts[]") for row in _array(conflicts_value, "conflicts")]
    merged_segments = _segments_document(merged_segments_path, "merged_segments")
    manifest = _mapping(_load_json(manifest_path), "manifest")
    models = [_mapping(row, "manifest.models[]") for row in _array(manifest.get("models"), "manifest.models")]
    asr_models = [row for row in models if row.get("role") == "asr"]
    if len(asr_models) != 1:
        _fail("manifest must contain exactly one ASR model")

    normalized_record_paths = [
        _absolute_without_symlinks(path, "VibeVoice backend record")
        for path in backend_record_paths
    ]
    if len(normalized_record_paths) != len(set(normalized_record_paths)):
        _fail("VibeVoice backend record paths must be unique")
    initial_record_fingerprints = [_fingerprint(path) for path in normalized_record_paths]
    record_hashes = [row["sha256"] for row in initial_record_fingerprints]
    if len(record_hashes) != len(set(record_hashes)):
        _fail("VibeVoice backend record fingerprints must be unique")

    backend_segments: list[tuple[float, float, str, int]] = []
    record_fingerprints: list[dict[str, Any]] = []
    segment_identities: set[tuple[float, float, str]] = set()
    excluded_empty_speaker_segments = 0
    for record_index, path in enumerate(normalized_record_paths):
        record = _mapping(_load_json(path), "backend_record")
        if record.get("backend") != "vibevoice":
            _fail("backend record is not VibeVoice: {}".format(path))
        if record.get("model") != asr_models[0]:
            _fail("backend record model does not match manifest ASR model: {}".format(path))
        rows = [_mapping(row, "backend_record.segments[]") for row in _array(record.get("segments"), "backend_record.segments")]
        for segment_index, row in enumerate(rows):
            start, end = _interval(row.get("start_s"), row.get("end_s"), "backend segment")
            speaker = row.get("speaker")
            if isinstance(speaker, bool) or not isinstance(speaker, (str, int)):
                _fail("backend segment speaker must be a string or integer")
            normalized_speaker = str(speaker).strip()
            identity = (start, end, normalized_speaker)
            if identity in segment_identities:
                _fail("duplicate VibeVoice backend-speaker segment identity")
            segment_identities.add(identity)
            if not normalized_speaker:
                excluded_empty_speaker_segments += 1
                continue
            backend_segments.append((start, end, normalized_speaker, record_index))
        record_fingerprints.append(_fingerprint(path))
    if not backend_segments:
        _fail("at least one VibeVoice backend-speaker segment is required")

    overlap_conflicts = [row for row in conflicts if row.get("kind") == "overlapping_speech"]
    conflict_identities = [
        json.dumps(row, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        for row in overlap_conflicts
    ]
    if len(conflict_identities) != len(set(conflict_identities)):
        _fail("overlap conflicts contain duplicate rows")
    conflict_indices = [
        _integer(row.get("segment_index"), "conflict.segment_index")
        for row in overlap_conflicts
    ]
    if len(conflict_indices) != len(set(conflict_indices)):
        _fail("overlap conflicts contain duplicate segment indices")
    expected_indices = tuple(expected_conflict_segment_indices)
    if len(expected_indices) != EXPECTED_VOXCONVERSE_CONFLICTS or len(expected_indices) != len(set(expected_indices)):
        _fail("expected overlap conflict identity contract is invalid")
    if tuple(conflict_indices) != expected_indices:
        _fail(
            "overlap conflicts do not match the exact canonical 45 segment identities"
        )
    at_least_two_segments = 0
    at_least_two_labels = 0
    for conflict in overlap_conflicts:
        segment_index = _integer(conflict.get("segment_index"), "conflict.segment_index")
        if segment_index < 0 or segment_index >= len(merged_segments):
            _fail("conflict segment_index is outside merged segments")
        merged = merged_segments[segment_index]
        start, end = _interval(merged.get("start_s"), merged.get("end_s"), "merged segment")
        intersections = [
            (speaker, record_index)
            for raw_start, raw_end, speaker, record_index in backend_segments
            if min(end, raw_end) > max(start, raw_start)
        ]
        if len(intersections) >= 2:
            at_least_two_segments += 1
        if len({speaker for speaker, _ in intersections}) >= 2:
            at_least_two_labels += 1

    return {
        "disclaimer": BACKEND_DISCLAIMER,
        "expected_overlap_conflict_count": EXPECTED_VOXCONVERSE_CONFLICTS,
        "observed_overlap_conflict_count": len(overlap_conflicts),
        "conflicts_intersecting_at_least_two_backend_speaker_segments": at_least_two_segments,
        "conflicts_intersecting_at_least_two_distinct_backend_labels": at_least_two_labels,
        "valid_backend_speaker_segment_count": len(backend_segments),
        "excluded_empty_speaker_segment_count": excluded_empty_speaker_segments,
        "intersection_rule": "strictly_positive_duration",
        "inputs": {
            "conflicts": _fingerprint(conflicts_path),
            "merged_segments": _fingerprint(merged_segments_path),
            "manifest": _fingerprint(manifest_path),
            "backend_records": record_fingerprints,
        },
    }


def _private_aggregate(path: Path | None) -> dict[str, Any]:
    base: dict[str, Any] = {
        "availability": {"status": "unavailable", "reason": "private_review_not_provided"},
        "unit": "seconds",
        "allowed_causes": list(ALLOWED_CAUSES),
        "overlap_caused_seconds": None,
        "total_seconds": None,
        "ratio": None,
        "percentage": None,
        "uncertain_seconds": None,
        "meeting_sha256": None,
    }
    if path is None:
        return base
    document = _mapping(_load_json(path), "private_review")
    if set(document) != {"schema_version", "meeting_sha256", "unit", "annotations"}:
        _fail("private review has unexpected or missing fields")
    if document.get("schema_version") != PRIVATE_SCHEMA_VERSION or document.get("unit") != "seconds":
        _fail("private review schema_version or unit is invalid")
    meeting_sha256 = _string(document.get("meeting_sha256"), "private_review.meeting_sha256")
    if _SHA256.fullmatch(meeting_sha256) is None:
        _fail("private_review.meeting_sha256 must be a lowercase SHA-256")
    annotations = [_mapping(row, "private_review.annotations[]") for row in _array(document.get("annotations"), "private_review.annotations")]
    if not annotations:
        _fail("private review must contain at least one correction or relistening second")
    seen_seconds: set[int] = set()
    overlap_caused = 0
    uncertain_seconds = 0
    for row in annotations:
        if set(row) != {"second", "intersects_diarizer_overlap", "causes", "uncertain"}:
            _fail("private annotation has unexpected or missing fields")
        second = _integer(row.get("second"), "private annotation second")
        if second < 0 or second in seen_seconds:
            _fail("private annotation seconds must be unique non-negative integers")
        seen_seconds.add(second)
        intersects = row.get("intersects_diarizer_overlap")
        uncertain = row.get("uncertain")
        if not isinstance(intersects, bool) or not isinstance(uncertain, bool):
            _fail("private annotation overlap and uncertain fields must be booleans")
        causes = _array(row.get("causes"), "private annotation causes")
        if any(not isinstance(cause, str) or cause not in ALLOWED_CAUSES for cause in causes):
            _fail("private annotation contains a cause outside the frozen set")
        if len(causes) != len(set(causes)):
            _fail("private annotation causes must be unique")
        if causes and not intersects:
            _fail("an overlap cause requires intersection with diarizer overlap")
        if not intersects and uncertain:
            _fail("uncertain overlap classification requires diarizer overlap")
        if intersects and len(causes) != 1 and not uncertain:
            _fail("zero-cause or multi-cause overlap seconds must be uncertain")
        if uncertain:
            uncertain_seconds += 1
        elif intersects and len(causes) == 1:
            overlap_caused += 1
    total = len(annotations)
    ratio = overlap_caused / total
    return {
        "availability": {"status": "available", "reason": None},
        "unit": "seconds",
        "allowed_causes": list(ALLOWED_CAUSES),
        "overlap_caused_seconds": overlap_caused,
        "total_seconds": total,
        "ratio": ratio,
        "percentage": 100.0 * ratio,
        "uncertain_seconds": uncertain_seconds,
        "meeting_sha256": meeting_sha256,
    }


def _verified_private_aggregate(path: Path | None) -> dict[str, Any]:
    if path is None:
        return _private_aggregate(None)
    try:
        canonical = _absolute_without_symlinks(path, "private review")
        before = _fingerprint(canonical)
        aggregate = _private_aggregate(canonical)
        _verify_unchanged(before)
        return aggregate
    except VerificationError:
        _fail("private review failed validation")
    raise AssertionError("unreachable")


def correction_burden_stops_lane(ratio: float) -> bool:
    """Apply the frozen PA-T11 stop rule to an available burden ratio."""
    numeric = _number(ratio, "correction burden ratio")
    if numeric < 0 or numeric > 1:
        _fail("correction burden ratio must be on [0, 1]")
    return numeric < CORRECTION_BURDEN_STOP_BELOW_RATIO


def _all_public_sources(evidence: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    sources = [_mapping(row.get("source"), "overlap source") for row in _array(evidence.get("overlap_sources"), "overlap_sources") for row in [_mapping(row, "overlap source")]]
    probe = _mapping(evidence.get("vibevoice_backend_probe"), "vibevoice_backend_probe")
    inputs = _mapping(probe.get("inputs"), "vibevoice_backend_probe.inputs")
    sources.extend(
        _mapping(inputs.get(name), "vibevoice_backend_probe.inputs.{}".format(name))
        for name in ("conflicts", "merged_segments", "manifest")
    )
    sources.extend(_mapping(row, "backend_records[]") for row in _array(inputs.get("backend_records"), "backend_records"))
    return sources


def build_evidence(
    private_review: Path | None = None,
    *,
    public_inputs: PublicInputs | None = None,
) -> dict[str, Any]:
    """Build evidence; ``public_inputs`` exists only for isolated synthetic tests."""
    inputs = public_inputs or _canonical_inputs()
    specs = list(inputs.overlap_sources)
    ids = [source_id for source_id, _ in specs]
    if not specs or len(ids) != len(set(ids)):
        _fail("at least one uniquely named overlap source is required")
    public_paths = [path for _, path in specs] + [
        inputs.conflicts,
        inputs.merged_segments,
        inputs.manifest,
    ] + list(inputs.backend_records)
    before = [_fingerprint(path) for path in public_paths]
    overlap_sources = [_measure_source(source_id, path) for source_id, path in specs]
    probe = _backend_probe(
        inputs.conflicts,
        inputs.merged_segments,
        inputs.manifest,
        inputs.backend_records,
        inputs.conflict_segment_indices,
    )
    evidence = {
        "schema_version": SCHEMA_VERSION,
        "overlap_sources": overlap_sources,
        "vibevoice_backend_probe": probe,
        "correction_burden": _verified_private_aggregate(private_review),
    }
    for source in before:
        _verify_unchanged(source)
    # The evidence must bind the same source tuples observed before analysis.
    if sorted(before, key=lambda row: (row["path"], row["sha256"])) != sorted(
        _all_public_sources(evidence), key=lambda row: (row["path"], row["sha256"])
    ):
        _fail("evidence source tuples do not match the named public inputs")
    return evidence


def _write_evidence(run: Path, evidence: Mapping[str, Any]) -> Path:
    run = _absolute_without_symlinks(run, "run directory")
    if run.exists():
        if not run.is_dir() or any(run.iterdir()):
            _fail("run directory must be absent or empty")
    else:
        run.mkdir(parents=True, mode=0o755)
    output = _absolute_without_symlinks(run / "evidence.json", "evidence output")
    raw = (json.dumps(evidence, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")
    try:
        descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o444)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(raw)
            handle.flush()
            os.fsync(handle.fileno())
    except OSError as exc:
        _fail("cannot create evidence artifact {}: {}".format(output, exc))
    output.chmod(0o444)
    return output


def verify_run(
    run: Path,
    private_review: Path | None = None,
    *,
    public_inputs: PublicInputs | None = None,
) -> dict[str, Any]:
    """Verify a run against canonical inputs and replay private evidence when present."""
    run = _absolute_without_symlinks(run, "run directory")
    if not run.is_dir():
        _fail("run must be a regular directory")
    output = _absolute_without_symlinks(run / "evidence.json", "evidence output")
    if {path.name for path in run.iterdir()} != {"evidence.json"}:
        _fail("zero-cost run must contain only aggregate evidence.json")
    if output.is_symlink() or not output.is_file():
        _fail("evidence.json is missing, not regular, or a symlink")
    if stat.S_IMODE(output.stat().st_mode) & 0o222:
        _fail("evidence.json must be read-only")
    evidence = _mapping(_load_json(output), "evidence")
    if set(evidence) != {"schema_version", "overlap_sources", "vibevoice_backend_probe", "correction_burden"}:
        _fail("evidence has unexpected or missing fields")
    if evidence.get("schema_version") != SCHEMA_VERSION:
        _fail("unsupported zero-cost evidence schema")

    inputs = public_inputs or _canonical_inputs()
    expected_overlap = [
        _measure_source(source_id, path) for source_id, path in inputs.overlap_sources
    ]
    if evidence.get("overlap_sources") != expected_overlap:
        _fail("overlap evidence is not bound to the canonical public inputs")
    expected_probe = _backend_probe(
        inputs.conflicts,
        inputs.merged_segments,
        inputs.manifest,
        inputs.backend_records,
        inputs.conflict_segment_indices,
    )
    if evidence.get("vibevoice_backend_probe") != expected_probe:
        _fail("VibeVoice backend-speaker probe does not replay")
    burden = _mapping(evidence.get("correction_burden"), "correction_burden")
    _verify_correction_burden(burden)
    availability = _mapping(burden.get("availability"), "correction_burden.availability")
    if availability.get("status") == "available":
        if private_review is None:
            _fail("available correction burden requires --private-review for replay")
        if _verified_private_aggregate(private_review) != burden:
            _fail("private correction burden does not replay from the supplied review")
    elif private_review is not None:
        _verified_private_aggregate(private_review)
        _fail("unavailable correction burden may not be verified with a private review")
    return dict(evidence)


def _verify_fingerprint(source: Mapping[str, Any]) -> None:
    if set(source) != {"path", "sha256", "bytes", "mode"}:
        _fail("source fingerprint has unexpected or missing fields")
    path = Path(_string(source.get("path"), "source.path"))
    sha256 = _string(source.get("sha256"), "source.sha256")
    if _SHA256.fullmatch(sha256) is None:
        _fail("source.sha256 must be a lowercase SHA-256")
    if _fingerprint(path) != dict(source):
        _fail("source fingerprint mismatch: {}".format(path))


def _verify_correction_burden(value: Mapping[str, Any]) -> None:
    expected_keys = {
        "availability", "unit", "allowed_causes", "overlap_caused_seconds",
        "total_seconds", "ratio", "percentage", "uncertain_seconds", "meeting_sha256",
    }
    if set(value) != expected_keys or value.get("unit") != "seconds" or value.get("allowed_causes") != list(ALLOWED_CAUSES):
        _fail("correction burden shape or frozen causes are invalid")
    availability = _mapping(value.get("availability"), "correction_burden.availability")
    if set(availability) != {"status", "reason"}:
        _fail("correction burden availability is invalid")
    if availability.get("status") == "unavailable":
        if availability.get("reason") != "private_review_not_provided":
            _fail("unavailable correction burden needs the typed reason")
        for field in ("overlap_caused_seconds", "total_seconds", "ratio", "percentage", "uncertain_seconds", "meeting_sha256"):
            if value.get(field) is not None:
                _fail("unavailable correction burden must use null aggregates")
        return
    if availability != {"status": "available", "reason": None}:
        _fail("correction burden availability status is invalid")
    overlap = _integer(value.get("overlap_caused_seconds"), "overlap_caused_seconds")
    total = _integer(value.get("total_seconds"), "total_seconds")
    uncertain = _integer(value.get("uncertain_seconds"), "uncertain_seconds")
    ratio = _number(value.get("ratio"), "ratio")
    percentage = _number(value.get("percentage"), "percentage")
    meeting_sha256 = _string(value.get("meeting_sha256"), "meeting_sha256")
    if total <= 0 or overlap < 0 or uncertain < 0 or overlap + uncertain > total:
        _fail("correction burden aggregate counts are inconsistent")
    if _SHA256.fullmatch(meeting_sha256) is None:
        _fail("meeting_sha256 must be a lowercase SHA-256")
    expected_ratio = overlap / total
    if ratio != expected_ratio or percentage != 100.0 * expected_ratio:
        _fail("correction burden ratio or percentage does not match its counts")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    analyze = subparsers.add_parser("analyze", help="create immutable zero-cost evidence")
    analyze.add_argument("--run", required=True, type=Path)
    analyze.add_argument("--private-review", type=Path)
    verify = subparsers.add_parser("verify", help="replay and verify a zero-cost run")
    verify.add_argument("--run", required=True, type=Path)
    verify.add_argument("--private-review", type=Path)
    return parser


def _production_run_path(requested: Path) -> Path:
    raw_cache = os.environ.get("DICOW_CACHE_ROOT")
    raw_root = os.environ.get("DICOW_RUN_ROOT")
    if not raw_cache or not Path(raw_cache).is_absolute():
        _fail("DICOW_CACHE_ROOT must be an absolute path for the production CLI")
    if not raw_root or not Path(raw_root).is_absolute():
        _fail("DICOW_RUN_ROOT must be an absolute path for the production CLI")
    cache_root = _absolute_without_symlinks(Path(raw_cache), "DICOW_CACHE_ROOT")
    run_root = _absolute_without_symlinks(Path(raw_root), "DICOW_RUN_ROOT")
    runs_root = _absolute_without_symlinks(cache_root / "runs", "benchmark runs root")
    try:
        run_relative = run_root.relative_to(runs_root)
    except ValueError:
        _fail("DICOW_RUN_ROOT must be below $DICOW_CACHE_ROOT/runs")
    if not run_relative.parts:
        _fail("DICOW_RUN_ROOT must name one run below $DICOW_CACHE_ROOT/runs")
    repo_root = _repo_root()
    try:
        run_root.relative_to(repo_root)
    except ValueError:
        pass
    else:
        _fail("DICOW_RUN_ROOT must stay outside the checkout")
    expected = _absolute_without_symlinks(run_root / "e3-zero-cost", "canonical E3 run")
    candidate = _absolute_without_symlinks(requested, "requested E3 run")
    if candidate != expected:
        _fail("production zero-cost run must be exactly $DICOW_RUN_ROOT/e3-zero-cost")
    return candidate


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "analyze":
            output = _write_evidence(
                _production_run_path(args.run), build_evidence(args.private_review)
            )
            print(json.dumps({"status": "ok", "evidence": str(output)}, sort_keys=True))
        else:
            evidence = verify_run(_production_run_path(args.run), args.private_review)
            burden = _mapping(evidence["correction_burden"], "correction_burden")
            print(json.dumps({
                "status": "ok",
                "schema_version": SCHEMA_VERSION,
                "correction_burden_status": _mapping(burden["availability"], "availability")["status"],
            }, sort_keys=True))
    except VerificationError as exc:
        print("zero-cost verification failed: {}".format(exc), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
