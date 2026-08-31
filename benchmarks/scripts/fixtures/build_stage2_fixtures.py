#!/usr/bin/env python3
"""Rebuild the eight public or synthetic Stage 2 fixtures into a mirror root."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import shutil
import subprocess
import sys
import unicodedata
from pathlib import Path
from typing import Any

import numpy as np
import pyarrow.parquet as pq
import soundfile as sf

CODE_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_OUTPUT_ROOT = (
    CODE_ROOT / "benchmarks/runs/post-v1-reliability-reset/fixture-rebuild"
)
SOURCE_ROOT = CODE_ROOT
OUTPUT_ROOT = DEFAULT_OUTPUT_ROOT
TARGET_HZ = 16_000
SAY = Path("/usr/bin/say")

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

FIXTURE_RELATIVE_PATHS = [
    Path("benchmarks/runs/ko-asr/fixtures/hike-tech"),
    Path("benchmarks/runs/ko-asr/fixtures/fleurs-ko-clean"),
    Path("benchmarks/runs/it-asr/fixtures/fleurs-it-clean"),
    Path("benchmarks/runs/it-asr/fixtures/italian-dialogue"),
    Path("benchmarks/runs/diarization/fixtures/ko-code-switch"),
    Path("benchmarks/runs/diarization/fixtures/it-dialogue"),
    Path("benchmarks/runs/diarization/fixtures/voxconverse-rcxzg"),
    Path("benchmarks/runs/diarization/fixtures/voxconverse-ppgjx-78m"),
]


def source_files(root: Path) -> dict[str, Path]:
    return {key: root / relative for key, relative in SOURCE_RELATIVE_PATHS.items()}


def fixture_dirs(root: Path) -> list[Path]:
    return [root / relative for relative in FIXTURE_RELATIVE_PATHS]


def configure_roots(source_root: Path, output_root: Path) -> None:
    global SOURCE_ROOT, OUTPUT_ROOT, SOURCE_FILES, FIXTURE_DIRS
    SOURCE_ROOT = source_root.resolve(strict=True)
    if not SOURCE_ROOT.is_dir():
        raise BuildError(f"source root is not a directory: {source_root}")
    OUTPUT_ROOT = output_root.expanduser().absolute()
    if OUTPUT_ROOT == SOURCE_ROOT:
        raise BuildError("output root must be separate from the physical source root")
    existing = OUTPUT_ROOT
    while not existing.exists() and existing != existing.parent:
        existing = existing.parent
    if existing.is_symlink() or not existing.is_dir():
        raise BuildError("output root must have a real directory ancestor")
    for parent in (OUTPUT_ROOT, *OUTPUT_ROOT.parents):
        if not parent.exists():
            continue
        if parent.is_symlink():
            raise BuildError("output root must not traverse a symlink")
    SOURCE_FILES = source_files(SOURCE_ROOT)
    FIXTURE_DIRS = fixture_dirs(OUTPUT_ROOT)


def validate_fixture_parent_paths() -> None:
    """Reject pre-existing path components that could redirect fixture writes."""
    for fixture_dir in FIXTURE_DIRS:
        relative = fixture_dir.relative_to(OUTPUT_ROOT)
        current = OUTPUT_ROOT
        for component in relative.parent.parts:
            current /= component
            if current.is_symlink():
                raise BuildError(
                    f"fixture parent must not be a symlink: {logical_path(current)}"
                )
            if current.exists() and not current.is_dir():
                raise BuildError(
                    f"fixture parent must be a directory: {logical_path(current)}"
                )


def logical_path(path: Path) -> str:
    """Return a path inside the historical mirror without leaking host paths."""
    try:
        return str(path.relative_to(OUTPUT_ROOT))
    except ValueError:
        try:
            return str(path.relative_to(SOURCE_ROOT))
        except ValueError:
            return "<outside-roots>"


SOURCE_FILES = source_files(SOURCE_ROOT)
FIXTURE_DIRS = fixture_dirs(OUTPUT_ROOT)

LEGACY_DEFINITION_RELATIVE_PATH = (
    "benchmarks/runs/fixture-build/build_stage2_fixtures.py"
)
LEGACY_DEFINITION_SHA256 = (
    "4fcd711e9c2c51bb2545ba9b9b01a78353f6ad40d2a4dfdb573aa7e9bbc15824"
)

DATASET_META = {
    "hike": {
        "dataset_id": "thetaone-ai/HiKE",
        "revision": "255609b24005e1fcce3f8b3a452260aaf2872cc9",
        "relative_path": "data/test-00000-of-00001.parquet",
    },
    "fleurs": {
        "dataset_id": "google/fleurs",
        "revision": "70bb2e84b976b7e960aa89f1c648e09c59f894dd",
    },
    "voxconverse": {
        "dataset_id": "diarizers-community/voxconverse",
        "revision": "3acfa1b45ca4b7419aee999d67d94c617f9c9d47",
        "relative_path": "data/dev-00000-of-00005.parquet",
    },
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
    "Maccheroni",
    "PostgreSQL",
    "CI/CD",
    "Qwen3-ASR",
    "Parakeet",
    "GitHub",
    "Docker",
    "Marco",
    "Alice",
]

IT_DIALOGUE = [
    ("Alice", "SPEAKER_00", "Ciao Marco, hai controllato il deployment di Maccheroni?"),
    (
        "Eddy (Italian (Italy))",
        "SPEAKER_01",
        "Sì, Alice. Il database PostgreSQL è pronto, ma la pipeline CI/CD ha ancora un timeout.",
    ),
    (
        "Alice",
        "SPEAKER_00",
        "Capisco. Puoi verificare anche l'API di Qwen3-ASR e il modello Parakeet?",
    ),
    (
        "Eddy (Italian (Italy))",
        "SPEAKER_01",
        "Certo. Prima faccio il code review, poi aggiorno il benchmark su GitHub.",
    ),
    ("Alice", "SPEAKER_00", "Perfetto, grazie."),
    (
        "Eddy (Italian (Italy))",
        "SPEAKER_01",
        "Prego. Ah, un momento, devo correggere la configurazione Docker.",
    ),
    ("Alice", "SPEAKER_00", "Va bene."),
]

BACKCHANNELS = ["Sì", "Capisco", "Certo", "Perfetto", "Prego", "Ah", "Va bene"]

class BuildError(RuntimeError):
    pass


def t6(value: float) -> float:
    return float(f"{float(value):.6f}")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def write_json(path: Path, payload: object) -> None:
    path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def write_text(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")


def _contains_hangul(text: str) -> bool:
    return any("\uac00" <= character <= "\ud7a3" for character in text)


def _is_latin_alnum(character: str) -> bool:
    return character.isdigit() or (
        unicodedata.category(character).startswith("L")
        and "LATIN" in unicodedata.name(character, "")
    )


def count_term_occurrences(term: str, transcript: str) -> int:
    if not term.strip():
        raise ValueError("term must not be empty")
    if _contains_hangul(term):
        normalized_term = "".join(unicodedata.normalize("NFKC", term).casefold().split())
        normalized_transcript = "".join(
            unicodedata.normalize("NFKC", transcript).casefold().split()
        )
        return len(re.findall(re.escape(normalized_term), normalized_transcript))
    normalized_term = unicodedata.normalize("NFKC", term).casefold().strip()
    normalized_transcript = unicodedata.normalize("NFKC", transcript).casefold()
    components = [
        component for component in re.split(r"[\s_-]+", normalized_term) if component
    ]
    if not components:
        raise ValueError("term must contain a non-separator character")
    pattern = re.compile(r"[\s_-]*".join(re.escape(component) for component in components))
    count = 0
    for match in pattern.finditer(normalized_transcript):
        left = normalized_transcript[match.start() - 1] if match.start() else None
        right = (
            normalized_transcript[match.end()]
            if match.end() < len(normalized_transcript)
            else None
        )
        if left is not None and _is_latin_alnum(left):
            continue
        if right is not None and _is_latin_alnum(right):
            continue
        count += 1
    return count


def terms_payload(terms: list[str], reference_text: str) -> list[dict[str, Any]]:
    return [
        {"term": term, "reference_count": count_term_occurrences(term, reference_text)}
        for term in terms
    ]


def glossary_text(terms: list[str]) -> str:
    return "".join(f"{term}\n" for term in terms)


def decode_audio_bytes(raw: bytes) -> tuple[np.ndarray, int, list[str]]:
    data, sample_rate = sf.read(io.BytesIO(raw), dtype="float64", always_2d=True)
    steps: list[str] = ["decode_soundfile_float64"]
    if data.shape[1] > 1:
        data = data.mean(axis=1, keepdims=True)
        steps.append("mono_downmix_mean")
    mono = data[:, 0]
    if sample_rate != TARGET_HZ:
        duration = mono.shape[0] / float(sample_rate)
        target_len = int(round(duration * TARGET_HZ))
        if target_len < 1:
            raise BuildError("resampled audio empty")
        source_x = np.linspace(0.0, 1.0, num=mono.shape[0], endpoint=False)
        target_x = np.linspace(0.0, 1.0, num=target_len, endpoint=False)
        mono = np.interp(target_x, source_x, mono).astype(np.float64, copy=False)
        steps.append(f"resample_linear_{sample_rate}_to_{TARGET_HZ}")
        sample_rate = TARGET_HZ
    if not np.isfinite(mono).all():
        raise BuildError("non-finite audio samples")
    if mono.size == 0:
        raise BuildError("empty audio")
    pcm = np.clip(np.rint(mono * 32767.0), -32768, 32767).astype(np.int16)
    steps.append("pcm16_encode_rint_clip")
    return pcm, sample_rate, steps


def write_wav(path: Path, pcm: np.ndarray) -> dict[str, Any]:
    if pcm.dtype != np.int16 or pcm.ndim != 1 or pcm.size == 0:
        raise BuildError(f"invalid PCM for {logical_path(path)}")
    sf.write(str(path), pcm, TARGET_HZ, subtype="PCM_16", format="WAV")
    info = sf.info(str(path))
    if info.samplerate != TARGET_HZ or info.channels != 1 or info.subtype != "PCM_16":
        raise BuildError(f"WAV contract failed for {logical_path(path)}: {info}")
    duration_s = t6(pcm.shape[0] / TARGET_HZ)
    return {
        "path": logical_path(path),
        "sha256": sha256_file(path),
        "size_bytes": path.stat().st_size,
        "duration_s": duration_s,
        "sample_rate_hz": TARGET_HZ,
        "channels": 1,
        "subtype": "PCM_16",
        "num_samples": int(pcm.shape[0]),
    }


def silence_pcm(duration_s: float) -> np.ndarray:
    n = int(round(duration_s * TARGET_HZ))
    if n <= 0:
        raise BuildError("silence duration must be positive")
    return np.zeros(n, dtype=np.int16)


def concatenate_with_silence(
    pieces: list[np.ndarray], separator_s: float
) -> tuple[np.ndarray, list[dict[str, float]], list[str]]:
    if not pieces:
        raise BuildError("no audio pieces")
    sep = silence_pcm(separator_s) if separator_s > 0 else np.zeros(0, dtype=np.int16)
    out_parts: list[np.ndarray] = []
    extents: list[dict[str, float]] = []
    cursor = 0
    for index, piece in enumerate(pieces):
        start = cursor
        out_parts.append(piece)
        cursor += int(piece.shape[0])
        end = cursor
        extents.append({"start_s": t6(start / TARGET_HZ), "end_s": t6(end / TARGET_HZ)})
        if index + 1 < len(pieces) and sep.size:
            out_parts.append(sep)
            cursor += int(sep.size)
    steps = [
        "concatenate_pcm16",
        f"insert_zero_pcm_silence_{separator_s:.3f}s_between_utterances",
    ]
    return np.concatenate(out_parts), extents, steps


def validate_segments_document(doc: dict[str, Any], wav_duration_s: float) -> list[str]:
    checked: list[str] = []
    if doc.get("schema_version") != "1.0.0":
        raise BuildError("segments schema_version must be 1.0.0")
    checked.append("schema_version=1.0.0")
    segments = doc.get("segments")
    if not isinstance(segments, list) or not segments:
        raise BuildError("segments must be a nonempty array")
    prev_start = -1.0
    speakers: set[str] = set()
    for index, segment in enumerate(segments):
        if not isinstance(segment, dict):
            raise BuildError(f"segment {index} not object")
        for key in ("speaker", "start_s", "end_s", "text"):
            if key not in segment:
                raise BuildError(f"segment {index} missing {key}")
        speaker = segment["speaker"]
        start_s = float(segment["start_s"])
        end_s = float(segment["end_s"])
        text = segment["text"]
        if not isinstance(speaker, str) or not speaker:
            raise BuildError(f"segment {index} invalid speaker")
        if not isinstance(text, str) or not text:
            raise BuildError(f"segment {index} empty text")
        if start_s < 0 or end_s <= start_s:
            raise BuildError(f"segment {index} invalid times {start_s}..{end_s}")
        if end_s > wav_duration_s + 1e-9:
            raise BuildError(
                f"segment {index} end_s {end_s} exceeds duration {wav_duration_s}"
            )
        if start_s < prev_start - 1e-12:
            raise BuildError(f"segment {index} not chronological")
        prev_start = start_s
        speakers.add(speaker)
        if "flags" in segment:
            flags = segment["flags"]
            if not isinstance(flags, list) or len(flags) != len(set(flags)):
                raise BuildError(f"segment {index} invalid flags")
            for flag in flags:
                if not re.fullmatch(r"[a-z][a-z0-9_-]*", flag):
                    raise BuildError(f"segment {index} bad flag {flag!r}")
    if int(doc.get("num_speakers", -1)) != len(speakers):
        raise BuildError("num_speakers mismatch")
    source = doc.get("source")
    if not isinstance(source, dict):
        raise BuildError("missing source")
    for key in ("file_name", "sha256", "duration_s"):
        if key not in source:
            raise BuildError(f"source missing {key}")
    if source["file_name"] != "input.wav":
        raise BuildError("source.file_name must be input.wav")
    if not re.fullmatch(r"[0-9a-f]{64}", source["sha256"]):
        raise BuildError("source.sha256 invalid")
    if t6(float(source["duration_s"])) != t6(wav_duration_s):
        raise BuildError("source.duration_s mismatch")
    checked.append("segments_ordered_nonempty_within_wav")
    checked.append("source_basename_hash_duration")
    return checked


def parse_rttm(text: str) -> list[dict[str, Any]]:
    turns: list[dict[str, Any]] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split()
        if len(fields) < 8 or fields[0] != "SPEAKER":
            raise BuildError(f"RTTM line {line_number}: expected SPEAKER")
        start = float(fields[3])
        duration = float(fields[4])
        if start < 0 or duration <= 0:
            raise BuildError(f"RTTM line {line_number}: invalid start/duration")
        turns.append(
            {
                "file_id": fields[1],
                "start_s": start,
                "duration_s": duration,
                "end_s": start + duration,
                "speaker": fields[7],
            }
        )
    return turns


def write_rttm(path: Path, file_id: str, turns: list[dict[str, Any]]) -> str:
    lines = []
    for turn in turns:
        start = float(turn["start_s"])
        end = float(turn["end_s"])
        duration = end - start
        if duration <= 0:
            raise BuildError("RTTM non-positive duration")
        lines.append(
            f"SPEAKER {file_id} 1 {start:.6f} {duration:.6f} <NA> <NA> {turn['speaker']} <NA> <NA>"
        )
    content = "\n".join(lines) + ("\n" if lines else "")
    path.write_text(content, encoding="utf-8")
    return sha256_file(path)


def validate_rttm_against_segments(
    rttm_turns: list[dict[str, Any]],
    segments: list[dict[str, Any]],
    wav_duration_s: float,
) -> list[str]:
    if not rttm_turns:
        raise BuildError("RTTM empty")
    for turn in rttm_turns:
        if turn["end_s"] > wav_duration_s + 1e-6:
            raise BuildError("RTTM end exceeds WAV")
    rttm_speakers = {turn["speaker"] for turn in rttm_turns}
    seg_speakers = {segment["speaker"] for segment in segments}
    if rttm_speakers != seg_speakers:
        raise BuildError(
            f"RTTM/segment speaker set mismatch: {sorted(rttm_speakers)} vs {sorted(seg_speakers)}"
        )
    return ["rttm_parse_positive_within_wav", "rttm_speaker_set_equals_segments"]


def ensure_voices_available() -> None:
    if not SAY.is_file():
        raise BuildError("/usr/bin/say missing")
    listed = subprocess.run(
        [str(SAY), "-v", "?"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    needed = {"Alice", "Eddy (Italian (Italy))"}
    present: set[str] = set()
    for line in listed.splitlines():
        for voice in needed:
            if line.startswith(voice) and (
                len(line) == len(voice) or line[len(voice)].isspace()
            ):
                present.add(voice)
    missing = sorted(needed - present)
    if missing:
        raise BuildError(f"missing local say voices: {missing}")


def say_generator_provenance(definition_sha256: str) -> dict[str, Any]:
    """Record the exact local synthesizer rather than a fictitious dataset revision."""
    if not SAY.is_file():
        raise BuildError("/usr/bin/say missing")

    def command_output(*args: str) -> str:
        return subprocess.run(
            list(args), check=True, capture_output=True, text=True
        ).stdout.strip()

    signature = subprocess.run(
        ["/usr/bin/codesign", "-dvv", str(SAY)],
        check=True,
        capture_output=True,
        text=True,
    ).stderr
    identifier_match = re.search(r"^Identifier=(.+)$", signature, flags=re.MULTILINE)
    if identifier_match is None:
        raise BuildError("could not determine /usr/bin/say signing identifier")
    return {
        "kind": "local_synthetic",
        "generator": {
            "tool_path": str(SAY),
            "macos_product_version": command_output("/usr/bin/sw_vers", "-productVersion"),
            "macos_build_version": command_output("/usr/bin/sw_vers", "-buildVersion"),
            "code_signing_identifier": identifier_match.group(1),
            "binary_sha256": sha256_file(SAY),
        },
        "definition_relative_path": "benchmarks/scripts/fixtures/build_stage2_fixtures.py",
        "definition_sha256": definition_sha256,
        "migration_lineage": {
            "legacy_builder_relative_path": LEGACY_DEFINITION_RELATIVE_PATH,
            "legacy_builder_sha256": LEGACY_DEFINITION_SHA256,
        },
    }


def synthesize_say(voice: str, rate: int, text: str, out_path: Path) -> list[str]:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [str(SAY), "-v", voice, "-r", str(rate), "-o", str(out_path), text],
        check=True,
        capture_output=True,
        text=True,
    )
    if not out_path.is_file() or out_path.stat().st_size == 0:
        raise BuildError(f"say produced empty file for voice={voice!r}")
    return [f"say_voice={voice}", f"say_rate={rate}", "say_write_aiff"]


def build_segments_doc(
    segments: list[dict[str, Any]],
    wav_meta: dict[str, Any],
) -> dict[str, Any]:
    speakers = {segment["speaker"] for segment in segments}
    return {
        "schema_version": "1.0.0",
        "num_speakers": len(speakers),
        "segments": segments,
        "source": {
            "file_name": "input.wav",
            "sha256": wav_meta["sha256"],
            "duration_s": wav_meta["duration_s"],
        },
    }


def write_common_sidecars(
    fixture_dir: Path,
    *,
    terms: list[dict[str, Any]],
    glossary_terms: list[str],
    selection: dict[str, Any],
    segments_doc: dict[str, Any],
    rttm_sha256: str | None,
    wav_meta: dict[str, Any],
    checked: list[str],
    source_hashes_before: dict[str, str],
    source_hashes_after: dict[str, str],
    extra_check: dict[str, Any] | None = None,
) -> dict[str, Any]:
    write_json(fixture_dir / "terms.json", terms)
    write_text(fixture_dir / "glossary.txt", glossary_text(glossary_terms))
    write_json(fixture_dir / "selection.json", selection)
    write_json(fixture_dir / "reference.segments.json", segments_doc)

    artifact_hashes = {
        "input.wav": wav_meta["sha256"],
        "reference.segments.json": sha256_file(fixture_dir / "reference.segments.json"),
        "terms.json": sha256_file(fixture_dir / "terms.json"),
        "glossary.txt": sha256_file(fixture_dir / "glossary.txt"),
        "selection.json": sha256_file(fixture_dir / "selection.json"),
    }
    if rttm_sha256 is not None:
        artifact_hashes["reference.rttm"] = rttm_sha256

    segment_speakers = {seg["speaker"] for seg in segments_doc["segments"]}
    check: dict[str, Any] = {
        "fixture_id": selection["fixture_id"],
        "input_wav": {
            "sha256": wav_meta["sha256"],
            "size_bytes": wav_meta["size_bytes"],
            "duration_s": wav_meta["duration_s"],
            "sample_rate_hz": wav_meta["sample_rate_hz"],
            "channels": wav_meta["channels"],
            "subtype": wav_meta["subtype"],
        },
        "artifact_sha256": artifact_hashes,
        "reference_segment_count": len(segments_doc["segments"]),
        "reference_rttm_count": (
            len(parse_rttm((fixture_dir / "reference.rttm").read_text(encoding="utf-8")))
            if rttm_sha256 is not None
            else 0
        ),
        "speaker_count": len(segment_speakers),
        "checked_invariants": sorted(set(checked)),
        "source_hashes_before": source_hashes_before,
        "source_hashes_after": source_hashes_after,
        "passed": True,
    }
    if extra_check:
        check.update(extra_check)
    write_json(fixture_dir / "fixture-check.json", check)
    return check


def require_absent(path: Path) -> None:
    if path.exists():
        raise BuildError(
            f"refusing to write; target already exists: {logical_path(path)}"
        )


def select_fleurs_rows(table: Any) -> tuple[list[int], dict[str, Any]]:
    num_samples = table.column("num_samples").to_pylist()
    genders = table.column("gender").to_pylist()
    ids = table.column("id").to_pylist()
    audio_paths = [table.column("audio")[i]["path"].as_py() for i in range(table.num_rows)]
    eligible_by_gender: dict[Any, list[int]] = {}
    for index, (samples, gender) in enumerate(zip(num_samples, genders, strict=True)):
        if 80_000 <= int(samples) <= 240_000:
            eligible_by_gender.setdefault(gender, []).append(index)
    distinct = sorted(eligible_by_gender.keys(), key=lambda value: str(value))
    if len(distinct) != 2:
        raise BuildError(f"expected exactly two gender values, got {distinct!r}")
    selected: list[int] = []
    per_gender: dict[str, list[dict[str, Any]]] = {}
    for gender in distinct:
        group = eligible_by_gender[gender]
        group_sorted = sorted(
            group,
            key=lambda i: (int(ids[i]), str(audio_paths[i])),
        )
        if len(group_sorted) < 4:
            raise BuildError(f"gender {gender!r} has fewer than 4 eligible rows")
        chosen = group_sorted[:4]
        per_gender[str(gender)] = [
            {
                "row_index": i,
                "id": int(ids[i]),
                "audio.path": audio_paths[i],
                "num_samples": int(num_samples[i]),
                "gender": gender,
            }
            for i in chosen
        ]
        selected.extend(chosen)
    selected = sorted(
        selected,
        key=lambda i: (str(genders[i]), int(ids[i]), str(audio_paths[i])),
    )
    if len(selected) != 8 or len(set(selected)) != 8:
        raise BuildError("FLEURS selection must be 8 unique rows")
    meta = {
        "algorithm": (
            "eligible num_samples in [80000,240000]; group by exact gender; "
            "sort each group by (id, audio.path); take first 4 per each of 2 genders; "
            "sort selected by (str(gender), id, audio.path)"
        ),
        "raw_gender_values": list(distinct),
        "per_gender_first4": per_gender,
        "selected_row_indexes": selected,
    }
    return selected, meta


def build_hike_tech(source_hashes_before: dict[str, str]) -> dict[str, Any]:
    fixture_dir = OUTPUT_ROOT / "benchmarks/runs/ko-asr/fixtures/hike-tech"
    require_absent(fixture_dir)
    fixture_dir.mkdir(parents=True, exist_ok=False)
    items_dir = fixture_dir / "items"
    items_dir.mkdir()

    table = pq.read_table(SOURCE_FILES["hike_parquet"])
    by_id = {
        sample_id: index
        for index, sample_id in enumerate(table.column("sample_id").to_pylist())
    }
    missing = [sample_id for sample_id in HIKE_SAMPLE_IDS if sample_id not in by_id]
    if missing:
        raise BuildError(f"HiKE sample_id missing: {missing}")
    if len(HIKE_SAMPLE_IDS) != len(set(HIKE_SAMPLE_IDS)):
        raise BuildError("HiKE sample_id list has duplicates")

    pieces: list[np.ndarray] = []
    item_records: list[dict[str, Any]] = []
    reference_parts: list[str] = []
    for order, sample_id in enumerate(HIKE_SAMPLE_IDS):
        row = by_id[sample_id]
        audio_bytes = table.column("audio")[row]["bytes"].as_py()
        source_audio_sha = sha256_bytes(audio_bytes)
        pcm, sr, steps = decode_audio_bytes(audio_bytes)
        if sr != TARGET_HZ:
            raise BuildError("HiKE decode did not land on 16 kHz")
        item_path = items_dir / f"{order:03d}.wav"
        item_meta = write_wav(item_path, pcm)
        text_normalized = table.column("text_normalized")[row].as_py()
        reference_parts.append(text_normalized)
        item_records.append(
            {
                "order": order,
                "sample_id": sample_id,
                "row_index": row,
                "text": table.column("text")[row].as_py(),
                "text_normalized": text_normalized,
                "text_pier_labeled": table.column("text_pier_labeled")[row].as_py(),
                "loanwords": table.column("loanwords")[row].as_py(),
                "cs_level": table.column("cs_level")[row].as_py(),
                "category": table.column("category")[row].as_py(),
                "source_audio_sha256": source_audio_sha,
                "source_duration_s": t6(item_meta["num_samples"] / TARGET_HZ),
                "item_wav": f"items/{order:03d}.wav",
                "item_wav_sha256": item_meta["sha256"],
                "transformation_steps": steps,
            }
        )
        pieces.append(pcm)

    concat, extents, concat_steps = concatenate_with_silence(pieces, 0.500)
    for record, extent in zip(item_records, extents, strict=True):
        record["reel_start_s"] = extent["start_s"]
        record["reel_end_s"] = extent["end_s"]

    wav_meta = write_wav(fixture_dir / "input.wav", concat)
    reference_text = " ".join(reference_parts)
    terms = terms_payload(KO_TERMS, reference_text)
    zero = [entry["term"] for entry in terms if entry["reference_count"] <= 0]
    if zero:
        raise BuildError(f"hike-tech terms with zero occurrences: {zero}")

    segments = []
    rttm_turns = []
    for record, extent in zip(item_records, extents, strict=True):
        segments.append(
            {
                "speaker": "SPEAKER_00",
                "start_s": extent["start_s"],
                "end_s": extent["end_s"],
                "text": record["text_normalized"],
                "language": "ko",
            }
        )
        rttm_turns.append(
            {
                "start_s": extent["start_s"],
                "end_s": extent["end_s"],
                "speaker": "SPEAKER_00",
            }
        )
    segments_doc = build_segments_doc(segments, wav_meta)
    checked = validate_segments_document(segments_doc, wav_meta["duration_s"])
    rttm_sha = write_rttm(fixture_dir / "reference.rttm", "hike-tech", rttm_turns)
    checked.extend(
        validate_rttm_against_segments(
            parse_rttm((fixture_dir / "reference.rttm").read_text(encoding="utf-8")),
            segments,
            wav_meta["duration_s"],
        )
    )
    checked.append("selected_row_count_unique=12")
    checked.append("required_glossary_terms_occur")

    selection = {
        "fixture_id": "hike-tech",
        "purpose": "Korean code-switched tech ASR glossary recall reel from HiKE",
        "public_source": {
            **DATASET_META["hike"],
            "source_relative_path": "benchmarks/samples/public/hike/data/test-00000-of-00001.parquet",
            "source_sha256": source_hashes_before["hike_parquet"],
        },
        "selected_row_ids": HIKE_SAMPLE_IDS,
        "reference_text": reference_text,
        "separator_duration_s": 0.5,
        "output_start_s": 0.0,
        "output_end_s": wav_meta["duration_s"],
        "transformation_steps": concat_steps,
        "items": item_records,
        "term_reference_occurrences": {
            entry["term"]: entry["reference_count"] for entry in terms
        },
    }
    source_hashes_after = {key: sha256_file(path) for key, path in SOURCE_FILES.items()}
    check = write_common_sidecars(
        fixture_dir,
        terms=terms,
        glossary_terms=KO_TERMS,
        selection=selection,
        segments_doc=segments_doc,
        rttm_sha256=rttm_sha,
        wav_meta=wav_meta,
        checked=checked,
        source_hashes_before=source_hashes_before,
        source_hashes_after=source_hashes_after,
    )
    return {
        "path": logical_path(fixture_dir),
        "duration_s": wav_meta["duration_s"],
        "speaker_count": check["speaker_count"],
        "segment_count": check["reference_segment_count"],
        "wav_sha256": wav_meta["sha256"],
        "source_hashes_unchanged": source_hashes_before == source_hashes_after,
        "passed": True,
        "_wav_meta": wav_meta,
        "_segments_bytes": (fixture_dir / "reference.segments.json").read_bytes(),
        "_rttm_bytes": (fixture_dir / "reference.rttm").read_bytes(),
        "_terms": terms,
        "_glossary_terms": KO_TERMS,
        "_selection": selection,
    }


def build_fleurs_clean(
    *,
    fixture_id: str,
    fixture_dir: Path,
    parquet_key: str,
    language: str,
    relative_parquet: str,
    terms_list: list[str],
    purpose: str,
    source_hashes_before: dict[str, str],
    require_zero_terms: bool,
) -> dict[str, Any]:
    require_absent(fixture_dir)
    fixture_dir.mkdir(parents=True, exist_ok=False)
    items_dir = fixture_dir / "items"
    items_dir.mkdir()

    table = pq.read_table(SOURCE_FILES[parquet_key])
    selected, algo_meta = select_fleurs_rows(table)
    pieces: list[np.ndarray] = []
    item_records: list[dict[str, Any]] = []
    reference_parts: list[str] = []
    for order, row in enumerate(selected):
        audio_struct = table.column("audio")[row]
        audio_bytes = audio_struct["bytes"].as_py()
        audio_path = audio_struct["path"].as_py()
        pcm, sr, steps = decode_audio_bytes(audio_bytes)
        if sr != TARGET_HZ:
            raise BuildError(f"{fixture_id}: decode not 16 kHz")
        item_meta = write_wav(items_dir / f"{order:03d}.wav", pcm)
        transcription = table.column("transcription")[row].as_py()
        reference_parts.append(transcription)
        item_records.append(
            {
                "order": order,
                "row_index": row,
                "id": int(table.column("id")[row].as_py()),
                "gender": table.column("gender")[row].as_py(),
                "num_samples": int(table.column("num_samples")[row].as_py()),
                "audio.path": audio_path,
                "transcription": transcription,
                "raw_transcription": table.column("raw_transcription")[row].as_py(),
                "source_audio_sha256": sha256_bytes(audio_bytes),
                "source_duration_s": t6(item_meta["num_samples"] / TARGET_HZ),
                "item_wav": f"items/{order:03d}.wav",
                "item_wav_sha256": item_meta["sha256"],
                "transformation_steps": steps,
            }
        )
        pieces.append(pcm)

    concat, extents, concat_steps = concatenate_with_silence(pieces, 0.500)
    for record, extent in zip(item_records, extents, strict=True):
        record["reel_start_s"] = extent["start_s"]
        record["reel_end_s"] = extent["end_s"]
    wav_meta = write_wav(fixture_dir / "input.wav", concat)
    reference_text = " ".join(reference_parts)
    terms = terms_payload(terms_list, reference_text)
    # Clean FLEURS fixtures expect zero glossary hits; record actual counts as-is.

    segments = []
    rttm_turns = []
    for record, extent in zip(item_records, extents, strict=True):
        segments.append(
            {
                "speaker": "SPEAKER_00",
                "start_s": extent["start_s"],
                "end_s": extent["end_s"],
                "text": record["transcription"],
                "language": language,
            }
        )
        rttm_turns.append(
            {
                "start_s": extent["start_s"],
                "end_s": extent["end_s"],
                "speaker": "SPEAKER_00",
            }
        )
    segments_doc = build_segments_doc(segments, wav_meta)
    checked = validate_segments_document(segments_doc, wav_meta["duration_s"])
    rttm_sha = write_rttm(fixture_dir / "reference.rttm", fixture_id, rttm_turns)
    checked.extend(
        validate_rttm_against_segments(
            parse_rttm((fixture_dir / "reference.rttm").read_text(encoding="utf-8")),
            segments,
            wav_meta["duration_s"],
        )
    )
    checked.append("selected_row_count_unique=8")
    checked.append("glossary_occurrence_counts_recorded")

    selection = {
        "fixture_id": fixture_id,
        "purpose": purpose,
        "public_source": {
            "dataset_id": DATASET_META["fleurs"]["dataset_id"],
            "revision": DATASET_META["fleurs"]["revision"],
            "source_relative_path": relative_parquet,
            "source_sha256": source_hashes_before[parquet_key],
        },
        "selection_algorithm": algo_meta,
        "selected_row_ids": [
            {
                "id": record["id"],
                "audio.path": record["audio.path"],
                "gender": record["gender"],
            }
            for record in item_records
        ],
        "reference_text": reference_text,
        "separator_duration_s": 0.5,
        "output_start_s": 0.0,
        "output_end_s": wav_meta["duration_s"],
        "transformation_steps": concat_steps,
        "items": item_records,
        "term_reference_occurrences": {
            entry["term"]: entry["reference_count"] for entry in terms
        },
        "expected_term_occurrences": "zero_for_overfire_detection"
        if require_zero_terms
        else "n/a",
    }
    source_hashes_after = {key: sha256_file(path) for key, path in SOURCE_FILES.items()}
    check = write_common_sidecars(
        fixture_dir,
        terms=terms,
        glossary_terms=terms_list,
        selection=selection,
        segments_doc=segments_doc,
        rttm_sha256=rttm_sha,
        wav_meta=wav_meta,
        checked=checked,
        source_hashes_before=source_hashes_before,
        source_hashes_after=source_hashes_after,
        extra_check={
            "term_reference_occurrences": {
                entry["term"]: entry["reference_count"] for entry in terms
            }
        },
    )
    return {
        "path": logical_path(fixture_dir),
        "duration_s": wav_meta["duration_s"],
        "speaker_count": check["speaker_count"],
        "segment_count": check["reference_segment_count"],
        "wav_sha256": wav_meta["sha256"],
        "source_hashes_unchanged": source_hashes_before == source_hashes_after,
        "passed": True,
    }


def build_italian_dialogue(source_hashes_before: dict[str, str]) -> dict[str, Any]:
    fixture_dir = OUTPUT_ROOT / "benchmarks/runs/it-asr/fixtures/italian-dialogue"
    require_absent(fixture_dir)
    fixture_dir.mkdir(parents=True, exist_ok=False)
    items_dir = fixture_dir / "items"
    temp_dir = fixture_dir / "_say_tmp"
    items_dir.mkdir()
    temp_dir.mkdir()

    ensure_voices_available()
    pieces: list[np.ndarray] = []
    item_records: list[dict[str, Any]] = []
    reference_parts: list[str] = []
    try:
        for order, (voice, speaker, text) in enumerate(IT_DIALOGUE):
            raw_path = temp_dir / f"{order:03d}.aiff"
            say_steps = synthesize_say(voice, 180, text, raw_path)
            raw = raw_path.read_bytes()
            pcm, sr, decode_steps = decode_audio_bytes(raw)
            if sr != TARGET_HZ:
                raise BuildError("say decode not 16 kHz")
            item_meta = write_wav(items_dir / f"{order:03d}.wav", pcm)
            reference_parts.append(text)
            item_records.append(
                {
                    "order": order,
                    "speaker": speaker,
                    "say": {"voice": voice, "rate": 180, "text": text},
                    "source_audio_sha256": sha256_bytes(raw),
                    "source_duration_s": t6(item_meta["num_samples"] / TARGET_HZ),
                    "item_wav": f"items/{order:03d}.wav",
                    "item_wav_sha256": item_meta["sha256"],
                    "transformation_steps": say_steps + decode_steps,
                }
            )
            pieces.append(pcm)
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)

    concat, extents, concat_steps = concatenate_with_silence(pieces, 0.400)
    for record, extent in zip(item_records, extents, strict=True):
        record["reel_start_s"] = extent["start_s"]
        record["reel_end_s"] = extent["end_s"]
    wav_meta = write_wav(fixture_dir / "input.wav", concat)
    reference_text = " ".join(reference_parts)
    terms = terms_payload(IT_TERMS, reference_text)
    zero = [entry["term"] for entry in terms if entry["reference_count"] <= 0]
    if zero:
        raise BuildError(f"italian-dialogue terms with zero occurrences: {zero}")
    backchannel_counts = {
        term: count_term_occurrences(term, reference_text) for term in BACKCHANNELS
    }
    if any(count <= 0 for count in backchannel_counts.values()):
        raise BuildError(f"backchannel missing in reference: {backchannel_counts}")

    segments = []
    rttm_turns = []
    for record, extent in zip(item_records, extents, strict=True):
        segments.append(
            {
                "speaker": record["speaker"],
                "start_s": extent["start_s"],
                "end_s": extent["end_s"],
                "text": record["say"]["text"],
                "language": "it",
            }
        )
        rttm_turns.append(
            {
                "start_s": extent["start_s"],
                "end_s": extent["end_s"],
                "speaker": record["speaker"],
            }
        )
    segments_doc = build_segments_doc(segments, wav_meta)
    checked = validate_segments_document(segments_doc, wav_meta["duration_s"])
    rttm_sha = write_rttm(fixture_dir / "reference.rttm", "italian-dialogue", rttm_turns)
    checked.extend(
        validate_rttm_against_segments(
            parse_rttm((fixture_dir / "reference.rttm").read_text(encoding="utf-8")),
            segments,
            wav_meta["duration_s"],
        )
    )
    checked.append("required_glossary_terms_occur")
    checked.append("backchannel_annotations_recorded")

    dialogue_definition = [
        {"voice": voice, "speaker": speaker, "rate": 180, "text": text}
        for voice, speaker, text in IT_DIALOGUE
    ]
    dialogue_definition_sha256 = sha256_bytes(
        json.dumps(
            dialogue_definition, ensure_ascii=False, separators=(",", ":"), sort_keys=True
        ).encode("utf-8")
    )
    selection = {
        "fixture_id": "italian-dialogue",
        "purpose": "Synthetic Italian two-speaker glossary dialogue via /usr/bin/say",
        "public_source": say_generator_provenance(dialogue_definition_sha256),
        "selected_row_ids": [f"say-{order:03d}" for order in range(len(IT_DIALOGUE))],
        "reference_text": reference_text,
        "separator_duration_s": 0.4,
        "output_start_s": 0.0,
        "output_end_s": wav_meta["duration_s"],
        "transformation_steps": concat_steps,
        "items": item_records,
        "say_utterances": [
            {"voice": voice, "rate": 180, "text": text, "speaker": speaker}
            for voice, speaker, text in IT_DIALOGUE
        ],
        "term_reference_occurrences": {
            entry["term"]: entry["reference_count"] for entry in terms
        },
        "backchannel_reference_occurrences": backchannel_counts,
    }
    source_hashes_after = {key: sha256_file(path) for key, path in SOURCE_FILES.items()}
    check = write_common_sidecars(
        fixture_dir,
        terms=terms,
        glossary_terms=IT_TERMS,
        selection=selection,
        segments_doc=segments_doc,
        rttm_sha256=rttm_sha,
        wav_meta=wav_meta,
        checked=checked,
        source_hashes_before=source_hashes_before,
        source_hashes_after=source_hashes_after,
        extra_check={"backchannel_reference_occurrences": backchannel_counts},
    )
    return {
        "path": logical_path(fixture_dir),
        "duration_s": wav_meta["duration_s"],
        "speaker_count": check["speaker_count"],
        "segment_count": check["reference_segment_count"],
        "wav_sha256": wav_meta["sha256"],
        "source_hashes_unchanged": source_hashes_before == source_hashes_after,
        "passed": True,
        "_wav_meta": wav_meta,
        "_segments_bytes": (fixture_dir / "reference.segments.json").read_bytes(),
        "_rttm_bytes": (fixture_dir / "reference.rttm").read_bytes(),
        "_terms": terms,
        "_glossary_terms": IT_TERMS,
        "_selection": selection,
    }


def copy_cross_task(
    *,
    fixture_id: str,
    fixture_dir: Path,
    source_summary: dict[str, Any],
    source_fixture_rel: str,
    purpose: str,
    source_hashes_before: dict[str, str],
) -> dict[str, Any]:
    require_absent(fixture_dir)
    fixture_dir.mkdir(parents=True, exist_ok=False)
    src = OUTPUT_ROOT / source_fixture_rel
    for name in ("input.wav", "reference.segments.json", "reference.rttm"):
        target = fixture_dir / name
        data = (src / name).read_bytes()
        target.write_bytes(data)
        if name == "input.wav" and sha256_bytes(data) != source_summary["wav_sha256"]:
            raise BuildError(f"{fixture_id}: copied WAV hash mismatch")
        if name == "reference.rttm" and sha256_bytes(data) != sha256_bytes(
            source_summary["_rttm_bytes"]
        ):
            raise BuildError(f"{fixture_id}: copied RTTM hash mismatch")
        if name == "reference.segments.json" and sha256_bytes(data) != sha256_bytes(
            source_summary["_segments_bytes"]
        ):
            raise BuildError(f"{fixture_id}: copied segments hash mismatch")

    for item in source_summary["_selection"].get("items", []):
        relative = Path(item["item_wav"])
        if relative.is_absolute() or ".." in relative.parts:
            raise BuildError(f"{fixture_id}: unsafe source item path")
        source_item = src / relative
        target_item = fixture_dir / relative
        target_item.parent.mkdir(parents=True, exist_ok=True)
        data = source_item.read_bytes()
        target_item.write_bytes(data)
        if sha256_bytes(data) != item["item_wav_sha256"]:
            raise BuildError(f"{fixture_id}: copied item hash mismatch: {relative}")

    wav_meta = {
        "sha256": sha256_file(fixture_dir / "input.wav"),
        "size_bytes": (fixture_dir / "input.wav").stat().st_size,
        "duration_s": source_summary["duration_s"],
        "sample_rate_hz": TARGET_HZ,
        "channels": 1,
        "subtype": "PCM_16",
    }
    if wav_meta["sha256"] != source_summary["wav_sha256"]:
        raise BuildError(f"{fixture_id}: WAV sha mismatch after copy")
    rttm_sha = sha256_file(fixture_dir / "reference.rttm")
    if rttm_sha != sha256_file(src / "reference.rttm"):
        raise BuildError(f"{fixture_id}: RTTM sha mismatch after copy")

    segments_doc = json.loads(
        (fixture_dir / "reference.segments.json").read_text(encoding="utf-8")
    )
    checked = validate_segments_document(segments_doc, wav_meta["duration_s"])
    checked.extend(
        validate_rttm_against_segments(
            parse_rttm((fixture_dir / "reference.rttm").read_text(encoding="utf-8")),
            segments_doc["segments"],
            wav_meta["duration_s"],
        )
    )
    checked.append("copied_wav_hash_matches_source_fixture")
    checked.append("copied_rttm_hash_matches_source_fixture")

    source_selection = source_summary["_selection"]
    selection = {
        "fixture_id": fixture_id,
        "purpose": purpose,
        "provenance": {
            "copied_from_fixture": source_fixture_rel,
            "copied_from_fixture_id": source_selection["fixture_id"],
            "source_input_wav_sha256": source_summary["wav_sha256"],
            "source_reference_rttm_sha256": sha256_bytes(source_summary["_rttm_bytes"]),
            "source_reference_segments_sha256": sha256_bytes(
                source_summary["_segments_bytes"]
            ),
            "copy_mode": "byte_for_byte",
        },
        "public_source": source_selection.get("public_source"),
        "selected_row_ids": source_selection.get("selected_row_ids"),
        "reference_text": source_selection.get("reference_text"),
        "separator_duration_s": source_selection.get("separator_duration_s"),
        "output_start_s": 0.0,
        "output_end_s": wav_meta["duration_s"],
        "transformation_steps": [
            f"byte_copy_from:{source_fixture_rel}/input.wav",
            f"byte_copy_from:{source_fixture_rel}/reference.segments.json",
            f"byte_copy_from:{source_fixture_rel}/reference.rttm",
        ],
        "term_reference_occurrences": source_selection.get("term_reference_occurrences"),
        "items": source_selection.get("items"),
        "say_utterances": source_selection.get("say_utterances"),
        "backchannel_reference_occurrences": source_selection.get(
            "backchannel_reference_occurrences"
        ),
    }
    source_hashes_after = {key: sha256_file(path) for key, path in SOURCE_FILES.items()}
    check = write_common_sidecars(
        fixture_dir,
        terms=source_summary["_terms"],
        glossary_terms=source_summary["_glossary_terms"],
        selection=selection,
        segments_doc=segments_doc,
        rttm_sha256=rttm_sha,
        wav_meta=wav_meta,
        checked=checked,
        source_hashes_before=source_hashes_before,
        source_hashes_after=source_hashes_after,
    )
    return {
        "path": logical_path(fixture_dir),
        "duration_s": wav_meta["duration_s"],
        "speaker_count": check["speaker_count"],
        "segment_count": check["reference_segment_count"],
        "wav_sha256": wav_meta["sha256"],
        "source_hashes_unchanged": source_hashes_before == source_hashes_after,
        "passed": True,
    }


def find_vox_row(table: Any, stem: str) -> tuple[int, str]:
    matches: list[tuple[int, str]] = []
    for index in range(table.num_rows):
        audio_path = table.column("audio")[index]["path"].as_py()
        path_stem = Path(audio_path).stem
        if path_stem == stem:
            matches.append((index, "audio.path_stem"))
    if len(matches) != 1:
        raise BuildError(f"VoxConverse stem {stem!r} not uniquely resolved: {matches}")
    return matches[0]


def rttm_agrees_with_arrays(
    rttm_path: Path,
    starts: list[float],
    ends: list[float],
    speakers: list[str],
    recording_id: str,
) -> None:
    turns = parse_rttm(rttm_path.read_text(encoding="utf-8"))
    if len(turns) != len(starts):
        raise BuildError(f"{recording_id}: RTTM/Parquet count mismatch")
    # Compare as multisets on rounded ms
    def key(start: float, end: float, speaker: str) -> tuple[int, int, str]:
        return (int(round(start * 1000)), int(round(end * 1000)), speaker)

    from_parquet = sorted(
        key(s, e, sp) for s, e, sp in zip(starts, ends, speakers, strict=True)
    )
    from_rttm = sorted(
        key(t["start_s"], t["end_s"], t["speaker"]) for t in turns
    )
    if from_parquet != from_rttm:
        raise BuildError(f"{recording_id}: RTTM disagrees with Parquet beyond 1 ms")
    for turn in turns:
        if turn["file_id"] != recording_id:
            raise BuildError(f"{recording_id}: RTTM file_id mismatch")


def build_vox_rcxzg(source_hashes_before: dict[str, str]) -> dict[str, Any]:
    fixture_dir = OUTPUT_ROOT / "benchmarks/runs/diarization/fixtures/voxconverse-rcxzg"
    require_absent(fixture_dir)
    fixture_dir.mkdir(parents=True, exist_ok=False)

    table = pq.read_table(SOURCE_FILES["vox_parquet"])
    row, resolve_field = find_vox_row(table, "rcxzg")
    audio_bytes = table.column("audio")[row]["bytes"].as_py()
    audio_path = table.column("audio")[row]["path"].as_py()
    starts = table.column("timestamps_start")[row].as_py()
    ends = table.column("timestamps_end")[row].as_py()
    speakers = table.column("speakers")[row].as_py()
    rttm_src = SOURCE_FILES["vox_rttm_rcxzg"]
    rttm_agrees_with_arrays(rttm_src, starts, ends, speakers, "rcxzg")

    pcm, sr, steps = decode_audio_bytes(audio_bytes)
    if sr != TARGET_HZ:
        raise BuildError("rcxzg not 16 kHz after decode")
    wav_meta = write_wav(fixture_dir / "input.wav", pcm)
    rttm_bytes = rttm_src.read_bytes()
    (fixture_dir / "reference.rttm").write_bytes(rttm_bytes)
    if (fixture_dir / "reference.rttm").read_bytes() != rttm_bytes:
        raise BuildError("rcxzg RTTM copy corrupted")

    segments = []
    for start, end, speaker in zip(starts, ends, speakers, strict=True):
        segments.append(
            {
                "speaker": speaker,
                "start_s": t6(start),
                "end_s": t6(end),
                "text": "[speech]",
                "flags": ["nonlexical"],
            }
        )
    segments = sorted(segments, key=lambda s: (s["start_s"], s["end_s"], s["speaker"]))
    segments_doc = build_segments_doc(segments, wav_meta)
    checked = validate_segments_document(segments_doc, wav_meta["duration_s"])
    checked.extend(
        validate_rttm_against_segments(
            parse_rttm((fixture_dir / "reference.rttm").read_text(encoding="utf-8")),
            segments,
            wav_meta["duration_s"],
        )
    )
    checked.append("rttm_byte_copy_from_canonical")
    checked.append("rttm_parquet_agree_1ms")

    terms: list[dict[str, Any]] = []
    selection = {
        "fixture_id": "voxconverse-rcxzg",
        "purpose": "VoxConverse multi-speaker diarization clip rcxzg",
        "public_source": {
            **DATASET_META["voxconverse"],
            "source_relative_path": (
                "benchmarks/samples/public/voxconverse/data/dev-00000-of-00005.parquet"
            ),
            "source_sha256": source_hashes_before["vox_parquet"],
            "rttm_relative_path": "benchmarks/samples/public/voxconverse/rttm/rcxzg.rttm",
            "rttm_sha256": source_hashes_before["vox_rttm_rcxzg"],
        },
        "resolve_field": resolve_field,
        "selected_row_ids": ["rcxzg"],
        "selected_audio_path": audio_path,
        "reference_text": "[speech]",
        "source_audio_sha256": sha256_bytes(audio_bytes),
        "source_duration_s": wav_meta["duration_s"],
        "output_start_s": 0.0,
        "output_end_s": wav_meta["duration_s"],
        "separator_duration_s": 0.0,
        "transformation_steps": steps + ["byte_copy_canonical_rttm"],
        "parquet_arrays": {
            "timestamps_start": [t6(v) for v in starts],
            "timestamps_end": [t6(v) for v in ends],
            "speakers": list(speakers),
        },
    }
    source_hashes_after = {key: sha256_file(path) for key, path in SOURCE_FILES.items()}
    check = write_common_sidecars(
        fixture_dir,
        terms=terms,
        glossary_terms=[],
        selection=selection,
        segments_doc=segments_doc,
        rttm_sha256=sha256_file(fixture_dir / "reference.rttm"),
        wav_meta=wav_meta,
        checked=checked,
        source_hashes_before=source_hashes_before,
        source_hashes_after=source_hashes_after,
    )
    return {
        "path": logical_path(fixture_dir),
        "duration_s": wav_meta["duration_s"],
        "speaker_count": check["speaker_count"],
        "segment_count": check["reference_segment_count"],
        "wav_sha256": wav_meta["sha256"],
        "source_hashes_unchanged": source_hashes_before == source_hashes_after,
        "passed": True,
    }


def build_vox_ppgjx(source_hashes_before: dict[str, str]) -> dict[str, Any]:
    fixture_dir = OUTPUT_ROOT / "benchmarks/runs/diarization/fixtures/voxconverse-ppgjx-78m"
    require_absent(fixture_dir)
    fixture_dir.mkdir(parents=True, exist_ok=False)
    items_dir = fixture_dir / "items"
    items_dir.mkdir()

    table = pq.read_table(SOURCE_FILES["vox_parquet"])
    row, resolve_field = find_vox_row(table, "ppgjx")
    audio_bytes = table.column("audio")[row]["bytes"].as_py()
    audio_path = table.column("audio")[row]["path"].as_py()
    starts = table.column("timestamps_start")[row].as_py()
    ends = table.column("timestamps_end")[row].as_py()
    speakers = table.column("speakers")[row].as_py()
    rttm_src = SOURCE_FILES["vox_rttm_ppgjx"]
    rttm_agrees_with_arrays(rttm_src, starts, ends, speakers, "ppgjx")

    pcm, sr, steps = decode_audio_bytes(audio_bytes)
    if sr != TARGET_HZ:
        raise BuildError("ppgjx not 16 kHz")
    item_meta = write_wav(items_dir / "000.wav", pcm)
    source_clip_duration = item_meta["duration_s"]
    repetition_count = 9
    separator_s = 0.500
    pieces = [pcm for _ in range(repetition_count)]
    concat, extents, concat_steps = concatenate_with_silence(pieces, separator_s)
    wav_meta = write_wav(fixture_dir / "input.wav", concat)
    if not (4500.0 <= wav_meta["duration_s"] <= 5100.0):
        raise BuildError(
            f"ppgjx-78m duration {wav_meta['duration_s']} outside 4500..5100"
        )

    repeat_offsets = [extent["start_s"] for extent in extents]
    base_turns = parse_rttm(rttm_src.read_text(encoding="utf-8"))
    global_speakers = sorted({turn["speaker"] for turn in base_turns})
    if global_speakers != ["spk00", "spk01"]:
        raise BuildError(f"expected speakers spk00/spk01, got {global_speakers}")

    segments: list[dict[str, Any]] = []
    rttm_turns: list[dict[str, Any]] = []
    for offset in repeat_offsets:
        for turn in base_turns:
            start = t6(offset + turn["start_s"])
            end = t6(offset + turn["end_s"])
            segments.append(
                {
                    "speaker": turn["speaker"],
                    "start_s": start,
                    "end_s": end,
                    "text": "[speech]",
                    "flags": ["nonlexical"],
                }
            )
            rttm_turns.append(
                {"start_s": start, "end_s": end, "speaker": turn["speaker"]}
            )
        for start, end, speaker in zip(starts, ends, speakers, strict=True):
            # already covered via RTTM; keep arrays for selection only
            _ = (start, end, speaker)

    segments = sorted(segments, key=lambda s: (s["start_s"], s["end_s"], s["speaker"]))
    rttm_turns = sorted(
        rttm_turns, key=lambda t: (t["start_s"], t["end_s"], t["speaker"])
    )
    segments_doc = build_segments_doc(segments, wav_meta)
    checked = validate_segments_document(segments_doc, wav_meta["duration_s"])
    rttm_sha = write_rttm(fixture_dir / "reference.rttm", "ppgjx", rttm_turns)
    checked.extend(
        validate_rttm_against_segments(
            parse_rttm((fixture_dir / "reference.rttm").read_text(encoding="utf-8")),
            segments,
            wav_meta["duration_s"],
        )
    )
    checked.append("duration_in_4500_5100")
    checked.append("global_two_speaker_identity")
    checked.append("repetition_count=9")
    expected_seg_count = len(base_turns) * repetition_count
    if len(segments) != expected_seg_count:
        raise BuildError("ppgjx segment count mismatch")

    selection = {
        "fixture_id": "voxconverse-ppgjx-78m",
        "purpose": (
            "Long synthetic reel repeating VoxConverse ppgjx nine times for "
            "full-file memory/duration/global-speaker checks; not a natural-corpus aggregate"
        ),
        "public_source": {
            **DATASET_META["voxconverse"],
            "source_relative_path": (
                "benchmarks/samples/public/voxconverse/data/dev-00000-of-00005.parquet"
            ),
            "source_sha256": source_hashes_before["vox_parquet"],
            "rttm_relative_path": "benchmarks/samples/public/voxconverse/rttm/ppgjx.rttm",
            "rttm_sha256": source_hashes_before["vox_rttm_ppgjx"],
        },
        "resolve_field": resolve_field,
        "selected_row_ids": ["ppgjx"],
        "selected_audio_path": audio_path,
        "reference_text": "[speech]",
        "source_audio_sha256": sha256_bytes(audio_bytes),
        "source_duration_s": source_clip_duration,
        "output_start_s": 0.0,
        "output_end_s": wav_meta["duration_s"],
        "separator_duration_s": separator_s,
        "repetition_count": repetition_count,
        "repeat_offsets_s": repeat_offsets,
        "expected_global_speaker_count": 2,
        "reference_segment_count": expected_seg_count,
        "transformation_steps": steps
        + concat_steps
        + ["shift_rttm_and_segments_by_repeat_offset"],
        "items": [
            {
                "order": 0,
                "item_wav": "items/000.wav",
                "item_wav_sha256": item_meta["sha256"],
                "source_audio_sha256": sha256_bytes(audio_bytes),
                "source_duration_s": source_clip_duration,
                "note": "single normalized source clip; nine reel uses share this item",
            }
        ],
    }
    source_hashes_after = {key: sha256_file(path) for key, path in SOURCE_FILES.items()}
    check = write_common_sidecars(
        fixture_dir,
        terms=[],
        glossary_terms=[],
        selection=selection,
        segments_doc=segments_doc,
        rttm_sha256=rttm_sha,
        wav_meta=wav_meta,
        checked=checked,
        source_hashes_before=source_hashes_before,
        source_hashes_after=source_hashes_after,
        extra_check={
            "repetition_count": repetition_count,
            "source_clip_duration_s": source_clip_duration,
            "separator_duration_s": separator_s,
            "repeat_offsets_s": repeat_offsets,
            "expected_global_speaker_count": 2,
        },
    )
    return {
        "path": logical_path(fixture_dir),
        "duration_s": wav_meta["duration_s"],
        "speaker_count": check["speaker_count"],
        "segment_count": check["reference_segment_count"],
        "wav_sha256": wav_meta["sha256"],
        "source_hashes_unchanged": source_hashes_before == source_hashes_after,
        "passed": True,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--source-root",
        type=Path,
        default=CODE_ROOT,
        help="repository-shaped root containing benchmarks/samples/public",
    )
    parser.add_argument(
        "--output-root",
        type=Path,
        default=DEFAULT_OUTPUT_ROOT,
        help=(
            "create-only mirror root; generated fixtures appear below its "
            "historical benchmarks/runs paths"
        ),
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    configure_roots(args.source_root, args.output_root)
    validate_fixture_parent_paths()
    for path in FIXTURE_DIRS:
        if path.is_symlink() or path.exists():
            raise BuildError(
                f"target fixture directory already exists: {logical_path(path)}"
            )
    for key, path in SOURCE_FILES.items():
        if not path.is_file():
            raise BuildError(f"missing source {key}: {logical_path(path)}")
    ensure_voices_available()

    source_hashes_before = {key: sha256_file(path) for key, path in SOURCE_FILES.items()}
    if source_hashes_before != EXPECTED_SOURCE_SHA256:
        raise BuildError(
            "pinned public source hash mismatch; refusing to create fixtures"
        )

    summaries: list[dict[str, Any]] = []
    hike = build_hike_tech(source_hashes_before)
    summaries.append({k: v for k, v in hike.items() if not k.startswith("_")})

    summaries.append(
        build_fleurs_clean(
            fixture_id="fleurs-ko-clean",
            fixture_dir=OUTPUT_ROOT / "benchmarks/runs/ko-asr/fixtures/fleurs-ko-clean",
            parquet_key="fleurs_ko_parquet",
            language="ko",
            relative_parquet=(
                "benchmarks/samples/public/fleurs/parquet-data/ko_kr/"
                "test-00000-of-00001.parquet"
            ),
            terms_list=KO_TERMS,
            purpose="Korean FLEURS clean reel for glossary overfire detection",
            source_hashes_before=source_hashes_before,
            require_zero_terms=True,
        )
    )
    summaries.append(
        build_fleurs_clean(
            fixture_id="fleurs-it-clean",
            fixture_dir=OUTPUT_ROOT / "benchmarks/runs/it-asr/fixtures/fleurs-it-clean",
            parquet_key="fleurs_it_parquet",
            language="it",
            relative_parquet=(
                "benchmarks/samples/public/fleurs/parquet-data/it_it/"
                "test-00000-of-00001.parquet"
            ),
            terms_list=IT_TERMS,
            purpose="Italian FLEURS clean reel for glossary overfire detection",
            source_hashes_before=source_hashes_before,
            require_zero_terms=True,
        )
    )

    italian = build_italian_dialogue(source_hashes_before)
    summaries.append({k: v for k, v in italian.items() if not k.startswith("_")})

    summaries.append(
        copy_cross_task(
            fixture_id="ko-code-switch",
            fixture_dir=OUTPUT_ROOT / "benchmarks/runs/diarization/fixtures/ko-code-switch",
            source_summary=hike,
            source_fixture_rel="benchmarks/runs/ko-asr/fixtures/hike-tech",
            purpose="Diarization view of hike-tech code-switch reel",
            source_hashes_before=source_hashes_before,
        )
    )
    summaries.append(
        copy_cross_task(
            fixture_id="it-dialogue",
            fixture_dir=OUTPUT_ROOT / "benchmarks/runs/diarization/fixtures/it-dialogue",
            source_summary=italian,
            source_fixture_rel="benchmarks/runs/it-asr/fixtures/italian-dialogue",
            purpose="Diarization view of italian-dialogue",
            source_hashes_before=source_hashes_before,
        )
    )
    summaries.append(build_vox_rcxzg(source_hashes_before))
    summaries.append(build_vox_ppgjx(source_hashes_before))

    source_hashes_after = {key: sha256_file(path) for key, path in SOURCE_FILES.items()}
    if source_hashes_before != source_hashes_after:
        raise BuildError(
            "source hashes changed after fixture build: "
            f"before={source_hashes_before} after={source_hashes_after}"
        )
    for summary in summaries:
        if not summary.get("source_hashes_unchanged", False):
            raise BuildError(f"source hash drift recorded in {summary['path']}")
        if not summary.get("passed", False):
            raise BuildError(f"fixture failed: {summary['path']}")

    report = {
        "fixtures": summaries,
        "source_hashes_unchanged": True,
        "passed": True,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BuildError as exc:
        print(json.dumps({"passed": False, "error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        raise SystemExit(1) from exc
