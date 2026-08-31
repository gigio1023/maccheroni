#!/usr/bin/env python3
"""Launch a DiCoW benchmark command from sealed environment fragments.

This module deliberately does not use a shell parser.  Environment files are a
small data format: one allow-listed ``NAME=/absolute/path`` assignment per line.
"""

import argparse
import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path
from typing import Dict, Iterable, Mapping, Optional, Sequence, Set, Tuple


class LauncherError(RuntimeError):
    """Raised when an environment contract is unsafe or incomplete."""


BASE_KEYS = (
    "MACCHERONI_BENCHMARK_CACHE",
    "HF_HOME",
    "DICOW_CACHE_ROOT",
    "DICOW_RUN_ID",
    "DICOW_RUN_ROOT",
    "DICOW_UV_CACHE",
    "DICOW_SPEECH_CACHE",
    "DICOW_SPEECH_RUNTIME_ROOT",
    "DICOW_SCORING_VENV",
)

FRAGMENT_RESOURCES = {
    "T2-aligner.env": {
        "producer": "T2",
        "resources": (("DICOW_ALIGNER_VENV", "venv", "benchmarks/env/dicow-aligner/uv.lock"),),
    },
    "T2-reference.env": {
        "producer": "T2",
        "resources": (
            ("DICOW_REFERENCE_VENV", "venv", "benchmarks/env/dicow-reference/uv.lock"),
        ),
    },
    "T9-diarizer.env": {
        "producer": "T9",
        "resources": (("DICOW_SPEECH_BIN", "file", None),),
    },
    "T10-pack.env": {
        "producer": "T10",
        "resources": (("DICOW_PACK_ROOT", "tree", None),),
    },
    "T17-mlx.env": {
        "producer": "T17",
        "resources": (("DICOW_MLX_VENV", "venv", "benchmarks/env/dicow-mlx/uv.lock"),),
    },
    "T22-control-goldens.env": {
        "producer": "T22",
        "resources": (("DICOW_CONTROL_GOLDEN_ROOT", "tree", None),),
    },
    "T23-control.env": {
        "producer": "T23",
        "resources": (
            ("DICOW_CONTROL_ROOT", "tree", None),
            ("DICOW_CONTROL_PARITY_ROOT", "tree", None),
        ),
    },
    "T24-dicow.env": {
        "producer": "T24",
        "resources": (
            ("DICOW_MODEL_ROOT", "tree", None),
            ("DICOW_PARITY_ROOT", "tree", None),
            ("DICOW_DICOW_GOLDEN_ROOT", "tree", None),
        ),
    },
    "Q1-qwen-apple.env": {
        "producer": "Q1",
        "resources": (
            ("DICOW_QWEN_APPLE_VENV", "venv", "benchmarks/env/qwen-apple/uv.lock"),
        ),
    },
    "R3-runtimes.env": {
        "producer": "R3",
        "resources": (
            ("DICOW_R2_ALIGNER_VENV", "venv", "benchmarks/env/dicow-aligner/uv.lock"),
            ("DICOW_R2_REFERENCE_VENV", "venv", "benchmarks/env/dicow-reference/uv.lock"),
            ("DICOW_R2_SPEECH_BIN", "file", None),
        ),
    },
    "R5-natural-pack.env": {
        "producer": "R5",
        "resources": (("DICOW_R2_PACK_ROOT", "tree", None),),
    },
    "R12-dicow-mlx.env": {
        "producer": "R12",
        "resources": (
            ("DICOW_R2_MLX_VENV", "venv", "benchmarks/env/dicow-mlx/uv.lock"),
            ("DICOW_R2_MODEL_ROOT", "tree", None),
            ("DICOW_R2_PARITY_ROOT", "tree", None),
        ),
    },
}


def _fragment_keys(name: str) -> Tuple[str, ...]:
    keys = []
    for resource_key, kind, _ in FRAGMENT_RESOURCES[name]["resources"]:
        keys.append(resource_key)
        if kind == "venv":
            keys.append(resource_key + "_LOCK_SHA256")
        else:
            keys.extend(
                (
                    resource_key + "_SHA256",
                    resource_key + "_BYTES",
                    resource_key + "_MODE",
                )
            )
        if resource_key == "DICOW_SPEECH_BIN":
            keys.append(resource_key + "_RELATIVE_PATH")
    return tuple(keys)


FRAGMENT_KEYS = {name: _fragment_keys(name) for name in FRAGMENT_RESOURCES}

PROFILE_FRAGMENTS = {
    "base": (),
    "scoring": (),
    "aligner": ("T2-aligner.env", "T10-pack.env"),
    "diarizer": ("T9-diarizer.env", "T10-pack.env"),
    "reference": (
        "T2-reference.env",
        "T10-pack.env",
        "T22-control-goldens.env",
        "T24-dicow.env",
    ),
    "mlx": (
        "T17-mlx.env",
        "T10-pack.env",
        "T22-control-goldens.env",
        "T23-control.env",
        "T24-dicow.env",
    ),
    "r2-qwen": ("Q1-qwen-apple.env",),
    "r2-aligner-bootstrap": ("R3-runtimes.env",),
    "r2-diarizer-bootstrap": ("R3-runtimes.env",),
    "r2-reference-bootstrap": ("R3-runtimes.env",),
    "r2-aligner": ("R3-runtimes.env", "R5-natural-pack.env"),
    "r2-diarizer": ("R3-runtimes.env", "R5-natural-pack.env"),
    "r2-reference": ("R3-runtimes.env", "R5-natural-pack.env"),
    "r2-mlx": ("R3-runtimes.env", "R5-natural-pack.env", "R12-dicow-mlx.env"),
}

REQUIRED_PROFILE_FRAGMENT = {
    "aligner": "T2-aligner.env",
    "diarizer": "T9-diarizer.env",
    "reference": "T2-reference.env",
    "mlx": "T17-mlx.env",
    "r2-qwen": "Q1-qwen-apple.env",
    "r2-aligner-bootstrap": "R3-runtimes.env",
    "r2-diarizer-bootstrap": "R3-runtimes.env",
    "r2-reference-bootstrap": "R3-runtimes.env",
    "r2-aligner": "R5-natural-pack.env",
    "r2-diarizer": "R5-natural-pack.env",
    "r2-reference": "R5-natural-pack.env",
    "r2-mlx": "R12-dicow-mlx.env",
}

VENV_KEYS = {
    "DICOW_ALIGNER_VENV",
    "DICOW_REFERENCE_VENV",
    "DICOW_MLX_VENV",
    "DICOW_QWEN_APPLE_VENV",
    "DICOW_R2_MLX_VENV",
    "DICOW_R2_ALIGNER_VENV",
    "DICOW_R2_REFERENCE_VENV",
}
ARTIFACT_KEYS = {
    "DICOW_PACK_ROOT",
    "DICOW_CONTROL_GOLDEN_ROOT",
    "DICOW_CONTROL_ROOT",
    "DICOW_CONTROL_PARITY_ROOT",
    "DICOW_MODEL_ROOT",
    "DICOW_PARITY_ROOT",
    "DICOW_DICOW_GOLDEN_ROOT",
    "DICOW_R2_PACK_ROOT",
    "DICOW_R2_MODEL_ROOT",
    "DICOW_R2_PARITY_ROOT",
    "DICOW_R2_SPEECH_BIN",
}

R2_TRACKED_FILES = (
    "docs/contracts/dicow-experiment.schema.json",
    "docs/contracts/dicow-gate.schema.json",
    "docs/dicow-conversion-lane.md",
    "benchmarks/scripts/dicow/common/pins.py",
    "benchmarks/scripts/dicow/common/manifest.py",
    "benchmarks/scripts/dicow/run_with_env.py",
    "benchmarks/scripts/dicow/tests/test_contract.py",
    "benchmarks/scripts/dicow/tests/test_run_with_env.py",
)
R2_TASK_TRACKED_FILES = {
    "R3": (
        "benchmarks/scripts/dicow/common/preflight.py",
        "benchmarks/scripts/dicow/reference/inspect.py",
        "benchmarks/scripts/dicow/tests/test_inspect.py",
        "benchmarks/scripts/dicow/tests/test_preflight.py",
    ),
}
R2_R3_FIXED_SOURCE_PATHS = {
    "frontier_rights_checksums": "frontier-rights-j0/SHA256SUMS",
    "r3_source_acquisition_checksums": "r3-source-acquisition.staging/SHA256SUMS",
    "r3_safetensors_headers_checksums": "r3-safetensors-headers.staging/SHA256SUMS",
    "r3_fleurs_timestamp_checksums": "r3-fleurs-timestamp.staging/SHA256SUMS",
    "r3_hike_terms_v2_checksums": "r3-hike-terms-v2.staging/SHA256SUMS",
    "r3_runtime_checksums": "r3-runtime.staging/SHA256SUMS",
    "qwen_q1_design_v2_checksums": "qwen-q1-design-v2.staging/SHA256SUMS",
    "r3_audit_spec_v2": "r3-audit-spec-v2.staging/spec.json",
}
R2_R3_SOURCE_INPUT_KEYS = (
    "plan_contract", "run_manifest", "R1_effective_state", "R2_state",
    *R2_R3_FIXED_SOURCE_PATHS,
    "pre_model_audit_manifest",
)
R2_R3_ACTIVE_SPEC_SOURCE_KEY = "r3_audit_spec_v2"
R2_R3_SEALED_PATH_KINDS = {
    "DICOW_R2_ALIGNER_VENV": "venv",
    "DICOW_R2_REFERENCE_VENV": "venv",
    "DICOW_R2_SPEECH_BIN": "file",
}
R2_TASK_DEPENDENCIES = {
    "R0": (), "R1": ("R0",), "R2": ("R0", "R1"),
    "R3": ("R1", "R2"), "R4": ("R3",), "R5": ("R4",),
    "Q1": ("R4",), "R6": ("R4",), "R7": ("R5", "R6"),
    "R8": ("R7",), "R9": ("R8",), "R10": ("R8", "R9"),
    "Q2": ("Q1", "R4"), "R11": ("R10",), "R12": ("R11",),
    "R13": ("Q2", "R12"),
}

