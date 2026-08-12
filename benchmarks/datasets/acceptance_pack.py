"""Shared construction and validation logic for public acceptance-pack fixtures.

The tracked pack declaration contains only source identities, selection rules, and
hashes. Downloaded sources and every transcript-bearing prepared artifact live in a
gitignored directory selected by the caller.
"""

from __future__ import annotations

import hashlib
import json
import re
import shutil
import sys
import unicodedata
import uuid
import wave
import xml.etree.ElementTree as ET
import zipfile
from collections import Counter, defaultdict
from collections.abc import Iterable
from dataclasses import dataclass
from io import BytesIO
from pathlib import Path
from typing import Any

REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
SCORING_DIR = REPOSITORY_ROOT / "benchmarks" / "scripts" / "scoring"
if str(SCORING_DIR) not in sys.path:
    sys.path.insert(0, str(SCORING_DIR))

from check_run import sha256_file, validate_segments_document
from metrics import count_term_occurrences

HIKE_LEVELS = ("word", "phrase", "sentence")
HIKE_SELECTION_SALT = "maccheroni-acceptance-hike-v1"
AMI_AGENTS = ("A", "B", "C", "D")
AMI_STOPWORDS = frozenset(
    {
        "a",
        "about",
        "after",
        "all",
        "also",
        "and",
        "are",
        "as",
        "at",
        "be",
        "because",
        "but",
        "by",
        "can",
        "do",
        "for",
        "from",
        "have",
        "i",
        "if",
        "in",
        "is",
        "it",
        "just",
        "like",
        "of",
        "on",
        "or",
        "so",
        "that",
        "the",
        "there",
        "this",
        "to",
        "uh",
        "um",
        "we",
        "with",
        "you",
        "yeah",
        "yes",
    }
)


class PackError(RuntimeError):
    """A public source or derived fixture violated the acceptance-pack contract."""


@dataclass(frozen=True)
class WaveInfo:
    frames: int
    sample_rate_hz: int
    channels: int
    sample_width_bytes: int

    @property
    def duration_s(self) -> float:
        return self.frames / self.sample_rate_hz


def rounded_seconds(value: float) -> float:
    return float(f"{value:.6f}")


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PackError(f"invalid JSON: {path}") from error
    if not isinstance(value, dict):
        raise PackError(f"JSON must contain an object: {path}")
    return value


def write_json_new(path: Path, value: object) -> None:
    if path.exists() or path.is_symlink():
        raise PackError(f"refusing to overwrite output: {path}")
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, sort_keys=True)
        stream.write("\n")


def write_text_new(path: Path, value: str) -> None:
    if path.exists() or path.is_symlink():
        raise PackError(f"refusing to overwrite output: {path}")
    path.write_text(value, encoding="utf-8", newline="\n")


def load_pack(path: Path) -> dict[str, Any]:
    pack = read_json(path)
    if pack.get("schema_version") != "1.0.0":
        raise PackError(f"unsupported pack schema: {pack.get('schema_version')!r}")
    fixtures = pack.get("fixtures")
    if not isinstance(fixtures, list) or not fixtures:
        raise PackError("pack fixtures must be a nonempty array")
    ids = [fixture.get("fixture_id") for fixture in fixtures if isinstance(fixture, dict)]
    if (
        len(ids) != len(fixtures)
        or any(not isinstance(fixture_id, str) or not fixture_id for fixture_id in ids)
        or len(set(ids)) != len(ids)
    ):
        raise PackError("pack fixture IDs must be unique nonempty strings")
    for fixture in fixtures:
        if not isinstance(fixture, dict):
            raise PackError("pack fixture must be an object")
        source = fixture.get("source")
        if not isinstance(source, dict) or not isinstance(source.get("files"), list) or not source["files"]:
            raise PackError(f"pack fixture {fixture['fixture_id']!r} has no source file list")
        for record in source["files"]:
            if not isinstance(record, dict):
                raise PackError(f"pack fixture {fixture['fixture_id']!r} has an invalid source file record")
            if not isinstance(record.get("relative_path"), str) or not isinstance(record.get("size_bytes"), int):
                raise PackError(f"pack fixture {fixture['fixture_id']!r} source file lacks path or size")
            digest = record.get("sha256")
            if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
                raise PackError(f"pack fixture {fixture['fixture_id']!r} source file has an invalid SHA-256")
        if fixture["fixture_id"] == "hike-code-switch-v1":
            selection = fixture.get("selection")
            if not isinstance(selection, dict):
                raise PackError("HiKE pack fixture has no selection object")
            subset = selection.get("pinned_subset")
            if not isinstance(subset, list) or len(subset) != 12:
                raise PackError("HiKE pinned subset must contain exactly 12 records")
            required = {"sample_id", "cs_level", "category", "row_index", "source_audio_sha256", "source_duration_s"}
            if any(not isinstance(item, dict) or set(item) != required for item in subset):
                raise PackError("HiKE pinned subset record schema mismatch")
            if any(
                not isinstance(item["sample_id"], str)
                or not isinstance(item["cs_level"], str)
                or not isinstance(item["category"], str)
                or not isinstance(item["row_index"], int)
                or not isinstance(item["source_duration_s"], (int, float))
                or not isinstance(item["source_audio_sha256"], str)
                or re.fullmatch(r"[0-9a-f]{64}", item["source_audio_sha256"]) is None
                for item in subset
            ):
                raise PackError("HiKE pinned subset has invalid field types")
    return pack


