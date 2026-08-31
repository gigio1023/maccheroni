#!/usr/bin/env python3
"""Fail-closed resource and create-only materialization primitives for DiCoW E0.

This module deliberately contains no downloader or model-specific inspection code.
``reference.inspect`` owns those decisions and uses the small substrate here to keep
path reads, byte accounting, locking, and final promotion replayable.
"""

from __future__ import annotations

import dataclasses
import ctypes
import fcntl
import hashlib
import json
import math
import os
import re
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, Mapping, Optional, Sequence, Tuple


HEADROOM_BYTES = 2**31
REPOSITORY_ROOT = Path(__file__).resolve().parents[4]
RESOURCE_CATEGORIES = (
    "source",
    "converted_output",
    "environment",
    "named_golden",
    "staging",
)
CONVERSION_PAYLOAD_BYTES = {
    "turbo_fp32_control": 3_235_512_320,
    "turbo_bf16_core": 1_622_743_040,
    "turbo_bf16_sensitive": 1_623_142_400,
    "dicow_fp32_control": 3_236_864_000,
    "dicow_bf16_core": 1_623_418_880,
    "dicow_bf16_sensitive": 1_624_494_080,
}
CONVERSION_PAYLOAD_TOTAL_BYTES = 12_966_174_720
CONDITIONAL_DICOW_BUDGET_NOTE = (
    "conditional budget input: assumes the intended 10-tensor CTC omission and "
    "projection tie; it is not evidence that either conversion invariant passed"
)

# r2 adds candidate-coupled execution and writer budgets without changing the E0
# ResourcePolicy contract above.  A writer retains only one phase at a time, so its
# required free space is the largest phase sum plus the same exact 2 GiB headroom.
R2_PHASE_BYTE_FIELDS = (
    "final_bytes",
    "staging_bytes",
    "retained_failure_bytes",
    "retry_bytes",
    "serializer_bytes",
    "simultaneously_retained_prior_outputs",
)
R2_EXECUTION_FIELDS = (
    "duration_seconds",
    "requested_output_tokens",
    "effective_output_tokens",
    "context_tokens",
    "prompt_tokens",
    "timeout_seconds",
    "maximum_attempts",
    "peak_resident_bytes",
    "cancellation_contract",
    "concurrent_model_processes",
)
R2_REQUIRED_RESOURCE_WRITERS = (
    "r3_audit_acquisition",
    "r5_natural_pack",
    "r7_turbo",
    "r8_dicow_mlc",
    "r9_dicow_v3_3",
    "q1_qwen_environment_source",
    "q2_asr_reuse",
    "q2_asr_direct_conversion",
    "q2_aligner_conversion",
    "r11_five_process_ctc_receipts",
    "r12_dicow_mlc_bf16",
    "r12_dicow_v3_3_bf16",
)
R2_REQUIRED_CONSTRAINT_PATHS = (
    "qwen_asr",
    "qwen_aligner",
    "turbo",
    "dicow_mlc",
    "dicow_v3_3",
)
R2_TIMESTAMP_CONTRACT = {
    "truth_authority": "google/fleurs@70bb2e84b976b7e960aa89f1c648e09c59f894dd_row_2005_pcm16",
    "sample_rate_hz": 16_000,
    "annotation_resolution_samples": 1,
    "boundary_tolerance_samples": 1_280,
    "boundary_tolerance_ms": 80,
    "interval_semantics": "half_open_samples",
    "attribution_rule": "unique_source_utterance_overlap_within_boundary_tolerance",
    "self_truth_forbidden": "Qwen/Qwen3-ForcedAligner-0.6B-hf",
}


class PreflightError(RuntimeError):
    """A typed, fail-closed preflight result."""

    def __init__(
        self,
        code: str,
        detail: str,
        *,
        evidence_outcome: str = "evidence_blocker",
        branch_verdict: str = "revise",
    ) -> None:
        super().__init__("{}: {}".format(code, detail))
        self.code = code
        self.detail = detail
        self.evidence_outcome = evidence_outcome
        self.branch_verdict = branch_verdict

    def as_record(self) -> Dict[str, str]:
        return {
            "code": self.code,
            "detail": self.detail,
            "evidence_outcome": self.evidence_outcome,
            "branch_verdict": self.branch_verdict,
        }


def _fail(code: str, detail: str) -> None:
    raise PreflightError(code, detail)


def canonical_json_bytes(value: Any) -> bytes:
    """Encode finite JSON deterministically."""

    try:
        rendered = json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
    except (TypeError, ValueError) as error:
        _fail("invalid_json", str(error))
    return (rendered + "\n").encode("utf-8")


def _reject_constant(value: str) -> None:
    _fail("nonfinite_json", "non-finite JSON number {} is forbidden".format(value))


def _unique_object(pairs: Iterable[Tuple[str, Any]]) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            _fail("duplicate_json_key", "duplicate JSON object key {!r}".format(key))
        result[key] = value
    return result


def _assert_finite_json(value: Any) -> None:
    if isinstance(value, float) and not math.isfinite(value):
        _fail("nonfinite_json", "overflowed or non-finite JSON number is forbidden")
    if isinstance(value, list):
        for item in value:
            _assert_finite_json(item)
    elif isinstance(value, dict):
        for item in value.values():
            _assert_finite_json(item)


def validate_external_path(
    path: Path,
    label: str,
    *,
    must_exist: bool = True,
    forbidden_roots: Sequence[Path] = (),
) -> Path:
    """Validate an absolute normalized path and every existing path component.

    Missing tail components are permitted only when ``must_exist`` is false. No
    ``resolve`` call is used because resolving first would hide a symlink boundary.
    """

    path = Path(path)
    rendered = str(path)
    if not path.is_absolute() or rendered == os.sep or os.path.normpath(rendered) != rendered:
        _fail("invalid_external_path", "{} must be absolute, normalized, and non-root".format(label))
    forbidden_identities = set()
    for forbidden in forbidden_roots:
        forbidden = Path(forbidden)
        if not forbidden.is_absolute():
            _fail("invalid_external_path", "forbidden root must be absolute")
        try:
            path.relative_to(forbidden)
        except ValueError:
            pass
        else:
            _fail("path_not_external", "{} is inside forbidden root {}".format(label, forbidden))
        try:
            forbidden_info = os.lstat(str(forbidden))
        except OSError as error:
            _fail("invalid_external_path", "cannot inspect forbidden root {}: {}".format(forbidden, error))
        if stat.S_ISLNK(forbidden_info.st_mode):
            _fail("invalid_external_path", "forbidden root must not be a symlink")
        forbidden_identities.add((forbidden_info.st_dev, forbidden_info.st_ino))

    current = Path(path.anchor)
    missing = False
    for component in path.parts[1:]:
        current = current / component
        if missing:
            continue
        try:
            info = os.lstat(str(current))
        except FileNotFoundError:
            missing = True
            continue
        except OSError as error:
            _fail("path_inspection_failed", "{}: {}".format(label, error))
        if stat.S_ISLNK(info.st_mode):
            _fail("symlink_component", "{} contains symlink component {}".format(label, current))
        if (info.st_dev, info.st_ino) in forbidden_identities:
            _fail("path_not_external", "{} resolves inside a forbidden root".format(label))
    if must_exist and missing:
        _fail("missing_path", "{} does not exist".format(label))
    return path


def validate_runtime_path(path: Path, label: str, *, must_exist: bool = True) -> Path:
    """Validate an experiment runtime path outside the tracked checkout."""

    return validate_external_path(
        path,
        label,
        must_exist=must_exist,
        forbidden_roots=(REPOSITORY_ROOT,),
    )


def _open_parent_no_follow(path: Path, label: str) -> Tuple[int, str]:
    """Open every parent with openat/O_NOFOLLOW and return the stable parent fd."""

    path = Path(path)
    rendered = str(path)
    if not path.is_absolute() or rendered == os.sep or os.path.normpath(rendered) != rendered:
        _fail("invalid_external_path", "{} must be absolute, normalized, and non-root".format(label))
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path.anchor, directory_flags)
    except OSError as error:
        _fail("stable_open_failed", "cannot open root for {}: {}".format(label, error))
    try:
        for component in path.parts[1:-1]:
            try:
                child = os.open(component, directory_flags, dir_fd=descriptor)
            except OSError as error:
                _fail("stable_open_failed", "cannot open parent of {} without following links: {}".format(label, error))
            os.close(descriptor)
            descriptor = child
        return descriptor, path.name
    except BaseException:
        os.close(descriptor)
        raise


def stable_read(path: Path, label: str = "file") -> Tuple[bytes, os.stat_result]:
    """Read one regular file without following links and reject read-time drift."""

    path = validate_external_path(path, label)
    parent_descriptor, name = _open_parent_no_follow(path, label)
    try:
        try:
            named_before = os.lstat(name, dir_fd=parent_descriptor)
        except OSError as error:
            _fail("stable_read_failed", "cannot inspect {} before opening it: {}".format(label, error))
        if not stat.S_ISREG(named_before.st_mode):
            _fail("not_regular_file", "{} must be a regular file".format(label))
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
        try:
            descriptor = os.open(name, flags, dir_fd=parent_descriptor)
        except OSError as error:
            _fail("stable_read_failed", "cannot open {}: {}".format(label, error))
        while True:
            try:
                before = os.fstat(descriptor)
                if not stat.S_ISREG(before.st_mode):
                    _fail("not_regular_file", "{} must be a regular file".format(label))
                if (before.st_dev, before.st_ino, before.st_mode) != (
                    named_before.st_dev, named_before.st_ino, named_before.st_mode,
                ):
                    _fail("unstable_read", "{} changed before it was opened".format(label))
                chunks = []
                while True:
                    chunk = os.read(descriptor, 1024 * 1024)
                    if not chunk:
                        break
                    chunks.append(chunk)
                after = os.fstat(descriptor)
                break
            finally:
                os.close(descriptor)
        try:
            observed = os.lstat(name, dir_fd=parent_descriptor)
        except OSError as error:
            _fail("stable_read_failed", "cannot restat {}: {}".format(label, error))
    finally:
        os.close(parent_descriptor)
    identity = lambda item: (item.st_dev, item.st_ino, item.st_size, item.st_mtime_ns, item.st_mode)
    if identity(named_before) != identity(before) or identity(before) != identity(after) or identity(after) != identity(observed):
        _fail("unstable_read", "{} changed while it was read".format(label))
    validate_external_path(path, label)
    named = os.lstat(str(path))
    if identity(named) != identity(observed):
        _fail("unstable_read", "{} pathname changed while it was read".format(label))
    return b"".join(chunks), after


def _strict_json_bytes(data: bytes, label: str) -> Any:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as error:
        _fail("invalid_json", "{} is not UTF-8: {}".format(label, error))
    try:
        value = json.loads(
            text,
            object_pairs_hook=_unique_object,
            parse_constant=_reject_constant,
        )
    except PreflightError:
        raise
    except (json.JSONDecodeError, ValueError) as error:
        _fail("invalid_json", "{}: {}".format(label, error))
    _assert_finite_json(value)
    return value


def strict_load_json(path: Path, label: str = "JSON file") -> Any:
    data, _ = stable_read(path, label)
    return _strict_json_bytes(data, label)


def _mode(info: os.stat_result) -> str:
    return "0{:03o}".format(stat.S_IMODE(info.st_mode))


def file_record(path: Path, *, immutable: bool = False) -> Dict[str, Any]:
    data, info = stable_read(path, str(path))
    if immutable and stat.S_IMODE(info.st_mode) & 0o222:
        _fail("mutable_materialization", "file is writable: {}".format(path))
    return {
        "kind": "file",
        "bytes": len(data),
        "mode": _mode(info),
        "sha256": hashlib.sha256(data).hexdigest(),
    }


def _immutable_json_with_record(path: Path, label: str) -> Tuple[Any, Mapping[str, Any]]:
    data, info = stable_read(path, label)
    if stat.S_IMODE(info.st_mode) & 0o222:
        _fail("mutable_materialization", "file is writable: {}".format(path))
    record = {
        "kind": "file",
        "bytes": len(data),
        "mode": _mode(info),
        "sha256": hashlib.sha256(data).hexdigest(),
    }
    return _strict_json_bytes(data, label), record


def _relative_link_target(root: Path, link: Path, target: str) -> Path:
    if os.path.isabs(target):
        _fail("unsafe_tree_symlink", "absolute internal symlink target: {}".format(link))
    normalized = Path(os.path.normpath(str(link.parent / target)))
    try:
        normalized.relative_to(root)
    except ValueError:
        _fail("unsafe_tree_symlink", "internal symlink escapes tree: {}".format(link))
    if not normalized.exists() and not normalized.is_symlink():
        _fail("dangling_tree_symlink", "internal symlink target is missing: {}".format(link))
    return normalized