_KEY_RE = re.compile(r"[A-Z][A-Z0-9_]*\Z")
_RUN_ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")
_SAFE_PATH_RE = re.compile(r"/[A-Za-z0-9._/@:+-]+(?:/[A-Za-z0-9._@:+-]+)*\Z")
_SAFE_RELATIVE_PATH_RE = re.compile(r"[A-Za-z0-9._@+-]+(?:/[A-Za-z0-9._@+-]+)*\Z")
_SHA256_RE = re.compile(r"[0-9a-f]{64}\Z")
_MODE_RE = re.compile(r"0[0-7]{3}\Z")
_INTEGER_RE = re.compile(r"0|[1-9][0-9]*\Z")

COMMUNITY1_MODEL_ID = "aufklarer/Pyannote-Community-1-CoreML"
COMMUNITY1_MODEL_REVISION = "a14e6c420d56e8472850649b016a486fd0acbe81"

# Commands in the plan use the system shell and, for Python environments, Homebrew's
# project tools.  The diarizer never needs Homebrew and must not discover its moving
# ``speech`` symlink.
SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
TOOL_PATH = "/opt/homebrew/bin:/usr/local/bin:" + SYSTEM_PATH
SAFE_PATH = TOOL_PATH
EMPTY_HOME = "/private/var/empty"


def _checkout_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _is_within(path: Path, parent: Path) -> bool:
    try:
        path.relative_to(parent)
    except ValueError:
        return False
    return True


def _require_absolute_normal_path(path: Path, label: str) -> None:
    rendered = str(path)
    if not path.is_absolute():
        raise LauncherError("{} must be absolute".format(label))
    if rendered == os.sep or os.path.normpath(rendered) != rendered:
        raise LauncherError("{} must be a normalized non-root path".format(label))


def _reject_symlink_components(path: Path, label: str) -> None:
    """Reject symlinks in every existing component, including the leaf."""

    _require_absolute_normal_path(path, label)
    current = Path(path.anchor)
    for component in path.parts[1:]:
        current = current / component
        try:
            info = os.lstat(str(current))
        except FileNotFoundError:
            return
        if stat.S_ISLNK(info.st_mode):
            raise LauncherError("{} contains symlink component {}".format(label, current))


def _read_stable_file(path: Path, label: str, require_read_only: bool) -> bytes:
    _reject_symlink_components(path, label)
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(str(path), flags)
    except OSError as error:
        raise LauncherError("cannot open {}: {}".format(label, error))
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise LauncherError("{} must be a regular file".format(label))
        if require_read_only and stat.S_IMODE(before.st_mode) & 0o222:
            raise LauncherError("{} must be read-only".format(label))
        chunks = []
        while True:
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    identity_before = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    identity_after = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
    try:
        path_info = os.lstat(str(path))
    except OSError as error:
        raise LauncherError("{} changed while it was read: {}".format(label, error))
    identity_path = (
        path_info.st_dev,
        path_info.st_ino,
        path_info.st_size,
        path_info.st_mtime_ns,
    )
    if identity_before != identity_after or identity_after != identity_path:
        raise LauncherError("{} changed while it was read".format(label))
    return b"".join(chunks)


def _read_sealed_file(path: Path, label: str) -> bytes:
    return _read_stable_file(path, label, require_read_only=True)


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _mode(path: Path) -> str:
    return "0{:03o}".format(stat.S_IMODE(os.lstat(str(path)).st_mode))


def _reject_duplicate_json_keys(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise LauncherError("JSON contains duplicate key {}".format(key))
        value[key] = item
    return value


def _read_sealed_json(path: Path, label: str):
    data = _read_sealed_file(path, label)
    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=_reject_duplicate_json_keys)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise LauncherError("{} is not valid JSON: {}".format(label, error))
    if not isinstance(value, dict):
        raise LauncherError("{} must contain a JSON object".format(label))
    return value, data


def _file_record(path: Path, label: str, require_read_only: bool = True) -> Dict[str, object]:
    data = _read_stable_file(path, label, require_read_only=require_read_only)
    return {
        "path": str(path),
        "sha256": _sha256(data),
        "bytes": len(data),
        "mode": _mode(path),
    }


def _tree_record(path: Path, label: str, require_read_only: bool) -> Dict[str, object]:
    """Fingerprint a tree, excluding Python bytecode caches in mutable venvs."""

    _reject_symlink_components(path, label)
    if not path.is_dir():
        raise LauncherError("{} must be an existing directory".format(label))
    digest = hashlib.sha256()
    total_bytes = 0
    root_mode = _mode(path)
    if require_read_only and stat.S_IMODE(os.lstat(str(path)).st_mode) & 0o222:
        raise LauncherError("{} root must be read-only".format(label))
    digest.update("D\t.\t{}\n".format(root_mode).encode("utf-8"))
    for directory, directory_names, file_names in os.walk(str(path), topdown=True, followlinks=False):
        directory_path = Path(directory)
        directory_names[:] = sorted(
            name for name in directory_names if name != "__pycache__"
        )
        file_names = sorted(
            name for name in file_names if not name.endswith((".pyc", ".pyo"))
        )
        for name in directory_names:
            child = directory_path / name
            info = os.lstat(str(child))
            relative = str(child.relative_to(path))
            if stat.S_ISLNK(info.st_mode):
                raise LauncherError("{} contains directory symlink {}".format(label, relative))
            if not stat.S_ISDIR(info.st_mode):
                raise LauncherError("{} contains non-directory {}".format(label, relative))
            mode = "0{:03o}".format(stat.S_IMODE(info.st_mode))
            if require_read_only and stat.S_IMODE(info.st_mode) & 0o222:
                raise LauncherError("{} contains writable directory {}".format(label, relative))
            digest.update("D\t{}\t{}\n".format(relative, mode).encode("utf-8"))
        for name in file_names:
            child = directory_path / name
            info = os.lstat(str(child))
            relative = str(child.relative_to(path))
            mode = "0{:03o}".format(stat.S_IMODE(info.st_mode))
            if stat.S_ISLNK(info.st_mode):
                target = os.readlink(str(child))
                if require_read_only:
                    raise LauncherError("{} contains symlink {}".format(label, relative))
                resolved = child.resolve(strict=True)
                target_data = _read_stable_file(
                    resolved,
                    "{} target {}".format(label, relative),
                    require_read_only=False,
                )
                digest.update(
                    "L\t{}\t{}\t{}\t{}\n".format(
                        relative, mode, target, _sha256(target_data)
                    ).encode("utf-8")
                )
                total_bytes += len(target_data)
                continue
            if not stat.S_ISREG(info.st_mode):
                raise LauncherError("{} contains non-regular file {}".format(label, relative))
            if require_read_only and stat.S_IMODE(info.st_mode) & 0o222:
                raise LauncherError("{} contains writable file {}".format(label, relative))
            if require_read_only:
                data = _read_sealed_file(child, "{} file {}".format(label, relative))
            else:
                data = _read_stable_file(
                    child,
                    "{} file {}".format(label, relative),
                    require_read_only=False,
                )
            total_bytes += len(data)
            digest.update(
                "F\t{}\t{}\t{}\t{}\n".format(
                    relative, mode, len(data), _sha256(data)
                ).encode("utf-8")
            )
    return {
        "path": str(path),
        "sha256": digest.hexdigest(),
        "bytes": total_bytes,
        "mode": root_mode,
    }


def sealed_path_record(path: Path, kind: str) -> Dict[str, object]:
    """Return the canonical tuple later task-state writers must seal."""

    path = Path(path)
    if kind == "file":
        return _file_record(path, str(path))
    if kind == "tree":
        return _tree_record(path, str(path), require_read_only=True)
    if kind == "venv":
        return _tree_record(path, str(path), require_read_only=False)
    raise LauncherError("unknown sealed path kind {}".format(kind))


def _parse_assignments(
    data: bytes, expected_keys: Iterable[str], label: str
) -> Dict[str, str]:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise LauncherError("{} is not UTF-8: {}".format(label, error))
    if not text or not text.endswith("\n") or "\r" in text or "\x00" in text:
        raise LauncherError("{} must be non-empty LF-terminated UTF-8".format(label))
    expected = tuple(expected_keys)
    allowed = set(expected)
    parsed = {}  # type: Dict[str, str]
    for line_number, line in enumerate(text[:-1].split("\n"), 1):
        if not line or line.count("=") != 1:
            raise LauncherError("{}:{} is not one assignment".format(label, line_number))
        key, value = line.split("=", 1)
        if not _KEY_RE.fullmatch(key) or key not in allowed:
            raise LauncherError("{}:{} contains unknown key {}".format(label, line_number, key))
        if key in parsed:
            raise LauncherError("{}:{} duplicates key {}".format(label, line_number, key))
        if not value or any(character.isspace() for character in value):
            raise LauncherError("{}:{} contains an empty or spaced value".format(label, line_number))
        parsed[key] = value
    if set(parsed) != allowed:
        missing = sorted(allowed.difference(parsed))
        raise LauncherError("{} is missing keys: {}".format(label, ", ".join(missing)))
    return parsed