def fixture_named(pack: dict[str, Any], fixture_id: str) -> dict[str, Any]:
    fixtures = pack["fixtures"]
    matches = [fixture for fixture in fixtures if fixture["fixture_id"] == fixture_id]
    if len(matches) != 1:
        raise PackError(f"unknown fixture ID: {fixture_id}")
    return matches[0]


def fixture_directory(root: Path, fixture_id: str) -> Path:
    return root / "prepared" / fixture_id


def source_file_paths(root: Path, fixture: dict[str, Any]) -> dict[str, Path]:
    result: dict[str, Path] = {}
    for record in fixture["source"]["files"]:
        relative = record["relative_path"]
        candidate = Path(relative)
        if candidate.is_absolute() or ".." in candidate.parts:
            raise PackError(f"unsafe source path in pack: {relative!r}")
        path = root / candidate
        result[relative] = path
    return result


def verify_source_files(root: Path, fixture: dict[str, Any]) -> dict[str, Path]:
    paths = source_file_paths(root, fixture)
    by_relative = {record["relative_path"]: record for record in fixture["source"]["files"]}
    for relative, path in paths.items():
        expected = by_relative[relative]
        if not path.is_file():
            raise PackError(f"source missing: {path}")
        actual_size = path.stat().st_size
        if actual_size != expected["size_bytes"]:
            raise PackError(
                f"source size mismatch: {relative}: expected {expected['size_bytes']}, got {actual_size}"
            )
        actual_hash = sha256_file(path)
        if actual_hash != expected["sha256"]:
            raise PackError(
                f"source hash mismatch: {relative}: expected {expected['sha256']}, got {actual_hash}"
            )
    archive_members = fixture["source"].get("archive_members", {})
    if archive_members:
        archive = next(path for path in paths.values() if path.suffix == ".zip")
        verify_archive_members(archive, archive_members)
    return paths


def archive_member_bytes(archive: Path, member: str) -> bytes:
    try:
        with zipfile.ZipFile(archive) as source:
            candidates = (member, f"ami_public_manual_1.6.2/{member}")
            for candidate in candidates:
                try:
                    return source.read(candidate)
                except KeyError:
                    continue
    except (OSError, zipfile.BadZipFile) as error:
        raise PackError(f"invalid AMI annotations archive: {archive}") from error
    raise PackError(f"AMI annotations archive is missing member: {member}")


def verify_archive_members(archive: Path, expected: dict[str, str]) -> None:
    for member, digest in expected.items():
        actual = sha256_bytes(archive_member_bytes(archive, member))
        if actual != digest:
            raise PackError(
                f"AMI annotation member hash mismatch: {member}: expected {digest}, got {actual}"
            )


def wave_info_bytes(value: bytes) -> WaveInfo:
    try:
        with wave.open(BytesIO(value), "rb") as source:
            info = WaveInfo(
                frames=source.getnframes(),
                sample_rate_hz=source.getframerate(),
                channels=source.getnchannels(),
                sample_width_bytes=source.getsampwidth(),
            )
            if source.getcomptype() != "NONE":
                raise PackError("HiKE audio must be uncompressed PCM WAV")
    except (EOFError, OSError, wave.Error) as error:
        raise PackError("HiKE source audio is not a valid WAV") from error
    if min(info.frames, info.sample_rate_hz, info.channels, info.sample_width_bytes) <= 0:
        raise PackError("HiKE source audio has an invalid WAV format")
    return info


def wave_info_file(path: Path) -> WaveInfo:
    try:
        with wave.open(str(path), "rb") as source:
            info = WaveInfo(
                frames=source.getnframes(),
                sample_rate_hz=source.getframerate(),
                channels=source.getnchannels(),
                sample_width_bytes=source.getsampwidth(),
            )
            if source.getcomptype() != "NONE":
                raise PackError(f"expected PCM WAV: {path}")
    except (EOFError, OSError, wave.Error) as error:
        raise PackError(f"invalid WAV: {path}") from error
    if min(info.frames, info.sample_rate_hz, info.channels, info.sample_width_bytes) <= 0:
        raise PackError(f"invalid WAV format: {path}")
    return info


def normal_key(value: str) -> str:
    return unicodedata.normalize("NFKC", value).casefold().strip()


def rank_key(kind: str, value: str) -> str:
    raw = f"{HIKE_SELECTION_SALT}\0{kind}\0{value}".encode()
    return sha256_bytes(raw)


def parse_hike_loanwords(raw: object) -> list[dict[str, str]]:
    if not isinstance(raw, str):
        raise PackError("HiKE loanwords must be a JSON string")
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        raise PackError("HiKE loanwords contains invalid JSON") from error
    if not isinstance(value, list):
        raise PackError("HiKE loanwords must decode to an array")
    pairs: list[dict[str, str]] = []
    for entry in value:
        if not isinstance(entry, dict):
            continue
        english = entry.get("English")
        korean = entry.get("Korean")
        if isinstance(english, str) and english.strip():
            pairs.append({"English": english.strip(), "Korean": str(korean or "").strip()})
    return pairs


