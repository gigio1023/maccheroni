"""Offline Qwen3 ForcedAligner batch wrapper for reference partitioning only."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import stat
import sys
from pathlib import Path
from typing import Callable, Mapping, Sequence


MODEL_ID = "Qwen/Qwen3-ForcedAligner-0.6B"
MODEL_REVISION = "c7cbfc2048c462b0d63a45797104fc9db3ad62b7"
EXPECTED_FAMILIES = (("hike", 12), ("fleurs-en", 8), ("fleurs-it", 8))
EXPECTED_ROWS = 28


class AlignerError(RuntimeError):
    """The frozen aligner input or output is incomplete or inconsistent."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def snapshot_tree_hash(root: Path) -> str:
    _reject_symlink_components(root)
    if not root.is_dir():
        raise AlignerError("aligner snapshot must be a directory")
    digest = hashlib.sha256()
    for path in sorted((item for item in root.rglob("*") if item.is_file()), key=lambda item: str(item.relative_to(root))):
        relative = str(path.relative_to(root))
        digest.update(relative.encode() + b"\0" + path.resolve(strict=True).read_bytes())
    return digest.hexdigest()


def _reject_symlink_components(path: Path) -> None:
    if not path.is_absolute() or os.path.normpath(str(path)) != str(path):
        raise AlignerError("snapshot and input paths must be normalized absolute paths")
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        try:
            mode = os.lstat(current).st_mode
        except FileNotFoundError:
            raise AlignerError(f"required path does not exist: {current}")
        if stat.S_ISLNK(mode):
            raise AlignerError(f"path contains a symlink component: {current}")


def read_json(path: Path) -> dict[str, object]:
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
        raise AlignerError(f"invalid JSON: {path}") from error
    if not isinstance(value, dict):
        raise AlignerError(f"JSON root must be an object: {path}")
    return value


def verify_t9_snapshot(preflight_root: Path, snapshot: Path) -> dict[str, object]:
    preflight_root = preflight_root.resolve(strict=True)
    canonical = read_json(preflight_root / "canonical.json")
    if canonical.get("schema_version") != "dicow-e0-preflight-v1":
        raise AlignerError("unexpected T9 canonical schema")
    run_id = os.environ.get("DICOW_RUN_ID")
    run_root = os.environ.get("DICOW_RUN_ROOT")
    if (
        not run_id
        or not run_root
        or canonical.get("run_id") != run_id
        or canonical.get("run_root") != run_root
        or Path(run_root) != preflight_root.parent
    ):
        raise AlignerError("T9 canonical run binding is invalid")
    fingerprint = canonical.get("attempt_fingerprint")
    attempt = Path(str(canonical.get("attempt_root", "")))
    if (
        not isinstance(fingerprint, str)
        or len(fingerprint) != 64
        or any(character not in "0123456789abcdef" for character in fingerprint)
        or not attempt.is_dir()
        or attempt.parent != preflight_root / "attempts"
        or not attempt.name.startswith(fingerprint + "-")
    ):
        raise AlignerError("T9 canonical attempt binding is invalid")
    bindings = canonical.get("runtime_bindings")
    aligner = bindings.get("aligner") if isinstance(bindings, dict) else None
    if not isinstance(aligner, dict) or set(aligner) != {"model_id", "model_revision", "snapshot"}:
        raise AlignerError("T9 aligner runtime binding is missing")
    if aligner.get("model_id") != MODEL_ID or aligner.get("model_revision") != MODEL_REVISION:
        raise AlignerError("T9 aligner runtime binding has the wrong model identity")
    binding = aligner.get("snapshot")
    if not isinstance(binding, dict) or set(binding) != {"path", "record"}:
        raise AlignerError("T9 aligner snapshot binding is malformed")
    if str(snapshot) != binding.get("path"):
        raise AlignerError("aligner snapshot path does not match T9")
    try:
        from benchmarks.scripts.dicow.common.preflight import artifact_record

        actual = artifact_record(snapshot, immutable=True)
    except Exception as error:
        raise AlignerError(f"cannot authenticate the T9 aligner snapshot: {error}") from error
    if actual != binding.get("record"):
        raise AlignerError("aligner snapshot record does not match T9")
    return aligner


def canonical_json_hash(value: object) -> str:
    payload = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(payload).hexdigest()