def _validated_path(value: str, key: str, checkout: Path) -> Path:
    if not _SAFE_PATH_RE.fullmatch(value):
        raise LauncherError("{} contains shell syntax or unsupported path bytes".format(key))
    path = Path(value)
    _reject_symlink_components(path, key)
    if _is_within(path, checkout):
        raise LauncherError("{} may not resolve inside the checkout".format(key))
    return path


def _require_exact_path(actual: Path, expected: Path, key: str) -> None:
    if actual != expected:
        raise LauncherError("{} does not match the fixed cache layout".format(key))


def _validate_base(values: Mapping[str, str], env_file: Path, checkout: Path) -> Dict[str, Path]:
    run_id = values["DICOW_RUN_ID"]
    if not _RUN_ID_RE.fullmatch(run_id):
        raise LauncherError("DICOW_RUN_ID contains unsupported syntax")

    paths = {}  # type: Dict[str, Path]
    for key in BASE_KEYS:
        if key != "DICOW_RUN_ID":
            paths[key] = _validated_path(values[key], key, checkout)

    benchmark_cache = paths["MACCHERONI_BENCHMARK_CACHE"]
    cache_root = paths["DICOW_CACHE_ROOT"]
    _require_exact_path(cache_root, benchmark_cache / "dicow", "DICOW_CACHE_ROOT")
    _require_exact_path(paths["HF_HOME"], cache_root / "models" / "huggingface", "HF_HOME")
    _require_exact_path(paths["DICOW_RUN_ROOT"], cache_root / "runs" / run_id, "DICOW_RUN_ROOT")
    _require_exact_path(paths["DICOW_UV_CACHE"], cache_root / "uv-cache" / run_id, "DICOW_UV_CACHE")
    _require_exact_path(
        paths["DICOW_SPEECH_CACHE"], cache_root / "models" / "speech-swift", "DICOW_SPEECH_CACHE"
    )
    runtime_parent = cache_root / "runtimes" / "speech-swift"
    if not _is_within(paths["DICOW_SPEECH_RUNTIME_ROOT"], runtime_parent):
        raise LauncherError("DICOW_SPEECH_RUNTIME_ROOT is outside the fixed runtime root")
    scoring_parent = cache_root / "venvs" / "scoring"
    if not _is_within(paths["DICOW_SCORING_VENV"], scoring_parent):
        raise LauncherError("DICOW_SCORING_VENV is outside the scoring venv root")
    _require_exact_path(env_file.parent, cache_root / "run-envs", "env file parent")
    if env_file.suffix != ".env":
        raise LauncherError("env file must have an .env suffix")
    for key in ("MACCHERONI_BENCHMARK_CACHE", "DICOW_CACHE_ROOT", "DICOW_RUN_ROOT"):
        if not paths[key].is_dir():
            raise LauncherError("{} must already exist as a directory".format(key))
    return paths


def _require_record(actual, expected, label: str) -> None:
    if not isinstance(expected, dict):
        raise LauncherError("{} evidence must be an object".format(label))
    if set(expected) != {"path", "sha256", "bytes", "mode"}:
        raise LauncherError("{} evidence has the wrong fields".format(label))
    if expected != actual:
        raise LauncherError("{} evidence does not match disk".format(label))


def _relative_sealed_path(run_root: Path, value, label: str) -> Path:
    if not isinstance(value, str) or not _SAFE_RELATIVE_PATH_RE.fullmatch(value):
        raise LauncherError("{} must be a safe relative path".format(label))
    path = run_root / value
    if not _is_within(path, run_root):
        raise LauncherError("{} escapes DICOW_RUN_ROOT".format(label))
    return path


def _validate_r2_state_chain(
    run_root: Path,
    run_id: str,
    manifest: Mapping[str, object],
    manifest_bytes: bytes,
    checkout: Path,
) -> None:
    """Authenticate the R0 bootstrap handoff and, when present, the R1 contract."""

    r0_path = run_root / "task-state" / "R0.json"
    r0, r0_bytes = _read_sealed_json(r0_path, "R0 task state")
    if (
        r0.get("schema_version") != "dicow-r2-task-state-v1"
        or r0.get("task") != "R0"
        or r0.get("state") != "done"
        or r0.get("branch_disposition") != "executed"
        or r0.get("evidence_outcome") != "supported"
        or r0.get("run_id") != run_id
        or r0.get("next_task_ids") != ["R1"]
        or r0.get("no_valid_r1_j1_gate") is not True
    ):
        raise LauncherError("R0 task state does not authorize the r2 contract handoff")
    if r0.get("run_manifest_sha256") != _sha256(manifest_bytes):
        raise LauncherError("r2 run manifest differs from the R0 task-state hash")
    sources = r0.get("source_input_hashes")
    plan = manifest.get("plan_contract")
    if (
        not isinstance(sources, dict)
        or not isinstance(plan, dict)
        or sources.get("plan_contract") != plan.get("sha256")
        or any(
            not isinstance(value, str) or not _SHA256_RE.fullmatch(value)
            for value in sources.values()
        )
    ):
        raise LauncherError("R0 does not bind the exact r2 plan contract")
    artifacts = r0.get("artifacts")
    imported = manifest.get("r1_import")
    if not isinstance(artifacts, dict) or not isinstance(imported, dict):
        raise LauncherError("R0 import artifact binding is missing")
    import_artifact = artifacts.get("import-manifest")
    if not isinstance(import_artifact, dict) or any(
        import_artifact.get(key) != imported.get(key)
        for key in ("path", "sha256", "bytes", "mode")
    ):
        raise LauncherError("R0 import artifact differs from the run manifest")

    r1_path = run_root / "task-state" / "R1.json"
    if not r1_path.exists():
        raise LauncherError("r2 normal launcher requires the sealed R1 task state")
    r1, _ = _read_sealed_json(r1_path, "R1 task state")
    if (
        r1.get("schema_version") != "dicow-r2-task-state-v1"
        or r1.get("task") != "R1"
        or r1.get("state") != "done"
        or r1.get("branch_disposition") != "executed"
        or r1.get("evidence_outcome") != "supported"
        or r1.get("run_id") != run_id
        or r1.get("next_task_ids") != ["R2"]
    ):
        raise LauncherError("R1 task state does not authorize R2")
    sources = r1.get("source_input_hashes")
    expected_sources = {
        "R0_state": _sha256(r0_bytes),
        "run_manifest": _sha256(manifest_bytes),
    }
    if sources != expected_sources:
        raise LauncherError("R1 source dependency is not the exact R0/manifest pair")
    effective_r1 = r1
    amendment_inputs = None
    prior_name = "R1"
    prior_path = r1_path
    for amendment_name in (
        "R1-contract-amendment-1", "R1-contract-amendment-2",
        "R1-contract-amendment-3", "R1-contract-amendment-4",
        "R1-contract-amendment-5", "R1-contract-amendment-6",
        "R1-contract-amendment-7", "R1-contract-amendment-8",
        "R1-contract-amendment-9", "R1-contract-amendment-10",
    ):
        amendment_path = run_root / "task-state/{}.json".format(amendment_name)
        if not amendment_path.exists():
            later = {
                "R1-contract-amendment-1": ("R1-contract-amendment-2", "R1-contract-amendment-3", "R1-contract-amendment-4", "R1-contract-amendment-5", "R1-contract-amendment-6", "R1-contract-amendment-7", "R1-contract-amendment-8", "R1-contract-amendment-9", "R1-contract-amendment-10"),
                "R1-contract-amendment-2": ("R1-contract-amendment-3", "R1-contract-amendment-4", "R1-contract-amendment-5", "R1-contract-amendment-6", "R1-contract-amendment-7", "R1-contract-amendment-8", "R1-contract-amendment-9", "R1-contract-amendment-10"),
                "R1-contract-amendment-3": ("R1-contract-amendment-4", "R1-contract-amendment-5", "R1-contract-amendment-6", "R1-contract-amendment-7", "R1-contract-amendment-8", "R1-contract-amendment-9", "R1-contract-amendment-10"),
                "R1-contract-amendment-4": ("R1-contract-amendment-5", "R1-contract-amendment-6", "R1-contract-amendment-7", "R1-contract-amendment-8", "R1-contract-amendment-9", "R1-contract-amendment-10"),
                "R1-contract-amendment-5": ("R1-contract-amendment-6", "R1-contract-amendment-7", "R1-contract-amendment-8", "R1-contract-amendment-9", "R1-contract-amendment-10"),
                "R1-contract-amendment-6": ("R1-contract-amendment-7", "R1-contract-amendment-8", "R1-contract-amendment-9", "R1-contract-amendment-10"),
                "R1-contract-amendment-7": ("R1-contract-amendment-8", "R1-contract-amendment-9", "R1-contract-amendment-10"),
                "R1-contract-amendment-8": ("R1-contract-amendment-9", "R1-contract-amendment-10"),
                "R1-contract-amendment-9": ("R1-contract-amendment-10",),
                "R1-contract-amendment-10": (),
            }[amendment_name]
            if any((run_root / "task-state/{}.json".format(name)).exists() for name in later):
                raise LauncherError("R1 amendment chain has a missing predecessor")
            continue
        amendment, _ = _read_sealed_json(amendment_path, amendment_name)
        original_sha = _sha256(_read_sealed_file(prior_path, "prior effective R1 state"))
        if (
            amendment.get("schema_version") != "dicow-r2-task-state-v1"
            or amendment.get("task") != amendment_name
            or amendment.get("state") != "done"
            or amendment.get("branch_disposition") != "executed"
            or amendment.get("evidence_outcome") != "supported"
            or amendment.get("run_id") != run_id
            or amendment.get("next_task_ids") != ["R2"]
            or amendment.get("original_state_sha256") != original_sha
            or amendment.get("predecessor_state_hashes") != {prior_name: original_sha}
        ):
            raise LauncherError("R1 contract amendment is not a valid effective state")
        original_tracked = effective_r1.get("tracked_files")
        if not isinstance(original_tracked, dict):
            raise LauncherError("prior effective R1 tracked files are missing")
        amendment_inputs = {
            relative: original_tracked[relative]["output"] for relative in R2_TRACKED_FILES
        }
        effective_r1 = amendment
        prior_name, prior_path = amendment_name, amendment_path
    before_record = manifest.get("repository_before_state")
    if not isinstance(before_record, dict) or set(before_record) != {
        "path", "run_path", "sha256", "bytes", "mode"
    }:
        raise LauncherError("r2 repository-before-state tuple is malformed")
    before_path = _relative_sealed_path(
        run_root, before_record.get("run_path"), "repository before state"
    )
    actual_before = _file_record(
        before_path, "repository before state", require_read_only=True
    )
    if any(actual_before.get(key) != before_record.get(key) for key in ("sha256", "bytes", "mode")):
        raise LauncherError("repository-before-state differs from the run manifest")
    if str(before_path) != before_record.get("path"):
        raise LauncherError("repository-before-state absolute path differs from the manifest")
    before, _ = _read_sealed_json(before_path, "repository before state")
    untracked = before.get("untracked_worktree")
    if not isinstance(untracked, list):
        raise LauncherError("repository-before-state lacks untracked_worktree")
    before_index = {}
    for record in untracked:
        if not isinstance(record, dict) or set(record) != {"repo_path", "sha256", "bytes", "mode"}:
            raise LauncherError("repository-before-state contains a malformed untracked tuple")
        relative = record.get("repo_path")
        if relative in before_index:
            raise LauncherError("repository-before-state repeats an untracked path")
        before_index[relative] = {
            "sha256": record.get("sha256"),
            "bytes": record.get("bytes"),
            "mode": record.get("mode"),
        }
    tracked = effective_r1.get("tracked_files")
    if not isinstance(tracked, dict) or set(tracked) != set(R2_TRACKED_FILES):
        raise LauncherError("R1 tracked-file roster differs from the r2 contract")
    for relative in R2_TRACKED_FILES:
        transition = tracked.get(relative)
        path = checkout / relative
        if not isinstance(transition, dict) or set(transition) != {"input", "output"}:
            raise LauncherError("R1 tracked tuple is malformed for {}".format(relative))
        expected_input = (
            before_index.get(relative)
            if amendment_inputs is None
            else amendment_inputs[relative]
        )
        if transition.get("input") != expected_input:
            raise LauncherError("effective R1 input does not match its predecessor: {}".format(relative))
        expected = transition.get("output")
        if not isinstance(expected, dict) or set(expected) != {"sha256", "bytes", "mode"}:
            raise LauncherError("R1 output tuple is malformed for {}".format(relative))
        actual = _file_record(path, "R1 tracked file", require_read_only=False)
        actual.pop("path")
        if actual != expected:
            raise LauncherError("R1 tracked file differs from sealed state: {}".format(relative))