def tree_manifest(root: Path, *, immutable: bool = False) -> Dict[str, Any]:
    """Return a deterministic physical tree inventory.

    Relative symlinks are included as link records. They must resolve inside the tree;
    walking never follows them.
    """

    root = validate_external_path(root, "tree root")
    root_info = os.lstat(str(root))
    if not stat.S_ISDIR(root_info.st_mode):
        _fail("not_directory", "tree root must be a directory")
    if immutable and stat.S_IMODE(root_info.st_mode) & 0o222:
        _fail("mutable_materialization", "tree root is writable: {}".format(root))

    entries = []
    directory_snapshots: Dict[str, Tuple[int, int, int, int, int, int]] = {}
    entry_snapshots: Dict[str, Tuple[int, int, int, int, int, int]] = {}
    directory_identity = lambda item: (
        item.st_dev,
        item.st_ino,
        item.st_size,
        item.st_mtime_ns,
        item.st_ctime_ns,
        item.st_mode,
    )
    entry_identity = directory_identity
    total_bytes = 0
    for parent, directories, files in os.walk(str(root), topdown=True, followlinks=False):
        parent_path = Path(parent)
        parent_before = os.lstat(str(parent_path))
        if not stat.S_ISDIR(parent_before.st_mode):
            _fail("unstable_tree", "walked parent is no longer a directory: {}".format(parent_path))
        if immutable and stat.S_IMODE(parent_before.st_mode) & 0o222:
            _fail("mutable_materialization", "directory is writable: {}".format(parent_path))
        if parent_path == root and directory_identity(parent_before) != directory_identity(root_info):
            _fail("unstable_tree", "tree root changed before inventory")
        directory_snapshots[str(parent_path)] = directory_identity(parent_before)
        names = sorted(directories + files)
        directories[:] = []
        for name in names:
            path = parent_path / name
            relative = path.relative_to(root).as_posix()
            info = os.lstat(str(path))
            mode = _mode(info)
            if stat.S_ISLNK(info.st_mode):
                target = os.readlink(str(path))
                _relative_link_target(root, path, target)
                entries.append({"path": relative, "kind": "symlink", "mode": mode, "target": target})
                entry_snapshots[str(path)] = entry_identity(info)
            elif stat.S_ISDIR(info.st_mode):
                if immutable and stat.S_IMODE(info.st_mode) & 0o222:
                    _fail("mutable_materialization", "directory is writable: {}".format(path))
                entries.append({"path": relative, "kind": "directory", "mode": mode})
                directories.append(name)
            elif stat.S_ISREG(info.st_mode):
                data, stable_info = stable_read(path, str(path))
                if immutable and stat.S_IMODE(stable_info.st_mode) & 0o222:
                    _fail("mutable_materialization", "file is writable: {}".format(path))
                record = {
                    "kind": "file",
                    "bytes": len(data),
                    "mode": _mode(stable_info),
                    "sha256": hashlib.sha256(data).hexdigest(),
                }
                total_bytes += int(record["bytes"])
                entries.append({"path": relative, **record})
                entry_snapshots[str(path)] = entry_identity(stable_info)
            else:
                _fail("unsupported_tree_entry", "unsupported entry: {}".format(path))
        parent_after = os.lstat(str(parent_path))
        if directory_identity(parent_before) != directory_identity(parent_after):
            _fail("unstable_tree", "directory changed while it was inventoried: {}".format(parent_path))
    for directory, before_identity in directory_snapshots.items():
        try:
            after_info = os.lstat(directory)
        except OSError as error:
            _fail("unstable_tree", "directory vanished after inventory: {}".format(error))
        if before_identity != directory_identity(after_info):
            _fail("unstable_tree", "directory changed during tree inventory: {}".format(directory))
    for entry, before_identity in entry_snapshots.items():
        try:
            after_info = os.lstat(entry)
        except OSError as error:
            _fail("unstable_tree", "entry vanished after inventory: {}".format(error))
        if before_identity != entry_identity(after_info):
            _fail("unstable_tree", "entry changed during tree inventory: {}".format(entry))
    encoded = canonical_json_bytes(entries)
    return {
        "kind": "tree",
        "root_mode": _mode(root_info),
        "payload_bytes": total_bytes,
        "entry_count": len(entries),
        "tree_sha256": hashlib.sha256(encoded).hexdigest(),
        "entries": entries,
    }


def artifact_record(path: Path, *, immutable: bool = False) -> Dict[str, Any]:
    path = validate_external_path(path, "artifact")
    info = os.lstat(str(path))
    if stat.S_ISREG(info.st_mode):
        return file_record(path, immutable=immutable)
    if stat.S_ISDIR(info.st_mode):
        return tree_manifest(path, immutable=immutable)
    _fail("unsupported_artifact", "artifact must be a regular file or directory")


@dataclasses.dataclass(frozen=True)
class ResourceComponent:
    name: str
    category: str
    declared_bytes: int
    final_path: Path
    expected_record: Optional[Mapping[str, Any]] = None
    staging_group: Optional[str] = None
    record_kind: str = "immutable_artifact"


@dataclasses.dataclass(frozen=True)
class ResourcePolicy:
    components: Tuple[ResourceComponent, ...]
    required_names: Tuple[str, ...]
    headroom_bytes: int = HEADROOM_BYTES


def sealed_venv_component_from_state(
    state_path: Path,
    sealed_key: str,
    component_name: str,
    *,
    expected_task: str,
    expected_run_id: str,
) -> ResourceComponent:
    """Bind an environment component to its immutable producer task state."""

    state, _ = _completed_task_state(
        state_path,
        expected_task=expected_task,
        expected_run_id=expected_run_id,
        label="venv producer state",
    )
    sealed_paths = state.get("sealed_paths")
    record = sealed_paths.get(sealed_key) if isinstance(sealed_paths, dict) else None
    if not isinstance(record, dict) or set(record) != {"path", "sha256", "bytes", "mode"}:
        _fail("resource_formula_unresolved", "producer state lacks full sealed record {}".format(sealed_key))
    if (
        not isinstance(record["path"], str)
        or not isinstance(record["sha256"], str)
        or not re.fullmatch(r"[0-9a-f]{64}", record["sha256"])
        or not isinstance(record["bytes"], int)
        or isinstance(record["bytes"], bool)
        or record["bytes"] <= 0
        or not isinstance(record["mode"], str)
        or not re.fullmatch(r"0[0-7]{3}", record["mode"])
    ):
        _fail("resource_formula_unresolved", "sealed venv record fields are invalid")
    final_path = validate_runtime_path(Path(record["path"]), sealed_key, must_exist=False)
    return ResourceComponent(
        component_name,
        "environment",
        record["bytes"],
        final_path,
        expected_record=dict(record),
        record_kind="sealed_venv",
    )


def _completed_task_state(
    state_path: Path,
    *,
    expected_task: str,
    expected_run_id: str,
    label: str,
) -> Tuple[Mapping[str, Any], Mapping[str, Any]]:
    if (
        not isinstance(expected_task, str)
        or not expected_task
        or not isinstance(expected_run_id, str)
        or not expected_run_id
    ):
        _fail("resource_formula_unresolved", "producer task/run identity is invalid")
    state_path = validate_runtime_path(state_path, label)
    state, record = _immutable_json_with_record(state_path, label)
    if (
        not isinstance(state, dict)
        or state.get("schema_version") != "dicow-task-state-v1"
        or state.get("state") != "done"
        or state.get("branch_disposition") != "executed"
        or state.get("task") != expected_task
        or state.get("run_id") != expected_run_id
    ):
        _fail("resource_formula_unresolved", "{} is not the expected completed task state".format(label))
    return state, record


def _json_pointer(value: Any, pointer: Sequence[str], label: str) -> Any:
    current = value
    if not pointer:
        _fail("resource_formula_unresolved", "{} JSON pointer is empty".format(label))
    for key in pointer:
        if not isinstance(key, str) or not key or not isinstance(current, dict) or key not in current:
            _fail("resource_formula_unresolved", "{} JSON pointer is unresolved".format(label))
        current = current[key]
    return current


def _derived_resource_bytes(
    derivation: Mapping[str, Any],
    expected_record: Optional[Mapping[str, Any]],
) -> int:
    kind = derivation.get("kind")
    if kind == "sealed_path_bytes":
        if set(derivation) != {"kind", "bytes"} or not isinstance(expected_record, Mapping):
            _fail("resource_formula_unresolved", "sealed-path derivation shape differs")
        value = derivation["bytes"]
        if not isinstance(value, int) or isinstance(value, bool) or value <= 0 or value != expected_record.get("bytes"):
            _fail("resource_formula_unresolved", "sealed-path derivation differs from expected record")
    else:
        _fail("resource_formula_unresolved", "unknown resource byte derivation")
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        _fail("resource_formula_unresolved", "derived resource bytes are invalid")
    return value


def parse_resource_ledger_v2(
    ledger_path: Path,
    *,
    expected_ledger_record: Mapping[str, Any],
    required_names: Mapping[str, str],
    expected_final_paths: Mapping[str, Path],
    expected_task: str,
    expected_run_id: str,
    expected_provenance_path: Path,
) -> Tuple[ResourceComponent, ...]:
    """Parse a provenance-bound future-resource ledger without trusting byte fields.

    Each component points into the caller-fixed immutable producer task state. R1 can
    replay a sealed environment record. It deliberately refuses named-golden rows:
    this run has no revised-plan T8R vocabulary or tracked serializer/calculator whose
    code can recompute their future maximum writes. The ledger cannot create that
    authority by asserting shapes, byte caps, paths, or hashes itself.
    """

    ledger_path = validate_runtime_path(ledger_path, "resource ledger v2")
    ledger, actual_ledger_record = _immutable_json_with_record(ledger_path, "resource ledger v2")
    if actual_ledger_record != expected_ledger_record:
        _fail("resource_formula_unresolved", "resource ledger v2 tuple differs from its pre-lock fingerprint")
    if not isinstance(ledger, Mapping) or set(ledger) != {"schema_version", "components"}:
        _fail("resource_formula_unresolved", "resource ledger v2 shape differs")
    if ledger.get("schema_version") != "dicow-e0-future-resource-ledger-v2":
        _fail("resource_formula_unresolved", "resource ledger v2 schema differs")
    rows = ledger.get("components")
    if (
        not isinstance(required_names, Mapping)
        or any(not isinstance(name, str) or not name or category not in ("environment", "named_golden") for name, category in required_names.items())
    ):
        _fail("resource_formula_unresolved", "required resource ledger identities are invalid")
    if not isinstance(expected_final_paths, Mapping) or set(expected_final_paths) != set(required_names):
        _fail("resource_formula_unresolved", "caller-fixed final-path coverage differs")
    fixed_final_paths = {
        name: validate_runtime_path(Path(path), name + " fixed final", must_exist=False)
        for name, path in expected_final_paths.items()
    }
    if not isinstance(rows, list) or len(rows) != len(required_names):
        _fail("resource_formula_unresolved", "resource ledger v2 coverage differs")
    provenance_path = validate_runtime_path(
        expected_provenance_path,
        "resource ledger producer state",
    )
    producer_state, producer_record = _completed_task_state(
        provenance_path,
        expected_task=expected_task,
        expected_run_id=expected_run_id,
        label="resource ledger producer state",
    )
    components = []
    seen = set()
    for row in rows:
        if not isinstance(row, Mapping) or set(row) != {
            "name", "category", "final_path", "expected_record", "staging_group",
            "record_kind", "provenance", "derivation",
        }:
            _fail("resource_formula_unresolved", "resource ledger v2 component shape differs")
        name = row["name"]
        if not isinstance(name, str) or not name:
            _fail("resource_formula_unresolved", "resource ledger v2 name is invalid")
        if name in seen or name not in required_names or row["category"] != required_names[name]:
            _fail("resource_formula_unresolved", "resource ledger v2 identity/category differs")
        seen.add(name)
        provenance = row["provenance"]
        if not isinstance(provenance, Mapping) or set(provenance) != {"path", "record", "json_pointer"}:
            _fail("resource_formula_unresolved", "resource provenance shape differs")
        if not isinstance(provenance["path"], str) or not isinstance(provenance["json_pointer"], list):
            _fail("resource_formula_unresolved", "resource provenance path/pointer types differ")
        row_provenance_path = validate_runtime_path(Path(provenance["path"]), name + " provenance")
        if row_provenance_path != provenance_path:
            _fail("resource_formula_unresolved", "resource provenance redirects from the fixed producer state")
        if producer_record != provenance["record"]:
            _fail("resource_formula_unresolved", "resource provenance tuple differs")
        selected = _json_pointer(
            producer_state,
            provenance["json_pointer"],
            name,
        )
        expected_record = row["expected_record"]
        derivation = row["derivation"]
        if row["category"] == "environment":
            if selected != expected_record:
                _fail("resource_formula_unresolved", "environment record is not selected from provenance")
        elif row["category"] == "named_golden":
            if selected != derivation:
                _fail("resource_formula_unresolved", "golden derivation is not selected from provenance")
            if expected_record is not None:
                _fail("resource_formula_unresolved", "future named golden must not claim an existing exact record")
        else:
            _fail("resource_formula_unresolved", "ledger v2 permits only environments and named goldens")
        if not isinstance(derivation, Mapping):
            _fail("resource_formula_unresolved", "resource derivation is not an object")
        if row["category"] == "environment":
            declared_bytes = _derived_resource_bytes(
                derivation,
                expected_record if isinstance(expected_record, Mapping) else None,
            )
        else:
            declared_bytes = None
        if not isinstance(row["final_path"], str) or row["staging_group"] is not None:
            _fail("resource_formula_unresolved", "future resource path/staging fields differ")
        final_path = validate_runtime_path(Path(row["final_path"]), name, must_exist=False)
        if final_path != fixed_final_paths[name]:
            _fail("resource_formula_unresolved", "resource final path differs from caller-fixed destination")
        if row["category"] == "named_golden" and os.path.lexists(str(final_path)):
            _fail("resource_formula_unresolved", "future named golden destination already exists")
        if row["record_kind"] not in ("sealed_venv", "immutable_artifact"):
            _fail("resource_formula_unresolved", "ledger record kind differs")
        if row["category"] == "environment" and row["record_kind"] != "sealed_venv":
            _fail("resource_formula_unresolved", "ledger environment must use sealed_venv replay")
        if row["category"] == "named_golden" and row["record_kind"] != "immutable_artifact":
            _fail("resource_formula_unresolved", "ledger golden must use immutable artifact replay")
        if row["category"] == "named_golden":
            _fail(
                "resource_formula_unresolved",
                "r1 has no revised-plan T8R serializer/calculator authority for named goldens",
            )
        components.append(ResourceComponent(
            name,
            row["category"],
            declared_bytes,
            final_path,
            expected_record=expected_record,
            staging_group=row["staging_group"],
            record_kind=row["record_kind"],
        ))
    if seen != set(required_names):
        _fail("resource_formula_unresolved", "resource ledger v2 required names differ")
    return tuple(components)