def validate_manifest(document: Mapping[str, object], *, require_exact_rows: bool = True) -> list[dict[str, object]]:
    if document.get("model_id") != MODEL_ID or document.get("model_revision") != MODEL_REVISION:
        raise AlignerError("wrong aligner model identity")
    rows = document.get("rows")
    if not isinstance(rows, list) or (require_exact_rows and len(rows) != EXPECTED_ROWS):
        raise AlignerError("ordered aligner manifest must contain exactly 28 rows")
    validated = []
    row_ids = []
    families = []
    for raw in rows:
        if not isinstance(raw, dict):
            raise AlignerError("aligner row must be an object")
        required = ("row_id", "family", "audio_path", "audio_sha256", "source_samples", "text", "language")
        if any(not isinstance(raw.get(key), str) for key in required if key != "source_samples") or not isinstance(raw.get("source_samples"), int):
            raise AlignerError("aligner row has missing or wrongly typed fields")
        if raw["language"] not in ("Korean", "English", "Italian"):
            raise AlignerError("aligner row uses an unsupported language name")
        if not 0 < int(raw["source_samples"]) <= 480_000:
            raise AlignerError("aligner source length is outside the pack range")
        audio = Path(str(raw["audio_path"]))
        _reject_symlink_components(audio)
        if sha256_file(audio) != raw["audio_sha256"]:
            raise AlignerError("aligner audio hash mismatch")
        row_ids.append(str(raw["row_id"]))
        families.append(str(raw["family"]))
        validated.append(dict(raw))
    if len(set(row_ids)) != len(row_ids):
        raise AlignerError("aligner manifest has duplicate row IDs")
    if require_exact_rows:
        expected = [family for family, count in EXPECTED_FAMILIES for _ in range(count)]
        if families != expected:
            raise AlignerError("aligner rows are not in the frozen 12+8+8 order")
    declared = document.get("manifest_sha256")
    hashable = {key: value for key, value in document.items() if key != "manifest_sha256"}
    if declared is not None and declared != canonical_json_hash(hashable):
        raise AlignerError("ordered aligner manifest hash mismatch")
    return validated


def validate_words(words: object, expected_units: Sequence[str], source_samples: int) -> list[dict[str, object]]:
    if not isinstance(words, list) or len(words) != len(expected_units):
        raise AlignerError("alignment normalized-unit round trip mismatch")
    result = []
    previous_end = 0.0
    duration_s = source_samples / 16_000.0
    for raw, expected in zip(words, expected_units):
        if not isinstance(raw, dict) or raw.get("text") != expected:
            raise AlignerError("alignment normalized-unit round trip mismatch")
        try:
            start_s, end_s = float(raw["start_s"]), float(raw["end_s"])
        except (KeyError, TypeError, ValueError) as error:
            raise AlignerError("alignment word has malformed timestamps") from error
        if (
            not math.isfinite(start_s)
            or not math.isfinite(end_s)
            or start_s < previous_end
            or end_s <= start_s
            or end_s > duration_s
        ):
            raise AlignerError("alignment word timestamps are not finite, monotone, and in bounds")
        previous_end = end_s
        result.append({"text": expected, "start_s": start_s, "end_s": end_s})
    return result


def validate_result_set(
    manifest: Mapping[str, object],
    result: Mapping[str, object],
    *,
    require_exact_rows: bool = True,
) -> list[dict[str, object]]:
    rows = validate_manifest(manifest, require_exact_rows=require_exact_rows)
    outputs = result.get("results")
    if not isinstance(outputs, list) or len(outputs) != len(rows):
        raise AlignerError("alignment result is partial")
    if result.get("input_manifest_sha256") != canonical_json_hash(dict(manifest)):
        raise AlignerError("alignment result cites the wrong input manifest")
    if result.get("model_id") != MODEL_ID or result.get("model_revision") != MODEL_REVISION:
        raise AlignerError("alignment result cites the wrong model")
    if not isinstance(result.get("snapshot_sha256"), str) or len(result["snapshot_sha256"]) != 64:
        raise AlignerError("alignment result has no snapshot hash")
    output_ids = [raw.get("row_id") if isinstance(raw, dict) else None for raw in outputs]
    expected_ids = [row["row_id"] for row in rows]
    if output_ids != expected_ids or len(set(output_ids)) != len(output_ids):
        raise AlignerError("alignment result is duplicated or reordered")
    validated = []
    for row, output in zip(rows, outputs):
        if not isinstance(output, dict) or output.get("audio_sha256") != row["audio_sha256"]:
            raise AlignerError("alignment output audio hash mismatch")
        expected_units = output.get("normalized_units")
        if not isinstance(expected_units, list) or not all(isinstance(item, str) and item for item in expected_units):
            raise AlignerError("alignment output has no normalized units")
        words = validate_words(output.get("words"), expected_units, int(row["source_samples"]))
        validated.append({**output, "words": words})
    return validated