def _validate_run_binding(
    base: Mapping[str, str],
    base_bytes: bytes,
    env_file: Path,
    base_paths: Mapping[str, Path],
    checkout: Path,
) -> None:
    run_root = base_paths["DICOW_RUN_ROOT"]
    manifest_path = run_root / "run-manifest.json"
    manifest, manifest_bytes = _read_sealed_json(manifest_path, "run manifest")
    manifest_schema = manifest.get("schema_version")
    if manifest_schema not in ("dicow-run-manifest-v1", "dicow-r2-run-manifest-v1"):
        raise LauncherError("run manifest schema is not a supported DiCoW manifest")
    if manifest.get("run_id") != base["DICOW_RUN_ID"] or manifest.get("run_root") != str(run_root):
        raise LauncherError("run manifest identity differs from the base env")
    base_evidence = manifest.get("base_env")
    actual_base = {
        "path": str(env_file),
        "sha256": _sha256(base_bytes),
        "bytes": len(base_bytes),
        "mode": _mode(env_file),
    }
    if not isinstance(base_evidence, dict):
        raise LauncherError("run manifest base_env evidence is missing")
    if set(base_evidence) != {"path", "sha256", "bytes", "mode", "keys"}:
        raise LauncherError("run manifest base_env evidence has the wrong fields")
    for key, value in actual_base.items():
        if base_evidence.get(key) != value:
            raise LauncherError("base env tuple differs from the run manifest")
    if base_evidence.get("keys") != list(BASE_KEYS):
        raise LauncherError("run manifest base env key order differs from the contract")

    scoring_lock = manifest.get("scoring_lock")
    if not isinstance(scoring_lock, dict):
        raise LauncherError("run manifest scoring_lock evidence is missing")
    lock_path_value = scoring_lock.get("path")
    if not isinstance(lock_path_value, str):
        raise LauncherError("run manifest scoring lock path is missing")
    if not _SAFE_PATH_RE.fullmatch(lock_path_value):
        raise LauncherError("scoring lock path contains unsupported bytes")
    lock_path = Path(lock_path_value)
    _reject_symlink_components(lock_path, "scoring lock")
    expected_lock_path = checkout / "benchmarks" / "scripts" / "scoring" / "uv.lock"
    _require_exact_path(lock_path, expected_lock_path, "scoring lock")
    lock_record = _file_record(lock_path, "scoring lock", require_read_only=False)
    _require_record(lock_record, scoring_lock, "scoring lock")
    if base_paths["DICOW_SCORING_VENV"].name != lock_record["sha256"]:
        raise LauncherError("DICOW_SCORING_VENV basename must equal the scoring lock SHA-256")

    if manifest_schema == "dicow-r2-run-manifest-v1":
        if manifest.get("create_only") is not True:
            raise LauncherError("r2 run manifest must declare create_only=true")
        plan = manifest.get("plan_contract")
        if not isinstance(plan, dict) or set(plan) != {
            "boundary", "bytes", "path", "sha256"
        }:
            raise LauncherError("r2 plan contract tuple is malformed")
        if plan.get("boundary") != "bytes-before-final-## Results-heading":
            raise LauncherError("r2 plan contract uses the wrong boundary")
        plan_path = Path(str(plan.get("path", "")))
        _reject_symlink_components(plan_path, "r2 plan contract")
        plan_bytes_count = plan.get("bytes")
        if (
            not isinstance(plan_bytes_count, int)
            or isinstance(plan_bytes_count, bool)
            or plan_bytes_count <= 0
            or not plan_path.is_file()
        ):
            raise LauncherError("r2 plan contract bytes are unavailable")
        plan_prefix = plan_path.read_bytes()[:plan_bytes_count]
        if len(plan_prefix) != plan_bytes_count or _sha256(plan_prefix) != plan.get("sha256"):
            raise LauncherError("r2 plan contract prefix differs from the run manifest")
        if (
            manifest.get("plan_contract_bytes") != plan_bytes_count
            or manifest.get("plan_contract_sha256") != plan.get("sha256")
        ):
            raise LauncherError("r2 plan contract aliases differ from the exact tuple")
        imported = manifest.get("r1_import")
        if not isinstance(imported, dict) or set(imported) != {"path", "sha256", "bytes", "mode"}:
            raise LauncherError("r2 imported-r1 tuple is malformed")
        import_path = _relative_sealed_path(run_root, imported.get("path"), "r1 import")
        import_record = _file_record(import_path, "r1 import", require_read_only=True)
        import_record["path"] = imported.get("path")
        if import_record != imported:
            raise LauncherError("r2 imported-r1 manifest differs from disk")
        _validate_r2_state_chain(
            run_root, base["DICOW_RUN_ID"], manifest, manifest_bytes, checkout
        )
        return

    t0_path = run_root / "task-state" / "T0.json"
    t0, _ = _read_sealed_json(t0_path, "T0 task state")
    if (
        t0.get("schema_version") != "dicow-task-state-v1"
        or t0.get("task") != "T0"
        or t0.get("state") != "done"
        or t0.get("branch_disposition") != "executed"
        or t0.get("run_id") != base["DICOW_RUN_ID"]
        or t0.get("branch_verdict") != "proceed"
    ):
        raise LauncherError("T0 task state does not authorize this run")
    if t0.get("run_manifest_path") != "run-manifest.json":
        raise LauncherError("T0 task state names the wrong run manifest")
    if t0.get("run_manifest_sha256") != _sha256(manifest_bytes):
        raise LauncherError("run manifest differs from the T0 task-state hash")

    gate_path = _relative_sealed_path(run_root, t0.get("gate_path"), "T0 gate path")
    gate, gate_bytes = _read_sealed_json(gate_path, "T0 gate")
    if t0.get("gate_sha256") != _sha256(gate_bytes):
        raise LauncherError("T0 gate differs from the task-state hash")
    if gate.get("branch_verdict") != "proceed" or "T1" not in gate.get("next_task_ids", []):
        raise LauncherError("T0 gate does not authorize T1")


