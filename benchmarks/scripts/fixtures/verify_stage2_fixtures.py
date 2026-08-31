#!/usr/bin/env python3
"""Verify a mirrored rebuild of the eight fixed Stage 2 fixtures."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
import unicodedata
import wave
from pathlib import Path
from typing import Any

try:
    import pyarrow.parquet as pq
except ModuleNotFoundError as exc:  # Kept explicit so an incomplete audit cannot pass.
    raise SystemExit(
        "FAIL: pyarrow is required for deterministic public-source selection checks; "
        "run with `uv run --project benchmarks/scripts/fixtures --frozen python "
        "benchmarks/scripts/fixtures/verify_stage2_fixtures.py`."
    ) from exc

try:
    from jsonschema import Draft202012Validator, FormatChecker, SchemaError
except ModuleNotFoundError as exc:  # Schema validation is a required audit gate.
    raise SystemExit(
        "FAIL: jsonschema is required for segments contract checks; run with "
        "`uv run --project benchmarks/scripts/fixtures --frozen python "
        "benchmarks/scripts/fixtures/verify_stage2_fixtures.py`."
    ) from exc


CODE_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_OUTPUT_ROOT = (
    CODE_ROOT / "benchmarks/runs/post-v1-reliability-reset/fixture-rebuild"
)
SOURCE_ROOT = CODE_ROOT
OUTPUT_ROOT = DEFAULT_OUTPUT_ROOT

FIXTURE_RELATIVE_PATHS = {
    "hike-tech": Path("benchmarks/runs/ko-asr/fixtures/hike-tech"),
    "fleurs-ko-clean": Path("benchmarks/runs/ko-asr/fixtures/fleurs-ko-clean"),
    "fleurs-it-clean": Path("benchmarks/runs/it-asr/fixtures/fleurs-it-clean"),
    "italian-dialogue": Path("benchmarks/runs/it-asr/fixtures/italian-dialogue"),
    "ko-code-switch": Path("benchmarks/runs/diarization/fixtures/ko-code-switch"),
    "it-dialogue": Path("benchmarks/runs/diarization/fixtures/it-dialogue"),
    "voxconverse-rcxzg": Path(
        "benchmarks/runs/diarization/fixtures/voxconverse-rcxzg"
    ),
    "voxconverse-ppgjx-78m": Path(
        "benchmarks/runs/diarization/fixtures/voxconverse-ppgjx-78m"
    ),
}
SOURCE_RELATIVE_PATHS = {
    "hike_parquet": Path(
        "benchmarks/samples/public/hike/data/test-00000-of-00001.parquet"
    ),
    "fleurs_ko_parquet": Path(
        "benchmarks/samples/public/fleurs/parquet-data/ko_kr/test-00000-of-00001.parquet"
    ),
    "fleurs_it_parquet": Path(
        "benchmarks/samples/public/fleurs/parquet-data/it_it/test-00000-of-00001.parquet"
    ),
    "vox_parquet": Path(
        "benchmarks/samples/public/voxconverse/data/dev-00000-of-00005.parquet"
    ),
    "vox_rttm_rcxzg": Path(
        "benchmarks/samples/public/voxconverse/rttm/rcxzg.rttm"
    ),
    "vox_rttm_ppgjx": Path(
        "benchmarks/samples/public/voxconverse/rttm/ppgjx.rttm"
    ),
}
EXPECTED_SOURCE_SHA256 = {
    "hike_parquet": "cc807d5e31c92df85a46445b28df2b239f7fb33943a35502161af61c1ee8b4d0",
    "fleurs_ko_parquet": "1a8319fc61c7996e8c15acde633786de97054e28ae1e463eb13901716176a7ec",
    "fleurs_it_parquet": "6b648b2851cd0d0cf50254c9a7ecf8d91d7e41ecdb536f5614b10ef33b6b11a8",
    "vox_parquet": "f36c54412f0ac9cfe7ec2682e27f70f3e3df63d8e2b8f288d4f62341a595917d",
    "vox_rttm_rcxzg": "33a57e68376caf19b3016ea6f9b54bd2981aaf6c7cadef730b4aaba4c5347455",
    "vox_rttm_ppgjx": "bc05cffe528d7ba23f7dcc444d176ee5cd19e91eac4d4292f43ddff7d49e3c34",
}

HISTORICAL_DETERMINISTIC_FIXTURE_CHECK_SHA256 = {
    "hike-tech": "9a8619ca86533c77fcc4e7974394e087810b228ee153864ef6fee3308a8e5603",
    "fleurs-ko-clean": "f6eb78e8b7efe2a0cab2fa8468940647a5c1e80df54d7706f63f861ca6698544",
    "fleurs-it-clean": "278def616a6910bf697e30e2f6d66b7028dd2eb46903eaffb4c0786a3e640b52",
    "ko-code-switch": "157a58c33df930178ac4e7ff809937ef35f83183baf54e231c9ed77d7e5343f2",
    "voxconverse-rcxzg": "9bee79cae493b19bd012aa65bd62e5f09a7e7c78f51d9e6fb7186b6fcaff5dd5",
    "voxconverse-ppgjx-78m": "9fefd03e5cf9d5cc72f3c94cb5c1329e2f53d104a0a9044ffa14f2c9820bb5e8",
}
HISTORICAL_SAY_PROVENANCE = {
    "tool_path": "/usr/bin/say",
    "macos_product_version": "26.5.2",
    "macos_build_version": "25F84",
    "code_signing_identifier": "com.apple.say",
    "binary_sha256": "480d4f1678034fa65a023502b4bc0330430dcd48cd7f584e746772635113b353",
}


def configure_roots(source_root: Path, output_root: Path) -> None:
    global SOURCE_ROOT, OUTPUT_ROOT, SOURCE_FILES, FIXTURES
    SOURCE_ROOT = source_root.resolve(strict=True)
    if not SOURCE_ROOT.is_dir():
        raise ValueError(f"source root is not a directory: {source_root}")
    OUTPUT_ROOT = output_root.expanduser().absolute()
    if OUTPUT_ROOT == SOURCE_ROOT:
        raise ValueError("output root must be separate from the physical source root")
    SOURCE_FILES = {
        key: SOURCE_ROOT / relative for key, relative in SOURCE_RELATIVE_PATHS.items()
    }
    FIXTURES = {
        key: OUTPUT_ROOT / relative for key, relative in FIXTURE_RELATIVE_PATHS.items()
    }


def logical_path(path: Path) -> str:
    for root in (OUTPUT_ROOT, SOURCE_ROOT):
        try:
            return str(path.relative_to(root))
        except ValueError:
            continue
    return "<outside-roots>"


SOURCE_FILES = {
    key: SOURCE_ROOT / relative for key, relative in SOURCE_RELATIVE_PATHS.items()
}
FIXTURES = {
    key: OUTPUT_ROOT / relative for key, relative in FIXTURE_RELATIVE_PATHS.items()
}
HIKE_SAMPLE_IDS = [
    "444f370a-2929-40bc-9039-777467ad9c9c",
    "32b4ea2d-89e9-47f6-80c1-86af6eadc7cb",
    "6e088e0a-7ba1-4505-a4cf-4b223d954376",
    "6228cf6e-8eaf-4396-bcf5-ffb3f1da6bb2",
    "5ce02c31-4a6f-412f-a15b-8cd4b853d3cc",
    "f81b67f7-255c-4cd1-8dd7-562fc99fdcdd",
    "2f4041a5-8699-450f-95ae-c67713aaaf62",
    "77cb44a7-7531-46a6-9807-ddca9437918f",
    "2584e8ed-d23b-4e45-b140-b9463d43a248",
    "abf88602-cf6b-4a36-b811-d9d1ac3a3960",
    "09db2ac1-98e9-47fd-b1a3-1230979b0951",
    "5ec39d92-ca37-46c9-9c6d-b719eaac0e1f",
]
KO_TERMS = [
    "session management logic",
    "microservices architecture",
    "API gateway pattern",
    "Docker container",
    "machine learning model",
    "training dataset",
    "cicd pipeline",
    "frontend",
    "backend",
    "timeout",
    "production",
    "debugging",
    "database",
    "query",
    "ablation study",
    "security vulnerabilities",
    "maintainer",
    "release",
    "QA",
]
IT_TERMS = [
    "Maccheroni", "PostgreSQL", "CI/CD", "Qwen3-ASR", "Parakeet", "GitHub", "Docker", "Marco", "Alice"
]
IT_DIALOGUE = [
    ("Alice", "SPEAKER_00", "Ciao Marco, hai controllato il deployment di Maccheroni?"),
    ("Eddy (Italian (Italy))", "SPEAKER_01", "Sì, Alice. Il database PostgreSQL è pronto, ma la pipeline CI/CD ha ancora un timeout."),
    ("Alice", "SPEAKER_00", "Capisco. Puoi verificare anche l'API di Qwen3-ASR e il modello Parakeet?"),
    ("Eddy (Italian (Italy))", "SPEAKER_01", "Certo. Prima faccio il code review, poi aggiorno il benchmark su GitHub."),
    ("Alice", "SPEAKER_00", "Perfetto, grazie."),
    ("Eddy (Italian (Italy))", "SPEAKER_01", "Prego. Ah, un momento, devo correggere la configurazione Docker."),
    ("Alice", "SPEAKER_00", "Va bene."),
]
BACKCHANNELS = ["Sì", "Capisco", "Certo", "Perfetto", "Prego", "Ah", "Va bene"]


class Audit:
    def __init__(self) -> None:
        self.errors: list[str] = []

    def require(self, condition: bool, message: str) -> None:
        if not condition:
            self.errors.append(message)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def t6(value: float) -> float:
    return float(f"{float(value):.6f}")


def read_json(path: Path, audit: Audit) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        audit.require(False, f"{logical_path(path)}: invalid JSON: {exc}")
        return {}
    audit.require(isinstance(value, dict), f"{logical_path(path)}: expected object")
    return value if isinstance(value, dict) else {}


def load_segments_schema(audit: Audit) -> Draft202012Validator | None:
    schema_path = SOURCE_ROOT / "docs/contracts/segments.schema.json"
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        audit.require(False, f"segments schema unavailable or invalid JSON: {exc}")
        return None
    try:
        Draft202012Validator.check_schema(schema)
        return Draft202012Validator(schema, format_checker=FormatChecker())
    except SchemaError as exc:
        audit.require(False, f"segments schema is malformed: {exc.message}")
        return None


def validate_segments_schema(
    fixture_id: str,
    document: dict[str, Any],
    validator: Draft202012Validator | None,
    audit: Audit,
) -> None:
    if validator is None:
        return
    try:
        errors = sorted(validator.iter_errors(document), key=lambda error: list(error.absolute_path))
    except SchemaError as exc:
        audit.require(False, f"{fixture_id}: segments schema validation failed: {exc.message}")
        return
    for error in errors:
        path = "/".join(str(part) for part in error.absolute_path) or "$"
        audit.require(False, f"{fixture_id}: segments schema {path}: {error.message}")


def parse_rttm(path: Path, audit: Audit) -> list[dict[str, Any]]:
    turns: list[dict[str, Any]] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        audit.require(False, f"{logical_path(path)}: cannot read RTTM: {exc}")
        return turns
    for line_number, line in enumerate(lines, start=1):
        fields = line.split()
        audit.require(
            len(fields) == 10 and fields[0] == "SPEAKER",
            f"{logical_path(path)}:{line_number}: malformed RTTM line",
        )
        if len(fields) != 10 or fields[0] != "SPEAKER":
            continue
        try:
            start, duration = float(fields[3]), float(fields[4])
        except ValueError:
            audit.require(False, f"{logical_path(path)}:{line_number}: nonnumeric RTTM time")
            continue
        audit.require(start >= 0 and duration > 0, f"{logical_path(path)}:{line_number}: invalid RTTM bounds")
        turns.append({"file_id": fields[1], "start_s": start, "end_s": start + duration, "speaker": fields[7]})
    return turns


def wave_info(path: Path, audit: Audit) -> dict[str, Any]:
    try:
        with wave.open(str(path), "rb") as handle:
            sample_rate = handle.getframerate()
            frames = handle.getnframes()
            channels = handle.getnchannels()
            sample_width = handle.getsampwidth()
            compression = handle.getcomptype()
    except (OSError, wave.Error) as exc:
        audit.require(False, f"{logical_path(path)}: invalid WAV: {exc}")
        return {}
    audit.require(channels == 1, f"{logical_path(path)}: expected mono WAV")
    audit.require(sample_rate == 16_000, f"{logical_path(path)}: expected 16 kHz WAV")
    audit.require(sample_width == 2 and compression == "NONE", f"{logical_path(path)}: expected PCM_16 WAV")
    return {"sample_rate_hz": sample_rate, "num_samples": frames, "channels": channels, "duration_s": t6(frames / sample_rate)}


def is_relative_artifact(value: str) -> bool:
    path = Path(value)
    return not path.is_absolute() and ".." not in path.parts


def contains_hangul(text: str) -> bool:
    return any("\uac00" <= character <= "\ud7a3" for character in text)


def is_latin_alnum(character: str) -> bool:
    return character.isdigit() or (
        unicodedata.category(character).startswith("L") and "LATIN" in unicodedata.name(character, "")
    )


def count_term_occurrences(term: str, transcript: str) -> int:
    if contains_hangul(term):
        normalized_term = "".join(unicodedata.normalize("NFKC", term).casefold().split())
        normalized_transcript = "".join(unicodedata.normalize("NFKC", transcript).casefold().split())
        return len(re.findall(re.escape(normalized_term), normalized_transcript))
    normalized_term = unicodedata.normalize("NFKC", term).casefold().strip()
    normalized_transcript = unicodedata.normalize("NFKC", transcript).casefold()
    components = [component for component in re.split(r"[\s_-]+", normalized_term) if component]
    pattern = re.compile(r"[\s_-]*".join(re.escape(component) for component in components))
    return sum(
        1
        for match in pattern.finditer(normalized_transcript)
        if not (match.start() and is_latin_alnum(normalized_transcript[match.start() - 1]))
        and not (match.end() < len(normalized_transcript) and is_latin_alnum(normalized_transcript[match.end()]))
    )


def validate_common(
    fixture_id: str,
    root: Path,
    source_hashes: dict[str, str],
    segments_validator: Draft202012Validator | None,
    audit: Audit,
) -> tuple[dict[str, Any], dict[str, Any], list[dict[str, Any]]]:
    check = read_json(root / "fixture-check.json", audit)
    selection = read_json(root / "selection.json", audit)
    segments_doc = read_json(root / "reference.segments.json", audit)
    validate_segments_schema(fixture_id, segments_doc, segments_validator, audit)
    audit.require(check.get("fixture_id") == fixture_id, f"{fixture_id}: fixture-check fixture_id drift")
    audit.require(selection.get("fixture_id") == fixture_id, f"{fixture_id}: selection fixture_id drift")
    audit.require(check.get("passed") is True, f"{fixture_id}: fixture-check is not passed")
    hashes = check.get("artifact_sha256")
    audit.require(isinstance(hashes, dict), f"{fixture_id}: missing artifact_sha256")
    if not isinstance(hashes, dict):
        hashes = {}
    audit.require("fixture-check.json" not in hashes, f"{fixture_id}: fixture-check self hash is forbidden")
    for relative, expected in hashes.items():
        audit.require(isinstance(relative, str) and is_relative_artifact(relative), f"{fixture_id}: unsafe artifact path {relative!r}")
        path = root / relative
        audit.require(path.is_file(), f"{fixture_id}: missing artifact {relative}")
        if path.is_file():
            audit.require(sha256_file(path) == expected, f"{fixture_id}: hash mismatch {relative}")
    before, after = check.get("source_hashes_before"), check.get("source_hashes_after")
    audit.require(before == source_hashes, f"{fixture_id}: source_hashes_before drift")
    audit.require(after == source_hashes, f"{fixture_id}: source_hashes_after drift")

    wav_path = root / "input.wav"
    wav = wave_info(wav_path, audit)
    input_meta = check.get("input_wav", {})
    for key, actual in (("sha256", sha256_file(wav_path)), ("size_bytes", wav_path.stat().st_size), ("duration_s", wav.get("duration_s")), ("sample_rate_hz", wav.get("sample_rate_hz")), ("channels", wav.get("channels")), ("subtype", "PCM_16")):
        audit.require(input_meta.get(key) == actual, f"{fixture_id}: input_wav.{key} drift")

    audit.require(segments_doc.get("schema_version") == "1.0.0", f"{fixture_id}: segments schema_version")
    segments = segments_doc.get("segments")
    audit.require(isinstance(segments, list) and bool(segments), f"{fixture_id}: segments must be nonempty list")
    segments = segments if isinstance(segments, list) else []
    speakers: set[str] = set()
    previous_start = -1.0
    for index, segment in enumerate(segments):
        audit.require(isinstance(segment, dict), f"{fixture_id}: segment {index} not object")
        if not isinstance(segment, dict):
            continue
        required = ("speaker", "start_s", "end_s", "text")
        audit.require(all(key in segment for key in required), f"{fixture_id}: segment {index} missing required field")
        try:
            start, end = float(segment["start_s"]), float(segment["end_s"])
        except (KeyError, TypeError, ValueError):
            audit.require(False, f"{fixture_id}: segment {index} invalid bounds")
            continue
        audit.require(isinstance(segment.get("speaker"), str) and bool(segment["speaker"]), f"{fixture_id}: segment {index} speaker")
        audit.require(isinstance(segment.get("text"), str) and bool(segment["text"]), f"{fixture_id}: segment {index} text")
        audit.require(0 <= start < end <= wav.get("duration_s", -1) + 1e-6, f"{fixture_id}: segment {index} bounds")
        audit.require(start + 1e-12 >= previous_start, f"{fixture_id}: segment {index} not ordered")
        previous_start = start
        speakers.add(segment.get("speaker", ""))
    audit.require(segments_doc.get("num_speakers") == len(speakers), f"{fixture_id}: num_speakers drift")
    source = segments_doc.get("source", {})
    audit.require(source == {"file_name": "input.wav", "sha256": sha256_file(wav_path), "duration_s": wav.get("duration_s")}, f"{fixture_id}: segments source drift")
    audit.require(check.get("reference_segment_count") == len(segments), f"{fixture_id}: reference segment count drift")

    rttm_turns = parse_rttm(root / "reference.rttm", audit)
    audit.require(check.get("reference_rttm_count") == len(rttm_turns), f"{fixture_id}: RTTM count drift")
    audit.require({turn["speaker"] for turn in rttm_turns} == speakers, f"{fixture_id}: RTTM speaker set drift")
    audit.require(all(turn["end_s"] <= wav.get("duration_s", -1) + 1e-6 for turn in rttm_turns), f"{fixture_id}: RTTM bounds")
    audit.require(check.get("speaker_count") == len(speakers), f"{fixture_id}: fixture-check speaker count drift")

    terms_path, glossary_path = root / "terms.json", root / "glossary.txt"
    try:
        terms = json.loads(terms_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        audit.require(False, f"{fixture_id}: invalid terms.json: {exc}")
        terms = []
    audit.require(isinstance(terms, list), f"{fixture_id}: terms must be list")
    terms = terms if isinstance(terms, list) else []
    glossary_terms = glossary_path.read_text(encoding="utf-8").splitlines()
    audit.require(glossary_terms == [entry.get("term") for entry in terms if isinstance(entry, dict)], f"{fixture_id}: glossary/terms drift")
    reference_text = selection.get("reference_text")
    audit.require(isinstance(reference_text, str), f"{fixture_id}: missing selection reference_text")
    if isinstance(reference_text, str):
        for entry in terms:
            if isinstance(entry, dict) and isinstance(entry.get("term"), str):
                audit.require(entry.get("reference_count") == count_term_occurrences(entry["term"], reference_text), f"{fixture_id}: glossary count drift for {entry['term']!r}")
        expected_term_counts = {entry.get("term"): entry.get("reference_count") for entry in terms if isinstance(entry, dict)}
        recorded_term_counts = selection.get("term_reference_occurrences")
        if not expected_term_counts and recorded_term_counts is None:
            recorded_term_counts = {}
        audit.require(recorded_term_counts == expected_term_counts, f"{fixture_id}: selection term counts drift")
    audit.require(selection.get("output_start_s") == 0.0 and selection.get("output_end_s") == wav.get("duration_s"), f"{fixture_id}: output bounds drift")

    for item in selection.get("items", []) if isinstance(selection.get("items"), list) else []:
        audit.require(isinstance(item, dict), f"{fixture_id}: item not object")
        if not isinstance(item, dict):
            continue
        relative = item.get("item_wav")
        audit.require(isinstance(relative, str) and is_relative_artifact(relative), f"{fixture_id}: unsafe item WAV path")
        if isinstance(relative, str) and is_relative_artifact(relative):
            item_path = root / relative
            audit.require(item_path.is_file(), f"{fixture_id}: missing item {relative}")
            if item_path.is_file():
                audit.require(sha256_file(item_path) == item.get("item_wav_sha256"), f"{fixture_id}: item hash mismatch {relative}")
    return check, selection, rttm_turns


def select_fleurs_rows(table: Any) -> list[int]:
    samples, genders, ids = (table.column(name).to_pylist() for name in ("num_samples", "gender", "id"))
    audio_paths = [table.column("audio")[i]["path"].as_py() for i in range(table.num_rows)]
    eligible: dict[Any, list[int]] = {}
    for index, (count, gender) in enumerate(zip(samples, genders, strict=True)):
        if 80_000 <= int(count) <= 240_000:
            eligible.setdefault(gender, []).append(index)
    selected: list[int] = []
    for gender in sorted(eligible, key=lambda value: str(value)):
        selected.extend(sorted(eligible[gender], key=lambda i: (int(ids[i]), str(audio_paths[i])))[:4])
    return sorted(selected, key=lambda i: (str(genders[i]), int(ids[i]), str(audio_paths[i])))


def validate_hike(selection: dict[str, Any], audit: Audit) -> None:
    table = pq.read_table(SOURCE_FILES["hike_parquet"])
    by_id = {sample_id: index for index, sample_id in enumerate(table.column("sample_id").to_pylist())}
    audit.require(selection.get("public_source") == {
        "dataset_id": "thetaone-ai/HiKE",
        "revision": "255609b24005e1fcce3f8b3a452260aaf2872cc9",
        "relative_path": "data/test-00000-of-00001.parquet",
        "source_relative_path": "benchmarks/samples/public/hike/data/test-00000-of-00001.parquet",
        "source_sha256": sha256_file(SOURCE_FILES["hike_parquet"]),
    }, "hike-tech: public source provenance drift")
    audit.require(selection.get("selected_row_ids") == HIKE_SAMPLE_IDS, "hike-tech: deterministic selected IDs drift")
    items = selection.get("items", [])
    audit.require(len(items) == len(HIKE_SAMPLE_IDS), "hike-tech: item count drift")
    for order, sample_id in enumerate(HIKE_SAMPLE_IDS):
        item = items[order] if isinstance(items, list) and order < len(items) else {}
        row = by_id.get(sample_id)
        audit.require(row is not None, f"hike-tech: source sample missing {sample_id}")
        if row is None or not isinstance(item, dict):
            continue
        audio = table.column("audio")[row]["bytes"].as_py()
        audit.require(item.get("order") == order and item.get("row_index") == row, f"hike-tech: source row drift {sample_id}")
        audit.require(item.get("source_audio_sha256") == sha256_bytes(audio), f"hike-tech: source audio drift {sample_id}")
        for field in ("text", "text_normalized", "text_pier_labeled", "loanwords", "cs_level", "category"):
            audit.require(item.get(field) == table.column(field)[row].as_py(), f"hike-tech: {field} drift {sample_id}")
    terms = selection.get("term_reference_occurrences", {})
    audit.require(set(terms) == set(KO_TERMS) and all(value > 0 for value in terms.values()), "hike-tech: required HiKE glossary occurrence drift")


def validate_fleurs(fixture_id: str, selection: dict[str, Any], parquet_key: str, audit: Audit) -> None:
    table = pq.read_table(SOURCE_FILES[parquet_key])
    language_dir = "ko_kr" if parquet_key == "fleurs_ko_parquet" else "it_it"
    audit.require(selection.get("public_source") == {
        "dataset_id": "google/fleurs",
        "revision": "70bb2e84b976b7e960aa89f1c648e09c59f894dd",
        "source_relative_path": f"benchmarks/samples/public/fleurs/parquet-data/{language_dir}/test-00000-of-00001.parquet",
        "source_sha256": sha256_file(SOURCE_FILES[parquet_key]),
    }, f"{fixture_id}: public source provenance drift")
    selected = select_fleurs_rows(table)
    algo = selection.get("selection_algorithm", {})
    audit.require(algo.get("selected_row_indexes") == selected, f"{fixture_id}: deterministic selected rows drift")
    items = selection.get("items", [])
    audit.require(len(items) == len(selected), f"{fixture_id}: FLEURS item count drift")
    for order, row in enumerate(selected):
        item = items[order] if isinstance(items, list) and order < len(items) else {}
        if not isinstance(item, dict):
            continue
        audio = table.column("audio")[row]
        expected = {
            "order": order, "row_index": row, "id": int(table.column("id")[row].as_py()),
            "gender": table.column("gender")[row].as_py(), "num_samples": int(table.column("num_samples")[row].as_py()),
            "audio.path": audio["path"].as_py(), "transcription": table.column("transcription")[row].as_py(),
            "raw_transcription": table.column("raw_transcription")[row].as_py(),
            "source_audio_sha256": sha256_bytes(audio["bytes"].as_py()),
        }
        for field, value in expected.items():
            audit.require(item.get(field) == value, f"{fixture_id}: {field} drift for row {row}")
    expected_zero = selection.get("expected_term_occurrences") == "zero_for_overfire_detection"
    if expected_zero:
        audit.require(all(value == 0 for value in selection.get("term_reference_occurrences", {}).values()), f"{fixture_id}: clean glossary has a recorded hit")


def expected_say_definition_sha256() -> str:
    payload = [{"voice": voice, "speaker": speaker, "rate": 180, "text": text} for voice, speaker, text in IT_DIALOGUE]
    return sha256_bytes(json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8"))


def current_say_generator(audit: Audit) -> dict[str, Any]:
    say = Path("/usr/bin/say")
    audit.require(say.is_file(), "italian-dialogue: /usr/bin/say is missing")
    if not say.is_file():
        return {}
    try:
        product = subprocess.run(["/usr/bin/sw_vers", "-productVersion"], check=True, capture_output=True, text=True).stdout.strip()
        build = subprocess.run(["/usr/bin/sw_vers", "-buildVersion"], check=True, capture_output=True, text=True).stdout.strip()
        signing = subprocess.run(["/usr/bin/codesign", "-dvv", str(say)], check=True, capture_output=True, text=True).stderr
    except (OSError, subprocess.CalledProcessError) as exc:
        audit.require(False, f"italian-dialogue: cannot identify say generator: {exc}")
        return {}
    match = re.search(r"^Identifier=(.+)$", signing, flags=re.MULTILINE)
    audit.require(match is not None, "italian-dialogue: say signing identifier unavailable")
    return {"tool_path": str(say), "macos_product_version": product, "macos_build_version": build, "code_signing_identifier": match.group(1) if match else None, "binary_sha256": sha256_file(say)}


def validate_italian(selection: dict[str, Any], fixture_id: str, audit: Audit) -> None:
    source = selection.get("public_source", {})
    audit.require(source.get("kind") == "local_synthetic", f"{fixture_id}: synthetic provenance kind drift")
    audit.require(source.get("definition_relative_path") == "benchmarks/scripts/fixtures/build_stage2_fixtures.py", f"{fixture_id}: synthetic definition path drift")
    audit.require(source.get("definition_sha256") == expected_say_definition_sha256(), f"{fixture_id}: synthetic definition hash drift")
    audit.require(source.get("migration_lineage") == {
        "legacy_builder_relative_path": "benchmarks/runs/fixture-build/build_stage2_fixtures.py",
        "legacy_builder_sha256": "4fcd711e9c2c51bb2545ba9b9b01a78353f6ad40d2a4dfdb573aa7e9bbc15824",
    }, f"{fixture_id}: legacy builder lineage drift")
    audit.require(source.get("generator") == current_say_generator(audit), f"{fixture_id}: /usr/bin/say provenance drift")
    expected_utterances = [{"voice": voice, "speaker": speaker, "rate": 180, "text": text} for voice, speaker, text in IT_DIALOGUE]
    audit.require(selection.get("say_utterances") == expected_utterances, f"{fixture_id}: Italian voice/rate/text provenance drift")
    reference = selection.get("reference_text", "")
    expected_backchannels = {term: count_term_occurrences(term, reference) for term in BACKCHANNELS}
    audit.require(selection.get("backchannel_reference_occurrences") == expected_backchannels and all(value == 1 for value in expected_backchannels.values()), f"{fixture_id}: Italian backchannel provenance drift")


def validate_copied(fixture_id: str, root: Path, selection: dict[str, Any], audit: Audit) -> None:
    provenance = selection.get("provenance", {})
    source_rel = provenance.get("copied_from_fixture")
    audit.require(isinstance(source_rel, str) and is_relative_artifact(source_rel), f"{fixture_id}: invalid copied fixture path")
    if not isinstance(source_rel, str) or not is_relative_artifact(source_rel):
        return
    source = OUTPUT_ROOT / source_rel
    audit.require(source.is_dir(), f"{fixture_id}: copied source fixture missing")
    if not source.is_dir():
        return
    for name, key in (("input.wav", "source_input_wav_sha256"), ("reference.rttm", "source_reference_rttm_sha256"), ("reference.segments.json", "source_reference_segments_sha256")):
        audit.require((root / name).read_bytes() == (source / name).read_bytes(), f"{fixture_id}: copied {name} not byte-identical")
        audit.require(provenance.get(key) == sha256_file(source / name), f"{fixture_id}: copied {name} provenance hash drift")
    source_selection = read_json(source / "selection.json", audit)
    audit.require(selection.get("public_source") == source_selection.get("public_source"), f"{fixture_id}: copied public provenance drift")
    audit.require(selection.get("selected_row_ids") == source_selection.get("selected_row_ids"), f"{fixture_id}: copied selected rows drift")
    for item in selection.get("items", []) if isinstance(selection.get("items"), list) else []:
        relative = item.get("item_wav") if isinstance(item, dict) else None
        if isinstance(relative, str) and is_relative_artifact(relative):
            target_item = root / relative
            source_item = source / relative
            audit.require(target_item.is_file(), f"{fixture_id}: copied item missing {relative}")
            audit.require(source_item.is_file(), f"{fixture_id}: source item missing {relative}")
            if target_item.is_file() and source_item.is_file():
                audit.require(target_item.read_bytes() == source_item.read_bytes(), f"{fixture_id}: copied item not byte-identical {relative}")


def validate_vox_source(selection: dict[str, Any], recording: str, audit: Audit) -> list[dict[str, Any]]:
    table = pq.read_table(SOURCE_FILES["vox_parquet"])
    matches = [i for i in range(table.num_rows) if Path(table.column("audio")[i]["path"].as_py()).stem == recording]
    audit.require(len(matches) == 1, f"{recording}: source parquet row is not unique")
    if len(matches) != 1:
        return []
    row = matches[0]
    audio = table.column("audio")[row]
    rttm_key = f"vox_rttm_{recording}"
    audit.require(selection.get("public_source") == {
        "dataset_id": "diarizers-community/voxconverse",
        "revision": "3acfa1b45ca4b7419aee999d67d94c617f9c9d47",
        "relative_path": "data/dev-00000-of-00005.parquet",
        "source_relative_path": "benchmarks/samples/public/voxconverse/data/dev-00000-of-00005.parquet",
        "source_sha256": sha256_file(SOURCE_FILES["vox_parquet"]),
        "rttm_relative_path": f"benchmarks/samples/public/voxconverse/rttm/{recording}.rttm",
        "rttm_sha256": sha256_file(SOURCE_FILES[rttm_key]),
    }, f"{recording}: public source provenance drift")
    audit.require(selection.get("selected_audio_path") == audio["path"].as_py(), f"{recording}: selected audio path drift")
    audit.require(selection.get("source_audio_sha256") == sha256_bytes(audio["bytes"].as_py()), f"{recording}: source audio hash drift")
    return parse_rttm(SOURCE_FILES[rttm_key], audit)


def validate_rcxzg(root: Path, selection: dict[str, Any], audit: Audit) -> None:
    canonical = SOURCE_FILES["vox_rttm_rcxzg"]
    audit.require((root / "reference.rttm").read_bytes() == canonical.read_bytes(), "voxconverse-rcxzg: canonical RTTM byte copy drift")
    turns = validate_vox_source(selection, "rcxzg", audit)
    table = pq.read_table(SOURCE_FILES["vox_parquet"])
    row = next(i for i in range(table.num_rows) if Path(table.column("audio")[i]["path"].as_py()).stem == "rcxzg")
    expected = {"timestamps_start": [t6(v) for v in table.column("timestamps_start")[row].as_py()], "timestamps_end": [t6(v) for v in table.column("timestamps_end")[row].as_py()], "speakers": table.column("speakers")[row].as_py()}
    audit.require(selection.get("parquet_arrays") == expected, "voxconverse-rcxzg: RTTM/Parquet selection drift")
    audit.require(all(turn["file_id"] == "rcxzg" for turn in turns), "voxconverse-rcxzg: canonical RTTM file id drift")


def validate_ppgjx(root: Path, selection: dict[str, Any], audit: Audit) -> None:
    base_turns = validate_vox_source(selection, "ppgjx", audit)
    item = root / "items/000.wav"
    item_info = wave_info(item, audit)
    input_info = wave_info(root / "input.wav", audit)
    repeat_count, separator_s = selection.get("repetition_count"), selection.get("separator_duration_s")
    audit.require(repeat_count == 9 and separator_s == 0.5, "voxconverse-ppgjx-78m: ninefold repetition/silence config drift")
    expected_offsets = [t6(index * (item_info.get("duration_s", 0) + 0.5)) for index in range(9)]
    audit.require(selection.get("repeat_offsets_s") == expected_offsets, "voxconverse-ppgjx-78m: repetition offsets drift")
    audit.require(selection.get("source_duration_s") == item_info.get("duration_s"), "voxconverse-ppgjx-78m: source duration drift")
    expected_frames = item_info.get("num_samples", 0) * 9 + 8 * 8_000
    audit.require(input_info.get("num_samples") == expected_frames, "voxconverse-ppgjx-78m: output frame count drift")
    try:
        with wave.open(str(item), "rb") as source_handle, wave.open(str(root / "input.wav"), "rb") as reel_handle:
            base_pcm = source_handle.readframes(source_handle.getnframes())
            for index in range(9):
                audit.require(reel_handle.readframes(source_handle.getnframes()) == base_pcm, f"voxconverse-ppgjx-78m: repeat {index} PCM drift")
                if index < 8:
                    audit.require(reel_handle.readframes(8_000) == b"\0" * 16_000, f"voxconverse-ppgjx-78m: repeat {index} silence drift")
    except (OSError, wave.Error) as exc:
        audit.require(False, f"voxconverse-ppgjx-78m: cannot read repeat waveform: {exc}")
    turns = parse_rttm(root / "reference.rttm", audit)
    expected_turns = [
        (t6(offset + turn["start_s"]), t6(offset + turn["end_s"]), turn["speaker"])
        for offset in expected_offsets for turn in base_turns
    ]
    actual_turns = [(t6(turn["start_s"]), t6(turn["end_s"]), turn["speaker"]) for turn in turns]
    audit.require(actual_turns == sorted(expected_turns), "voxconverse-ppgjx-78m: shifted RTTM repetition drift")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source-root",
        type=Path,
        default=CODE_ROOT,
        help="repository-shaped root containing public source files and schemas",
    )
    parser.add_argument(
        "--fixture-root",
        type=Path,
        default=DEFAULT_OUTPUT_ROOT,
        help="mirror root produced by build_stage2_fixtures.py",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        configure_roots(args.source_root, args.fixture_root)
    except (OSError, ValueError) as exc:
        print(f"FAIL: invalid roots: {exc}")
        return 1
    audit = Audit()
    segments_validator = load_segments_schema(audit)
    source_hashes: dict[str, str] = {}
    for key, path in SOURCE_FILES.items():
        audit.require(path.is_file(), f"source missing: {logical_path(path)}")
        if path.is_file():
            source_hashes[key] = sha256_file(path)
    audit.require(
        source_hashes == EXPECTED_SOURCE_SHA256,
        "pinned public source hash ledger mismatch",
    )
    selections: dict[str, dict[str, Any]] = {}
    for fixture_id, root in FIXTURES.items():
        audit.require(root.is_dir(), f"fixture missing: {logical_path(root)}")
        if root.is_dir():
            _, selections[fixture_id], _ = validate_common(
                fixture_id, root, source_hashes, segments_validator, audit
            )
            expected_hash = HISTORICAL_DETERMINISTIC_FIXTURE_CHECK_SHA256.get(
                fixture_id
            )
            if expected_hash is not None:
                audit.require(
                    sha256_file(root / "fixture-check.json") == expected_hash,
                    f"{fixture_id}: deterministic fixture-check historical hash drift",
                )
    if len(selections) == len(FIXTURES):
        validate_hike(selections["hike-tech"], audit)
        validate_fleurs("fleurs-ko-clean", selections["fleurs-ko-clean"], "fleurs_ko_parquet", audit)
        validate_fleurs("fleurs-it-clean", selections["fleurs-it-clean"], "fleurs_it_parquet", audit)
        validate_italian(selections["italian-dialogue"], "italian-dialogue", audit)
        validate_italian(selections["it-dialogue"], "it-dialogue", audit)
        validate_copied("ko-code-switch", FIXTURES["ko-code-switch"], selections["ko-code-switch"], audit)
        validate_copied("it-dialogue", FIXTURES["it-dialogue"], selections["it-dialogue"], audit)
        validate_rcxzg(FIXTURES["voxconverse-rcxzg"], selections["voxconverse-rcxzg"], audit)
        validate_ppgjx(FIXTURES["voxconverse-ppgjx-78m"], selections["voxconverse-ppgjx-78m"], audit)
    if audit.errors:
        print(f"FAIL: Stage 2 fixture audit ({len(audit.errors)} issue(s))")
        for error in audit.errors:
            print(f"- {error}")
        return 1
    current_say = current_say_generator(Audit())
    current_comparable = {
        key: current_say.get(key) for key in HISTORICAL_SAY_PROVENANCE
    }
    print(
        "PORTABILITY: macOS say fixtures are host-bound; "
        + json.dumps(
            {
                "historical": HISTORICAL_SAY_PROVENANCE,
                "current": current_comparable,
                "historical_match": current_comparable == HISTORICAL_SAY_PROVENANCE,
                "hash_equality_required": False,
            },
            sort_keys=True,
        )
    )
    print("PASS: Stage 2 fixture audit (8 fixtures, 19 copied item WAVs, 6 source hashes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
