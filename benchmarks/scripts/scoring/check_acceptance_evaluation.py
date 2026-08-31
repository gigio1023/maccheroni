#!/usr/bin/env python3
"""Create and verify immutable acceptance-pack evaluation envelopes."""

from __future__ import annotations

import argparse
from collections.abc import Sequence
import ctypes
import errno
import fcntl
from hashlib import sha256
from io import BytesIO
import json
import math
import os
from pathlib import Path
import re
import secrets
import stat
import struct
import subprocess
import sys
import tempfile
from typing import Any
import unicodedata
import wave


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
SCORING_ROOT = REPOSITORY_ROOT / "benchmarks/scripts/scoring"
DATASETS_ROOT = REPOSITORY_ROOT / "benchmarks/datasets"
PACK_MANIFEST = REPOSITORY_ROOT / "benchmarks/datasets/acceptance-pack-v1.json"

from check_run import (
    REQUIRED_SUCCESS_ARTIFACTS,
    load_json as load_json_unchecked,
    validate_completed_run_manifest,
    validate_conflicts,
    validate_scores,
    validate_segments,
    validate_timeline,
)
from metrics import count_term_occurrences

if str(DATASETS_ROOT) not in sys.path:
    sys.path.insert(0, str(DATASETS_ROOT))
from acceptance_pack import (  # noqa: E402
    ami_reference_from_archive,
    PackError,
    derive_ami_glossary,
    derive_hike_glossary,
    fixture_named,
    hike_rows,
    load_pack,
    rounded_seconds,
    select_hike_rows,
    verify_prepared_fixture,
    wave_info_bytes,
    wave_info_file,
)

SCORER_FILES = (
    "benchmarks/scripts/scoring/score.py",
    "benchmarks/scripts/scoring/metrics.py",
    "benchmarks/scripts/scoring/rttm.py",
    "benchmarks/scripts/scoring/check_run.py",
    "benchmarks/scripts/scoring/check_contracts.py",
    "benchmarks/scripts/scoring/check_acceptance_evaluation.py",
    "benchmarks/scripts/runners/run_acceptance_pack_v1.sh",
    "benchmarks/scripts/scoring/pyproject.toml",
    "benchmarks/scripts/scoring/uv.lock",
    "benchmarks/env/dicow-reference/pyproject.toml",
    "benchmarks/env/dicow-reference/uv.lock",
    "benchmarks/datasets/acceptance_pack.py",
    "benchmarks/datasets/acceptance-pack-v1.json",
    "docs/contracts/manifest.schema.json",
    "docs/contracts/segments.schema.json",
)
FIXTURE_KINDS = {
    "hike-code-switch-v1": "acceptance-asr",
    "ami-in1009-ihm-mix-v1": "acceptance-full",
}
HEX64 = set("0123456789abcdef")
EVALUATION_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
ATTEMPT_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$")
MINIMUM_ACCEPTANCE_MEMORY_BYTES = 36 * 1024 * 1024 * 1024
# Root is depth 0. The shipped run tree is fewer than 8 directories deep;
# 24 leaves 3x observed headroom while staying far below Python's recursion
# limit and the macOS open-file soft limit during depth-first no-follow walks.
SOURCE_ENVELOPE_MAX_DIRECTORY_DEPTH: int = 24
EXPECTED_MODELS = [
    {
        "role": "asr",
        "hf_model_id": "mlx-community/VibeVoice-ASR-8bit",
        "revision": "725c72e54d6ef875472c27fbc50fab470a960940",
        "quantization": "int8",
    },
    {
        "role": "vad",
        "hf_model_id": "aufklarer/Silero-VAD-v6.2.1-CoreML",
        "revision": "523876545a57961474fee9df913e833e130560b8",
        "quantization": "coreml-float16",
    },
    {
        "role": "diarization",
        "hf_model_id": "aufklarer/Pyannote-Community-1-CoreML",
        "revision": "a14e6c420d56e8472850649b016a486fd0acbe81",
        "quantization": "coreml-fp32",
    },
]
EXPECTED_BACKEND = {"name": "mlx-audio-vibevoice", "version": "0.4.6"}


class EvaluationError(ValueError):
    """An acceptance evaluation violated its immutable evidence contract."""


def reject_nonfinite(value: object, *, label: str) -> None:
    if isinstance(value, float) and not math.isfinite(value):
        raise EvaluationError(f"{label} contains a non-finite number")
    if isinstance(value, dict):
        for item in value.values():
            reject_nonfinite(item, label=label)
    elif isinstance(value, list):
        for item in value:
            reject_nonfinite(item, label=label)


def load_json(path: Path) -> Any:
    value = load_json_unchecked(path)
    reject_nonfinite(value, label=path.name)
    return value


def sha256_file(path: Path) -> str:
    digest = sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical_sha256(value: object) -> str:
    encoded = json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return sha256(encoded).hexdigest()


def vibevoice_glossary_payload_sha256(glossary_path: Path) -> str:
    text = glossary_path.read_text(encoding="utf-8")
    if text.startswith("\ufeff"):
        text = text[1:]
    entries: list[str] = []
    seen: set[str] = set()
    for line in text.splitlines():
        entry = unicodedata.normalize("NFC", line.strip())
        if not entry or entry.startswith("#") or entry in seen:
            continue
        seen.add(entry)
        entries.append(entry)
    if not entries:
        raise EvaluationError("fixture glossary has no VibeVoice payload entries")
    context = (
        "Preserve these spellings only when supported by the audio. "
        "Candidate glossary terms:\n"
        + "\n".join(entries)
    )
    return sha256(context.encode("utf-8")).hexdigest()