def _fragment_record(values: Mapping[str, str], key: str, path: Path) -> Dict[str, object]:
    sha256 = values.get(key + "_SHA256")
    byte_count = values.get(key + "_BYTES")
    mode = values.get(key + "_MODE")
    if not isinstance(sha256, str) or not _SHA256_RE.fullmatch(sha256):
        raise LauncherError("{} fragment SHA-256 is invalid".format(key))
    if not isinstance(byte_count, str) or not _INTEGER_RE.fullmatch(byte_count):
        raise LauncherError("{} fragment byte count is invalid".format(key))
    if not isinstance(mode, str) or not _MODE_RE.fullmatch(mode):
        raise LauncherError("{} fragment mode is invalid".format(key))
    return {"path": str(path), "sha256": sha256, "bytes": int(byte_count), "mode": mode}


def _validate_speech_canonical(
    expected: Mapping[str, object], run_root: Path, run_id: str
) -> None:
    canonical_path = run_root / "e0-preflight" / "canonical.json"
    canonical, _ = _read_sealed_json(canonical_path, "E0 canonical manifest")
    if canonical.get("schema_version") != "dicow-e0-preflight-v1":
        raise LauncherError("E0 canonical schema is not dicow-e0-preflight-v1")
    if canonical.get("run_id") != run_id or canonical.get("run_root") != str(run_root):
        raise LauncherError("E0 canonical run identity differs from the base env")

    bindings = canonical.get("runtime_bindings")
    if not isinstance(bindings, dict) or set(bindings) != {"aligner", "community1"}:
        raise LauncherError("E0 canonical runtime binding set differs from the contract")
    community = bindings.get("community1")
    if not isinstance(community, dict) or set(community) != {
        "model_id",
        "model_revision",
        "binary",
        "model_tree",
        "sandbox_profile",
    }:
        raise LauncherError("E0 canonical Community-1 binding has the wrong fields")
    if (
        community.get("model_id") != COMMUNITY1_MODEL_ID
        or community.get("model_revision") != COMMUNITY1_MODEL_REVISION
    ):
        raise LauncherError("E0 canonical Community-1 model identity differs from the plan pin")

    binary = community.get("binary")
    if not isinstance(binary, dict) or set(binary) != {"path", "record"}:
        raise LauncherError("E0 canonical Community-1 binary binding has the wrong fields")
    if binary.get("path") != expected["path"]:
        raise LauncherError("E0 canonical Community-1 binary path differs from the fragment")
    expected_record = {
        "kind": "file",
        "bytes": expected["bytes"],
        "mode": expected["mode"],
        "sha256": expected["sha256"],
    }
    if binary.get("record") != expected_record:
        raise LauncherError("E0 canonical Community-1 binary record differs from the fragment")


def _validate_resource(
    values: Mapping[str, str],
    key: str,
    kind: str,
    lock_relative: Optional[str],
    base_paths: Mapping[str, Path],
    checkout: Path,
    producer_state_exists: bool,
    run_id: str,
) -> Optional[Dict[str, object]]:
    cache_root = base_paths["DICOW_CACHE_ROOT"]
    run_root = base_paths["DICOW_RUN_ROOT"]
    path = _validated_path(values[key], key, checkout)
    if kind == "venv":
        if not _is_within(path, cache_root / "venvs"):
            raise LauncherError("{} is outside the isolated venv root".format(key))
        lock_sha = values.get(key + "_LOCK_SHA256")
        if not isinstance(lock_sha, str) or not _SHA256_RE.fullmatch(lock_sha):
            raise LauncherError("{} lock SHA-256 is invalid".format(key))
        if path.name != lock_sha:
            raise LauncherError("{} basename must equal its lock SHA-256".format(key))
        if lock_relative is None:
            raise LauncherError("{} has no lock contract".format(key))
        lock_path = checkout / lock_relative
        lock_data = _read_stable_file(
            lock_path, "{} lock".format(key), require_read_only=False
        )
        if _sha256(lock_data) != lock_sha:
            raise LauncherError("{} lock SHA-256 differs from disk".format(key))
        if producer_state_exists:
            return sealed_path_record(path, "venv")
        if path.exists() and not path.is_dir():
            raise LauncherError("{} must be absent or an existing venv directory".format(key))
        return None

    if kind == "tree":
        if not _is_within(path, run_root):
            raise LauncherError("{} is outside DICOW_RUN_ROOT".format(key))
        actual = sealed_path_record(path, "tree")
        expected = _fragment_record(values, key, path)
        _require_record(actual, expected, "{} fragment".format(key))
        return actual

    if kind == "file" and key == "DICOW_SPEECH_BIN":
        runtime_root = base_paths["DICOW_SPEECH_RUNTIME_ROOT"]
        if not _is_within(path, runtime_root):
            raise LauncherError("DICOW_SPEECH_BIN is outside DICOW_SPEECH_RUNTIME_ROOT")
        relative_path = values.get(key + "_RELATIVE_PATH")
        if not isinstance(relative_path, str) or not _SAFE_RELATIVE_PATH_RE.fullmatch(relative_path):
            raise LauncherError("DICOW_SPEECH_BIN_RELATIVE_PATH is invalid")
        if path != runtime_root / relative_path:
            raise LauncherError("DICOW_SPEECH_BIN differs from its archive-relative path")
        if not os.access(str(path), os.X_OK):
            raise LauncherError("DICOW_SPEECH_BIN must be executable")
        actual = sealed_path_record(path, "file")
        expected = _fragment_record(values, key, path)
        _require_record(actual, expected, "DICOW_SPEECH_BIN fragment")
        _validate_speech_canonical(expected, run_root, run_id)
        return actual

    if kind == "file" and key == "DICOW_R2_SPEECH_BIN":
        if not _is_within(path, base_paths["DICOW_SPEECH_RUNTIME_ROOT"]):
            raise LauncherError("DICOW_R2_SPEECH_BIN is outside the sealed speech runtime")
        actual = sealed_path_record(path, "file")
        expected = _fragment_record(values, key, path)
        _require_record(actual, expected, "DICOW_R2_SPEECH_BIN fragment")
        return actual

    raise LauncherError("unhandled fragment key {}".format(key))


def _effective_r2_state_path(run_root: Path, task: str) -> Path:
    if task == "R1":
        for amendment_name in (
            "R1-contract-amendment-10", "R1-contract-amendment-9",
            "R1-contract-amendment-8",
            "R1-contract-amendment-7",
            "R1-contract-amendment-6",
            "R1-contract-amendment-5",
            "R1-contract-amendment-4",
            "R1-contract-amendment-3",
            "R1-contract-amendment-2",
            "R1-contract-amendment-1",
        ):
            amendment = run_root / "task-state/{}.json".format(amendment_name)
            if amendment.exists():
                return amendment
    return run_root / "task-state/{}.json".format(task)


def _load_r2_gate_authority(
    run_root: Path,
    run_id: str,
    authority_task: str,
    gate_id: str,
    gate_relative: str,
) -> Tuple[Mapping[str, object], Mapping[str, object], Path]:
    from benchmarks.scripts.dicow.common.pins import (
        R2_GATE_TASK_SEMANTICS,
    )
    authority_path = _effective_r2_state_path(run_root, authority_task)
    authority, _ = _read_sealed_json(
        authority_path, "{} gate authority state".format(authority_task)
    )
    if (
        authority.get("schema_version") != "dicow-r2-task-state-v1"
        or authority.get("task") != authority_task
        or authority.get("state") != "done"
        or authority.get("run_id") != run_id
        or authority.get("branch_disposition") != "executed"
    ):
        raise LauncherError("{} gate authority state is invalid".format(authority_task))
    if authority.get("gate_path") != gate_relative:
        raise LauncherError("{} gate authority path is not canonical".format(authority_task))
    gate_path = _relative_sealed_path(run_root, gate_relative, "gate authority")
    gate, gate_bytes = _read_sealed_json(gate_path, "gate authority")
    if authority.get("gate_sha256") != _sha256(gate_bytes):
        raise LauncherError("{} gate authority hash differs".format(authority_task))
    try:
        from benchmarks.scripts.dicow.common.manifest import verify_gate
        verify_gate(gate_path)
    except Exception as error:
        raise LauncherError(
            "{} gate authority semantic replay failed: {}".format(authority_task, error)
        )
    decision = gate.get("decision")
    if not isinstance(decision, dict):
        raise LauncherError("{} gate authority decision is malformed".format(authority_task))
    scope = decision.get("scope")
    allowed_scopes = {
        key_scope
        for key_gate, key_scope in R2_GATE_TASK_SEMANTICS
        if key_gate == gate_id
    }
    if (
        gate.get("gate_id") != gate_id
        or gate.get("task") != authority_task
        or scope not in allowed_scopes
    ):
        raise LauncherError(
            "{} gate authority is not an authenticated {} transition".format(
                authority_task, gate_id
            )
        )
    semantics = R2_GATE_TASK_SEMANTICS[(gate_id, scope)]
    if (
        decision.get("next_task_ids") != list(semantics["next"])
        or decision.get("skip_task_ids") != list(semantics["skip"])
    ):
        raise LauncherError("{} gate authority has the wrong task transition".format(
            authority_task
        ))
    if (
        authority.get("evidence_outcome") != decision.get("evidence_outcome")
        or authority.get("next_task_ids") != decision.get("next_task_ids")
    ):
        raise LauncherError(
            "{} differs from its authenticated gate transition".format(authority_task)
        )
    return authority, decision, gate_path


