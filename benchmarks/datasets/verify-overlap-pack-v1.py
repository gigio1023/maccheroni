"""Independent read-only verifier for an external ``overlap-pack-v1`` tree."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import stat
import sys
import wave
from pathlib import Path
from typing import Mapping, Sequence

import numpy as np

from benchmarks.scripts.dicow.aligner import qwen_reference
from benchmarks.scripts.dicow.common.fixtures import (
    FixtureError,
    Interval,
    apply_crop,
    canonical_mix,
    classify_stable_words,
    enforce_korean_all_or_nothing,
    derive_absent_terms,
    oracle_activity,
    require_target_geometry,
    sha256_pcm16,
)
from benchmarks.scripts.dicow.common.stno import decode_reference, stno_record, target_stno
from benchmarks.scripts.dicow.diarizer import community1_reference


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
DECLARATION = REPOSITORY_ROOT / "benchmarks/datasets/overlap-pack-v1.json"


class VerifyError(RuntimeError):
    """The external pack cannot be recreated from its sealed evidence."""


def read_json(path: Path) -> dict[str, object]:
    def reject_constant(value: str) -> object:
        raise VerifyError(f"non-finite JSON number: {value}")

    try:
        value = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_unique_object,
            parse_constant=reject_constant,
        )
    except (OSError, json.JSONDecodeError) as error:
        raise VerifyError(f"invalid JSON: {path}") from error
    if not isinstance(value, dict):
        raise VerifyError(f"JSON root must be an object: {path}")
    return value


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise VerifyError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def artifact_id(value: object) -> str:
    return hashlib.sha256(str(value).encode("utf-8")).hexdigest()[:24]


def _inside(path: Path, root: Path) -> Path:
    root = root.resolve(strict=True)
    if not path.is_absolute() or os.path.normpath(str(path)) != str(path):
        raise VerifyError(f"pack path must be normalized and absolute: {path}")
    try:
        relative = path.relative_to(root)
    except ValueError as error:
        raise VerifyError(f"pack artifact escapes its root: {path}") from error
    current = root
    for part in relative.parts:
        current /= part
        try:
            mode = os.lstat(current).st_mode
        except OSError as error:
            raise VerifyError(f"pack artifact is missing: {current}") from error
        if stat.S_ISLNK(mode):
            raise VerifyError(f"pack path may not contain a symlink: {current}")
    resolved = path.resolve(strict=True)
    try:
        resolved.relative_to(root)
    except ValueError as error:
        raise VerifyError(f"pack artifact resolves outside its root: {path}") from error
    return resolved


def _read_pcm(path: Path) -> np.ndarray:
    from importlib.util import module_from_spec, spec_from_file_location

    prepare_path = REPOSITORY_ROOT / "benchmarks/datasets/prepare-overlap-pack-v1.py"
    spec = spec_from_file_location("overlap_prepare_verify", prepare_path)
    module = module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module.pcm16_from_wav(path)


def _pcm16_from_wav_payload(payload: bytes) -> np.ndarray:
    try:
        with wave.open(io.BytesIO(payload), "rb") as source:
            if source.getnchannels() != 1 or source.getframerate() != 16_000 or source.getsampwidth() != 2:
                raise VerifyError("FLEURS source WAV must be mono 16 kHz PCM16")
            frames = source.readframes(source.getnframes())
    except (wave.Error, EOFError) as error:
        raise VerifyError("FLEURS source row has invalid WAV audio") from error
    return np.frombuffer(frames, dtype="<i2").copy()


def _fleurs_audio_payload(value: object) -> bytes:
    if isinstance(value, dict) and isinstance(value.get("bytes"), bytes):
        return value["bytes"]
    if isinstance(value, bytes):
        return value
    raise VerifyError("FLEURS parquet audio row has no embedded WAV bytes")


def scan_fleurs_candidates(path: Path, locale: str, salt: str, count: int, *, include_locale: bool) -> list[dict[str, object]]:
    """Independently rederive a ranked public FLEURS pool from one parquet."""

    import pyarrow.parquet as pq

    parquet = pq.ParquetFile(path)
    names = set(parquet.schema_arrow.names)
    id_column = next((name for name in ("id", "row_id", "audio_id") if name in names), None)
    text_column = next((name for name in ("transcription", "raw_transcription", "text") if name in names), None)
    if id_column is None or text_column is None or "audio" not in names:
        raise VerifyError("FLEURS parquet schema lacks id, audio, or transcription")
    candidates = []
    for batch in parquet.iter_batches(columns=[id_column, "audio", text_column], batch_size=32):
        values = batch.to_pydict()
        for row_id, audio, text in zip(values[id_column], values["audio"], values[text_column]):
            payload = _fleurs_audio_payload(audio)
            samples = _pcm16_from_wav_payload(payload)
            duration = len(samples) / 16_000.0
            if not 4.0 <= duration <= 12.0:
                continue
            identity = str(row_id)
            rank = hashlib.sha256((salt + (locale if include_locale else "") + identity).encode()).hexdigest()
            candidates.append({
                "row_id": identity,
                "rank": rank,
                "text": str(text),
                "audio_payload": payload,
                "audio_sha256": hashlib.sha256(payload).hexdigest(),
                "source_samples": len(samples),
            })
    candidates.sort(key=lambda item: (item["rank"], item["row_id"]))
    if len(candidates) < count:
        raise VerifyError(f"{locale} has fewer than {count} duration-eligible FLEURS rows")
    return candidates[:count]


def verify_t9_fleurs_inputs(source_plan: Mapping[str, object], pack: Path) -> None:
    run_root_value = os.environ.get("DICOW_RUN_ROOT")
    run_id = os.environ.get("DICOW_RUN_ID")
    if not run_root_value or not run_id:
        raise VerifyError("launcher run binding is required for FLEURS verification")
    run_root = Path(run_root_value)
    canonical = read_json(run_root / "e0-preflight/canonical.json")
    if canonical.get("schema_version") != "dicow-e0-preflight-v1" or canonical.get("run_id") != run_id or canonical.get("run_root") != str(run_root):
        raise VerifyError("T9 canonical run binding differs during FLEURS verification")
    paths = canonical.get("paths")
    resource_policy = canonical.get("resource_policy")
    if not isinstance(paths, dict) or not isinstance(resource_policy, dict) or not isinstance(resource_policy.get("components"), list):
        raise VerifyError("T9 FLEURS resource binding is missing")
    components = [item for item in resource_policy["components"] if isinstance(item, dict) and item.get("name") == "fleurs_snapshot"]
    if len(components) != 1:
        raise VerifyError("T9 must bind exactly one FLEURS snapshot")
    component = components[0]
    snapshot = Path(str(paths.get("fleurs_snapshot", "")))
    if component.get("final_path") != str(snapshot) or not isinstance(component.get("expected_record"), dict):
        raise VerifyError("T9 FLEURS snapshot path or record is malformed")
    try:
        from benchmarks.scripts.dicow.common.preflight import artifact_record

        if artifact_record(snapshot, immutable=True) != component["expected_record"]:
            raise VerifyError("T9 FLEURS snapshot record changed")
    except VerifyError:
        raise
    except Exception as error:
        raise VerifyError(f"cannot authenticate T9 FLEURS snapshot: {error}") from error

    relative_paths = {
        locale: f"parquet-data/{locale}/test-00000-of-00001.parquet"
        for locale in ("en_us", "it_it", "ko_kr")
    }
    source_hashes = source_plan.get("fleurs_source_hashes_before")
    if not isinstance(source_hashes, dict) or len(source_hashes) != 3:
        raise VerifyError("FLEURS source hash set is incomplete")
    source_paths = {}
    for locale, relative in relative_paths.items():
        expected = (snapshot / relative).resolve(strict=True)
        matches = [Path(path) for path in source_hashes if Path(path).resolve(strict=True) == expected]
        if len(matches) != 1 or sha256_file(expected) != source_hashes[str(matches[0])]:
            raise VerifyError("FLEURS source payload does not match the T9 snapshot")
        source_paths[locale] = expected

    derived = {
        "en_us": scan_fleurs_candidates(source_paths["en_us"], "en_us", "maccheroni-overlap-pack-v1", 8, include_locale=True),
        "it_it": scan_fleurs_candidates(source_paths["it_it"], "it_it", "maccheroni-overlap-pack-v1", 8, include_locale=True),
        "ko_kr": scan_fleurs_candidates(source_paths["ko_kr"], "ko_kr", "maccheroni-overlap-pack-v1-clean-ko", 2, include_locale=False),
    }
    families = {"en_us": ("fleurs-en", "English"), "it_it": ("fleurs-it", "Italian")}
    frozen_rows = source_plan.get("fleurs_rows")
    if not isinstance(frozen_rows, dict):
        raise VerifyError("frozen FLEURS rows are missing")
    for locale, (family, language) in families.items():
        rows = frozen_rows.get(locale)
        if not isinstance(rows, list) or len(rows) != 8:
            raise VerifyError("frozen FLEURS candidate pool has the wrong size")
        for frozen, expected in zip(rows, derived[locale]):
            audio_path = _inside(Path(str(frozen.get("audio_path", ""))), pack)
            if (
                frozen.get("row_id") != expected["row_id"]
                or frozen.get("rank") != expected["rank"]
                or frozen.get("text") != expected["text"]
                or frozen.get("audio_sha256") != expected["audio_sha256"]
                or frozen.get("source_samples") != expected["source_samples"]
                or frozen.get("family") != family
                or frozen.get("language") != language
                or audio_path.read_bytes() != expected["audio_payload"]
            ):
                raise VerifyError("frozen FLEURS candidate row does not rederive from T9 parquet")
    controls = source_plan.get("korean_clean_controls")
    if not isinstance(controls, list) or len(controls) != 2:
        raise VerifyError("Korean clean controls are missing")
    for frozen, expected in zip(controls, derived["ko_kr"]):
        audio_path = _inside(Path(str(frozen.get("audio_path", ""))), pack)
        if (
            frozen.get("row_id") != expected["row_id"]
            or frozen.get("rank") != expected["rank"]
            or frozen.get("text") != expected["text"]
            or frozen.get("audio_sha256") != expected["audio_sha256"]
            or frozen.get("source_samples") != expected["source_samples"]
            or frozen.get("language") != "Korean"
            or audio_path.read_bytes() != expected["audio_payload"]
        ):
            raise VerifyError("Korean clean control does not rederive from T9 parquet")


def verify_hike_inputs(source_plan: Mapping[str, object], pack: Path) -> None:
    acceptance_root = Path(str(source_plan.get("acceptance_root", ""))).resolve(strict=True)
    declaration = read_json(REPOSITORY_ROOT / "benchmarks/datasets/acceptance-pack-v1.json")
    fixtures = declaration.get("fixtures")
    if not isinstance(fixtures, list):
        raise VerifyError("acceptance-pack declaration has no fixtures")
    hike_fixtures = [item for item in fixtures if isinstance(item, dict) and item.get("fixture_id") == "hike-code-switch-v1"]
    if len(hike_fixtures) != 1:
        raise VerifyError("acceptance-pack declaration has no unique HiKE fixture")
    pinned = hike_fixtures[0].get("selection", {}).get("pinned_subset")
    if not isinstance(pinned, list) or len(pinned) != 12:
        raise VerifyError("tracked HiKE pinned subset is malformed")
    selection_path = acceptance_root / "prepared/hike-code-switch-v1/selection.json"
    selection = read_json(selection_path)
    expected_keys = {"fixture_id", "items", "reference_text", "selection", "source", "term_source_sample_ids"}
    items = selection.get("items") if set(selection) == expected_keys and selection.get("fixture_id") == "hike-code-switch-v1" else None
    if not isinstance(items, list) or len(items) != 12:
        raise VerifyError("prepared HiKE selection has the wrong shape")
    expected_ids = [str(item["sample_id"]) for item in pinned]
    if [str(item.get("sample_id")) for item in items if isinstance(item, dict)] != expected_ids:
        raise VerifyError("prepared HiKE selection differs from the tracked pinned subset")
    rows = source_plan.get("hike_rows")
    if not isinstance(rows, list) or len(rows) != 12:
        raise VerifyError("frozen HiKE rows are missing")
    for item, row in zip(items, rows):
        if not isinstance(item, dict) or not isinstance(row, dict):
            raise VerifyError("HiKE selection row is malformed")
        item_wav = (acceptance_root / "prepared/hike-code-switch-v1" / str(item.get("item_wav", ""))).resolve(strict=True)
        try:
            item_wav.relative_to(acceptance_root)
        except ValueError as error:
            raise VerifyError("HiKE prepared WAV escapes the public acceptance root") from error
        copied_wav = _inside(Path(str(row.get("audio_path", ""))), pack)
        expected_terms = sorted({str(term["English"]) for term in item.get("loanwords", []) if isinstance(term, dict) and "English" in term})
        if (
            sha256_file(item_wav) != item.get("item_wav_sha256")
            or copied_wav.read_bytes() != item_wav.read_bytes()
            or row.get("row_id") != item.get("sample_id")
            or row.get("audio_sha256") != item.get("item_wav_sha256")
            or row.get("source_samples") != len(_read_pcm(item_wav))
            or row.get("text") != item.get("text_normalized")
            or row.get("terms") != expected_terms
            or row.get("family") != "hike"
            or row.get("language") != "Korean"
        ):
            raise VerifyError("frozen HiKE row does not reproduce the public acceptance selection")
    hike_source = acceptance_root / "sources/hike/data/test-00000-of-00001.parquet"
    source_hashes = source_plan.get("source_hashes_before")
    if not isinstance(source_hashes, dict) or source_hashes.get(str(hike_source)) != sha256_file(hike_source):
        raise VerifyError("HiKE public parquet hash differs from the sealed source plan")


def _geometry(value: Mapping[str, object]):
    from benchmarks.scripts.dicow.common.fixtures import CropGeometry

    return CropGeometry(
        overlap=Interval(**value["overlap"]),
        core=Interval(**value["core"]),
        crop=Interval(**value["crop"]),
        left_context=int(value["left_context"]),
        right_context=int(value["right_context"]),
    )


def _alignment_words(result: Mapping[str, object]) -> dict[str, list[dict[str, object]]]:
    rows = result.get("results")
    if not isinstance(rows, list):
        raise VerifyError("aligner result has no rows")
    return {str(row["row_id"]): list(row["words"]) for row in rows}


def _derive_pair_geometry(
    a: Mapping[str, object],
    b: Mapping[str, object],
    repetitions: Sequence[Mapping[str, list[dict[str, object]]]],
):
    mixed = canonical_mix(_read_pcm(Path(str(a["audio_path"]))), _read_pcm(Path(str(b["audio_path"]))))
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
                "words": [
                    {"text": word.text, "start": word.start, "end": word.end, "region": word.region}
                    for word in words
                ],
                "geometry": (
                    {
                        "overlap": {"start": geometry.overlap.start, "end": geometry.overlap.end},
                        "core": {"start": geometry.core.start, "end": geometry.core.end},
                        "crop": {"start": geometry.crop.start, "end": geometry.crop.end},
                        "left_context": geometry.left_context,
                        "right_context": geometry.right_context,
                    }
                    if geometry
                    else None
                ),
            }
        )
    return mixed, targets


def _derive_fleurs_selection(
    source_plan: Mapping[str, object],
    repetitions: Sequence[Mapping[str, list[dict[str, object]]]],
) -> tuple[list[tuple[str, str]], list[dict[str, object]]]:
    selected_pairs = []
    attempts = []
    for locale in ("en_us", "it_it"):
        queue = list(source_plan["fleurs_rows"][locale])
        selected = 0
        while selected < 2:
            if len(queue) < 2:
                raise VerifyError(f"{locale} independently exhausts its eight-row pool")
            a, b = queue[0], queue[1]
            _, targets = _derive_pair_geometry(a, b, repetitions)
            eligibility = [bool(target["eligible"]) for target in targets]
            attempts.append(
                {
                    "locale": locale,
                    "a": a["row_id"],
                    "b": b["row_id"],
                    "role_order": "A-then-B",
                    "eligibility": eligibility,
                    "exclusions": [target["target_id"] for target in targets if not target["eligible"]],
                }
            )
            if all(eligibility):
                selected_pairs.append((str(a["row_id"]), str(b["row_id"])))
                del queue[:2]
                selected += 1
            else:
                if not eligibility[0]:
                    queue.remove(a)
                if not eligibility[1]:
                    queue.remove(b)
    return selected_pairs, attempts


def derive_reference_contract(
    source_plan: Mapping[str, object],
    mixtures: Sequence[Mapping[str, object]],
    aligner_manifest: Mapping[str, object],
    first: Mapping[str, object],
    second: Mapping[str, object],
) -> dict[str, object]:
    qwen_reference.validate_result_set(aligner_manifest, first)
    qwen_reference.validate_result_set(aligner_manifest, second)
    qwen_reference.require_consistent_repetitions(first, second)
    repetitions = (_alignment_words(first), _alignment_words(second))
    selected_pairs, attempts = _derive_fleurs_selection(source_plan, repetitions)
    candidate_manifests = source_plan.get("fleurs_candidate_manifests")
    if not isinstance(candidate_manifests, dict) or set(candidate_manifests) != {"en_us", "it_it"}:
        raise VerifyError("FLEURS candidate manifests are missing")
    fleurs_rows = source_plan.get("fleurs_rows")
    if not isinstance(fleurs_rows, dict):
        raise VerifyError("FLEURS candidate pools are missing")
    for locale in ("en_us", "it_it"):
        locale_rows = fleurs_rows.get(locale)
        if not isinstance(locale_rows, list) or len(locale_rows) != 8:
            raise VerifyError("FLEURS candidate pool must contain eight rows per locale")
        expected_ranks = [
            hashlib.sha256(("maccheroni-overlap-pack-v1" + locale + str(row["row_id"])).encode()).hexdigest()
            for row in locale_rows
        ]
        if (
            [row.get("rank") for row in locale_rows] != expected_ranks
            or expected_ranks != sorted(expected_ranks)
            or any(not 4.0 <= int(row["source_samples"]) / 16_000.0 <= 12.0 for row in locale_rows)
        ):
            raise VerifyError("FLEURS candidate rank or duration rule does not reproduce")
        expected_candidate = {
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
        expected_candidate["candidate_manifest_sha256"] = qwen_reference.canonical_json_hash(expected_candidate)
        if candidate_manifests.get(locale) != expected_candidate:
            raise VerifyError("FLEURS candidate manifest hash does not reproduce")
    selection = {"attempts": attempts}
    selection["selection_sha256"] = qwen_reference.canonical_json_hash(selection)
    rows = {str(row["row_id"]): row for row in aligner_manifest["rows"]}
    geometry = {}
    for mixture in mixtures:
        window_id = str(mixture["window_id"])
        _, targets = _derive_pair_geometry(
            rows[str(mixture["target_a"])], rows[str(mixture["target_b"])], repetitions
        )
        geometry[window_id] = {"window_id": window_id, "targets": targets}
    return {
        "repetitions": repetitions,
        "fleurs_pairs": selected_pairs,
        "fleurs_selection": selection,
        "geometry": geometry,
    }


def verify_frozen_reference_contract(
    derived: Mapping[str, object],
    regions: Mapping[str, object],
    manifest: Mapping[str, object],
    mixtures: Sequence[Mapping[str, object]],
) -> None:
    actual_pairs = [
        (str(record["target_a"]), str(record["target_b"]))
        for record in mixtures
        if str(record["window_id"]).startswith("fleurs-")
    ]
    if actual_pairs != derived.get("fleurs_pairs"):
        raise VerifyError("FLEURS survivor selection does not reproduce")
    if manifest.get("fleurs_selection") != derived.get("fleurs_selection"):
        raise VerifyError("FLEURS selection evidence or hash does not reproduce")
    frozen_geometry = {
        str(record["window_id"]): record for record in regions.get("geometry", [])
    }
    if frozen_geometry != derived.get("geometry"):
        raise VerifyError("stable regions, exclusions, or K do not independently reproduce")


def verify_frozen_mapping(
    frozen: object,
    labels: Sequence[str],
    provider_activity: Sequence[Sequence[int]],
    reference_ids: Sequence[str],
    reference_activity: Sequence[Sequence[int]],
) -> dict[str, object]:
    expected = community1_reference.freeze_mapping(
        labels, provider_activity, reference_ids, reference_activity
    )
    if frozen != expected:
        raise VerifyError("frozen Community mapping does not independently reproduce")
    return expected


def _pack_relative(path_value: object, pack: Path) -> str:
    path = Path(str(path_value))
    if not path.is_absolute():
        if os.path.normpath(str(path)) != str(path) or ".." in path.parts:
            raise VerifyError(f"pack-relative path is not normalized: {path}")
        path = pack / path
    return _inside(path, pack).relative_to(pack).as_posix()


def _expected_pack_files(
    pack: Path,
    source_plan: Mapping[str, object],
    regions: Mapping[str, object],
    manifest: Mapping[str, object],
) -> set[str]:
    expected = {
        "aligner/ordered-manifest.json",
        "aligner/repetition-1.json",
        "aligner/repetition-2.json",
        "pack-manifest.json",
        "regions.json",
        "source-plan.json",
    }
    aligner = read_json(pack / "aligner/ordered-manifest.json")
    for row in aligner.get("rows", []):
        expected.add(_pack_relative(row["audio_path"], pack))
    for control in source_plan.get("korean_clean_controls", []):
        expected.add(_pack_relative(control["audio_path"], pack))
    for item in source_plan.get("ami_parity_windows", []):
        expected.add(_pack_relative(item["audio_path"], pack))
    for single in manifest.get("singles", []):
        audio = _pack_relative(single["audio_path"], pack)
        expected.add(audio)
        parent = Path(audio).parent
        expected.add((parent / "speaker_activity.u8").as_posix())
        expected.add((parent / "stno-full-clean-target.f32le").as_posix())

    acceptance_root = Path(str(source_plan.get("acceptance_root", "")))
    try:
        acceptance_relative = acceptance_root.relative_to(pack)
    except ValueError:
        acceptance_relative = None
    if acceptance_relative is not None:
        public_files = {
            "sources/hike/data/test-00000-of-00001.parquet",
            "sources/ami/IN1009.Mix-Headset.wav",
            "sources/ami/ami_public_manual_1.6.2.zip",
            "prepared/hike-code-switch-v1/fixture-check.json",
            "prepared/hike-code-switch-v1/glossary.txt",
            "prepared/hike-code-switch-v1/input.wav",
            "prepared/hike-code-switch-v1/terms.json",
            "prepared/hike-code-switch-v1/selection.json",
            "prepared/hike-code-switch-v1/reference.segments.json",
            "prepared/ami-in1009-ihm-mix-v1/fixture-check.json",
            "prepared/ami-in1009-ihm-mix-v1/reference.rttm",
            "prepared/ami-in1009-ihm-mix-v1/glossary.txt",
            "prepared/ami-in1009-ihm-mix-v1/terms.json",
            "prepared/ami-in1009-ihm-mix-v1/selection.json",
            "prepared/ami-in1009-ihm-mix-v1/reference.segments.json",
        }
        public_files.update(f"prepared/hike-code-switch-v1/items/{index:02d}.wav" for index in range(12))
        expected.update((acceptance_relative / relative).as_posix() for relative in public_files)

    geometry = {str(item["window_id"]): item for item in regions.get("geometry", [])}
    korean_unavailable = manifest.get("korean_geometry", {}).get("status") == "korean_geometry_unavailable"
    for mixture in manifest.get("constructed_mixtures", []):
        window_id = str(mixture["window_id"])
        expected.add(_pack_relative(mixture["audio_path"], pack))
        evidence = Path(_pack_relative(mixture["community1"]["evidence_path"], pack))
        expected.update({evidence.as_posix(), (evidence.parent / "stdout.txt").as_posix(), (evidence.parent / "stderr.txt").as_posix()})
        activity = Path("activity") / window_id
        expected.update(
            (activity / name).as_posix()
            for name in ("speaker_activity.u8", "oracle.u8", "community1.u8", "community1-spurious.u8")
        )
        slots = mixture.get("mapping", {}).get("slots", [])
        targets = geometry.get(window_id, {}).get("targets", [])
        for index, target in enumerate(targets):
            if (window_id.startswith("hike-") and korean_unavailable) or not target.get("eligible"):
                continue
            base = Path("targets") / window_id / artifact_id(target["target_id"])
            expected.update(
                (base / name).as_posix()
                for name in (
                    "clean-crop.wav", "mix-crop.wav", "stno-crop-oracle.f32le",
                    "stno-crop-clean.f32le", "stno-full-reference.f32le",
                    "stno-full-oracle.f32le", "stno-crop-oracle-swapped.f32le",
                )
            )
            if len(slots) == 2 and slots[index].get("status") == "mapped":
                expected.update({(base / "stno-crop-community1.f32le").as_posix(), (base / "stno-full-community1.f32le").as_posix()})
            if len(slots) == 2 and slots[1 - index].get("status") == "mapped":
                expected.add((base / "stno-crop-community1-swapped.f32le").as_posix())
        expected.add((Path("targets") / window_id / "SPURIOUS_PADDED_SILENCE/stno-full-community1-spurious.f32le").as_posix())
    return expected


def verify_pack_inventory(
    pack: Path,
    source_plan: Mapping[str, object],
    regions: Mapping[str, object],
    manifest: Mapping[str, object],
) -> dict[str, object]:
    inventory = read_json(pack / "pack-inventory.json")
    if set(inventory) != {"schema_version", "directories", "files", "inventory_sha256"}:
        raise VerifyError("pack inventory has an unexpected shape")
    if inventory.get("schema_version") != "overlap-pack-inventory-v1":
        raise VerifyError("pack inventory schema changed")
    hashable = {key: value for key, value in inventory.items() if key != "inventory_sha256"}
    if qwen_reference.canonical_json_hash(hashable) != inventory.get("inventory_sha256"):
        raise VerifyError("pack inventory hash changed")
    actual_files = []
    actual_directories = []
    for path in sorted(pack.rglob("*"), key=lambda item: str(item.relative_to(pack))):
        relative = path.relative_to(pack).as_posix()
        if relative == "pack-inventory.json":
            continue
        mode = os.lstat(path).st_mode
        if stat.S_ISLNK(mode):
            raise VerifyError(f"pack inventory rejects symlink: {relative}")
        if stat.S_ISDIR(mode):
            actual_directories.append(relative)
        elif stat.S_ISREG(mode):
            actual_files.append({"path": relative, "bytes": path.stat().st_size, "sha256": sha256_file(path)})
        else:
            raise VerifyError(f"pack inventory rejects unsupported entry: {relative}")
    if inventory.get("files") != actual_files or inventory.get("directories") != actual_directories:
        raise VerifyError("pack inventory no longer matches the sealed tree")
    expected_files = _expected_pack_files(pack, source_plan, regions, manifest)
    if {item["path"] for item in actual_files} != expected_files:
        raise VerifyError("pack inventory contains a missing or unexpected artifact")
    expected_directories = sorted(
        {
            parent.as_posix()
            for relative in expected_files
            for parent in Path(relative).parents
            if parent != Path(".")
        }
    )
    if actual_directories != expected_directories:
        raise VerifyError("pack inventory contains a missing or unexpected directory")
    return inventory


def verify_published_binding(pack: Path) -> dict[str, object] | None:
    published = os.environ.get("DICOW_PACK_ROOT")
    if published is None:
        return None
    if published != str(pack) or Path(published) != pack:
        raise VerifyError("DICOW_PACK_ROOT does not name the verified pack")
    run_value = os.environ.get("DICOW_RUN_ROOT")
    if not run_value:
        raise VerifyError("published pack verification requires DICOW_RUN_ROOT")
    run_root = Path(run_value).resolve(strict=True)
    expected_parent = run_root / "e1-overlap-pack/attempts"
    if pack.parent != expected_parent or len(pack.name) != 64 or any(character not in "0123456789abcdef" for character in pack.name):
        raise VerifyError("published pack is not a fingerprint-named E1 attempt")
    from importlib.util import module_from_spec, spec_from_file_location

    prepare_path = REPOSITORY_ROOT / "benchmarks/datasets/prepare-overlap-pack-v1.py"
    spec = spec_from_file_location("overlap_prepare_published", prepare_path)
    module = module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    run_manifest_path = run_root / "run-manifest.json"
    if (
        run_manifest_path.is_symlink()
        or not run_manifest_path.is_file()
        or stat.S_IMODE(os.lstat(run_manifest_path).st_mode) != 0o444
    ):
        raise VerifyError("published pack run manifest is not a sealed regular file")
    run_manifest = read_json(run_manifest_path)
    if run_manifest.get("schema_version") not in {
        "dicow-run-manifest-v1", "dicow-r2-run-manifest-v1",
    }:
        raise VerifyError("published pack run manifest has the wrong schema")
    base_env = run_manifest.get("base_env")
    if not isinstance(base_env, dict) or set(base_env) != {
        "path", "sha256", "bytes", "mode", "keys",
    }:
        raise VerifyError("published pack run manifest has no exact base env record")
    env_file = Path(str(base_env.get("path", "")))
    if (
        not env_file.is_absolute()
        or os.path.normpath(str(env_file)) != str(env_file)
        or env_file.is_symlink()
        or not env_file.is_file()
        or stat.S_IMODE(os.lstat(env_file).st_mode) != 0o444
        or sha256_file(env_file) != base_env.get("sha256")
        or env_file.stat().st_size != base_env.get("bytes")
        or base_env.get("mode") != "0444"
    ):
        raise VerifyError("published pack base env differs from its run manifest")
    inputs = module._build_inputs(run_root, env_file)
    fingerprint = module.source_fingerprint(inputs)
    if fingerprint != pack.name:
        raise VerifyError("published pack fingerprint does not reproduce")
    from benchmarks.scripts.dicow.run_with_env import sealed_path_record

    record = sealed_path_record(pack, "tree")
    canonical_path = run_root / "e1-overlap-pack/canonical.json"
    fragment_path = run_root / "env.d/T10-pack.env"
    for path in (canonical_path, fragment_path):
        if path.is_symlink() or not path.is_file() or stat.S_IMODE(os.lstat(path).st_mode) != 0o444:
            raise VerifyError(f"published selector is not a sealed regular file: {path}")
    expected_canonical = {"pack_id": "overlap-pack-v1", "attempt": str(pack), **record}
    if read_json(canonical_path) != expected_canonical:
        raise VerifyError("published canonical selector does not match the pack")
    expected_fragment = (
        f"DICOW_PACK_ROOT={pack}\n"
        f"DICOW_PACK_ROOT_SHA256={record['sha256']}\n"
        f"DICOW_PACK_ROOT_BYTES={record['bytes']}\n"
        f"DICOW_PACK_ROOT_MODE={record['mode']}\n"
    )
    if fragment_path.read_text(encoding="utf-8") != expected_fragment:
        raise VerifyError("published launcher fragment does not match the pack")
    expected_environment = {
        "DICOW_PACK_ROOT_SHA256": str(record["sha256"]),
        "DICOW_PACK_ROOT_BYTES": str(record["bytes"]),
        "DICOW_PACK_ROOT_MODE": str(record["mode"]),
    }
    if any(os.environ.get(key) != value for key, value in expected_environment.items()):
        raise VerifyError("published launcher environment does not match the selector")
    return {"fingerprint": fingerprint, "record": record}


def verify_pack(pack: Path) -> None:
    pack = pack.resolve(strict=True)
    published_binding = verify_published_binding(pack)
    declaration = read_json(DECLARATION)
    if declaration.get("pack_id") != "overlap-pack-v1":
        raise VerifyError("tracked pack declaration has the wrong identity")
    manifest = read_json(pack / "pack-manifest.json")
    source_plan = read_json(pack / "source-plan.json")
    regions = read_json(pack / "regions.json")
    verify_pack_inventory(pack, source_plan, regions, manifest)
    if manifest.get("pack_id") != "overlap-pack-v1":
        raise VerifyError("external pack has the wrong identity")
    expected_scalars = {
        "mixture_count": 10,
        "pair_target_count": 20,
        "aligner_row_count": 28,
        "aligner_process_count": 2,
        "community_process_count": 10,
        "single_count": 22,
    }
    for key, expected in expected_scalars.items():
        if manifest.get(key) != expected:
            raise VerifyError(f"pack {key} must equal {expected}")
    mixtures = manifest.get("constructed_mixtures")
    if not isinstance(mixtures, list) or len(mixtures) != 10:
        raise VerifyError("pack must contain ten mixtures")
    ids = [record.get("window_id") if isinstance(record, dict) else None for record in mixtures]
    if len(set(ids)) != 10 or ids[:6] != [f"hike-{index:02d}" for index in range(6)]:
        raise VerifyError("mixture identities or fixed HiKE order changed")
    if sum(str(item).startswith("fleurs-en-") for item in ids) != 2 or sum(str(item).startswith("fleurs-it-") for item in ids) != 2:
        raise VerifyError("FLEURS locale strata must each contain two pairs")

    aligner_manifest = read_json(pack / "aligner/ordered-manifest.json")
    first = read_json(pack / "aligner/repetition-1.json")
    second = read_json(pack / "aligner/repetition-2.json")
    for row in aligner_manifest.get("rows", []):
        if not isinstance(row, dict):
            raise VerifyError("aligner source row must be an object")
        _inside(Path(str(row.get("audio_path", ""))), pack)
    for control in source_plan.get("korean_clean_controls", []):
        if not isinstance(control, dict):
            raise VerifyError("Korean clean control must be an object")
        _inside(Path(str(control.get("audio_path", ""))), pack)
    verify_hike_inputs(source_plan, pack)
    verify_t9_fleurs_inputs(source_plan, pack)
    derived_contract = derive_reference_contract(source_plan, mixtures, aligner_manifest, first, second)
    verify_frozen_reference_contract(derived_contract, regions, manifest, mixtures)
    repetitions = derived_contract["repetitions"]
    selected_pairs = derived_contract["fleurs_pairs"]
    actual_fleurs_pairs = [
        (str(record["target_a"]), str(record["target_b"]))
        for record in mixtures
        if str(record["window_id"]).startswith("fleurs-")
    ]
    if actual_fleurs_pairs != selected_pairs:
        raise VerifyError("FLEURS survivor selection does not reproduce")
    expected_selection = derived_contract["fleurs_selection"]
    if expected_selection != manifest.get("fleurs_selection"):
        raise VerifyError("FLEURS selection evidence or hash does not reproduce")

    source_rows = {str(row["row_id"]): row for row in aligner_manifest["rows"]}
    geometry_by_window = {str(item["window_id"]): item for item in regions["geometry"]}
    hike_eligibility = {}
    for record in mixtures:
        window_id = str(record["window_id"])
        a = source_rows[str(record["target_a"])]
        b = source_rows[str(record["target_b"])]
        a_path = _inside(Path(str(a["audio_path"])), pack)
        b_path = _inside(Path(str(b["audio_path"])), pack)
        mixed = canonical_mix(_read_pcm(a_path), _read_pcm(b_path))
        derived_mixed, derived_targets = _derive_pair_geometry(a, b, repetitions)
        if sha256_pcm16(derived_mixed.mixture) != sha256_pcm16(mixed.mixture):
            raise VerifyError("independent pair mixer disagreement")
        if (
            mixed.source_a_samples != record["source_a_samples"]
            or mixed.source_b_samples != record["source_b_samples"]
            or mixed.overlap_samples != record["overlap_samples"]
            or mixed.b_start != record["b_start"]
            or mixed.normalization_gain_a != record["normalization_gain_a"]
            or mixed.normalization_gain_b != record["normalization_gain_b"]
            or mixed.mix_gain != record["mix_gain"]
            or sha256_pcm16(mixed.mixture) != record["mixture_pcm_sha256"]
            or mixed.pre_quantization_peak_a != record["pre_quantization_peak_a"]
            or mixed.pre_quantization_peak_b != record["pre_quantization_peak_b"]
            or mixed.pre_quantization_mix_peak != record["pre_quantization_mix_peak"]
            or mixed.post_quantization_peak_a != record["post_quantization_peak_a"]
            or mixed.post_quantization_peak_b != record["post_quantization_peak_b"]
            or mixed.post_quantization_mix_peak != record["post_quantization_mix_peak"]
            or mixed.formula_version != record["formula_version"]
            or sha256_pcm16(mixed.component_a) != record["component_a_sha256"]
            or sha256_pcm16(mixed.component_b) != record["component_b_sha256"]
        ):
            raise VerifyError(f"canonical mixer does not reproduce {window_id}")
        audio_path = _inside(Path(str(record["audio_path"])), pack)
        if sha256_file(audio_path) != record["audio_sha256"] or not np.array_equal(_read_pcm(audio_path), mixed.mixture):
            raise VerifyError(f"sealed mixture bytes do not reproduce {window_id}")

        geometry = geometry_by_window.get(window_id)
        if not isinstance(geometry, dict) or len(geometry.get("targets", [])) != 2:
            raise VerifyError(f"{window_id} has no two-target geometry")
        if geometry != derived_contract["geometry"][window_id] or geometry["targets"] != derived_targets:
            raise VerifyError(f"stable regions or K do not independently reproduce for {window_id}")
        if window_id.startswith("hike-"):
            hike_eligibility.update({str(item["target_id"]): bool(item["eligible"]) for item in geometry["targets"]})
        oracle = oracle_activity((mixed.support_a, mixed.support_b))
        activity_dir = pack / "activity" / window_id
        if (activity_dir / "speaker_activity.u8").read_bytes() != oracle.tobytes(order="C"):
            raise VerifyError("sealed speaker_activity.u8 does not reproduce")
        if (activity_dir / "oracle.u8").read_bytes() != oracle.tobytes(order="C"):
            raise VerifyError("oracle activity does not reproduce")
        provider_records = record.get("activity_providers")
        oracle_record = provider_records.get("oracle") if isinstance(provider_records, dict) else None
        if oracle_record != {
            "path": str((activity_dir / "speaker_activity.u8").relative_to(pack)),
            "shape": list(oracle.shape),
            "sha256": hashlib.sha256(oracle.tobytes(order="C")).hexdigest(),
        }:
            raise VerifyError("oracle activity provider record does not reproduce")
        evidence = read_json(pack / str(record["community1"]["evidence_path"]))
        labels = list(evidence["labels"])
        provider_activity = (
            np.asarray(evidence["activity"], dtype=np.uint8).reshape(len(labels), 1500)
            if labels else np.zeros((0, 1500), dtype=np.uint8)
        )
        if (activity_dir / "community1.u8").read_bytes() != provider_activity.tobytes(order="C"):
            raise VerifyError("Community activity does not reproduce")
        if provider_records.get("community1") != {
            "path": str((activity_dir / "community1.u8").relative_to(pack)),
            "shape": list(provider_activity.shape),
            "sha256": hashlib.sha256(provider_activity.tobytes(order="C")).hexdigest(),
        }:
            raise VerifyError("Community activity provider record does not reproduce")
        expected_mapping = verify_frozen_mapping(
            record.get("mapping"), labels, provider_activity.tolist(),
            [str(record["target_a"]), str(record["target_b"])], oracle.tolist()
        )
        suppress_korean_utility = (
            window_id.startswith("hike-")
            and regions["korean_geometry"]["status"] == "korean_geometry_unavailable"
        )
        if suppress_korean_utility and record.get("targets") != []:
            raise VerifyError("korean_geometry_unavailable retained partial HiKE utility targets")
        for target_index, target in enumerate(geometry["targets"]):
            if suppress_korean_utility or not target["eligible"]:
                continue
            target_record = next((item for item in record["targets"] if item["target_id"] == target["target_id"]), None)
            if not isinstance(target_record, dict):
                raise VerifyError("eligible target output is missing")
            geometry_object = _geometry(derived_targets[target_index]["geometry"])
            output_dir = pack / "targets" / window_id / artifact_id(target["target_id"])
            clean_path = output_dir / "clean-crop.wav"
            mix_path = output_dir / "mix-crop.wav"
            source_track = mixed.component_a if target_index == 0 else mixed.component_b
            if not np.array_equal(_read_pcm(clean_path), apply_crop(source_track, geometry_object)):
                raise VerifyError("clean crop does not reproduce")
            if not np.array_equal(_read_pcm(mix_path), apply_crop(mixed.mixture, geometry_object)):
                raise VerifyError("mixture crop does not reproduce")
            crop = geometry_object.crop
            from benchmarks.scripts.dicow.common.fixtures import k_frames

            frames = k_frames(crop)
            if (
                target_record.get("K") != [crop.start, crop.end]
                or target_record.get("k_frames_sha256") != hashlib.sha256(frames.tobytes(order="C")).hexdigest()
            ):
                raise VerifyError("target K or k_frames record does not reproduce")
            oracle_mask = target_stno(oracle, target_index, frames)
            sealed_mask = decode_reference((output_dir / "stno-crop-oracle.f32le").read_bytes())
            if not np.array_equal(sealed_mask, oracle_mask):
                raise VerifyError("oracle crop STNO does not reproduce")
            if target_record.get("oracle_stno") != stno_record(sealed_mask, "oracle"):
                raise VerifyError("oracle crop STNO record does not reproduce")
            full_oracle = decode_reference((output_dir / "stno-full-oracle.f32le").read_bytes())
            if not np.array_equal(full_oracle, target_stno(oracle, target_index)):
                raise VerifyError("full oracle STNO does not reproduce")
            if target_record.get("oracle_full_stno") != stno_record(full_oracle, "oracle"):
                raise VerifyError("full oracle STNO record does not reproduce")
            full_reference = decode_reference((output_dir / "stno-full-reference.f32le").read_bytes())
            if not np.array_equal(full_reference, full_oracle):
                raise VerifyError("full reference STNO does not reproduce")
            if target_record.get("reference_full_stno") != stno_record(full_reference, "oracle"):
                raise VerifyError("full reference STNO record does not reproduce")
            swapped_oracle = decode_reference((output_dir / "stno-crop-oracle-swapped.f32le").read_bytes())
            if not np.array_equal(swapped_oracle, target_stno(oracle, 1 - target_index, frames)):
                raise VerifyError("swapped oracle crop STNO does not reproduce")
            oracle_swap_record = target_record.get("oracle_swapped_stno")
            if (
                not isinstance(oracle_swap_record, dict)
                or oracle_swap_record.get("K") != target_record["K"]
                or oracle_swap_record.get("clean_audio_sha256") != target_record["clean_audio_sha256"]
                or oracle_swap_record.get("mix_audio_sha256") != target_record["mix_audio_sha256"]
                or oracle_swap_record.get("crop") != stno_record(swapped_oracle, "oracle")
            ):
                raise VerifyError("swapped oracle arm changed K or paired audio")
            if np.any(sealed_mask[1:, frames == 0]) or np.any(sealed_mask[0, frames == 0] != 1):
                raise VerifyError("crop STNO is not exact silence outside K")
            clean_mask = decode_reference((output_dir / "stno-crop-clean.f32le").read_bytes())
            if np.any(clean_mask[2:]):
                raise VerifyError("clean crop STNO contains non-target or overlap")
            expected_clean = target_stno(oracle[target_index].reshape(1, 1500), 0, frames)
            if not np.array_equal(clean_mask, expected_clean) or target_record.get("clean_stno") != stno_record(clean_mask, "clean_target"):
                raise VerifyError("clean crop STNO does not reproduce")
            if target_record.get("audio_crop_gain") != record["mix_gain"] or target_record.get("post_crop_gain") != 1.0:
                raise VerifyError("crop gain contract changed")
            if (
                sha256_file(clean_path) != target_record.get("clean_audio_sha256")
                or sha256_file(mix_path) != target_record.get("mix_audio_sha256")
            ):
                raise VerifyError("crop audio hashes do not reproduce")
            slot = expected_mapping["slots"][target_index]
            if slot["status"] == "mapped":
                provider_index = labels.index(slot["provider_label"])
                sealed_community = decode_reference((output_dir / "stno-crop-community1.f32le").read_bytes())
                full_community = decode_reference((output_dir / "stno-full-community1.f32le").read_bytes())
                community_record = target_record.get("community1_stno")
                if (
                    not np.array_equal(sealed_community, target_stno(provider_activity, provider_index, frames))
                    or not np.array_equal(full_community, target_stno(provider_activity, provider_index))
                    or community_record != {
                        "status": "mapped",
                        "crop": stno_record(sealed_community, "community1"),
                        "full": stno_record(full_community, "community1"),
                    }
                ):
                    raise VerifyError("Community crop STNO does not reproduce")
            else:
                if target_record.get("community1_stno") != {"status": "ABSENT"}:
                    raise VerifyError("ABSENT Community slot has a mask record")
                if (output_dir / "stno-crop-community1.f32le").exists() or (output_dir / "stno-full-community1.f32le").exists():
                    raise VerifyError("ABSENT Community slot has materialized masks")
            swapped = target_record["community1_swapped_stno"]
            if swapped["K"] != target_record["K"] or swapped["clean_audio_sha256"] != target_record["clean_audio_sha256"] or swapped["mix_audio_sha256"] != target_record["mix_audio_sha256"]:
                raise VerifyError("swapped arm changed K or paired audio")
            swapped_slot = expected_mapping["slots"][1 - target_index]
            swapped_path = output_dir / "stno-crop-community1-swapped.f32le"
            if swapped_slot["status"] == "mapped":
                swapped_index = labels.index(swapped_slot["provider_label"])
                sealed_swapped = decode_reference(swapped_path.read_bytes())
                if (
                    not np.array_equal(sealed_swapped, target_stno(provider_activity, swapped_index, frames))
                    or swapped.get("status") != "mapped"
                    or swapped.get("crop") != stno_record(sealed_swapped, "community1")
                ):
                    raise VerifyError("swapped Community crop STNO does not reproduce")
            elif swapped.get("status") != "ABSENT" or swapped_path.exists() or "crop" in swapped:
                raise VerifyError("ABSENT swapped Community slot has a materialized mask")
        spurious_record = record.get("spurious_target")
        if (
            not isinstance(spurious_record, dict)
            or spurious_record.get("target_id") != "SPURIOUS_PADDED_SILENCE"
            or spurious_record.get("mapping_member") is not False
        ):
            raise VerifyError("spurious target entered the frozen mapping")
        frame_range = spurious_record.get("frame_range")
        expected_spurious_start = (max(mixed.support_a.end, mixed.support_b.end) + 319) // 320
        if frame_range != [expected_spurious_start, expected_spurious_start + 50] or frame_range[1] > 1500:
            raise VerifyError("spurious target is not exactly one second")
        spurious = np.zeros((1, 1500), dtype=np.uint8)
        spurious[0, frame_range[0] : frame_range[1]] = 1
        provider_spurious = np.concatenate((provider_activity, spurious), axis=0)
        if (activity_dir / "community1-spurious.u8").read_bytes() != provider_spurious.tobytes(order="C"):
            raise VerifyError("spurious activity provider does not reproduce")
        expected_clean_target = {
            "derivation": "one sealed oracle target row per target",
            "target_rows": [
                {
                    "target_id": str(target["target_id"]),
                    "oracle_row": index,
                    "sha256": hashlib.sha256(oracle[index].tobytes(order="C")).hexdigest(),
                }
                for index, target in enumerate(geometry["targets"])
            ],
        }
        if provider_records.get("community1_spurious") != {
            "path": str((activity_dir / "community1-spurious.u8").relative_to(pack)),
            "shape": list(provider_spurious.shape),
            "sha256": hashlib.sha256(provider_spurious.tobytes(order="C")).hexdigest(),
        } or provider_records.get("clean_target") != expected_clean_target:
            raise VerifyError("derived activity-provider records do not reproduce")
        spurious_path = pack / "targets" / window_id / "SPURIOUS_PADDED_SILENCE/stno-full-community1-spurious.f32le"
        sealed_spurious = decode_reference(spurious_path.read_bytes())
        if (
            not np.array_equal(sealed_spurious, target_stno(provider_spurious, provider_spurious.shape[0] - 1))
            or spurious_record.get("stno") != stno_record(sealed_spurious, "community1_spurious")
        ):
            raise VerifyError("spurious full-window STNO does not reproduce")

    hike_ids = [str(row["row_id"]) for row in source_plan["hike_rows"]]
    expected_korean = enforce_korean_all_or_nothing(hike_eligibility, hike_ids)
    if expected_korean != manifest.get("korean_geometry"):
        raise VerifyError("Korean all-or-nothing geometry record does not reproduce")
    if expected_korean["status"] == "korean_geometry_unavailable" and expected_korean["utility_target_ids"]:
        raise VerifyError("unavailable Korean geometry retained partial utility rows")
    if manifest.get("source_hashes_before") != manifest.get("source_hashes_after"):
        raise VerifyError("read-only source hashes changed during build")
    public_hashes = {
        "cc807d5e31c92df85a46445b28df2b239f7fb33943a35502161af61c1ee8b4d0",
        "7ee90aac9105734ab40d3085dcb4d0ad4ba06adc1c24facb2ad843529b489506",
        "b56e5babb2496b8795deeeda7e71178d7fbc9963f94276cf2a3f4b56ebbc9f9d",
    }
    if set(manifest["source_hashes_before"].values()) != public_hashes or len(manifest["source_hashes_before"]) != 3:
        raise VerifyError("pack source set is not exactly the three pinned public acceptance payloads")
    if manifest.get("fleurs_source_hashes_before") != manifest.get("fleurs_source_hashes_after") or len(manifest.get("fleurs_source_hashes_before", {})) != 3:
        raise VerifyError("the three pinned FLEURS source payloads changed during build")
    expected_fleurs_sizes = {401_722_686, 806_437_035, 291_159_866}
    if {Path(path).stat().st_size for path in manifest["fleurs_source_hashes_before"]} != expected_fleurs_sizes:
        raise VerifyError("FLEURS payload sizes do not match the pinned locale files")
    singles = manifest.get("singles")
    if not isinstance(singles, list) or len(singles) != 22 or len({item.get("target_id") for item in singles if isinstance(item, dict)}) != 22:
        raise VerifyError("pack must seal 12 HiKE, 8 selected FLEURS, and 2 Korean-control singles")
    expected_singles = {
        str(row["row_id"]): (
            row,
            row["family"],
            ["on", "off"] if row["family"] == "hike" else ["reference"],
        )
        for row in aligner_manifest["rows"]
        if row["family"] == "hike" or str(row["row_id"]) in {item for pair in selected_pairs for item in pair}
    }
    expected_singles.update({
        str(control["row_id"]): (control, "fleurs-ko-clean", ["absent-term-control"])
        for control in source_plan["korean_clean_controls"]
    })
    if set(expected_singles) != {str(item["target_id"]) for item in singles}:
        raise VerifyError("single fixture identities do not match their frozen sources")
    for single in singles:
        path = _inside(Path(str(single["audio_path"])), pack)
        samples = _read_pcm(path)
        source, expected_family, prompt_arms = expected_singles[str(single["target_id"])]
        source_path = _inside(Path(str(source["audio_path"])), pack)
        from benchmarks.scripts.dicow.common.fixtures import pad_single

        if (
            len(samples) != 480_000
            or sha256_file(path) != single["audio_sha256"]
            or not np.array_equal(samples, pad_single(_read_pcm(source_path)))
            or single.get("family") != expected_family
            or single.get("prompt_arms") != prompt_arms
        ):
            raise VerifyError("single fixture is not an exact 30-second sealed WAV")
        activity_payload = (path.parent / "speaker_activity.u8").read_bytes()
        if len(activity_payload) != 1500 or hashlib.sha256(activity_payload).hexdigest() != single.get("activity_sha256"):
            raise VerifyError("single fixture activity is missing or changed")
        activity = np.frombuffer(activity_payload, dtype=np.uint8).reshape(1, 1500)
        full_stno = decode_reference((path.parent / "stno-full-clean-target.f32le").read_bytes())
        if not np.array_equal(full_stno, target_stno(activity, 0)):
            raise VerifyError("single clean-target full STNO does not reproduce")
    absent = manifest.get("korean_absent_terms")
    if not isinstance(absent, dict) or len(absent.get("terms", [])) != 8:
        raise VerifyError("Korean clean controls must freeze eight absent terms")
    hashable_absent = {key: value for key, value in absent.items() if key != "list_sha256"}
    if qwen_reference.canonical_json_hash(hashable_absent) != absent.get("list_sha256"):
        raise VerifyError("Korean absent-term list hash mismatch")
    from benchmarks.scripts.scoring.metrics import count_term_occurrences, normalize_text

    control_texts = [str(item["text"]) for item in source_plan["korean_clean_controls"]]
    official_terms = sorted({str(term) for row in source_plan["hike_rows"] for term in row.get("terms", [])})
    if (
        absent.get("normalized_references") != [normalize_text(text) for text in control_texts]
        or absent.get("terms") != derive_absent_terms(official_terms, control_texts)
        or any(count_term_occurrences(str(term), " ".join(control_texts)) for term in absent["terms"])
    ):
        raise VerifyError("declared absent terms do not reproduce under scoring normalization")
    ami = manifest.get("ami_parity_windows")
    if not isinstance(ami, list) or [item.get("source_range_s") for item in ami] != [[95, 125], [125, 155]] or any(item.get("use") != "parity-only" for item in ami):
        raise VerifyError("AMI [95,155) must remain two parity-only windows")
    if ami != source_plan.get("ami_parity_windows"):
        raise VerifyError("AMI parity records differ from the source plan")
    acceptance_root = Path(str(source_plan.get("acceptance_root", "")))
    ami_source_path = acceptance_root / "sources/ami/IN1009.Mix-Headset.wav"
    sealed_source_hashes = source_plan.get("source_hashes_before")
    recorded_source_hash = sealed_source_hashes.get(str(ami_source_path)) if isinstance(sealed_source_hashes, dict) else None
    if not isinstance(recorded_source_hash, str) or sha256_file(ami_source_path) != recorded_source_hash:
        raise VerifyError("AMI public source no longer matches the sealed source plan")
    ami_source = _read_pcm(ami_source_path)
    for item in ami:
        audio_path = _inside(Path(str(item.get("audio_path", ""))), pack)
        start_sample = int(item["source_range_s"][0]) * 16_000
        expected_audio = ami_source[start_sample : start_sample + 480_000]
        if (
            len(expected_audio) != 480_000
            or not np.array_equal(_read_pcm(audio_path), expected_audio)
            or sha256_file(audio_path) != item.get("audio_sha256")
        ):
            raise VerifyError("AMI parity window audio is missing or changed")

    community1_reference.verify_pack(pack)
    if verify_published_binding(pack) != published_binding:
        raise VerifyError("published pack binding changed during verification")


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pack", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        verify_pack(args.pack)
    except (VerifyError, FixtureError, qwen_reference.AlignerError, community1_reference.CommunityError, OSError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("PASS: overlap-pack-v1")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