def has_hangul_and_latin(text: str) -> bool:
    return any("HANGUL" in unicodedata.name(character, "") for character in text) and any(
        "LATIN" in unicodedata.name(character, "") for character in text
    )


def require_pyarrow() -> Any:
    try:
        import pyarrow.parquet as pq
    except ModuleNotFoundError as error:
        raise PackError(
            "pyarrow is required; run with `uv run --with pyarrow --with jsonschema python ...`"
        ) from error
    return pq


def hike_rows(source_path: Path, fixture: dict[str, Any]) -> list[dict[str, Any]]:
    pq = require_pyarrow()
    table = pq.read_table(
        source_path,
        columns=["audio", "text_normalized", "loanwords", "cs_level", "category", "sample_id"],
    )
    if table.num_rows != 1121:
        raise PackError(f"HiKE source row count mismatch: expected 1121, got {table.num_rows}")
    selection = fixture["selection"]
    minimum = float(selection["minimum_duration_s"])
    maximum = float(selection["maximum_duration_s"])
    by_id: set[str] = set()
    eligible: list[dict[str, Any]] = []
    columns = {name: table.column(name).to_pylist() for name in table.column_names}
    for index in range(table.num_rows):
        sample_id = columns["sample_id"][index]
        text = columns["text_normalized"][index]
        level = columns["cs_level"][index]
        category = columns["category"][index]
        if not all(isinstance(value, str) and value.strip() for value in (sample_id, text, category)):
            continue
        if sample_id in by_id:
            raise PackError(f"HiKE source has duplicate sample_id: {sample_id}")
        by_id.add(sample_id)
        if level not in HIKE_LEVELS or not has_hangul_and_latin(text):
            continue
        pairs = parse_hike_loanwords(columns["loanwords"][index])
        if not pairs or not any(count_term_occurrences(pair["English"], text) for pair in pairs):
            continue
        audio = columns["audio"][index]
        if not isinstance(audio, dict) or not isinstance(audio.get("bytes"), bytes):
            continue
        info = wave_info_bytes(audio["bytes"])
        if not minimum <= info.duration_s <= maximum:
            continue
        if (info.sample_rate_hz, info.channels, info.sample_width_bytes) != (16000, 1, 2):
            raise PackError(
                "HiKE eligible audio must be 16 kHz, mono, PCM_16; "
                f"sample {sample_id} is {info.sample_rate_hz} Hz/{info.channels} ch/{info.sample_width_bytes * 8}-bit"
            )
        eligible.append(
            {
                "row_index": index,
                "sample_id": sample_id,
                "cs_level": level,
                "category": category,
                "text_normalized": text,
                "loanwords": pairs,
                "audio_bytes": audio["bytes"],
                "source_audio_sha256": sha256_bytes(audio["bytes"]),
                "source_audio_path": audio.get("path"),
                "source_duration_s": rounded_seconds(info.duration_s),
            }
        )
    return eligible


def select_hike_rows(eligible: Iterable[dict[str, Any]], fixture: dict[str, Any]) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    selection = fixture["selection"]
    quota = int(selection["quota_per_cs_level"])
    by_level_category: dict[str, dict[str, list[dict[str, Any]]]] = defaultdict(lambda: defaultdict(list))
    for row in eligible:
        by_level_category[row["cs_level"]][row["category"]].append(row)
    selected: list[dict[str, Any]] = []
    record: dict[str, Any] = {
        "algorithm_id": selection["algorithm_id"],
        "algorithm_version": selection["algorithm_version"],
        "quota_per_cs_level": quota,
        "eligible_counts": {},
        "category_selection": {},
        "fallbacks": {},
    }
    for level in selection["cs_level_order"]:
        categories = by_level_category[level]
        ranked_categories = sorted(categories, key=lambda category: rank_key("category", category))
        selected_for_level: list[dict[str, Any]] = []
        selected_ids: set[str] = set()
        category_records: list[dict[str, Any]] = []
        for category in ranked_categories[:quota]:
            candidate = min(categories[category], key=lambda row: rank_key("sample", row["sample_id"]))
            selected_for_level.append(dict(candidate, selection_kind="category"))
            selected_ids.add(candidate["sample_id"])
            category_records.append(
                {
                    "category": category,
                    "category_rank_sha256": rank_key("category", category),
                    "sample_id": candidate["sample_id"],
                    "sample_rank_sha256": rank_key("sample", candidate["sample_id"]),
                }
            )
        fallback_rows = sorted(
            (row for rows in categories.values() for row in rows if row["sample_id"] not in selected_ids),
            key=lambda row: rank_key("sample", row["sample_id"]),
        )
        needed = quota - len(selected_for_level)
        if needed > 0:
            if len(fallback_rows) < needed:
                raise PackError(
                    f"HiKE selection has fewer than {quota} eligible rows for cs_level={level!r}"
                )
            selected_for_level.extend(dict(row, selection_kind="fallback") for row in fallback_rows[:needed])
        if len(selected_for_level) != quota:
            raise PackError(f"HiKE selection quota failure for cs_level={level!r}")
        selected.extend(selected_for_level)
        record["eligible_counts"][level] = {
            "rows": sum(len(rows) for rows in categories.values()),
            "categories": len(categories),
        }
        record["category_selection"][level] = category_records
        record["fallbacks"][level] = [
            row["sample_id"] for row in selected_for_level if row["selection_kind"] == "fallback"
        ]
    if len({row["sample_id"] for row in selected}) != len(selected):
        raise PackError("HiKE selection produced duplicate sample IDs")
    pinned_subset = selection.get("pinned_subset")
    actual_subset = [
        {
            key: row[key]
            for key in (
                "sample_id",
                "cs_level",
                "category",
                "row_index",
                "source_audio_sha256",
                "source_duration_s",
            )
        }
        for row in selected
    ]
    if pinned_subset is not None and pinned_subset != actual_subset:
        raise PackError("HiKE deterministic selection differs from the pinned subset manifest")
    return selected, record