def _verify_r2_skip_gate_authority(
    run_root: Path, run_id: str, task: str, state: Mapping[str, object]
) -> None:
    from benchmarks.scripts.dicow.common.pins import R2_J1_GATE_PATH, R2_J2_GATE_PATH

    gate_relative = state.get("gate_path")
    if task in {"R11", "R12"} and gate_relative == R2_J2_GATE_PATH:
        authority_task, gate_id = "R10", "J2-r2"
    else:
        authority_task, gate_id = "R4", "J1-r2"
        if gate_relative != R2_J1_GATE_PATH:
            expected = "canonical J1-r2 or J2-r2" if task in {"R11", "R12"} else "canonical J1-r2"
            raise LauncherError("{} skip gate path must be the {} path".format(
                task, expected
            ))
    authority, decision, _ = _load_r2_gate_authority(
        run_root, run_id, authority_task, gate_id, str(gate_relative)
    )
    if state.get("gate_sha256") != authority.get("gate_sha256"):
        raise LauncherError("{} skip gate hash differs from {}".format(task, authority_task))
    if state.get("evidence_outcome") != decision.get("evidence_outcome"):
        raise LauncherError(
            "{} skip outcome differs from its authenticated gate".format(task)
        )
    if task not in decision.get("skip_task_ids", []):
        raise LauncherError("{} is absent from its authenticated skip gate".format(task))


def _verify_r2_executed_gate_authority(
    run_root: Path, run_id: str, task: str
) -> None:
    from benchmarks.scripts.dicow.common.pins import (
        R2_FINAL_GATE_PATH,
        R2_GATE_TASK_SEMANTICS,
        R2_J1_GATE_PATH,
        R2_J2_GATE_PATH,
    )

    governed = {
        governed_task
        for (gate_id, _), semantics in R2_GATE_TASK_SEMANTICS.items()
        if gate_id == "J1-r2"
        for governed_task in semantics["next"] + semantics["skip"]
    }
    if task not in governed or task == "R4":
        return
    _, j1_decision, _ = _load_r2_gate_authority(
        run_root, run_id, "R4", "J1-r2", R2_J1_GATE_PATH
    )
    if task in j1_decision.get("skip_task_ids", []):
        raise LauncherError(
            "{} executes despite the authenticated J1-r2 skip decision".format(task)
        )
    j2_active = task in {"R10", "R11", "R12"}
    if task == "R13":
        r10_path = _effective_r2_state_path(run_root, "R10")
        if r10_path.exists():
            r10_state, _ = _read_sealed_json(r10_path, "R10 state")
            j2_active = r10_state.get("branch_disposition") == "executed"
    if j2_active:
        _, j2_decision, _ = _load_r2_gate_authority(
            run_root, run_id, "R10", "J2-r2", R2_J2_GATE_PATH
        )
        if task in {"R11", "R12", "R13"} and task in j2_decision.get(
            "skip_task_ids", []
        ):
            raise LauncherError(
                "{} executes despite the authenticated J2-r2 skip decision".format(task)
            )
    if task == "R13":
        _load_r2_gate_authority(
            run_root, run_id, "R13", "FINAL-r2", R2_FINAL_GATE_PATH
        )


def _verify_r2_task_dependencies(
    run_root: Path, run_id: str, task: str, state: Mapping[str, object], checkout: Path
) -> None:
    if task not in R2_TASK_DEPENDENCIES:
        raise LauncherError("unknown r2 producer task {}".format(task))
    identity = state.get("task")
    allowed_identity = (
        (
            task, "R1-contract-amendment-1", "R1-contract-amendment-2",
            "R1-contract-amendment-3", "R1-contract-amendment-4",
            "R1-contract-amendment-5", "R1-contract-amendment-6",
            "R1-contract-amendment-7", "R1-contract-amendment-8",
            "R1-contract-amendment-9", "R1-contract-amendment-10",
        )
        if task == "R1" else (task,)
    )
    if (
        state.get("schema_version") != "dicow-r2-task-state-v1"
        or identity not in allowed_identity
        or state.get("state") != "done"
        or state.get("run_id") != run_id
        or state.get("branch_disposition") not in ("executed", "skipped")
        or (
            task != "R3"
            and state.get("evidence_outcome") not in (
                "supported", "not_supported", "evidence_blocker", "unresolved"
            )
        )
    ):
        raise LauncherError("{} task state is not a typed closed r2 state".format(task))
    expected = {}
    for predecessor in R2_TASK_DEPENDENCIES[task]:
        predecessor_path = _effective_r2_state_path(run_root, predecessor)
        predecessor_state, predecessor_bytes = _read_sealed_json(
            predecessor_path, "{} predecessor state".format(predecessor)
        )
        predecessor_identity = predecessor_state.get("task")
        if predecessor == "R1" and predecessor_identity in (
            "R1-contract-amendment-1", "R1-contract-amendment-2",
            "R1-contract-amendment-3", "R1-contract-amendment-4",
            "R1-contract-amendment-5", "R1-contract-amendment-6",
            "R1-contract-amendment-7", "R1-contract-amendment-8",
            "R1-contract-amendment-9", "R1-contract-amendment-10",
        ):
            _validate_r2_state_chain(
                run_root, run_id,
                _read_sealed_json(run_root / "run-manifest.json", "run manifest")[0],
                _read_sealed_file(run_root / "run-manifest.json", "run manifest"),
                Path(__file__).resolve().parents[3],
            )
        elif predecessor_identity != predecessor:
            raise LauncherError("{} predecessor identity is wrong".format(predecessor))
        if (
            predecessor_state.get("schema_version") != "dicow-r2-task-state-v1"
            or predecessor_state.get("state") != "done"
            or predecessor_state.get("run_id") != run_id
            or predecessor_state.get("branch_disposition") not in ("executed", "skipped")
            or (
                predecessor != "R3"
                and predecessor_state.get("evidence_outcome") not in (
                    "supported", "not_supported", "evidence_blocker", "unresolved"
                )
            )
        ):
            raise LauncherError("{} predecessor state is invalid".format(predecessor))
        _verify_r2_task_dependencies(
            run_root, run_id, predecessor, predecessor_state, checkout
        )
        expected[predecessor] = _sha256(predecessor_bytes)
    if task not in ("R0", "R1") and state.get("predecessor_state_hashes") != expected:
        raise LauncherError("{} predecessor state hashes are not exact".format(task))
    if task == "R3":
        if state.get("next_task_ids") != ["R4"]:
            raise LauncherError("R3 must authorize exactly R4")
        _verify_r2_tracked_task_state(run_root, state, task, checkout)
        if state.get("branch_disposition") != "executed":
            raise LauncherError("R3 must be an executed publication state")
        _verify_r3_publication_state(run_root, run_id, state)
        if state.get("evidence_outcome") != "evidence_blocker":
            raise LauncherError(
                "R3 must publish the exact DiCoW evidence-blocker outcome"
            )
    if task == "R4":
        if state.get("branch_disposition") != "executed":
            raise LauncherError("R4 must publish an executed J1-r2 transition")
        if state.get("gate_path") != "fable-j1/gate.json":
            raise LauncherError("R4 gate path must be the canonical fable-j1/gate.json")
        gate_path = _relative_sealed_path(run_root, state.get("gate_path"), "R4 gate")
        gate, gate_bytes = _read_sealed_json(gate_path, "R4 gate")
        if state.get("gate_sha256") != _sha256(gate_bytes):
            raise LauncherError("R4 gate hash differs from fresh disk")
        try:
            from benchmarks.scripts.dicow.common.manifest import verify_gate
            verify_gate(gate_path)
        except Exception as error:
            raise LauncherError("R4 gate semantic replay failed: {}".format(error))
        decision = gate.get("decision")
        if not isinstance(decision, dict):
            raise LauncherError("R4 gate decision is malformed")
        scope = decision.get("scope")
        outcome = decision.get("evidence_outcome")
        next_tasks = decision.get("next_task_ids")
        if scope == "proceed_dicow_and_qwen":
            raise LauncherError(
                "R4 cannot proceed with DiCoW while the R3 blocker stands"
            )
        if scope == "proceed_qwen_only":
            if outcome != "evidence_blocker" or next_tasks != ["Q1"]:
                raise LauncherError("R4 Qwen-only gate has an invalid transition")
        elif scope == "revise_or_stop_all":
            if (
                outcome not in {"not_supported", "evidence_blocker", "unresolved"}
                or next_tasks != ["R13"]
            ):
                raise LauncherError("R4 stop gate has an invalid typed transition")
        else:
            raise LauncherError("R4 state does not reference an accepted J1-r2 scope")
        if (
            state.get("evidence_outcome") != outcome
            or state.get("next_task_ids") != next_tasks
        ):
            raise LauncherError(
                "R4 state differs from its authenticated J1-r2 transition"
            )
    if state.get("branch_disposition") == "executed":
        _verify_r2_executed_gate_authority(run_root, run_id, task)
    if state.get("branch_disposition") == "skipped":
        _verify_r2_skip_gate_authority(run_root, run_id, task, state)