def _existing_anchor(path: Path) -> Tuple[Path, os.stat_result]:
    candidate = path
    while True:
        try:
            return candidate, os.stat(str(candidate), follow_symlinks=False)
        except FileNotFoundError:
            parent = candidate.parent
            if parent == candidate:
                _fail("missing_filesystem_anchor", "no existing parent for {}".format(path))
            candidate = parent


def filesystem_free_bytes(path: Path) -> Dict[str, int | str]:
    path = validate_runtime_path(path, "filesystem destination", must_exist=False)
    anchor, info = _existing_anchor(path)
    values = os.statvfs(str(anchor))
    return {
        "anchor": str(anchor),
        "device": int(info.st_dev),
        "available_bytes": int(values.f_bavail) * int(values.f_frsize),
        "fragment_size": int(values.f_frsize),
        "available_blocks": int(values.f_bavail),
    }


def _remaining_component_bytes(component: ResourceComponent) -> Tuple[int, str]:
    if not isinstance(component.declared_bytes, int) or isinstance(component.declared_bytes, bool) or component.declared_bytes < 0:
        _fail("resource_formula_unresolved", "{} has invalid declared bytes".format(component.name))
    path = validate_runtime_path(component.final_path, component.name, must_exist=False)
    if component.record_kind not in ("immutable_artifact", "sealed_venv"):
        _fail("resource_formula_unresolved", "{} has unknown record kind".format(component.name))
    if component.record_kind == "sealed_venv":
        expected = component.expected_record
        if not isinstance(expected, Mapping) or set(expected) != {"path", "sha256", "bytes", "mode"}:
            _fail("resource_formula_unresolved", "{} lacks a full sealed venv record".format(component.name))
        if (
            expected.get("path") != str(path)
            or expected.get("bytes") != component.declared_bytes
            or not isinstance(expected.get("bytes"), int)
            or isinstance(expected.get("bytes"), bool)
            or expected["bytes"] <= 0
            or not isinstance(expected.get("sha256"), str)
            or not re.fullmatch(r"[0-9a-f]{64}", expected["sha256"])
            or not isinstance(expected.get("mode"), str)
            or not re.fullmatch(r"0[0-7]{3}", expected["mode"])
        ):
            _fail("resource_formula_unresolved", "{} sealed path/bytes differ from the component".format(component.name))
    if not os.path.lexists(str(path)):
        return component.declared_bytes, "absent"
    if component.expected_record is None:
        _fail("resource_formula_unresolved", "{} exists without an exact expected record".format(component.name))
    if component.record_kind == "sealed_venv":
        try:
            from benchmarks.scripts.dicow.run_with_env import sealed_path_record
            actual = sealed_path_record(path, "venv")
        except Exception as error:
            _fail("resource_materialization_mismatch", "{} venv replay failed: {}".format(component.name, error))
    else:
        actual = artifact_record(path, immutable=True)
    if actual != dict(component.expected_record):
        _fail("resource_materialization_mismatch", "{} differs from its exact immutable record".format(component.name))
    return 0, "exact_immutable"


def calculate_required_free_bytes(policy: ResourcePolicy) -> Dict[str, Any]:
    """Compute exact remaining writes and compare each destination filesystem.

    Staging is the maximum sum among named stages, not the sum of every stage. All
    other categories add their remaining bytes. The 2 GiB headroom is charged once to
    every destination filesystem, including a staging-only filesystem; a policy spanning
    filesystems therefore remains fail-closed rather than pretending free bytes are fungible.
    """

    names = [component.name for component in policy.components]
    if len(names) != len(set(names)):
        _fail("resource_formula_unresolved", "every resource component must appear exactly once")
    if set(names) != set(policy.required_names) or len(names) != len(policy.required_names):
        missing = sorted(set(policy.required_names) - set(names))
        extra = sorted(set(names) - set(policy.required_names))
        _fail("resource_formula_unresolved", "component coverage mismatch missing={} extra={}".format(missing, extra))
    if not isinstance(policy.headroom_bytes, int) or isinstance(policy.headroom_bytes, bool) or policy.headroom_bytes != HEADROOM_BYTES:
        _fail("resource_formula_unresolved", "temporary headroom must be exactly 2**31 bytes")

    rows = []
    remaining_by_category = {name: 0 for name in RESOURCE_CATEGORIES}
    per_device: Dict[int, Dict[str, Any]] = {}
    for component in policy.components:
        if component.category not in RESOURCE_CATEGORIES:
            _fail("resource_formula_unresolved", "{} has unknown category {}".format(component.name, component.category))
        remaining, state = _remaining_component_bytes(component)
        filesystem = filesystem_free_bytes(component.final_path)
        device = int(filesystem["device"])
        bucket = per_device.setdefault(
            device,
            {
                "device": device,
                "available_bytes": int(filesystem["available_bytes"]),
                "anchors": set(),
                "nonstaging_bytes": 0,
                "staging_groups": {},
            },
        )
        bucket["available_bytes"] = min(bucket["available_bytes"], int(filesystem["available_bytes"]))
        bucket["anchors"].add(str(filesystem["anchor"]))
        if component.category == "staging":
            if not component.staging_group:
                _fail("resource_formula_unresolved", "staging component {} has no stage name".format(component.name))
            groups = bucket["staging_groups"]
            groups[component.staging_group] = groups.get(component.staging_group, 0) + remaining
        else:
            if component.staging_group is not None:
                _fail("resource_formula_unresolved", "non-staging component {} names a stage".format(component.name))
            bucket["nonstaging_bytes"] += remaining
        remaining_by_category[component.category] += remaining
        rows.append(
            {
                "name": component.name,
                "category": component.category,
                "declared_bytes": component.declared_bytes,
                "remaining_bytes": remaining,
                "state": state,
                "final_path": str(component.final_path),
                "device": device,
                "staging_group": component.staging_group,
                "record_kind": component.record_kind,
            }
        )

    devices = []
    for device in sorted(per_device):
        bucket = per_device[device]
        groups = dict(sorted(bucket["staging_groups"].items()))
        staging_peak = max(groups.values(), default=0)
        required = int(bucket["nonstaging_bytes"]) + staging_peak + HEADROOM_BYTES
        available = int(bucket["available_bytes"])
        devices.append(
            {
                "device": device,
                "anchors": sorted(bucket["anchors"]),
                "available_bytes": available,
                "remaining_nonstaging_bytes": int(bucket["nonstaging_bytes"]),
                "staging_groups": groups,
                "staging_peak_bytes": staging_peak,
                "temporary_headroom_bytes": HEADROOM_BYTES,
                "required_free_bytes": required,
                "sufficient": available >= required,
            }
        )
    if not devices:
        _fail("resource_formula_unresolved", "resource policy is empty")
    result = {
        "formula": "remaining_source+converted_outputs+staging_peak+remaining_envs+named_goldens+2**31",
        "remaining_source_bytes": remaining_by_category["source"],
        "converted_outputs_bytes": remaining_by_category["converted_output"],
        "remaining_environments_bytes": remaining_by_category["environment"],
        "named_goldens_bytes": remaining_by_category["named_golden"],
        "components": rows,
        "filesystems": devices,
        "sufficient": all(item["sufficient"] for item in devices),
    }
    if not result["sufficient"]:
        _fail("insufficient_free_space", canonical_json_bytes(result).decode("utf-8").strip())
    return result