def derive_hike_glossary(rows: Iterable[dict[str, Any]], reference_text: str) -> tuple[list[dict[str, object]], dict[str, list[str]]]:
    original_by_key: dict[str, str] = {}
    sample_ids_by_key: dict[str, list[str]] = defaultdict(list)
    for row in rows:
        for pair in row["loanwords"]:
            term = pair["English"]
            key = normal_key(term)
            if count_term_occurrences(term, reference_text) <= 0:
                continue
            original_by_key.setdefault(key, term)
            sample_ids_by_key[key].append(row["sample_id"])
    terms = [
        {
            "term": original_by_key[key],
            "reference_count": count_term_occurrences(original_by_key[key], reference_text),
        }
        for key in sorted(original_by_key)
    ]
    if not terms or any(int(entry["reference_count"]) <= 0 for entry in terms):
        raise PackError("HiKE glossary derivation produced no spoken terms")
    sources = {key: sorted(set(value)) for key, value in sample_ids_by_key.items()}
    return terms, sources


def create_hike_fixture(root: Path, fixture: dict[str, Any], destination: Path) -> None:
    paths = verify_source_files(root, fixture)
    source_path = paths["sources/hike/data/test-00000-of-00001.parquet"]
    source_hashes_before = {relative: sha256_file(path) for relative, path in paths.items()}
    eligible = hike_rows(source_path, fixture)
    rows, selection_record = select_hike_rows(eligible, fixture)
    items_dir = destination / "items"
    items_dir.mkdir()
    audio_format: tuple[int, int, int] | None = None
    pcm_pieces: list[bytes] = []
    item_records: list[dict[str, Any]] = []
    for index, row in enumerate(rows):
        info = wave_info_bytes(row["audio_bytes"])
        current_format = (info.sample_rate_hz, info.channels, info.sample_width_bytes)
        if audio_format is None:
            audio_format = current_format
        if current_format != audio_format:
            raise PackError("HiKE selection contains incompatible WAV formats")
        relative = f"items/{index:02d}.wav"
        item_path = destination / relative
        item_path.write_bytes(row["audio_bytes"])
        with wave.open(BytesIO(row["audio_bytes"]), "rb") as source:
            pcm = source.readframes(source.getnframes())
        pcm_pieces.append(pcm)
        item_records.append(
            {
                "order": index,
                "row_index": row["row_index"],
                "sample_id": row["sample_id"],
                "cs_level": row["cs_level"],
                "category": row["category"],
                "selection_kind": row["selection_kind"],
                "text_normalized": row["text_normalized"],
                "loanwords": row["loanwords"],
                "source_audio_path": row["source_audio_path"],
                "source_audio_sha256": row["source_audio_sha256"],
                "source_duration_s": row["source_duration_s"],
                "item_wav": relative,
                "item_wav_sha256": sha256_file(item_path),
            }
        )
    if audio_format != (16000, 1, 2):
        raise PackError(f"unexpected HiKE fixture WAV format: {audio_format}")
    silence_frames = int(float(fixture["selection"]["silence_between_items_s"]) * audio_format[0])
    silence = b"\0" * silence_frames * audio_format[1] * audio_format[2]
    input_path = destination / "input.wav"
    segments: list[dict[str, object]] = []
    cursor_frames = 0
    with wave.open(str(input_path), "wb") as output:
        output.setnchannels(audio_format[1])
        output.setsampwidth(audio_format[2])
        output.setframerate(audio_format[0])
        for index, (row, pcm) in enumerate(zip(rows, pcm_pieces, strict=True)):
            source_info = wave_info_bytes(row["audio_bytes"])
            start_s = rounded_seconds(cursor_frames / audio_format[0])
            output.writeframes(pcm)
            cursor_frames += source_info.frames
            end_s = rounded_seconds(cursor_frames / audio_format[0])
            item_records[index]["reel_start_s"] = start_s
            item_records[index]["reel_end_s"] = end_s
            segments.append(
                {
                    "speaker": "UNASSIGNED",
                    "start_s": start_s,
                    "end_s": end_s,
                    "text": row["text_normalized"],
                    "language": "ko-en",
                }
            )
            if index + 1 < len(rows):
                output.writeframes(silence)
                cursor_frames += silence_frames
    input_info = wave_info_file(input_path)
    input_hash = sha256_file(input_path)
    reference_text = " ".join(str(segment["text"]) for segment in segments)
    terms, term_sources = derive_hike_glossary(rows, reference_text)
    reference = {
        "schema_version": "1.0.0",
        "segments": segments,
        "num_speakers": 0,
        "source": {
            "file_name": input_path.name,
            "sha256": input_hash,
            "duration_s": rounded_seconds(input_info.duration_s),
        },
    }
    validate_segments_document(reference, label="HiKE reference")
    write_json_new(destination / "reference.segments.json", reference)
    write_json_new(destination / "terms.json", terms)
    write_text_new(destination / "glossary.txt", "\n".join(str(entry["term"]) for entry in terms) + "\n")
    selection_document = {
        "fixture_id": fixture["fixture_id"],
        "source": {
            "dataset_id": fixture["source"]["dataset_id"],
            "revision": fixture["source"]["revision"],
            "source_sha256": source_hashes_before["sources/hike/data/test-00000-of-00001.parquet"],
        },
        "selection": selection_record,
        "items": item_records,
        "reference_text": reference_text,
        "term_source_sample_ids": term_sources,
    }
    write_json_new(destination / "selection.json", selection_document)
    source_hashes_after = {relative: sha256_file(path) for relative, path in paths.items()}
    if source_hashes_before != source_hashes_after:
        raise PackError("HiKE source changed while preparing the fixture")
    artifact_hashes = {
        "input.wav": input_hash,
        "reference.segments.json": sha256_file(destination / "reference.segments.json"),
        "terms.json": sha256_file(destination / "terms.json"),
        "glossary.txt": sha256_file(destination / "glossary.txt"),
        "selection.json": sha256_file(destination / "selection.json"),
        **{record["item_wav"]: record["item_wav_sha256"] for record in item_records},
    }
    write_json_new(
        destination / "fixture-check.json",
        {
            "fixture_id": fixture["fixture_id"],
            "passed": True,
            "source_hashes_before": source_hashes_before,
            "source_hashes_after": source_hashes_after,
            "artifact_sha256": artifact_hashes,
            "input_wav": {
                "sha256": input_hash,
                "size_bytes": input_path.stat().st_size,
                "duration_s": rounded_seconds(input_info.duration_s),
                "sample_rate_hz": input_info.sample_rate_hz,
                "channels": input_info.channels,
                "sample_width_bytes": input_info.sample_width_bytes,
            },
            "reference_segment_count": len(segments),
            "term_count": len(terms),
        },
    )