def write_json_create(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as output:
        json.dump(value, output, ensure_ascii=False, indent=2, sort_keys=True)
        output.write("\n")


def safe_relative(value: object, *, label: str) -> str:
    if not isinstance(value, str):
        raise EvaluationError(f"{label} must be a relative path")
    path = Path(value)
    if not value or path.is_absolute() or ".." in path.parts or path.as_posix() != value:
        raise EvaluationError(f"unsafe {label}: {value!r}")
    return value


def require_hash(value: object, *, label: str) -> str:
    if not isinstance(value, str) or len(value) != 64 or any(character not in HEX64 for character in value):
        raise EvaluationError(f"{label} is not a lowercase SHA-256")
    return value


def file_record(path: Path) -> dict[str, object]:
    if path.is_symlink():
        raise EvaluationError(f"evidence path is not a regular file: {path}")
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise EvaluationError(f"evidence path is not a unique regular file: {path}")
    return {"sha256": sha256_file(path), "size_bytes": metadata.st_size}


def canonical_pcm16_mono_samples(
    path: Path,
    *,
    expected_frame_count: int,
    label: str,
    source_format: str,
) -> bytes:
    """Read a strict product WAV and return its canonical PCM16 sample bytes."""

    if (
        not isinstance(expected_frame_count, int)
        or isinstance(expected_frame_count, bool)
        or expected_frame_count < 0
    ):
        raise EvaluationError(f"{label} has an invalid expected frame count")
    bytes_per_frame = {"float32": 4, "pcm16": 2}.get(source_format)
    if bytes_per_frame is None:
        raise EvaluationError(f"unsupported internal WAV source format: {source_format}")
    maximum_container_bytes = expected_frame_count * bytes_per_frame + 64 * 1024
    try:
        metadata = path.lstat()
    except OSError as error:
        raise EvaluationError(f"{label} is not a readable WAV") from error
    if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
        raise EvaluationError(f"{label} is not a regular WAV file")
    if metadata.st_size > maximum_container_bytes:
        raise EvaluationError(f"{label} exceeds its bounded WAV container size")
    try:
        with path.open("rb") as source:
            payload = source.read(metadata.st_size + 1)
    except OSError as error:
        raise EvaluationError(f"{label} is not a readable WAV") from error
    if len(payload) > maximum_container_bytes:
        raise EvaluationError(f"{label} exceeds its bounded WAV container size")
    if len(payload) != metadata.st_size:
        raise EvaluationError(f"{label} changed while its WAV evidence was read")
    if len(payload) < 12 or payload[:4] != b"RIFF" or payload[8:12] != b"WAVE":
        raise EvaluationError(f"{label} is not a little-endian RIFF/WAVE file")
    if struct.unpack_from("<I", payload, 4)[0] != len(payload) - 8:
        raise EvaluationError(f"{label} has an invalid RIFF size")

    payload_view = memoryview(payload)
    chunks: dict[bytes, memoryview] = {}
    offset = 12
    while offset < len(payload):
        if len(payload) - offset < 8:
            raise EvaluationError(f"{label} has a truncated RIFF chunk header")
        chunk_id = payload[offset : offset + 4]
        chunk_size = struct.unpack_from("<I", payload, offset + 4)[0]
        data_start = offset + 8
        data_end = data_start + chunk_size
        padded_end = data_end + (chunk_size & 1)
        if data_end > len(payload) or padded_end > len(payload):
            raise EvaluationError(f"{label} has a truncated RIFF chunk")
        if chunk_size & 1 and payload[data_end] != 0:
            raise EvaluationError(f"{label} has a nonzero RIFF padding byte")
        if chunk_id in chunks:
            raise EvaluationError(f"{label} repeats a RIFF chunk")
        chunks[chunk_id] = payload_view[data_start:data_end]
        offset = padded_end
    if offset != len(payload):
        raise EvaluationError(f"{label} has trailing bytes outside its RIFF chunks")

    format_chunk = chunks.get(b"fmt ")
    audio_data = chunks.get(b"data")
    if format_chunk is None or audio_data is None or len(format_chunk) != 16:
        raise EvaluationError(f"{label} lacks an exact fmt or data chunk")
    audio_format, channels, sample_rate, byte_rate, block_align, bits_per_sample = (
        struct.unpack("<HHIIHH", format_chunk)
    )
    expected_format = {
        "float32": (3, 1, 16_000, 64_000, 4, 32),
        "pcm16": (1, 1, 16_000, 32_000, 2, 16),
    }.get(source_format)
    assert expected_format is not None
    if (
        audio_format,
        channels,
        sample_rate,
        byte_rate,
        block_align,
        bits_per_sample,
    ) != expected_format:
        raise EvaluationError(f"{label} is not 16 kHz mono {source_format} WAV")
    expected_data_bytes = expected_frame_count * block_align
    if len(audio_data) != expected_data_bytes:
        raise EvaluationError(f"{label} does not contain the exact expected frame count")
    if source_format == "pcm16":
        return bytes(audio_data)

    canonical = bytearray(len(audio_data) // 2)
    output_offset = 0
    for (sample,) in struct.iter_unpack("<f", audio_data):
        if not math.isfinite(sample):
            raise EvaluationError(f"{label} contains a non-finite Float32 sample")
        if abs(sample) > 0.950001:
            raise EvaluationError(f"{label} contains an out-of-range Float32 sample")
        scaled = sample * 32_768.0
        rounded = math.floor(scaled + 0.5) if scaled >= 0 else math.ceil(scaled - 0.5)
        saturated = max(-32_768, min(32_767, rounded))
        struct.pack_into("<h", canonical, output_offset, saturated)
        output_offset += 2
    return bytes(canonical)


def reject_symlink_components(path: Path, *, label: str) -> None:
    absolute = path.absolute()
    components = list(reversed(absolute.parents)) + [absolute]
    for component in components:
        if component.is_symlink():
            raise EvaluationError(f"{label} contains a symlinked path component")


def same_open_directory(path: Path, directory_fd: int) -> bool:
    try:
        path_metadata = path.stat(follow_symlinks=False)
        descriptor_metadata = os.fstat(directory_fd)
    except OSError:
        return False
    return (
        stat.S_ISDIR(path_metadata.st_mode)
        and path_metadata.st_dev == descriptor_metadata.st_dev
        and path_metadata.st_ino == descriptor_metadata.st_ino
    )


def directory_path_from_fd(directory_fd: int) -> Path:
    raw = fcntl.fcntl(directory_fd, 50, b"\0" * 1024)  # F_GETPATH on macOS.
    value = raw.split(b"\0", 1)[0]
    if not value:
        raise EvaluationError("cannot resolve anchored evaluation directory")
    path = Path(os.fsdecode(value))
    if not same_open_directory(path, directory_fd):
        raise EvaluationError("anchored evaluation directory identity mismatch")
    return path


def publish_directory_exclusive(
    *,
    staging_name: str,
    destination_name: str,
    destination_parent: Path,
    staging_parent_fd: int,
    destination_parent_fd: int,
) -> None:
    """Atomically publish a directory without replacing an existing entry on macOS."""

    if sys.platform != "darwin":
        raise EvaluationError("exclusive acceptance publication requires macOS")
    if not same_open_directory(destination_parent, destination_parent_fd):
        raise EvaluationError("evaluation output parent identity changed before publication")
    libc = ctypes.CDLL(None, use_errno=True)
    renameatx_np = libc.renameatx_np
    renameatx_np.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    renameatx_np.restype = ctypes.c_int
    rename_excl = 0x00000004
    result = renameatx_np(
        staging_parent_fd,
        os.fsencode(staging_name),
        destination_parent_fd,
        os.fsencode(destination_name),
        rename_excl,
    )
    if result == 0:
        return
    error_number = ctypes.get_errno()
    if error_number in (errno.EEXIST, errno.ENOTEMPTY):
        raise FileExistsError("create-only evaluation output already exists")
    raise EvaluationError(f"exclusive evaluation publication failed with errno {error_number}")


def snapshot_tree(root: Path) -> dict[str, dict[str, object]]:
    if root.is_symlink():
        raise EvaluationError(f"source run root is a symlink: {root}")
    root = root.resolve(strict=True)
    if not root.is_dir():
        raise EvaluationError(f"source run is not a directory: {root}")
    records: dict[str, dict[str, object]] = {}
    for directory, names, files in os.walk(root, followlinks=False):
        current = Path(directory)
        for name in names:
            candidate = current / name
            if candidate.is_symlink():
                raise EvaluationError(f"source run contains a directory symlink: {candidate.relative_to(root)}")
        for name in files:
            candidate = current / name
            relative = candidate.relative_to(root).as_posix()
            records[relative] = file_record(candidate)
    if "manifest.json" not in records:
        raise EvaluationError("source run has no manifest.json")
    return dict(sorted(records.items()))


def snapshot_source_run_envelope(root: Path) -> dict[str, dict[str, object]]:
    """Inventory only the immutable source-run evidence sealed by its manifest.

    Existing-run operations append create-only evidence below the top-level
    ``derived/`` directory. That later evidence is not part of the canonical
    source-run envelope. Finder metadata is likewise outside the manifest
    inventory. Refuse aliases or non-directories at the boundary itself, then
    avoid traversing the unrelated derived tree.
    """

    if root.is_symlink():
        raise EvaluationError(f"source run root is a symlink: {root}")
    root = root.resolve(strict=True)
    if not root.is_dir():
        raise EvaluationError(f"source run is not a directory: {root}")

    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    root_fd = os.open(root, directory_flags)
    derived_fd: int | None = None
    evidence_stable_fields = (
        "st_dev",
        "st_ino",
        "st_mode",
        "st_nlink",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    file_anchors: dict[str, os.stat_result] = {}
    directory_snapshots: dict[
        str,
        tuple[os.stat_result, dict[str, os.stat_result], bool],
    ] = {}

    def same_derived_directory() -> bool:
        if derived_fd is None:
            return False
        try:
            path_metadata = os.stat("derived", dir_fd=root_fd, follow_symlinks=False)
            descriptor_metadata = os.fstat(derived_fd)
        except OSError:
            return False
        return (
            stat.S_ISDIR(path_metadata.st_mode)
            and path_metadata.st_dev == descriptor_metadata.st_dev
            and path_metadata.st_ino == descriptor_metadata.st_ino
        )

    def open_derived_directory() -> int | None:
        try:
            path_metadata = os.stat("derived", dir_fd=root_fd, follow_symlinks=False)
        except FileNotFoundError:
            return None
        if stat.S_ISLNK(path_metadata.st_mode):
            raise EvaluationError("source run derived evidence root is a symlink")
        if not stat.S_ISDIR(path_metadata.st_mode):
            raise EvaluationError("source run derived evidence root is not a directory")
        try:
            descriptor = os.open("derived", directory_flags, dir_fd=root_fd)
        except OSError as error:
            raise EvaluationError("source run derived evidence root changed during inventory") from error
        descriptor_metadata = os.fstat(descriptor)
        if (
            path_metadata.st_dev != descriptor_metadata.st_dev
            or path_metadata.st_ino != descriptor_metadata.st_ino
        ):
            os.close(descriptor)
            raise EvaluationError("source run derived evidence root changed during inventory")
        return descriptor

    def anchored_file_record(
        parent_fd: int,
        name: str,
        relative: str,
        expected: os.stat_result,
    ) -> dict[str, object]:
        try:
            path_metadata = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
        except OSError as error:
            raise EvaluationError(f"evidence path is not a regular file: {relative}") from error
        if not stat.S_ISREG(path_metadata.st_mode):
            raise EvaluationError(f"evidence path is not a regular file: {relative}")
        if path_metadata.st_nlink != 1:
            raise EvaluationError(f"evidence path is not a unique regular file: {relative}")
        if any(
            getattr(expected, field) != getattr(path_metadata, field)
            for field in evidence_stable_fields
        ):
            raise EvaluationError(f"evidence path changed before it was opened: {relative}")
        try:
            descriptor = os.open(
                name,
                os.O_RDONLY
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_NONBLOCK", 0),
                dir_fd=parent_fd,
            )
        except OSError as error:
            raise EvaluationError(f"evidence path changed while it was opened: {relative}") from error
        try:
            before = os.fstat(descriptor)
            if (
                not stat.S_ISREG(before.st_mode)
                or before.st_nlink != 1
                or any(
                    getattr(expected, field) != getattr(before, field)
                    for field in evidence_stable_fields
                )
            ):
                raise EvaluationError(f"evidence path changed while it was opened: {relative}")
            digest = sha256()
            size_bytes = 0
            while True:
                block = os.read(descriptor, 1024 * 1024)
                if not block:
                    break
                digest.update(block)
                size_bytes += len(block)
            after = os.fstat(descriptor)
            if (
                any(
                    getattr(before, field) != getattr(after, field)
                    for field in evidence_stable_fields
                )
                or size_bytes != after.st_size
            ):
                raise EvaluationError(f"evidence path changed while it was read: {relative}")
            try:
                final_path_metadata = os.stat(
                    name,
                    dir_fd=parent_fd,
                    follow_symlinks=False,
                )
            except OSError as error:
                raise EvaluationError(f"evidence path changed while it was read: {relative}") from error
            if any(
                getattr(final_path_metadata, field) != getattr(after, field)
                for field in evidence_stable_fields
            ):
                raise EvaluationError(f"evidence path changed while it was read: {relative}")
            file_anchors[relative] = expected
            return {"sha256": digest.hexdigest(), "size_bytes": size_bytes}
        finally:
            os.close(descriptor)

    def inventory_directory(
        directory_fd: int,
        relative_root: Path,
        records: dict[str, dict[str, object]],
        *,
        source_root: bool = False,
        expected_directory: os.stat_result | None = None,
        depth: int = 0,
    ) -> bool:
        nonlocal derived_fd
        if depth > SOURCE_ENVELOPE_MAX_DIRECTORY_DEPTH:
            raise EvaluationError("source run directory depth exceeds the configured maximum")
        saw_derived = False
        try:
            names = sorted(os.listdir(directory_fd))
        except OSError as error:
            raise EvaluationError("source run directory changed during inventory") from error
        initial_entries: dict[str, os.stat_result] = {}
        for name in names:
            try:
                initial_entries[name] = os.stat(
                    name,
                    dir_fd=directory_fd,
                    follow_symlinks=False,
                )
            except OSError as error:
                raise EvaluationError("source run directory changed during inventory") from error
        directory_metadata = os.fstat(directory_fd)
        if expected_directory is not None and any(
            getattr(expected_directory, field) != getattr(directory_metadata, field)
            for field in evidence_stable_fields
        ):
            raise EvaluationError("source run directory changed during inventory")
        relative_directory = "" if relative_root == Path() else relative_root.as_posix()
        directory_snapshots[relative_directory] = (
            directory_metadata,
            initial_entries,
            source_root,
        )
        for name in names:
            relative_path = relative_root / name
            relative = relative_path.as_posix()
            metadata = initial_entries[name]
            if source_root and name == "derived":
                if stat.S_ISLNK(metadata.st_mode):
                    raise EvaluationError("source run derived evidence root is a symlink")
                if not stat.S_ISDIR(metadata.st_mode):
                    raise EvaluationError("source run derived evidence root is not a directory")
                if derived_fd is None:
                    derived_fd = open_derived_directory()
                if derived_fd is None or not same_derived_directory():
                    raise EvaluationError("source run derived evidence root changed during inventory")
                saw_derived = True
                continue
            if stat.S_ISDIR(metadata.st_mode):
                child_depth = depth + 1
                if child_depth > SOURCE_ENVELOPE_MAX_DIRECTORY_DEPTH:
                    raise EvaluationError(
                        "source run directory depth exceeds the configured maximum"
                    )
                try:
                    child_fd = os.open(name, directory_flags, dir_fd=directory_fd)
                except OSError as error:
                    raise EvaluationError(
                        f"source run directory changed during inventory: {relative}"
                    ) from error
                try:
                    child_metadata = os.fstat(child_fd)
                    if any(
                        getattr(metadata, field) != getattr(child_metadata, field)
                        for field in evidence_stable_fields
                    ):
                        raise EvaluationError(
                            f"source run directory changed during inventory: {relative}"
                        )
                    inventory_directory(
                        child_fd,
                        relative_path,
                        records,
                        expected_directory=metadata,
                        depth=child_depth,
                    )
                finally:
                    os.close(child_fd)
                continue
            record = anchored_file_record(directory_fd, name, relative, metadata)
            if name != ".DS_Store":
                records[relative] = record
        verify_directory_roster(
            directory_fd,
            initial_entries,
            source_root=source_root,
            final=False,
        )
        return saw_derived

    def verify_directory_roster(
        directory_fd: int,
        initial_entries: dict[str, os.stat_result],
        *,
        source_root: bool,
        final: bool,
    ) -> None:
        label = "final inventory" if final else "inventory"
        try:
            final_names = sorted(os.listdir(directory_fd))
        except OSError as error:
            raise EvaluationError(f"source run directory changed during {label}") from error
        if final_names != sorted(initial_entries):
            raise EvaluationError(f"source run directory changed during {label}")
        for name, initial_metadata in initial_entries.items():
            try:
                final_metadata = os.stat(
                    name,
                    dir_fd=directory_fd,
                    follow_symlinks=False,
                )
            except OSError as error:
                raise EvaluationError(f"source run directory changed during {label}") from error
            fields = (
                ("st_dev", "st_ino", "st_mode")
                if source_root and name == "derived"
                else evidence_stable_fields
            )
            if any(
                getattr(final_metadata, field) != getattr(initial_metadata, field)
                for field in fields
            ):
                raise EvaluationError(f"source run directory changed during {label}")

    def verify_complete_inventory() -> None:
        visited_directories: set[str] = set()
        visited_files: set[str] = set()

        def verify_directory(
            descriptor: int,
            relative_root: Path,
            *,
            source_root: bool = False,
            depth: int = 0,
        ) -> None:
            if depth > SOURCE_ENVELOPE_MAX_DIRECTORY_DEPTH:
                raise EvaluationError("source run directory depth exceeds the configured maximum")
            relative_directory = "" if relative_root == Path() else relative_root.as_posix()
            snapshot = directory_snapshots.get(relative_directory)
            if snapshot is None:
                raise EvaluationError("source run contains an unrecorded directory")
            expected_directory, initial_entries, expected_source_root = snapshot
            if expected_source_root != source_root:
                raise EvaluationError("source run directory role changed during final inventory")
            try:
                descriptor_metadata = os.fstat(descriptor)
            except OSError as error:
                raise EvaluationError("source run directory changed during final inventory") from error
            if any(
                getattr(expected_directory, field) != getattr(descriptor_metadata, field)
                for field in evidence_stable_fields
            ):
                raise EvaluationError("source run directory changed during final inventory")
            verify_directory_roster(
                descriptor,
                initial_entries,
                source_root=source_root,
                final=True,
            )
            visited_directories.add(relative_directory)
            for name, initial_metadata in initial_entries.items():
                relative_path = relative_root / name
                relative = relative_path.as_posix()
                if source_root and name == "derived":
                    continue
                if stat.S_ISDIR(initial_metadata.st_mode):
                    child_depth = depth + 1
                    if child_depth > SOURCE_ENVELOPE_MAX_DIRECTORY_DEPTH:
                        raise EvaluationError(
                            "source run directory depth exceeds the configured maximum"
                        )
                    try:
                        child_fd = os.open(name, directory_flags, dir_fd=descriptor)
                    except OSError as error:
                        raise EvaluationError(
                            "source run directory changed during final inventory"
                        ) from error
                    try:
                        verify_directory(child_fd, relative_path, depth=child_depth)
                    finally:
                        os.close(child_fd)
                    continue
                expected_file = file_anchors.get(relative)
                if expected_file is None or any(
                    getattr(expected_file, field) != getattr(initial_metadata, field)
                    for field in evidence_stable_fields
                ):
                    raise EvaluationError("source run file anchor changed during final inventory")
                visited_files.add(relative)

        verify_directory(root_fd, Path(), source_root=True)
        if visited_directories != set(directory_snapshots):
            raise EvaluationError("source run directory inventory is incomplete")
        if visited_files != set(file_anchors):
            raise EvaluationError("source run file inventory is incomplete")

    try:
        if not same_open_directory(root, root_fd):
            raise EvaluationError("source run root identity changed during inventory")
        derived_fd = open_derived_directory()
        records: dict[str, dict[str, object]] = {}
        saw_derived = inventory_directory(root_fd, Path(), records, source_root=True)
        if (derived_fd is not None) != saw_derived:
            raise EvaluationError("source run derived evidence root changed during inventory")
        if not same_open_directory(root, root_fd):
            raise EvaluationError("source run root identity changed during inventory")
        if derived_fd is not None:
            if not same_derived_directory():
                raise EvaluationError("source run derived evidence root changed during inventory")
        else:
            try:
                os.stat("derived", dir_fd=root_fd, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                raise EvaluationError("source run derived evidence root changed during inventory")
        verify_complete_inventory()
        if "manifest.json" not in records:
            raise EvaluationError("source run has no manifest.json")
        return dict(sorted(records.items()))
    finally:
        if derived_fd is not None:
            os.close(derived_fd)
        os.close(root_fd)


def snapshot_fixture_tree(root: Path) -> dict[str, dict[str, object]]:
    """Inventory a fixture without following aliases or accepting special files."""

    if root.is_symlink():
        raise EvaluationError("fixture root is a symlink")
    root = root.resolve(strict=True)
    records: dict[str, dict[str, object]] = {}
    for directory, names, files in os.walk(root, followlinks=False):
        current = Path(directory)
        for name in names:
            candidate = current / name
            if candidate.is_symlink():
                raise EvaluationError("fixture contains a directory symlink")
        for name in files:
            candidate = current / name
            relative = candidate.relative_to(root).as_posix()
            records[relative] = file_record(candidate)
    return dict(sorted(records.items()))


def acceptance_memory_supported(memory_bytes: int) -> bool:
    """Return whether the benchmark-only model-run stop condition is met."""

    return memory_bytes >= MINIMUM_ACCEPTANCE_MEMORY_BYTES


def validate_exact_partition(
    ranges: Sequence[tuple[int, int]],
    expected_start: int,
    expected_end: int,
    *,
    label: str,
) -> None:
    cursor = expected_start
    for start_sample, end_sample in sorted(ranges):
        if start_sample != cursor or end_sample <= start_sample:
            raise EvaluationError(f"{label} has a gap or overlap")
        cursor = end_sample
    if cursor != expected_end:
        raise EvaluationError(f"{label} does not cover its expected range")


def verify_hike_source_derivation(
    acceptance_root: Path,
    fixture: dict[str, Any],
    fixture_root: Path,
) -> None:
    """Replay every transcript- and glossary-bearing HiKE artifact from Parquet."""

    source_path = acceptance_root / "sources/hike/data/test-00000-of-00001.parquet"
    rows, expected_selection = select_hike_rows(hike_rows(source_path, fixture), fixture)
    silence_frames = int(float(fixture["selection"]["silence_between_items_s"]) * 16_000)
    cursor_frames = 0
    expected_segments: list[dict[str, object]] = []
    expected_items: list[dict[str, object]] = []
    pcm_pieces: list[bytes] = []
    for index, row in enumerate(rows):
        info = wave_info_bytes(row["audio_bytes"])
        start_s = rounded_seconds(cursor_frames / 16_000)
        cursor_frames += info.frames
        end_s = rounded_seconds(cursor_frames / 16_000)
        relative = f"items/{index:02d}.wav"
        if (fixture_root / relative).read_bytes() != row["audio_bytes"]:
            raise EvaluationError("HiKE item WAV differs from its pinned Parquet row")
        with wave.open(BytesIO(row["audio_bytes"]), "rb") as source:
            pcm_pieces.append(source.readframes(source.getnframes()))
        expected_segments.append(
            {
                "speaker": "UNASSIGNED",
                "start_s": start_s,
                "end_s": end_s,
                "text": row["text_normalized"],
                "language": "ko-en",
            }
        )
        expected_items.append(
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
                "item_wav_sha256": row["source_audio_sha256"],
                "reel_start_s": start_s,
                "reel_end_s": end_s,
            }
        )
        if index + 1 < len(rows):
            cursor_frames += silence_frames
    expected_reel = BytesIO()
    silence = b"\0" * silence_frames * 2
    with wave.open(expected_reel, "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(16_000)
        for index, pcm in enumerate(pcm_pieces):
            output.writeframes(pcm)
            if index + 1 < len(pcm_pieces):
                output.writeframes(silence)
    if (fixture_root / "input.wav").read_bytes() != expected_reel.getvalue():
        raise EvaluationError("HiKE input reel differs from the pinned source-derived audio")
    reference = load_json(fixture_root / "reference.segments.json")
    if reference.get("segments") != expected_segments:
        raise EvaluationError("HiKE reference differs from the pinned source-derived rows")
    reference_text = " ".join(str(segment["text"]) for segment in expected_segments)
    expected_terms, term_sources = derive_hike_glossary(rows, reference_text)
    if load_json(fixture_root / "terms.json") != expected_terms:
        raise EvaluationError("HiKE terms differ from the pinned source-derived rows")
    if (fixture_root / "glossary.txt").read_text(encoding="utf-8") != (
        "\n".join(str(entry["term"]) for entry in expected_terms) + "\n"
    ):
        raise EvaluationError("HiKE glossary differs from the pinned source-derived rows")
    source_record = fixture["source"]
    source_hash = sha256_file(source_path)
    expected_selection_document = {
        "fixture_id": fixture["fixture_id"],
        "source": {
            "dataset_id": source_record["dataset_id"],
            "revision": source_record["revision"],
            "source_sha256": source_hash,
        },
        "selection": expected_selection,
        "items": expected_items,
        "reference_text": reference_text,
        "term_source_sample_ids": term_sources,
    }
    if load_json(fixture_root / "selection.json") != expected_selection_document:
        raise EvaluationError("HiKE selection evidence differs from the source-derived contract")


def verify_source_derived_fixture(
    acceptance_root: Path,
    fixture_id: str,
    fixture_root: Path,
) -> None:
    """Run the canonical source verifier plus the stricter HiKE replay."""

    try:
        pack = load_pack(PACK_MANIFEST)
        fixture = fixture_named(pack, fixture_id)
        verify_prepared_fixture(acceptance_root, fixture)
        if fixture_id == "hike-code-switch-v1":
            verify_hike_source_derivation(acceptance_root, fixture, fixture_root)
        else:
            verify_ami_source_derivation(acceptance_root, fixture, fixture_root)
    except PackError as error:
        raise EvaluationError("source-derived prepared fixture verification failed") from error


def verify_ami_source_derivation(
    acceptance_root: Path,
    fixture: dict[str, Any],
    fixture_root: Path,
) -> None:
    """Replay AMI transcript, RTTM, glossary, and selection from annotations."""

    audio_path = acceptance_root / "sources/ami/IN1009.Mix-Headset.wav"
    archive_path = acceptance_root / "sources/ami/ami_public_manual_1.6.2.zip"
    expected_asr, expected_rttm, mapping = ami_reference_from_archive(archive_path)
    reference = load_json(fixture_root / "reference.segments.json")
    if reference.get("segments") != expected_asr:
        raise EvaluationError("AMI reference differs from the pinned manual annotations")
    reference_text = " ".join(str(segment["text"]) for segment in expected_asr)
    expected_terms = derive_ami_glossary(reference_text)
    if load_json(fixture_root / "terms.json") != expected_terms:
        raise EvaluationError("AMI terms differ from the pinned source-derived glossary rule")
    if (fixture_root / "glossary.txt").read_text(encoding="utf-8") != (
        "\n".join(str(entry["term"]) for entry in expected_terms) + "\n"
    ):
        raise EvaluationError("AMI glossary differs from the pinned source-derived glossary rule")
    expected_rttm_bytes = (
        "\n".join(
            "SPEAKER IN1009 1 "
            f"{float(turn['start_s']):.6f} "
            f"{float(turn['end_s']) - float(turn['start_s']):.6f} "
            f"<NA> <NA> {turn['speaker']} <NA> <NA>"
            for turn in expected_rttm
        )
        + "\n"
    ).encode("utf-8")
    if (fixture_root / "reference.rttm").read_bytes() != expected_rttm_bytes:
        raise EvaluationError("AMI RTTM differs from the pinned manual annotations")
    derivation = fixture["reference_derivation"]
    expected_selection = {
        "fixture_id": fixture["fixture_id"],
        "source": {
            "meeting_id": fixture["source"]["meeting_id"],
            "audio_sha256": sha256_file(audio_path),
            "annotations_sha256": sha256_file(archive_path),
        },
        "speaker_mapping": mapping,
        "reference_derivation": derivation,
        "reference_text": reference_text,
        "lexical_word_count": sum(len(str(segment["text"]).split()) for segment in expected_asr),
        "term_reference_occurrences": {
            entry["term"]: entry["reference_count"] for entry in expected_terms
        },
    }
    if load_json(fixture_root / "selection.json") != expected_selection:
        raise EvaluationError("AMI selection evidence differs from the source-derived contract")
    audio_info = wave_info_file(audio_path)
    expected_source = {
        "file_name": audio_path.name,
        "sha256": sha256_file(audio_path),
        "duration_s": rounded_seconds(audio_info.duration_s),
    }
    if reference.get("source") != expected_source:
        raise EvaluationError("AMI reference source differs from the pinned recording")


def validate_fixture(
    fixture_root: Path,
    fixture_id: str,
    input_path: Path,
) -> dict[str, object]:
    if fixture_root.is_symlink() or input_path.is_symlink():
        raise EvaluationError("fixture root and input must not be symlinks")
    fixture_root = fixture_root.resolve(strict=True)
    input_path = input_path.resolve(strict=True)
    if fixture_root.name != fixture_id:
        raise EvaluationError("fixture directory name does not match fixture ID")
    fixture_files = snapshot_fixture_tree(fixture_root)
    check_path = fixture_root / "fixture-check.json"
    check = load_json(check_path)
    if not isinstance(check, dict) or check.get("fixture_id") != fixture_id or check.get("passed") is not True:
        raise EvaluationError("fixture-check identity or status mismatch")

    artifact_hashes = check.get("artifact_sha256")
    if not isinstance(artifact_hashes, dict) or not artifact_hashes:
        raise EvaluationError("fixture-check has no artifact hashes")
    sealed_artifacts: dict[str, str] = {}
    for raw_relative, raw_expected in artifact_hashes.items():
        relative = safe_relative(raw_relative, label="fixture artifact path")
        expected = require_hash(raw_expected, label=f"fixture artifact {relative} hash")
        artifact = fixture_root / relative
        if file_record(artifact)["sha256"] != expected:
            raise EvaluationError(f"fixture artifact hash mismatch: {relative}")
        sealed_artifacts[relative] = expected

    source_hashes = check.get("source_hashes_before")
    if not isinstance(source_hashes, dict) or source_hashes != check.get("source_hashes_after"):
        raise EvaluationError("fixture source hashes do not match before and after preparation")
    acceptance_root = fixture_root.parent.parent
    sealed_sources: dict[str, str] = {}
    for raw_relative, raw_expected in source_hashes.items():
        relative = safe_relative(raw_relative, label="fixture source path")
        expected = require_hash(raw_expected, label=f"fixture source {relative} hash")
        source = acceptance_root / relative
        reject_symlink_components(source, label="fixture source")
        if file_record(source)["sha256"] != expected:
            raise EvaluationError(f"fixture source hash mismatch: {relative}")
        sealed_sources[relative] = expected
    pack = load_json(PACK_MANIFEST)
    fixtures = pack.get("fixtures") if isinstance(pack, dict) else None
    declarations = [item for item in fixtures or [] if isinstance(item, dict) and item.get("fixture_id") == fixture_id]
    if len(declarations) != 1:
        raise EvaluationError("tracked acceptance-pack manifest has no unique fixture declaration")
    declared_files = declarations[0].get("source", {}).get("files")
    if not isinstance(declared_files, list):
        raise EvaluationError("tracked fixture declaration has no source files")
    declared_sources = {
        safe_relative(item.get("relative_path"), label="tracked fixture source path"):
        require_hash(item.get("sha256"), label="tracked fixture source hash")
        for item in declared_files
        if isinstance(item, dict)
    }
    if sealed_sources != declared_sources:
        raise EvaluationError("fixture source hashes differ from the tracked acceptance-pack manifest")
    verify_source_derived_fixture(acceptance_root, fixture_id, fixture_root)

    input_check = check.get("input_wav")
    if not isinstance(input_check, dict):
        raise EvaluationError("fixture-check has no input_wav record")
    try:
        input_audio = wave_info_file(input_path)
    except PackError as error:
        raise EvaluationError("fixture input is not a readable PCM WAV") from error
    if (
        input_audio.sample_rate_hz != 16_000
        or input_audio.channels != 1
        or input_audio.sample_width_bytes != 2
        or input_check.get("sample_rate_hz") != input_audio.sample_rate_hz
        or input_check.get("channels") != input_audio.channels
        or input_check.get("sample_width_bytes") != input_audio.sample_width_bytes
        or input_check.get("duration_s") != rounded_seconds(input_audio.duration_s)
    ):
        raise EvaluationError("fixture-check input_wav differs from the physical PCM input")
    input_frame_count = input_audio.frames
    expected_input_hash = require_hash(input_check.get("sha256"), label="fixture input hash")
    input_record = file_record(input_path)
    if input_record["sha256"] != expected_input_hash:
        raise EvaluationError("fixture input hash mismatch")
    if input_record["size_bytes"] != input_check.get("size_bytes"):
        raise EvaluationError("fixture input size mismatch")

    required = {"reference.segments.json", "terms.json", "glossary.txt", "selection.json"}
    if fixture_id == "hike-code-switch-v1":
        required.add("input.wav")
    else:
        required.add("reference.rttm")
    missing = required - sealed_artifacts.keys()
    if missing:
        raise EvaluationError(f"fixture-check does not seal required artifacts: {sorted(missing)}")
    if set(fixture_files) != {"fixture-check.json", *sealed_artifacts}:
        raise EvaluationError("prepared fixture contains files outside fixture-check artifact seals")

    reference = load_json(fixture_root / "reference.segments.json")
    if not isinstance(reference, dict) or reference.get("source") != {
        "file_name": input_path.name,
        "sha256": expected_input_hash,
        "duration_s": input_check.get("duration_s"),
    }:
        raise EvaluationError("fixture reference source identity differs from input_wav")
    segments = reference.get("segments")
    if not isinstance(segments, list) or len(segments) != check.get("reference_segment_count"):
        raise EvaluationError("fixture reference segment count mismatch")
    terms = load_json(fixture_root / "terms.json")
    if not isinstance(terms, list) or len(terms) != check.get("term_count") or not terms:
        raise EvaluationError("fixture term count mismatch")
    if any(not isinstance(item, dict) or not isinstance(item.get("term"), str) or not item["term"] for item in terms):
        raise EvaluationError("fixture terms contain an invalid entry")
    reference_text = " ".join(str(item.get("text", "")) for item in segments if isinstance(item, dict))
    for term in terms:
        if term.get("reference_count") != count_term_occurrences(term["term"], reference_text):
            raise EvaluationError(f"fixture term reference count mismatch: {term['term']!r}")
    glossary_lines = (fixture_root / "glossary.txt").read_text(encoding="utf-8").splitlines()
    if glossary_lines != [item["term"] for item in terms]:
        raise EvaluationError("fixture glossary is not the ordered terms projection")

    return {
        "artifact_sha256": dict(sorted(sealed_artifacts.items())),
        "fixture_check_sha256": sha256_file(check_path),
        "input_frame_count": input_frame_count,
        "input_sha256": expected_input_hash,
        "input_size_bytes": input_record["size_bytes"],
        "pack_manifest_sha256": sha256_file(PACK_MANIFEST),
        "source_sha256": dict(sorted(sealed_sources.items())),
        "term_count": len(terms),
    }


def validate_source_run(
    source_run: Path,
    input_path: Path,
    glossary_path: Path,
    kind: str,
) -> tuple[dict[str, Any], dict[str, dict[str, object]]]:
    for label, path in (("source run", source_run), ("input", input_path), ("glossary", glossary_path)):
        if path.is_symlink():
            raise EvaluationError(f"{label} path is a symlink")
    source_run = source_run.resolve(strict=True)
    input_path = input_path.resolve(strict=True)
    glossary_path = glossary_path.resolve(strict=True)
    manifest, artifact_paths = validate_completed_run_manifest(source_run)
    reject_nonfinite(manifest, label="source manifest")
    missing = set(REQUIRED_SUCCESS_ARTIFACTS) - artifact_paths
    if missing:
        raise EvaluationError(f"source run omits required artifacts: {sorted(missing)}")
    if manifest["input"] != {
        "file_name": input_path.name,
        "sha256": sha256_file(input_path),
        "size_bytes": input_path.stat().st_size,
    }:
        raise EvaluationError("source run input identity differs from the fixture input")
    glossary = manifest.get("glossary")
    if not isinstance(glossary, dict) or not (
        glossary.get("provided") is True
        and glossary.get("applied") is True
        and glossary.get("sha256") == sha256_file(glossary_path)
        and isinstance(glossary.get("item_count"), int)
        and glossary["item_count"] > 0
        and glossary.get("injection_mode") != "none"
    ):
        raise EvaluationError("source run does not prove the fixture glossary was applied")
    models = manifest.get("models")
    if models != EXPECTED_MODELS:
        raise EvaluationError("source run does not contain the exact pinned ko-meeting model tuples")
    if manifest.get("backend") != EXPECTED_BACKEND:
        raise EvaluationError("source run does not contain the exact pinned VibeVoice backend")
    if manifest.get("postprocess") is not None:
        raise EvaluationError("source run does not use the ko-meeting no-postprocess lane")
    if manifest.get("preprocessing", {}).get("vad") != {"enabled": True, "backend": "silero"}:
        raise EvaluationError("source run does not prove the pinned Silero VAD path")

    duration = float(manifest["coverage"]["input_duration_s"])
    for relative in (
        "primary/segments.json",
        "merged/segments.json",
        "diarization/timeline.json",
        "merged/conflicts.json",
    ):
        load_json(source_run / relative)
    validate_segments(source_run / "primary/segments.json", schema_validator=None, input_path=input_path, duration=duration)
    validate_segments(source_run / "merged/segments.json", schema_validator=None, input_path=input_path, duration=duration)
    validate_timeline(source_run / "diarization/timeline.json", duration=duration)
    validate_conflicts(source_run / "merged/conflicts.json")
    source_files = snapshot_source_run_envelope(source_run)
    expected_files = {"manifest.json", *artifact_paths}
    if set(source_files) != expected_files:
        raise EvaluationError("source run contains files outside its sealed manifest artifacts")
    return manifest, source_files


def validate_runner_evidence(
    source_run: Path,
    manifest: dict[str, Any],
    expected_glossary_payload_sha256: str,
    *,
    trusted_input_frame_count: int,
) -> dict[str, object]:
    if (
        not isinstance(trusted_input_frame_count, int)
        or isinstance(trusted_input_frame_count, bool)
        or trusted_input_frame_count <= 0
    ):
        raise EvaluationError("fixture input frame count is invalid")
    coverage = manifest.get("coverage")
    manifest_duration = coverage.get("input_duration_s") if isinstance(coverage, dict) else None
    trusted_duration = trusted_input_frame_count / 16_000
    duration_tolerance = 0.5 / 16_000 + 1e-9
    if (
        not isinstance(manifest_duration, (int, float))
        or isinstance(manifest_duration, bool)
        or not math.isfinite(float(manifest_duration))
        or abs(float(manifest_duration) - trusted_duration) > duration_tolerance
    ):
        raise EvaluationError("source manifest duration differs from the sealed fixture frame count")
    manifest_artifacts = {
        item["path"]: item["sha256"]
        for item in manifest.get("artifacts", [])
        if isinstance(item, dict)
        and isinstance(item.get("path"), str)
        and isinstance(item.get("sha256"), str)
    }

    def sealed_evidence_file(relative: str) -> dict[str, object]:
        expected = manifest_artifacts.get(relative)
        if expected is None:
            raise EvaluationError(f"runner evidence is not manifest-sealed: {relative}")
        record = file_record(source_run / relative)
        if record["sha256"] != expected:
            raise EvaluationError(f"runner evidence differs from its manifest seal: {relative}")
        return record

    promotion_path = source_run / "primary/promotion.json"
    if not promotion_path.is_file():
        raise EvaluationError("source run has no canonical ASR promotion evidence")
    promotion = load_json(promotion_path)
    if not isinstance(promotion, dict) or not (
        promotion.get("input_sha256_before")
        == promotion.get("input_sha256_at_promotion")
        == manifest["input"]["sha256"]
    ):
        raise EvaluationError("canonical promotion does not prove source-input immutability")
    attempt_ids = promotion.get("eos_leaf_attempt_ids")
    result_hashes = promotion.get("eos_leaf_result_sha256")
    if not isinstance(attempt_ids, list) or not attempt_ids or not isinstance(result_hashes, list) or len(attempt_ids) != len(result_hashes):
        raise EvaluationError("canonical promotion has no closed EOS leaf set")
    if len(set(attempt_ids)) != len(attempt_ids):
        raise EvaluationError("canonical promotion repeats an EOS leaf")
    canonical = promotion.get("canonical_artifact_sha256")
    expected_canonical_paths = {
        "primary/raw.txt",
        "primary/segments.json",
        "merged/segments.json",
        "merged/conflicts.json",
    }
    if not isinstance(canonical, dict) or set(canonical) != expected_canonical_paths:
        raise EvaluationError("canonical promotion does not seal the exact canonical artifact set")
    for raw_relative, raw_expected in canonical.items():
        relative = safe_relative(raw_relative, label="canonical artifact path")
        expected = require_hash(raw_expected, label=f"canonical artifact {relative} hash")
        if sha256_file(source_run / relative) != expected:
            raise EvaluationError(f"canonical promotion artifact hash mismatch: {relative}")

    expected_preprocessing = {
        "sample_rate_hz": 16_000,
        "channels": 1,
        "peak_normalization": True,
        "vad": {"enabled": True, "backend": "silero"},
        "enhancement": {"enabled": False, "backend": None},
    }
    if manifest.get("preprocessing") != expected_preprocessing:
        raise EvaluationError("source run does not use the exact ko-meeting preprocessing contract")
    sample_rate = 16_000
    expected_input_samples = trusted_input_frame_count
    preprocessed_records = [
        item
        for item in manifest.get("artifacts", [])
        if isinstance(item, dict) and item.get("kind") == "preprocessed_audio"
    ]
    if len(preprocessed_records) != 1:
        raise EvaluationError("source run does not seal exactly one preprocessed audio artifact")
    preprocessed_relative = safe_relative(
        preprocessed_records[0].get("path"),
        label="preprocessed audio path",
    )
    sealed_evidence_file(preprocessed_relative)
    preprocessed_pcm = canonical_pcm16_mono_samples(
        source_run / preprocessed_relative,
        expected_frame_count=expected_input_samples,
        label="preprocessed acceptance input",
        source_format="float32",
    )
    boundaries = manifest.get("chunk_boundaries")
    if not isinstance(boundaries, list) or not boundaries:
        raise EvaluationError("source run has no ASR root chunk boundaries")
    root_by_attempt: dict[str, dict[str, object]] = {}
    root_ranges_by_index: dict[int, tuple[int, int]] = {}
    promoted_ids_from_roots: list[str] = []
    promoted_hashes_from_roots: list[str] = []
    for root_index, boundary in enumerate(boundaries):
        if not isinstance(boundary, dict) or not (
            boundary.get("index") == root_index
            and boundary.get("status") == "succeeded"
            and isinstance(boundary.get("start_s"), (int, float))
            and isinstance(boundary.get("end_s"), (int, float))
        ):
            raise EvaluationError("source run has noncanonical ASR root chunk boundaries")
        start_sample = round(float(boundary["start_s"]) * sample_rate)
        end_sample = round(float(boundary["end_s"]) * sample_rate)
        if (
            start_sample < 0
            or end_sample <= start_sample
            or end_sample > expected_input_samples
        ):
            raise EvaluationError("source run has an invalid ASR root sample range")
        root_ranges_by_index[root_index] = (start_sample, end_sample)
        chunk_audio_relative = f"primary/chunks/{root_index}/audio.wav"
        root_record_relative = f"primary/chunks/{root_index}/backend.raw"
        sealed_evidence_file(chunk_audio_relative)
        sealed_evidence_file(root_record_relative)
        chunk_pcm = canonical_pcm16_mono_samples(
            source_run / chunk_audio_relative,
            expected_frame_count=end_sample - start_sample,
            label=f"ASR root {root_index} audio",
            source_format="pcm16",
        )
        if chunk_pcm != preprocessed_pcm[start_sample * 2 : end_sample * 2]:
            raise EvaluationError("ASR root audio differs from its preprocessed-input sample range")
        root_record = load_json(source_run / root_record_relative)
        expected_root_attempt = f"chunk-{root_index:04d}-root"
        root_attempt_ids = root_record.get("eos_leaf_attempt_ids") if isinstance(root_record, dict) else None
        root_result_hashes = root_record.get("eos_leaf_result_sha256") if isinstance(root_record, dict) else None
        if not isinstance(root_record, dict) or not (
            root_record.get("schema_version") == "1.0.0"
            and root_record.get("root_chunk_index") == root_index
            and root_record.get("root_attempt_id") == expected_root_attempt
            and isinstance(root_attempt_ids, list)
            and root_attempt_ids
            and isinstance(root_result_hashes, list)
            and len(root_attempt_ids) == len(root_result_hashes)
        ):
            raise EvaluationError("ASR root index evidence is invalid")
        for attempt_id, result_hash in zip(root_attempt_ids, root_result_hashes, strict=True):
            if not isinstance(attempt_id, str) or attempt_id in root_by_attempt:
                raise EvaluationError("ASR root index repeats or misstates an EOS leaf")
            root_by_attempt[attempt_id] = {
                "end_sample": end_sample,
                "index": root_index,
                "start_sample": start_sample,
            }
            require_hash(result_hash, label="ASR root result hash")
        promoted_ids_from_roots.extend(root_attempt_ids)
        promoted_hashes_from_roots.extend(root_result_hashes)
    if promoted_ids_from_roots != attempt_ids or promoted_hashes_from_roots != result_hashes:
        raise EvaluationError("ASR root indexes differ from canonical promotion")
    if len(preprocessed_pcm) != expected_input_samples * 2:
        raise EvaluationError("preprocessed input PCM length differs from the source manifest")
    boundary_ranges = [
        (
            round(float(boundary["start_s"]) * sample_rate),
            round(float(boundary["end_s"]) * sample_rate),
        )
        for boundary in boundaries
    ]
    validate_exact_partition(
        boundary_ranges,
        0,
        expected_input_samples,
        label="ASR root chunks",
    )

    leaf_summaries: list[dict[str, object]] = []
    leaf_ranges_by_root: dict[int, list[tuple[int, int]]] = {
        index: [] for index in range(len(boundaries))
    }
    for index, (raw_attempt_id, raw_result_hash) in enumerate(zip(attempt_ids, result_hashes, strict=True)):
        if not isinstance(raw_attempt_id, str) or not ATTEMPT_ID_PATTERN.fullmatch(raw_attempt_id):
            raise EvaluationError(f"invalid promoted attempt ID at index {index}")
        result_hash = require_hash(raw_result_hash, label=f"promoted result {index} hash")
        base_relative = f"primary/attempts/{raw_attempt_id}"
        audio_relative = f"{base_relative}/audio.wav"
        request_relative = f"{base_relative}/request.json"
        runner_relative = f"{base_relative}/runner-record.json"
        raw_relative = f"{base_relative}/backend.raw"
        result_relative = f"{base_relative}/result.json"
        outcome_relative = f"{base_relative}/outcome.json"
        evidence_records = {
            relative: sealed_evidence_file(relative)
            for relative in (
                audio_relative,
                request_relative,
                runner_relative,
                raw_relative,
                result_relative,
                outcome_relative,
            )
        }
        request = load_json(source_run / request_relative)
        outcome = load_json(source_run / outcome_relative)
        expected_request_glossary = {**manifest["glossary"], "applied": False}
        root = root_by_attempt.get(raw_attempt_id)
        if not isinstance(request, dict) or not (
            request.get("attempt_id") == raw_attempt_id
            and request.get("audio_path") == audio_relative
            and request.get("backend") == "vibevoice"
            and request.get("model") == EXPECTED_MODELS[0]
            and request.get("language") == "auto"
            and request.get("glossary") == expected_request_glossary
            and root is not None
            and request.get("root_chunk_index") == root["index"]
            and request.get("sample_rate_hz") == sample_rate
            and isinstance(request.get("start_sample"), int)
            and not isinstance(request.get("start_sample"), bool)
            and isinstance(request.get("end_sample"), int)
            and not isinstance(request.get("end_sample"), bool)
            and root["start_sample"] <= request["start_sample"] < request["end_sample"] <= root["end_sample"]
        ):
            raise EvaluationError(f"ASR leaf {raw_attempt_id} has invalid request provenance")
        leaf_ranges_by_root[int(root["index"])].append(
            (request["start_sample"], request["end_sample"])
        )
        if not isinstance(outcome, dict) or not (
            outcome.get("attempt_id") == raw_attempt_id
            and outcome.get("status") == "eos_complete"
            and outcome.get("stop_reason") == "endOfSequence"
            and outcome.get("child_attempt_ids") == []
            and outcome.get("error_code") is None
            and outcome.get("error_message") is None
        ):
            raise EvaluationError(f"ASR leaf {raw_attempt_id} is not a closed EOS result")
        if outcome.get("runner_record_path") != runner_relative:
            raise EvaluationError(f"ASR leaf {raw_attempt_id} runner-record path is not canonical")
        if outcome.get("backend_raw_path") != raw_relative:
            raise EvaluationError(f"ASR leaf {raw_attempt_id} backend evidence path is not canonical")
        if outcome.get("result_path") != result_relative:
            raise EvaluationError(f"ASR leaf {raw_attempt_id} result path is not canonical")
        runner_hash = require_hash(outcome.get("runner_record_sha256"), label="runner-record hash")
        raw_hash = require_hash(outcome.get("backend_raw_sha256"), label="backend evidence hash")
        outcome_result_hash = require_hash(outcome.get("result_sha256"), label="ASR result hash")
        runner_path = source_run / runner_relative
        result_path = source_run / result_relative
        if (
            evidence_records[runner_relative]["sha256"] != runner_hash
            or evidence_records[raw_relative]["sha256"] != raw_hash
            or evidence_records[result_relative]["sha256"] != outcome_result_hash
            or evidence_records[request_relative]["sha256"] != outcome.get("request_sha256")
        ):
            raise EvaluationError(f"ASR leaf {raw_attempt_id} evidence hash mismatch")
        if outcome_result_hash != result_hash:
            raise EvaluationError(f"ASR leaf {raw_attempt_id} differs from the promotion result seal")
        runner = load_json(runner_path)
        runner_glossary = runner.get("glossary") if isinstance(runner, dict) else None
        request_audio_hash = request.get("audio_sha256")
        if request_audio_hash != evidence_records[audio_relative]["sha256"]:
            raise EvaluationError(f"ASR leaf {raw_attempt_id} request audio hash differs from audio.wav")
        leaf_pcm = canonical_pcm16_mono_samples(
            source_run / audio_relative,
            expected_frame_count=request["end_sample"] - request["start_sample"],
            label=f"ASR leaf {raw_attempt_id} audio",
            source_format="pcm16",
        )
        if leaf_pcm != preprocessed_pcm[request["start_sample"] * 2 : request["end_sample"] * 2]:
            raise EvaluationError(f"ASR leaf {raw_attempt_id} audio differs from its preprocessed-input range")
        if not isinstance(runner, dict) or not (
            runner.get("backend") == "vibevoice"
            and runner.get("model") == EXPECTED_MODELS[0]
            and runner.get("outcome") == "complete"
            and runner.get("stop_reason") == "endOfSequence"
            and runner.get("terminal_evidence") == "observed"
            and runner.get("coverage", {}).get("truncated") is False
            and runner.get("coverage", {}).get("processed_duration_s")
            == runner.get("coverage", {}).get("input_duration_s")
            and runner.get("input", {}).get("sha256_before")
            == runner.get("input", {}).get("sha256_after")
            == request_audio_hash
        ):
            raise EvaluationError(f"ASR leaf {raw_attempt_id} lacks complete terminal or input evidence")
        if not isinstance(runner_glossary, dict) or not (
            runner_glossary.get("provided") is True
            and runner_glossary.get("applied") is True
            and runner_glossary.get("sha256") == manifest["glossary"]["sha256"]
            and runner_glossary.get("item_count") == manifest["glossary"]["item_count"]
            and runner_glossary.get("injection_mode") == manifest["glossary"]["injection_mode"]
            and runner_glossary.get("canonical_payload_sha256")
            == manifest["glossary"]["sha256"]
            and require_hash(
                runner_glossary.get("payload_sha256"),
                label="runner glossary payload hash",
            )
            == expected_glossary_payload_sha256
            == require_hash(
                runner_glossary.get("instruction_sha256"),
                label="runner glossary instruction hash",
            )
            and runner_glossary.get("payload_sha256") == outcome.get("glossary_payload_sha256")
            and runner_glossary.get("payload_entry_count") == outcome.get("glossary_payload_entry_count")
            and runner_glossary.get("payload_entry_count")
            == manifest["glossary"]["item_count"]
            and outcome.get("glossary_payload_entry_count")
            == manifest["glossary"]["item_count"]
        ):
            raise EvaluationError(f"ASR leaf {raw_attempt_id} lacks exact glossary application evidence")
        expected_runner_language = {
            "requested": "auto",
            "instruction_sha256": runner_glossary["instruction_sha256"],
            "prompt_guidance_applied": False,
        }
        expected_outcome_language = {
            "requested": "auto",
            "instructionSHA256": runner_glossary["instruction_sha256"],
            "promptGuidanceApplied": False,
        }
        if (
            runner.get("language") != expected_runner_language
            or outcome.get("language") != expected_outcome_language
        ):
            raise EvaluationError(f"ASR leaf {raw_attempt_id} lacks exact auto-language evidence")
        if outcome.get("glossary") != manifest["glossary"]:
            raise EvaluationError(f"ASR leaf {raw_attempt_id} outcome glossary differs from the manifest")
        leaf_summaries.append(
            {
                "attempt_id": raw_attempt_id,
                "audio_sha256": request_audio_hash,
                "result_sha256": result_hash,
                "runner_record_sha256": runner_hash,
            }
        )
    for root_index, ranges in leaf_ranges_by_root.items():
        root_start, root_end = root_ranges_by_index[root_index]
        validate_exact_partition(
            ranges,
            root_start,
            root_end,
            label="promoted EOS leaves",
        )
    return {
        "asr_model": EXPECTED_MODELS[0],
        "complete_nontruncated": True,
        "evidence_sha256": canonical_sha256(leaf_summaries),
        "glossary_applied": True,
        "input_unchanged": True,
        "leaf_count": len(leaf_summaries),
        "terminal_evidence": "observed",
    }


def scorer_hashes() -> dict[str, str]:
    return {name: sha256_file(REPOSITORY_ROOT / name) for name in SCORER_FILES}


def repository_revision() -> str:
    completed = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=REPOSITORY_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    revision = completed.stdout.strip()
    if completed.returncode != 0 or re.fullmatch(r"[0-9a-f]{40}", revision) is None:
        raise EvaluationError("scorer repository revision is unavailable")
    return revision


def score_command(
    fixture_root: Path,
    source_run: Path,
    kind: str,
    output: Path,
    hypothesis_rttm: Path | None = None,
) -> list[str]:
    command = [
        sys.executable,
        str(SCORING_ROOT / "score.py"),
        "--reference",
        str(fixture_root / "reference.segments.json"),
        "--hypothesis",
        str(source_run / "merged/segments.json"),
        "--terms",
        str(fixture_root / "terms.json"),
        "--output",
        str(output),
    ]
    if kind == "acceptance-full":
        if hypothesis_rttm is None:
            raise EvaluationError("acceptance-full scoring requires a derived hypothesis RTTM")
        command.extend(
            [
                "--reference-rttm",
                str(fixture_root / "reference.rttm"),
                "--hypothesis-rttm",
                str(hypothesis_rttm),
            ]
        )
    return command


def run_scorer(
    fixture_root: Path,
    source_run: Path,
    kind: str,
    output: Path,
    hypothesis_rttm: Path | None = None,
) -> None:
    completed = subprocess.run(
        score_command(fixture_root, source_run, kind, output, hypothesis_rttm),
        cwd=REPOSITORY_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        raise EvaluationError(
            f"acceptance scorer failed with exit status {completed.returncode}"
        )
    load_json(output)
    validate_scores(output, kind=kind)


def rttm_file_ids(path: Path) -> set[str]:
    identifiers: set[str] = set()
    for index, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        fields = line.split()
        if len(fields) != 10 or fields[0] != "SPEAKER":
            raise EvaluationError(f"invalid RTTM line {index}: {path.name}")
        identifiers.add(fields[1])
    if not identifiers:
        raise EvaluationError(f"RTTM is empty: {path.name}")
    return identifiers


def write_hypothesis_rttm(source_run: Path, output: Path, reference_rttm: Path) -> None:
    identifiers = rttm_file_ids(reference_rttm)
    if identifiers != {"IN1009"}:
        raise EvaluationError(f"AMI reference RTTM has unexpected file IDs: {sorted(identifiers)}")
    timeline = load_json(source_run / "diarization/timeline.json")
    if not isinstance(timeline, list) or not timeline:
        raise EvaluationError("AMI source timeline is empty")
    lines: list[str] = []
    for index, turn in enumerate(timeline):
        if not isinstance(turn, dict):
            raise EvaluationError(f"timeline entry {index} is not an object")
        start = float(turn["start_s"])
        duration = float(turn["end_s"]) - start
        speaker = str(turn["speaker"])
        if duration <= 0 or not speaker or any(character.isspace() for character in speaker):
            raise EvaluationError(f"timeline entry {index} cannot be represented as RTTM")
        lines.append(
            f"SPEAKER IN1009 1 {start:.6f} {duration:.6f} <NA> <NA> {speaker} <NA> <NA>\n"
        )
    with output.open("x", encoding="utf-8") as stream:
        stream.writelines(lines)
    if rttm_file_ids(output) != identifiers:
        raise EvaluationError("derived hypothesis RTTM file IDs differ from the reference")


def build_envelope(
    *,
    evaluation_id: str,
    fixture_id: str,
    kind: str,
    fixture: dict[str, object],
    source_manifest: dict[str, Any],
    source_files: dict[str, dict[str, object]],
    scores_hash: str,
    fixture_root: Path,
    source_run: Path,
    hypothesis_rttm: Path | None,
) -> dict[str, object]:
    models = source_manifest["models"]
    runner_evidence = validate_runner_evidence(
        source_run,
        source_manifest,
        vibevoice_glossary_payload_sha256(fixture_root / "glossary.txt"),
        trusted_input_frame_count=int(fixture["input_frame_count"]),
    )
    scorer_files = scorer_hashes()
    scored_inputs: dict[str, str] = {
        "hypothesis_segments_sha256": sha256_file(source_run / "merged/segments.json"),
        "reference_segments_sha256": sha256_file(fixture_root / "reference.segments.json"),
        "terms_sha256": sha256_file(fixture_root / "terms.json"),
    }
    rttm: dict[str, object] | None = None
    if kind == "acceptance-full":
        if hypothesis_rttm is None:
            raise EvaluationError("acceptance-full envelope has no hypothesis RTTM")
        rttm = {
            "hypothesis_path": "hypothesis.rttm",
            "hypothesis_sha256": sha256_file(hypothesis_rttm),
            "reference_sha256": sha256_file(fixture_root / "reference.rttm"),
        }
        scored_inputs.update(
            {
                "hypothesis_rttm_sha256": rttm["hypothesis_sha256"],
                "reference_rttm_sha256": rttm["reference_sha256"],
            }
        )
    return {
        "schema_version": "1.0.0",
        "evaluation_id": evaluation_id,
        "fixture_id": fixture_id,
        "kind": kind,
        "fixture": fixture,
        "source_run": {
            "backend": source_manifest["backend"],
            "files": source_files,
            "manifest_sha256": source_files["manifest.json"]["sha256"],
            "run_id": source_manifest["run_id"],
            "tree_sha256": canonical_sha256(source_files),
        },
        "models": {
            "identities": models,
            "identity_sha256": canonical_sha256(models),
        },
        "glossary": source_manifest["glossary"],
        "inputs": scored_inputs,
        "rttm": rttm,
        "scorer": {
            "files": scorer_files,
            "git_revision": repository_revision(),
            "invocation": "score.py with the sealed fixture reference, terms, and merged hypothesis",
            "source_revision_sha256": canonical_sha256(scorer_files),
        },
        "result": {"path": "scores.json", "sha256": scores_hash},
        "runner_evidence": runner_evidence,
        "structural_verdict": {"passed": True},
    }


def create_evaluation(
    *,
    evaluation_id: str,
    fixture_id: str,
    kind: str,
    fixture_root: Path,
    input_path: Path,
    source_run: Path,
    output: Path,
) -> dict[str, object]:
    expected_kind = FIXTURE_KINDS.get(fixture_id)
    if expected_kind != kind:
        raise EvaluationError(f"{fixture_id} requires {expected_kind}, not {kind}")
    if not EVALUATION_ID_PATTERN.fullmatch(evaluation_id):
        raise EvaluationError("evaluation ID must match the manifest-safe 1-128 character form")
    if output.name != evaluation_id:
        raise EvaluationError("evaluation output directory name must equal the evaluation ID")
    for label, path in (("fixture root", fixture_root), ("input", input_path), ("source run", source_run)):
        if path.is_symlink():
            raise EvaluationError(f"{label} path is a symlink")
    fixture_root = fixture_root.resolve(strict=True)
    input_path = input_path.resolve(strict=True)
    source_run = source_run.resolve(strict=True)
    reject_symlink_components(output.parent, label="evaluation output parent")
    output_canonical = output.resolve(strict=False)
    if output_canonical.is_relative_to(source_run):
        raise EvaluationError("evaluation output must be outside the immutable source run")
    if output_canonical.is_relative_to(fixture_root):
        raise EvaluationError("evaluation output must be outside the immutable prepared fixture")
    fixture = validate_fixture(fixture_root, fixture_id, input_path)
    glossary_path = fixture_root / "glossary.txt"
    source_manifest, source_before = validate_source_run(source_run, input_path, glossary_path, kind)
    if source_manifest["glossary"]["item_count"] != fixture["term_count"]:
        raise EvaluationError("source run glossary item count differs from the fixture")

    reject_symlink_components(output.parent, label="evaluation output parent")
    output.parent.mkdir(parents=True, exist_ok=True)
    reject_symlink_components(output.parent, label="evaluation output parent")
    if (output.parent.resolve(strict=True) / output.name) != output_canonical:
        raise EvaluationError("evaluation output path changed during preflight")
    if output.exists() or output.is_symlink():
        raise FileExistsError("create-only evaluation output already exists")
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    output_parent_fd = os.open(output.parent, directory_flags)
    staging_parent_name = f".acceptance-staging-{secrets.token_hex(16)}"
    try:
        os.mkdir(staging_parent_name, mode=0o700, dir_fd=output_parent_fd)
        staging_parent_fd = os.open(
            staging_parent_name,
            directory_flags,
            dir_fd=output_parent_fd,
        )
    except BaseException:
        os.close(output_parent_fd)
        raise
    try:
        os.mkdir(evaluation_id, mode=0o700, dir_fd=staging_parent_fd)
    except BaseException:
        os.close(staging_parent_fd)
        os.close(output_parent_fd)
        raise
    staging_parent_path = directory_path_from_fd(staging_parent_fd)
    staging = staging_parent_path / evaluation_id
    scores_path = staging / "scores.json"
    try:
        hypothesis_rttm = None
        if kind == "acceptance-full":
            hypothesis_rttm = staging / "hypothesis.rttm"
            write_hypothesis_rttm(
                source_run,
                hypothesis_rttm,
                fixture_root / "reference.rttm",
            )
        run_scorer(fixture_root, source_run, kind, scores_path, hypothesis_rttm)
        source_after = snapshot_source_run_envelope(source_run)
        if source_after != source_before:
            raise EvaluationError("scoring changed the source run")
        envelope = build_envelope(
            evaluation_id=evaluation_id,
            fixture_id=fixture_id,
            kind=kind,
            fixture=fixture,
            source_manifest=source_manifest,
            source_files=source_before,
            scores_hash=sha256_file(scores_path),
            fixture_root=fixture_root,
            source_run=source_run,
            hypothesis_rttm=hypothesis_rttm,
        )
        write_json_create(staging / "evaluation.json", envelope)
        verified = verify_evaluation(
            evaluation=staging,
            fixture_root=fixture_root,
            input_path=input_path,
            source_run=source_run,
        )
        if snapshot_source_run_envelope(source_run) != source_before:
            raise EvaluationError("prepublication verification changed the immutable source run")
        if output.parent.resolve(strict=True) != output_canonical.parent:
            raise EvaluationError("evaluation output parent ancestry changed before publication")
        publish_directory_exclusive(
            staging_name=evaluation_id,
            destination_name=output.name,
            destination_parent=output.parent,
            staging_parent_fd=staging_parent_fd,
            destination_parent_fd=output_parent_fd,
        )
        try:
            os.rmdir(staging_parent_name, dir_fd=output_parent_fd)
        except OSError:
            pass
    except BaseException:
        # Preserve an unpublished staging directory as failure evidence.
        raise
    finally:
        try:
            os.close(staging_parent_fd)
        except OSError:
            pass
        try:
            os.close(output_parent_fd)
        except OSError:
            pass
    return verified


def verify_evaluation(
    *,
    evaluation: Path,
    fixture_root: Path,
    input_path: Path,
    source_run: Path,
) -> dict[str, object]:
    if evaluation.is_symlink():
        raise EvaluationError("evaluation path is a symlink")
    evaluation = evaluation.resolve(strict=True)
    for label, path in (("fixture root", fixture_root), ("input", input_path), ("source run", source_run)):
        if path.is_symlink():
            raise EvaluationError(f"{label} path is a symlink")
    fixture_root = fixture_root.resolve(strict=True)
    input_path = input_path.resolve(strict=True)
    source_run = source_run.resolve(strict=True)
    if evaluation.is_symlink() or not evaluation.is_dir():
        raise EvaluationError("evaluation is not a regular directory")
    expected_names = ["evaluation.json", "scores.json"]
    envelope = load_json(evaluation / "evaluation.json")
    if not isinstance(envelope, dict) or envelope.get("schema_version") != "1.0.0":
        raise EvaluationError("invalid acceptance evaluation envelope")
    evaluation_id = envelope.get("evaluation_id")
    if not isinstance(evaluation_id, str) or not EVALUATION_ID_PATTERN.fullmatch(evaluation_id):
        raise EvaluationError("evaluation envelope has an unsafe evaluation ID")
    if evaluation.name != evaluation_id:
        raise EvaluationError("evaluation directory name differs from its sealed evaluation ID")
    fixture_id = envelope.get("fixture_id")
    kind = envelope.get("kind")
    if not isinstance(fixture_id, str) or FIXTURE_KINDS.get(fixture_id) != kind:
        raise EvaluationError("evaluation fixture and kind mapping is invalid")
    if kind == "acceptance-full":
        expected_names.append("hypothesis.rttm")
    if sorted(path.name for path in evaluation.iterdir()) != sorted(expected_names):
        raise EvaluationError(f"evaluation directory has an unexpected file set: {expected_names}")
    for name in expected_names:
        file_record(evaluation / name)

    actual_fixture = validate_fixture(fixture_root, fixture_id, input_path)
    if envelope.get("fixture") != actual_fixture:
        raise EvaluationError("evaluation fixture hash record mismatch")
    source_manifest, source_files = validate_source_run(
        source_run,
        input_path,
        fixture_root / "glossary.txt",
        kind,
    )
    if source_manifest["glossary"]["item_count"] != actual_fixture["term_count"]:
        raise EvaluationError("source run glossary item count differs from the fixture")
    source_record = envelope.get("source_run")
    expected_source = {
        "backend": source_manifest["backend"],
        "files": source_files,
        "manifest_sha256": source_files["manifest.json"]["sha256"],
        "run_id": source_manifest["run_id"],
        "tree_sha256": canonical_sha256(source_files),
    }
    if source_record != expected_source:
        raise EvaluationError("evaluation source-run hash record mismatch")

    models = source_manifest["models"]
    if envelope.get("models") != {
        "identities": models,
        "identity_sha256": canonical_sha256(models),
    }:
        raise EvaluationError("evaluation model identity hash mismatch")
    if envelope.get("runner_evidence") != validate_runner_evidence(
        source_run,
        source_manifest,
        vibevoice_glossary_payload_sha256(fixture_root / "glossary.txt"),
        trusted_input_frame_count=int(actual_fixture["input_frame_count"]),
    ):
        raise EvaluationError("evaluation runner-evidence summary mismatch")
    if envelope.get("glossary") != source_manifest["glossary"]:
        raise EvaluationError("evaluation glossary record mismatch")

    expected_rttm = None
    if kind == "acceptance-full":
        hypothesis_path = evaluation / "hypothesis.rttm"
        if rttm_file_ids(hypothesis_path) != rttm_file_ids(fixture_root / "reference.rttm"):
            raise EvaluationError("evaluation RTTM file IDs differ")
        expected_rttm = {
            "hypothesis_path": "hypothesis.rttm",
            "hypothesis_sha256": sha256_file(hypothesis_path),
            "reference_sha256": sha256_file(fixture_root / "reference.rttm"),
        }
    if envelope.get("rttm") != expected_rttm:
        raise EvaluationError("evaluation RTTM hash mismatch")
    expected_inputs = {
        "hypothesis_segments_sha256": sha256_file(source_run / "merged/segments.json"),
        "reference_segments_sha256": sha256_file(fixture_root / "reference.segments.json"),
        "terms_sha256": sha256_file(fixture_root / "terms.json"),
    }
    if kind == "acceptance-full":
        expected_inputs.update(
            {
                "hypothesis_rttm_sha256": expected_rttm["hypothesis_sha256"],
                "reference_rttm_sha256": expected_rttm["reference_sha256"],
            }
        )
    if envelope.get("inputs") != expected_inputs:
        raise EvaluationError("evaluation scored-input hash record mismatch")
    scorer = envelope.get("scorer")
    actual_scorer_files = scorer_hashes()
    if not isinstance(scorer, dict) or scorer.get("files") != actual_scorer_files:
        raise EvaluationError("evaluation scorer hash mismatch")
    if scorer.get("git_revision") != repository_revision():
        raise EvaluationError("evaluation scorer Git revision mismatch")
    if scorer.get("source_revision_sha256") != canonical_sha256(actual_scorer_files):
        raise EvaluationError("evaluation scorer source revision hash mismatch")

    result = envelope.get("result")
    scores_path = evaluation / "scores.json"
    if result != {"path": "scores.json", "sha256": sha256_file(scores_path)}:
        raise EvaluationError("evaluation result hash mismatch")
    if envelope.get("structural_verdict") != {"passed": True}:
        raise EvaluationError("evaluation structural verdict is not passed")
    load_json(scores_path)
    validate_scores(scores_path, kind=kind)
    with tempfile.TemporaryDirectory(prefix="maccheroni-acceptance-verify-") as temporary:
        replay = Path(temporary) / "scores.json"
        replay_rttm = None
        if kind == "acceptance-full":
            replay_rttm = Path(temporary) / "hypothesis.rttm"
            write_hypothesis_rttm(
                source_run,
                replay_rttm,
                fixture_root / "reference.rttm",
            )
            if replay_rttm.read_bytes() != (evaluation / "hypothesis.rttm").read_bytes():
                raise EvaluationError("hypothesis RTTM is not reproducible from the sealed timeline")
        run_scorer(fixture_root, source_run, kind, replay, replay_rttm)
        if replay.read_bytes() != scores_path.read_bytes():
            raise EvaluationError("evaluation result is not reproducible from sealed inputs")
    if snapshot_source_run_envelope(source_run) != source_files:
        raise EvaluationError("verification changed the source run")
    expected_envelope = build_envelope(
        evaluation_id=evaluation_id,
        fixture_id=fixture_id,
        kind=kind,
        fixture=actual_fixture,
        source_manifest=source_manifest,
        source_files=source_files,
        scores_hash=sha256_file(scores_path),
        fixture_root=fixture_root,
        source_run=source_run,
        hypothesis_rttm=(evaluation / "hypothesis.rttm") if kind == "acceptance-full" else None,
    )
    if envelope != expected_envelope:
        raise EvaluationError("evaluation envelope differs from the exact reconstructed contract")
    return envelope


def parse_arguments(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    preflight = subparsers.add_parser("preflight")
    preflight.add_argument("--fixture-id", required=True, choices=tuple(FIXTURE_KINDS))
    preflight.add_argument("--kind", required=True, choices=tuple(FIXTURE_KINDS.values()))
    preflight.add_argument("--fixture-root", required=True, type=Path)
    preflight.add_argument("--input", required=True, type=Path)
    memory_check = subparsers.add_parser("memory-check")
    memory_check.add_argument("--bytes", required=True, type=int)
    for command in ("create", "verify"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("--fixture-root", required=True, type=Path)
        subparser.add_argument("--input", required=True, type=Path)
        subparser.add_argument("--source-run", required=True, type=Path)
        subparser.add_argument("--output", required=True, type=Path)
        if command == "create":
            subparser.add_argument("--evaluation-id", required=True)
            subparser.add_argument("--fixture-id", required=True, choices=tuple(FIXTURE_KINDS))
            subparser.add_argument("--kind", required=True, choices=tuple(FIXTURE_KINDS.values()))
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    if os.environ.get("MACCHERONI_ACCEPTANCE_TESTING") or os.environ.get(
        "MACCHERONI_ACCEPTANCE_TEST_PACK_MANIFEST"
    ):
        print("FAIL: acceptance evaluation rejected [test-mode-environment]", file=sys.stderr)
        return 1
    arguments = parse_arguments(argv or sys.argv[1:])
    try:
        if arguments.command == "memory-check":
            if not acceptance_memory_supported(arguments.bytes):
                raise EvaluationError("benchmark model-run memory stop condition is not met")
            print(
                json.dumps(
                    {
                        "minimum_bytes": MINIMUM_ACCEPTANCE_MEMORY_BYTES,
                        "observed_bytes": arguments.bytes,
                        "passed": True,
                    },
                    sort_keys=True,
                )
            )
            return 0
        if arguments.command == "preflight":
            if FIXTURE_KINDS[arguments.fixture_id] != arguments.kind:
                raise EvaluationError(
                    f"{arguments.fixture_id} requires {FIXTURE_KINDS[arguments.fixture_id]}, not {arguments.kind}"
                )
            validate_fixture(arguments.fixture_root, arguments.fixture_id, arguments.input)
            print(
                json.dumps(
                    {
                        "fixture_id": arguments.fixture_id,
                        "kind": arguments.kind,
                        "model_started": False,
                        "passed": True,
                    },
                    sort_keys=True,
                )
            )
            return 0
        if arguments.command == "create":
            envelope = create_evaluation(
                evaluation_id=arguments.evaluation_id,
                fixture_id=arguments.fixture_id,
                kind=arguments.kind,
                fixture_root=arguments.fixture_root,
                input_path=arguments.input,
                source_run=arguments.source_run,
                output=arguments.output,
            )
        else:
            envelope = verify_evaluation(
                evaluation=arguments.output,
                fixture_root=arguments.fixture_root,
                input_path=arguments.input,
                source_run=arguments.source_run,
            )
    except (ValueError, FileExistsError, OSError, KeyError, TypeError) as error:
        print(
            f"FAIL: acceptance evaluation rejected [{type(error).__name__}]",
            file=sys.stderr,
        )
        return 1
    print(
        json.dumps(
            {
                "evaluation_id": envelope["evaluation_id"],
                "fixture_id": envelope["fixture_id"],
                "kind": envelope["kind"],
                "passed": True,
                "source_manifest_sha256": envelope["source_run"]["manifest_sha256"],
                "score_sha256": envelope["result"]["sha256"],
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
