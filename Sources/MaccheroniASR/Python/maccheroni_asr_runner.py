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
import shutil
import subprocess
import sys
import tempfile
import time
import wave
from dataclasses import dataclass
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path
from typing import Any, Sequence


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


@dataclass(frozen=True)
class ModelSpec:
    backend: str
    hf_model_id: str
    revision: str
    quantization: str
    injection_mode: str


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


class RunnerError(RuntimeError):
    def __init__(self, code: str, message: str):
        self.code = code
        super().__init__(message)


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
    assert_hf_snapshot(cache_root, spec)
    if duration > MAX_VIBEVOICE_DURATION_SECONDS:
        raise RunnerError("duration_limit", "VibeVoice has a verified 59-minute limit; split this chunk before launch")
    from mlx_audio.stt.generate import generate_transcription
    from mlx_audio.stt.utils import load_model

    raw_prefix = work / "vibevoice"
    context = canonical_context(entries) if entries else None
    os.environ["HF_HOME"] = str(cache_root / "models" / "huggingface")
    os.environ["HF_HUB_OFFLINE"] = "1"
    model = load_model(spec.hf_model_id, revision=spec.revision)
    result = generate_transcription(
        model=model,
        audio=str(audio),
        output_path=str(raw_prefix),
        format="json",
        max_tokens=max_tokens,
        prefill_step_size=2048,
        context=context,
    )
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
    if reached_limit:
        return {
            "raw_text": "",
            "segments": [],
            "payload_hash": sha256_bytes(context.encode("utf-8")) if context else None,
            "command": ["mlx_audio.stt.generate"],
            "artifact": raw_artifact,
            "outcome": "limit",
            "stop_reason": "maximumTokens",
            "terminal_evidence": "observed",
            "timing_granularity": "segment",
            "metrics": metrics,
            "metrics_unavailable": metrics_unavailable,
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
        segments.append({
            "start_s": start,
            "end_s": end,
            "text": text,
            "speaker": speaker,
        })
    return {
        "raw_text": raw_text,
        "segments": segments,
        "payload_hash": sha256_bytes(context.encode("utf-8")) if context else None,
        "command": ["mlx_audio.stt.generate"],
        "artifact": raw_artifact,
        "outcome": "complete",
        "stop_reason": "endOfSequence",
        "terminal_evidence": "observed",
        "timing_granularity": "segment",
        "metrics": metrics,
        "metrics_unavailable": metrics_unavailable,
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
        raise RunnerError("backend_failed", f"Qwen exited {result.returncode}: {result.stderr[-800:]}")
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
        message = failure.get("message") if isinstance(failure, dict) else None
        if not isinstance(message, str) or not message.strip():
            message = "MOSS emitted invalid EOS output"
        return {
            **common,
            "outcome": "invalid_eos_output",
            "raw_text": "",
            "segments": [],
            "failure": {
                "code": "invalid_eos_output",
                "message": message,
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
        if spec.backend in {"vibevoice", "qwen3"}:
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