def _r2_nonnegative_integer(value: Any, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        _fail("r2_constraint_invalid", "{} must be a non-negative integer".format(label))
    return value


def _r2_constraint_value(value: Any, label: str, *, positive: bool = False) -> Any:
    """Accept one measured integer or a typed unavailable constraint.

    Unknown execution limits remain visible instead of becoming zero.  Zero is valid
    only for fields such as prompt/output tokens; duration, time, attempts, and memory
    are required to be positive when measured.
    """

    if isinstance(value, int) and not isinstance(value, bool):
        if value < (1 if positive else 0):
            _fail("r2_constraint_invalid", "{} has an invalid measured value".format(label))
        return value
    if (
        isinstance(value, Mapping)
        and set(value) == {"state", "reason"}
        and value.get("state") == "unavailable"
        and isinstance(value.get("reason"), str)
        and value["reason"].strip()
    ):
        return dict(value)
    _fail("r2_constraint_invalid", "{} must be measured or typed unavailable".format(label))


def _validate_r2_execution_plan(value: Any, label: str) -> Dict[str, Any]:
    """Validate an R3 execution plan without accepting it as an observation."""

    expected = {*R2_EXECUTION_FIELDS, "plan_state", "receipt"}
    if not isinstance(value, Mapping) or set(value) != expected or value.get("plan_state") != "planned_unverified":
        _fail("r2_constraint_invalid", "{} execution plan shape differs".format(label))
    result = {"plan_state": "planned_unverified"}
    for field in R2_EXECUTION_FIELDS:
        item = value[field]
        if field == "cancellation_contract":
            if not isinstance(item, str) or not item.strip():
                _fail("r2_constraint_invalid", "{} cancellation contract is empty".format(label))
            result[field] = item
        elif field == "concurrent_model_processes":
            if item != {"state": "planned_limit", "maximum": 1}:
                _fail("r2_model_concurrency", "{} concurrency must be an unobserved one-process plan".format(label))
            result[field] = dict(item)
        else:
            result[field] = _r2_constraint_value(
                item,
                "{} {}".format(label, field),
                positive=field in {"duration_seconds", "timeout_seconds", "maximum_attempts", "peak_resident_bytes"},
            )
    receipt = value["receipt"]
    if (
        not isinstance(receipt, Mapping)
        or set(receipt) != {"state", "producer_task", "schema_version"}
        or receipt.get("state") != "deferred"
        or not isinstance(receipt.get("producer_task"), str)
        or not receipt["producer_task"].strip()
        or receipt.get("schema_version") != "dicow-r2-execution-receipt-v1"
    ):
        _fail("r2_constraint_invalid", "{} execution receipt must remain deferred".format(label))
    result["receipt"] = dict(receipt)
    return result


def _calculate_r2_writer_resource_plan(
    ledger: Mapping[str, Any],
    required_writers: Sequence[str],
    sealed_snapshot: Optional[Mapping[str, Any]] = None,
) -> Dict[str, Any]:
    """Replay source-derived writer bounds while deferring execution receipts."""

    if set(ledger) != {"schema_version", "writers"}:
        _fail("r2_resource_shape", "r2 resource plan envelope differs")
    rows = ledger.get("writers")
    required = tuple(required_writers)
    if not isinstance(rows, list) or len(rows) != len(required):
        _fail("r2_resource_coverage", "writer resource plan coverage differs")
    results = []
    seen = set()
    for row in rows:
        if not isinstance(row, Mapping) or set(row) != {
            "writer", "destination_path", "sources", "phases", "execution", "planning_state",
        }:
            _fail("r2_resource_shape", "writer resource plan row differs")
        writer = row.get("writer")
        if writer not in required or writer in seen:
            _fail("r2_resource_coverage", "writer resource plan identity differs")
        seen.add(writer)
        if row.get("planning_state") != "source_bounds_frozen_receipt_deferred":
            _fail("r2_resource_formula_mismatch", "writer bound/receipt branch differs")
        destination = validate_runtime_path(Path(row["destination_path"]), writer + " destination", must_exist=False)
        sources = row.get("sources")
        if not isinstance(sources, list) or not sources:
            _fail("r2_resource_shape", "{} source authority is empty".format(writer))
        normalized_sources = []
        source_names = set()
        for source in sources:
            if not isinstance(source, Mapping) or set(source) != {
                "candidate", "model_id", "revision", "model_file_bytes", "model_file_lfs_sha256",
                "header_record", "lfs_record",
            }:
                _fail("r2_resource_shape", "{} source authority shape differs".format(writer))
            candidate = source.get("candidate")
            if not isinstance(candidate, str) or not candidate or candidate in source_names:
                _fail("r2_resource_shape", "{} source authority identity differs".format(writer))
            source_names.add(candidate)
            for key in ("model_id", "revision"):
                if not isinstance(source.get(key), str) or not source[key]:
                    _fail("r2_resource_shape", "{} source {} is empty".format(writer, key))
            if (
                not isinstance(source.get("model_file_bytes"), int)
                or isinstance(source["model_file_bytes"], bool)
                or source["model_file_bytes"] <= 8
                or not isinstance(source.get("model_file_lfs_sha256"), str)
                or not re.fullmatch(r"[0-9a-f]{64}", source["model_file_lfs_sha256"])
            ):
                _fail("r2_resource_shape", "{} source model tuple differs".format(writer))
            for record_name in ("header_record", "lfs_record"):
                record = source.get(record_name)
                if (
                    not isinstance(record, Mapping) or set(record) != {"bytes", "sha256"}
                    or not isinstance(record.get("bytes"), int) or isinstance(record["bytes"], bool)
                    or record["bytes"] <= 0 or not isinstance(record.get("sha256"), str)
                    or not re.fullmatch(r"[0-9a-f]{64}", record["sha256"])
                ):
                    _fail("r2_resource_shape", "{} source {} differs".format(writer, record_name))
            normalized_sources.append(dict(source))
        source_model_bytes = sum(source["model_file_bytes"] for source in normalized_sources)
        source_header_bytes = sum(source["header_record"]["bytes"] for source in normalized_sources)
        extractors = {
            "sum_model_file_bytes_upper_bound_v1": (source_model_bytes, "upper_bound"),
            "sum_safetensors_header_bytes_exact_v1": (source_header_bytes, "exact"),
            "zero_by_phase_contract_v1": (0, "exact"),
        }
        required_extractors = {
            "final_bytes": "sum_model_file_bytes_upper_bound_v1",
            "staging_bytes": "sum_model_file_bytes_upper_bound_v1",
            "retained_failure_bytes": "sum_model_file_bytes_upper_bound_v1",
            "retry_bytes": "zero_by_phase_contract_v1",
            "serializer_bytes": "sum_safetensors_header_bytes_exact_v1",
            "simultaneously_retained_prior_outputs": "zero_by_phase_contract_v1",
        }
        phases = row.get("phases")
        if not isinstance(phases, list) or not phases:
            _fail("r2_resource_shape", "{} phase plan is empty".format(writer))
        normalized_phases = []
        names = set()
        for phase in phases:
            if not isinstance(phase, Mapping) or set(phase) != {"name", *R2_PHASE_BYTE_FIELDS}:
                _fail("r2_resource_shape", "{} phase plan shape differs".format(writer))
            name = phase.get("name")
            if not isinstance(name, str) or not name or name in names:
                _fail("r2_resource_shape", "{} phase plan identity differs".format(writer))
            names.add(name)
            normalized = {"name": name}
            for field in R2_PHASE_BYTE_FIELDS:
                item = phase[field]
                if not isinstance(item, Mapping) or set(item) != {
                    "state", "bytes", "bound_kind", "extractor_id",
                } or item.get("state") != "source_derived":
                    _fail("r2_resource_formula_mismatch", "{} {} is not a source-derived bound".format(writer, field))
                extractor = item.get("extractor_id")
                expected = extractors.get(extractor)
                if (
                    extractor != required_extractors[field]
                    or expected is None
                    or (item.get("bytes"), item.get("bound_kind")) != expected
                ):
                    _fail("r2_resource_formula_mismatch", "{} {} source formula differs".format(writer, field))
                normalized[field] = dict(item)
            normalized["phase_bytes"] = sum(normalized[field]["bytes"] for field in R2_PHASE_BYTE_FIELDS)
            normalized_phases.append(normalized)
        peak = sorted(normalized_phases, key=lambda item: (-item["phase_bytes"], item["name"]))[0]
        required_free = peak["phase_bytes"] + HEADROOM_BYTES
        if sealed_snapshot is None:
            filesystem = filesystem_free_bytes(destination)
        else:
            snapshot_rows = sealed_snapshot.get("writers") if isinstance(sealed_snapshot, Mapping) else None
            snapshot = next(
                (item for item in snapshot_rows or [] if isinstance(item, Mapping) and item.get("writer") == writer),
                None,
            )
            if not isinstance(snapshot, Mapping):
                _fail("r2_resource_formula_mismatch", "{} sealed volume row is missing".format(writer))
            filesystem = {
                "anchor": snapshot.get("volume"),
                "device": snapshot.get("device"),
                "available_bytes": snapshot.get("available_bytes"),
            }
            if (
                not isinstance(filesystem["anchor"], str) or not filesystem["anchor"]
                or not isinstance(filesystem["device"], int) or isinstance(filesystem["device"], bool)
                or not isinstance(filesystem["available_bytes"], int) or isinstance(filesystem["available_bytes"], bool)
                or filesystem["available_bytes"] < 0
            ):
                _fail("r2_resource_formula_mismatch", "{} sealed volume observation differs".format(writer))
        sufficient = filesystem["available_bytes"] >= required_free
        results.append({
            "writer": writer,
            "destination_path": str(destination),
            "sources": normalized_sources,
            "phases": normalized_phases,
            "execution": _validate_r2_execution_plan(row["execution"], writer),
            "planning_state": "source_bounds_frozen_receipt_deferred",
            "volume": filesystem["anchor"],
            "device": filesystem["device"],
            "available_bytes": filesystem["available_bytes"],
            "peak_phase": peak["name"],
            "peak_phase_bytes": peak["phase_bytes"],
            "headroom_bytes": HEADROOM_BYTES,
            "required_free_bytes": required_free,
            "sufficient": sufficient,
        })
    if seen != set(required):
        _fail("r2_resource_coverage", "writer resource plan roster differs")
    result = {
        "schema_version": "dicow-r2-writer-resource-plan-replay-v1",
        "formula": "max_phase(final+staging+retained_failure+retry+serializer+simultaneously_retained_prior_outputs)+2**31",
        "receipt_schema_version": "dicow-r2-writer-resource-receipt-v1",
        "writers": sorted(results, key=lambda item: item["writer"]),
        "resource_gate_state": "sufficient" if all(item["sufficient"] for item in results) else "insufficient",
    }
    if result["resource_gate_state"] != "sufficient":
        _fail("r2_operational_resource_blocker", canonical_json_bytes(result).decode("utf-8").strip())
    return result


def calculate_r2_writer_resource_ledger(
    ledger: Mapping[str, Any],
    *,
    required_writers: Sequence[str] = R2_REQUIRED_RESOURCE_WRITERS,
    sealed_snapshot: Optional[Mapping[str, Any]] = None,
) -> Dict[str, Any]:
    """Validate and replay the r2 per-writer, maximum-phase resource formula.

    This deliberately does not reuse :func:`calculate_required_free_bytes`.  E0 has
    category-level materializations while r2 must retain failures, retries, serializer
    buffers, and prior outputs in the same phase.  Summing every phase or doubling the
    payload would overstate the gate and is rejected by the claimed calculation replay.
    """

    if isinstance(ledger, Mapping) and ledger.get("schema_version") == "dicow-r2-writer-resource-plan-v2":
        return _calculate_r2_writer_resource_plan(ledger, required_writers, sealed_snapshot)
    if not isinstance(ledger, Mapping) or set(ledger) != {"schema_version", "writers"}:
        _fail("r2_resource_shape", "r2 resource ledger envelope differs")
    if ledger.get("schema_version") != "dicow-r2-writer-resource-ledger-v1":
        _fail("r2_resource_shape", "r2 resource ledger schema differs")
    _fail("r2_resource_formula_mismatch", "observed-looking v1 resource integers are forbidden in R3")
    rows = ledger.get("writers")
    if not isinstance(rows, list):
        _fail("r2_resource_shape", "writers must be a list")
    required = tuple(required_writers)
    if (
        not required
        or len(required) != len(set(required))
        or any(not isinstance(item, str) or not item for item in required)
    ):
        _fail("r2_resource_shape", "required writer roster is invalid")
    results = []
    seen = set()
    for row in rows:
        expected_keys = {
            "writer", "destination_path", "phases", "byte_authority", "execution",
            "claimed_peak_phase", "claimed_peak_phase_bytes", "claimed_required_free_bytes",
        }
        if not isinstance(row, Mapping) or set(row) != expected_keys:
            _fail("r2_resource_shape", "writer row shape differs")
        writer = row.get("writer")
        if not isinstance(writer, str) or writer not in required or writer in seen:
            _fail("r2_resource_coverage", "writer identity is missing, extra, or duplicated")
        seen.add(writer)
        if not isinstance(row.get("destination_path"), str):
            _fail("r2_resource_shape", "{} destination path is invalid".format(writer))
        destination = validate_runtime_path(Path(row["destination_path"]), writer + " destination", must_exist=False)
        filesystem = filesystem_free_bytes(destination)
        available = int(filesystem["available_bytes"])
        phases = row.get("phases")
        if not isinstance(phases, list) or not phases:
            _fail("r2_resource_shape", "{} must declare at least one phase".format(writer))
        phase_results = []
        phase_names = set()
        for phase in phases:
            if not isinstance(phase, Mapping) or set(phase) != {"name", *R2_PHASE_BYTE_FIELDS}:
                _fail("r2_resource_shape", "{} phase shape differs".format(writer))
            name = phase.get("name")
            if not isinstance(name, str) or not name or name in phase_names:
                _fail("r2_resource_shape", "{} phase name is invalid or duplicated".format(writer))
            phase_names.add(name)
            byte_values = {
                field: _r2_nonnegative_integer(phase.get(field), "{} {} {}".format(writer, name, field))
                for field in R2_PHASE_BYTE_FIELDS
            }
            total = sum(byte_values.values())
            phase_results.append({"name": name, **byte_values, "phase_bytes": total})
        authority = row.get("byte_authority")
        expected_authority = {(phase["name"], field) for phase in phase_results for field in R2_PHASE_BYTE_FIELDS}
        if not isinstance(authority, list) or len(authority) != len(expected_authority):
            _fail("r2_resource_shape", "{} byte authority coverage differs".format(writer))
        seen_authority = set()
        phase_lookup = {phase["name"]: phase for phase in phase_results}
        for item in authority:
            if not isinstance(item, Mapping) or set(item) != {"phase", "field", "value", "formula", "source"}:
                _fail("r2_resource_shape", "{} byte authority row shape differs".format(writer))
            pair = (item.get("phase"), item.get("field"))
            if pair not in expected_authority or pair in seen_authority:
                _fail("r2_resource_shape", "{} byte authority identity differs".format(writer))
            seen_authority.add(pair)
            if item.get("value") != phase_lookup[pair[0]][pair[1]]:
                _fail("r2_resource_formula_mismatch", "{} byte authority value differs".format(writer))
            if item.get("formula") != "r2_writer_phase_bytes_v1":
                _fail("r2_resource_shape", "{} byte authority formula is empty".format(writer))
            source = item.get("source")
            if not isinstance(source, Mapping) or set(source) != {"path", "bytes", "sha256"} or source.get("path") != "captures/resource-authority.json":
                _fail("r2_resource_shape", "{} byte authority source differs".format(writer))
        # The lexical tie-break makes a repeated maximum deterministic.
        peak = sorted(phase_results, key=lambda item: (-item["phase_bytes"], item["name"]))[0]
        required_free = peak["phase_bytes"] + HEADROOM_BYTES
        if (
            row.get("claimed_peak_phase") != peak["name"]
            or row.get("claimed_peak_phase_bytes") != peak["phase_bytes"]
            or row.get("claimed_required_free_bytes") != required_free
        ):
            _fail("r2_resource_formula_mismatch", "{} claimed calculation is not max_phase(sum(six))+2**31".format(writer))

        execution = row.get("execution")
        if not isinstance(execution, Mapping) or set(execution) != set(R2_EXECUTION_FIELDS):
            _fail("r2_constraint_invalid", "{} execution constraint shape differs".format(writer))
        normalized_execution = {}
        for field in R2_EXECUTION_FIELDS:
            value = execution[field]
            if field == "cancellation_contract":
                if not isinstance(value, str) or not value.strip():
                    _fail("r2_constraint_invalid", "{} cancellation contract is empty".format(writer))
                normalized_execution[field] = value
            elif field == "concurrent_model_processes":
                if value != 1 or isinstance(value, bool):
                    _fail("r2_model_concurrency", "{} model concurrency must be exactly one".format(writer))
                normalized_execution[field] = 1
            else:
                normalized_execution[field] = _r2_constraint_value(
                    value,
                    "{} {}".format(writer, field),
                    positive=field in {
                        "duration_seconds", "timeout_seconds", "maximum_attempts", "peak_resident_bytes",
                    },
                )
        results.append({
            "writer": writer,
            "destination_path": str(destination),
            "volume": str(filesystem["anchor"]),
            "device": int(filesystem["device"]),
            "available_bytes": available,
            "phases": phase_results,
            "byte_authority": [dict(item) for item in authority],
            "peak_phase": peak["name"],
            "peak_phase_bytes": peak["phase_bytes"],
            "headroom_bytes": HEADROOM_BYTES,
            "required_free_bytes": required_free,
            "sufficient": available >= required_free,
            "execution": normalized_execution,
        })
    if seen != set(required) or len(rows) != len(required):
        _fail("r2_resource_coverage", "writer roster differs missing={} extra={}".format(
            sorted(set(required) - seen), sorted(seen - set(required))
        ))
    result = {
        "schema_version": "dicow-r2-writer-resource-replay-v1",
        "formula": "max_phase(final+staging+retained_failure+retry+serializer+simultaneously_retained_prior_outputs)+2**31",
        "writers": sorted(results, key=lambda item: item["writer"]),
        "sufficient": all(item["sufficient"] for item in results),
    }
    if not result["sufficient"]:
        # Resource shortfall is operational.  It never means the research task or a
        # candidate completed, failed its quality gate, or may be skipped.
        _fail(
            "r2_operational_resource_blocker",
            canonical_json_bytes(result).decode("utf-8").strip(),
        )
    return result


def _validate_r2_timestamp_fixed(contract: Mapping[str, Any]) -> None:
    if any(contract.get(key) != value for key, value in R2_TIMESTAMP_CONTRACT.items()):
        _fail("r2_timestamp_contract", "timestamp authority or tolerance differs")
    if "ForcedAligner" in str(contract.get("truth_authority", "")):
        _fail("r2_timestamp_self_truth", "ForcedAligner cannot be its own acoustic truth")


def validate_r2_timestamp_contract(contract: Mapping[str, Any]) -> Dict[str, Any]:
    """Validate independent truth, fixture tuples, coverage, and attribution replay."""

    if isinstance(contract, Mapping) and contract.get("status") == "timestamp_truth_unavailable":
        if set(contract) != {"status", "reason", "forced_aligner_self_truth_forbidden"} or not isinstance(contract.get("reason"), str) or not contract["reason"].strip() or contract.get("forced_aligner_self_truth_forbidden") is not True:
            _fail("r2_timestamp_contract", "unavailable timestamp truth is untyped")
        return dict(contract)
    required = {
        *R2_TIMESTAMP_CONTRACT,
        "status", "truth_fixture_record", "join_manifest_record", "coverage_locales", "attribution_replay",
    }
    if not isinstance(contract, Mapping) or set(contract) != required:
        _fail("r2_timestamp_contract", "timestamp contract shape differs")
    _validate_r2_timestamp_fixed(contract)
    if contract.get("status") != "available":
        _fail("r2_timestamp_contract", "timestamp truth status differs")
    for key in ("truth_fixture_record", "join_manifest_record"):
        record = contract.get(key)
        if (
            not isinstance(record, Mapping)
            or set(record) != {"path", "bytes", "sha256"}
            or not isinstance(record.get("path"), str)
            or not record["path"]
            or not isinstance(record.get("bytes"), int)
            or record["bytes"] <= 0
            or not isinstance(record.get("sha256"), str)
            or len(record["sha256"]) != 64
            or any(character not in "0123456789abcdef" for character in record["sha256"])
        ):
            _fail("r2_timestamp_contract", "{} is not an immutable evidence tuple".format(key))
    if contract["truth_fixture_record"]["path"] != "captures/timestamp-fixture.pcm" or contract["join_manifest_record"]["path"] != "captures/timestamp-join.json":
        _fail("r2_timestamp_contract", "timestamp evidence roles differ")
    if contract.get("coverage_locales") != ["ko", "en", "it"]:
        _fail("r2_timestamp_contract", "timestamp coverage must freeze ko/en/it")
    replay = contract.get("attribution_replay")
    if not isinstance(replay, Mapping) or set(replay) != {"utterances", "words", "expected"}:
        _fail("r2_timestamp_contract", "timestamp attribution replay shape differs")
    actual = attribute_r2_words_to_utterances(
        replay["utterances"], replay["words"], contract=contract, _fixed_validated=True
    )
    if replay["expected"] != actual:
        _fail("r2_timestamp_contract", "timestamp attribution replay result differs")
    return dict(contract)


def validate_r2_boundary_receipt(plan: Mapping[str, Any], receipt: Mapping[str, Any]) -> Dict[str, Any]:
    """Validate a later observed audio boundary receipt at one-sample epsilon."""

    if not isinstance(plan, Mapping) or set(plan) != {
        "constraint_id", "sample_rate_hz", "epsilon_unit", "below_samples", "at_samples",
        "above_samples", "receipt_state", "producer_task", "receipt_schema_version",
    }:
        _fail("r2_constraint_invalid", "boundary probe plan shape differs")
    if (
        plan.get("sample_rate_hz") != 16_000
        or plan.get("epsilon_unit") != "one_sample"
        or plan.get("below_samples") + 1 != plan.get("at_samples")
        or plan.get("above_samples") - 1 != plan.get("at_samples")
        or plan.get("receipt_state") != "deferred"
        or plan.get("receipt_schema_version") != "dicow-r2-boundary-receipt-v1"
    ):
        _fail("r2_constraint_invalid", "boundary plan does not use one-sample epsilon")
    if not isinstance(receipt, Mapping) or set(receipt) != {
        "schema_version", "constraint_id", "producer_task", "runner_fingerprint",
        "observations", "record",
    }:
        _fail("r2_constraint_invalid", "boundary receipt shape differs")
    if (
        receipt.get("schema_version") != "dicow-r2-boundary-receipt-v1"
        or receipt.get("constraint_id") != plan["constraint_id"]
        or receipt.get("producer_task") != plan["producer_task"]
        or not isinstance(receipt.get("runner_fingerprint"), str)
        or len(receipt["runner_fingerprint"]) != 64
        or any(character not in "0123456789abcdef" for character in receipt["runner_fingerprint"])
        or not isinstance(receipt.get("record"), Mapping)
        or set(receipt["record"]) != {"path", "bytes", "sha256"}
        or not isinstance(receipt["record"].get("path"), str)
        or not receipt["record"]["path"]
        or not isinstance(receipt["record"].get("bytes"), int)
        or isinstance(receipt["record"].get("bytes"), bool)
        or receipt["record"]["bytes"] <= 0
        or not isinstance(receipt["record"].get("sha256"), str)
        or len(receipt["record"]["sha256"]) != 64
        or any(character not in "0123456789abcdef" for character in receipt["record"]["sha256"])
    ):
        _fail("r2_constraint_invalid", "boundary receipt identity is unauthenticated")
    observations = receipt.get("observations")
    expected_samples = [plan["below_samples"], plan["at_samples"], plan["above_samples"]]
    if not isinstance(observations, list) or len(observations) != 3:
        _fail("r2_constraint_invalid", "boundary receipt observation coverage differs")
    outcomes = []
    expected_outcomes = ["supported", "supported", "reject_or_split"]
    for index, observation in enumerate(observations):
        if not isinstance(observation, Mapping) or set(observation) != {
            "input_samples", "outcome", "terminal_reason",
        }:
            _fail("r2_constraint_invalid", "boundary receipt observation shape differs")
        if observation.get("input_samples") != expected_samples[index]:
            _fail("r2_constraint_invalid", "boundary receipt does not preserve one-sample epsilon")
        if observation.get("outcome") != expected_outcomes[index] or not isinstance(observation.get("terminal_reason"), str) or not observation["terminal_reason"].strip():
            _fail("r2_constraint_invalid", "boundary receipt outcome is untyped")
        outcomes.append(dict(observation))
    return {"constraint_id": plan["constraint_id"], "observations": outcomes}


def _validate_r2_candidate_constraint_plan(
    ledger: Mapping[str, Any], required_paths: Sequence[str]
) -> Dict[str, Any]:
    if set(ledger) != {"schema_version", "paths"}:
        _fail("r2_constraint_invalid", "candidate constraint plan envelope differs")
    rows = ledger.get("paths")
    required = tuple(required_paths)
    if not isinstance(rows, list) or len(rows) != len(required):
        _fail("r2_constraint_invalid", "candidate constraint plan coverage differs")
    result = {}
    for row in rows:
        if not isinstance(row, Mapping) or set(row) != {
            "path", "execution", "unit_contract", "constraints", "supported_range", "boundary_probe_plans",
        }:
            _fail("r2_constraint_invalid", "candidate constraint plan row shape differs")
        path = row.get("path")
        if path not in required or path in result:
            _fail("r2_constraint_invalid", "candidate constraint plan identity differs")
        execution = _validate_r2_execution_plan(row["execution"], path)
        unit = row.get("unit_contract")
        if not isinstance(unit, Mapping) or set(unit) != {"unit", "batch_size", "sample_rate_hz"} or unit.get("sample_rate_hz") != 16_000 or unit.get("batch_size") != {"state": "planned_limit", "maximum": 1}:
            _fail("r2_constraint_invalid", "{} unit/batch plan differs".format(path))
        expected_unit = "utterance" if path == "qwen_aligner" else "audio_file"
        if unit.get("unit") != expected_unit:
            _fail("r2_constraint_invalid", "{} unit kind differs".format(path))
        constraints = row.get("constraints")
        if not isinstance(constraints, list) or len(constraints) != 1:
            _fail("r2_constraint_invalid", "{} must have one planned audio limit".format(path))
        constraint = constraints[0]
        fields = {
            "constraint_id", "variable", "unit", "scope", "kind", "source", "formula", "headroom",
            "observed_range", "planned_maximum_samples", "failure_mode", "telemetry", "review_trigger",
        }
        if not isinstance(constraint, Mapping) or set(constraint) != fields:
            _fail("r2_constraint_invalid", "{} planned constraint shape differs".format(path))
        maximum = constraint.get("planned_maximum_samples")
        if (
            constraint.get("unit") != "samples"
            or constraint.get("scope") != path
            or constraint.get("kind") != "operator_choice"
            or constraint.get("source") != "R3 unverified execution plan"
            or constraint.get("formula") != "floor(planned_seconds*16000)"
            or constraint.get("observed_range") != "not_observed_at_R3"
            or not isinstance(maximum, int) or isinstance(maximum, bool) or maximum <= 1
        ):
            _fail("r2_constraint_invalid", "{} planned constraint semantics differ".format(path))
        for field in ("constraint_id", "variable", "headroom", "failure_mode", "telemetry", "review_trigger"):
            if not isinstance(constraint.get(field), str) or not constraint[field].strip():
                _fail("r2_constraint_invalid", "{} {} is empty".format(path, field))
        supported = row.get("supported_range")
        if supported != {
            "state": "planned_unverified",
            "maximum_samples": maximum,
            "limiting_constraints": [constraint["constraint_id"]],
            "reason": "boundary receipt deferred to producing task",
        }:
            _fail("r2_constraint_invalid", "{} supported range overclaims observation".format(path))
        plans = row.get("boundary_probe_plans")
        if not isinstance(plans, list) or len(plans) != 1:
            _fail("r2_constraint_invalid", "{} boundary plan coverage differs".format(path))
        plan = plans[0]
        expected_plan = {
            "constraint_id": constraint["constraint_id"],
            "sample_rate_hz": 16_000,
            "epsilon_unit": "one_sample",
            "below_samples": maximum - 1,
            "at_samples": maximum,
            "above_samples": maximum + 1,
            "receipt_state": "deferred",
            "producer_task": execution["receipt"]["producer_task"],
            "receipt_schema_version": "dicow-r2-boundary-receipt-v1",
        }
        if plan != expected_plan:
            _fail("r2_constraint_invalid", "{} boundary plan does not use one-sample epsilon".format(path))
        result[path] = {
            "path": path,
            "execution": execution,
            "unit_contract": dict(unit),
            "constraints": [dict(constraint)],
            "supported_range": dict(supported),
            "boundary_probe_plans": [dict(plan)],
        }
    if set(result) != set(required):
        _fail("r2_constraint_invalid", "candidate constraint plan roster differs")
    return {"schema_version": ledger["schema_version"], "paths": result}


def validate_r2_candidate_constraint_ledger(
    ledger: Mapping[str, Any],
    *,
    required_paths: Sequence[str] = R2_REQUIRED_CONSTRAINT_PATHS,
) -> Dict[str, Any]:
    """Validate candidate execution limits and their supported-range result."""

    if isinstance(ledger, Mapping) and ledger.get("schema_version") == "dicow-r2-candidate-constraint-plan-v2":
        return _validate_r2_candidate_constraint_plan(ledger, required_paths)
    if not isinstance(ledger, Mapping) or set(ledger) != {"schema_version", "paths"}:
        _fail("r2_constraint_invalid", "candidate constraint envelope differs")
    if ledger.get("schema_version") != "dicow-r2-candidate-constraint-ledger-v1":
        _fail("r2_constraint_invalid", "candidate constraint schema differs")
    _fail("r2_constraint_invalid", "observed-looking v1 boundary booleans are forbidden in R3")
    rows = ledger.get("paths")
    required = tuple(required_paths)
    if not isinstance(rows, list) or len(rows) != len(required) or len(required) != len(set(required)):
        _fail("r2_constraint_invalid", "candidate constraint coverage differs")
    result = {}
    expected_keys = {"path", *R2_EXECUTION_FIELDS, "constraints", "supported_range", "boundary_probes"}
    for row in rows:
        if not isinstance(row, Mapping) or set(row) != expected_keys:
            _fail("r2_constraint_invalid", "candidate constraint row shape differs")
        path = row.get("path")
        if path not in required or path in result:
            _fail("r2_constraint_invalid", "candidate constraint path is missing, extra, or duplicated")
        normalized = {"path": path}
        for field in R2_EXECUTION_FIELDS:
            value = row[field]
            if field == "cancellation_contract":
                if not isinstance(value, str) or not value.strip():
                    _fail("r2_constraint_invalid", "{} cancellation contract is empty".format(path))
                normalized[field] = value
            elif field == "concurrent_model_processes":
                if value != 1 or isinstance(value, bool):
                    _fail("r2_model_concurrency", "{} model concurrency must be exactly one".format(path))
                normalized[field] = 1
            else:
                normalized[field] = _r2_constraint_value(
                    value,
                    "{} {}".format(path, field),
                    positive=field in {"duration_seconds", "timeout_seconds", "maximum_attempts", "peak_resident_bytes"},
                )
        requested = normalized["requested_output_tokens"]
        effective = normalized["effective_output_tokens"]
        if isinstance(requested, int) and isinstance(effective, int) and effective > requested:
            _fail("r2_constraint_invalid", "{} effective output exceeds requested output".format(path))
        constraints = row.get("constraints")
        constraint_fields = {
            "constraint_id", "variable", "unit", "scope", "kind", "source", "formula",
            "headroom", "observed_range", "maximum_duration_seconds", "failure_mode",
            "telemetry", "review_trigger",
        }
        if not isinstance(constraints, list) or not constraints:
            _fail("r2_constraint_invalid", "{} constraint rows are missing".format(path))
        hard_limits = []
        constraint_ids = set()
        for constraint in constraints:
            if not isinstance(constraint, Mapping) or set(constraint) != constraint_fields:
                _fail("r2_constraint_invalid", "{} constraint row shape differs".format(path))
            identifier = constraint.get("constraint_id")
            if not isinstance(identifier, str) or not identifier or identifier in constraint_ids:
                _fail("r2_constraint_invalid", "{} constraint id is invalid".format(path))
            constraint_ids.add(identifier)
            if constraint.get("kind") not in ("hard", "empirical", "operator_choice"):
                _fail("r2_constraint_invalid", "{} constraint kind differs".format(path))
            if constraint.get("unit") != "seconds" or constraint.get("scope") != path:
                _fail("r2_constraint_invalid", "{} constraint unit/scope differs".format(path))
            for field in ("variable", "headroom", "observed_range", "failure_mode", "telemetry", "review_trigger"):
                if not isinstance(constraint.get(field), str) or not constraint[field].strip():
                    _fail("r2_constraint_invalid", "{} {} is empty".format(path, field))
            if constraint.get("formula") != "r2_hard_duration_limit_v1":
                _fail("r2_constraint_invalid", "{} constraint formula differs".format(path))
            source = constraint.get("source")
            if not isinstance(source, Mapping) or set(source) != {"path", "bytes", "sha256"} or source.get("path") != "captures/constraint-authority.json":
                _fail("r2_constraint_invalid", "{} constraint source tuple differs".format(path))
            maximum = constraint.get("maximum_duration_seconds")
            if maximum is not None and (not isinstance(maximum, int) or isinstance(maximum, bool) or maximum <= 0):
                _fail("r2_constraint_invalid", "{} constraint maximum is invalid".format(path))
            if constraint["kind"] == "hard":
                if maximum is None:
                    _fail("r2_constraint_invalid", "{} hard constraint lacks a maximum".format(path))
                hard_limits.append((identifier, maximum))
        if not hard_limits:
            _fail("r2_constraint_invalid", "{} has no hard supported-range constraint".format(path))
        safe_maximum = min(value for _, value in hard_limits)
        limiting_ids = sorted(identifier for identifier, value in hard_limits if value == safe_maximum)

        probes = row.get("boundary_probes")
        if not isinstance(probes, list):
            _fail("r2_constraint_invalid", "{} boundary probes are missing".format(path))
        probe_by_id = {}
        for probe in probes:
            if not isinstance(probe, Mapping) or set(probe) != {
                "constraint_id", "below_seconds", "at_seconds", "above_seconds",
                "below_outcome", "at_outcome", "above_outcome", "receipt",
            }:
                _fail("r2_constraint_invalid", "{} boundary probe shape differs".format(path))
            identifier = probe.get("constraint_id")
            if identifier in probe_by_id:
                _fail("r2_constraint_invalid", "{} boundary probe is duplicated".format(path))
            probe_by_id[identifier] = probe
        for identifier, maximum in hard_limits:
            probe = probe_by_id.get(identifier)
            if (
                probe is None
                or probe.get("below_seconds") != maximum - 1
                or probe.get("at_seconds") != maximum
                or probe.get("above_seconds") != maximum + 1
                or probe.get("below_outcome") != "supported"
                or probe.get("at_outcome") != "supported"
                or probe.get("above_outcome") != "reject_or_split"
                or not isinstance(probe.get("receipt"), Mapping)
                or set(probe["receipt"]) != {"path", "bytes", "sha256"}
                or probe["receipt"].get("path") != "captures/boundary-probes.json"
            ):
                _fail("r2_constraint_invalid", "{} hard boundary probes differ".format(path))
        if set(probe_by_id) != {identifier for identifier, _ in hard_limits}:
            _fail("r2_constraint_invalid", "{} boundary probe coverage differs".format(path))

        supported = row.get("supported_range")
        if not isinstance(supported, Mapping) or set(supported) != {
            "state", "maximum_duration_seconds", "limiting_constraints", "reason",
        }:
            _fail("r2_constraint_invalid", "{} supported range shape differs".format(path))
        if supported.get("state") == "calculated":
            maximum = supported.get("maximum_duration_seconds")
            if (
                not isinstance(maximum, int) or isinstance(maximum, bool) or maximum <= 0
                or supported.get("limiting_constraints") != limiting_ids
                or supported.get("reason") is not None
                or maximum != safe_maximum
            ):
                _fail("r2_constraint_invalid", "{} calculated range is invalid".format(path))
            duration = normalized["duration_seconds"]
            if isinstance(duration, int) and duration > maximum:
                _fail("r2_supported_range_exceeded", "{} duration exceeds its supported range".format(path))
        elif supported.get("state") == "unavailable":
            if (
                supported.get("maximum_duration_seconds") is not None
                or supported.get("limiting_constraints") is not None
                or not isinstance(supported.get("reason"), str)
                or not supported["reason"].strip()
            ):
                _fail("r2_constraint_invalid", "{} unavailable range is untyped".format(path))
        else:
            _fail("r2_constraint_invalid", "{} supported range state differs".format(path))
        normalized["supported_range"] = dict(supported)
        normalized["constraints"] = [dict(item) for item in constraints]
        normalized["boundary_probes"] = [dict(item) for item in probes]
        result[path] = normalized
    if set(result) != set(required):
        _fail("r2_constraint_invalid", "candidate constraint roster differs")
    return {"schema_version": ledger["schema_version"], "paths": result}


def attribute_r2_words_to_utterances(
    utterances: Sequence[Mapping[str, Any]],
    words: Sequence[Mapping[str, Any]],
    *,
    contract: Mapping[str, Any] = R2_TIMESTAMP_CONTRACT,
    _fixed_validated: bool = False,
) -> list[Dict[str, Any]]:
    """Attribute half-open word intervals to exactly one sample-exact utterance.

    A word must overlap the source utterance itself and both word boundaries must be
    within one 80 ms-expanded utterance.  A word wholly inside a concatenation gap is
    therefore rejected even when it lies near one side of the gap.
    """

    if not _fixed_validated:
        _validate_r2_timestamp_fixed(contract)
    tolerance = int(contract["boundary_tolerance_samples"])
    normalized_utterances = []
    previous_end = None
    ids = set()
    for index, row in enumerate(utterances):
        if not isinstance(row, Mapping) or set(row) != {"utterance_id", "start_sample", "end_sample"}:
            _fail("r2_timestamp_shape", "utterance {} shape differs".format(index))
        utterance_id = row["utterance_id"]
        start = row["start_sample"]
        end = row["end_sample"]
        if (
            not isinstance(utterance_id, str) or not utterance_id or utterance_id in ids
            or not isinstance(start, int) or isinstance(start, bool)
            or not isinstance(end, int) or isinstance(end, bool)
            or start < 0 or end <= start
            or (previous_end is not None and start < previous_end)
        ):
            _fail("r2_timestamp_shape", "utterances must be unique, ordered, non-overlapping half-open intervals")
        ids.add(utterance_id)
        previous_end = end
        normalized_utterances.append((utterance_id, start, end))
    if not normalized_utterances:
        _fail("r2_timestamp_shape", "at least one source utterance is required")
    result = []
    if not words:
        _fail("r2_timestamp_shape", "at least one word is required for attribution replay")
    word_ids = set()
    previous_word_start = None
    for index, row in enumerate(words):
        if not isinstance(row, Mapping) or set(row) != {"word_id", "start_sample", "end_sample"}:
            _fail("r2_timestamp_shape", "word {} shape differs".format(index))
        word_id = row["word_id"]
        start = row["start_sample"]
        end = row["end_sample"]
        if (
            not isinstance(word_id, str) or not word_id or word_id in word_ids
            or not isinstance(start, int) or isinstance(start, bool)
            or not isinstance(end, int) or isinstance(end, bool)
            or start < 0 or end <= start
            or (previous_word_start is not None and start < previous_word_start)
        ):
            _fail("r2_timestamp_shape", "word interval is invalid")
        word_ids.add(word_id)
        previous_word_start = start
        candidates = []
        for utterance_id, utterance_start, utterance_end in normalized_utterances:
            overlaps_source = start < utterance_end and end > utterance_start
            within_tolerance = start >= utterance_start - tolerance and end <= utterance_end + tolerance
            if overlaps_source and within_tolerance:
                candidates.append(utterance_id)
        if len(candidates) != 1:
            code = "r2_timestamp_gap_word" if not candidates else "r2_timestamp_ambiguous_attribution"
            _fail(code, "word {} maps to {} source utterances".format(word_id, len(candidates)))
        result.append({
            "word_id": word_id,
            "utterance_id": candidates[0],
            "start_sample": start,
            "end_sample": end,
        })
    return result


class SequentialProcessLock:
    """A non-blocking advisory lock shared by sequential E0 processes."""

    def __init__(self, path: Path, *, create: bool, anchor: Path) -> None:
        self.path = validate_runtime_path(path, "sequential lock", must_exist=not create)
        self.anchor = validate_runtime_path(anchor, "sequential lock anchor")
        if not self.anchor.is_dir():
            _fail("sequential_process_lock_failed", "lock anchor must be a directory")
        try:
            self.path.relative_to(self.anchor)
        except ValueError:
            _fail("sequential_process_lock_failed", "lock path must be below its stable anchor")
        self.create = create
        self._descriptor: Optional[int] = None
        self._lock_file_descriptor: Optional[int] = None
        self._parent_descriptor: Optional[int] = None

    def __enter__(self) -> "SequentialProcessLock":
        parent_descriptor, name = _open_parent_no_follow(self.path, "sequential lock")
        anchor_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
        try:
            anchor_descriptor = os.open(str(self.anchor), anchor_flags)
        except OSError as error:
            os.close(parent_descriptor)
            _fail("sequential_process_lock_failed", "cannot open stable anchor: {}".format(error))
        try:
            fcntl.flock(anchor_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(anchor_descriptor)
            os.close(parent_descriptor)
            _fail("sequential_process_lock_busy", "another E0 process holds {}".format(self.path))
        except OSError as error:
            os.close(anchor_descriptor)
            os.close(parent_descriptor)
            _fail("sequential_process_lock_failed", str(error))
        flags = os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
        if self.create:
            flags |= os.O_CREAT
        try:
            lock_descriptor = os.open(name, flags, 0o600, dir_fd=parent_descriptor)
            lock_info = os.fstat(lock_descriptor)
            named_info = os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
            if not stat.S_ISREG(lock_info.st_mode):
                _fail("sequential_process_lock_failed", "lock path is not a regular file")
            identity = lambda item: (item.st_dev, item.st_ino, item.st_mode)
            if identity(lock_info) != identity(named_info):
                _fail("sequential_process_lock_failed", "lock pathname changed during acquisition")
        except BaseException:
            try:
                os.close(lock_descriptor)
            except UnboundLocalError:
                pass
            fcntl.flock(anchor_descriptor, fcntl.LOCK_UN)
            os.close(anchor_descriptor)
            os.close(parent_descriptor)
            raise
        anchor_named = os.lstat(str(self.anchor))
        anchor_open = os.fstat(anchor_descriptor)
        if (anchor_named.st_dev, anchor_named.st_ino) != (anchor_open.st_dev, anchor_open.st_ino):
            os.close(lock_descriptor)
            fcntl.flock(anchor_descriptor, fcntl.LOCK_UN)
            os.close(anchor_descriptor)
            os.close(parent_descriptor)
            _fail("sequential_process_lock_failed", "stable anchor pathname changed")
        self._descriptor = anchor_descriptor
        self._parent_descriptor = parent_descriptor
        self._lock_file_descriptor = lock_descriptor
        return self

    def __exit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        if self._descriptor is not None:
            try:
                fcntl.flock(self._descriptor, fcntl.LOCK_UN)
            finally:
                if self._lock_file_descriptor is not None:
                    os.close(self._lock_file_descriptor)
                    self._lock_file_descriptor = None
                if self._parent_descriptor is not None:
                    os.close(self._parent_descriptor)
                    self._parent_descriptor = None
                os.close(self._descriptor)
                self._descriptor = None


def verify_deny_network(
    profile_path: Path,
    *,
    sandbox_exec: Path = Path("/usr/bin/sandbox-exec"),
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> Dict[str, Any]:
    """Verify static deny-network semantics and two denied socket operations."""

    profile, _ = stable_read(profile_path, "deny-network sandbox profile")
    try:
        text = profile.decode("utf-8")
    except UnicodeDecodeError as error:
        _fail("invalid_sandbox_profile", str(error))
    rules = [line.split(";", 1)[0].strip() for line in text.splitlines()]
    rules = [line for line in rules if line]
    comment_free = "\n".join(rules)
    if rules.count("(version 1)") != 1 or rules.count("(deny network*)") != 1:
        _fail("invalid_sandbox_profile", "profile must contain one version and one exact network* denial")
    if sum(rule in ("(allow default)", "(deny default)") for rule in rules) != 1:
        _fail("invalid_sandbox_profile", "profile must select exactly one default policy")
    if re.search(r"\(\s*allow\s+network", comment_free, flags=re.IGNORECASE):
        _fail("invalid_sandbox_profile", "profile must not contain an explicit network allow")
    executable = validate_external_path(sandbox_exec, "sandbox-exec")
    info = os.lstat(str(executable))
    if not stat.S_ISREG(info.st_mode) or not os.access(str(executable), os.X_OK):
        _fail("sandbox_exec_unavailable", "sandbox-exec is not an executable regular file")

    operations = {
        "inet_datagram_connect": "socket.socket(socket.AF_INET,socket.SOCK_DGRAM).connect(('127.0.0.1',9))",
        "inet_stream_bind": "s=socket.socket(socket.AF_INET,socket.SOCK_STREAM);s.bind(('127.0.0.1',0))",
    }
    results = []
    for name, operation in operations.items():
        sentinel = "DICOW_NETWORK_DENIED_V1:{}".format(name)
        code = (
            "import errno,socket,sys\n"
            "try:\n {}\n"
            "except PermissionError as e:\n"
            " if e.errno==errno.EPERM:\n  print({!r})\n  sys.exit(73)\n"
            " raise\n"
            "sys.exit(0)\n"
        ).format(operation, sentinel)
        completed = runner(
            [str(executable), "-f", str(profile_path), "/usr/bin/python3", "-c", code],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=30,
            check=False,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/private/var/empty", "LC_ALL": "C"},
        )
        if completed.returncode == 0:
            _fail("sandbox_network_probe_escaped", "{} unexpectedly completed".format(name))
        if completed.returncode != 73 or completed.stdout != sentinel + "\n" or completed.stderr != "":
            _fail("sandbox_network_probe_invalid", "{} did not produce the exact caught-EPERM sentinel".format(name))
        results.append({"name": name, "returncode": completed.returncode})
    return {"profile_sha256": hashlib.sha256(profile).hexdigest(), "socket_probes": results}


@dataclasses.dataclass(frozen=True)
class Promotion:
    name: str
    staged_path: Path
    final_path: Path
    expected_record: Mapping[str, Any]


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(str(path), os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _fsync_artifact(path: Path) -> None:
    info = os.lstat(str(path))
    if stat.S_ISDIR(info.st_mode):
        directories = []
        for parent, child_directories, files in os.walk(str(path), topdown=False, followlinks=False):
            for name in files:
                child = Path(parent) / name
                child_info = os.lstat(str(child))
                if stat.S_ISREG(child_info.st_mode):
                    _fsync_artifact(child)
                elif not stat.S_ISLNK(child_info.st_mode):
                    _fail("unsupported_artifact", "cannot fsync special tree entry {}".format(child))
            directories.append(Path(parent))
        for directory in directories:
            descriptor = os.open(str(directory), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        return
    descriptor = os.open(str(path), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _json_file_record(value: Any, mode: int = 0o444) -> Dict[str, Any]:
    data = canonical_json_bytes(value)
    return {
        "kind": "file",
        "bytes": len(data),
        "mode": "0{:03o}".format(mode),
        "sha256": hashlib.sha256(data).hexdigest(),
    }


def _create_only_json(path: Path, value: Any, mode: int = 0o444) -> None:
    data = canonical_json_bytes(value)
    descriptor = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    created_info = os.fstat(descriptor)
    succeeded = False
    try:
        os.fchmod(descriptor, mode)
        offset = 0
        while offset < len(data):
            offset += os.write(descriptor, data[offset:])
        os.fsync(descriptor)
        succeeded = True
    finally:
        os.close(descriptor)
        if not succeeded:
            try:
                quarantine = path.with_name(".{}.failed-write-{}".format(path.name, created_info.st_ino))
                _rename_exclusive(path, quarantine)
                observed = os.lstat(str(quarantine))
                identity = lambda item: (item.st_dev, item.st_ino)
                if identity(observed) != identity(created_info):
                    try:
                        _rename_exclusive(quarantine, path)
                    finally:
                        _fail("unresolved_partial_materialization", "create-only path changed during quarantine")
                _fsync_directory(path.parent)
            except FileNotFoundError:
                pass
    if not succeeded:
        _fail("create_only_write_failed", "create-only JSON write did not complete")
    _fsync_directory(path.parent)


def _replace_journal(path: Path, value: Mapping[str, Any]) -> None:
    temporary = path.with_name(path.name + ".next")
    if os.path.lexists(str(temporary)):
        _fail("unresolved_partial_materialization", "stale journal successor exists")
    _create_only_json(temporary, value, 0o600)
    os.replace(str(temporary), str(path))
    _fsync_directory(path.parent)


def _same_device(paths: Iterable[Path]) -> int:
    device: Optional[int] = None
    for path in paths:
        anchor, info = _existing_anchor(path)
        if device is None:
            device = int(info.st_dev)
        elif device != int(info.st_dev):
            _fail("cross_device_staging", "{} is on a different filesystem".format(anchor))
    if device is None:
        _fail("invalid_promotion", "no promotion paths")
    return device


def _rename_exclusive(source: Path, destination: Path) -> None:
    """Atomically rename without replacing a destination created by a racer."""

    library = ctypes.CDLL(None, use_errno=True)
    source_bytes = os.fsencode(str(source))
    destination_bytes = os.fsencode(str(destination))
    if sys.platform == "darwin" and hasattr(library, "renamex_np"):
        function = library.renamex_np
        function.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
        function.restype = ctypes.c_int
        result = function(source_bytes, destination_bytes, 0x00000004)  # RENAME_EXCL
    elif hasattr(library, "renameat2"):
        function = library.renameat2
        function.argtypes = (
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        )
        function.restype = ctypes.c_int
        result = function(-100, source_bytes, -100, destination_bytes, 1)  # RENAME_NOREPLACE
    else:
        _fail("exclusive_rename_unavailable", "host has no atomic no-replace rename")
    if result != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number), str(destination))


def _directory_rename_mode(path: Path, expected_record: Mapping[str, Any], *, prepare: bool) -> bool:
    """Toggle only a tree root's owner-write bit around Darwin renamex_np.

    Darwin rejects ``RENAME_EXCL`` for a non-writable source directory even when both
    parents permit the rename. Children remain sealed throughout, and the expected root
    mode is restored immediately after the atomic move (or a failed attempt).
    """

    if expected_record.get("kind") != "tree":
        return False
    expected_mode = expected_record.get("root_mode")
    if not isinstance(expected_mode, str) or not expected_mode.startswith("0"):
        _fail("invalid_promotion", "tree expected record has no root mode")
    mode = int(expected_mode, 8)
    os.chmod(str(path), mode | stat.S_IWUSR if prepare else mode, follow_symlinks=False)
    return True


def promote_create_only(
    attempt_root: Path,
    promotions: Sequence[Promotion],
    canonical_path: Path,
    canonical_payload: Mapping[str, Any],
) -> Dict[str, Any]:
    """Promote exactly four verified objects, then write canonical JSON last.

    A durable journal is updated after each rename. Any later failure moves only an
    unchanged tuple back to its attempt path in reverse order. A mismatching tuple is
    left in place and marks the attempt unresolved for manual investigation.
    """

    attempt_root = validate_runtime_path(attempt_root, "attempt root")
    if len(promotions) != 4 or len({item.name for item in promotions}) != 4:
        _fail("invalid_promotion", "exactly four uniquely named objects are required")
    journal_path = attempt_root / "partial_materialization.json"
    if os.path.lexists(str(journal_path)):
        prior = strict_load_json(journal_path, "promotion journal")
        _fail("unresolved_partial_materialization", "attempt already has journal status {}".format(prior.get("status")))
    canonical_path = validate_runtime_path(canonical_path, "canonical selector", must_exist=False)
    try:
        canonical_path.relative_to(attempt_root)
    except ValueError:
        pass
    else:
        _fail("invalid_promotion", "canonical selector must be outside its attempt root")
    if os.path.lexists(str(canonical_path)):
        _fail("preexisting_final", "canonical selector already exists")

    checked = []
    canonical_staged_path = attempt_root / ".canonical-selector.json"
    if os.path.lexists(str(canonical_staged_path)):
        _fail("unresolved_partial_materialization", "attempt already has a staged canonical selector")
    staged_paths = [Path(item.staged_path) for item in promotions]
    final_paths = [Path(item.final_path) for item in promotions]
    if len(set(staged_paths)) != 4 or len(set(final_paths)) != 4:
        _fail("invalid_promotion", "staged and final paths must each be unique")
    all_object_paths = staged_paths + final_paths + [canonical_path]
    for index, left in enumerate(all_object_paths):
        for right in all_object_paths[index + 1 :]:
            if left == right:
                _fail("invalid_promotion", "promotion and canonical paths must be disjoint")
            try:
                left.relative_to(right)
            except ValueError:
                try:
                    right.relative_to(left)
                except ValueError:
                    continue
            _fail("invalid_promotion", "promotion paths must not contain one another")
    path_set = {attempt_root, canonical_path.parent}
    for item in promotions:
        staged = validate_runtime_path(item.staged_path, item.name + " staged")
        final = validate_runtime_path(item.final_path, item.name + " final", must_exist=False)
        try:
            staged.relative_to(attempt_root)
        except ValueError:
            _fail("invalid_promotion", "staged object is outside its attempt root")
        try:
            final.relative_to(attempt_root)
        except ValueError:
            pass
        else:
            _fail("invalid_promotion", "final object must be outside its attempt root")
        if os.path.lexists(str(final)):
            _fail("preexisting_final", "final object already exists: {}".format(final))
        actual = artifact_record(staged, immutable=True)
        if actual != dict(item.expected_record):
            _fail("staged_tuple_mismatch", "{} staged tuple differs".format(item.name))
        if not final.parent.exists():
            _fail("missing_final_parent", "final parent must exist before promotion: {}".format(final.parent))
        checked.append((item, staged, final))
        path_set.update((staged, final.parent, canonical_staged_path))
    _same_device(path_set)

    journal: Dict[str, Any] = {
        "status": "promoting",
        "attempt_root": str(attempt_root),
        "canonical_path": str(canonical_path),
        "promoted": [],
        "objects": [
            {
                "name": item.name,
                "staged_path": str(staged),
                "final_path": str(final),
                "expected_record": dict(item.expected_record),
            }
            for item, staged, final in checked
        ],
    }
    _create_only_json(journal_path, journal, 0o600)
    moved: list[Tuple[Promotion, Path, Path]] = []
    canonical_promoted = False
    try:
        for item, staged, final in checked:
            directory_mode_toggled = _directory_rename_mode(staged, item.expected_record, prepare=True)
            try:
                _rename_exclusive(staged, final)
            except BaseException:
                if directory_mode_toggled and os.path.lexists(str(staged)):
                    _directory_rename_mode(staged, item.expected_record, prepare=False)
                raise
            moved.append((item, staged, final))
            if directory_mode_toggled:
                _directory_rename_mode(final, item.expected_record, prepare=False)
            _fsync_artifact(final)
            if artifact_record(final, immutable=True) != dict(item.expected_record):
                raise OSError("promoted tuple differs after rename: {}".format(item.name))
            _fsync_directory(staged.parent)
            _fsync_directory(final.parent)
            journal["promoted"] = [entry[0].name for entry in moved]
            _replace_journal(journal_path, journal)
        for item, _, final in moved:
            if artifact_record(final, immutable=True) != dict(item.expected_record):
                raise OSError("final tuple drifted before canonical promotion: {}".format(item.name))
        _create_only_json(canonical_staged_path, canonical_payload, 0o444)
        _rename_exclusive(canonical_staged_path, canonical_path)
        canonical_promoted = True
        _fsync_artifact(canonical_path)
        _fsync_directory(canonical_staged_path.parent)
        _fsync_directory(canonical_path.parent)
        for item, _, final in moved:
            if artifact_record(final, immutable=True) != dict(item.expected_record):
                raise OSError("final tuple drifted during canonical promotion: {}".format(item.name))
        journal["status"] = "complete"
        _replace_journal(journal_path, journal)
        os.chmod(str(journal_path), 0o444, follow_symlinks=False)
        _fsync_artifact(journal_path)
        _fsync_directory(journal_path.parent)
        return dict(journal)
    except BaseException as error:
        if canonical_promoted:
            try:
                if os.path.lexists(str(canonical_staged_path)):
                    raise OSError("canonical rollback destination already exists")
                _rename_exclusive(canonical_path, canonical_staged_path)
                _fsync_directory(canonical_path.parent)
                _fsync_directory(canonical_staged_path.parent)
                if file_record(canonical_staged_path, immutable=True) != _json_file_record(canonical_payload):
                    try:
                        _rename_exclusive(canonical_staged_path, canonical_path)
                    finally:
                        raise OSError("canonical tuple changed during rollback")
            except BaseException:
                journal["status"] = "unresolved"
                journal["rollback_error"] = "canonical selector could not be safely removed"
                _replace_journal(journal_path, journal)
                _fail("unresolved_partial_materialization", journal["rollback_error"])
        rollback_error = None
        for item, staged, final in reversed(moved):
            try:
                if os.path.lexists(str(staged)) or not os.path.lexists(str(final)):
                    raise OSError("rollback source/destination state changed")
                if item.expected_record.get("kind") == "tree":
                    _directory_rename_mode(final, item.expected_record, prepare=False)
                if artifact_record(final, immutable=True) != dict(item.expected_record):
                    raise OSError("promoted tuple changed")
                directory_mode_toggled = _directory_rename_mode(final, item.expected_record, prepare=True)
                try:
                    _rename_exclusive(final, staged)
                except BaseException:
                    if directory_mode_toggled and os.path.lexists(str(final)):
                        _directory_rename_mode(final, item.expected_record, prepare=False)
                    raise
                if directory_mode_toggled:
                    _directory_rename_mode(staged, item.expected_record, prepare=False)
                _fsync_artifact(staged)
                if artifact_record(staged, immutable=True) != dict(item.expected_record):
                    try:
                        toggled_back = _directory_rename_mode(staged, item.expected_record, prepare=True)
                        _rename_exclusive(staged, final)
                        if toggled_back:
                            _directory_rename_mode(final, item.expected_record, prepare=False)
                    finally:
                        raise OSError("tuple changed during rollback rename")
                _fsync_directory(final.parent)
                _fsync_directory(staged.parent)
            except BaseException as rollback_failure:
                rollback_error = "{}: {}".format(item.name, rollback_failure)
                break
        if rollback_error is None:
            for item, staged, _ in moved:
                try:
                    if artifact_record(staged, immutable=True) != dict(item.expected_record):
                        raise OSError("recovered staged tuple differs")
                except BaseException as final_audit_failure:
                    rollback_error = "{} final rollback audit: {}".format(item.name, final_audit_failure)
                    break
        journal["status"] = "unresolved" if rollback_error else "rolled_back"
        journal["rollback_error"] = rollback_error
        _replace_journal(journal_path, journal)
        if rollback_error:
            _fail("unresolved_partial_materialization", rollback_error)
        if isinstance(error, PreflightError):
            raise error
        _fail("partial_materialization", str(error))


def verify_promotion(
    attempt_root: Path,
    promotions: Sequence[Promotion],
    canonical_path: Path,
    canonical_payload: Mapping[str, Any],
) -> Dict[str, Any]:
    """Read-only, idempotent verification of a completed promotion."""

    attempt_root = validate_runtime_path(attempt_root, "attempt root")
    journal_path = attempt_root / "partial_materialization.json"
    journal = strict_load_json(journal_path, "promotion journal")
    if journal.get("status") != "complete":
        _fail("unresolved_partial_materialization", "promotion journal is not complete")
    journal_info = os.lstat(str(journal_path))
    if stat.S_IMODE(journal_info.st_mode) & 0o222:
        _fail("promotion_verification_failed", "completed promotion journal is writable")
    if len(promotions) != 4 or len({item.name for item in promotions}) != 4:
        _fail("invalid_promotion", "exactly four uniquely named objects are required")
    staged_paths = [Path(item.staged_path) for item in promotions]
    final_paths = [Path(item.final_path) for item in promotions]
    if len(set(staged_paths)) != 4 or len(set(final_paths)) != 4:
        _fail("invalid_promotion", "staged and final paths must each be unique")
    canonical_path = validate_runtime_path(canonical_path, "canonical selector")
    try:
        canonical_path.relative_to(attempt_root)
    except ValueError:
        pass
    else:
        _fail("invalid_promotion", "canonical selector must be outside its attempt root")
    all_paths = staged_paths + final_paths + [canonical_path]
    for index, left in enumerate(all_paths):
        for right in all_paths[index + 1 :]:
            try:
                left.relative_to(right)
            except ValueError:
                try:
                    right.relative_to(left)
                except ValueError:
                    continue
            _fail("invalid_promotion", "verification paths must be disjoint")
    for staged, final in zip(staged_paths, final_paths):
        try:
            staged.relative_to(attempt_root)
        except ValueError:
            _fail("invalid_promotion", "staged verification path is outside attempt")
        try:
            final.relative_to(attempt_root)
        except ValueError:
            pass
        else:
            _fail("invalid_promotion", "final verification path is inside attempt")
    expected_journal_objects = [
        {
            "name": item.name,
            "staged_path": str(item.staged_path),
            "final_path": str(item.final_path),
            "expected_record": dict(item.expected_record),
        }
        for item in promotions
    ]
    expected_journal = {
        "status": "complete",
        "attempt_root": str(attempt_root),
        "canonical_path": str(canonical_path),
        "promoted": [item.name for item in promotions],
        "objects": expected_journal_objects,
    }
    if journal != expected_journal:
        _fail("promotion_verification_failed", "promotion journal binding differs")
    journal_bytes, _ = stable_read(journal_path, "promotion journal")
    if journal_bytes != canonical_json_bytes(expected_journal):
        _fail("promotion_verification_failed", "promotion journal bytes are not canonical and exact")
    for item in promotions:
        if os.path.lexists(str(item.staged_path)):
            _fail("promotion_verification_failed", "staged path remains: {}".format(item.name))
        final = validate_runtime_path(item.final_path, item.name + " final")
        if artifact_record(final, immutable=True) != dict(item.expected_record):
            _fail("promotion_verification_failed", "final tuple differs: {}".format(item.name))
    canonical = strict_load_json(canonical_path, "canonical selector")
    canonical_bytes, _ = stable_read(canonical_path, "canonical selector")
    if canonical != dict(canonical_payload) or canonical_bytes != canonical_json_bytes(canonical_payload):
        _fail("promotion_verification_failed", "canonical selector differs")
    if file_record(canonical_path, immutable=True) != _json_file_record(canonical_payload):
        _fail("promotion_verification_failed", "canonical selector tuple differs")
    _same_device([attempt_root, canonical_path.parent] + final_paths)
    return {"status": "complete", "objects": [item.name for item in promotions]}


def conversion_payload_regression() -> Dict[str, Any]:
    if sum(CONVERSION_PAYLOAD_BYTES.values()) != CONVERSION_PAYLOAD_TOTAL_BYTES:
        _fail("resource_formula_unresolved", "six conversion payload figures do not sum exactly")
    return {
        "payload_bytes": dict(CONVERSION_PAYLOAD_BYTES),
        "total_payload_bytes": CONVERSION_PAYLOAD_TOTAL_BYTES,
        "dicow_budget_status": "conditional",
        "dicow_budget_note": CONDITIONAL_DICOW_BUDGET_NOTE,
    }
