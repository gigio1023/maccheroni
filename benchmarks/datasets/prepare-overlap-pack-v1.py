"""Create the external, fingerprinted ``overlap-pack-v1`` evidence tree.

The pure construction functions are importable for synthetic tests.  The
``build`` command is deliberately create-only and publishes the canonical
selector and launcher fragment only after all three independent verifiers pass.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import stat
import subprocess
import sys
import urllib.request
import wave
from dataclasses import asdict
from pathlib import Path
from typing import Callable, Mapping, Sequence

import numpy as np

from benchmarks.scripts.dicow.aligner import qwen_reference
from benchmarks.scripts.dicow.common.fixtures import (
    FORMULA_VERSION,
    FixtureError,
    Interval,
    apply_crop,
    canonical_mix,
    classify_stable_words,
    enforce_korean_all_or_nothing,
    derive_absent_terms,
    oracle_activity,
    pad_single,
    require_target_geometry,
    sha256_pcm16,
)
from benchmarks.scripts.dicow.common.stno import clean_target_stno, encode_reference, stno_record, target_stno
from benchmarks.scripts.dicow.diarizer.community1_reference import freeze_mapping
from benchmarks.scripts.scoring.metrics import normalize_text


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
DECLARATION = REPOSITORY_ROOT / "benchmarks/datasets/overlap-pack-v1.json"
ACCEPTANCE_ROOT = REPOSITORY_ROOT / "benchmarks/samples/public/acceptance-pack-v1"
FINGERPRINT_INPUTS = (
    "benchmarks/datasets/overlap-pack-v1.json",
    "benchmarks/datasets/overlap-pack-v1.md",
    "benchmarks/datasets/prepare-overlap-pack-v1.py",
    "benchmarks/datasets/build-overlap-pack-v1.zsh",
    "benchmarks/datasets/verify-overlap-pack-v1.py",
    "benchmarks/datasets/tests/test_overlap_pack.py",
    "benchmarks/scripts/dicow/common/fixtures.py",
    "benchmarks/scripts/dicow/common/stno.py",
    "benchmarks/scripts/dicow/diarizer/community1_reference.py",
    "benchmarks/scripts/dicow/diarizer/deny-network.sb",
    "benchmarks/scripts/dicow/aligner/qwen_reference.py",
    "benchmarks/scripts/dicow/tests/test_stno.py",
    "benchmarks/scripts/dicow/tests/test_community1_reference.py",
    "benchmarks/scripts/dicow/tests/test_reference_aligner.py",
    "benchmarks/datasets/acceptance-pack-v1.json",
    "benchmarks/datasets/acceptance_pack.py",
    "benchmarks/scripts/dicow/common/pins.py",
    "benchmarks/scripts/dicow/common/preflight.py",
    "benchmarks/scripts/dicow/run_with_env.py",
    "benchmarks/env/dicow-reference/pyproject.toml",
    "benchmarks/env/dicow-reference/uv.lock",
    "benchmarks/env/dicow-aligner/pyproject.toml",
    "benchmarks/env/dicow-aligner/uv.lock",
)


class PrepareError(RuntimeError):
    """The external pack could not be built without weakening its contract."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


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
        raise PrepareError(f"invalid JSON: {path}") from error
    if not isinstance(value, dict):
        raise PrepareError(f"JSON root must be an object: {path}")
    return value


