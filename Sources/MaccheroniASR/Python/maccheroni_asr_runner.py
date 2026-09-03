#!/usr/bin/env python3
"""Pinned, offline ASR subprocess contract used by MaccheroniASR.

The runner owns a fresh output path supplied by the Swift adapter.  It never
opens the audio input for writing and refuses any missing model, unpinned
revision, malformed backend output, incomplete coverage, or overwrite.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import wave
from dataclasses import dataclass
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path
from typing import Any, Mapping, Sequence


EXPECTED_MLX_AUDIO = "0.4.6"
MAX_VIBEVOICE_DURATION_SECONDS = 59 * 60
TIME_TOLERANCE_SECONDS = 0.01
MOSS_HARNESS_CONTRACT = "moss-harness-v2"
MOSS_HARNESS_FLAGS = ["--configuration", "release", "--arch", "arm64", "--product", "MaccheroniMossHarness"]
MOSS_CONTEXT_HARD_CAP = 131_072
MOSS_SAMPLE_RATE = 16_000
MOSS_ENCODER_CHUNK_SAMPLES = 480_000
MOSS_ENCODER_STRIDE_SAMPLES = 1_280
MOSS_DEFAULT_INSTRUCTION = (
    "请将音频转写为文本，每一段需以起始时间戳和说话人编号"
    "（[S01]、[S02]、[S03]…）开头，正文为对应的语音内容，"
    "并在段末标注结束时间戳，以清晰标明该段语音范围。"
)

# Repetition-looping detection for the VibeVoice path.  A collapsed
# decoder stops producing new content and repeats one token or short phrase
# until the output cap, so the signal is the length of the longest run of
# consecutive identical units rather than the generated-token count.  The
# threshold carries headroom over the worst run observed inside an accepted
# end-of-sequence transcript; see the VibeVoice section of
# docs/engineering-constraint-policy.md.
VIBEVOICE_REPETITION_RUN_THRESHOLD = 12
# A runaway does not always cycle a single token.  A measured collapse cycled a
# five-unit phrase 333 times, which a four-unit window scores as 2 and misses
# entirely.  Eight is the widest window validated against every accepted
# payload: across 16 accepted and 13 collapsed payloads the worst run inside an
# accepted transcript is 6 at any width up to 8, and the smallest run inside a
# collapsed one is 339.
VIBEVOICE_REPETITION_PHRASE_UNITS = 8
VIBEVOICE_REPETITION_UNIT = re.compile(r"[^\s,.!?;:~…·。，、！？]+")


@dataclass(frozen=True)
class ModelSpec:
    backend: str
    hf_model_id: str
    revision: str
    quantization: str
    injection_mode: str


@dataclass(frozen=True)
class HFFilePin:
    size: int
    sha256: str
    blob_id: str


MODELS = {
    "vibevoice": ModelSpec(
        backend="vibevoice",
        hf_model_id="mlx-community/VibeVoice-ASR-8bit",
        revision="725c72e54d6ef875472c27fbc50fab470a960940",
        quantization="int8",
        injection_mode="free_text_context",
    ),
    "qwen3": ModelSpec(
        backend="qwen3",
        hf_model_id="aufklarer/Qwen3-ASR-1.7B-MLX-8bit",
        revision="e5450a26d1fd417c45fc9c405651ddc3180a27a6",
        quantization="int8",
        injection_mode="free_text_context",
    ),
    "moss": ModelSpec(
        backend="moss",
        hf_model_id="aufklarer/MOSS-Transcribe-Diarize-0.9B-MLX-INT8",
        revision="90aa65287111a327db98eb83e325bd5332945edd",
        quantization="int8-decoder+fp16-audio-vq-kv",
        injection_mode="hotword_instruction",
    ),
}

VIBEVOICE_TOKENIZER = ModelSpec(
    backend="tokenizer",
    hf_model_id="Qwen/Qwen2.5-7B",
    revision="d149729398750b98c0af14eb82c78cfe92750796",
    quantization="tokenizer-only",
    injection_mode="none",
)
VIBEVOICE_MODEL_FILES = (
    "config.json",
    "model.safetensors.index.json",
    "model-00001-of-00002.safetensors",
    "model-00002-of-00002.safetensors",
)
VIBEVOICE_MODEL_PINS = {
    "config.json": HFFilePin(
        4_372, "f4418d57174253f52174c74d6dc3b53ae452d8234b2e007231bea53f2437f16a",
        "8c1f7894ad6bbeef87088fbd161599d08cba9603",
    ),
    "model.safetensors.index.json": HFFilePin(
        130_385, "8f282316181bcbd6bb4d7d57ce3e3c5601de35d9003b6bfe1da3a0a22a814a55",
        "ebaa64b12e781344315901a56d64a3029a6626ac",
    ),
    "model-00001-of-00002.safetensors": HFFilePin(
        5_331_193_271, "ce6e064d50295cb0100f33af8c69c9d2a3d647a8d375f764851e940180308650",
        "bce75647675c562e2d8114d6a416336203c3cf00",
    ),
    "model-00002-of-00002.safetensors": HFFilePin(
        4_190_296_379, "53750f68f0fca138e70d8ed5eb38c29a02e3b44c3e530142a7b0cb3453bf455a",
        "6d47b73e4817fb0b0870286e45c876399dadc32e",
    ),
}
VIBEVOICE_TOKENIZER_FILES = (
    "config.json",
    "tokenizer.json",
    "tokenizer_config.json",
    "merges.txt",
    "vocab.json",
)
VIBEVOICE_TOKENIZER_PINS = {
    "config.json": HFFilePin(
        686, "267ce68584c5f24c3b267d934db2de68dd21d1ca677fb78ed809eb60067f7642",
        "1a90713f0e2cf13b8320cd576175ff9f0b587ea4",
    ),
    "tokenizer.json": HFFilePin(
        7_031_645, "c0382117ea329cdf097041132f6d735924b697924d6f6fc3945713e96ce87539",
        "443909a61d429dff23010e5bddd28ff530edda00",
    ),
    "tokenizer_config.json": HFFilePin(
        7_228, "c91efca15ceff6e9ee9424db58a6f59cd41294e550a86cbd07e3c1fb500b34f9",
        "ba7e4c5637b9732dadcd66286ce48334e8b31e9e",
    ),
    "merges.txt": HFFilePin(
        1_671_839, "599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3",
        "20024bfe7c83998e9aeaf98a0cd6a2ce6306c2f0",
    ),
    "vocab.json": HFFilePin(
        2_776_833, "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910",
        "4783fe10ac3adce15ac8f358ef5462739852c569",
    ),
}


class RunnerError(RuntimeError):
    def __init__(self, code: str, message: str):
        self.code = code
        super().__init__(message)


def safe_exception_class(error: BaseException) -> str:
    """Return only a bounded Python identifier for structured diagnostics."""
    candidate = type(error).__name__
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]{0,63}", candidate):
        return candidate
    return "Exception"


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def output_is_present(path: Path) -> bool:
    return path.exists() or path.is_symlink()


def is_sha256(value: Any) -> bool:
    return isinstance(value, str) and len(value) == 64 and all(character in "0123456789abcdef" for character in value)


def moss_harness_paths(cache_root: Path) -> tuple[Path, Path, Path]:
    root = cache_root / "swift-scratch" / "moss-harness" / "arm64-apple-macosx" / "release"
    binary = root / "MaccheroniMossHarness"
    return binary, root / "mlx.metallib", Path(str(binary) + ".fingerprint.json")


def verify_moss_harness_fingerprint(cache_root: Path) -> dict[str, Any]:
    binary, metallib, sidecar = moss_harness_paths(cache_root)
    if binary.is_symlink() or not binary.is_file() or not os.access(binary, os.X_OK):
        raise RunnerError("harness_missing", f"pinned MOSS release harness is missing: {binary}")
    if metallib.is_symlink() or not metallib.is_file():
        raise RunnerError("harness_missing", f"MOSS harness metallib is missing: {metallib}")
    if sidecar.is_symlink() or not sidecar.is_file():
        raise RunnerError("harness_fingerprint_missing", f"MOSS harness fingerprint is missing: {sidecar}")
    try:
        raw = sidecar.read_bytes()
    except OSError as error:
        raise RunnerError("harness_fingerprint_missing", f"MOSS harness fingerprint is missing: {sidecar}") from error
    try:
        found = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RunnerError("harness_fingerprint_malformed", f"MOSS harness fingerprint is malformed: {sidecar}") from error
    required_hashes = ("source_tree_sha256", "package_swift_sha256", "package_resolved_sha256", "swift_version_sha256", "executable_sha256", "metallib_sha256")
    if not isinstance(found, dict) or found.get("contract_version") != MOSS_HARNESS_CONTRACT or found.get("target_architecture") != "arm64" or found.get("configuration") != "release" or found.get("build_flags") != MOSS_HARNESS_FLAGS or not isinstance(found.get("swift_version"), str) or sha256_bytes(found["swift_version"].encode("utf-8")) != found.get("swift_version_sha256") or any(not is_sha256(found.get(key)) for key in required_hashes):
        raise RunnerError("harness_fingerprint_malformed", "MOSS harness fingerprint lacks the required v2 release evidence")
    if sha256_file(binary) != found["executable_sha256"] or sha256_file(metallib) != found["metallib_sha256"]:
        raise RunnerError("harness_fingerprint_stale", "MOSS harness binary or metallib no longer matches its fingerprint")
    return {"path": str(sidecar), "sha256": sha256_bytes(raw), **found}


def read_audio_duration(path: Path) -> float:
    if not path.is_file() or path.stat().st_size == 0:
        raise RunnerError("audio_missing", f"audio input is missing or empty: {path}")
    try:
        with wave.open(str(path), "rb") as audio:
            frames = audio.getnframes()
            sample_rate = audio.getframerate()
            if frames <= 0 or sample_rate <= 0:
                raise RunnerError("audio_invalid", f"audio contains no playable frames: {path}")
            return frames / sample_rate
    except RunnerError:
        raise
    except (OSError, EOFError, wave.Error) as error:
        raise RunnerError("audio_invalid", f"ASR input must be a valid WAV chunk: {path}") from error


def assert_pinned(spec: ModelSpec) -> None:
    if len(spec.revision) != 40 or any(character not in "0123456789abcdef" for character in spec.revision):
        raise RunnerError("model_unpinned", f"model revision is not a 40-character SHA: {spec.revision}")
    if not spec.hf_model_id or not spec.quantization:
        raise RunnerError("model_unpinned", "model identity is incomplete")


def hf_snapshot(cache_root: Path, spec: ModelSpec) -> Path:
    return cache_root / "models" / "huggingface" / "hub" / (
        "models--" + spec.hf_model_id.replace("/", "--")
    ) / "snapshots" / spec.revision


def hf_repository(cache_root: Path, spec: ModelSpec) -> Path:
    return hf_snapshot(cache_root, spec).parent.parent


def hf_cache_checks(
    cache_root: Path,
    spec: ModelSpec,
    *,
    name_prefix: str,
    required_files: Mapping[str, HFFilePin],
    require_ref: bool = False,
    require_tree: bool = False,
) -> list[dict[str, Any]]:
    repository = hf_repository(cache_root, spec)
    snapshot = hf_snapshot(cache_root, spec)
    reference = repository / "refs" / "main"
    tree = repository / "trees" / f"{spec.revision}.json"
    checks: list[dict[str, Any]] = []

    snapshot_ok = snapshot.is_dir() and not snapshot.is_symlink()
    checks.append({"name": f"{name_prefix}_snapshot", "ok": snapshot_ok, "path": str(snapshot)})

    if require_ref:
        try:
            reference_value = reference.read_bytes()
        except OSError:
            reference_value = None
        reference_ok = (
            reference.is_file()
            and not reference.is_symlink()
            and reference_value == spec.revision.encode("ascii")
        )
        checks.append({
            "name": f"{name_prefix}_ref",
            "ok": reference_ok,
            "path": str(reference),
            "message": None if reference_ok else f"refs/main must equal pinned revision {spec.revision}",
        })

    tree_payload: dict[str, Any] | None = None
    try:
        candidate = json.loads(tree.read_text(encoding="utf-8"))
        if (
            tree.is_file()
            and not tree.is_symlink()
            and isinstance(candidate, dict)
            and candidate.get("format_version") == 1
            and isinstance(candidate.get("files"), dict)
        ):
            tree_payload = candidate
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        pass
    if require_tree:
        checks.append({"name": f"{name_prefix}_tree", "ok": tree_payload is not None, "path": str(tree)})

    files_ok = snapshot_ok
    for relative, pin in required_files.items():
        path = snapshot / relative
        try:
            file_ok = (
                path.is_file()
                and path.stat().st_size == pin.size
                and sha256_file(path) == pin.sha256
            )
        except OSError:
            file_ok = False
        if tree_payload is not None:
            entry = tree_payload["files"].get(relative)
            file_ok = file_ok and isinstance(entry, dict)
            if isinstance(entry, dict):
                file_ok = (
                    file_ok
                    and entry.get("size") == pin.size
                    and entry.get("blob_id") == pin.blob_id
                    and (
                        "lfs_sha256" not in entry
                        or entry.get("lfs_sha256") == pin.sha256
                    )
                )
        elif require_tree:
            file_ok = False
        files_ok = files_ok and file_ok
    checks.append({"name": f"{name_prefix}_files", "ok": files_ok})

    return checks


def assert_vibevoice_closure(cache_root: Path) -> None:
    checks = hf_cache_checks(
        cache_root,
        MODELS["vibevoice"],
        name_prefix="model",
        required_files=VIBEVOICE_MODEL_PINS,
        require_tree=True,
    ) + hf_cache_checks(
        cache_root,
        VIBEVOICE_TOKENIZER,
        name_prefix="tokenizer",
        required_files=VIBEVOICE_TOKENIZER_PINS,
        require_ref=True,
        require_tree=True,
    )
    failed = next((check for check in checks if not check["ok"]), None)
    if failed is not None:
        raise RunnerError("dependency_missing", f"VibeVoice dependency check {failed['name']} failed")
    if not vibevoice_tokenizer_semantics_are_valid(cache_root):
        raise RunnerError(
            "dependency_invalid",
            "VibeVoice tokenizer is missing required offline Qwen control tokens",
        )


def vibevoice_tokenizer_semantics_are_valid(cache_root: Path) -> bool:
    hf_home = cache_root / "models" / "huggingface"
    previous_hf_home = os.environ.get("HF_HOME")
    previous_offline = os.environ.get("HF_HUB_OFFLINE")
    os.environ["HF_HOME"] = str(hf_home)
    os.environ["HF_HUB_OFFLINE"] = "1"
    try:
        from transformers import AutoTokenizer

        tokenizer = AutoTokenizer.from_pretrained(
            VIBEVOICE_TOKENIZER.hf_model_id,
            local_files_only=True,
            trust_remote_code=True,
        )
        return (
            tokenizer.eos_token_id == 151643
            and tokenizer.convert_tokens_to_ids("<|object_ref_start|>") == 151646
            and tokenizer.convert_tokens_to_ids("<|object_ref_end|>") == 151647
            and tokenizer.convert_tokens_to_ids("<|box_start|>") == 151648
        )
    except Exception:
        return False
    finally:
        if previous_hf_home is None:
            os.environ.pop("HF_HOME", None)
        else:
            os.environ["HF_HOME"] = previous_hf_home
        if previous_offline is None:
            os.environ.pop("HF_HUB_OFFLINE", None)
        else:
            os.environ["HF_HUB_OFFLINE"] = previous_offline


def assert_hf_snapshot(cache_root: Path, spec: ModelSpec) -> Path:
    snapshot = hf_snapshot(cache_root, spec)
    if not snapshot.is_dir() or snapshot.is_symlink():
        raise RunnerError("model_missing", f"required pinned snapshot is missing: {snapshot}")
    if spec.backend == "qwen3":
        main_ref = snapshot.parent.parent / "refs" / "main"
        try:
            resolved_revision = main_ref.read_text(encoding="utf-8").strip()
        except OSError as error:
            raise RunnerError("model_unpinned", f"Qwen cache has no refs/main pin: {main_ref}") from error
        if resolved_revision != spec.revision:
            raise RunnerError(
                "model_unpinned",
                f"Qwen refs/main must equal pinned revision {spec.revision}, found {resolved_revision!r}",
            )
    return snapshot


def parse_entries(path: Path | None) -> tuple[list[str], str | None]:
    if path is None:
        return [], None
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise RunnerError("glossary_missing", f"glossary is unreadable: {path}") from error
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise RunnerError("glossary_invalid", "glossary is not UTF-8") from error
    if "\x00" in text:
        raise RunnerError("glossary_invalid", "glossary contains NUL")
    if text.startswith("\ufeff"):
        text = text[1:]
    entries: list[str] = []
    seen: set[str] = set()
    import unicodedata

    for number, line in enumerate(text.splitlines(), start=1):
        entry = unicodedata.normalize("NFC", line.strip())
        if not entry or entry.startswith("#"):
            continue
        if len(entry) > 256 or any(unicodedata.category(char) == "Cc" for char in entry):
            raise RunnerError("glossary_invalid", f"invalid glossary entry at line {number}")
        if entry not in seen:
            seen.add(entry)
            entries.append(entry)
    if not entries:
        raise RunnerError("glossary_invalid", "glossary has no usable entries")
    return entries, sha256_bytes(raw)


def canonical_context(entries: Sequence[str]) -> str:
    return "Preserve these spellings only when supported by the audio. Candidate glossary terms:\n" + "\n".join(entries)


def moss_instruction(entries: Sequence[str]) -> str:
    return (
        "Transcribe the speech faithfully with timestamps and speaker labels when available. "
        "Preserve the transcript strictly according to acoustic evidence. "
        "The following terms are candidate spellings only; emit a term only when the audio supports it: "
        + ", ".join(entries)
        + "."
    )


def moss_harness_instruction(entries: Sequence[str], language: str) -> str:
    instruction = MOSS_DEFAULT_INSTRUCTION + " Preserve the transcript strictly according to acoustic evidence."
    if language != "auto":
        display_names = {
            "de": "German",
            "en": "English",
            "es": "Spanish",
            "fr": "French",
            "it": "Italian",
            "ja": "Japanese",
            "ko": "Korean",
            "pt": "Portuguese",
            "ru": "Russian",
            "zh": "Chinese",
        }
        base_language = language.split("-", 1)[0]
        display_name = display_names.get(
            base_language,
            f"the language identified by BCP-47 tag '{language}'",
        )
        instruction += f" Language: {display_name}."
    if entries:
        instruction += " The following terms are candidate spellings only; emit a term only when the audio supports it: " + ", ".join(entries) + "."
    return instruction


def moss_audio_token_count(sample_count: int) -> int:
    if sample_count <= 0:
        raise RunnerError("request_invalid", "MOSS sample count must be positive")
    full_chunks, remainder = divmod(sample_count, MOSS_ENCODER_CHUNK_SAMPLES)
    tokens = full_chunks * (MOSS_ENCODER_CHUNK_SAMPLES // MOSS_ENCODER_STRIDE_SAMPLES)
    if remainder:
        tokens += (remainder - 1) // MOSS_ENCODER_STRIDE_SAMPLES + 1
    return tokens


def moss_audio_span_token_count(
    audio_tokens: int,
    *,
    audio_tokens_per_second: float,
    time_marker_every_seconds: int,
    enable_time_marker: bool,
) -> int:
    if not enable_time_marker:
        return audio_tokens
    if audio_tokens_per_second <= 0 or time_marker_every_seconds <= 0:
        raise RunnerError("model_unpinned", "MOSS processor token-rate configuration is invalid")
    duration = audio_tokens / audio_tokens_per_second
    marker_digits = sum(
        len(str(seconds))
        for seconds in range(time_marker_every_seconds, int(duration) + 1, time_marker_every_seconds)
    )
    return audio_tokens + marker_digits


def plan_moss_prompt(args: argparse.Namespace) -> dict[str, Any]:
    spec = MODELS["moss"]
    assert_pinned(spec)
    if args.max_tokens <= 0 or args.max_tokens > MOSS_CONTEXT_HARD_CAP:
        raise RunnerError("max_tokens_invalid", f"MOSS max tokens must be within 1...{MOSS_CONTEXT_HARD_CAP}")
    if args.sample_count <= 0:
        raise RunnerError("request_invalid", "MOSS sample count must be positive")
    cache_root = Path(args.cache_root).expanduser().resolve()
    model_dir = cache_root / "models" / f"moss-transcribe-diarize-0.9b-mlx-int8-{spec.revision}"
    metadata = model_dir / ".cache" / "huggingface" / "trees" / f"{spec.revision}.json"
    tokenizer_path = model_dir / "tokenizer.json"
    processor_path = model_dir / "processor_config.json"
    if not metadata.is_file() or not tokenizer_path.is_file() or not processor_path.is_file():
        raise RunnerError("model_unpinned", "MOSS prompt planner requires the pinned tokenizer and processor")
    fingerprint = verify_moss_harness_fingerprint(cache_root)
    entries, _ = parse_entries(Path(args.glossary) if args.glossary else None)
    canonical_glossary_sha = (
        sha256_bytes((("\n".join(entries)) + "\n").encode("utf-8"))
        if entries else None
    )
    if entries:
        if not args.glossary_sha256 or len(args.glossary_sha256) != 64 or any(character not in "0123456789abcdef" for character in args.glossary_sha256):
            raise RunnerError("glossary_invalid", "planner requires the original 64-character glossary SHA-256")
        glossary_sha = args.glossary_sha256
    else:
        if args.glossary_sha256:
            raise RunnerError("glossary_invalid", "absent glossary must not carry an original SHA-256")
        glossary_sha = None
    language = args.language.strip().lower()
    if not language or len(language) > 64 or any(not (character.isalpha() or character == "-") for character in language):
        raise RunnerError("request_invalid", "MOSS language must be auto or a BCP-47 language tag")
    try:
        from tokenizers import Tokenizer

        tokenizer = Tokenizer.from_file(str(tokenizer_path))
        processor = json.loads(processor_path.read_text(encoding="utf-8"))
    except (ImportError, OSError, json.JSONDecodeError, ValueError) as error:
        raise RunnerError("runtime_missing", "MOSS prompt tokenizer is unavailable or invalid") from error
    audio_rate = processor.get("audio_tokens_per_second")
    marker_seconds = processor.get("time_marker_every_seconds")
    markers_enabled = processor.get("enable_time_marker")
    if isinstance(audio_rate, bool) or not isinstance(audio_rate, (int, float)) or not math.isfinite(float(audio_rate)) or isinstance(marker_seconds, bool) or not isinstance(marker_seconds, int) or not isinstance(markers_enabled, bool):
        raise RunnerError("model_unpinned", "MOSS processor token-rate configuration is invalid")
    if float(audio_rate) != 12.5 or marker_seconds != 5 or not markers_enabled:
        raise RunnerError("model_unpinned", "MOSS processor token-rate configuration differs from the pinned contract")
    if tokenizer.token_to_id("<|audio_pad|>") is None or tokenizer.token_to_id("<|im_end|>") is None:
        raise RunnerError("model_unpinned", "MOSS tokenizer is missing required special tokens")
    if any(len(tokenizer.encode(digit, add_special_tokens=False).ids) != 1 for digit in "0123456789"):
        raise RunnerError("model_unpinned", "MOSS tokenizer digits do not match the time-marker contract")
    instruction = moss_harness_instruction(entries, language)
    prefix = "<|im_start|>system\nYou are a helpful assistant.<|im_end|>\n<|im_start|>user\n<|audio_start|>"
    suffix = "<|audio_end|>\n" + instruction + "<|im_end|>\n<|im_start|>assistant\n"
    text_tokens = len(tokenizer.encode(prefix, add_special_tokens=False).ids) + len(tokenizer.encode(suffix, add_special_tokens=False).ids)
    audio_tokens = moss_audio_token_count(args.sample_count)
    audio_span_tokens = moss_audio_span_token_count(
        audio_tokens,
        audio_tokens_per_second=float(audio_rate),
        time_marker_every_seconds=marker_seconds,
        enable_time_marker=markers_enabled,
    )
    prompt_tokens = text_tokens + audio_span_tokens
    context_upper_bound = prompt_tokens + args.max_tokens
    if context_upper_bound > MOSS_CONTEXT_HARD_CAP:
        raise RunnerError(
            "context_preflight",
            f"MOSS prompt plus output budget requires {context_upper_bound} tokens, exceeding {MOSS_CONTEXT_HARD_CAP}",
        )
    return {
        "backend": "moss",
        "model": {"role": "asr", "hf_model_id": spec.hf_model_id, "revision": spec.revision, "quantization": spec.quantization},
        "sample_count": args.sample_count,
        "text_tokens": text_tokens,
        "audio_tokens": audio_tokens,
        "audio_span_tokens": audio_span_tokens,
        "prompt_tokens": prompt_tokens,
        "maximum_tokens": args.max_tokens,
        "context_upper_bound_tokens": context_upper_bound,
        "context_hard_cap_tokens": MOSS_CONTEXT_HARD_CAP,
        "audio_tokens_per_second": float(audio_rate),
        "time_marker_every_seconds": marker_seconds,
        "time_markers_enabled": markers_enabled,
        "language": language,
        "instruction_sha256": sha256_bytes(instruction.encode("utf-8")),
        "glossary_sha256": glossary_sha,
        "glossary_payload_sha256": canonical_glossary_sha,
        "glossary_item_count": len(entries),
        "helper_fingerprint_sha256": fingerprint["sha256"],
    }


def run_process(command: list[str], *, timeout_seconds: float, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            env=env,
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise RunnerError("backend_timeout", f"backend exceeded {timeout_seconds:.1f}s: {command[0]}") from error
    except OSError as error:
        raise RunnerError("executable_missing", f"cannot launch backend: {command[0]}") from error


def validate_segment(start: Any, end: Any, text: Any, duration: float, index: int) -> tuple[float, float, str]:
    if isinstance(start, bool) or isinstance(end, bool) or not isinstance(start, (int, float)) or not isinstance(end, (int, float)):
        raise RunnerError("malformed_output", f"segment {index} has invalid timestamps")
    start_value, end_value = float(start), float(end)
    if not math.isfinite(start_value) or not math.isfinite(end_value) or not 0 <= start_value < end_value <= duration + TIME_TOLERANCE_SECONDS:
        raise RunnerError("coverage_shortfall", f"segment {index} is outside chunk duration")
    if not isinstance(text, str) or not text.strip():
        raise RunnerError("malformed_output", f"segment {index} has empty text")
    return start_value, min(end_value, duration), text


def validate_moss_eos_structure(
    raw_text: Any, raw_segments: Any, duration: float
) -> tuple[str | None, list[dict[str, Any]]]:
    """Check a MOSS end-of-sequence payload for structured-output completeness.

    The engineering constraint policy closes an EOS stop as ``invalid_eos_output``
    unless the payload carries timestamped, in-range, non-blank segments.  The
    caller decides the outcome; this returns the first failure reason (``None``
    when the payload is complete) together with the normalized segments.
    """
    if not isinstance(raw_text, str) or not raw_text.strip():
        return "MOSS EOS output has no raw transcript", []
    if not isinstance(raw_segments, list) or not raw_segments:
        return "MOSS EOS output has no validated segments", []
    segments: list[dict[str, Any]] = []
    for index, item in enumerate(raw_segments):
        if not isinstance(item, dict):
            return f"MOSS EOS segment {index} is not an object", []
        try:
            start, end, text = validate_segment(item.get("start_s"), item.get("end_s"), item.get("text"), duration, index)
        except RunnerError as error:
            return f"MOSS EOS output failed structure validation: {error}", []
        speaker = item.get("speaker") if isinstance(item.get("speaker"), str) and item["speaker"].strip() else "UNASSIGNED"
        segments.append({"start_s": start, "end_s": end, "text": text, "speaker": speaker})
    return None, segments


def repetition_units(text: Any) -> list[str]:
    """Split transcript text into the units repetition is measured over."""
    if not isinstance(text, str):
        return []
    return VIBEVOICE_REPETITION_UNIT.findall(text)


def repetition_run_length(text: Any, *, phrase_units: int = VIBEVOICE_REPETITION_PHRASE_UNITS) -> int:
    """Longest run of consecutive identical 1..``phrase_units``-grams.

    A healthy transcript repeats a word two or three times; a collapsed
    decoder repeats one unit or a short phrase for the rest of the
    generation.  Counting repeats rather than a frequency share keeps a long
    passage that happens to reuse a common word from scoring as degenerate.
    """
    units = repetition_units(text)
    total = len(units)
    if total == 0:
        return 0
    longest = 1
    for width in range(1, max(1, phrase_units) + 1):
        if total < 2 * width:
            break
        index = 0
        while index + width <= total:
            cursor, repeats = index, 1
            while (
                cursor + 2 * width <= total
                and units[cursor:cursor + width] == units[cursor + width:cursor + 2 * width]
            ):
                repeats += 1
                cursor += width
            longest = max(longest, repeats)
            index = cursor + width
    return longest


def is_repetition_looping(text: Any) -> bool:
    return repetition_run_length(text) >= VIBEVOICE_REPETITION_RUN_THRESHOLD


def decode_leading_transcript_objects(text: Any) -> tuple[list[tuple[dict[str, Any], int]], str]:
    """Incrementally decode the leading complete objects of a JSON array in string form.

    VibeVoice emits its transcript into the payload ``text`` field as a JSON
    array of objects.  When generation collapses, the array is never closed,
    ``mlx-audio`` cannot parse it, and the payload ``segments`` list arrives
    empty even though the leading objects are complete and correct.  This
    returns each complete object with the offset just past it, plus the
    trailing text that could not be decoded.
    """
    if not isinstance(text, str):
        return [], ""
    decoder = json.JSONDecoder()
    index, total = 0, len(text)
    while index < total and text[index] in " \t\r\n":
        index += 1
    if index < total and text[index] == "[":
        index += 1
    decoded: list[tuple[dict[str, Any], int]] = []
    while True:
        while index < total and text[index] in " \t\r\n,":
            index += 1
        if index >= total or text[index] != "{":
            break
        try:
            item, end = decoder.raw_decode(text, index)
        except ValueError:
            break
        if not isinstance(item, dict):
            break
        decoded.append((item, end))
        index = end
    return decoded, text[index:]


def recover_vibevoice_prefix(raw_text: Any, duration: float) -> dict[str, Any]:
    """Recover the leading valid transcript prefix from a VibeVoice payload.

    Looping is intermittent before it is terminal: a collapsed passage
    can be followed by correct output.  Stopping at the first repeated run
    would therefore discard recoverable transcript, so only trailing
    degenerate objects are dropped and an interior one is kept and marked.
    """
    decoded, tail = decode_leading_transcript_objects(raw_text)
    segments: list[dict[str, Any]] = []
    offsets: list[int] = []
    previous_end = 0.0
    for index, (item, end_offset) in enumerate(decoded):
        try:
            start, end, text = validate_segment(
                item.get("Start"), item.get("End"), item.get("Content"), duration, index
            )
        except RunnerError:
            break
        if start < previous_end - TIME_TOLERANCE_SECONDS:
            break
        previous_end = end
        speaker = item.get("Speaker")
        if isinstance(speaker, bool) or not isinstance(speaker, (str, int)):
            speaker = ""
        else:
            speaker = str(speaker).strip()
        segments.append({
            "start_s": start,
            "end_s": end,
            "text": text,
            "speaker": speaker,
            "degenerate": is_repetition_looping(text),
        })
        offsets.append(end_offset)
    promoted = len(segments)
    while promoted > 0 and segments[promoted - 1]["degenerate"]:
        promoted -= 1
    # A closed array leaves only its terminator behind, and ``]`` is not
    # repeated content.  Scoring it as a repeatable unit sent an
    # end-of-sequence collapse down the nonempty-tail branch, where a run of 1
    # reported ``terminal_collapse = false`` while the caller emitted
    # ``repetitionLooping``; the Swift adapter rejects that pair as
    # inconsistent evidence.  The decision reads the model's own undecodable
    # text, so the terminator and the whitespace around it are removed first.
    residual_tail = tail.strip()
    if residual_tail.startswith("]"):
        residual_tail = residual_tail[1:].strip()
    tail_run = repetition_run_length(residual_tail)
    if repetition_units(residual_tail):
        terminal_collapse = tail_run >= VIBEVOICE_REPETITION_RUN_THRESHOLD
    else:
        terminal_collapse = bool(segments) and segments[-1]["degenerate"]
    # The promoted bytes are the model's own emission up to the end of the
    # last promoted object; only the array terminator is added back.
    prefix_text = raw_text[:offsets[promoted - 1]] + "]" if promoted else ""
    return {
        "complete_object_count": len(decoded),
        "validated_object_count": len(segments),
        "promoted_object_count": promoted,
        # Both counts describe the promoted prefix, which is the only thing
        # the run promotes and the only thing the CLI disclosure claims they
        # describe.  Objects sliced off the tail are already excluded from
        # ``promoted_object_count`` and ``segments``; counting them here made
        # the prefix look more degraded than the transcript it actually kept.
        "degenerate_object_count": sum(
            1 for item in segments[:promoted] if item["degenerate"]
        ),
        "coverage_s": segments[promoted - 1]["end_s"] if promoted else 0.0,
        "repetition_run_threshold": VIBEVOICE_REPETITION_RUN_THRESHOLD,
        "repetition_run_maximum": max(
            (repetition_run_length(item["text"]) for item in segments[:promoted]),
            default=0,
        ),
        "tail_repetition_run": tail_run,
        "tail_characters": len(residual_tail),
        "terminal_collapse": terminal_collapse,
        "raw_text": prefix_text,
        "segments": segments[:promoted],
    }


def run_vibevoice(
    *,
    spec: ModelSpec,
    audio: Path,
    duration: float,
    entries: Sequence[str],
    max_tokens: int,
    cache_root: Path,
    work: Path,
) -> dict[str, Any]:
    try:
        found = version("mlx-audio")
    except PackageNotFoundError as error:
        raise RunnerError("environment_missing", "mlx-audio is not installed in the pinned uv environment") from error
    if found != EXPECTED_MLX_AUDIO:
        raise RunnerError("environment_version", f"requires mlx-audio {EXPECTED_MLX_AUDIO}, found {found}")
    assert_vibevoice_closure(cache_root)
    if duration > MAX_VIBEVOICE_DURATION_SECONDS:
        raise RunnerError("duration_limit", "VibeVoice has a verified 59-minute limit; split this chunk before launch")
    try:
        from mlx_audio.stt.generate import generate_transcription
        from mlx_audio.stt.utils import load_model
    except Exception as error:
        raise RunnerError(
            "backend_import_failed",
            f"VibeVoice dependency import failed ({safe_exception_class(error)})",
        ) from None

    raw_prefix = work / "vibevoice"
    context = canonical_context(entries) if entries else None
    os.environ["HF_HOME"] = str(cache_root / "models" / "huggingface")
    os.environ["HF_HUB_OFFLINE"] = "1"
    try:
        model = load_model(spec.hf_model_id, revision=spec.revision)
    except Exception as error:
        raise RunnerError(
            "backend_load_failed",
            f"VibeVoice model load failed ({safe_exception_class(error)})",
        ) from None
    try:
        result = generate_transcription(
            model=model,
            audio=str(audio),
            output_path=str(raw_prefix),
            format="json",
            max_tokens=max_tokens,
            prefill_step_size=2048,
            context=context,
        )
    except Exception as error:
        raise RunnerError(
            "backend_inference_failed",
            f"VibeVoice inference failed ({safe_exception_class(error)})",
        ) from None
    assert_vibevoice_closure(cache_root)
    raw_path = raw_prefix.with_suffix(".json")
    if not raw_path.is_file():
        raise RunnerError("malformed_output", "VibeVoice produced no JSON output")
    raw_artifact = raw_path
    raw_json = raw_path.read_text(encoding="utf-8")
    try:
        payload = json.loads(raw_json)
    except json.JSONDecodeError as error:
        raise RunnerError("malformed_output", "VibeVoice JSON is malformed") from error
    prompt_tokens = getattr(result, "prompt_tokens", None)
    generated_tokens = getattr(result, "generation_tokens", None)
    total_time = getattr(result, "total_time", None)
    for name, value in (("prompt_tokens", prompt_tokens), ("generation_tokens", generated_tokens)):
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise RunnerError("malformed_output", f"VibeVoice {name} evidence is invalid")
    if isinstance(total_time, bool) or not isinstance(total_time, (int, float)) or not math.isfinite(float(total_time)) or total_time < 0:
        raise RunnerError("malformed_output", "VibeVoice total_time evidence is invalid")
    if generated_tokens > max_tokens:
        raise RunnerError("malformed_output", "VibeVoice generated token count exceeds the requested cap")

    # mlx-audio 0.4.6 consumes EOS without yielding it. Exhausting the
    # generator therefore yields exactly max_tokens non-EOS tokens, while an
    # EOS stop always reports fewer than max_tokens generated tokens.
    reached_limit = generated_tokens == max_tokens
    metrics = {
        "preprocessing_s": None,
        "audio_encoder_s": None,
        "decoder_prefill_s": None,
        "token_decode_s": None,
        "total_s": float(total_time),
        "model_load_s": None,
        "audio_duration_s": duration,
        "prompt_tokens": prompt_tokens,
        "generated_tokens": generated_tokens,
        "requested_max_tokens": max_tokens,
        "max_tokens": max_tokens,
        "context_hard_cap_tokens": None,
        "peak_rss_bytes": None,
    }
    aggregate_reason = "mlx-audio 0.4.6 reports only aggregate generation total_time"
    metrics_unavailable = {
        "preprocessing_s": aggregate_reason,
        "audio_encoder_s": aggregate_reason,
        "decoder_prefill_s": aggregate_reason,
        "token_decode_s": aggregate_reason,
        "model_load_s": aggregate_reason,
        "context_hard_cap_tokens": "mlx-audio 0.4.6 does not expose the model context hard cap",
        "peak_rss_bytes": "mlx-audio 0.4.6 does not report process peak RSS",
    }
    payload_text = payload.get("text") if isinstance(payload, dict) else None
    common = {
        "payload_hash": sha256_bytes(context.encode("utf-8")) if context else None,
        "command": ["mlx_audio.stt.generate"],
        "artifact": raw_artifact,
        "terminal_evidence": "observed",
        "timing_granularity": "segment",
        "metrics": metrics,
        "metrics_unavailable": metrics_unavailable,
    }
    if reached_limit:
        # The generator was exhausted, so the transcript array in ``text`` was
        # never closed and ``segments`` arrived empty.  Recover the leading
        # valid objects as a non-promotable prefix instead of discarding the
        # payload, and separate a collapsed decoder from a transcript that
        # legitimately ran out of output budget.
        prefix = recover_vibevoice_prefix(payload_text, duration)
        return {
            **common,
            "raw_text": "",
            "segments": [],
            "outcome": "limit",
            "stop_reason": "repetitionLooping" if prefix["terminal_collapse"] else "maximumTokens",
            "partial_prefix": prefix,
        }

    raw_segments = payload.get("segments") if isinstance(payload, dict) else None
    if not isinstance(raw_segments, list) or not raw_segments:
        raise RunnerError("malformed_output", "VibeVoice JSON has no segments")
    raw_text = payload.get("text")
    if not isinstance(raw_text, str) or not raw_text:
        raise RunnerError("malformed_output", "VibeVoice JSON has no transcript text field")
    segments: list[dict[str, Any]] = []
    previous = (-1.0, -1.0)
    for index, item in enumerate(raw_segments):
        if not isinstance(item, dict):
            raise RunnerError("malformed_output", f"VibeVoice segment {index} is not an object")
        start, end, text = validate_segment(item.get("start"), item.get("end"), item.get("text"), duration, index)
        if (start, end) < previous:
            raise RunnerError("malformed_output", "VibeVoice segments are not ordered")
        previous = (start, end)
        speaker = item.get("speaker_id")
        if isinstance(speaker, bool):
            speaker = ""
        elif isinstance(speaker, (str, int)):
            speaker = str(speaker).strip()
        else:
            speaker = ""
        entry = {
            "start_s": start,
            "end_s": end,
            "text": text,
            "speaker": speaker,
        }
        if is_repetition_looping(text):
            entry["degenerate"] = True
        segments.append(entry)
    # An end-of-sequence stop is not by itself a complete result: a decoder
    # that collapsed and then emitted EOS ends on repeated content.  Close
    # that case as a limit outcome carrying the same recovered prefix rather
    # than promoting the repetition as canonical.
    if segments[-1].get("degenerate"):
        return {
            **common,
            "raw_text": "",
            "segments": [],
            "outcome": "limit",
            "stop_reason": "repetitionLooping",
            "partial_prefix": recover_vibevoice_prefix(raw_text, duration),
        }
    return {
        **common,
        "raw_text": raw_text,
        "segments": segments,
        "outcome": "complete",
        "stop_reason": "endOfSequence",
    }


def run_qwen(
    *,
    spec: ModelSpec,
    audio: Path,
    duration: float,
    entries: Sequence[str],
    language: str | None,
    max_tokens: int,
    cache_root: Path,
    timeout_seconds: float,
    work: Path,
) -> dict[str, Any]:
    assert_hf_snapshot(cache_root, spec)
    speech = shutil.which("speech")
    if speech is None:
        raise RunnerError("executable_missing", "speech CLI is not on PATH")
    command = [speech, "transcribe", str(audio), "--engine", "qwen3", "--model", spec.hf_model_id]
    if language:
        command.extend(["--language", language])
    context = canonical_context(entries) if entries else None
    if context:
        command.extend(["--context", context])
    environment = dict(os.environ)
    environment["HF_HOME"] = str(cache_root / "models" / "huggingface")
    environment["HF_HUB_OFFLINE"] = "1"
    result = run_process(command, timeout_seconds=timeout_seconds, env=environment)
    raw_output = result.stdout
    if result.returncode != 0:
        raise RunnerError(
            "backend_failed",
            f"Qwen backend exited with status {result.returncode}",
        )
    lines = [line for line in raw_output.splitlines() if line.startswith("Result: ")]
    if len(lines) != 1:
        raise RunnerError("malformed_output", "Qwen must emit exactly one Result line per chunk")
    transcript = lines[0][len("Result: "):].strip()
    if not transcript:
        raise RunnerError("malformed_output", "Qwen emitted an empty transcript")
    artifact = work / "qwen.stdout.txt"
    artifact.write_text(raw_output, encoding="utf-8", newline="\n")
    terminal_reason = "speech 0.0.23 emits transcript text but no decoder terminal reason"
    timing_reason = "speech 0.0.23 emits no timestamped Qwen segments"
    unsupported_reason = (
        "Qwen output cannot be verified because speech 0.0.23 exposes neither "
        "a token cap and terminal reason nor intra-chunk timestamps"
    )
    metrics = {
        "preprocessing_s": None,
        "audio_encoder_s": None,
        "decoder_prefill_s": None,
        "token_decode_s": None,
        "total_s": None,
        "model_load_s": None,
        "audio_duration_s": duration,
        "prompt_tokens": None,
        "generated_tokens": None,
        "requested_max_tokens": max_tokens,
        "max_tokens": None,
        "context_hard_cap_tokens": None,
        "peak_rss_bytes": None,
    }
    metrics_unavailable = {
        "preprocessing_s": "speech 0.0.23 does not report Qwen stage timings",
        "audio_encoder_s": "speech 0.0.23 does not report Qwen stage timings",
        "decoder_prefill_s": "speech 0.0.23 does not report Qwen stage timings",
        "token_decode_s": "speech 0.0.23 does not report Qwen stage timings",
        "total_s": "speech 0.0.23 does not report Qwen backend total time",
        "model_load_s": "speech 0.0.23 does not report Qwen model-load time",
        "prompt_tokens": "speech 0.0.23 does not report Qwen prompt tokens",
        "generated_tokens": "speech 0.0.23 does not report Qwen generated tokens",
        "max_tokens": "speech 0.0.23 does not accept an effective Qwen output cap",
        "context_hard_cap_tokens": "speech 0.0.23 does not expose the Qwen context hard cap",
        "peak_rss_bytes": "speech 0.0.23 does not report process peak RSS",
    }
    return {
        "raw_text": transcript,
        "segments": [],
        "payload_hash": sha256_bytes(context.encode("utf-8")) if context else None,
        "command": command,
        "artifact": artifact,
        "outcome": "unverified",
        "stop_reason": None,
        "terminal_evidence": "unavailable",
        "timing_granularity": "chunk",
        "metrics": metrics,
        "metrics_unavailable": metrics_unavailable,
        "evidence_unavailable": {
            "terminal_reason": terminal_reason,
            "intra_chunk_timing": timing_reason,
        },
        "failure": {"code": "evidence_unavailable", "message": unsupported_reason},
    }


def run_moss(
    *, spec: ModelSpec, audio: Path, duration: float, entries: Sequence[str], language: str, max_tokens: int, cache_root: Path, work: Path, timeout_seconds: float
) -> dict[str, Any]:
    model_dir = cache_root / "models" / f"moss-transcribe-diarize-0.9b-mlx-int8-{spec.revision}"
    if not model_dir.is_dir():
        raise RunnerError("model_missing", f"MOSS model directory is missing: {model_dir}")
    metadata = model_dir / ".cache" / "huggingface" / "trees" / f"{spec.revision}.json"
    if not metadata.is_file():
        raise RunnerError("model_unpinned", f"MOSS model has no pinned revision metadata: {metadata}")
    fingerprint = verify_moss_harness_fingerprint(cache_root)
    binary, _, _ = moss_harness_paths(cache_root)
    glossary_path: Path | None = None
    if entries:
        glossary_path = work / "glossary.txt"
        glossary_path.write_text("\n".join(entries) + "\n", encoding="utf-8", newline="\n")
    output = work / "moss.json"
    command = [str(binary), "--audio", str(audio), "--model-dir", str(model_dir), "--max-tokens", str(max_tokens), "--language", language]
    if glossary_path:
        command.extend(["--glossary", str(glossary_path)])
    command.extend(["--output", str(output)])
    environment = dict(os.environ)
    environment["HF_HUB_OFFLINE"] = "1"
    result = run_process(command, timeout_seconds=timeout_seconds, env=environment)
    if not output.is_file():
        raise RunnerError("malformed_output", "MOSS did not create its output JSON")
    try:
        payload = json.loads(output.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise RunnerError("malformed_output", "MOSS output is malformed") from error
    model = payload.get("model") if isinstance(payload, dict) else None
    if not isinstance(model, dict) or model.get("hf_id") != spec.hf_model_id or model.get("revision") != spec.revision or model.get("quantization") != spec.quantization:
        raise RunnerError("model_unpinned", "MOSS output does not prove the selected model identity")
    audio_meta = payload.get("audio") or {}
    if abs(float(audio_meta.get("duration_s", -1)) - duration) > TIME_TOLERANCE_SECONDS:
        raise RunnerError("coverage_shortfall", "MOSS reported a duration different from the input chunk")
    metrics = payload.get("metrics") or {}
    stop_reason = metrics.get("stop_reason")
    status = payload.get("status")
    failure = payload.get("failure") if isinstance(payload, dict) else None
    failure_code = failure.get("code") if isinstance(failure, dict) else None
    invalid_eos_output = (
        result.returncode == 1
        and status == "failed"
        and stop_reason == "endOfSequence"
        and failure_code == "invalid_eos_output"
    )
    expected_exit = {"endOfSequence": 0, "maximumTokens": 75, "contextLimit": 76}.get(stop_reason)
    expected_status = "complete" if stop_reason == "endOfSequence" else "incomplete"
    if not invalid_eos_output and (expected_exit is None or result.returncode != expected_exit or status != expected_status):
        raise RunnerError("harness_contract_mismatch", f"MOSS exit/status/stop mismatch: exit={result.returncode}, status={status!r}, stop={stop_reason!r}")
    glossary = payload.get("glossary") or {}
    if bool(glossary.get("applied")) != bool(entries) or int(glossary.get("item_count", -1)) != len(entries):
        raise RunnerError("glossary_not_applied", "MOSS did not confirm the exact glossary payload")
    instruction_hash = glossary.get("instruction_sha256")
    language_evidence = payload.get("language") or {}
    if not isinstance(instruction_hash, str) or not is_sha256(instruction_hash) or language_evidence.get("requested") != language or language_evidence.get("instruction_sha256") != instruction_hash or bool(language_evidence.get("prompt_guidance_applied")) != (language != "auto"):
        raise RunnerError("glossary_not_applied", "MOSS did not retain hotword instruction evidence")
    for key in ("preprocessing_s", "audio_encoder_s", "decoder_prefill_s", "token_decode_s", "total_s", "model_load_s", "audio_duration_s"):
        value = metrics.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)) or value < 0:
            raise RunnerError("malformed_output", f"MOSS metrics field {key} is invalid")
    for key in ("prompt_tokens", "generated_tokens", "max_tokens", "context_hard_cap_tokens", "peak_rss_bytes"):
        value = metrics.get(key)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise RunnerError("malformed_output", f"MOSS metrics field {key} is invalid")
    if abs(float(metrics["audio_duration_s"]) - duration) > TIME_TOLERANCE_SECONDS:
        raise RunnerError("coverage_shortfall", "MOSS metrics audio duration differs from input chunk")
    if int(metrics["max_tokens"]) != max_tokens or int(metrics["context_hard_cap_tokens"]) != 131072:
        raise RunnerError("harness_contract_mismatch", "MOSS did not retain max token or context-limit evidence")
    metrics["requested_max_tokens"] = max_tokens
    common = {"command": command, "artifact": output, "fingerprint": fingerprint, "instruction_hash": instruction_hash, "metrics": metrics, "stop_reason": stop_reason, "helper_returncode": result.returncode}
    if invalid_eos_output:
        return {
            **common,
            "outcome": "invalid_eos_output",
            "raw_text": "",
            "segments": [],
            "failure": {
                "code": "invalid_eos_output",
                "message": "MOSS EOS output has no validated segments",
            },
            "diagnostics": {"invalid_eos_source": "harness"},
        }
    # A non-failed stop must not carry a failure block.  The contradiction is
    # preserved as evidence instead of being dropped, without reclassifying the
    # outcome the exit/status/stop matrix already fixed.
    contradictory_failure = failure if isinstance(failure, dict) else None
    if stop_reason != "endOfSequence":
        limit = {**common, "outcome": "limit", "raw_text": "", "segments": []}
        if contradictory_failure is not None:
            limit["diagnostics"] = {"helper_failure": contradictory_failure}
        return limit
    reason, segments = validate_moss_eos_structure(payload.get("raw_text"), payload.get("segments"), duration)
    if reason is not None:
        diagnostics: dict[str, Any] = {"invalid_eos_source": "runner", "structure_failure": reason}
        if contradictory_failure is not None:
            diagnostics["helper_failure"] = contradictory_failure
        return {
            **common,
            "outcome": "invalid_eos_output",
            "raw_text": "",
            "segments": [],
            "failure": {"code": "invalid_eos_output", "message": reason},
            "diagnostics": diagnostics,
        }
    complete = {**common, "outcome": "complete", "raw_text": payload["raw_text"], "segments": segments}
    if contradictory_failure is not None:
        complete["diagnostics"] = {"helper_failure": contradictory_failure}
    return complete


def run(args: argparse.Namespace) -> dict[str, Any]:
    spec = MODELS[args.backend]
    assert_pinned(spec)
    if args.max_tokens <= 0 or args.max_tokens > 131072:
        raise RunnerError("request_invalid", "--max-tokens must be in 1...131072")
    if args.injection_mode not in {"none", spec.injection_mode}:
        raise RunnerError("injection_mode", f"{spec.backend} requires {spec.injection_mode}, got {args.injection_mode}")
    audio = Path(args.audio).resolve(strict=True)
    duration = read_audio_duration(audio)
    expected_duration = args.end_s - args.start_s
    if args.start_s < 0 or args.end_s <= args.start_s:
        raise RunnerError("request_invalid", "ASR range must be a positive half-open interval")
    if abs(duration - expected_duration) > TIME_TOLERANCE_SECONDS:
        raise RunnerError("coverage_shortfall", f"chunk duration {duration:.3f}s does not match request range {expected_duration:.3f}s")
    entries, canonical_glossary_sha = parse_entries(Path(args.glossary) if args.glossary else None)
    if not entries and args.injection_mode != "none":
        raise RunnerError("glossary_invalid", "a glossary injection mode requires nonempty glossary entries")
    if entries and args.injection_mode == "none":
        raise RunnerError("injection_mode", "glossary entries require a decode-time injection mode")
    if entries and args.injection_mode != spec.injection_mode:
        raise RunnerError("injection_mode", f"{spec.backend} requires {spec.injection_mode}, got {args.injection_mode}")
    if entries:
        if not args.glossary_sha256 or len(args.glossary_sha256) != 64 or any(character not in "0123456789abcdef" for character in args.glossary_sha256):
            raise RunnerError("glossary_invalid", "adapter must provide the original 64-character glossary SHA-256")
        glossary_sha = args.glossary_sha256
    else:
        if args.glossary_sha256:
            raise RunnerError("glossary_invalid", "absent glossary must not carry an original SHA-256")
        glossary_sha = None
    cache_root = Path(args.cache_root).expanduser().resolve()
    output = Path(args.output).resolve()
    if output_is_present(output):
        raise RunnerError("output_exists", f"refusing to overwrite output: {output}")
    if output == audio or (args.glossary and output == Path(args.glossary).resolve()):
        raise RunnerError("output_alias", "output must not alias audio or glossary input")
    output.parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="asr-", dir=output.parent))
    audio_sha_before = sha256_file(audio)
    language = None if args.language == "auto" else args.language
    started = time.monotonic()
    failure: dict[str, Any] | None = None
    diagnostics: dict[str, Any] | None = None
    evidence_unavailable: dict[str, str] | None = None
    partial_prefix: dict[str, Any] | None = None
    if spec.backend == "vibevoice":
        backend = run_vibevoice(
            spec=spec,
            audio=audio,
            duration=duration,
            entries=entries,
            max_tokens=args.max_tokens,
            cache_root=cache_root,
            work=work,
        )
        raw_text, segments = backend["raw_text"], backend["segments"]
        payload_hash, command, backend_artifact = backend["payload_hash"], backend["command"], backend["artifact"]
        helper = None
        outcome, stop_reason = backend["outcome"], backend["stop_reason"]
        terminal_evidence, timing_granularity = backend["terminal_evidence"], backend["timing_granularity"]
        metrics, metrics_unavailable = backend["metrics"], backend["metrics_unavailable"]
        instruction_hash = payload_hash or sha256_bytes(b"vibevoice-no-prompt")
        prompt_guidance = False
        partial_prefix = backend.get("partial_prefix")
    elif spec.backend == "qwen3":
        backend = run_qwen(
            spec=spec,
            audio=audio,
            duration=duration,
            entries=entries,
            language=language,
            max_tokens=args.max_tokens,
            cache_root=cache_root,
            timeout_seconds=args.timeout_seconds,
            work=work,
        )
        raw_text, segments = backend["raw_text"], backend["segments"]
        payload_hash, command, backend_artifact = backend["payload_hash"], backend["command"], backend["artifact"]
        helper = None
        outcome, stop_reason = backend["outcome"], backend["stop_reason"]
        terminal_evidence, timing_granularity = backend["terminal_evidence"], backend["timing_granularity"]
        metrics, metrics_unavailable = backend["metrics"], backend["metrics_unavailable"]
        evidence_unavailable = backend["evidence_unavailable"]
        failure = backend["failure"]
        instruction_hash = payload_hash or sha256_bytes(b"qwen3-no-context")
        prompt_guidance = False
    else:
        moss = run_moss(spec=spec, audio=audio, duration=duration, entries=entries, language=args.language, max_tokens=args.max_tokens, cache_root=cache_root, work=work, timeout_seconds=args.timeout_seconds)
        raw_text, segments, command, backend_artifact = moss["raw_text"], moss["segments"], moss["command"], moss["artifact"]
        helper, outcome, stop_reason, metrics = moss["fingerprint"], moss["outcome"], moss["stop_reason"], moss["metrics"]
        terminal_evidence, timing_granularity = "observed", "segment"
        metrics_unavailable = {}
        instruction_hash, prompt_guidance = moss["instruction_hash"], args.language != "auto"
        failure = moss.get("failure")
        diagnostics = moss.get("diagnostics")
    audio_sha_after = sha256_file(audio)
    if audio_sha_after != audio_sha_before:
        raise RunnerError("input_mutated", "audio input changed during ASR; backend artifacts were preserved for inspection")
    if outcome == "complete" and not segments:
        raise RunnerError("malformed_output", "backend returned no normalized segments")
    if outcome == "complete" and any(segment["end_s"] > duration + TIME_TOLERANCE_SECONDS for segment in segments):
        raise RunnerError("coverage_shortfall", "backend returned out-of-range output")
    document = {
        "backend": spec.backend,
        "model": {"role": "asr", "hf_model_id": spec.hf_model_id, "revision": spec.revision, "quantization": spec.quantization},
        "outcome": outcome,
        "stop_reason": stop_reason,
        "terminal_evidence": terminal_evidence,
        "timing_granularity": timing_granularity,
        "language": {"requested": args.language, "instruction_sha256": instruction_hash, "prompt_guidance_applied": prompt_guidance},
        "raw_text": raw_text,
        "segments": [{**segment, "start_s": segment["start_s"] + args.start_s, "end_s": segment["end_s"] + args.start_s} for segment in segments],
        "glossary": {
            "provided": bool(entries), "sha256": glossary_sha, "canonical_payload_sha256": canonical_glossary_sha, "item_count": len(entries),
            "injection_mode": args.injection_mode if entries else "none", "applied": bool(entries),
            "payload_sha256": instruction_hash if entries else None,
            "payload_entry_count": len(entries),
            "instruction_sha256": instruction_hash,
        },
        "coverage": {"input_duration_s": expected_duration, "processed_duration_s": expected_duration if outcome == "complete" else 0, "truncated": outcome != "complete"},
        "input": {"sha256_before": audio_sha_before, "sha256_after": audio_sha_after},
        "command": command,
        "backend_raw_artifact": {"path": str(backend_artifact), "sha256": sha256_file(backend_artifact)},
        "helper_fingerprint": helper,
        "work_directory": str(work),
        "runner_wall_time_s": time.monotonic() - started,
        "metrics": metrics,
        "metrics_unavailable": metrics_unavailable,
    }
    if partial_prefix is not None:
        # The prefix is diagnostic evidence with an explicit covered range.
        # It is reported on the same timeline as the promoted segments so the
        # caller can promote it as partial coverage without recomputing it.
        # ``coverage_s`` stays a duration measured from the leaf start while
        # the segments carry absolute source timestamps, matching the
        # document's own coverage and segment conventions.
        document["partial_prefix"] = {
            **partial_prefix,
            "segments": [
                {**segment, "start_s": segment["start_s"] + args.start_s, "end_s": segment["end_s"] + args.start_s}
                for segment in partial_prefix["segments"]
            ],
        }
    if failure is not None:
        document["failure"] = failure
    if evidence_unavailable:
        document["evidence_unavailable"] = evidence_unavailable
    if diagnostics:
        document["diagnostics"] = diagnostics
    encoded = json.dumps(document, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
    try:
        with output.open("x", encoding="utf-8", newline="\n") as stream:
            stream.write(encoded)
    except FileExistsError as error:
        raise RunnerError("output_exists", f"refusing to overwrite output: {output}") from error
    return document


def doctor(args: argparse.Namespace) -> dict[str, Any]:
    spec = MODELS[args.backend]
    cache_root = Path(args.cache_root).expanduser().resolve()
    python_version = f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}"
    executable = Path(sys.executable)
    report: dict[str, Any] = {
        "backend": spec.backend, "python": python_version, "python_executable": str(executable),
        "model": {"role": "asr", "hf_model_id": spec.hf_model_id, "revision": spec.revision, "quantization": spec.quantization},
        "checks": [],
    }
    try:
        assert_pinned(spec)
        report["checks"].append({"name": "model_identity", "ok": True})
        if spec.backend == "vibevoice":
            report["checks"].extend(hf_cache_checks(
                cache_root,
                spec,
                name_prefix="model",
                required_files=VIBEVOICE_MODEL_PINS,
                require_tree=True,
            ))
            report["checks"].extend(hf_cache_checks(
                cache_root,
                VIBEVOICE_TOKENIZER,
                name_prefix="tokenizer",
                required_files=VIBEVOICE_TOKENIZER_PINS,
                require_ref=True,
                require_tree=True,
            ))
            report["checks"].append({
                "name": "tokenizer_semantics",
                "ok": vibevoice_tokenizer_semantics_are_valid(cache_root),
            })
        elif spec.backend == "qwen3":
            assert_hf_snapshot(cache_root, spec)
            report["checks"].append({"name": "model_snapshot", "ok": True})
        else:
            model_dir = cache_root / "models" / f"moss-transcribe-diarize-0.9b-mlx-int8-{spec.revision}"
            report["checks"].append({"name": "model_snapshot", "ok": model_dir.is_dir(), "path": str(model_dir)})
        if spec.backend == "vibevoice":
            found = version("mlx-audio")
            report["checks"].append({"name": "mlx_audio", "ok": found == EXPECTED_MLX_AUDIO, "version": found})
        elif spec.backend == "qwen3":
            speech = shutil.which("speech")
            report["checks"].append({"name": "speech", "ok": speech is not None, "path": speech})
        else:
            fingerprint = verify_moss_harness_fingerprint(cache_root)
            report["checks"].append({"name": "moss_harness", "ok": True, "path": fingerprint["path"], "version": fingerprint["contract_version"]})
    except (RunnerError, PackageNotFoundError) as error:
        report["checks"].append({"name": "runtime", "ok": False, "message": str(error)})
    report["ok"] = all(bool(check.get("ok")) for check in report["checks"])
    return report


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="operation", required=True)
    run_parser = subparsers.add_parser("run")
    run_parser.add_argument("--backend", choices=tuple(MODELS), required=True)
    run_parser.add_argument("--audio", required=True)
    run_parser.add_argument("--start-s", type=float, required=True)
    run_parser.add_argument("--end-s", type=float, required=True)
    run_parser.add_argument("--language", default="auto")
    run_parser.add_argument("--glossary")
    run_parser.add_argument("--glossary-sha256")
    run_parser.add_argument("--injection-mode", choices=("none", "free_text_context", "hotword_instruction"), required=True)
    run_parser.add_argument("--cache-root", required=True)
    run_parser.add_argument("--output", required=True)
    run_parser.add_argument("--timeout-seconds", type=float, default=900.0)
    run_parser.add_argument("--max-tokens", type=int, default=5120)
    plan_parser = subparsers.add_parser("plan-moss")
    plan_parser.add_argument("--sample-count", type=int, required=True)
    plan_parser.add_argument("--language", default="auto")
    plan_parser.add_argument("--glossary")
    plan_parser.add_argument("--glossary-sha256")
    plan_parser.add_argument("--cache-root", required=True)
    plan_parser.add_argument("--max-tokens", type=int, default=5120)
    doctor_parser = subparsers.add_parser("doctor")
    doctor_parser.add_argument("--backend", choices=tuple(MODELS), required=True)
    doctor_parser.add_argument("--cache-root", required=True)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        if args.operation == "doctor":
            document = doctor(args)
        elif args.operation == "plan-moss":
            document = plan_moss_prompt(args)
        else:
            document = run(args)
        print(json.dumps(document, ensure_ascii=False, sort_keys=True))
        if document.get("outcome") in {"invalid_eos_output", "unverified"}:
            failure = document["failure"]
            print(json.dumps({"error": failure}, ensure_ascii=False), file=sys.stderr)
            return 2
    except RunnerError as error:
        print(json.dumps({"error": {"code": error.code, "message": str(error)}}, ensure_ascii=False), file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
