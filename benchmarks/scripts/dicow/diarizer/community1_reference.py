"""Pinned Community-1 process wrapper and transcript-free activity mapping."""

from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import math
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Mapping, Sequence


FRAME_HZ = 50
FRAME_COUNT = 1_500
WINDOW_SECONDS = 30.0
PROCESS_TIMEOUT_SECONDS = 240.0
EXPECTED_MODEL_ID = "aufklarer/Pyannote-Community-1-CoreML"
EXPECTED_MODEL_REVISION = "a14e6c420d56e8472850649b016a486fd0acbe81"


class CommunityError(RuntimeError):
    """Community-1 evidence is missing, malformed, or not reproducible."""


@dataclass(frozen=True)
class Segment:
    label: str
    start_s: float
    end_s: float


@dataclass(frozen=True)
class ProcessEvidence:
    argv: tuple[str, ...]
    stdout: str
    stderr: str
    exit_status: int
    elapsed_s: float


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def tree_hash(root: Path) -> str:
    if not root.is_dir():
        raise CommunityError(f"model cache is not a directory: {root}")
    digest = hashlib.sha256()
    for path in sorted((item for item in root.rglob("*") if item.is_file()), key=lambda item: str(item.relative_to(root))):
        digest.update(str(path.relative_to(root)).encode() + b"\0" + path.resolve(strict=True).read_bytes())
    return digest.hexdigest()


def canonical_label(value: object) -> str:
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        raise CommunityError("speaker label must be a string or integer")
    label = str(value).strip()
    if not label:
        raise CommunityError("speaker label cannot be empty")
    return label


def _inside(path: Path, root: Path) -> Path:
    resolved = path.resolve(strict=True)
    try:
        resolved.relative_to(root)
    except ValueError as error:
        raise CommunityError(f"pack evidence escapes the pack root: {path}") from error
    return resolved