def write_json_new(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write("\n")


def write_bytes_new(path: Path, value: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("xb") as stream:
        stream.write(value)


def artifact_id(value: object) -> str:
    return hashlib.sha256(str(value).encode("utf-8")).hexdigest()[:24]


def pcm16_from_wav_bytes(payload: bytes) -> np.ndarray:
    try:
        with wave.open(io.BytesIO(payload), "rb") as source:
            if source.getnchannels() != 1 or source.getframerate() != 16_000 or source.getsampwidth() != 2:
                raise PrepareError("source WAV must be mono 16 kHz PCM16")
            frames = source.readframes(source.getnframes())
    except (wave.Error, EOFError) as error:
        raise PrepareError("invalid source WAV") from error
    return np.frombuffer(frames, dtype="<i2").copy()


def pcm16_from_wav(path: Path) -> np.ndarray:
    return pcm16_from_wav_bytes(path.read_bytes())


def wav_bytes(samples: np.ndarray) -> bytes:
    output = io.BytesIO()
    with wave.open(output, "wb") as target:
        target.setnchannels(1)
        target.setsampwidth(2)
        target.setframerate(16_000)
        target.writeframes(samples.astype("<i2", copy=False).tobytes())
    return output.getvalue()


def source_fingerprint(extra_inputs: Sequence[Path] = ()) -> str:
    digest = hashlib.sha256()
    for relative in FINGERPRINT_INPUTS:
        path = REPOSITORY_ROOT / relative
        digest.update(relative.encode() + b"\0" + path.read_bytes())
    for path in sorted(extra_inputs, key=str):
        digest.update(str(path).encode() + b"\0" + path.read_bytes())
    return digest.hexdigest()


def orchestration_order(window_ids: Sequence[str]) -> list[str]:
    if len(window_ids) != 10 or len(set(window_ids)) != 10:
        raise PrepareError("orchestration requires ten unique final mixture IDs")
    return [
        "fingerprint-and-create",
        "reference:prepare-sources-and-ordered-aligner-manifest",
        "aligner:fresh-process-1",
        "aligner:fresh-process-2",
        "reference:seal-regions-selection-and-mixtures",
        *[f"diarizer:fresh-network-denied:{window_id}" for window_id in window_ids],
        "reference:seal-community-mappings-stno-crops",
        "verify:general",
        "verify:aligner",
        "verify:community",
        "publish:canonical-and-fragment",
    ]


def run_orchestration(
    window_ids: Sequence[str],
    execute: Callable[[str], None],
    publish: Callable[[], None],
) -> None:
    """Run the frozen phase order; publish is unreachable after any failure."""

    steps = orchestration_order(window_ids)
    for step in steps[:-1]:
        execute(step)
    publish()


def read_hike_selection(path: Path) -> list[dict[str, object]]:
    value = read_json(path)
    expected_keys = {"fixture_id", "items", "reference_text", "selection", "source", "term_source_sample_ids"}
    if not isinstance(value, dict) or set(value) != expected_keys or value.get("fixture_id") != "hike-code-switch-v1":
        raise PrepareError("HiKE selection must be the sealed acceptance-pack object")
    items = value.get("items")
    if not isinstance(items, list) or len(items) != 12 or not all(isinstance(item, dict) for item in items):
        raise PrepareError("HiKE selection must contain exactly twelve items")
    return items


def acquire_public_file(
    url: str,
    destination: Path,
    expected_size: int,
    expected_sha256: str,
    *,
    fetch: Callable[[str], bytes] | None = None,
) -> None:
    """Acquire one allow-listed public payload without adopting partial output."""

    if destination.exists() or destination.is_symlink():
        raise PrepareError(f"refusing to overwrite acquired source: {destination}")
    if not url.startswith("https://"):
        raise PrepareError("public source URL must use HTTPS")
    loader = fetch or (lambda source: urllib.request.urlopen(source, timeout=120).read())
    payload = loader(url)
    if len(payload) != expected_size or hashlib.sha256(payload).hexdigest() != expected_sha256:
        raise PrepareError("acquired public source failed pinned size/hash verification")
    write_bytes_new(destination, payload)


def resolve_acceptance_root(attempt: Path) -> Path:
    """Use verified host inputs or recreate both public fixtures inside the attempt."""

    import importlib.util

    acceptance_path = REPOSITORY_ROOT / "benchmarks/datasets/acceptance_pack.py"
    spec = importlib.util.spec_from_file_location("overlap_acceptance_pack", acceptance_path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    declaration = module.load_pack(REPOSITORY_ROOT / "benchmarks/datasets/acceptance-pack-v1.json")
    try:
        for fixture in declaration["fixtures"]:
            module.verify_source_files(ACCEPTANCE_ROOT, fixture)
            module.verify_prepared_fixture(ACCEPTANCE_ROOT, fixture)
        return ACCEPTANCE_ROOT
    except module.PackError:
        external = attempt / "reacquired-acceptance"
        for fixture in declaration["fixtures"]:
            for record in fixture["source"]["files"]:
                acquire_public_file(
                    record["url"],
                    external / record["relative_path"],
                    record["size_bytes"],
                    record["sha256"],
                )
            module.create_fixture(external, fixture)
            module.verify_prepared_fixture(external, fixture)
        return external


def _find_hf_file(dataset_or_model: str, revision: str, relative: str) -> Path:
    hf_home = Path(os.environ["HF_HOME"])
    candidate = hf_home / "hub" / dataset_or_model / "snapshots" / revision / relative
    if not candidate.is_file():
        raise PrepareError(f"pinned isolated Hub payload is missing: {candidate}")
    return candidate.resolve(strict=True)


def _find_hf_snapshot(dataset_or_model: str, revision: str) -> Path:
    snapshot = Path(os.environ["HF_HOME"]) / "hub" / dataset_or_model / "snapshots" / revision
    if not snapshot.is_dir() or not (snapshot / "config.json").is_file():
        raise PrepareError(f"pinned isolated Hub snapshot is missing: {snapshot}")
    return snapshot


def _extract_audio_payload(value: object) -> bytes:
    if isinstance(value, dict):
        if isinstance(value.get("bytes"), bytes):
            return value["bytes"]
        if isinstance(value.get("path"), str):
            return Path(value["path"]).read_bytes()
    if isinstance(value, bytes):
        return value
    raise PrepareError("FLEURS audio column has no WAV bytes")


def scan_fleurs(path: Path, locale: str, salt: str, count: int, *, include_locale: bool = True) -> list[dict[str, object]]:
    import pyarrow.parquet as pq

    parquet = pq.ParquetFile(path)
    names = set(parquet.schema_arrow.names)
    id_column = next((name for name in ("id", "row_id", "audio_id") if name in names), None)
    text_column = next((name for name in ("transcription", "raw_transcription", "text") if name in names), None)
    if id_column is None or text_column is None or "audio" not in names:
        raise PrepareError("FLEURS parquet schema lacks id, audio, or transcription")
    candidates = []
    for batch in parquet.iter_batches(columns=[id_column, "audio", text_column], batch_size=32):
        data = batch.to_pydict()
        for row_id, audio, text in zip(data[id_column], data["audio"], data[text_column]):
            payload = _extract_audio_payload(audio)
            samples = pcm16_from_wav_bytes(payload)
            duration = len(samples) / 16_000.0
            if not 4.0 <= duration <= 12.0:
                continue
            identity = str(row_id)
            rank = hashlib.sha256((salt + (locale if include_locale else "") + identity).encode()).hexdigest()
            candidates.append(
                {
                    "row_id": identity,
                    "duration_s": duration,
                    "text": str(text),
                    "audio_bytes": payload,
                    "audio_sha256": hashlib.sha256(payload).hexdigest(),
                    "rank": rank,
                }
            )
    candidates.sort(key=lambda item: (item["rank"], item["row_id"]))
    if len(candidates) < count:
        raise PrepareError(f"{locale} has fewer than {count} eligible public rows")
    return candidates[:count]


def prepare_sources(attempt: Path) -> dict[str, object]:
    declaration = read_json(DECLARATION)
    acceptance_root = resolve_acceptance_root(attempt)
    hike_selection = read_hike_selection(acceptance_root / "prepared/hike-code-switch-v1/selection.json")
    if len(hike_selection) != 12:
        raise PrepareError("HiKE acceptance fixture no longer has twelve items")
    rows: list[dict[str, object]] = []
    mixtures: list[dict[str, object]] = []
    for index, item in enumerate(hike_selection):
        source = acceptance_root / "prepared/hike-code-switch-v1" / str(item["item_wav"])
        if sha256_file(source) != item["item_wav_sha256"]:
            raise PrepareError("HiKE read-only item hash drift")
        destination = attempt / f"sources/hike/{index:02d}.wav"
        write_bytes_new(destination, source.read_bytes())
        samples = pcm16_from_wav(destination)
        rows.append(
            {
                "row_id": str(item["sample_id"]),
                "family": "hike",
                "audio_path": str(destination),
                "audio_sha256": sha256_file(destination),
                "source_samples": len(samples),
                "text": str(item["text_normalized"]),
                "language": "Korean",
                "terms": sorted({str(term["English"]) for term in item.get("loanwords", [])}),
            }
        )
    for pair in range(6):
        a, b = rows[2 * pair], rows[2 * pair + 1]
        mixed = canonical_mix(pcm16_from_wav(Path(a["audio_path"])), pcm16_from_wav(Path(b["audio_path"])))
        window_id = f"hike-{pair:02d}"
        audio = attempt / f"mixtures/{window_id}/mix.wav"
        write_bytes_new(audio, wav_bytes(mixed.mixture))
        mixtures.append(_mix_record(window_id, a, b, mixed, audio))

    fleurs_rows: dict[str, list[dict[str, object]]] = {}
    fleurs_source_paths: list[Path] = []
    language_names = {"en_us": ("fleurs-en", "English"), "it_it": ("fleurs-it", "Italian")}
    for locale, (family, language) in language_names.items():
        source = _find_hf_file(
            "datasets--google--fleurs",
            "70bb2e84b976b7e960aa89f1c648e09c59f894dd",
            f"parquet-data/{locale}/test-00000-of-00001.parquet",
        )
        fleurs_source_paths.append(source)
        candidates = scan_fleurs(source, locale, "maccheroni-overlap-pack-v1", 8)
        fleurs_rows[locale] = []
        for index, candidate in enumerate(candidates):
            destination = attempt / f"sources/{family}/{index:02d}.wav"
            write_bytes_new(destination, candidate.pop("audio_bytes"))
            row = {
                "row_id": candidate["row_id"],
                "family": family,
                "audio_path": str(destination),
                "audio_sha256": sha256_file(destination),
                "source_samples": len(pcm16_from_wav(destination)),
                "text": candidate["text"],
                "language": language,
                "rank": candidate["rank"],
            }
            rows.append(row)
            fleurs_rows[locale].append(row)

    korean_source = _find_hf_file(
        "datasets--google--fleurs",
        "70bb2e84b976b7e960aa89f1c648e09c59f894dd",
        "parquet-data/ko_kr/test-00000-of-00001.parquet",
    )
    fleurs_source_paths.append(korean_source)
    korean_controls = scan_fleurs(
        korean_source,
        "ko_kr",
        "maccheroni-overlap-pack-v1-clean-ko",
        2,
        include_locale=False,
    )
    control_records = []
    for index, candidate in enumerate(korean_controls):
        destination = attempt / f"sources/fleurs-ko-clean/{index:02d}.wav"
        write_bytes_new(destination, candidate.pop("audio_bytes"))
        control_records.append(
            {
                "row_id": candidate["row_id"],
                "audio_path": str(destination),
                "audio_sha256": sha256_file(destination),
                "source_samples": len(pcm16_from_wav(destination)),
                "text": candidate["text"],
                "language": "Korean",
                "rank": candidate["rank"],
            }
        )
    official_terms = sorted({term for row in rows[:12] for term in row.get("terms", [])})
    absent_terms = derive_absent_terms(official_terms, [str(record["text"]) for record in control_records])
    absent_record = {
        "terms": absent_terms,
        "normalized_references": [normalize_text(str(record["text"])) for record in control_records],
        "source_ids": [record["row_id"] for record in control_records],
    }
    absent_record["list_sha256"] = qwen_reference.canonical_json_hash(absent_record)

    ami_source = acceptance_root / "sources/ami/IN1009.Mix-Headset.wav"
    ami = pcm16_from_wav(ami_source)
    ami_windows = []
    for index, start_s in enumerate((95, 125)):
        samples = ami[start_s * 16_000 : (start_s + 30) * 16_000]
        if len(samples) != 480_000:
            raise PrepareError("AMI parity replay source is shorter than [95,155)")
        destination = attempt / f"parity/ami-in1009-{index}.wav"
        write_bytes_new(destination, wav_bytes(samples))
        ami_windows.append(
            {
                "window_id": f"ami-in1009-{index}",
                "source_range_s": [start_s, start_s + 30],
                "audio_path": str(destination),
                "audio_sha256": sha256_file(destination),
                "use": "parity-only",
            }
        )

    manifest = {
        "schema_version": "1.0.0",
        "model_id": qwen_reference.MODEL_ID,
        "model_revision": qwen_reference.MODEL_REVISION,
        "rows": rows,
    }
    manifest["manifest_sha256"] = qwen_reference.canonical_json_hash(manifest)
    write_json_new(attempt / "aligner/ordered-manifest.json", manifest)
    fleurs_candidate_manifests = {}
    for locale, locale_rows in fleurs_rows.items():
        candidate = {
            "locale": locale,
            "rows": [
                {
                    "row_id": row["row_id"], "rank": row["rank"],
                    "audio_sha256": row["audio_sha256"], "source_samples": row["source_samples"],
                    "text": row["text"], "language": row["language"],
                }
                for row in locale_rows
            ],
        }
        candidate["candidate_manifest_sha256"] = qwen_reference.canonical_json_hash(candidate)
        fleurs_candidate_manifests[locale] = candidate
    plan = {
        "schema_version": "1.0.0",
        "pack_id": declaration["pack_id"],
        "hike_rows": rows[:12],
        "fleurs_rows": fleurs_rows,
        "fleurs_candidate_manifests": fleurs_candidate_manifests,
        "korean_clean_controls": control_records,
        "korean_absent_terms": absent_record,
        "ami_parity_windows": ami_windows,
        "preselected_mixtures": mixtures,
        "acceptance_root": str(acceptance_root),
        "source_hashes_before": _host_source_hashes(acceptance_root),
        "fleurs_source_hashes_before": {str(path): sha256_file(path) for path in fleurs_source_paths},
    }
    write_json_new(attempt / "source-plan.json", plan)
    return plan


def _mix_record(window_id: str, a: Mapping[str, object], b: Mapping[str, object], mixed, audio: Path) -> dict[str, object]:
    return {
        "window_id": window_id,
        "target_a": a["row_id"],
        "target_b": b["row_id"],
        "language": a["language"],
        "glossary": sorted(set(a.get("terms", [])) | set(b.get("terms", []))),
        "audio_path": str(audio),
        "audio_sha256": sha256_file(audio),
        "source_a_samples": mixed.source_a_samples,
        "source_b_samples": mixed.source_b_samples,
        "overlap_samples": mixed.overlap_samples,
        "b_start": mixed.b_start,
        "normalization_gain_a": mixed.normalization_gain_a,
        "normalization_gain_b": mixed.normalization_gain_b,
        "mix_gain": mixed.mix_gain,
        "pre_quantization_peak_a": mixed.pre_quantization_peak_a,
        "pre_quantization_peak_b": mixed.pre_quantization_peak_b,
        "pre_quantization_mix_peak": mixed.pre_quantization_mix_peak,
        "post_quantization_peak_a": mixed.post_quantization_peak_a,
        "post_quantization_peak_b": mixed.post_quantization_peak_b,
        "post_quantization_mix_peak": mixed.post_quantization_mix_peak,
        "formula_version": FORMULA_VERSION,
        "component_a_sha256": sha256_pcm16(mixed.component_a),
        "component_b_sha256": sha256_pcm16(mixed.component_b),
        "mixture_pcm_sha256": sha256_pcm16(mixed.mixture),
    }


def _host_source_hashes(root: Path) -> dict[str, str]:
    paths = [
        root / "sources/hike/data/test-00000-of-00001.parquet",
        root / "sources/ami/IN1009.Mix-Headset.wav",
        root / "sources/ami/ami_public_manual_1.6.2.zip",
    ]
    return {str(path): sha256_file(path) for path in paths}


def _result_words(result: Mapping[str, object]) -> dict[str, list[dict[str, object]]]:
    return {str(row["row_id"]): list(row["words"]) for row in result["results"]}  # type: ignore[index]


def _geometry_for_pair(a: Mapping[str, object], b: Mapping[str, object], repetitions, window_id: str):
    mixed = canonical_mix(pcm16_from_wav(Path(a["audio_path"])), pcm16_from_wav(Path(b["audio_path"])))
    targets = []
    for role, row, shift, support in (
        ("A", a, 0, mixed.support_a),
        ("B", b, mixed.b_start, mixed.support_b),
    ):
        words = classify_stable_words(
            [repetition[str(row["row_id"])] for repetition in repetitions],
            source_count=int(row["source_samples"]),
            shift=shift,
            source_support=support,
            overlap=mixed.overlap,
        )
        try:
            geometry = require_target_geometry(words, mixed.overlap)
        except FixtureError:
            geometry = None
        targets.append(
            {
                "target_id": row["row_id"],
                "role": role,
                "eligible": geometry is not None,
                "words": [asdict(word) for word in words],
                "geometry": asdict(geometry) if geometry else None,
            }
        )
    return mixed, targets


def seal_regions(attempt: Path) -> dict[str, object]:
    source_plan = read_json(attempt / "source-plan.json")
    manifest = read_json(attempt / "aligner/ordered-manifest.json")
    first = read_json(attempt / "aligner/repetition-1.json")
    second = read_json(attempt / "aligner/repetition-2.json")
    qwen_reference.validate_result_set(manifest, first)
    qwen_reference.validate_result_set(manifest, second)
    qwen_reference.require_consistent_repetitions(first, second)
    repetitions = (_result_words(first), _result_words(second))
    mixtures = list(source_plan["preselected_mixtures"])
    geometry_records = []
    selection_attempts = []
    hike_by_id = {str(row["row_id"]): row for row in source_plan["hike_rows"]}
    hike_eligibility = {}
    for mixture in mixtures:
        a, b = hike_by_id[str(mixture["target_a"])], hike_by_id[str(mixture["target_b"])]
        _, targets = _geometry_for_pair(a, b, repetitions, str(mixture["window_id"]))
        geometry_records.append({"window_id": mixture["window_id"], "targets": targets})
        hike_eligibility.update({str(target["target_id"]): bool(target["eligible"]) for target in targets})
    for locale, family in (("en_us", "fleurs-en"), ("it_it", "fleurs-it")):
        queue = list(source_plan["fleurs_rows"][locale])
        selected = 0
        while selected < 2:
            if len(queue) < 2:
                raise PrepareError(f"{locale} exhausted its frozen eight-row pool")
            a, b = queue[0], queue[1]
            mixed, targets = _geometry_for_pair(a, b, repetitions, f"{family}-{selected:02d}")
            eligible = [bool(target["eligible"]) for target in targets]
            selection_attempts.append(
                {
                    "locale": locale,
                    "a": a["row_id"],
                    "b": b["row_id"],
                    "role_order": "A-then-B",
                    "eligibility": eligible,
                    "exclusions": [target["target_id"] for target in targets if not target["eligible"]],
                }
            )
            if all(eligible):
                window_id = f"{family}-{selected:02d}"
                audio = attempt / f"mixtures/{window_id}/mix.wav"
                write_bytes_new(audio, wav_bytes(mixed.mixture))
                mixtures.append(_mix_record(window_id, a, b, mixed, audio))
                geometry_records.append({"window_id": window_id, "targets": targets})
                del queue[:2]
                selected += 1
            else:
                if not eligible[0]:
                    queue.remove(a)
                if not eligible[1]:
                    queue.remove(b)
    selection_record = {"attempts": selection_attempts}
    selection_record["selection_sha256"] = qwen_reference.canonical_json_hash(selection_record)
    all_rows = {str(row["row_id"]): row for row in manifest["rows"]}
    selected_pair_ids = [str(item[key]) for item in mixtures for key in ("target_a", "target_b")]
    singles = []
    single_ids = [str(row["row_id"]) for row in source_plan["hike_rows"]] + selected_pair_ids[12:]
    for row_id in single_ids:
        row = all_rows[row_id]
        destination = attempt / f"singles/{artifact_id(row_id)}/audio.wav"
        source_samples = pcm16_from_wav(Path(row["audio_path"]))
        write_bytes_new(destination, wav_bytes(pad_single(source_samples)))
        activity = oracle_activity((Interval(0, len(source_samples)),))
        activity_path = destination.parent / "speaker_activity.u8"
        stno_path = destination.parent / "stno-full-clean-target.f32le"
        write_bytes_new(activity_path, activity.tobytes(order="C"))
        single_stno = target_stno(activity, 0)
        write_bytes_new(stno_path, encode_reference(single_stno))
        singles.append(
            {
                "target_id": row_id,
                "family": row["family"],
                "audio_path": str(destination),
                "audio_sha256": sha256_file(destination),
                "activity_shape": [1, 1500],
                "activity_sha256": sha256_file(activity_path),
                "full_stno": stno_record(single_stno, "clean_target"),
                "prompt_arms": ["on", "off"] if row["family"] == "hike" else ["reference"],
            }
        )
    for control in source_plan["korean_clean_controls"]:
        destination = attempt / f"singles/{artifact_id(control['row_id'])}/audio.wav"
        source_samples = pcm16_from_wav(Path(control["audio_path"]))
        write_bytes_new(destination, wav_bytes(pad_single(source_samples)))
        activity = oracle_activity((Interval(0, len(source_samples)),))
        activity_path = destination.parent / "speaker_activity.u8"
        stno_path = destination.parent / "stno-full-clean-target.f32le"
        write_bytes_new(activity_path, activity.tobytes(order="C"))
        single_stno = target_stno(activity, 0)
        write_bytes_new(stno_path, encode_reference(single_stno))
        singles.append(
            {
                "target_id": control["row_id"],
                "family": "fleurs-ko-clean",
                "audio_path": str(destination),
                "audio_sha256": sha256_file(destination),
                "activity_shape": [1, 1500],
                "activity_sha256": sha256_file(activity_path),
                "full_stno": stno_record(single_stno, "clean_target"),
                "prompt_arms": ["absent-term-control"],
            }
        )
    status = enforce_korean_all_or_nothing(hike_eligibility, [str(row["row_id"]) for row in source_plan["hike_rows"]])
    result = {
        "schema_version": "1.0.0",
        "mixtures": mixtures,
        "geometry": geometry_records,
        "fleurs_selection": selection_record,
        "singles": singles,
        "korean_absent_terms": source_plan["korean_absent_terms"],
        "ami_parity_windows": source_plan["ami_parity_windows"],
        "korean_geometry": status,
        "source_hashes_after": _host_source_hashes(Path(str(source_plan["acceptance_root"]))),
        "fleurs_source_hashes_after": {
            str(path): sha256_file(Path(str(path)))
            for path in source_plan["fleurs_source_hashes_before"]
        },
    }
    if result["source_hashes_after"] != source_plan["source_hashes_before"]:
        raise PrepareError("read-only host input changed during preparation")
    if result["fleurs_source_hashes_after"] != source_plan["fleurs_source_hashes_before"]:
        raise PrepareError("read-only FLEURS input changed during preparation")
    write_json_new(attempt / "regions.json", result)
    return result


def seal_final(attempt: Path) -> dict[str, object]:
    regions = read_json(attempt / "regions.json")
    geometry_by_window = {record["window_id"]: record for record in regions["geometry"]}
    constructed = []
    for mixture in regions["mixtures"]:
        window_id = str(mixture["window_id"])
        community_path = attempt / "community" / window_id / "evidence.json"
        community = read_json(community_path)
        labels = list(community["labels"])
        provider_activity = (
            np.asarray(community["activity"], dtype=np.uint8).reshape(len(labels), 1500)
            if labels else np.zeros((0, 1500), dtype=np.uint8)
        )
        mixed = canonical_mix(
            pcm16_from_wav(_source_path(attempt, str(mixture["target_a"]))),
            pcm16_from_wav(_source_path(attempt, str(mixture["target_b"]))),
        )
        oracle = oracle_activity((mixed.support_a, mixed.support_b))
        mapping = freeze_mapping(labels, provider_activity.tolist(), [str(mixture["target_a"]), str(mixture["target_b"])], oracle.tolist())
        activity_dir = attempt / "activity" / window_id
        write_bytes_new(activity_dir / "speaker_activity.u8", oracle.tobytes(order="C"))
        write_bytes_new(activity_dir / "oracle.u8", oracle.tobytes(order="C"))
        write_bytes_new(activity_dir / "community1.u8", provider_activity.tobytes(order="C"))
        spurious = np.zeros((1, 1500), dtype=np.uint8)
        padded_start = (max(mixed.support_a.end, mixed.support_b.end) + 319) // 320
        if padded_start + 50 > 1500:
            raise PrepareError("constructed mixture has no one-second padded-silence spurious region")
        spurious[0, padded_start : padded_start + 50] = 1
        community_spurious = np.concatenate((provider_activity, spurious), axis=0)
        write_bytes_new(activity_dir / "community1-spurious.u8", community_spurious.tobytes(order="C"))
        geometry = geometry_by_window[window_id]
        clean_target_rows = [
            {
                "target_id": str(target["target_id"]),
                "oracle_row": index,
                "sha256": hashlib.sha256(oracle[index].tobytes(order="C")).hexdigest(),
            }
            for index, target in enumerate(geometry["targets"])
        ]
        activity_providers = {
            "oracle": {
                "path": str((activity_dir / "speaker_activity.u8").relative_to(attempt)),
                "shape": list(oracle.shape),
                "sha256": hashlib.sha256(oracle.tobytes()).hexdigest(),
            },
            "community1": {
                "path": str((activity_dir / "community1.u8").relative_to(attempt)),
                "shape": list(provider_activity.shape),
                "sha256": hashlib.sha256(provider_activity.tobytes()).hexdigest(),
            },
            "community1_spurious": {
                "path": str((activity_dir / "community1-spurious.u8").relative_to(attempt)),
                "shape": list(community_spurious.shape),
                "sha256": hashlib.sha256(community_spurious.tobytes()).hexdigest(),
            },
            "clean_target": {
                "derivation": "one sealed oracle target row per target",
                "target_rows": clean_target_rows,
            },
        }
        target_outputs = []
        suppress_korean_utility = (
            window_id.startswith("hike-")
            and regions["korean_geometry"]["status"] == "korean_geometry_unavailable"
        )
        for target_index, target in enumerate(geometry["targets"]):
            if suppress_korean_utility or not target["eligible"]:
                continue
            crop_data = target["geometry"]["crop"]
            crop_interval = Interval(int(crop_data["start"]), int(crop_data["end"]))
            from benchmarks.scripts.dicow.common.fixtures import k_frames

            frames = k_frames(crop_interval)
            oracle_mask = target_stno(oracle, target_index, frames)
            clean_mask = clean_target_stno(oracle[target_index], frames)
            target_track = mixed.component_a if target_index == 0 else mixed.component_b
            clean_crop = apply_crop(target_track, _geometry_object(target["geometry"]))
            mix_crop = apply_crop(mixed.mixture, _geometry_object(target["geometry"]))
            output_dir = attempt / "targets" / window_id / artifact_id(target["target_id"])
            write_bytes_new(output_dir / "clean-crop.wav", wav_bytes(clean_crop))
            write_bytes_new(output_dir / "mix-crop.wav", wav_bytes(mix_crop))
            write_bytes_new(output_dir / "stno-crop-oracle.f32le", encode_reference(oracle_mask))
            write_bytes_new(output_dir / "stno-crop-clean.f32le", encode_reference(clean_mask))
            full_oracle = target_stno(oracle, target_index)
            write_bytes_new(output_dir / "stno-full-reference.f32le", encode_reference(full_oracle))
            write_bytes_new(output_dir / "stno-full-oracle.f32le", encode_reference(full_oracle))
            swapped_oracle_mask = target_stno(oracle, 1 - target_index, frames)
            write_bytes_new(output_dir / "stno-crop-oracle-swapped.f32le", encode_reference(swapped_oracle_mask))
            slot = mapping["slots"][target_index]
            community_masks = {"status": slot["status"]}
            if slot["status"] == "mapped":
                provider_index = labels.index(slot["provider_label"])
                crop_community = target_stno(provider_activity, provider_index, frames)
                full_community = target_stno(provider_activity, provider_index)
                write_bytes_new(output_dir / "stno-crop-community1.f32le", encode_reference(crop_community))
                write_bytes_new(output_dir / "stno-full-community1.f32le", encode_reference(full_community))
                community_masks.update(
                    {
                        "crop": stno_record(crop_community, "community1"),
                        "full": stno_record(full_community, "community1"),
                    }
                )
            swapped_slot = mapping["slots"][1 - target_index]
            swapped = {
                "status": swapped_slot["status"],
                "K": [crop_interval.start, crop_interval.end],
                "clean_audio_sha256": sha256_file(output_dir / "clean-crop.wav"),
                "mix_audio_sha256": sha256_file(output_dir / "mix-crop.wav"),
            }
            if swapped_slot["status"] == "mapped":
                swapped_index = labels.index(swapped_slot["provider_label"])
                swapped_mask = target_stno(provider_activity, swapped_index, frames)
                write_bytes_new(output_dir / "stno-crop-community1-swapped.f32le", encode_reference(swapped_mask))
                swapped.update({"crop": stno_record(swapped_mask, "community1")})
            target_outputs.append(
                {
                    "target_id": target["target_id"],
                    "K": [crop_interval.start, crop_interval.end],
                    "k_frames_sha256": hashlib.sha256(frames.tobytes()).hexdigest(),
                    "audio_crop_gain": mixture["mix_gain"],
                    "post_crop_gain": 1.0,
                    "clean_audio_sha256": sha256_file(output_dir / "clean-crop.wav"),
                    "mix_audio_sha256": sha256_file(output_dir / "mix-crop.wav"),
                    "oracle_stno": stno_record(oracle_mask, "oracle"),
                    "reference_full_stno": stno_record(full_oracle, "oracle"),
                    "oracle_full_stno": stno_record(full_oracle, "oracle"),
                    "oracle_swapped_stno": {
                        "K": [crop_interval.start, crop_interval.end],
                        "clean_audio_sha256": sha256_file(output_dir / "clean-crop.wav"),
                        "mix_audio_sha256": sha256_file(output_dir / "mix-crop.wav"),
                        "crop": stno_record(swapped_oracle_mask, "oracle"),
                    },
                    "clean_stno": stno_record(clean_mask, "clean_target"),
                    "community1_stno": community_masks,
                    "community1_swapped_stno": swapped,
                }
            )
        spurious_mask = target_stno(community_spurious, community_spurious.shape[0] - 1)
        spurious_dir = attempt / "targets" / window_id / "SPURIOUS_PADDED_SILENCE"
        write_bytes_new(spurious_dir / "stno-full-community1-spurious.f32le", encode_reference(spurious_mask))
        constructed.append(
            {
                **mixture,
                "community1": {
                    "raw_stdout": str((community_path.parent / "stdout.txt").relative_to(attempt)),
                    "evidence_path": str(community_path.relative_to(attempt)),
                    "raw_evidence_sha256": sha256_file(community_path),
                    "labels": labels,
                    "activity_sha256": community["activity_sha256"],
                },
                "mapping": mapping,
                "activity_providers": activity_providers,
                "spurious_target": {
                    "target_id": "SPURIOUS_PADDED_SILENCE",
                    "frame_range": [padded_start, padded_start + 50],
                    "stno": stno_record(spurious_mask, "community1_spurious"),
                    "mapping_member": False,
                },
                "targets": target_outputs,
            }
        )
    manifest = {
        "schema_version": "1.0.0",
        "pack_id": "overlap-pack-v1",
        "constructed_mixtures": constructed,
        "mixture_count": len(constructed),
        "pair_target_count": 20,
        "aligner_row_count": 28,
        "aligner_process_count": 2,
        "community_process_count": 10,
        "korean_geometry": regions["korean_geometry"],
        "singles": regions["singles"],
        "single_count": len(regions["singles"]),
        "korean_absent_terms": regions["korean_absent_terms"],
        "ami_parity_windows": regions["ami_parity_windows"],
        "fleurs_selection": regions["fleurs_selection"],
        "source_hashes_before": read_json(attempt / "source-plan.json")["source_hashes_before"],
        "source_hashes_after": regions["source_hashes_after"],
        "fleurs_source_hashes_before": read_json(attempt / "source-plan.json")["fleurs_source_hashes_before"],
        "fleurs_source_hashes_after": regions["fleurs_source_hashes_after"],
    }
    write_json_new(attempt / "pack-manifest.json", manifest)
    write_pack_inventory(attempt)
    return manifest


def write_pack_inventory(root: Path) -> None:
    files = []
    directories = []
    for path in sorted(root.rglob("*"), key=lambda item: str(item.relative_to(root))):
        relative = path.relative_to(root).as_posix()
        if relative == "pack-inventory.json":
            continue
        if path.is_symlink():
            raise PrepareError(f"pack inventory rejects symlink: {relative}")
        if path.is_dir():
            directories.append(relative)
        elif path.is_file():
            files.append({"path": relative, "bytes": path.stat().st_size, "sha256": sha256_file(path)})
        else:
            raise PrepareError(f"pack inventory rejects unsupported entry: {relative}")
    inventory = {
        "schema_version": "overlap-pack-inventory-v1",
        "directories": directories,
        "files": files,
    }
    inventory["inventory_sha256"] = qwen_reference.canonical_json_hash(inventory)
    write_json_new(root / "pack-inventory.json", inventory)


def _geometry_object(value: Mapping[str, object]):
    from benchmarks.scripts.dicow.common.fixtures import CropGeometry

    return CropGeometry(
        overlap=Interval(**value["overlap"]),
        core=Interval(**value["core"]),
        crop=Interval(**value["crop"]),
        left_context=int(value["left_context"]),
        right_context=int(value["right_context"]),
    )


def _source_path(attempt: Path, row_id: str) -> Path:
    manifest = read_json(attempt / "aligner/ordered-manifest.json")
    matches = [Path(str(row["audio_path"])) for row in manifest["rows"] if row["row_id"] == row_id]
    if len(matches) != 1:
        raise PrepareError(f"cannot resolve frozen source row: {row_id}")
    return matches[0]


def _run(command: Sequence[str]) -> None:
    subprocess.run(command, cwd=REPOSITORY_ROOT, check=True)


def _launcher(env_file: Path, profile: str, shell: str) -> list[str]:
    return [
        sys.executable,
        "benchmarks/scripts/dicow/run_with_env.py",
        "--env-file",
        str(env_file),
        "--profile",
        profile,
        "--",
        "zsh",
        "-euc",
        shell,
    ]


def chmod_tree_read_only(root: Path) -> None:
    for directory, directory_names, file_names in os.walk(root, topdown=False):
        for name in file_names:
            os.chmod(Path(directory) / name, 0o444)
        for name in directory_names:
            os.chmod(Path(directory) / name, 0o555)
    os.chmod(root, 0o555)


def _tree_record(root: Path) -> dict[str, object]:
    from benchmarks.scripts.dicow.run_with_env import sealed_path_record

    return sealed_path_record(root, "tree")


def _selector_material(attempt: Path, record: Mapping[str, object]) -> tuple[dict[str, object], str]:
    canonical = {"pack_id": "overlap-pack-v1", "attempt": str(attempt), **record}
    fragment = (
        f"DICOW_PACK_ROOT={attempt}\n"
        f"DICOW_PACK_ROOT_SHA256={record['sha256']}\n"
        f"DICOW_PACK_ROOT_BYTES={record['bytes']}\n"
        f"DICOW_PACK_ROOT_MODE={record['mode']}\n"
    )
    return canonical, fragment


def _authenticate_regular(path: Path, expected_mode: int = 0o444) -> None:
    if path.is_symlink() or not path.is_file() or stat.S_IMODE(os.lstat(path).st_mode) != expected_mode:
        raise PrepareError(f"selector is not a sealed regular file: {path}")


def _selector_state(attempt: Path, artifact_root: Path, run_root: Path) -> tuple[str, dict[str, object]]:
    record = _tree_record(attempt)
    expected_canonical, expected_fragment = _selector_material(attempt, record)
    canonical = artifact_root / "canonical.json"
    fragment = run_root / "env.d/T10-pack.env"
    canonical_present = canonical.exists() or canonical.is_symlink()
    fragment_present = fragment.exists() or fragment.is_symlink()
    if fragment_present and not canonical_present:
        raise PrepareError("pack launcher fragment exists without its canonical selector")
    if canonical_present:
        _authenticate_regular(canonical)
        if read_json(canonical) != expected_canonical:
            raise PrepareError("pack canonical selector does not match the sealed attempt")
    if fragment_present:
        _authenticate_regular(fragment)
        if fragment.read_text(encoding="utf-8") != expected_fragment:
            raise PrepareError("pack launcher fragment does not match the sealed attempt")
    if fragment_present:
        return "complete", record
    if canonical_present:
        return "canonical-only", record
    return "absent", record


def publish(
    attempt: Path,
    artifact_root: Path,
    run_root: Path,
    *,
    expected_record: Mapping[str, object] | None = None,
    existing_canonical: bool = False,
) -> None:
    chmod_tree_read_only(attempt)
    record = _tree_record(attempt)
    if expected_record is not None and record != expected_record:
        raise PrepareError("sealed pack changed after verification")
    canonical = artifact_root / "canonical.json"
    fragment = run_root / "env.d/T10-pack.env"
    if (not existing_canonical and (canonical.exists() or canonical.is_symlink())) or fragment.exists() or fragment.is_symlink():
        raise PrepareError("refusing to replace a pack selector or environment fragment")
    if existing_canonical:
        state, current_record = _selector_state(attempt, artifact_root, run_root)
        if state != "canonical-only" or current_record != record:
            raise PrepareError("cannot resume an unauthenticated canonical-only publication")
    fragment.parent.mkdir(parents=True, exist_ok=True)
    canonical_value, content = _selector_material(attempt, record)
    canonical_temp = artifact_root / f".canonical.{os.getpid()}.tmp"
    fragment_temp = fragment.parent / f".T10-pack.{os.getpid()}.tmp"
    fragment_created = False
    canonical_created = False
    try:
        if not existing_canonical:
            write_json_new(canonical_temp, canonical_value)
        with fragment_temp.open("x", encoding="utf-8") as stream:
            stream.write(content)
        if not existing_canonical:
            os.chmod(canonical_temp, 0o444)
        os.chmod(fragment_temp, 0o444)
        if not existing_canonical:
            os.link(canonical_temp, canonical)
            canonical_created = True
        # The launcher fragment is the activation point.  Linking it last means
        # an interruption can leave only an inert canonical record, never a live
        # fragment that refers to a missing canonical selector.
        os.link(fragment_temp, fragment)
        fragment_created = True
    except BaseException:
        if canonical_created:
            canonical.unlink(missing_ok=True)
        if fragment_created:
            fragment.unlink(missing_ok=True)
        raise
    finally:
        canonical_temp.unlink(missing_ok=True)
        fragment_temp.unlink(missing_ok=True)


def _build_inputs(run_root: Path, env_file: Path) -> list[Path]:
    inputs = [run_root / "task-state/T2.json", run_root / "e0-preflight/canonical.json", env_file]
    hike_selection = ACCEPTANCE_ROOT / "prepared/hike-code-switch-v1/selection.json"
    if hike_selection.is_file():
        inputs.append(hike_selection)
    missing = [path for path in inputs if not path.is_file()]
    if missing:
        raise PrepareError(f"fingerprint input is missing: {missing[0]}")
    return inputs


def _run_pack_verifiers(env_file: Path, attempt: Path) -> None:
    _run(_launcher(env_file, "reference", f"uv run --locked --project benchmarks/env/dicow-reference python benchmarks/datasets/verify-overlap-pack-v1.py --pack {attempt}"))
    _run(_launcher(env_file, "aligner", f"env HF_HUB_OFFLINE=1 uv run --locked --project benchmarks/env/dicow-aligner python -m benchmarks.scripts.dicow.aligner.qwen_reference verify-pack --pack {attempt}"))
    _run(_launcher(env_file, "diarizer", f"python3 -m benchmarks.scripts.dicow.diarizer.community1_reference verify-pack --pack {attempt}"))


def build(env_file: Path) -> Path:
    run_root = Path(os.environ["DICOW_RUN_ROOT"])
    inputs = _build_inputs(run_root, env_file)
    fingerprint = source_fingerprint(inputs)
    artifact_root = run_root / "e1-overlap-pack"
    attempt = artifact_root / "attempts" / fingerprint
    if attempt.exists() or attempt.is_symlink():
        if attempt.is_symlink() or not attempt.is_dir():
            raise PrepareError("fingerprinted pack attempt is not a regular directory")
        state, record = _selector_state(attempt, artifact_root, run_root)
        if state == "absent":
            raise PrepareError("fingerprinted failed attempt is preserved without selectors")
        _run_pack_verifiers(env_file, attempt)
        if source_fingerprint(_build_inputs(run_root, env_file)) != fingerprint or _tree_record(attempt) != record:
            raise PrepareError("pack or fingerprint inputs changed during resume verification")
        if state == "canonical-only":
            publish(attempt, artifact_root, run_root, expected_record=record, existing_canonical=True)
        return attempt
    canonical = artifact_root / "canonical.json"
    fragment = run_root / "env.d/T10-pack.env"
    if canonical.exists() or canonical.is_symlink() or fragment.exists() or fragment.is_symlink():
        raise PrepareError("another pack selector is already published for this run")
    attempt.mkdir(parents=True)
    try:
        prepare_sources(attempt)
        snapshot = _find_hf_snapshot(
            "models--Qwen--Qwen3-ForcedAligner-0.6B",
            qwen_reference.MODEL_REVISION,
        )
        for repetition in (1, 2):
            _run(
                _launcher(
                    env_file,
                    "aligner",
                    "env HF_HUB_OFFLINE=1 uv run --locked --project benchmarks/env/dicow-aligner "
                    "python -m benchmarks.scripts.dicow.aligner.qwen_reference run-batch "
                    f"--manifest {attempt}/aligner/ordered-manifest.json --snapshot {snapshot} "
                    ' --preflight "$DICOW_RUN_ROOT/e0-preflight" '
                    f"--output {attempt}/aligner/repetition-{repetition}.json",
                )
            )
        regions = seal_regions(attempt)
        for mixture in regions["mixtures"]:
            window_id = str(mixture["window_id"])
            _run(
                _launcher(
                    env_file,
                    "diarizer",
                    "python3 -m benchmarks.scripts.dicow.diarizer.community1_reference run-one "
                    f"--binary \"$DICOW_SPEECH_BIN\" --audio {mixture['audio_path']} "
                    f"--output {attempt}/community/{window_id} --preflight \"$DICOW_RUN_ROOT/e0-preflight\"",
                )
            )
        seal_final(attempt)
        chmod_tree_read_only(attempt)
        sealed_record = _tree_record(attempt)
        _run_pack_verifiers(env_file, attempt)
        if source_fingerprint(_build_inputs(run_root, env_file)) != fingerprint:
            raise PrepareError("fingerprint inputs changed during pack verification")
        if _tree_record(attempt) != sealed_record:
            raise PrepareError("sealed pack changed during verification")
        publish(attempt, artifact_root, run_root, expected_record=sealed_record)
    except Exception:
        # The create-only attempt is failure evidence. Selectors stay absent.
        raise
    return attempt


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build_parser = commands.add_parser("build")
    build_parser.add_argument("--env-file", type=Path, required=True)
    verify_parser = commands.add_parser("verify")
    verify_parser.add_argument("--pack", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "build":
            print(build(args.env_file))
        else:
            from importlib.util import module_from_spec, spec_from_file_location

            spec = spec_from_file_location("overlap_verify", REPOSITORY_ROOT / "benchmarks/datasets/verify-overlap-pack-v1.py")
            module = module_from_spec(spec)
            assert spec and spec.loader
            spec.loader.exec_module(module)
            module.verify_pack(args.pack)
    except (PrepareError, FixtureError, qwen_reference.AlignerError, OSError, subprocess.CalledProcessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print(f"PASS: {args.command}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