def xml_local_name(value: str) -> str:
    return value.rsplit("}", maxsplit=1)[-1]


def xml_attr(element: ET.Element, name: str) -> str | None:
    for key, value in element.attrib.items():
        if xml_local_name(key) == name:
            return value
    return None


def ami_speaker_mapping(meetings_xml: bytes) -> dict[str, str]:
    try:
        root = ET.fromstring(meetings_xml)
    except ET.ParseError as error:
        raise PackError("AMI meetings.xml is malformed") from error
    for meeting in root.iter():
        if xml_local_name(meeting.tag) != "meeting" or xml_attr(meeting, "observation") != "IN1009":
            continue
        mapping: dict[str, str] = {}
        for speaker in meeting:
            agent = xml_attr(speaker, "nxt_agent")
            global_name = xml_attr(speaker, "global_name")
            if agent in AMI_AGENTS and isinstance(global_name, str) and global_name:
                mapping[agent] = global_name
        if set(mapping) != set(AMI_AGENTS):
            raise PackError(f"AMI IN1009 speaker mapping is incomplete: {mapping}")
        return mapping
    raise PackError("AMI meetings.xml has no IN1009 meeting")


def ami_words(words_xml: bytes) -> dict[str, str]:
    try:
        root = ET.fromstring(words_xml)
    except ET.ParseError as error:
        raise PackError("AMI words XML is malformed") from error
    result: dict[str, str] = {}
    for element in root.iter():
        identifier = xml_attr(element, "id")
        if not identifier:
            continue
        # Keep every NITE node as a position. A parent segment can begin or end
        # on punctuation, a disfluency marker, or another non-lexical node.
        # Only ordinary non-punctuation <w> nodes contribute surface text.
        if xml_local_name(element.tag) == "w" and xml_attr(element, "punc") != "true":
            result[identifier] = (element.text or "").strip()
        else:
            result[identifier] = ""
    return result


def ami_segment_word_range(segment: ET.Element) -> tuple[str, str] | None:
    for child in segment:
        if xml_local_name(child.tag) != "child":
            continue
        href = xml_attr(child, "href") or ""
        match = re.search(r"#id\(([^)]+)\)(?:\.\.id\(([^)]+)\))?", href)
        if match:
            return match.group(1), match.group(2) or match.group(1)
    return None