def _verify_r2_tracked_task_state(
    run_root: Path, state: Mapping[str, object], task: str, checkout: Path
) -> None:
    allowed = R2_TASK_TRACKED_FILES.get(task)
    if allowed is None:
        raise LauncherError("{} has no launcher tracked-file contract".format(task))
    tracked = state.get("tracked_files")
    if not isinstance(tracked, dict) or set(tracked) != set(allowed):
        raise LauncherError("{} tracked-file roster differs from the frozen r2 set".format(task))

    manifest, _ = _read_sealed_json(run_root / "run-manifest.json", "run manifest")
    before_record = manifest.get("repository_before_state")
    if not isinstance(before_record, dict):
        raise LauncherError("r2 repository-before-state tuple is missing")
    before_path = _relative_sealed_path(
        run_root, before_record.get("run_path"), "repository before state"
    )
    before, _ = _read_sealed_json(before_path, "repository before state")
    before_index = {}
    for collection_name in ("untracked_worktree", "tracked_worktree"):
        records = before.get(collection_name, [])
        if not isinstance(records, list):
            raise LauncherError("repository-before-state {} is malformed".format(collection_name))
        for record in records:
            if not isinstance(record, dict) or set(record) != {
                "repo_path", "sha256", "bytes", "mode"
            }:
                raise LauncherError("repository-before-state contains a malformed tuple")
            relative = record.get("repo_path")
            if relative in before_index:
                raise LauncherError("repository-before-state repeats {}".format(relative))
            before_index[relative] = {
                "sha256": record.get("sha256"),
                "bytes": record.get("bytes"),
                "mode": record.get("mode"),
            }

    for relative in allowed:
        transition = tracked.get(relative)
        if not isinstance(transition, dict) or set(transition) != {"input", "output"}:
            raise LauncherError("{} tracked tuple is malformed for {}".format(task, relative))
        if transition.get("input") != before_index.get(relative):
            raise LauncherError("{} tracked input differs from R0 for {}".format(task, relative))
        expected = transition.get("output")
        if not isinstance(expected, dict) or set(expected) != {"sha256", "bytes", "mode"}:
            raise LauncherError("{} tracked output tuple is malformed for {}".format(task, relative))
        actual = _file_record(
            checkout / relative, "{} tracked file".format(task), require_read_only=False
        )
        actual.pop("path")
        if actual != expected:
            raise LauncherError("{} tracked output differs from disk: {}".format(task, relative))


def _r3_selected_audit_paths(
    run_root: Path, run_id: str
) -> Tuple[Path, Path, Mapping[str, object]]:
    audit_root = run_root / "pre-model-audit"
    try:
        from benchmarks.scripts.dicow.reference import inspect as r2_inspect
        replay = r2_inspect.verify_r2_audit(audit_root)
    except Exception as error:
        raise LauncherError("R3 pre-model audit replay failed: {}".format(error))
    if not isinstance(replay, dict) or not isinstance(replay.get("summary"), dict):
        raise LauncherError("R3 pre-model audit replay result is malformed")
    decision = replay["summary"].get("decision")
    if (
        replay.get("status") != "verified"
        or replay.get("run_id") != run_id
        or not isinstance(decision, dict)
        or decision.get("dicow_scope") != "evidence_blocker"
    ):
        raise LauncherError(
            "R3 pre-model audit replay does not prove the DiCoW evidence blocker"
        )
    canonical, _ = _read_sealed_json(audit_root / "canonical.json", "R3 audit selector")
    if (
        set(canonical) != {"schema_version", "run_id", "attempt", "manifest_record"}
        or canonical.get("schema_version") != "dicow-r2-pre-model-audit-canonical-v1"
        or canonical.get("run_id") != run_id
    ):
        raise LauncherError("R3 pre-model audit selector identity differs")
    attempt_value = canonical.get("attempt")
    if not isinstance(attempt_value, str):
        raise LauncherError("R3 pre-model audit selector lacks an absolute attempt")
    attempt = Path(attempt_value)
    _reject_symlink_components(attempt, "R3 selected audit attempt")
    try:
        attempt.relative_to(audit_root / "attempts")
    except ValueError:
        raise LauncherError("R3 selected audit attempt escapes the attempts root")
    manifest_path = attempt / "manifest.json"
    manifest_record = _file_record(manifest_path, "R3 selected audit manifest")
    manifest_record.pop("path")
    expected = canonical.get("manifest_record")
    if not isinstance(expected, dict) or set(expected) != {"sha256", "bytes"}:
        raise LauncherError("R3 selected audit manifest record is malformed")
    if {key: manifest_record[key] for key in ("sha256", "bytes")} != expected:
        raise LauncherError("R3 selected audit manifest tuple differs")
    selected, _ = _read_sealed_json(manifest_path, "R3 selected audit manifest")
    if (
        selected.get("schema_version") != "dicow-r2-pre-model-audit-manifest-v1"
        or selected.get("run_id") != run_id
    ):
        raise LauncherError("R3 selected audit manifest identity differs")
    spec_path = _relative_sealed_path(
        run_root,
        R2_R3_FIXED_SOURCE_PATHS[R2_R3_ACTIVE_SPEC_SOURCE_KEY],
        "R3 active audit spec",
    )
    spec_record = _file_record(spec_path, "R3 active audit spec")
    expected_spec_record = {
        "bytes": spec_record["bytes"], "sha256": spec_record["sha256"]
    }
    if spec_record.get("mode") != "0444" or selected.get("spec_record") != expected_spec_record:
        raise LauncherError(
            "R3 selected audit manifest does not bind the active frozen spec"
        )
    return manifest_path, attempt / "audit/model-identities.json", replay


def _verify_r3_publication_state(
    run_root: Path, run_id: str, state: Mapping[str, object]
) -> None:
    manifest, manifest_bytes = _read_sealed_json(run_root / "run-manifest.json", "run manifest")
    selected_manifest_path, identities_path, _ = _r3_selected_audit_paths(
        run_root, run_id
    )
    plan = manifest.get("plan_contract")
    if not isinstance(plan, dict) or not isinstance(plan.get("sha256"), str):
        raise LauncherError("R3 cannot resolve the plan contract hash")
    effective_r1_path = _effective_r2_state_path(run_root, "R1")
    expected_sources = {
        "plan_contract": plan["sha256"],
        "run_manifest": _sha256(manifest_bytes),
        "R1_effective_state": _sha256(_read_sealed_file(effective_r1_path, "effective R1 state")),
        "R2_state": _sha256(_read_sealed_file(run_root / "task-state/R2.json", "R2 state")),
    }
    for key, relative in R2_R3_FIXED_SOURCE_PATHS.items():
        source_path = _relative_sealed_path(run_root, relative, "R3 source {}".format(key))
        expected_sources[key] = _sha256(_read_sealed_file(source_path, "R3 source {}".format(key)))
        if _mode(source_path) != "0444":
            raise LauncherError("R3 fixed source {} must have mode 0444".format(key))
    expected_sources["pre_model_audit_manifest"] = _sha256(
        _read_sealed_file(selected_manifest_path, "R3 selected audit manifest")
    )
    if tuple(expected_sources) != R2_R3_SOURCE_INPUT_KEYS:
        raise LauncherError("internal R3 source-input key order differs")
    if state.get("source_input_hashes") != expected_sources:
        raise LauncherError("R3 source_input_hashes differ from the immutable source roster")

    identity_record = _file_record(identities_path, "R3 selected model identities")
    if identity_record.pop("mode") != "0444":
        raise LauncherError("R3 selected model identities must have mode 0444")
    identity_record["path"] = str(identities_path.relative_to(run_root))
    artifacts = state.get("artifacts")
    if not isinstance(artifacts, dict) or artifacts != {"model-identities": identity_record}:
        raise LauncherError("R3 artifacts must bind exactly the selected model-identities file")

    fragment_proposal, _ = _read_sealed_json(
        run_root / "r3-runtime.staging/sealed-fragment-record.json", "R3 fragment proposal"
    )
    if set(fragment_proposal) != {"R3-runtimes.env"}:
        raise LauncherError("R3 fragment proposal roster differs")
    fragment_path = run_root / "env.d/R3-runtimes.env"
    fragment_record = _file_record(fragment_path, "R3 canonical runtime fragment")
    if fragment_record.get("mode") != "0444":
        raise LauncherError("R3 canonical runtime fragment must have mode 0444")
    fragment_record["path"] = "env.d/R3-runtimes.env"
    if fragment_record != fragment_proposal.get("R3-runtimes.env"):
        raise LauncherError("R3 canonical runtime fragment differs from its proposal")
    if state.get("sealed_fragments") != {"R3-runtimes.env": fragment_record}:
        raise LauncherError("R3 sealed_fragments roster or tuple differs")

    path_proposal, _ = _read_sealed_json(
        run_root / "r3-runtime.staging/sealed-path-records.json", "R3 path proposal"
    )
    if set(path_proposal) != set(R2_R3_SEALED_PATH_KINDS):
        raise LauncherError("R3 sealed-path proposal roster differs")
    if state.get("sealed_paths") != path_proposal:
        raise LauncherError("R3 sealed_paths roster or tuple differs")
    for key, kind in R2_R3_SEALED_PATH_KINDS.items():
        record = path_proposal[key]
        if not isinstance(record, dict) or set(record) != {"path", "sha256", "bytes", "mode"}:
            raise LauncherError("R3 sealed path {} is malformed".format(key))
        actual = sealed_path_record(Path(str(record.get("path"))), kind)
        if actual != record:
            raise LauncherError("R3 sealed path {} differs from fresh disk".format(key))