def trailing_json_object(stdout: str) -> dict[str, object]:
    def reject_constant(value: str) -> object:
        raise CommunityError(f"non-finite JSON number {value}")

    def reject_duplicates(pairs: Sequence[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise CommunityError(f"duplicate JSON key {key}")
            result[key] = value
        return result

    decoder = json.JSONDecoder(object_pairs_hook=reject_duplicates, parse_constant=reject_constant)
    candidates: list[dict[str, object]] = []
    for offset, character in enumerate(stdout):
        if character != "{":
            continue
        try:
            value, end = decoder.raw_decode(stdout, offset)
        except json.JSONDecodeError:
            continue
        if stdout[end:].strip() == "" and isinstance(value, dict):
            candidates.append(value)
    if len(candidates) != 1:
        raise CommunityError("stdout must end in one unique JSON object")
    return candidates[0]


def _segment_array(document: Mapping[str, object]) -> Sequence[object]:
    for key in ("segments", "diarization", "speaker_segments"):
        value = document.get(key)
        if isinstance(value, list):
            return value
    raise CommunityError("Community JSON has no segment array")


def parse_segments(stdout: str) -> tuple[Segment, ...]:
    document = trailing_json_object(stdout)
    result = []
    for raw in _segment_array(document):
        if not isinstance(raw, dict):
            raise CommunityError("Community segment must be an object")
        label_value = raw.get("speaker", raw.get("label", raw.get("speaker_id")))
        try:
            label = canonical_label(label_value)
            start_s = float(raw.get("start", raw.get("start_s")))
            end_s = float(raw.get("end", raw.get("end_s")))
        except (TypeError, ValueError) as error:
            raise CommunityError("Community segment has invalid fields") from error
        if not math.isfinite(start_s) or not math.isfinite(end_s) or end_s <= start_s:
            raise CommunityError("Community segment must have finite increasing bounds")
        start_s, end_s = max(0.0, start_s), min(WINDOW_SECONDS, end_s)
        if end_s <= start_s:
            raise CommunityError("Community segment is wholly outside [0,30)")
        result.append(Segment(label, start_s, end_s))
    return tuple(result)


def merge_segments(segments: Sequence[Segment]) -> tuple[Segment, ...]:
    by_label: dict[str, list[Segment]] = {}
    for segment in segments:
        by_label.setdefault(segment.label, []).append(segment)
    merged = []
    for label in sorted(by_label):
        ordered = sorted(by_label[label], key=lambda item: (item.start_s, item.end_s))
        start, end = ordered[0].start_s, ordered[0].end_s
        for segment in ordered[1:]:
            if segment.start_s <= end:
                end = max(end, segment.end_s)
            else:
                merged.append(Segment(label, start, end))
                start, end = segment.start_s, segment.end_s
        merged.append(Segment(label, start, end))
    return tuple(merged)


def rasterize(segments: Sequence[Segment]) -> tuple[tuple[str, ...], list[list[int]]]:
    merged = merge_segments(segments)
    labels = tuple(sorted({segment.label for segment in merged}))
    raster = [[0] * FRAME_COUNT for _ in labels]
    label_index = {label: index for index, label in enumerate(labels)}
    for segment in merged:
        row = raster[label_index[segment.label]]
        for frame in range(FRAME_COUNT):
            center = (frame + 0.5) / FRAME_HZ
            if segment.start_s <= center < segment.end_s:
                row[frame] = 1
    positive = [(label, row) for label, row in zip(labels, raster) if any(row)]
    return tuple(label for label, _ in positive), [row for _, row in positive]


def freeze_mapping(
    labels: Sequence[str],
    provider_activity: Sequence[Sequence[int]],
    reference_ids: Sequence[str],
    reference_activity: Sequence[Sequence[int]],
) -> dict[str, object]:
    if len(reference_ids) != 2 or len(set(reference_ids)) != 2:
        raise CommunityError("mapping requires two distinct frozen references")
    if len(labels) != len(provider_activity) or len(set(labels)) != len(labels):
        raise CommunityError("provider labels and activity rows do not match")
    if len(reference_activity) != 2:
        raise CommunityError("mapping requires two reference activity rows")
    width = len(reference_activity[0])
    if width == 0 or any(len(row) != width for row in reference_activity) or any(
        len(row) != width for row in provider_activity
    ):
        raise CommunityError("mapping activity widths do not match")
    overlaps = [
        [sum(int(a) & int(b) for a, b in zip(provider, reference)) for reference in reference_activity]
        for provider in provider_activity
    ]
    canonical = [canonical_label(label) for label in labels]
    if len(set(canonical)) != len(canonical):
        raise CommunityError("provider labels collide after canonicalization")
    choices: list[tuple[int, tuple[tuple[str, str], ...], tuple[int, int]]] = []
    if len(canonical) >= 2:
        for first, second in itertools.permutations(range(len(canonical)), 2):
            score = overlaps[first][0] + overlaps[second][1]
            selected = (first, second)
            tie_key = tuple(
                sorted((canonical[label_index], str(reference_ids[reference_index])) for reference_index, label_index in enumerate(selected))
            )
            choices.append((score, tie_key, selected))
        best_score = max(item[0] for item in choices)
        best = min((item for item in choices if item[0] == best_score), key=lambda item: item[1])
        selected = best[2]
        slots = [
            {"reference_id": reference_ids[index], "provider_label": canonical[selected[index]], "status": "mapped"}
            for index in range(2)
        ]
        used = {canonical[index] for index in selected}
    elif len(canonical) == 1:
        scores = overlaps[0]
        reference_index = min(
            (index for index, score in enumerate(scores) if score == max(scores)),
            key=lambda index: reference_ids[index],
        )
        slots = []
        for index, reference_id in enumerate(reference_ids):
            if index == reference_index:
                slots.append({"reference_id": reference_id, "provider_label": canonical[0], "status": "mapped"})
            else:
                slots.append({"reference_id": reference_id, "provider_label": f"ABSENT:{reference_id}", "status": "ABSENT"})
        used = {canonical[0]}
        best_score = scores[reference_index]
    else:
        slots = [
            {"reference_id": reference_id, "provider_label": f"ABSENT:{reference_id}", "status": "ABSENT"}
            for reference_id in reference_ids
        ]
        used = set()
        best_score = 0
    surplus = sorted(set(canonical) - used)
    return {
        "reference_ids": list(reference_ids),
        "real_labels": canonical,
        "activity_matrix": overlaps,
        "objective": best_score,
        "tie_break": ["maximum_activity_overlap", "lexical_label_id", "reference_id"],
        "slots": slots,
        "surplus": surplus,
        "diarizer_undercount": len(canonical) < 2,
        "diarizer_overcount": len(canonical) > 2,
    }


def command_for(binary: Path, audio: Path) -> tuple[str, ...]:
    return (
        "/usr/bin/sandbox-exec",
        "-f",
        str(Path(__file__).with_name("deny-network.sb").resolve()),
        str(binary),
        "diarize",
        "--engine",
        "community1",
        "--community1-compute-units",
        "ane",
        "--min-speakers",
        "1",
        "--json",
        str(audio),
    )


def validate_runtime_invocation(runtime: Mapping[str, object], binary: Path, audio: Path) -> None:
    binary_record = runtime.get("binary")
    if not isinstance(binary_record, dict) or str(binary) != binary_record.get("path"):
        raise CommunityError("Community invocation does not use the T9 speech binary")
    if not binary.is_file() or sha256_file(binary) != binary_record.get("sha256"):
        raise CommunityError("Community invocation speech binary hash mismatch")
    if not audio.is_absolute() or not audio.is_file():
        raise CommunityError("Community invocation audio must be an existing absolute file")


def validate_elapsed(elapsed_s: float, timeout_s: float = PROCESS_TIMEOUT_SECONDS) -> None:
    if not math.isfinite(elapsed_s) or elapsed_s < 0:
        raise CommunityError("invalid process elapsed time")
    if elapsed_s > timeout_s:
        raise CommunityError("Community-1 process exceeded 240-second timeout")


def run_process(
    binary: Path,
    audio: Path,
    *,
    popen_factory: Callable[..., subprocess.Popen[str]] = subprocess.Popen,
    clock: Callable[[], float] = time.monotonic,
) -> ProcessEvidence:
    argv = command_for(binary, audio)
    started = clock()
    process = popen_factory(
        argv,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env={
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": "/private/var/empty",
            "QWEN3_CACHE_DIR": os.environ.get("QWEN3_CACHE_DIR", ""),
        },
    )
    try:
        stdout, stderr = process.communicate(timeout=PROCESS_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired as error:
        process.kill()
        process.communicate()
        raise CommunityError("Community-1 process exceeded 240-second timeout") from error
    elapsed = clock() - started
    validate_elapsed(elapsed)
    if process.returncode != 0:
        raise CommunityError(f"Community-1 process exited {process.returncode}")
    parse_segments(stdout)
    return ProcessEvidence(argv, stdout, stderr, int(process.returncode), elapsed)


def _read_json(path: Path) -> dict[str, object]:
    def reject_constant(value: str) -> object:
        raise ValueError(f"non-finite JSON number {value}")

    def reject_duplicates(pairs: Sequence[tuple[str, object]]) -> dict[str, object]:
        result: dict[str, object] = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON key {key}")
            result[key] = value
        return result

    try:
        value = json.loads(
            path.read_text(encoding="utf-8"),
            parse_constant=reject_constant,
            object_pairs_hook=reject_duplicates,
        )
    except (OSError, json.JSONDecodeError, ValueError) as error:
        raise CommunityError(f"invalid JSON: {path}") from error
    if not isinstance(value, dict):
        raise CommunityError(f"JSON root must be an object: {path}")
    return value


def verify_runtime(preflight: Path) -> Mapping[str, object]:
    preflight = preflight.resolve(strict=True)
    canonical_path = preflight / "canonical.json"
    canonical = _read_json(canonical_path)
    expected_top_level = {
        "schema_version", "run_id", "run_root", "attempt_fingerprint", "attempt_root", "paths",
        "mlx_reused_symbols", "mlx_implementation_source", "inspection_sha256",
        "inspection_outcome", "inspection_verdict", "inspection_blocker",
        "runtime_bindings", "resource", "resource_policy", "future_resource_ledger", "host", "acquisitions",
        "promotion_records", "promotion_final_paths", "promotion_staged_paths",
    }
    if set(canonical) != expected_top_level or canonical.get("schema_version") != "dicow-e0-preflight-v1":
        raise CommunityError("unexpected T9 canonical shape")
    run_id = os.environ.get("DICOW_RUN_ID")
    run_root = os.environ.get("DICOW_RUN_ROOT")
    if (
        not run_id
        or not run_root
        or canonical.get("run_id") != run_id
        or canonical.get("run_root") != run_root
        or Path(run_root) != preflight.parent
    ):
        raise CommunityError("T9 canonical run binding is invalid")
    fingerprint = canonical.get("attempt_fingerprint")
    attempt = Path(str(canonical.get("attempt_root", "")))
    if (
        not isinstance(fingerprint, str)
        or len(fingerprint) != 64
        or any(character not in "0123456789abcdef" for character in fingerprint)
        or not attempt.is_absolute()
        or not attempt.is_dir()
        or attempt.parent != preflight / "attempts"
        or not attempt.name.startswith(fingerprint + "-")
    ):
        raise CommunityError("T9 canonical attempt binding is invalid")
    bindings = canonical.get("runtime_bindings")
    if not isinstance(bindings, dict) or set(bindings) != {"aligner", "community1"}:
        raise CommunityError("T9 runtime binding set is invalid")
    record = bindings.get("community1")
    if not isinstance(record, dict) or set(record) != {
        "model_id", "model_revision", "binary", "model_tree", "sandbox_profile"
    }:
        raise CommunityError("T9 Community-1 runtime binding shape is invalid")
    if record.get("model_id") != EXPECTED_MODEL_ID or record.get("model_revision") != EXPECTED_MODEL_REVISION:
        raise CommunityError("wrong Community-1 model identity")
    try:
        from benchmarks.scripts.dicow.common.preflight import artifact_record
    except ImportError as error:
        raise CommunityError("cannot import the T9 artifact verifier") from error
    normalized: dict[str, object] = {
        "model_id": EXPECTED_MODEL_ID,
        "model_revision": EXPECTED_MODEL_REVISION,
        "canonical_path": str(canonical_path),
        "canonical_sha256": sha256_file(canonical_path),
    }
    for field in ("binary", "model_tree", "sandbox_profile"):
        item = record.get(field)
        if not isinstance(item, dict) or set(item) != {"path", "record"} or not isinstance(item.get("path"), str):
            raise CommunityError(f"runtime {field} fingerprint is missing")
        path = Path(item["path"])
        try:
            actual = artifact_record(path, immutable=field != "sandbox_profile")
        except Exception as error:
            raise CommunityError(f"runtime {field} artifact verification failed: {error}") from error
        if actual != item.get("record"):
            raise CommunityError(f"runtime {field} record mismatch")
        digest_key = "tree_sha256" if field == "model_tree" else "sha256"
        digest = actual.get(digest_key)
        if not isinstance(digest, str):
            raise CommunityError(f"runtime {field} record has no digest")
        normalized[field] = {"path": str(path), "record": actual, "sha256": digest}
    paths = canonical.get("paths")
    promotions = canonical.get("promotion_final_paths")
    model_path = Path(str(record["model_tree"]["path"]))
    binary_path = Path(str(record["binary"]["path"]))
    tracked_sandbox = Path(__file__).with_name("deny-network.sb").resolve()
    if not isinstance(paths, dict) or str(model_path) != paths.get("community_snapshot"):
        raise CommunityError("Community model tree is not the T9 canonical snapshot")
    if not isinstance(promotions, dict):
        raise CommunityError("T9 promotion paths are missing")
    try:
        binary_path.relative_to(Path(str(promotions.get("speech-runtime", ""))))
    except ValueError as error:
        raise CommunityError("Community binary is outside the T9 runtime") from error
    if Path(str(record["sandbox_profile"]["path"])) != tracked_sandbox:
        raise CommunityError("T9 does not bind the tracked network-denial profile")
    return normalized


def verify_pack(pack: Path) -> None:
    pack = pack.resolve(strict=True)
    run_root_value = os.environ.get("DICOW_RUN_ROOT")
    if not run_root_value:
        raise CommunityError("DICOW_RUN_ROOT is required to bind T9 runtime evidence")
    runtime = verify_runtime(Path(run_root_value) / "e0-preflight")
    expected_binary = runtime["binary"]
    expected_model = runtime["model_tree"]
    expected_sandbox = runtime["sandbox_profile"]
    tracked_sandbox = Path(__file__).with_name("deny-network.sb").resolve()
    if expected_sandbox.get("path") != str(tracked_sandbox) or expected_sandbox.get("sha256") != sha256_file(tracked_sandbox):
        raise CommunityError("T9 runtime does not bind the tracked network-denial profile")
    manifest = _read_json(pack / "pack-manifest.json")
    windows = manifest.get("constructed_mixtures")
    if not isinstance(windows, list) or len(windows) != 10:
        raise CommunityError("pack must contain ten constructed mixtures")
    for window in windows:
        if not isinstance(window, dict):
            raise CommunityError("invalid constructed-mixture record")
        community = window.get("community1")
        if not isinstance(community, dict):
            raise CommunityError("mixture lacks Community-1 evidence")
        raw_path = _inside(pack / str(community.get("raw_stdout", "")), pack)
        segments = parse_segments(raw_path.read_text(encoding="utf-8"))
        labels, raster = rasterize(segments)
        if list(labels) != community.get("labels") or hashlib.sha256(bytes(sum(raster, []))).hexdigest() != community.get("activity_sha256"):
            raise CommunityError("Community-1 raster does not reproduce")
        evidence_path = _inside(
            pack / str(community.get("evidence_path", Path(str(community.get("raw_stdout", ""))).parent / "evidence.json")),
            pack,
        )
        evidence = _read_json(evidence_path)
        binary = Path(str(evidence.get("binary_path", "")))
        model_tree = Path(str(evidence.get("model_tree_path", "")))
        audio = _inside(Path(str(window.get("audio_path", ""))), pack)
        expected_argv = list(command_for(binary, audio))
        activity_sha256 = hashlib.sha256(bytes(sum(raster, []))).hexdigest()
        expected_segments = [segment.__dict__ for segment in merge_segments(segments)]
        if (
            evidence.get("binary_path") != expected_binary.get("path")
            or evidence.get("binary_sha256") != expected_binary.get("sha256")
            or evidence.get("model_tree_path") != expected_model.get("path")
            or evidence.get("model_tree_sha256") != expected_model.get("sha256")
            or evidence.get("sandbox_sha256") != expected_sandbox.get("sha256")
            or evidence.get("t9_canonical_path") != runtime.get("canonical_path")
            or evidence.get("t9_canonical_sha256") != runtime.get("canonical_sha256")
            or evidence.get("argv") != expected_argv
            or evidence.get("audio_path") != str(audio)
            or evidence.get("audio_sha256") != sha256_file(audio)
            or evidence.get("exit_status") != 0
            or evidence.get("labels") != list(labels)
            or evidence.get("segments") != expected_segments
            or evidence.get("activity") != raster
            or evidence.get("activity_sha256") != activity_sha256
        ):
            raise CommunityError("Community evidence does not match T9 runtime provenance")
        validate_elapsed(float(evidence.get("elapsed_s", float("nan"))))
        if sha256_file(raw_path) != evidence.get("stdout_sha256"):
            raise CommunityError("Community stdout hash changed")
        stderr_path = raw_path.with_name("stderr.txt")
        if sha256_file(stderr_path) != evidence.get("stderr_sha256"):
            raise CommunityError("Community stderr hash changed")
        if sha256_file(evidence_path) != community.get("raw_evidence_sha256"):
            raise CommunityError("Community evidence record hash changed")
        if not binary.is_file() or sha256_file(binary) != evidence.get("binary_sha256"):
            raise CommunityError("Community runtime binary hash changed")
        if expected_model.get("sha256") != evidence.get("model_tree_sha256"):
            raise CommunityError("Community model-tree hash changed")
        sandbox = Path(__file__).with_name("deny-network.sb")
        if sha256_file(sandbox) != evidence.get("sandbox_sha256"):
            raise CommunityError("Community sandbox profile hash changed")


def write_process_evidence(output: Path, evidence: ProcessEvidence, runtime: Mapping[str, object]) -> None:
    if output.exists() or output.is_symlink():
        raise CommunityError(f"refusing to overwrite Community output: {output}")
    segments = parse_segments(evidence.stdout)
    labels, raster = rasterize(segments)
    binary = Path(evidence.argv[3])
    audio = Path(evidence.argv[-1])
    if evidence.argv != command_for(binary, audio):
        raise CommunityError("Community process evidence has a noncanonical command")
    if evidence.exit_status != 0:
        raise CommunityError("Community process evidence has a nonzero exit status")
    validate_elapsed(evidence.elapsed_s)
    binary_record = runtime.get("binary")
    sandbox_record = runtime.get("sandbox_profile")
    tracked_sandbox = Path(__file__).with_name("deny-network.sb").resolve()
    if (
        not isinstance(binary_record, dict)
        or str(binary) != binary_record.get("path")
        or sha256_file(binary) != binary_record.get("sha256")
    ):
        raise CommunityError("speech binary changed during Community inference")
    if (
        not isinstance(sandbox_record, dict)
        or str(tracked_sandbox) != sandbox_record.get("path")
        or sha256_file(tracked_sandbox) != sandbox_record.get("sha256")
    ):
        raise CommunityError("network-denial profile does not match T9 provenance")
    model_record = runtime.get("model_tree")
    if not isinstance(model_record, dict):
        raise CommunityError("runtime model-tree provenance is missing")
    model_tree = Path(str(model_record.get("path", ""))).resolve(strict=True)
    cache_root = Path(os.environ.get("QWEN3_CACHE_DIR", "")).resolve(strict=True)
    try:
        model_tree.relative_to(cache_root)
    except ValueError as error:
        raise CommunityError("pinned Community model tree is outside QWEN3_CACHE_DIR") from error
    try:
        from benchmarks.scripts.dicow.common.preflight import artifact_record

        if artifact_record(model_tree, immutable=True) != model_record.get("record"):
            raise CommunityError("pinned Community model tree changed before inference")
    except CommunityError:
        raise
    except Exception as error:
        raise CommunityError(f"pinned Community model tree verification failed: {error}") from error
    output.mkdir(parents=True)
    (output / "stdout.txt").write_text(evidence.stdout, encoding="utf-8")
    (output / "stderr.txt").write_text(evidence.stderr, encoding="utf-8")
    record = {
        "schema_version": "1.0.0",
        "argv": list(evidence.argv),
        "stdout_sha256": sha256_file(output / "stdout.txt"),
        "stderr_sha256": sha256_file(output / "stderr.txt"),
        "exit_status": evidence.exit_status,
        "elapsed_s": evidence.elapsed_s,
        "labels": list(labels),
        "segments": [segment.__dict__ for segment in merge_segments(segments)],
        "activity_sha256": hashlib.sha256(bytes(sum(raster, []))).hexdigest(),
        "activity": raster,
        "binary_path": str(binary),
        "binary_sha256": sha256_file(binary),
        "audio_path": str(audio),
        "audio_sha256": sha256_file(audio),
        "model_tree_path": str(model_tree),
        "model_tree_sha256": model_record["sha256"],
        "sandbox_sha256": sandbox_record["sha256"],
        "t9_canonical_path": runtime["canonical_path"],
        "t9_canonical_sha256": runtime["canonical_sha256"],
    }
    (output / "evidence.json").write_text(
        json.dumps(record, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    runtime = subparsers.add_parser("verify-runtime")
    runtime.add_argument("--preflight", type=Path, required=True)
    pack = subparsers.add_parser("verify-pack")
    pack.add_argument("--pack", type=Path, required=True)
    run = subparsers.add_parser("run-one")
    run.add_argument("--binary", type=Path, required=True)
    run.add_argument("--audio", type=Path, required=True)
    run.add_argument("--output", type=Path, required=True)
    run.add_argument("--preflight", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "verify-runtime":
            verify_runtime(args.preflight)
        elif args.command == "verify-pack":
            verify_pack(args.pack)
        else:
            runtime = verify_runtime(args.preflight)
            validate_runtime_invocation(runtime, args.binary, args.audio)
            write_process_evidence(args.output, run_process(args.binary, args.audio), runtime)
    except (CommunityError, OSError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(f"PASS: {args.command}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