def ami_segments(segment_xml: bytes, words: dict[str, str], speaker: str) -> list[dict[str, object]]:
    try:
        root = ET.fromstring(segment_xml)
    except ET.ParseError as error:
        raise PackError("AMI segment XML is malformed") from error
    ordered_ids = list(words)
    position = {identifier: index for index, identifier in enumerate(ordered_ids)}
    result: list[dict[str, object]] = []
    for element in root.iter():
        if xml_local_name(element.tag) != "segment":
            continue
        try:
            start_s = float(xml_attr(element, "transcriber_start") or "")
            end_s = float(xml_attr(element, "transcriber_end") or "")
        except ValueError as error:
            raise PackError("AMI segment contains nonnumeric time") from error
        if start_s < 0 or end_s <= start_s:
            continue
        range_ids = ami_segment_word_range(element)
        text = ""
        if range_ids is not None and range_ids[0] in position and range_ids[1] in position:
            first, last = sorted((position[range_ids[0]], position[range_ids[1]]))
            text = " ".join(
                word for word in (words[identifier] for identifier in ordered_ids[first : last + 1]) if word
            )
        result.append(
            {
                "speaker": speaker,
                "start_s": rounded_seconds(start_s),
                "end_s": rounded_seconds(end_s),
                "text": text,
            }
        )
    return result


def ami_reference_from_archive(archive: Path) -> tuple[list[dict[str, object]], list[dict[str, object]], dict[str, str]]:
    mapping = ami_speaker_mapping(archive_member_bytes(archive, "corpusResources/meetings.xml"))
    all_turns: list[dict[str, object]] = []
    for agent in AMI_AGENTS:
        words = ami_words(archive_member_bytes(archive, f"words/IN1009.{agent}.words.xml"))
        all_turns.extend(
            ami_segments(
                archive_member_bytes(archive, f"segments/IN1009.{agent}.segments.xml"),
                words,
                mapping[agent],
            )
        )
    all_turns.sort(key=lambda entry: (entry["start_s"], entry["end_s"], entry["speaker"]))
    asr_segments = [dict(turn, language="en") for turn in all_turns if str(turn["text"]).strip()]
    return asr_segments, all_turns, mapping


def derive_ami_glossary(reference_text: str) -> list[dict[str, object]]:
    tokens = [normal_key(token) for token in re.findall(r"[A-Za-z][A-Za-z'-]*", reference_text)]
    counts = Counter(tokens)
    terms = [
        {"term": term, "reference_count": count_term_occurrences(term, reference_text)}
        for term, count in sorted(counts.items())
        if 3 <= len(term) and 3 <= count <= 8 and term not in AMI_STOPWORDS
    ]
    if not terms or any(int(entry["reference_count"]) <= 0 for entry in terms):
        raise PackError("AMI glossary derivation produced no spoken terms")
    return terms


def create_ami_fixture(root: Path, fixture: dict[str, Any], destination: Path) -> None:
    paths = verify_source_files(root, fixture)
    audio_path = paths["sources/ami/IN1009.Mix-Headset.wav"]
    archive_path = paths["sources/ami/ami_public_manual_1.6.2.zip"]
    source_hashes_before = {relative: sha256_file(path) for relative, path in paths.items()}
    audio_info = wave_info_file(audio_path)
    if (audio_info.sample_rate_hz, audio_info.channels, audio_info.sample_width_bytes) != (16000, 1, 2):
        raise PackError("AMI IN1009 IHM-mix must be 16 kHz mono PCM_16 WAV")
    asr_segments, rttm_turns, mapping = ami_reference_from_archive(archive_path)
    derivation = fixture["reference_derivation"]
    lexical_words = sum(len(str(segment["text"]).split()) for segment in asr_segments)
    if len(asr_segments) != derivation["expected_lexical_segment_count"]:
        raise PackError(
            f"AMI lexical segment count mismatch: expected {derivation['expected_lexical_segment_count']}, got {len(asr_segments)}"
        )
    if lexical_words != derivation["expected_lexical_word_count"]:
        raise PackError(
            f"AMI lexical word count mismatch: expected {derivation['expected_lexical_word_count']}, got {lexical_words}"
        )
    if len(rttm_turns) != derivation["expected_rttm_turn_count"]:
        raise PackError(
            f"AMI RTTM turn count mismatch: expected {derivation['expected_rttm_turn_count']}, got {len(rttm_turns)}"
        )
    speakers = {str(turn["speaker"]) for turn in rttm_turns}
    if len(speakers) != derivation["expected_speaker_count"]:
        raise PackError(f"AMI speaker count mismatch: expected 4, got {len(speakers)}")
    duration_s = rounded_seconds(audio_info.duration_s)
    if any(float(turn["end_s"]) > duration_s + 0.01 for turn in rttm_turns):
        raise PackError("AMI manual reference extends past IHM-mix audio")
    reference = {
        "schema_version": "1.0.0",
        "segments": asr_segments,
        "num_speakers": len(speakers),
        "source": {
            "file_name": audio_path.name,
            "sha256": source_hashes_before["sources/ami/IN1009.Mix-Headset.wav"],
            "duration_s": duration_s,
        },
    }
    validate_segments_document(reference, label="AMI reference")
    reference_text = " ".join(str(segment["text"]) for segment in asr_segments)
    terms = derive_ami_glossary(reference_text)
    write_json_new(destination / "reference.segments.json", reference)
    write_json_new(destination / "terms.json", terms)
    write_text_new(destination / "glossary.txt", "\n".join(str(entry["term"]) for entry in terms) + "\n")
    rttm_lines = [
        "SPEAKER IN1009 1 "
        f"{float(turn['start_s']):.6f} {float(turn['end_s']) - float(turn['start_s']):.6f} "
        f"<NA> <NA> {turn['speaker']} <NA> <NA>"
        for turn in rttm_turns
    ]
    write_text_new(destination / "reference.rttm", "\n".join(rttm_lines) + "\n")
    selection_document = {
        "fixture_id": fixture["fixture_id"],
        "source": {
            "meeting_id": fixture["source"]["meeting_id"],
            "audio_sha256": source_hashes_before["sources/ami/IN1009.Mix-Headset.wav"],
            "annotations_sha256": source_hashes_before["sources/ami/ami_public_manual_1.6.2.zip"],
        },
        "speaker_mapping": mapping,
        "reference_derivation": derivation,
        "reference_text": reference_text,
        "lexical_word_count": lexical_words,
        "term_reference_occurrences": {entry["term"]: entry["reference_count"] for entry in terms},
    }
    write_json_new(destination / "selection.json", selection_document)
    source_hashes_after = {relative: sha256_file(path) for relative, path in paths.items()}
    if source_hashes_before != source_hashes_after:
        raise PackError("AMI source changed while preparing the fixture")
    artifact_hashes = {
        relative: sha256_file(destination / relative)
        for relative in ("reference.segments.json", "terms.json", "glossary.txt", "reference.rttm", "selection.json")
    }
    write_json_new(
        destination / "fixture-check.json",
        {
            "fixture_id": fixture["fixture_id"],
            "passed": True,
            "source_hashes_before": source_hashes_before,
            "source_hashes_after": source_hashes_after,
            "artifact_sha256": artifact_hashes,
            "input_wav": {
                "file_name": audio_path.name,
                "sha256": source_hashes_before["sources/ami/IN1009.Mix-Headset.wav"],
                "size_bytes": audio_path.stat().st_size,
                "duration_s": duration_s,
                "sample_rate_hz": audio_info.sample_rate_hz,
                "channels": audio_info.channels,
                "sample_width_bytes": audio_info.sample_width_bytes,
            },
            "reference_segment_count": len(asr_segments),
            "reference_rttm_count": len(rttm_turns),
            "speaker_count": len(speakers),
            "term_count": len(terms),
        },
    )