def _producer_state(
    run_root: Path, run_id: str, producer: str, checkout: Optional[Path] = None
) -> Optional[Mapping[str, object]]:
    path = run_root / "task-state" / "{}.json".format(producer)
    if path.is_symlink():
        raise LauncherError("{} task state may not be a symlink".format(producer))
    if not path.exists():
        return None
    state, _ = _read_sealed_json(path, "{} task state".format(producer))
    expected_schema = (
        "dicow-r2-task-state-v1"
        if producer.startswith(("R", "Q"))
        else "dicow-task-state-v1"
    )
    if (
        state.get("schema_version") != expected_schema
        or state.get("task") != producer
        or state.get("state") != "done"
        or state.get("branch_disposition") != "executed"
        or state.get("run_id") != run_id
    ):
        raise LauncherError("{} task state cannot authorize fragments".format(producer))
    if producer.startswith(("R", "Q")):
        _verify_r2_task_dependencies(
            run_root, run_id, producer, state,
            _checkout_root() if checkout is None else checkout.resolve(),
        )
    if not isinstance(state.get("sealed_fragments"), dict) or not isinstance(
        state.get("sealed_paths"), dict
    ):
        raise LauncherError("{} task state lacks sealed fragment/path evidence".format(producer))
    return state


def _validate_producer_evidence(
    name: str,
    fragment_record: Mapping[str, object],
    resource_records: Mapping[str, Mapping[str, object]],
    state: Mapping[str, object],
) -> None:
    expected_fragment = dict(fragment_record)
    expected_fragment["path"] = "env.d/{}".format(name)
    sealed_fragments = state["sealed_fragments"]
    _require_record(expected_fragment, sealed_fragments.get(name), "{} sealed fragment".format(name))
    sealed_paths = state["sealed_paths"]
    for key, record in resource_records.items():
        _require_record(record, sealed_paths.get(key), "{} sealed path".format(key))


def _validate_scoring_venv_state(
    base_paths: Mapping[str, Path], run_id: str, profile: str
) -> None:
    if profile != "scoring":
        return
    run_root = base_paths["DICOW_RUN_ROOT"]
    state = _producer_state(run_root, run_id, "T1")
    if state is None:
        return
    actual = sealed_path_record(base_paths["DICOW_SCORING_VENV"], "venv")
    _require_record(
        actual,
        state["sealed_paths"].get("DICOW_SCORING_VENV"),
        "DICOW_SCORING_VENV sealed path",
    )


def _load_fragments(
    run_root: Path,
    run_id: str,
    profile: str,
    base_paths: Mapping[str, Path],
    checkout: Path,
) -> Tuple[Dict[str, Dict[str, str]], Set[str]]:
    env_directory = run_root / "env.d"
    _reject_symlink_components(env_directory, "env.d")
    if not env_directory.exists():
        return {}, set()
    if not env_directory.is_dir():
        raise LauncherError("env.d must be a directory")

    fragments = {}  # type: Dict[str, Dict[str, str]]
    all_keys = set()  # type: Set[str]
    for name in sorted(os.listdir(str(env_directory))):
        if name not in FRAGMENT_KEYS:
            raise LauncherError("env.d contains unknown fragment {}".format(name))
        path = env_directory / name
        fragment_bytes = _read_sealed_file(path, "fragment {}".format(name))
        if _mode(path) != "0444":
            raise LauncherError("fragment {} must have exact mode 0444".format(name))
        parsed = _parse_assignments(
            fragment_bytes,
            FRAGMENT_KEYS[name],
            "fragment {}".format(name),
        )
        duplicates = all_keys.intersection(parsed)
        if duplicates:
            raise LauncherError("fragment keys are duplicated: {}".format(", ".join(sorted(duplicates))))
        spec = FRAGMENT_RESOURCES[name]
        producer = spec["producer"]
        state = _producer_state(run_root, run_id, producer, checkout)
        fragment_record = {
            "path": str(path),
            "sha256": _sha256(fragment_bytes),
            "bytes": len(fragment_bytes),
            "mode": _mode(path),
        }
        resource_records = {}  # type: Dict[str, Mapping[str, object]]
        if name in PROFILE_FRAGMENTS[profile]:
            for key, kind, lock_relative in spec["resources"]:
                record = _validate_resource(
                    parsed,
                    key,
                    kind,
                    lock_relative,
                    base_paths,
                    checkout,
                    state is not None,
                    run_id,
                )
                if record is not None:
                    resource_records[key] = record
            if state is not None:
                _validate_producer_evidence(name, fragment_record, resource_records, state)
        elif state is not None:
            expected_fragment = dict(fragment_record)
            expected_fragment["path"] = "env.d/{}".format(name)
            _require_record(
                expected_fragment,
                state["sealed_fragments"].get(name),
                "{} sealed fragment".format(name),
            )
        all_keys.update(parsed)
        fragments[name] = parsed
    return fragments, all_keys


def load_profile(
    env_file: Path, profile: str, checkout_root: Optional[Path] = None
) -> Dict[str, str]:
    """Validate the sealed files and return the exact child environment."""

    if profile not in PROFILE_FRAGMENTS:
        raise LauncherError("unknown profile {}".format(profile))
    env_file = Path(env_file)
    checkout = (checkout_root or _checkout_root()).resolve()
    base_bytes = _read_sealed_file(env_file, "base env")
    if _mode(env_file) != "0444":
        raise LauncherError("base env must have exact mode 0444")
    base = _parse_assignments(base_bytes, BASE_KEYS, "base env")
    base_paths = _validate_base(base, env_file, checkout)
    _validate_run_binding(base, base_bytes, env_file, base_paths, checkout)
    _validate_scoring_venv_state(base_paths, base["DICOW_RUN_ID"], profile)
    fragments, _ = _load_fragments(
        base_paths["DICOW_RUN_ROOT"],
        base["DICOW_RUN_ID"],
        profile,
        base_paths,
        checkout,
    )

    required = REQUIRED_PROFILE_FRAGMENT.get(profile)
    if required is not None and required not in fragments:
        raise LauncherError("profile {} requires sealed fragment {}".format(profile, required))

    child = {
        "PATH": SYSTEM_PATH if profile in ("base", "diarizer") else TOOL_PATH,
        "HOME": EMPTY_HOME,
        "LC_ALL": "C",
        "LANG": "C",
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONNOUSERSITE": "1",
        "PYTHONUTF8": "1",
    }
    child.update(base)
    for fragment_name in PROFILE_FRAGMENTS[profile]:
        if fragment_name in fragments:
            for key, _, _ in FRAGMENT_RESOURCES[fragment_name]["resources"]:
                child[key] = fragments[fragment_name][key]

    if profile in (
        "scoring", "aligner", "reference", "mlx",
        "r2-qwen", "r2-aligner-bootstrap", "r2-reference-bootstrap",
        "r2-aligner", "r2-reference", "r2-mlx",
    ):
        venv_key = {
            "scoring": "DICOW_SCORING_VENV",
            "aligner": "DICOW_ALIGNER_VENV",
            "reference": "DICOW_REFERENCE_VENV",
            "mlx": "DICOW_MLX_VENV",
            "r2-qwen": "DICOW_QWEN_APPLE_VENV",
            "r2-aligner-bootstrap": "DICOW_R2_ALIGNER_VENV",
            "r2-reference-bootstrap": "DICOW_R2_REFERENCE_VENV",
            "r2-aligner": "DICOW_R2_ALIGNER_VENV",
            "r2-reference": "DICOW_R2_REFERENCE_VENV",
            "r2-mlx": "DICOW_R2_MLX_VENV",
        }[profile]
        child["UV_CACHE_DIR"] = base["DICOW_UV_CACHE"]
        child["UV_PROJECT_ENVIRONMENT"] = child[venv_key]

    if profile.startswith("r2-") and "DICOW_R2_SPEECH_BIN" in child:
        child["DICOW_SPEECH_BIN"] = child["DICOW_R2_SPEECH_BIN"]
    if profile.startswith("r2-") and "DICOW_R2_ALIGNER_VENV" in child:
        child["DICOW_ALIGNER_VENV"] = child["DICOW_R2_ALIGNER_VENV"]
    if profile.startswith("r2-") and "DICOW_R2_REFERENCE_VENV" in child:
        child["DICOW_REFERENCE_VENV"] = child["DICOW_R2_REFERENCE_VENV"]

    if profile in ("r2-diarizer-bootstrap", "r2-diarizer"):
        child["PATH"] = SYSTEM_PATH
        child["QWEN3_CACHE_DIR"] = base["DICOW_SPEECH_CACHE"]
        for key in (
            "HF_HOME", "DICOW_UV_CACHE", "DICOW_SCORING_VENV",
            "DICOW_SPEECH_CACHE", "DICOW_SPEECH_RUNTIME_ROOT",
            "DICOW_R2_ALIGNER_VENV", "DICOW_R2_REFERENCE_VENV",
        ):
            child.pop(key, None)

    if profile == "diarizer":
        # The speech runtime has its own cache contract.  Do not let libraries fall
        # back to the Hugging Face or user cache through unrelated base variables.
        for key in (
            "HF_HOME",
            "DICOW_UV_CACHE",
            "DICOW_SCORING_VENV",
            "DICOW_SPEECH_CACHE",
            "DICOW_SPEECH_RUNTIME_ROOT",
        ):
            child.pop(key, None)
        child["QWEN3_CACHE_DIR"] = base["DICOW_SPEECH_CACHE"]

    return child


def _argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env-file", required=True, type=Path)
    parser.add_argument("--profile", required=True, choices=tuple(PROFILE_FRAGMENTS))
    parser.add_argument("command", nargs=argparse.REMAINDER)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = _argument_parser()
    arguments = parser.parse_args(argv)
    command = list(arguments.command)
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("a command is required after --")
    try:
        environment = load_profile(arguments.env_file, arguments.profile)
        os.execvpe(command[0], command, environment)
    except LauncherError as error:
        parser.error(str(error))
    except OSError as error:
        parser.error("cannot execute {}: {}".format(command[0], error))
    return 2


if __name__ == "__main__":
    sys.exit(main())