def require_consistent_repetitions(first: Mapping[str, object], second: Mapping[str, object]) -> None:
    if first.get("input_manifest_sha256") != second.get("input_manifest_sha256"):
        raise AlignerError("aligner repetitions consumed different manifests")
    for field in ("model_id", "model_revision", "snapshot_path", "snapshot_sha256"):
        if first.get(field) != second.get(field):
            raise AlignerError(f"aligner repetitions differ in {field}")
    if first.get("process_id") == second.get("process_id"):
        raise AlignerError("aligner repetitions were not fresh processes")
    first_results, second_results = first.get("results"), second.get("results")
    if not isinstance(first_results, list) or not isinstance(second_results, list) or len(first_results) != len(second_results):
        raise AlignerError("aligner repetitions have different result counts")
    for left, right in zip(first_results, second_results):
        if not isinstance(left, dict) or not isinstance(right, dict):
            raise AlignerError("aligner repetition result must be an object")
        for field in ("row_id", "audio_sha256", "normalized_units"):
            if left.get(field) != right.get(field):
                raise AlignerError(f"aligner repetitions differ in {field}")


def execute_batch(
    manifest: Mapping[str, object],
    snapshot: Path,
    generate: Callable[[str, str, str], tuple[Sequence[str], Sequence[Mapping[str, object]]]],
    *,
    require_exact_rows: bool = True,
) -> dict[str, object]:
    _reject_symlink_components(snapshot)
    rows = validate_manifest(manifest, require_exact_rows=require_exact_rows)
    outputs = []
    for row in rows:
        units, words = generate(str(row["audio_path"]), str(row["text"]), str(row["language"]))
        validated = validate_words(list(words), list(units), int(row["source_samples"]))
        outputs.append(
            {
                "row_id": row["row_id"],
                "audio_sha256": row["audio_sha256"],
                "normalized_units": list(units),
                "words": validated,
            }
        )
    return {
        "schema_version": "1.0.0",
        "model_id": MODEL_ID,
        "model_revision": MODEL_REVISION,
        "snapshot_path": str(snapshot),
        "snapshot_sha256": snapshot_tree_hash(snapshot),
        "input_manifest_sha256": canonical_json_hash(dict(manifest)),
        "process_id": os.getpid(),
        "results": outputs,
    }


def _mlx_generate(snapshot: Path) -> Callable[[str, str, str], tuple[Sequence[str], Sequence[Mapping[str, object]]]]:
    # Imported only in the model-owning child process.  Unit tests and preparer
    # orchestration therefore cannot accidentally load the 1.8 GB checkpoint.
    from mlx_audio.stt.utils import load_model

    model = load_model(str(snapshot))

    def generate(audio: str, text: str, language: str):
        units, _ = model.aligner_processor.encode_timestamp(text, language)
        aligned = model.generate(audio=audio, text=text, language=language)
        words = [
            {"text": item.text, "start_s": item.start_time, "end_s": item.end_time}
            for item in aligned.items
        ]
        return units, words

    return generate


def write_json_new(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write("\n")


def verify_pack(pack: Path, preflight_root: Path | None = None) -> None:
    if preflight_root is None:
        run_root = os.environ.get("DICOW_RUN_ROOT")
        if not run_root:
            raise AlignerError("DICOW_RUN_ROOT is required to bind T9 aligner evidence")
        preflight_root = Path(run_root) / "e0-preflight"
    manifest = read_json(pack / "aligner" / "ordered-manifest.json")
    first = read_json(pack / "aligner" / "repetition-1.json")
    second = read_json(pack / "aligner" / "repetition-2.json")
    validate_result_set(manifest, first)
    validate_result_set(manifest, second)
    require_consistent_repetitions(first, second)
    bound_snapshot = verify_t9_snapshot(preflight_root, Path(str(first.get("snapshot_path", ""))))
    for repetition in (first, second):
        snapshot = Path(str(repetition.get("snapshot_path", "")))
        if str(snapshot) != bound_snapshot["snapshot"]["path"]:
            raise AlignerError("aligner repetition does not cite the T9 snapshot")
        if snapshot_tree_hash(snapshot) != repetition.get("snapshot_sha256"):
            raise AlignerError("aligner snapshot changed after the batch run")


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    batch = commands.add_parser("run-batch")
    batch.add_argument("--manifest", type=Path, required=True)
    batch.add_argument("--snapshot", type=Path, required=True)
    batch.add_argument("--preflight", type=Path, required=True)
    batch.add_argument("--output", type=Path, required=True)
    verify = commands.add_parser("verify-pack")
    verify.add_argument("--pack", type=Path, required=True)
    verify.add_argument("--preflight", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.command == "run-batch":
            document = read_json(args.manifest)
            verify_t9_snapshot(args.preflight, args.snapshot)
            result = execute_batch(document, args.snapshot, _mlx_generate(args.snapshot))
            write_json_new(args.output, result)
        else:
            verify_pack(args.pack, args.preflight)
    except (AlignerError, OSError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(f"PASS: {args.command}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