def verify_artifact_hashes(destination: Path, check: dict[str, Any]) -> None:
    hashes = check.get("artifact_sha256")
    if not isinstance(hashes, dict) or not hashes:
        raise PackError("fixture-check.json has no artifact hashes")
    if "fixture-check.json" in hashes:
        raise PackError("fixture-check.json must not hash itself")
    for relative, expected in hashes.items():
        if not isinstance(relative, str) or Path(relative).is_absolute() or ".." in Path(relative).parts:
            raise PackError(f"unsafe fixture artifact path: {relative!r}")
        path = destination / relative
        if not path.is_file():
            raise PackError(f"prepared artifact missing: {path}")
        actual = sha256_file(path)
        if actual != expected:
            raise PackError(f"prepared artifact hash mismatch: {relative}")


def verify_terms_and_glossary(destination: Path, reference: dict[str, Any]) -> list[dict[str, Any]]:
    try:
        terms = json.loads((destination / "terms.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise PackError("invalid terms.json") from error
    if not isinstance(terms, list) or not terms:
        raise PackError("terms.json must contain a nonempty array")
    reference_text = " ".join(str(segment["text"]) for segment in reference["segments"])
    for entry in terms:
        if not isinstance(entry, dict) or not isinstance(entry.get("term"), str):
            raise PackError("terms.json has an invalid term entry")
        actual = count_term_occurrences(entry["term"], reference_text)
        if entry.get("reference_count") != actual or actual <= 0:
            raise PackError(f"term reference count mismatch: {entry['term']!r}")
    glossary = (destination / "glossary.txt").read_text(encoding="utf-8").splitlines()
    if glossary != [entry["term"] for entry in terms]:
        raise PackError("glossary.txt is not derived from terms.json")
    return terms


def verify_common_prepared_fixture(destination: Path, fixture_id: str) -> tuple[dict[str, Any], dict[str, Any]]:
    """Check hash-sealed fixture artifacts before source-specific reconstruction."""

    check = read_json(destination / "fixture-check.json")
    if check.get("fixture_id") != fixture_id or check.get("passed") is not True:
        raise PackError("fixture-check.json identity or status mismatch")
    verify_artifact_hashes(destination, check)
    reference = read_json(destination / "reference.segments.json")
    validate_segments_document(reference, label=f"{fixture_id} reference")
    expected_count = check.get("reference_segment_count")
    if expected_count != len(reference["segments"]):
        raise PackError(
            f"reference segment count mismatch: expected {expected_count}, got {len(reference['segments'])}"
        )
    verify_terms_and_glossary(destination, reference)
    return check, reference


def verify_hike_fixture(root: Path, fixture: dict[str, Any], destination: Path, check: dict[str, Any], reference: dict[str, Any]) -> None:
    input_path = destination / "input.wav"
    info = wave_info_file(input_path)
    if reference["source"] != {
        "file_name": "input.wav",
        "sha256": sha256_file(input_path),
        "duration_s": rounded_seconds(info.duration_s),
    }:
        raise PackError("HiKE reference source metadata mismatch")
    selection = read_json(destination / "selection.json")
    eligible = hike_rows(root / "sources/hike/data/test-00000-of-00001.parquet", fixture)
    expected_rows, expected_selection = select_hike_rows(eligible, fixture)
    items = selection.get("items")
    if not isinstance(items, list) or len(items) != len(expected_rows):
        raise PackError("HiKE selected row count mismatch")
    if selection.get("selection") != expected_selection:
        raise PackError("HiKE selection manifest differs from the deterministic rule")
    actual_ids = [item.get("sample_id") if isinstance(item, dict) else None for item in items]
    expected_ids = [row["sample_id"] for row in expected_rows]
    if actual_ids != expected_ids:
        raise PackError("HiKE selected sample IDs differ from the deterministic rule")
    if len(reference["segments"]) != len(expected_rows):
        raise PackError("HiKE reference segment count mismatch")
    if check.get("reference_segment_count") != len(expected_rows):
        raise PackError("HiKE fixture-check reference segment count mismatch")


def parse_rttm_lines(path: Path) -> list[list[str]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    fields = [line.split() for line in lines]
    if not fields or any(len(line) != 10 or line[0] != "SPEAKER" for line in fields):
        raise PackError("invalid reference.rttm")
    return fields


def verify_ami_fixture(root: Path, fixture: dict[str, Any], destination: Path, check: dict[str, Any], reference: dict[str, Any]) -> None:
    paths = source_file_paths(root, fixture)
    audio_path = paths["sources/ami/IN1009.Mix-Headset.wav"]
    info = wave_info_file(audio_path)
    expected_source = {
        "file_name": audio_path.name,
        "sha256": sha256_file(audio_path),
        "duration_s": rounded_seconds(info.duration_s),
    }
    if reference["source"] != expected_source:
        raise PackError("AMI reference source metadata mismatch")
    archive = paths["sources/ami/ami_public_manual_1.6.2.zip"]
    expected_asr, expected_rttm, mapping = ami_reference_from_archive(archive)
    if reference["segments"] != expected_asr:
        raise PackError("AMI reference segments differ from the manual annotations")
    fields = parse_rttm_lines(destination / "reference.rttm")
    if len(fields) != len(expected_rttm):
        raise PackError("AMI reference RTTM turn count mismatch")
    if [line[7] for line in fields] != [turn["speaker"] for turn in expected_rttm]:
        raise PackError("AMI reference RTTM speakers differ from manual annotations")
    selection = read_json(destination / "selection.json")
    if selection.get("speaker_mapping") != mapping:
        raise PackError("AMI speaker mapping mismatch")
    if check.get("reference_segment_count") != len(expected_asr):
        raise PackError("AMI fixture-check reference segment count mismatch")
    if check.get("reference_rttm_count") != len(expected_rttm):
        raise PackError("AMI fixture-check RTTM count mismatch")


def verify_prepared_fixture(root: Path, fixture: dict[str, Any]) -> None:
    paths = verify_source_files(root, fixture)
    destination = fixture_directory(root, fixture["fixture_id"])
    if not destination.is_dir():
        raise PackError(f"prepared fixture missing: {destination}")
    source_hashes = {relative: sha256_file(path) for relative, path in paths.items()}
    check = read_json(destination / "fixture-check.json")
    if check.get("source_hashes_before") != source_hashes or check.get("source_hashes_after") != source_hashes:
        raise PackError("fixture source hash manifest mismatch")
    check, reference = verify_common_prepared_fixture(destination, fixture["fixture_id"])
    if fixture["fixture_id"] == "hike-code-switch-v1":
        verify_hike_fixture(root, fixture, destination, check, reference)
    elif fixture["fixture_id"] == "ami-in1009-ihm-mix-v1":
        verify_ami_fixture(root, fixture, destination, check, reference)
    else:
        raise PackError(f"no verifier for fixture: {fixture['fixture_id']}")


def create_fixture(root: Path, fixture: dict[str, Any]) -> str:
    destination = fixture_directory(root, fixture["fixture_id"])
    if destination.exists() or destination.is_symlink():
        verify_prepared_fixture(root, fixture)
        return "reverified"
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.parent / f".{fixture['fixture_id']}.tmp-{uuid.uuid4().hex}"
    try:
        temporary.mkdir()
        if fixture["fixture_id"] == "hike-code-switch-v1":
            create_hike_fixture(root, fixture, temporary)
        elif fixture["fixture_id"] == "ami-in1009-ihm-mix-v1":
            create_ami_fixture(root, fixture, temporary)
        else:
            raise PackError(f"no builder for fixture: {fixture['fixture_id']}")
        verify_prepared_fixture_at(root, fixture, temporary)
        temporary.rename(destination)
        return "created"
    except Exception:
        shutil.rmtree(temporary, ignore_errors=True)
        raise


def verify_prepared_fixture_at(root: Path, fixture: dict[str, Any], destination: Path) -> None:
    """Verify a new staging directory before its atomic promotion.

    The public verifier accepts only canonical locations. This staging pass checks
    the common seals and semantic material that does not depend on the final path.
    The promoted fixture is immediately reverified by the command wrapper.
    """

    verify_common_prepared_fixture(destination, fixture["fixture_id"])
