#!/usr/bin/env python3
"""Fail-closed executable contract for the DiCoW CTC-omission proof.

This module does not import or run a model itself.  It coordinates a separately
provided runner in fresh CPU/FP32 processes and validates compact, hash-based
observations.  Tensor payloads, including the deliberately NaN CTC branch
output, are never accepted in the runner protocol.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import stat
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Sequence

from benchmarks.scripts.dicow.common.pins import GRAPH_PINS


UNIVERSE_SCHEMA_VERSION = "dicow-ctc-request-universe-v1"
SOURCE_SCHEMA_VERSION = "dicow-ctc-source-requests-v1"
OBSERVATION_SCHEMA_VERSION = "dicow-ctc-observation-v1"
REPORT_SCHEMA_VERSION = "dicow-ctc-invariance-report-v1"
SCENARIOS = ("baseline_a", "baseline_b", "nan_perturbation", "branch_bypass")
CTC_TENSOR_NAMES = tuple(GRAPH_PINS["ctc_tensor_names"])
_SHA256 = re.compile(r"[0-9a-f]{64}\Z")
_RUNNER_OPTION = re.compile(r"-{1,2}[A-Za-z0-9][A-Za-z0-9_-]*\Z")


class ContractError(RuntimeError):
    """Raised when evidence is incomplete, malformed, or not reproducible."""


@dataclass(frozen=True)
class ProofRequest:
    request_id: str
    source: str
    signature: Mapping[str, Any]
    signature_sha256: str


@dataclass(frozen=True)
class RequestUniverse:
    path: Path
    sha256: str
    t10_sha256: str
    ami_sha256: str
    r1_captures: tuple[str, ...]
    r2_captures: tuple[str, ...]
    requests: tuple[ProofRequest, ...]


def _fail(message: str) -> None:
    raise ContractError(message)


def _reject_constant(value: str) -> None:
    _fail("non-finite JSON number is forbidden: {}".format(value))


def _object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            _fail("duplicate JSON key")
        result[key] = value
    return result


def _loads(raw: bytes, label: str) -> Any:
    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_object,
            parse_constant=_reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        _fail("cannot parse {} as strict JSON: {}".format(label, error))
    _finite_tree(value, label)
    return value


def _finite_tree(value: Any, field: str) -> None:
    if isinstance(value, float) and not math.isfinite(value):
        _fail("{} contains a non-finite number".format(field))
    if isinstance(value, list):
        for index, item in enumerate(value):
            _finite_tree(item, "{}[{}]".format(field, index))
    elif isinstance(value, dict):
        for key, item in value.items():
            _finite_tree(item, "{}.{}".format(field, key))


def _canonical(value: Any) -> bytes:
    try:
        return (
            json.dumps(
                value,
                allow_nan=False,
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
            )
            + "\n"
        ).encode("utf-8")
    except (TypeError, ValueError) as error:
        _fail("value cannot be encoded as canonical strict JSON: {}".format(error))


def _exact_keys(value: Any, expected: set[str], field: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        _fail("{} must be an object".format(field))
    observed = set(value)
    if observed != expected:
        _fail(
            "{} keys differ: missing={} extra={}".format(
                field, sorted(expected - observed), sorted(observed - expected)
            )
        )
    return value


def _string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value:
        _fail("{} must be a non-empty string".format(field))
    return value


def _text(value: Any, field: str) -> str:
    if not isinstance(value, str):
        _fail("{} must be a string".format(field))
    return value


def _integer(value: Any, field: str, minimum: int | None = None) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        _fail("{} must be an integer".format(field))
    if minimum is not None and value < minimum:
        _fail("{} must be at least {}".format(field, minimum))
    return value


def _number(value: Any, field: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        _fail("{} must be a finite number".format(field))
    try:
        result = float(value)
    except OverflowError:
        _fail("{} must be representable as a finite float".format(field))
    if not math.isfinite(result):
        _fail("{} must be a finite number".format(field))
    return result


def _string_array(value: Any, field: str, nonempty: bool = False) -> tuple[str, ...]:
    if not isinstance(value, list) or (nonempty and not value):
        _fail("{} must be {}array".format(field, "a non-empty " if nonempty else "an "))
    result = tuple(_string(item, "{}[]".format(field)) for item in value)
    if len(result) != len(set(result)):
        _fail("{} must not contain duplicates".format(field))
    return result


def _stable_read(path: Path, label: str) -> tuple[bytes, os.stat_result]:
    if not path.is_absolute() or os.path.normpath(str(path)) != str(path):
        _fail("{} must be an absolute normalized path".format(label))
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current = current / part
        try:
            info = os.lstat(current)
        except FileNotFoundError:
            _fail("{} does not exist: {}".format(label, path))
        if stat.S_ISLNK(info.st_mode):
            _fail("{} contains a symlink component: {}".format(label, current))
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        _fail("cannot open {}: {}".format(label, error))
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            _fail("{} must be a regular file".format(label))
        chunks: list[bytes] = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (
        after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns
    ):
        _fail("{} changed while being read".format(label))
    final = os.lstat(path)
    if (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) != (
        final.st_dev, final.st_ino, final.st_size, final.st_mtime_ns
    ):
        _fail("{} path changed while being read".format(label))
    return b"".join(chunks), after


def _runner_command_sha256(runner_argv: Sequence[str]) -> str:
    if not runner_argv or any(not isinstance(item, str) or not item for item in runner_argv):
        _fail("runner argv must be a non-empty sequence of strings")
    executable = Path(runner_argv[0])
    if not executable.is_absolute():
        _fail("runner executable must be an absolute path")
    entries: list[dict[str, Any]] = []
    for index, argument in enumerate(runner_argv):
        candidate = Path(argument)
        if candidate.is_absolute() and candidate.exists():
            try:
                resolved = candidate.resolve(strict=True)
            except OSError as error:
                _fail("cannot resolve runner command file: {}".format(error))
            raw, info = _stable_read(resolved, "runner command file")
            entries.append({
                "argument": argument,
                "resolved_path": str(resolved),
                "bytes": info.st_size,
                "sha256": hashlib.sha256(raw).hexdigest(),
                "mode": "0{:03o}".format(stat.S_IMODE(info.st_mode)),
            })
        else:
            if index > 0 and not _RUNNER_OPTION.fullmatch(argument):
                _fail(
                    "runner arguments after the executable must be absolute files or fixed options"
                )
            entries.append({"argument": argument})
    return hashlib.sha256(_canonical(entries)).hexdigest()


def _signature_hash(signature: Mapping[str, Any]) -> str:
    return hashlib.sha256(_canonical(signature)).hexdigest()


def load_universe(
    path: Path,
    expected_sha256: str,
    *,
    expected_t10_sha256: str,
    expected_ami_sha256: str,
) -> RequestUniverse:
    """Load a sealed universe and prove its exact filtered request set."""
    if not _SHA256.fullmatch(expected_sha256):
        _fail("expected universe SHA-256 must be 64 lowercase hex characters")
    raw, info = _stable_read(path, "request universe")
    observed_sha256 = hashlib.sha256(raw).hexdigest()
    if observed_sha256 != expected_sha256:
        _fail("request universe SHA-256 mismatch")
    if stat.S_IMODE(info.st_mode) != 0o444:
        _fail("request universe must be sealed mode 0444")
    value = _exact_keys(
        _loads(raw, "request universe"),
        {
            "schema_version",
            "capture_contract",
            "source_manifests",
            "proof_request_sha256s",
        },
        "request universe",
    )
    if value["schema_version"] != UNIVERSE_SCHEMA_VERSION:
        _fail("unsupported request-universe schema version")
    captures = _exact_keys(value["capture_contract"], {"r1", "r2"}, "capture_contract")
    r1 = _string_array(captures["r1"], "capture_contract.r1", nonempty=True)
    r2 = _string_array(captures["r2"], "capture_contract.r2", nonempty=True)
    if set(r1) & set(r2):
        _fail("R1 and R2 capture names must be disjoint")

    bindings = _exact_keys(
        value["source_manifests"], {"t10", "ami_parity"}, "source_manifests"
    )

    def load_source(role: str, independent_sha256: str) -> list[Any]:
        if not _SHA256.fullmatch(independent_sha256):
            _fail("independent {} SHA-256 is invalid".format(role))
        binding = _exact_keys(
            bindings[role], {"path", "sha256"}, "source_manifests." + role
        )
        source_path = Path(_string(binding["path"], "source_manifests.{}.path".format(role)))
        bound_sha256 = _string(binding["sha256"], "source_manifests.{}.sha256".format(role))
        if bound_sha256 != independent_sha256:
            _fail("{} source binding does not match its independently sealed SHA-256".format(role))
        source_raw, source_info = _stable_read(source_path, role + " request source")
        if stat.S_IMODE(source_info.st_mode) != 0o444:
            _fail("{} request source must be sealed mode 0444".format(role))
        if hashlib.sha256(source_raw).hexdigest() != independent_sha256:
            _fail("{} request source SHA-256 mismatch".format(role))
        source_value = _exact_keys(
            _loads(source_raw, role + " request source"),
            {"schema_version", "source", "requests"},
            role + " request source",
        )
        if source_value["schema_version"] != SOURCE_SCHEMA_VERSION or source_value["source"] != role:
            _fail("{} request source identity is invalid".format(role))
        if not isinstance(source_value["requests"], list) or not source_value["requests"]:
            _fail("{} request source must contain requests".format(role))
        return source_value["requests"]

    t10_rows = load_source("t10", expected_t10_sha256)
    ami_rows = load_source("ami_parity", expected_ami_sha256)

    all_ids: set[str] = set()
    all_signatures: set[str] = set()
    selected: list[ProofRequest] = []

    def parse_rows(raw_rows: Any, source: str) -> None:
        if not isinstance(raw_rows, list) or not raw_rows:
            _fail("{} must be a non-empty array".format(source))
        for index, raw_row in enumerate(raw_rows):
            field = "{}[{}]".format(source, index)
            row = _exact_keys(
                raw_row,
                {"request_id", "model_kind", "invocation_kind", "signature"},
                field,
            )
            request_id = _string(row["request_id"], field + ".request_id")
            if request_id in all_ids:
                _fail("duplicate request_id in universe: {}".format(request_id))
            all_ids.add(request_id)
            model_kind = _string(row["model_kind"], field + ".model_kind")
            invocation_kind = _string(row["invocation_kind"], field + ".invocation_kind")
            if model_kind not in {"dicow", "vanilla_control"}:
                _fail("{} has an unknown model_kind".format(field))
            if invocation_kind not in {"actual", "virtual_absent"}:
                _fail("{} has an unknown invocation_kind".format(field))
            if not isinstance(row["signature"], dict) or not row["signature"]:
                _fail("{}.signature must be a non-empty object".format(field))
            digest = _signature_hash(row["signature"])
            if digest in all_signatures:
                _fail("duplicate request signature in universe: {}".format(digest))
            all_signatures.add(digest)
            should_select = model_kind == "dicow" and invocation_kind == "actual"
            if source == "ami_parity" and not should_select:
                _fail("AMI parity replays must all be actual DiCoW requests")
            if should_select:
                selected.append(ProofRequest(request_id, source, row["signature"], digest))

    parse_rows(t10_rows, "t10")
    t10_selected = len(selected)
    if t10_selected == 0:
        _fail("sealed T10 source contains no actual DiCoW request")
    parse_rows(ami_rows, "ami_parity")
    if len(selected) == t10_selected:
        _fail("sealed AMI source contains no actual DiCoW parity replay")
    declared = _string_array(
        value["proof_request_sha256s"], "proof_request_sha256s", nonempty=True
    )
    for digest in declared:
        if not _SHA256.fullmatch(digest):
            _fail("proof_request_sha256s contains an invalid SHA-256")
    expected = tuple(sorted(request.signature_sha256 for request in selected))
    if declared != expected:
        _fail("proof request universe does not exactly match filtered T10 plus AMI requests")
    return RequestUniverse(
        path.absolute(), observed_sha256, expected_t10_sha256, expected_ami_sha256,
        r1, r2, tuple(selected)
    )


def _tensor(value: Any, field: str) -> Mapping[str, Any]:
    tensor = _exact_keys(
        value,
        {"shape", "dtype", "byte_order", "layout", "bytes", "sha256", "finite"},
        field,
    )
    if not isinstance(tensor["shape"], list) or not tensor["shape"]:
        _fail("{}.shape must be a non-empty array".format(field))
    elements = 1
    for index, dimension in enumerate(tensor["shape"]):
        elements *= _integer(dimension, "{}.shape[{}]".format(field, index), 1)
    if tensor["dtype"] != "float32":
        _fail("{}.dtype must be float32".format(field))
    if tensor["byte_order"] != "little" or tensor["layout"] != "c_contiguous":
        _fail("{} must use little-endian C-contiguous tensor bytes".format(field))
    if _integer(tensor["bytes"], field + ".bytes", 1) != elements * 4:
        _fail("{}.bytes does not match its FP32 shape".format(field))
    if not _SHA256.fullmatch(_string(tensor["sha256"], field + ".sha256")):
        _fail("{}.sha256 is invalid".format(field))
    if tensor["finite"] is not True:
        _fail("{} must declare all decoder-facing values finite".format(field))
    return tensor


def _integer_array(value: Any, field: str, nonempty: bool = False) -> tuple[int, ...]:
    if not isinstance(value, list) or (nonempty and not value):
        _fail("{} must be {}array".format(field, "a non-empty " if nonempty else "an "))
    return tuple(_integer(item, "{}[]".format(field), 0) for item in value)


def _validate_observation(
    value: Any,
    request: ProofRequest,
    scenario: str,
    universe: RequestUniverse,
    actual_pid: int,
    expected_runner_sha256: str,
) -> Mapping[str, Any]:
    record = _exact_keys(
        value,
        {
            "schema_version",
            "request_sha256",
            "scenario",
            "process",
            "execution_binding",
            "ctc_branch",
            "observables",
        },
        "runner observation",
    )
    if record["schema_version"] != OBSERVATION_SCHEMA_VERSION:
        _fail("runner observation has wrong schema version")
    if record["request_sha256"] != request.signature_sha256:
        _fail("runner observation is bound to the wrong request")
    if record["scenario"] != scenario:
        _fail("runner observation is bound to the wrong scenario")
    process = _exact_keys(
        record["process"],
        {
            "pid", "device", "dtype", "attention", "deterministic_algorithms",
            "threads", "seed", "decode", "previous_token_conditioning",
        },
        "process",
    )
    if _integer(process["pid"], "process.pid", 1) != actual_pid:
        _fail("runner-reported PID does not match the fresh subprocess")
    expected_process = {
        "device": "cpu", "dtype": "float32", "attention": "eager",
        "deterministic_algorithms": True, "threads": 1, "seed": 0,
        "decode": "greedy", "previous_token_conditioning": False,
    }
    for key, expected in expected_process.items():
        if process[key] != expected:
            _fail("process.{} does not match the frozen reference setting".format(key))

    binding = _exact_keys(
        record["execution_binding"],
        {
            "runner_sha256", "model_sha256", "model_config_sha256",
            "input_sha256", "instrumentation_sha256",
        },
        "execution_binding",
    )
    for key, digest in binding.items():
        if not _SHA256.fullmatch(_string(digest, "execution_binding." + key)):
            _fail("execution_binding.{} is not a SHA-256".format(key))
    if binding["input_sha256"] != request.signature_sha256:
        _fail("execution binding does not name the sealed request signature")
    if binding["runner_sha256"] != expected_runner_sha256:
        _fail("execution binding does not match the coordinator-hashed runner command")

    branch = _exact_keys(
        record["ctc_branch"],
        {"calls", "processor_present", "perturbed_tensor_names", "bypassed", "output_summary"},
        "ctc_branch",
    )
    calls = _integer(branch["calls"], "ctc_branch.calls", 0)
    if branch["processor_present"] is not False:
        _fail("a CTC decode processor was present")
    names = _string_array(branch["perturbed_tensor_names"], "ctc_branch.perturbed_tensor_names")
    if not isinstance(branch["bypassed"], bool):
        _fail("ctc_branch.bypassed must be boolean")
    if scenario == "nan_perturbation":
        if names != CTC_TENSOR_NAMES:
            _fail("NaN perturbation did not cover the exact ten-tensor CTC set")
        if calls != 1 or branch["bypassed"] is not False:
            _fail("NaN perturbation must execute the complete CTC branch exactly once")
        summary = _exact_keys(branch["output_summary"], {"all_nan", "shape", "dtype"}, "ctc_branch.output_summary")
        if summary["all_nan"] is not True or summary["dtype"] != "float32":
            _fail("NaN perturbation did not produce the declared FP32 all-NaN branch output")
        if not isinstance(summary["shape"], list) or not summary["shape"]:
            _fail("ctc_branch.output_summary.shape must be non-empty")
        for index, dimension in enumerate(summary["shape"]):
            _integer(dimension, "ctc_branch.output_summary.shape[{}]".format(index), 1)
    elif scenario == "branch_bypass":
        if names or calls != 0 or branch["bypassed"] is not True or branch["output_summary"] is not None:
            _fail("branch bypass must make zero calls and serialize no branch output")
    else:
        if names or calls != 1 or branch["bypassed"] is not False:
            _fail("baseline must execute the unperturbed CTC branch exactly once")
        summary = _exact_keys(branch["output_summary"], {"all_nan", "shape", "dtype"}, "ctc_branch.output_summary")
        if summary["all_nan"] is not False or summary["dtype"] != "float32":
            _fail("baseline CTC output summary is invalid")
        if not isinstance(summary["shape"], list) or not summary["shape"]:
            _fail("ctc_branch.output_summary.shape must be non-empty")
        for index, dimension in enumerate(summary["shape"]):
            _integer(dimension, "ctc_branch.output_summary.shape[{}]".format(index), 1)

    observables = _exact_keys(
        record["observables"],
        {
            "encoder_post_layernorm", "r1_captures", "r2_captures",
            "decoder_input_ids", "teacher_forced_input_ids_sha256",
            "teacher_forced_logits", "greedy_token_ids",
            "greedy_timestamp_ids", "greedy_text", "segments", "boundaries",
        },
        "observables",
    )
    _tensor(observables["encoder_post_layernorm"], "observables.encoder_post_layernorm")
    for rung, names_expected in (("r1_captures", universe.r1_captures), ("r2_captures", universe.r2_captures)):
        captures = _exact_keys(observables[rung], set(names_expected), "observables." + rung)
        for name in names_expected:
            _tensor(captures[name], "observables.{}.{}".format(rung, name))
    decoder_input_ids = _integer_array(
        observables["decoder_input_ids"], "observables.decoder_input_ids", nonempty=True
    )
    input_digest = hashlib.sha256(_canonical(list(decoder_input_ids))).hexdigest()
    if observables["teacher_forced_input_ids_sha256"] != input_digest:
        _fail("teacher-forced logits are not bound to the declared decoder input IDs")
    _tensor(observables["teacher_forced_logits"], "observables.teacher_forced_logits")
    _integer_array(observables["greedy_token_ids"], "observables.greedy_token_ids")
    _integer_array(observables["greedy_timestamp_ids"], "observables.greedy_timestamp_ids")
    _text(observables["greedy_text"], "observables.greedy_text")
    if not isinstance(observables["segments"], list):
        _fail("observables.segments must be an array")
    for index, raw_segment in enumerate(observables["segments"]):
        segment = _exact_keys(
            raw_segment,
            {"start_seconds", "end_seconds", "text", "text_token_ids", "timestamp_token_ids"},
            "observables.segments[{}]".format(index),
        )
        start = _number(segment["start_seconds"], "segment.start_seconds")
        end = _number(segment["end_seconds"], "segment.end_seconds")
        if start < 0 or end < start:
            _fail("segment boundaries are invalid")
        _text(segment["text"], "segment.text")
        _integer_array(segment["text_token_ids"], "segment.text_token_ids")
        _integer_array(segment["timestamp_token_ids"], "segment.timestamp_token_ids")
    if not isinstance(observables["boundaries"], list):
        _fail("observables.boundaries must be an array")
    for index, raw_boundary in enumerate(observables["boundaries"]):
        boundary = _exact_keys(
            raw_boundary,
            {"segment_index", "start_seconds", "end_seconds"},
            "observables.boundaries[{}]".format(index),
        )
        _integer(boundary["segment_index"], "boundary.segment_index", 0)
        start = _number(boundary["start_seconds"], "boundary.start_seconds")
        end = _number(boundary["end_seconds"], "boundary.end_seconds")
        if start < 0 or end < start:
            _fail("boundary record is invalid")
    if len(observables["boundaries"]) != len(observables["segments"]):
        _fail("segment and boundary record counts differ")
    for index, (boundary, segment) in enumerate(
        zip(observables["boundaries"], observables["segments"], strict=True)
    ):
        if boundary["segment_index"] != index:
            _fail("boundary indices must exactly cover ordered segment indices")
        if (
            boundary["start_seconds"] != segment["start_seconds"]
            or boundary["end_seconds"] != segment["end_seconds"]
        ):
            _fail("boundary times must exactly match their referenced segment")
    return record


def _runner_environment(extra: Mapping[str, str] | None) -> dict[str, str]:
    environment = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONHASHSEED": "0",
        "HF_HUB_OFFLINE": "1",
        "TRANSFORMERS_OFFLINE": "1",
        "CUDA_VISIBLE_DEVICES": "",
        "PYTORCH_ENABLE_MPS_FALLBACK": "0",
        "OMP_NUM_THREADS": "1",
        "MKL_NUM_THREADS": "1",
        "TOKENIZERS_PARALLELISM": "false",
    }
    if extra:
        for key, value in extra.items():
            if not isinstance(key, str) or not key.startswith("DICOW_TEST_") or not isinstance(value, str):
                _fail("extra runner environment is restricted to DICOW_TEST_* strings")
            environment[key] = value
    return environment


def _run_one(
    runner_argv: Sequence[str],
    request: ProofRequest,
    scenario: str,
    universe: RequestUniverse,
    timeout_seconds: int,
    extra_env: Mapping[str, str] | None,
    attempt_kind: str,
) -> tuple[Mapping[str, Any], int]:
    runner_sha256 = _runner_command_sha256(runner_argv)
    environment = _runner_environment(extra_env)
    environment["DICOW_CTC_PROOF_SCENARIO"] = scenario
    environment["DICOW_CTC_PROOF_ATTEMPT"] = attempt_kind
    environment["DICOW_CTC_PROOF_REQUEST_SHA256"] = request.signature_sha256
    environment["DICOW_CTC_PROOF_RUNNER_SHA256"] = runner_sha256
    try:
        process = subprocess.Popen(
            list(runner_argv),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
        )
        stdout, stderr = process.communicate(_canonical(request.signature), timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        process.kill()
        process.communicate()
        _fail("runner timed out for {} {}".format(request.request_id, scenario))
    except OSError as error:
        _fail("cannot start runner: {}".format(error))
    if process.returncode != 0:
        stderr_sha256 = hashlib.sha256(stderr).hexdigest()
        _fail(
            "runner failed for {} {} with code {}; stderr_bytes={}; stderr_sha256={}".format(
                request.request_id,
                scenario,
                process.returncode,
                len(stderr),
                stderr_sha256,
            )
        )
    record = _validate_observation(
        _loads(stdout, "runner stdout"), request, scenario, universe, process.pid,
        runner_sha256,
    )
    return record, process.pid


def _observable_mismatches(left: Mapping[str, Any], right: Mapping[str, Any]) -> list[str]:
    left_observables = left["observables"]
    right_observables = right["observables"]
    mismatches: list[str] = []
    for key in (
        "encoder_post_layernorm", "r1_captures", "r2_captures",
        "decoder_input_ids", "teacher_forced_input_ids_sha256",
        "teacher_forced_logits", "greedy_token_ids",
        "greedy_timestamp_ids", "greedy_text", "segments", "boundaries",
    ):
        if _canonical(left_observables[key]) != _canonical(right_observables[key]):
            mismatches.append(key)
    return mismatches


def _execute_attempt(
    universe: RequestUniverse,
    runner_argv: Sequence[str],
    timeout_seconds: int,
    extra_env: Mapping[str, str] | None,
    attempt_kind: str,
) -> tuple[str, list[dict[str, Any]]]:
    summaries: list[dict[str, Any]] = []
    all_pids: set[int] = set()
    for request in universe.requests:
        records: dict[str, Mapping[str, Any]] = {}
        for scenario in SCENARIOS:
            record, pid = _run_one(
                runner_argv, request, scenario, universe, timeout_seconds, extra_env,
                attempt_kind,
            )
            if pid in all_pids:
                _fail("runner process was reused instead of being fresh")
            all_pids.add(pid)
            records[scenario] = record
        first_binding = records["baseline_a"]["execution_binding"]
        if any(records[scenario]["execution_binding"] != first_binding for scenario in SCENARIOS[1:]):
            _fail("execution binding changed across scenarios for {}".format(request.request_id))
        baseline_branch = records["baseline_a"]["ctc_branch"]
        if baseline_branch != records["baseline_b"]["ctc_branch"]:
            _fail("baseline CTC instrumentation is nondeterministic for {}".format(request.request_id))
        nan_branch = records["nan_perturbation"]["ctc_branch"]
        if (
            nan_branch["calls"] != baseline_branch["calls"]
            or nan_branch["output_summary"]["shape"] != baseline_branch["output_summary"]["shape"]
            or nan_branch["output_summary"]["dtype"] != baseline_branch["output_summary"]["dtype"]
        ):
            _fail("NaN perturbation CTC instrumentation differs from baseline")
        repeat_mismatches = _observable_mismatches(records["baseline_a"], records["baseline_b"])
        if repeat_mismatches:
            _fail(
                "baseline is nondeterministic for {}: {}".format(
                    request.request_id, ",".join(repeat_mismatches)
                )
            )
        perturb_mismatches = _observable_mismatches(records["baseline_a"], records["nan_perturbation"])
        bypass_mismatches = _observable_mismatches(records["baseline_a"], records["branch_bypass"])
        summaries.append({
            "request_id": request.request_id,
            "request_sha256": request.signature_sha256,
            "source": request.source,
            "process_count": len(SCENARIOS),
            "execution_binding": dict(first_binding),
            "perturbation_mismatches": perturb_mismatches,
            "bypass_mismatches": bypass_mismatches,
        })
    status = "difference" if any(
        item["perturbation_mismatches"] or item["bypass_mismatches"] for item in summaries
    ) else "pass"
    invariant_keys = (
        "runner_sha256", "model_sha256", "model_config_sha256", "instrumentation_sha256"
    )
    first = summaries[0]["execution_binding"]
    for summary in summaries[1:]:
        binding = summary["execution_binding"]
        if any(binding[key] != first[key] for key in invariant_keys):
            _fail("runner, model, config, or instrumentation changed across the request universe")
    return status, summaries


def execute_proof(
    universe: RequestUniverse,
    runner_argv: Sequence[str],
    *,
    repair_runner_argv: Sequence[str] | None = None,
    timeout_seconds: int = 1800,
    runner_env: Mapping[str, str] | None = None,
    repair_runner_env: Mapping[str, str] | None = None,
) -> dict[str, Any]:
    """Execute the proof contract and return a typed, non-publishable verdict.

    A semantic difference may be adjudicated once with an explicitly supplied
    repaired runner.  Malformed, incomplete, or nondeterministic evidence never
    becomes negative model evidence.
    """
    if isinstance(timeout_seconds, bool) or not isinstance(timeout_seconds, int) or timeout_seconds < 1:
        _fail("timeout_seconds must be a positive integer")
    report: dict[str, Any] = {
        "schema_version": REPORT_SCHEMA_VERSION,
        "universe": {
            "path": str(universe.path),
            "sha256": universe.sha256,
            "t10_sha256": universe.t10_sha256,
            "ami_sha256": universe.ami_sha256,
            "request_count": len(universe.requests),
        },
        "actual_model_proof_completed": False,
        "repair_attempts": 0,
        "attempts": [],
    }
    try:
        if len(CTC_TENSOR_NAMES) != 10 or len(set(CTC_TENSOR_NAMES)) != 10:
            _fail("pinned CTC tensor universe must contain exactly ten unique names")
        initial_status, initial = _execute_attempt(
            universe, runner_argv, timeout_seconds, runner_env, "initial"
        )
        report["attempts"].append({"kind": "initial", "status": initial_status, "requests": initial})
        if initial_status == "pass":
            report.update({
                "evidence_outcome": "eligible_pending_invariance",
                "branch_verdict": "proceed",
                "reason": "complete synthetic contract pass; actual sealed model proof remains pending",
            })
        elif repair_runner_argv is None:
            report.update({
                "evidence_outcome": "evidence_blocker",
                "branch_verdict": "revise",
                "reason": "valid observable difference requires the one bounded harness repair",
            })
        else:
            if tuple(repair_runner_argv) != tuple(runner_argv):
                _fail("bounded repair must use the identical runner command")
            report["repair_attempts"] = 1
            repaired_status, repaired = _execute_attempt(
                universe, repair_runner_argv, timeout_seconds,
                repair_runner_env if repair_runner_env is not None else runner_env,
                "bounded_repair",
            )
            report["attempts"].append({"kind": "bounded_repair", "status": repaired_status, "requests": repaired})
            initial_by_request = {item["request_sha256"]: item for item in initial}
            repaired_by_request = {item["request_sha256"]: item for item in repaired}
            if set(initial_by_request) != set(repaired_by_request):
                _fail("bounded repair changed the request universe")
            immutable_binding_keys = (
                "runner_sha256", "model_sha256", "model_config_sha256", "input_sha256"
            )
            for request_sha256 in sorted(initial_by_request):
                before = initial_by_request[request_sha256]["execution_binding"]
                after = repaired_by_request[request_sha256]["execution_binding"]
                if any(before[key] != after[key] for key in immutable_binding_keys):
                    _fail("bounded repair changed runner, model, config, or input provenance")
                if before["instrumentation_sha256"] == after["instrumentation_sha256"]:
                    _fail("bounded repair did not identify one hashed instrumentation change")
            if repaired_status == "difference":
                persistent = all(
                    initial_by_request[request_sha256]["perturbation_mismatches"]
                    == repaired_by_request[request_sha256]["perturbation_mismatches"]
                    and initial_by_request[request_sha256]["bypass_mismatches"]
                    == repaired_by_request[request_sha256]["bypass_mismatches"]
                    for request_sha256 in initial_by_request
                )
                if persistent:
                    report.update({
                        "evidence_outcome": "not_supported",
                        "branch_verdict": "retarget",
                        "reason": "the same decoder-facing difference persists after one bounded harness repair",
                    })
                else:
                    report.update({
                        "evidence_outcome": "evidence_blocker",
                        "branch_verdict": "revise",
                        "reason": "bounded repair changed rather than resolved the observable mismatch identity",
                    })
            else:
                report.update({
                    "evidence_outcome": "eligible_pending_invariance",
                    "branch_verdict": "proceed",
                    "reason": "bounded harness repair produced a complete pass; actual sealed model proof remains pending",
                })
    except ContractError as error:
        report.update({
            "evidence_outcome": "evidence_blocker",
            "branch_verdict": "revise",
            "reason": str(error),
        })
    _canonical(report)
    return report


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--universe", required=True, type=Path)
    parser.add_argument("--universe-sha256", required=True)
    parser.add_argument("--t10-sha256", required=True)
    parser.add_argument("--ami-sha256", required=True)
    parser.add_argument("--timeout-seconds", type=int, default=1800)
    parser.add_argument(
        "--repair-runner-json",
        help="optional strict JSON argv for the single bounded repaired-runner attempt",
    )
    parser.add_argument("runner", nargs=argparse.REMAINDER)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    runner = list(arguments.runner)
    if runner and runner[0] == "--":
        runner.pop(0)
    if not runner:
        print("runner command is required after --", file=sys.stderr)
        return 2
    try:
        universe = load_universe(
            arguments.universe,
            arguments.universe_sha256,
            expected_t10_sha256=arguments.t10_sha256,
            expected_ami_sha256=arguments.ami_sha256,
        )
        repair_runner = None
        if arguments.repair_runner_json is not None:
            parsed_repair = _loads(arguments.repair_runner_json.encode("utf-8"), "repair runner argv")
            if (
                not isinstance(parsed_repair, list)
                or not parsed_repair
                or any(not isinstance(item, str) or not item for item in parsed_repair)
            ):
                _fail("repair runner argv must be a non-empty JSON array of strings")
            repair_runner = parsed_repair
        report = execute_proof(
            universe,
            runner,
            repair_runner_argv=repair_runner,
            timeout_seconds=arguments.timeout_seconds,
        )
        sys.stdout.buffer.write(_canonical(report))
    except ContractError as error:
        print(str(error), file=sys.stderr)
        return 2
    return 0 if report["evidence_outcome"] == "eligible_pending_invariance" else 1


if __name__ == "__main__":
    raise SystemExit(main())
