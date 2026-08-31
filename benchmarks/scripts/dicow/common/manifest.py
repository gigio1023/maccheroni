"""Fail-closed verification for DiCoW manifests, judgments, and tracked edits."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import random
import re
import stat
import struct
import sys
import uuid
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple
from urllib.parse import urlsplit

from .pins import (
    BRANCH_VERDICTS,
    EVIDENCE_OUTCOMES,
    EXECUTION_PROVENANCE_PINS,
    FABLE_ACTUAL_MODEL,
    J1_REQUIRED_INPUT_KEYS,
    J1_STATE_REPO_ARTIFACT_PATHS,
    J1_STATE_SOURCE_KEYS,
    MAX_FRONTIER_CAPTURE_AGE_SECONDS,
    QWEN_BRANCH_KINDS,
    QWEN_SEED_NAMES,
    QWEN_SEED_STATUSES,
    REQUIRED_FRONTIER_FAMILIES,
    R2_ABSOLUTE_FAILURE_TYPES,
    R2_CANDIDATES,
    R2_CTC_DECISIONS,
    R2_CTC_PROCESS_ROLES,
    R2_FABLE_ALLOWED_TERMINAL_REASON,
    R2_FABLE_CONTEXT_TOKENS,
    R2_FABLE_MAX_ESTIMATED_INPUT_TOKENS,
    R2_FABLE_USABLE_INPUT_TOKENS,
    R2_MODEL_PINS,
    R2_QWEN_COMPONENTS,
    R2_QWEN_COMPONENT_STATES,
    R2_QWEN_FINAL_OUTCOMES,
    R2_REPETITIONS,
    R2_RESOURCE_FIELDS,
    R2_RESOURCE_WRITERS,
    R2_RIGHTS_ACTIONS,
    R2_RIGHTS_STATES,
    R2_SELECTION_OUTCOMES,
    R2_TASK_DEPENDENCIES,
    R2_GATE_TASK_SEMANTICS,
    R2_J1_ADVISORY_PATH,
    R2_J1_CLAUDE_CLI,
    R2_J1_ESTIMATOR_OVERHEAD,
    R2_J1_FORBIDDEN_PRE_VERDICT_OUTPUTS,
    R2_J1_GATE_PATH,
    R2_J2_GATE_PATH,
    R2_FINAL_GATE_PATH,
    R2_J1_OPERATIONAL_MAX_ESTIMATED_INPUT_TOKENS,
    R2_J1_PACKET_MAX_UTF8_BYTES,
    R2_J1_QWEN_CLAIM_CEILING,
    R2_J1_REFRESH_MAX_AGE_SECONDS,
    R2_J1_REFRESH_PATHS,
    R2_J1_REVERSAL_CONDITION,
    R2_R3_FIXED_SOURCE_PATHS,
    R2_R3_SEALED_FRAGMENT_KEYS,
    R2_R3_SEALED_PATH_KINDS,
    R2_R3_SOURCE_INPUT_KEYS,
    R2_TASK_IDS,
    R2_TASK_TRACKED_FILES,
    R2_TRACKED_FILES,
    TASK_TRACKED_FILES,
    TRACKED_FILE_PREDECESSORS,
)


_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_MODE = re.compile(r"^0[0-7]{3}$")
_R2_R3_ACTIVE_SPEC_SOURCE_KEY = "r3_audit_spec_v2"


class VerificationError(RuntimeError):
    """Raised when evidence does not satisfy the frozen contract."""


def _fail(message: str) -> None:
    raise VerificationError(message)


def _reject_json_constant(value: str) -> None:
    _fail("JSON input contains forbidden non-finite constant {}".format(value))


def _reject_duplicate_json_keys(pairs: List[Tuple[str, Any]]) -> Dict[str, Any]:
    value: Dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            _fail("JSON input contains duplicate object key {}".format(key))
        value[key] = item
    return value


def _reject_nonfinite_numbers(value: Any, field: str) -> None:
    if isinstance(value, float):
        if not math.isfinite(value):
            _fail("{} contains a non-finite number".format(field))
        return
    if isinstance(value, dict):
        for key, item in value.items():
            _reject_nonfinite_numbers(item, "{}.{}".format(field, key))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            _reject_nonfinite_numbers(item, "{}[{}]".format(field, index))


def _load_json(path: Path) -> Mapping[str, Any]:
    if path.is_symlink():
        _fail("JSON input may not be a symlink: {}".format(path))
    try:
        value = json.loads(
            path.read_text(encoding="utf-8"),
            parse_constant=_reject_json_constant,
            object_pairs_hook=_reject_duplicate_json_keys,
        )
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        _fail("cannot read JSON {}: {}".format(path, exc))
    if not isinstance(value, dict):
        _fail("{} must contain a JSON object".format(path))
    _reject_nonfinite_numbers(value, str(path))
    return value


def _loads_json_object(payload: str, field: str) -> Mapping[str, Any]:
    try:
        value = json.loads(
            payload,
            parse_constant=_reject_json_constant,
            object_pairs_hook=_reject_duplicate_json_keys,
        )
    except json.JSONDecodeError as exc:
        _fail("{} is not JSON: {}".format(field, exc))
    if not isinstance(value, dict):
        _fail("{} must contain a JSON object".format(field))
    _reject_nonfinite_numbers(value, field)
    return value


def _load_immutable_json(path: Path, field: str) -> Mapping[str, Any]:
    if path.is_symlink() or not path.is_file():
        _fail("{} is missing, not regular, or a symlink: {}".format(field, path))
    if stat.S_IMODE(path.stat().st_mode) & 0o222:
        _fail("{} must be immutable before verification: {}".format(field, path))
    return _load_json(path)


def _mapping(value: Any, field: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        _fail("{} must be an object".format(field))
    return value


def _list(value: Any, field: str) -> List[Any]:
    if not isinstance(value, list):
        _fail("{} must be an array".format(field))
    return value


def _string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        _fail("{} must be a non-empty string".format(field))
    return value


def _sha(value: Any, field: str) -> str:
    text = _string(value, field)
    if _SHA256.fullmatch(text) is None:
        _fail("{} must be a lowercase SHA-256".format(field))
    return text


def _unique_strings(value: Any, field: str) -> List[str]:
    items = _list(value, field)
    strings = [_string(item, "{}[]".format(field)) for item in items]
    if len(strings) != len(set(strings)):
        _fail("{} contains duplicates".format(field))
    return strings


def r2_contract_template() -> Mapping[str, Any]:
    """Return the closed r2-only decision contract.

    r1 threshold definitions remain authoritative.  This template binds only the
    successor comparison, mandatory Qwen work, execution resources, rights, CTC
    decision, conversion precision, and bounded human-model judgment interface.
    """

    return {
        "schema_version": "dicow-r2-contract-v1",
        "dependencies": {
            task: list(needs) for task, needs in R2_TASK_DEPENDENCIES.items()
        },
        "dependency_closures": {
            "gate_authorized_skip_satisfies_named_task": True,
            "r13_requires_closed_q2_and_r12": True,
            "dicow_closure_cannot_close_qwen": True,
        },
        "candidate_matrix": {
            "candidates": list(R2_CANDIDATES),
            "candidate_only_execution_difference": "candidate_id",
            "identical_inputs": [
                "audio", "references", "prompts", "crops", "stno",
                "community1_mapping", "arm_order", "output_cap",
            ],
            "complete_denominator_required": True,
            "repetitions": list(R2_REPETITIONS),
            "absolute_gates_before_selection": True,
            "korean_utility_basis": {
                "selected_at": "R3",
                "states": ["hike_pair", "r2_fleurs_ko_pair", "unavailable"],
                "unavailable_outcome": "dicow_only_evidence_blocker",
            },
            "r5_denominator": {
                "join_keys": [
                    "repetition", "window_id", "target_id", "language", "fixture_family",
                ],
                "complete_tuple_and_sha256_required": True,
                "r1_base_pack_immutable": True,
                "supplementary_fleurs_ko_is_sibling_pack": True,
                "sibling_binds_base_pack_sha256": True,
            },
            "selection": {
                "strict_dominance_estimand": "paired_window_first_community1_overlap_gain",
                "strict_dominance_lower_bound": ">0",
                "pairwise_superiority_margin": None,
                "identical_complete_denominator": True,
                "both_repetitions_must_pass": True,
                "preserve_every_mlc_passing_stratum": True,
                "non_overlap_non_inferiority_required": True,
                "s7b_non_inferiority_required": True,
                "missing_pair_outcome": "underpowered_no_decision",
                "korean_negative_point_reverses_v3_3": True,
                "incumbent_on_no_decision": "dicow_mlc",
                "exact_tie_requires_equal_complete_vectors_both_repetitions": True,
                "population_equivalence_claim": False,
                "outcomes": list(R2_SELECTION_OUTCOMES),
            },
            "v3_3_incompatibility": {
                "outcome": "excluded_with_named_follow_up",
                "counts_as_negative_model_evidence": False,
                "named_follow_up_required": True,
            },
        },
        "absolute_failures": list(R2_ABSOLUTE_FAILURE_TYPES),
        "qwen_lane": {
            "mandatory": True,
            "independent_of_dicow_selection": True,
            "components": [
                {
                    "component": component,
                    "required": True,
                    "closure_states": list(R2_QWEN_COMPONENT_STATES),
                }
                for component in R2_QWEN_COMPONENTS
            ],
            "asr_reuse": {
                "comparator_owner": "qwen_apple",
                "reuse_requires_full_lineage_inventory_and_behavior": True,
                "fallback_converter_owner": "qwen_apple",
                "fallback_converter_always_implemented": True,
                "behavior_failure_selects_current_revision_conversion": True,
            },
            "aligner": {
                "exact_latest_revision_required": True,
                "bf16_first": True,
                "fp32_timestamp_class_parity": "exact",
                "bf16_boundary_tolerance_ms": 80,
                "older_conversion_substitution": False,
            },
            "final_outcomes": list(R2_QWEN_FINAL_OUTCOMES),
            "both_components_must_close": True,
            "one_blocked_component_does_not_close_other": True,
            "dicow_gate_may_skip_q1_or_q2": False,
            "d37_ready_prerequisites": [
                "enforceable_output_cap",
                "generated_token_count",
                "directly_observed_terminal_reason",
                "acoustic_truth_timestamps",
            ],
            "hotword_transport_required": True,
            "positive_hotword_accuracy_delta_required": False,
            "primary_alignment_text": "asr_output",
            "forced_aligner_is_its_own_acoustic_truth": False,
        },
        "rights": {
            "actions": list(R2_RIGHTS_ACTIONS),
            "states": list(R2_RIGHTS_STATES),
            "per_asset_per_action_record_required": True,
            "one_action_never_implies_another": True,
            "private_artifacts_outside_checkout": True,
        },
        "resource_ledger": {
            "writers": list(R2_RESOURCE_WRITERS),
            "fields": list(R2_RESOURCE_FIELDS),
            "writer_id_and_phase_label_required": True,
            "only_co_resident_terms_nonzero_per_phase": True,
            "required_free_bytes_formula": (
                "max_phase(final_bytes+staging_bytes+retained_failure_bytes+retry_bytes+"
                "serializer_bytes+simultaneously_retained_prior_outputs)+2**31"
            ),
            "concurrent_model_processes": 1,
            "boundary_probes": ["below", "at", "above"],
            "retry_must_change_failure_condition": True,
            "attempt_policy": {
                "source_acquisition": {
                    "maximum_attempts": 2,
                    "retained_failure_peak_formula": "2*source_bytes",
                },
                "deterministic_conversion": {"maximum_attempts": 1},
                "receipt_or_serializer": {"maximum_attempts": 1},
            },
        },
        "ctc": {
            "process_roles": list(R2_CTC_PROCESS_ROLES),
            "process_count": 5,
            "generation_request_universe_frozen_pre_output": True,
            "control_envelope": "max_abs_baseline_a_vs_baseline_b_fp32",
            "control_envelope_method_frozen_task": "R3",
            "control_envelope_numeric_task": "R11",
            "numeric_state_at_R3": "deferred_to_R11_pre_perturbation",
            "r11_baselines_sealed_before_perturbations": True,
            "perturbations": ["zeroed", "deterministically_shuffled", "bypass"],
            "token_identity": "exact_full_universe",
            "decisions": list(R2_CTC_DECISIONS),
            "decision_implications": {
                "omit_proved_invariant_no_dataflow": [
                    "exact_tokens_all_processes",
                    "decoder_logits_within_control_envelope",
                    "proved_no_decoder_dataflow",
                ],
                "preserve_incomplete_invariance_no_dataflow": [
                    "proved_no_decoder_dataflow",
                    "preserve_ctc_tensors",
                    "preserve_head_execution",
                    "shape_and_logit_parity_where_called",
                ],
                "retarget_token_change_or_decoder_dataflow": [
                    "token_change_or_decoder_consumption",
                    "no_ctc_prefix_scoring",
                ],
            },
            "nonzero_head_call_alone_is_failure": False,
            "ctc_prefix_scoring_allowed": False,
        },
        "dicow_conversion": {
            "maximum_candidates": 1,
            "precision": "BF16",
            "quantized_derivative_allowed": False,
            "persistent_service_allowed": False,
        },
        "fable_packet": {
            "context_tokens": R2_FABLE_CONTEXT_TOKENS,
            "observed_usable_input_tokens": R2_FABLE_USABLE_INPUT_TOKENS,
            "maximum_estimated_input_tokens": R2_FABLE_MAX_ESTIMATED_INPUT_TOKENS,
            "maximum_formula": "observed_usable_input_tokens-1",
            "usable_input_source": "r1_j1_prompt_too_long_provider_estimate",
            "boundary_probes": ["maximum-1", "maximum", "maximum+1"],
            "preflight_estimator_record_required": True,
            "contains": [
                "question", "measurements", "short_cited_excerpts",
                "claim_ceilings", "reversal_conditions", "evidence_graph_hashes",
            ],
            "excludes": ["duplicate_code", "raw_test_bodies", "model_weights"],
            "accepted_terminal_reason": R2_FABLE_ALLOWED_TERMINAL_REASON,
            "prompt_too_long_is_judgment": False,
            "actual_model": FABLE_ACTUAL_MODEL,
            "effort": "max",
            "fallback": False,
        },
    }


def verify_r2_contract_document(value: Any) -> None:
    """Reject every mutation of the pre-output r2 decision contract."""

    contract = _mapping(value, "r2_contract")
    expected = r2_contract_template()
    if contract != expected:
        _fail("r2 contract differs from the frozen pre-output template")


def r2_required_free_bytes(phases: Sequence[Mapping[str, int]]) -> int:
    """Compute the sealed max-phase writer requirement plus 2 GiB headroom."""

    fields = (
        "final_bytes", "staging_bytes", "retained_failure_bytes", "retry_bytes",
        "serializer_bytes", "simultaneously_retained_prior_outputs",
    )
    if not phases:
        _fail("r2 resource calculation requires at least one phase")
    totals = []
    for index, phase in enumerate(phases):
        if set(phase) != set(fields):
            _fail("r2 resource phase {} has the wrong fields".format(index))
        total = 0
        for field in fields:
            value = phase.get(field)
            if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                _fail("r2 resource phase {}.{} must be nonnegative bytes".format(index, field))
            total += value
        totals.append(total)
    return max(totals) + 2**31


def verify_r2_fable_judgment(
    packet: bytes,
    estimated_input_tokens: int,
    raw_payload: bytes,
    provenance: Mapping[str, Any],
) -> None:
    """Verify that a bounded Fable call produced a model judgment."""

    if (
        not isinstance(estimated_input_tokens, int)
        or isinstance(estimated_input_tokens, bool)
        or estimated_input_tokens < 0
        or estimated_input_tokens > R2_FABLE_MAX_ESTIMATED_INPUT_TOKENS
    ):
        _fail("r2 Fable packet exceeds the observed usable-context token bound")
    raw_result = _loads_json_object(raw_payload.decode("utf-8"), "r2 Fable raw result")
    lowered = raw_payload.lower()
    if b"prompt_too_long" in lowered or b"prompt too long" in lowered:
        _fail("prompt-too-long transport output is not a model judgment")
    if raw_result.get("terminal_reason") != R2_FABLE_ALLOWED_TERMINAL_REASON:
        _fail("r2 Fable terminal reason is not a model judgment")
    usage = _mapping(raw_result.get("modelUsage"), "r2 Fable modelUsage")
    if list(usage) != [FABLE_ACTUAL_MODEL]:
        _fail("r2 Fable judgment did not use the sole frozen actual model")
    if raw_result.get("is_error") is not False:
        _fail("r2 Fable judgment is an error result")
    _string(raw_result.get("result"), "r2 Fable result")
    if set(provenance) != {
        "requested_model", "actual_model", "effort", "fallback", "prompt_sha256",
        "raw_result_sha256", "input_hashes", "estimated_input_tokens", "cli_version",
        "estimator_version", "estimator_source_sha256",
    }:
        _fail("r2 Fable provenance has the wrong fields")
    if (
        provenance.get("requested_model") != "fable"
        or provenance.get("actual_model") != FABLE_ACTUAL_MODEL
        or provenance.get("effort") != "max"
        or provenance.get("fallback") is not False
        or provenance.get("prompt_sha256") != hashlib.sha256(packet).hexdigest()
        or provenance.get("raw_result_sha256") != hashlib.sha256(raw_payload).hexdigest()
        or provenance.get("estimated_input_tokens") != estimated_input_tokens
    ):
        _fail("r2 Fable invocation provenance differs from the frozen request")
    _string(provenance.get("cli_version"), "r2 Fable CLI version")
    _string(provenance.get("estimator_version"), "r2 Fable estimator version")
    _sha(provenance.get("estimator_source_sha256"), "r2 estimator source SHA")
    inputs = _mapping(provenance.get("input_hashes"), "r2 Fable input_hashes")
    if not inputs:
        _fail("r2 Fable judgment requires a nonempty machine-evidence graph")
    for key, value in inputs.items():
        _sha(value, "r2 Fable input hash {}".format(key))


def verify_r2_experiment_envelope_document(document: Mapping[str, Any]) -> None:
    """Verify the r2 candidate wrapper without widening r1 experiment evidence."""

    expected_keys = {
        "schema_version", "experiment_id", "run_id", "task", "candidate_id",
        "candidate_source", "execution_basis", "r2_contract", "evidence",
    }
    if set(document) != expected_keys:
        _fail("r2 experiment envelope has the wrong fields")
    if document.get("schema_version") != "dicow-r2-experiment-envelope-v1":
        _fail("r2 experiment envelope has the wrong schema version")
    _string(document.get("experiment_id"), "r2 experiment_id")
    _string(document.get("run_id"), "r2 run_id")
    task = _string(document.get("task"), "r2 task")
    if task not in ("R7", "R8", "R9"):
        _fail("r2 candidate envelope task must be R7, R8, or R9")
    candidate = _string(document.get("candidate_id"), "r2 candidate_id")
    expected_candidate = {"R7": "turbo", "R8": "dicow_mlc", "R9": "dicow_v3_3"}[task]
    if candidate != expected_candidate:
        _fail("r2 task/candidate identity differs from the fixed matrix")
    source = _mapping(document.get("candidate_source"), "r2 candidate_source")
    if set(source) != {
        "model_id", "revision", "weights_sha256", "weights_bytes",
        "source_task", "source_artifact_format", "source_artifact_id",
        "source_artifact_path", "source_artifact_sha256", "source_artifact_bytes",
    }:
        _fail("r2 candidate source is not the complete R3 tuple")
    if (
        source.get("source_task") != "R3"
        or source.get("source_artifact_format") != "dicow-r2-model-identities-v1"
        or source.get("source_artifact_id") != "model-identities"
    ):
        _fail("r2 candidate source must be supplied by sealed R3")
    pin = R2_MODEL_PINS[candidate]
    if source.get("model_id") != pin["model_id"]:
        _fail("r2 candidate model ID differs from its namespace pin")
    if "revision" in pin and source.get("revision") != pin["revision"]:
        _fail("r2 candidate revision differs from its namespace pin")
    _string(source.get("revision"), "r2 candidate revision")
    _sha(source.get("weights_sha256"), "r2 candidate weights_sha256")
    _string(source.get("source_artifact_path"), "r2 source artifact path")
    _sha(source.get("source_artifact_sha256"), "r2 source artifact SHA")
    source_bytes = source.get("source_artifact_bytes")
    if not isinstance(source_bytes, int) or isinstance(source_bytes, bool) or source_bytes <= 0:
        _fail("r2 source artifact bytes must be positive")
    size = source.get("weights_bytes")
    if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
        _fail("r2 candidate weights_bytes must be a positive integer")
    basis = _mapping(document.get("execution_basis"), "r2 execution_basis")
    if set(basis) != {"R3", "R5", "R6"}:
        _fail("r2 execution basis must bind exactly R3, R5, and R6")
    for key in ("R3", "R5", "R6"):
        _sha(basis.get(key), "r2 execution basis {}".format(key))
    verify_r2_contract_document(document.get("r2_contract"))
    evidence = _mapping(document.get("evidence"), "r2 evidence")
    if set(evidence) != {
        "format", "candidate_model", "evidence_id", "path", "sha256", "bytes",
    }:
        _fail("r2 evidence reference has the wrong fields")
    if evidence.get("format") != "dicow-experiment-v1":
        _fail("r2 evidence must name the recursively verified r1 experiment format")
    expected_evidence_model = "turbo" if candidate == "turbo" else "dicow"
    if evidence.get("candidate_model") != expected_evidence_model:
        _fail("r2 evidence candidate linkage differs from its task candidate")
    _string(evidence.get("evidence_id"), "r2 evidence_id")
    _string(evidence.get("path"), "r2 evidence path")
    _sha(evidence.get("sha256"), "r2 evidence SHA")
    evidence_bytes = evidence.get("bytes")
    if not isinstance(evidence_bytes, int) or isinstance(evidence_bytes, bool) or evidence_bytes <= 0:
        _fail("r2 evidence bytes must be a positive integer")


def _r2_j1_session_id(value: Any) -> str:
    session_id = _string(value, "r2 Fable session ID")
    try:
        parsed = uuid.UUID(session_id)
    except (ValueError, AttributeError) as exc:
        _fail("r2 Fable session ID is not a UUID: {}".format(exc))
    if parsed.version != 4 or str(parsed) != session_id:
        _fail("r2 Fable session ID must be a canonical fresh UUIDv4")
    return session_id


def _r2_j1_argv(run_root: str, session_id: str) -> List[str]:
    return [
        R2_J1_CLAUDE_CLI,
        "-p",
        "--no-session-persistence",
        "--model", "fable",
        "--effort", "max",
        "--output-format", "json",
        "--restricted",
        "--tools", "Read",
        "--add-dir", run_root,
        "--permission-mode", "dontAsk",
        "--no-chrome",
        "--disable-slash-commands",
        "--strict-mcp-config",
        "--safe-mode",
        "--session-id", session_id,
    ]


def verify_r2_gate_envelope_document(document: Mapping[str, Any]) -> None:
    """Verify the r2 Fable envelope and its machine/judgment separation."""

    expected_keys = {
        "schema_version", "gate_id", "task", "scope", "evidence_outcome",
        "machine_evidence_graph", "judgment_packet", "estimator_artifact", "decision",
        "fable_result", "r2_contract",
    }
    if set(document) != expected_keys:
        _fail("r2 gate envelope has the wrong fields")
    if document.get("schema_version") != "dicow-r2-gate-envelope-v1":
        _fail("r2 gate envelope has the wrong schema version")
    identities = {
        "J1-r2": "R4",
        "J2-r2": "R10",
        "FINAL-r2": "R13",
    }
    gate_id = _string(document.get("gate_id"), "r2 gate_id")
    if gate_id not in identities or document.get("task") != identities[gate_id]:
        _fail("r2 gate/task identity differs from the plan")
    allowed_scopes = {
        "J1-r2": {"proceed_dicow_and_qwen", "proceed_qwen_only", "revise_or_stop_all"},
        "J2-r2": {"select_none", "select_dicow_mlc", "select_dicow_v3_3", "retarget", "underpowered_keep_mlc"},
        "FINAL-r2": {"final_review"},
    }
    if document.get("scope") not in allowed_scopes[gate_id]:
        _fail("r2 gate scope is invalid for its checkpoint")
    decision = _mapping(document.get("decision"), "r2 decision")
    if set(decision) != {
        "checkpoint", "scope", "evidence_outcome", "next_task_ids", "skip_task_ids",
        "reversal_condition",
    }:
        _fail("r2 decision has the wrong checkpoint-specific fields")
    if (
        decision.get("checkpoint") != gate_id
        or decision.get("scope") != document.get("scope")
        or decision.get("evidence_outcome") != document.get("evidence_outcome")
    ):
        _fail("r2 parsed decision differs from the gate")
    next_tasks = _unique_strings(decision.get("next_task_ids"), "r2 decision next tasks")
    skip_tasks = _unique_strings(decision.get("skip_task_ids"), "r2 decision skip tasks")
    if any(task not in R2_TASK_IDS for task in next_tasks + skip_tasks):
        _fail("r2 decision contains an unknown R/Q task ID")
    if set(next_tasks) & set(skip_tasks):
        _fail("r2 decision next and skip tasks overlap")
    expected_semantics = R2_GATE_TASK_SEMANTICS[(gate_id, document.get("scope"))]
    if next_tasks != list(expected_semantics["next"]) or skip_tasks != list(expected_semantics["skip"]):
        _fail("r2 decision does not carry the exact checkpoint/scope task sets")
    if gate_id == "J2-r2" and ({"Q1", "Q2"} & set(skip_tasks)):
        _fail("a DiCoW selection gate may not skip Qwen")
    reversal_condition = _string(
        decision.get("reversal_condition"), "r2 decision reversal condition"
    )
    if gate_id == "J1-r2":
        scope = document.get("scope")
        outcome = document.get("evidence_outcome")
        if scope == "proceed_qwen_only" and (
            outcome != "evidence_blocker"
            or reversal_condition != R2_J1_REVERSAL_CONDITION
        ):
            _fail("J1-r2 Qwen-only scope must preserve the exact DiCoW blocker")
        if scope == "proceed_dicow_and_qwen" and outcome != "supported":
            _fail("J1-r2 dual-lane scope requires supported evidence")
        if scope == "revise_or_stop_all" and outcome not in {
            "not_supported", "evidence_blocker", "unresolved",
        }:
            _fail("J1-r2 stop scope requires a typed non-supporting outcome")
    graph = _mapping(document.get("machine_evidence_graph"), "machine evidence graph")
    packet = _mapping(document.get("judgment_packet"), "judgment packet")
    estimator_artifact = _mapping(document.get("estimator_artifact"), "estimator artifact")
    for label, record in (
        ("machine graph", graph), ("judgment packet", packet),
        ("estimator artifact", estimator_artifact),
    ):
        if set(record) != {"key", "path", "sha256", "bytes"}:
            _fail("{} artifact tuple is malformed".format(label))
        _string(record.get("path"), "{} path".format(label))
        _sha(record.get("sha256"), "{} SHA".format(label))
        size = record.get("bytes")
        if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
            _fail("{} bytes must be positive".format(label))
    expected_artifacts = {
        "machine graph": ("machine_graph", "machine-graph.json"),
        "judgment packet": ("judgment_packet", "judgment-packet.txt"),
        "estimator artifact": ("estimator", "estimator.json"),
    }
    for label, record in (
        ("machine graph", graph), ("judgment packet", packet),
        ("estimator artifact", estimator_artifact),
    ):
        key, path = expected_artifacts[label]
        if record.get("key") != key or record.get("path") != path:
            _fail("{} must use its exact canonical key and path".format(label))
    if graph.get("path") == packet.get("path") or graph.get("sha256") == packet.get("sha256"):
        _fail("machine evidence graph and bounded judgment packet must be separate")
    fable = _mapping(document.get("fable_result"), "r2 fable_result")
    expected_fable_fields = {
        "terminal_reason", "is_error", "requested_model", "actual_model", "effort",
        "fallback", "context_tokens", "usable_input_tokens", "estimated_input_tokens",
        "cli_path", "cli_version", "session_id", "fresh_session", "resumed", "argv",
        "session_started_at_utc",
        "tool_allowlist", "estimator_version", "estimator_source_sha256",
        "prompt_sha256", "raw_path", "raw_sha256", "decision_path", "decision_sha256",
        "input_hashes",
    }
    if set(fable) != expected_fable_fields:
        _fail("r2 fable_result has the wrong fields")
    if (
        fable.get("terminal_reason") != R2_FABLE_ALLOWED_TERMINAL_REASON
        or fable.get("is_error") is not False
        or fable.get("requested_model") != "fable"
        or fable.get("actual_model") != FABLE_ACTUAL_MODEL
        or fable.get("effort") != "max"
        or fable.get("fallback") is not False
        or fable.get("context_tokens") != R2_FABLE_CONTEXT_TOKENS
        or fable.get("usable_input_tokens") != R2_FABLE_USABLE_INPUT_TOKENS
        or fable.get("fresh_session") is not True
        or fable.get("resumed") is not False
        or fable.get("tool_allowlist") != ["Read"]
    ):
        _fail("r2 Fable result is not an authenticated model judgment")
    estimated = fable.get("estimated_input_tokens")
    if (
        not isinstance(estimated, int)
        or isinstance(estimated, bool)
        or estimated < 0
        or estimated > R2_FABLE_MAX_ESTIMATED_INPUT_TOKENS
    ):
        _fail("r2 Fable result exceeds the estimator bound")
    _sha(fable.get("prompt_sha256"), "r2 Fable prompt SHA")
    if fable.get("cli_path") != R2_J1_CLAUDE_CLI:
        _fail("r2 Fable CLI path differs from the frozen executable")
    _string(fable.get("cli_version"), "r2 Fable CLI version")
    session_id = _r2_j1_session_id(fable.get("session_id"))
    _timestamp(fable.get("session_started_at_utc"), "r2 Fable session start")
    argv = _unique_strings(fable.get("argv"), "r2 Fable argv")
    try:
        add_dir = argv[argv.index("--add-dir") + 1]
    except (ValueError, IndexError):
        _fail("r2 Fable argv omits its run-root add-dir")
    if argv != _r2_j1_argv(add_dir, session_id):
        _fail("r2 Fable argv differs from the exact fresh restricted invocation")
    _string(fable.get("estimator_version"), "r2 estimator version")
    _sha(fable.get("estimator_source_sha256"), "r2 estimator source SHA")
    if fable.get("estimator_version") != "j1-byte-formula-v1":
        _fail("r2 estimator version differs from the frozen byte formula")
    _string(fable.get("raw_path"), "r2 Fable raw path")
    _sha(fable.get("raw_sha256"), "r2 raw Fable SHA")
    _string(fable.get("decision_path"), "r2 Fable decision path")
    if fable.get("raw_path") != "raw.json" or fable.get("decision_path") != "decision.json":
        _fail("r2 Fable raw and decision paths must be canonical")
    if fable.get("decision_sha256") != _canonical_sha(decision):
        _fail("r2 decision SHA differs from the exact parsed decision")
    input_hashes = _mapping(fable.get("input_hashes"), "r2 Fable input hashes")
    if input_hashes != {graph.get("key"): graph.get("sha256")}:
        _fail("r2 Fable input hashes do not exactly bind the declared machine graph")
    for key, value in input_hashes.items():
        _sha(value, "r2 Fable input hash {}".format(key))
    verify_r2_contract_document(document.get("r2_contract"))


def _r2_j1_output_schema() -> Mapping[str, Any]:
    required = [
        "checkpoint", "scope", "evidence_outcome", "next_task_ids",
        "skip_task_ids", "reversal_condition",
    ]

    def branch(
        scope: str,
        outcomes: Sequence[str],
        next_tasks: Sequence[str],
        skip_tasks: Sequence[str],
        *,
        reversal: Optional[str] = None,
    ) -> Mapping[str, Any]:
        reversal_schema: Mapping[str, Any] = (
            {"const": reversal}
            if reversal is not None
            else {"type": "string", "minLength": 1}
        )
        outcome_schema: Mapping[str, Any] = (
            {"const": outcomes[0]}
            if len(outcomes) == 1
            else {"enum": list(outcomes)}
        )
        return {
            "type": "object",
            "additionalProperties": False,
            "required": required,
            "properties": {
                "checkpoint": {"const": "J1-r2"},
                "scope": {"const": scope},
                "evidence_outcome": outcome_schema,
                "next_task_ids": {"const": list(next_tasks)},
                "skip_task_ids": {"const": list(skip_tasks)},
                "reversal_condition": reversal_schema,
            },
        }

    return {
        "oneOf": [
            branch(
                "proceed_dicow_and_qwen", ("supported",),
                R2_GATE_TASK_SEMANTICS[("J1-r2", "proceed_dicow_and_qwen")]["next"],
                R2_GATE_TASK_SEMANTICS[("J1-r2", "proceed_dicow_and_qwen")]["skip"],
            ),
            branch(
                "proceed_qwen_only", ("evidence_blocker",),
                R2_GATE_TASK_SEMANTICS[("J1-r2", "proceed_qwen_only")]["next"],
                R2_GATE_TASK_SEMANTICS[("J1-r2", "proceed_qwen_only")]["skip"],
                reversal=R2_J1_REVERSAL_CONDITION,
            ),
            branch(
                "revise_or_stop_all",
                ("not_supported", "evidence_blocker", "unresolved"),
                R2_GATE_TASK_SEMANTICS[("J1-r2", "revise_or_stop_all")]["next"],
                R2_GATE_TASK_SEMANTICS[("J1-r2", "revise_or_stop_all")]["skip"],
            ),
        ]
    }


def _r2_j1_packet(machine_graph_record: Mapping[str, Any]) -> bytes:
    graph_tuple = {
        "path": machine_graph_record.get("path"),
        "sha256": machine_graph_record.get("sha256"),
        "bytes": machine_graph_record.get("bytes"),
    }
    sections = (
        ("protocol_version", "dicow-r2-j1-judgment-packet-v1"),
        ("checkpoint", "J1-r2"),
        (
            "decision_question",
            "Choose the execution scope with the highest justified product value for the frozen R4 graph.",
        ),
        (
            "machine_graph_tuple",
            json.dumps(graph_tuple, sort_keys=True, separators=(",", ":")),
        ),
        (
            "frozen_scope_choices",
            json.dumps([
                "proceed_dicow_and_qwen", "proceed_qwen_only", "revise_or_stop_all"
            ], separators=(",", ":")),
        ),
        (
            "authoritative_facts",
            "R3 derives dicow_scope=evidence_blocker and both Qwen components="
            "implementation_ready from source identity and rights. Qwen aligner semantic "
            "compatibility remains unestablished; accept only facts bound by machine_graph_tuple.",
        ),
        (
            "decision_rules",
            "Do not proceed with DiCoW while its R3 evidence blocker stands. Choose "
            "proceed_qwen_only only if Q1 implementation value justifies the remaining "
            "uncertainty. Choose revise_or_stop_all if it does not; emit one exact output branch.",
        ),
        (
            "value_interpretation",
            "implementation_ready permits Q1 implementation; it does not prove product quality.",
        ),
        ("claim_ceilings", R2_J1_QWEN_CLAIM_CEILING),
        (
            "excluded_work",
            json.dumps(list(R2_J1_FORBIDDEN_PRE_VERDICT_OUTPUTS), separators=(",", ":")),
        ),
        ("reversal_rule", R2_J1_REVERSAL_CONDITION),
        (
            "output_contract",
            json.dumps(
                _r2_j1_output_schema(), sort_keys=True, separators=(",", ":"),
                ensure_ascii=False,
            ),
        ),
    )
    return "".join("{}\n{}\n".format(name, value) for name, value in sections).encode(
        "utf-8"
    )


def _r2_j1_authority_roles() -> Mapping[str, Tuple[str, str]]:
    base = {
        key: ("authenticated_input", "identity_and_fresh_tuple_only")
        for key in (
            "plan_contract", "run_manifest", "effective_r1_state", "r2_state",
            "r3_state", "pre_model_audit_manifest", "pre_model_decision",
            "active_spec", *R2_J1_REFRESH_PATHS,
            "gate_schema", "pins", "manifest_verifier",
        )
    }
    base["pre_model_decision"] = (
        "decision_authority", "dicow_blocker_and_qwen_implementation_readiness_only"
    )
    base["active_spec"] = ("audit_spec", "audit_validation_contract_only")
    for key in (
        "r4_qwen_rights_identity", "r4_roster", "r4_three_axis",
        "r4_frontier_delta", "r4_synthesis",
    ):
        base[key] = (
            "refresh_evidence", "implementation_readiness_not_product_quality"
        )
    base["advisory_checkpoint"] = (
        "advisory_only", "non_authoritative_value_review_only"
    )
    return base


def _r2_j1_record(path: Path, display_path: str, *, prefix_bytes: Optional[int] = None) -> Mapping[str, Any]:
    if path.is_symlink() or not path.is_file():
        _fail("R4 authority is missing, non-regular, or a symlink: {}".format(path))
    payload = path.read_bytes()
    if prefix_bytes is not None:
        if prefix_bytes <= 0 or len(payload) < prefix_bytes:
            _fail("R4 plan contract prefix is unavailable")
        payload = payload[:prefix_bytes]
    return {
        "path": display_path,
        "sha256": hashlib.sha256(payload).hexdigest(),
        "bytes": len(payload),
    }


def _verify_r2_j1_machine_graph(
    graph_path: Path,
    estimator_path: Path,
    packet_path: Path,
    gate: Mapping[str, Any],
    run_root: Path,
) -> None:
    graph = _load_json(graph_path)
    expected_graph_fields = {
        "schema_version", "run_id", "checkpoint", "prepared_at_utc",
        "latest_permitted_session_start_utc", "authorities", "derived_facts",
        "claim_ceilings", "forbidden_pre_verdict_outputs", "verification",
    }
    if set(graph) != expected_graph_fields or (
        graph.get("schema_version") != "dicow-r2-j1-machine-graph-v1"
        or graph.get("checkpoint") != "J1-r2"
    ):
        _fail("R4 machine graph identity or fields differ from the frozen contract")
    run_manifest_path = run_root / "run-manifest.json"
    run_manifest = _load_json(run_manifest_path)
    run_id = _string(run_manifest.get("run_id"), "R4 run ID")
    if graph.get("run_id") != run_id:
        _fail("R4 machine graph belongs to another run")

    effective_r1 = _effective_r2_state_path("R1", run_root)
    r1_state = _load_json(effective_r1)
    if (
        r1_state.get("task") != "R1-contract-amendment-10"
        or r1_state.get("run_id") != run_id
        or r1_state.get("state") != "done"
    ):
        _fail("R4 machine graph does not bind effective R1 amendment10")
    r2_path = run_root / "task-state/R2.json"
    r3_path = run_root / "task-state/R3.json"
    r2_state = _load_json(r2_path)
    r3_state = _load_json(r3_path)
    r1_sha = _digest(effective_r1)
    r2_sha = _digest(r2_path)
    if (
        r2_state.get("task") != "R2"
        or r2_state.get("run_id") != run_id
        or r2_state.get("state") != "done"
        or r3_state.get("task") != "R3"
        or r3_state.get("run_id") != run_id
        or r3_state.get("state") != "done"
        or r3_state.get("branch_disposition") != "executed"
        or r3_state.get("next_task_ids") != ["R4"]
        or _mapping(
            r2_state.get("predecessor_state_hashes"), "R4 R2 predecessor hashes"
        ).get("R1") != r1_sha
        or r3_state.get("predecessor_state_hashes") != {"R1": r1_sha, "R2": r2_sha}
        or r3_state.get("evidence_outcome") != "evidence_blocker"
    ):
        _fail("R4 machine graph predecessor states are not the exact final R1/R2/R3 chain")

    selected_manifest, _, replay = _r3_selected_audit_paths(
        run_root, run_id, replay=True
    )
    replay_decision = _mapping(
        _mapping(replay.get("summary"), "R4 replay summary").get("decision"),
        "R4 replay decision",
    )
    decision_path = selected_manifest.parent / "audit/decision.json"
    decision = _load_json(decision_path)
    for key, expected in {
        "dicow_scope": "evidence_blocker",
        "qwen_asr_scope": "implementation_ready",
        "qwen_aligner_scope": "implementation_ready",
    }.items():
        if decision.get(key) != expected or replay_decision.get(key) != expected:
            _fail("R4 pre-model decision does not prove {}={}".format(key, expected))

    spec_path = run_root / R2_R3_FIXED_SOURCE_PATHS[_R2_R3_ACTIVE_SPEC_SOURCE_KEY]
    r3_sources = _mapping(r3_state.get("source_input_hashes"), "R4 R3 source hashes")
    if r3_sources.get(_R2_R3_ACTIVE_SPEC_SOURCE_KEY) != _digest(spec_path):
        _fail("R4 active audit spec authority differs from final R3")

    repo_root = Path(__file__).resolve().parents[4]
    plan = _mapping(run_manifest.get("plan_contract"), "R4 plan contract")
    plan_path = Path(_string(plan.get("path"), "R4 plan path")).absolute()
    plan_bytes = plan.get("bytes")
    if not isinstance(plan_bytes, int) or isinstance(plan_bytes, bool):
        _fail("R4 plan contract bytes are malformed")
    fresh_plan_record = _r2_j1_record(
        plan_path, str(plan_path), prefix_bytes=plan_bytes
    )
    if (
        plan.get("sha256") != fresh_plan_record.get("sha256")
        or plan.get("bytes") != fresh_plan_record.get("bytes")
    ):
        _fail("R4 run manifest plan contract differs from its fresh prefix")
    expected_paths = {
        "plan_contract": (plan_path, str(plan_path), plan_bytes),
        "run_manifest": (run_manifest_path, "run-manifest.json", None),
        "effective_r1_state": (
            effective_r1, str(effective_r1.relative_to(run_root)), None,
        ),
        "r2_state": (r2_path, "task-state/R2.json", None),
        "r3_state": (r3_path, "task-state/R3.json", None),
        "pre_model_audit_manifest": (
            selected_manifest, str(selected_manifest.relative_to(run_root)), None,
        ),
        "pre_model_decision": (
            decision_path, str(decision_path.relative_to(run_root)), None,
        ),
        "active_spec": (spec_path, str(spec_path.relative_to(run_root)), None),
        "gate_schema": (
            repo_root / "docs/contracts/dicow-gate.schema.json",
            str(repo_root / "docs/contracts/dicow-gate.schema.json"), None,
        ),
        "pins": (
            repo_root / "benchmarks/scripts/dicow/common/pins.py",
            str(repo_root / "benchmarks/scripts/dicow/common/pins.py"), None,
        ),
        "manifest_verifier": (
            Path(__file__).resolve(), str(Path(__file__).resolve()), None,
        ),
        "advisory_checkpoint": (
            run_root / R2_J1_ADVISORY_PATH, R2_J1_ADVISORY_PATH, None,
        ),
    }
    for key, relative in R2_J1_REFRESH_PATHS.items():
        expected_paths[key] = (run_root / relative, relative, None)
    roles = _r2_j1_authority_roles()
    raw_authorities = _list(graph.get("authorities"), "R4 machine graph authorities")
    if len(raw_authorities) != len(roles):
        _fail("R4 machine graph authority roster has missing or extra records")
    authorities = {}
    for raw in raw_authorities:
        record = _mapping(raw, "R4 machine graph authority")
        if set(record) != {"key", "path", "sha256", "bytes", "role", "claim_ceiling"}:
            _fail("R4 machine graph authority record has the wrong fields")
        key = _string(record.get("key"), "R4 authority key")
        if key in authorities:
            _fail("R4 machine graph authority keys must be unique")
        authorities[key] = record
    if set(authorities) != set(roles) or set(expected_paths) != set(roles):
        _fail("R4 machine graph authority roster differs from the frozen set")
    for key, (path, display, prefix) in expected_paths.items():
        expected = dict(_r2_j1_record(path, display, prefix_bytes=prefix))
        expected["key"] = key
        expected["role"], expected["claim_ceiling"] = roles[key]
        if authorities[key] != expected:
            _fail("R4 authority {} differs from fresh disk or frozen semantics".format(key))

    refresh_root = run_root / "r4-frontier-refresh.staging"
    refresh_documents = {
        "capture": _load_json(refresh_root / "capture-manifest.json"),
        "delta": _load_json(refresh_root / "frontier-delta.json"),
        "rights": _load_json(refresh_root / "qwen-rights-and-identity.json"),
        "roster": _load_json(refresh_root / "roster.json"),
        "three_axis": _load_json(refresh_root / "three-axis-candidates.json"),
    }
    cutoff_text = _string(
        refresh_documents["rights"].get("cutoff_utc"), "R4 refresh cutoff"
    )
    cutoff = _timestamp(cutoff_text, "R4 refresh cutoff")
    for label, field in (
        ("capture", "search_cutoff_utc"), ("delta", "search_cutoff_utc"),
        ("roster", "search_cutoff_utc"), ("three_axis", "cutoff_utc"),
    ):
        if refresh_documents[label].get(field) != cutoff_text:
            _fail("R4 refresh evidence does not share one accepted cutoff")
    verify_output = (refresh_root / "verify-output.txt").read_text(encoding="utf-8")
    synthesis = (refresh_root / "synthesis.md").read_text(encoding="utf-8")
    if not verify_output.startswith("PASS r4 frontier delta offline verification:") or (
        "cutoff {}".format(cutoff_text) not in verify_output
        or "Cutoff: `{}`".format(cutoff_text) not in synthesis
    ):
        _fail("R4 refresh verifier/synthesis does not authenticate the cutoff")
    sums = {}
    for line in (refresh_root / "SHA256SUMS").read_text(encoding="utf-8").splitlines():
        if "  " in line:
            sha, relative = line.split("  ", 1)
            sums[relative] = sha
    for key, relative in R2_J1_REFRESH_PATHS.items():
        name = Path(relative).name
        if key != "r4_refresh_checksums" and key != "r4_verify_output":
            if sums.get(name) != _digest(run_root / relative):
                _fail("R4 refresh SHA256SUMS does not bind {}".format(name))

    fable = _mapping(gate.get("fable_result"), "R4 fable result")
    session_start = _timestamp(
        fable.get("session_started_at_utc"), "R4 Fable session start"
    )
    latest = cutoff + dt.timedelta(seconds=R2_J1_REFRESH_MAX_AGE_SECONDS)
    if not cutoff <= session_start <= latest:
        _fail("R4 Fable session starts outside the accepted refresh window")
    prepared = _timestamp(graph.get("prepared_at_utc"), "R4 graph prepared time")
    if not cutoff <= prepared <= session_start:
        _fail("R4 machine graph was not prepared after refresh and before judgment")
    if _timestamp(
        graph.get("latest_permitted_session_start_utc"), "R4 latest session start"
    ) != latest:
        _fail("R4 machine graph latest session start is not cutoff plus 21600 seconds")
    expected_facts = {
        "r3_dicow_scope": "evidence_blocker",
        "qwen_asr_scope": "implementation_ready",
        "qwen_aligner_scope": "implementation_ready",
        "qwen_aligner_semantic_scope": "unestablished",
        "dicow_probe_scope": "successor_plan_reversal_only",
        "server_scope": "excluded",
        "baseline_scope": "excluded",
    }
    if graph.get("derived_facts") != expected_facts:
        _fail("R4 machine graph derived facts differ from replayed decision scope")
    if gate.get("scope") == "proceed_dicow_and_qwen":
        _fail("R4 cannot proceed with DiCoW while the replayed R3 blocker stands")
    if graph.get("claim_ceilings") != [R2_J1_QWEN_CLAIM_CEILING]:
        _fail("R4 machine graph lacks the exact Qwen product-promotion claim ceiling")
    if graph.get("forbidden_pre_verdict_outputs") != list(
        R2_J1_FORBIDDEN_PRE_VERDICT_OUTPUTS
    ):
        _fail("R4 machine graph inserts DiCoW probe, server, or baseline work")
    if graph.get("verification") != {
        "status": "verified",
        "refresh_cutoff_utc": cutoff_text,
        "session_started_at_utc": fable.get("session_started_at_utc"),
        "authority_count": len(roles),
    }:
        _fail("R4 machine graph verification summary is not exact")

    packet_payload = packet_path.read_bytes()
    try:
        packet_payload.decode("utf-8")
    except UnicodeDecodeError as exc:
        _fail("R4 judgment packet is not UTF-8: {}".format(exc))
    expected_packet = _r2_j1_packet(
        _mapping(gate.get("machine_evidence_graph"), "R4 machine graph tuple")
    )
    if packet_payload != expected_packet:
        _fail("R4 judgment packet differs from the exact graph-bound decision packet")
    estimator = _load_json(estimator_path)
    schema_bytes = len(
        json.dumps(
            _r2_j1_output_schema(), sort_keys=True, separators=(",", ":"),
            ensure_ascii=False,
        ).encode("utf-8")
    )
    estimated = len(packet_payload) + schema_bytes + R2_J1_ESTIMATOR_OVERHEAD
    expected_estimator = {
        "packet_utf8_bytes": len(packet_payload),
        "output_schema_utf8_bytes": schema_bytes,
        "overhead": R2_J1_ESTIMATOR_OVERHEAD,
        "estimated_input_tokens": estimated,
        "packet_max_utf8_bytes": R2_J1_PACKET_MAX_UTF8_BYTES,
        "operational_max_estimated_input_tokens": (
            R2_J1_OPERATIONAL_MAX_ESTIMATED_INPUT_TOKENS
        ),
        "contract_max_estimated_input_tokens": R2_FABLE_MAX_ESTIMATED_INPUT_TOKENS,
    }
    if estimator != expected_estimator:
        _fail("R4 estimator does not reproduce the frozen byte formula and caps")
    if (
        len(packet_payload) > R2_J1_PACKET_MAX_UTF8_BYTES
        or estimated > R2_J1_OPERATIONAL_MAX_ESTIMATED_INPUT_TOKENS
        or estimated > R2_FABLE_MAX_ESTIMATED_INPUT_TOKENS
        or fable.get("estimated_input_tokens") != estimated
    ):
        _fail("R4 judgment packet exceeds its operational or contract estimator cap")
    if (
        fable.get("prompt_sha256") != hashlib.sha256(packet_payload).hexdigest()
        or fable.get("argv") != _r2_j1_argv(str(run_root), fable.get("session_id"))
        or fable.get("estimator_source_sha256")
        != authorities["manifest_verifier"].get("sha256")
    ):
        _fail("R4 recorded stdin, estimator source, or exact invocation differs")


def _timestamp(value: Any, field: str) -> dt.datetime:
    text = _string(value, field)
    if not text.endswith("Z"):
        _fail("{} must be an explicit UTC timestamp ending in Z".format(field))
    try:
        parsed = dt.datetime.fromisoformat(text[:-1] + "+00:00")
    except ValueError as exc:
        _fail("{} is not ISO-8601: {}".format(field, exc))
    if parsed.utcoffset() != dt.timedelta(0):
        _fail("{} is not UTC".format(field))
    return parsed


def _digest(path: Path) -> str:
    hasher = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                hasher.update(block)
    except OSError as exc:
        _fail("cannot hash {}: {}".format(path, exc))
    return hasher.hexdigest()


def _verify_file(path: Path, expected_sha: Any, expected_bytes: Any = None) -> None:
    if path.is_symlink() or not path.is_file():
        _fail("evidence file is missing, not regular, or a symlink: {}".format(path))
    sha = _sha(expected_sha, "sha256 for {}".format(path))
    if _digest(path) != sha:
        _fail("SHA-256 mismatch for {}".format(path))
    if expected_bytes is not None:
        if not isinstance(expected_bytes, int) or isinstance(expected_bytes, bool) or expected_bytes < 0:
            _fail("byte count for {} must be a non-negative integer".format(path))
        if path.stat().st_size != expected_bytes:
            _fail("byte-count mismatch for {}".format(path))


def _contained_path(base: Path, raw: Any, field: str, allowed_root: Optional[Path] = None) -> Path:
    text = _string(raw, field)
    candidate = Path(text)
    if ".." in candidate.parts:
        _fail("{} may not contain parent traversal".format(field))
    if not candidate.is_absolute():
        candidate = base / candidate
    candidate = candidate.absolute()
    root = (allowed_root or base).resolve()
    try:
        candidate.relative_to(root)
    except ValueError:
        _fail("{} is not lexically contained by evidence root {}: {}".format(field, root, candidate))
    current = candidate
    while current != root:
        if current.is_symlink():
            _fail("{} contains a symlink component: {}".format(field, current))
        current = current.parent
    resolved = candidate.resolve(strict=False)
    try:
        resolved.relative_to(root)
    except ValueError:
        _fail("{} escapes evidence root {}: {}".format(field, root, resolved))
    return resolved


def _find_run_root(start: Path) -> Path:
    current = start.absolute()
    for candidate in (current,) + tuple(current.parents):
        if candidate.is_symlink():
            _fail("run path contains a symlink component: {}".format(candidate))
        if (candidate / "run-manifest.json").is_file():
            return candidate.resolve()
    _fail("no enclosing run-manifest.json for {}".format(start))
    raise AssertionError("unreachable")


def _validate_schema(document: Mapping[str, Any], schema_name: str) -> None:
    try:
        import jsonschema
    except ImportError:
        _fail("jsonschema is required from the locked scoring environment")
    repo = Path(__file__).resolve().parents[4]
    schema = _load_json(repo / "docs" / "contracts" / schema_name)
    validator = jsonschema.Draft202012Validator(
        schema, format_checker=jsonschema.FormatChecker()
    )
    errors = sorted(validator.iter_errors(document), key=lambda error: list(error.path))
    if errors:
        error = errors[0]
        location = ".".join(str(part) for part in error.absolute_path) or "<root>"
        _fail("{} schema violation at {}: {}".format(schema_name, location, error.message))


def _validate_schema_definition(
    document: Mapping[str, Any], schema_name: str, definition: str
) -> None:
    try:
        import jsonschema
    except ImportError:
        _fail("jsonschema is required from the locked scoring environment")
    repo = Path(__file__).resolve().parents[4]
    schema = _load_json(repo / "docs" / "contracts" / schema_name)
    definitions = _mapping(schema.get("$defs"), "{} $defs".format(schema_name))
    _mapping(definitions.get(definition), definition)
    target = {
        "$schema": schema.get("$schema"),
        "$ref": "#/$defs/{}".format(definition),
        "$defs": definitions,
    }
    validator = jsonschema.Draft202012Validator(
        target,
        format_checker=jsonschema.FormatChecker(),
    )
    errors = sorted(validator.iter_errors(document), key=lambda error: list(error.path))
    if errors:
        error = errors[0]
        location = ".".join(str(part) for part in error.absolute_path) or "<root>"
        _fail("{} {} violation at {}: {}".format(
            schema_name, definition, location, error.message
        ))


def _verify_capture(
    capture: Mapping[str, Any], evidence_root: Path, session_start: dt.datetime
) -> Tuple[str, dt.datetime, bool]:
    url = _string(capture.get("url"), "capture.url")
    success = capture.get("success")
    if not isinstance(success, bool):
        _fail("capture {} success must be boolean".format(url))
    status = capture.get("status")
    if not isinstance(status, int) or isinstance(status, bool) or status < 0:
        _fail("capture {} status must be a nonnegative integer".format(url))
    effective_url = _string(capture.get("effective_url"), "capture.effective_url")
    transport = _string(capture.get("transport"), "capture.transport")
    if transport not in ("curl-https", "git-ls-remote"):
        _fail("capture {} uses unsupported transport {}".format(url, transport))
    if urlsplit(url).scheme != "https" or urlsplit(effective_url).scheme != "https":
        _fail("capture {} transport requires HTTPS url and effective_url".format(url))
    expected_success = 200 <= status <= 299 if transport == "curl-https" else status == 0
    if success is not expected_success:
        _fail("capture {} success flag contradicts its exact transport status".format(url))
    captured_bytes = capture.get("bytes")
    if success and (
        not isinstance(captured_bytes, int) or isinstance(captured_bytes, bool)
        or captured_bytes <= 0
    ):
        _fail("successful capture {} must contain nonempty response bytes".format(url))
    relative = _string(capture.get("capture_path"), "capture.capture_path")
    captured_at = _timestamp(capture.get("captured_at_utc"), "capture.captured_at_utc")
    age = (session_start - captured_at).total_seconds()
    if age < 0:
        _fail("capture {} is newer than the Fable session start".format(relative))
    if age > MAX_FRONTIER_CAPTURE_AGE_SECONDS:
        _fail("capture {} is {:.0f}s old; maximum is {}s".format(
            relative, age, MAX_FRONTIER_CAPTURE_AGE_SECONDS
        ))
    path = _contained_path(evidence_root, relative, "capture.capture_path")
    _verify_file(path, capture.get("sha256"), capture.get("bytes"))
    replay_relative = _string(capture.get("replay_record_path"), "capture.replay_record_path")
    replay_path = _contained_path(evidence_root, replay_relative, "capture.replay_record_path")
    replay = _load_json(replay_path)
    expected_replay = {
        "source_capture_path": relative,
        "url": url,
        "effective_url": capture.get("effective_url"),
        "status": status,
        "success": success,
        "transport": capture.get("transport"),
        "sha256": capture.get("sha256"),
        "bytes": capture.get("bytes"),
        "captured_at_utc": capture.get("captured_at_utc"),
    }
    for field, expected in expected_replay.items():
        if replay.get(field) != expected:
            _fail("capture replay record {} differs at {}".format(replay_relative, field))
    return relative, captured_at, success


def _verify_frontier(
    evidence_root: Path,
    ledger: Mapping[str, Any],
    query_manifest: Mapping[str, Any],
    capture_manifest: Mapping[str, Any],
    session_start: dt.datetime,
    base_query_manifest: Mapping[str, Any],
    base_capture_manifest: Mapping[str, Any],
) -> Tuple[int, int]:
    if ledger.get("schema_version") != "frontier-ledger-v1":
        _fail("frontier ledger schema_version must be frontier-ledger-v1")
    if query_manifest.get("schema_version") != "frontier-query-manifest-v1":
        _fail("query manifest schema_version must be frontier-query-manifest-v1")
    if capture_manifest.get("schema_version") != "source-capture-manifest-v1":
        _fail("capture manifest schema_version must be source-capture-manifest-v1")
    if capture_manifest.get("fail_closed") is not True:
        _fail("capture manifest must declare fail_closed=true")
    replay_policy = _string(query_manifest.get("replay_policy"), "query_manifest.replay_policy")
    if replay_policy != _string(base_query_manifest.get("replay_policy"), "base query replay_policy"):
        _fail("refreshed query manifest changed the frozen replay policy")
    _string(capture_manifest.get("policy"), "capture_manifest.policy")

    required = _unique_strings(ledger.get("required_roster"), "ledger.required_roster")
    query_required = _unique_strings(
        query_manifest.get("required_roster"), "query_manifest.required_roster"
    )
    if set(required) != set(REQUIRED_FRONTIER_FAMILIES) or set(query_required) != set(required):
        _fail("frontier required roster is not the frozen 16-family set")
    qwen_names = _unique_strings(
        query_manifest.get("qwen_seed_names"), "query_manifest.qwen_seed_names"
    )
    if set(qwen_names) != set(QWEN_SEED_NAMES) or len(qwen_names) != len(QWEN_SEED_NAMES):
        _fail("Qwen seed names are not the frozen six-name set")
    if set(base_query_manifest.get("qwen_seed_names", [])) != set(QWEN_SEED_NAMES):
        _fail("sealed T0 query manifest does not contain the frozen Qwen seed set")

    search_cutoff = _timestamp(ledger.get("search_cutoff_utc"), "ledger.search_cutoff_utc")
    if _timestamp(query_manifest.get("search_cutoff_utc"), "query_manifest.search_cutoff_utc") != search_cutoff:
        _fail("ledger and query-manifest cutoffs differ")
    if _timestamp(capture_manifest.get("search_cutoff_utc"), "capture_manifest.search_cutoff_utc") != search_cutoff:
        _fail("ledger and capture-manifest cutoffs differ")
    if search_cutoff > session_start:
        _fail("frontier cutoff is newer than the Fable session start")

    seed_queries = _list(query_manifest.get("qwen_seed_queries"), "query_manifest.qwen_seed_queries")
    seed_by_name: Dict[str, Mapping[str, Any]] = {}
    for index, raw in enumerate(seed_queries):
        seed = _mapping(raw, "query_manifest.qwen_seed_queries[{}]".format(index))
        name = _string(seed.get("name"), "qwen seed name")
        _string(seed.get("official_query"), "qwen seed official_query")
        if name in seed_by_name:
            _fail("duplicate Qwen seed query {}".format(name))
        seed_by_name[name] = seed
    if set(seed_by_name) != set(QWEN_SEED_NAMES):
        _fail("query manifest does not contain exactly the frozen Qwen seed queries")
    base_seed_queries = {
        _string(seed.get("name"), "base Qwen seed name"): _mapping(seed, "base Qwen seed")
        for seed in _list(base_query_manifest.get("qwen_seed_queries"), "base qwen_seed_queries")
    }
    if set(base_seed_queries) != set(QWEN_SEED_NAMES):
        _fail("sealed T0 manifest does not contain exactly six Qwen seed queries")
    for name, current_seed in seed_by_name.items():
        if current_seed.get("official_query") != base_seed_queries[name].get("official_query"):
            _fail("refreshed manifest replaced frozen Qwen seed query {}".format(name))

    ledger_seeds = _list(ledger.get("qwen_seed_queries"), "ledger.qwen_seed_queries")
    ledger_seed_names: List[str] = []
    for index, raw in enumerate(ledger_seeds):
        seed = _mapping(raw, "ledger.qwen_seed_queries[{}]".format(index))
        name = _string(seed.get("name"), "ledger Qwen seed name")
        status = _string(seed.get("status"), "ledger Qwen seed status")
        if status not in QWEN_SEED_STATUSES:
            _fail("invalid Qwen seed status for {}".format(name))
        if status == "superseded":
            _string(seed.get("successor"), "successor for {}".format(name))
        _string(seed.get("official_query"), "ledger Qwen seed official_query")
        ledger_seed_names.append(name)
    if len(ledger_seed_names) != len(set(ledger_seed_names)) or set(ledger_seed_names) != set(QWEN_SEED_NAMES):
        _fail("ledger does not contain exactly the frozen Qwen seed records")
    for raw in ledger_seeds:
        ledger_seed = _mapping(raw, "ledger.qwen_seed_queries[]")
        query_seed = seed_by_name[_string(ledger_seed.get("name"), "ledger Qwen seed name")]
        if ledger_seed.get("official_query") != query_seed.get("official_query"):
            _fail("ledger and query manifest disagree on a Qwen seed query")

    branches = _list(ledger.get("qwen_branches"), "ledger.qwen_branches")
    branch_kinds: List[str] = []
    for index, raw in enumerate(branches):
        branch = _mapping(raw, "ledger.qwen_branches[{}]".format(index))
        kind = _string(branch.get("kind"), "Qwen branch kind")
        _mapping(branch.get("official_source"), "Qwen branch official_source")
        if _timestamp(branch.get("query_utc"), "Qwen branch query_utc") != search_cutoff:
            _fail("Qwen branch query timestamp differs from the fresh search cutoff")
        _string(branch.get("latest_checkpoint"), "Qwen branch latest_checkpoint")
        _string(branch.get("exact_revision"), "Qwen branch exact_revision")
        _string(branch.get("d37_disposition"), "Qwen branch d37_disposition")
        branch_kinds.append(kind)
    if len(branch_kinds) != len(set(branch_kinds)) or set(branch_kinds) != set(QWEN_BRANCH_KINDS):
        _fail("Qwen branch set must be exactly asr, audio, and omni")

    queries = _list(ledger.get("queries"), "ledger.queries")
    manifest_queries = _list(query_manifest.get("queries"), "query_manifest.queries")
    if queries != manifest_queries:
        _fail("ledger queries must byte-semantically match the replay query manifest")
    query_families: List[str] = []
    query_ids: List[str] = []
    for index, raw in enumerate(queries):
        query = _mapping(raw, "ledger.queries[{}]".format(index))
        query_ids.append(_string(query.get("query_id"), "query.query_id"))
        query_families.append(_string(query.get("family"), "query.family"))
        _string(query.get("branch"), "query.branch")
        _string(query.get("registry_url"), "query.registry_url")
        _string(query.get("query"), "query.query")
        if _timestamp(query.get("queried_at_utc"), "query.queried_at_utc") != search_cutoff:
            _fail("query timestamp differs from the fresh search cutoff")
        _list(query.get("included"), "query.included")
        excluded = _list(query.get("excluded"), "query.excluded")
        for exclusion in excluded:
            excluded_record = _mapping(exclusion, "query.excluded[]")
            _string(excluded_record.get("result"), "query exclusion result")
            _string(excluded_record.get("reason"), "query exclusion reason")
    if len(query_ids) != len(set(query_ids)):
        _fail("query IDs are not unique")
    if not set(REQUIRED_FRONTIER_FAMILIES).issubset(set(query_families)):
        _fail("query manifest does not cover every required family")
    frozen_inputs = {}
    for raw in _list(base_query_manifest.get("queries"), "base query_manifest.queries"):
        query = _mapping(raw, "base query")
        query_id = _string(query.get("query_id"), "base query ID")
        frozen_inputs[query_id] = tuple(
            query.get(field) for field in ("family", "branch", "registry_url", "query")
        )
    current_inputs = {
        query["query_id"]: tuple(
            query.get(field) for field in ("family", "branch", "registry_url", "query")
        )
        for query in queries
    }
    if not set(frozen_inputs).issubset(current_inputs):
        _fail("refreshed manifest omitted a frozen T0 query")
    for query_id, frozen in frozen_inputs.items():
        if current_inputs[query_id] != frozen:
            _fail("refreshed manifest replaced frozen query input {}".format(query_id))
    additions = sorted(set(current_inputs) - set(frozen_inputs))
    additive_contract = query_manifest.get("additive_discovery")
    if additions:
        contract = _mapping(additive_contract, "query_manifest.additive_discovery")
        declared = _unique_strings(contract.get("query_ids"), "additive_discovery.query_ids")
        _string(contract.get("reason"), "additive_discovery.reason")
        if declared != additions:
            _fail("additive discovery contract does not exactly name extra queries")
    elif additive_contract not in (None, {}):
        _fail("additive discovery contract is present without added queries")

    families = _list(ledger.get("families"), "ledger.families")
    family_names: List[str] = []
    for index, raw in enumerate(families):
        family = _mapping(raw, "ledger.families[{}]".format(index))
        family_names.append(_string(family.get("family"), "family.family"))
        if _timestamp(family.get("query_utc"), "family.query_utc") != search_cutoff:
            _fail("family query timestamp differs from the fresh search cutoff")
        for field in (
            "latest_checkpoint", "release_date", "exact_revision", "license",
            "predecessor", "maccheroni_role",
        ):
            _string(family.get(field), "family.{}".format(field))
        _mapping(family.get("non_dominated_disposition"), "family.non_dominated_disposition")
        _mapping(family.get("conversion_feasibility"), "family.conversion_feasibility")
        _list(family.get("apple_paths"), "family.apple_paths")
        pillars = _mapping(family.get("pillar_evidence"), "family.pillar_evidence")
        if set(("P1", "P2", "P4")) - set(pillars):
            _fail("family {} omits P1, P2, or P4".format(family_names[-1]))
        _list(family.get("included"), "family.included")
        _list(family.get("excluded"), "family.excluded")
        sources = _list(family.get("official_sources"), "family.official_sources")
        if not sources:
            _fail("family {} has no official source".format(family_names[-1]))
    if len(family_names) != len(set(family_names)):
        _fail("frontier family records contain duplicate family names")
    if not set(REQUIRED_FRONTIER_FAMILIES).issubset(set(family_names)):
        _fail("frontier ledger omits a required family")

    captures = _list(capture_manifest.get("captures"), "capture_manifest.captures")
    ledger_captures = _list(ledger.get("source_captures"), "ledger.source_captures")
    if captures != ledger_captures:
        _fail("ledger captures must byte-semantically match capture manifest")
    if capture_manifest.get("capture_count") != len(captures):
        _fail("capture_manifest.capture_count is wrong")
    base_captures = _list(base_capture_manifest.get("captures"), "base capture_manifest.captures")
    base_by_path = {
        _string(item.get("capture_path"), "base capture path"): _mapping(item, "base capture")
        for item in base_captures
    }
    if len(base_by_path) != len(base_captures):
        _fail("sealed T0 capture paths are not unique")
    current_by_path = {
        _string(item.get("capture_path"), "capture path"): _mapping(item, "capture")
        for item in captures
    }
    if len(current_by_path) != len(captures):
        _fail("capture paths must be non-empty and unique")
    for path, base in base_by_path.items():
        current = current_by_path.get(path)
        if current is None or current.get("url") != base.get("url"):
            _fail("frontier replay omitted or relabeled sealed T0 capture {}".format(path))
    base_urls = {_string(item.get("url"), "base capture url") for item in base_captures}
    missing_query_urls = {
        _string(item.get("registry_url"), "base query registry_url")
        for item in _list(base_query_manifest.get("queries"), "base query_manifest.queries")
        if item.get("registry_url") not in base_urls
    }
    extras = [item for path, item in current_by_path.items() if path not in base_by_path]
    if {item.get("url") for item in extras} != missing_query_urls or any(
        item.get("role") != "frozen_query_replay_capture" for item in extras
    ):
        _fail("frontier replay capture universe is not exact T0 captures plus frozen query gaps")
    capture_paths: List[str] = []
    ages: List[float] = []
    failed_capture_paths: List[str] = []
    for raw in captures:
        capture = _mapping(raw, "capture_manifest.captures[]")
        relative, captured_at, success = _verify_capture(capture, evidence_root, session_start)
        capture_paths.append(relative)
        ages.append((session_start - captured_at).total_seconds())
        if not success:
            failed_capture_paths.append(relative)
    if not captures or len(capture_paths) != len(set(capture_paths)):
        _fail("capture paths must be non-empty and unique")

    provenance_relative = _string(
        capture_manifest.get("replay_provenance_path"),
        "capture_manifest.replay_provenance_path",
    )
    replay_provenance_path = _contained_path(
        evidence_root, provenance_relative, "capture replay provenance path"
    )
    _verify_file(replay_provenance_path, capture_manifest.get("replay_provenance_sha256"))
    replay_provenance = _load_json(replay_provenance_path)
    if (
        replay_provenance.get("fail_closed") is not True
        or replay_provenance.get("capture_count") != len(captures)
        or replay_provenance.get("failure_count") != len(failed_capture_paths)
        or replay_provenance.get("failure_paths") != sorted(failed_capture_paths)
    ):
        _fail("frontier replay provenance failure summary differs from exact captures")
    records = _list(replay_provenance.get("records"), "replay provenance records")
    if len(records) != len(captures):
        _fail("frontier replay provenance does not cover the exact capture universe")
    record_paths = [_string(item.get("source_capture_path"), "replay source path") for item in records]
    if set(record_paths) != set(capture_paths) or len(record_paths) != len(set(record_paths)):
        _fail("frontier replay provenance has omitted or duplicate capture identities")
    query_replay = _mapping(query_manifest.get("replay_status"), "query_manifest.replay_status")
    expected_outcome = "supported" if not failed_capture_paths else "evidence_blocker"
    if (
        query_replay.get("capture_count") != len(captures)
        or query_replay.get("transport_failure_count") != len(failed_capture_paths)
        or query_replay.get("outcome") != expected_outcome
        or query_replay.get("source_capture_manifest_sha256") != _digest(
            evidence_root / "source-capture-manifest.json"
        )
    ):
        _fail("query manifest replay status is not a complete successful exact replay")
    ledger_replay = _mapping(ledger.get("replay_status"), "ledger.replay_status")
    if (
        ledger_replay.get("transport_failure_count") != len(failed_capture_paths)
        or ledger_replay.get("outcome") != expected_outcome
    ):
        _fail("frontier ledger replay status differs from exact capture failures")

    source_index = {item["capture_path"]: item for item in captures}
    for raw_branch in branches:
        branch = _mapping(raw_branch, "ledger.qwen_branches[]")
        source = _mapping(branch.get("official_source"), "Qwen branch official_source")
        path = _string(source.get("capture_path"), "Qwen branch source capture_path")
        if path not in source_index or source != source_index[path]:
            _fail("Qwen branch source {} differs from capture manifest".format(path))
    for raw_family in families:
        family = _mapping(raw_family, "ledger.families[]")
        for raw_source in _list(family.get("official_sources"), "family.official_sources"):
            source = _mapping(raw_source, "family.official_sources[]")
            path = _string(source.get("capture_path"), "official source capture_path")
            if path not in source_index or source != source_index[path]:
                _fail("official source {} is absent from or differs from capture manifest".format(path))
    return (int(max(ages)) if ages else 0, len(failed_capture_paths))


def _canonical_sha(value: Any) -> str:
    payload = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


EvidenceResolver = Callable[[str, str, Mapping[str, Any]], bytes]


def _community_stno_replay(
    activity: Sequence[Sequence[int]], target_row: int,
    crop: Optional[Tuple[int, int]] = None,
) -> Tuple[str, int]:
    """Reproduce the reference little-endian [4,1500] STNO bytes without NumPy."""

    if not activity or not 0 <= target_row < len(activity) or any(
        len(row) != 1500 or any(value not in (0, 1) for value in row)
        for row in activity
    ):
        _fail("Community STNO activity is malformed")
    if crop is not None and not 0 <= crop[0] < crop[1] <= 480_000:
        _fail("Community STNO crop bounds are invalid")
    classes = [[], [], [], []]
    non_target_or_overlap = 0
    for frame in range(1500):
        active = crop is None or (frame * 320 < crop[1] and (frame + 1) * 320 > crop[0])
        target = int(active and activity[target_row][frame])
        other = int(active and any(
            row[frame] for index, row in enumerate(activity) if index != target_row
        ))
        overlap = target & other
        target_only = target & (1 - other)
        other_only = other & (1 - target)
        silence = 1 - (target_only | other_only | overlap)
        values = (silence, target_only, other_only, overlap)
        for index, value in enumerate(values):
            classes[index].append(float(value))
        non_target_or_overlap += other_only + overlap
    flattened = [value for row in classes for value in row]
    payload = struct.pack("<{}f".format(len(flattened)), *flattened)
    return hashlib.sha256(payload).hexdigest(), non_target_or_overlap


def _arm_execution_role(arm: Mapping[str, Any]) -> str:
    model = str(arm.get("model"))
    if model == "shipped":
        return "shipped_it" if arm.get("language") == "it" else "shipped_ko"
    return model


def _expected_execution_argv(
    arm: Mapping[str, Any], execution: Mapping[str, Any], provenance: Mapping[str, Any]
) -> List[str]:
    forced = execution.get("forced_language")
    stno = execution.get("stno_sha256")
    return [
        str(_mapping(provenance.get("runner"), "execution runner").get("run_path")),
        "--model-manifest",
        str(_mapping(provenance.get("model_manifest"), "model manifest").get("run_path")),
        "--arm-id", str(arm.get("arm_id")),
        "--fixture-manifest-sha256", str(execution.get("fixture_manifest_sha256")),
        "--audio-sha256", str(execution.get("audio_sha256")),
        "--language-mode", str(execution.get("language_mode")),
        "--forced-language", "null" if forced is None else str(forced),
        "--prompt-sha256", str(execution.get("prompt_sha256")),
        "--stno-sha256", "null" if stno is None else str(stno),
        "--attempt-id", str(execution.get("attempt_id")),
        "--parser", "dicow-terminal-json-v1",
    ]


def _expected_execution_receipt(
    arm: Mapping[str, Any], execution: Mapping[str, Any], provenance: Mapping[str, Any]
) -> Mapping[str, Any]:
    """Return the non-circular process receipt frozen for one arm."""

    model_manifest = _mapping(provenance.get("model_manifest"), "model manifest")
    basis = _mapping(provenance.get("_execution_basis"), "execution basis")
    model_asset = _mapping(provenance.get("model_asset"), "model asset")
    receipt_input = {
        key: value for key, value in execution.items()
        if key not in ("sha256", "receipt")
    }
    return {
        "schema_version": "dicow-runner-receipt-v1",
        "arm_id": arm.get("arm_id"),
        "execution_input_sha256": _canonical_sha(receipt_input),
        "argv": list(execution.get("argv", [])),
        "attempt_id": execution.get("attempt_id"),
        "process_id": execution.get("process_id"),
        "session_id": execution.get("session_id"),
        "order_index": execution.get("order_index"),
        "exit_status": execution.get("exit_status"),
        "runner_sha256": _mapping(provenance.get("runner"), "runner").get("sha256"),
        "lock_sha256": _mapping(provenance.get("lock"), "lock").get("sha256"),
        "t9_state_sha256": _mapping(basis.get("t9_state"), "T9 state").get("sha256"),
        "t13_state_sha256": _mapping(basis.get("t13_state"), "T13 state").get("sha256"),
        "model_manifest_sha256": model_manifest.get("sha256"),
        "model_asset_record_sha256": _canonical_sha(model_asset.get("record")),
        "raw_stdout_sha256": _mapping(execution.get("raw_stdout"), "stdout").get("sha256"),
        "raw_stderr_sha256": _mapping(execution.get("raw_stderr"), "stderr").get("sha256"),
        "parsed_result_sha256": execution.get("parsed_result_sha256"),
    }


def _verify_execution_provenance(
    document: Mapping[str, Any], resolver: Optional[EvidenceResolver],
    r2_candidate_context: Optional[Mapping[str, Any]] = None,
) -> Mapping[str, Mapping[str, Any]]:
    records = _list(document.get("execution_provenance"), "execution_provenance")
    basis = _mapping(document.get("execution_basis"), "execution_basis")
    basis_values: Dict[str, Mapping[str, Any]] = {}
    state_values: Dict[str, Mapping[str, Any]] = {}
    for field, task in (("t9_state", "T9"), ("t13_state", "T13")):
        ref = _mapping(basis.get(field), "execution basis {}".format(field))
        expected_path = "task-state/{}.json".format(task)
        if ref.get("run_path") != expected_path:
            _fail("execution basis {} must cite {}".format(field, expected_path))
        basis_values[field] = ref
        if resolver is not None:
            payload = resolver("run", expected_path, ref)
            try:
                state = _loads_json_object(payload.decode("utf-8"), field)
            except UnicodeDecodeError as exc:
                _fail("{} is not UTF-8: {}".format(field, exc))
            if (
                state.get("task") != task or state.get("state") != "done"
                or state.get("branch_disposition") != "executed"
                or state.get("run_id") != document.get("run_id")
            ):
                _fail("execution basis {} is not a completed state for this run".format(field))
            state_values[field] = state
    if resolver is not None:
        t13_sources = _mapping(
            state_values["t13_state"].get("source_input_hashes"), "T13 sources"
        )
        if t13_sources.get("T9_state") != basis_values["t9_state"].get("sha256"):
            _fail("T13 execution state does not consume the cited T9 state")
    index: Dict[str, Mapping[str, Any]] = {}
    roles: set[str] = set()
    for raw in records:
        record = _mapping(raw, "execution_provenance[]")
        provenance_id = _string(record.get("provenance_id"), "execution provenance ID")
        role = _string(record.get("model_role"), "execution model role")
        if provenance_id in index or role in roles:
            _fail("execution provenance IDs and model roles must be unique")
        pin = EXECUTION_PROVENANCE_PINS.get(role)
        if pin is None:
            _fail("execution provenance uses an unpinned model role")
        candidate_record = (
            r2_candidate_context
            if r2_candidate_context is not None
            and role == r2_candidate_context.get("model_role")
            else None
        )
        expected_model_id = (
            candidate_record.get("model_id") if candidate_record is not None
            else pin["model_id"]
        )
        expected_revision = (
            candidate_record.get("revision") if candidate_record is not None
            else pin["model_revision"]
        )
        if (
            record.get("model_id") != expected_model_id
            or record.get("model_revision") != expected_revision
            or record.get("parser_id") != "dicow-terminal-json-v1"
        ):
            _fail("execution provenance model, revision, or parser differs from pins")
        if record.get("runner_interface") != "dicow-runner-receipt-v1":
            _fail("execution provenance runner interface differs from contract")
        for field, path_key, pin_key, domain in (
            ("runner", "run_path", None, "run"),
            ("lock", "repo_path", "lock_path", "repo"),
        ):
            artifact = _mapping(record.get(field), "execution provenance {}".format(field))
            if pin_key is not None and artifact.get(path_key) != pin[pin_key]:
                _fail("execution provenance {} path differs from its pin".format(field))
            _sha(artifact.get("sha256"), "execution provenance {} SHA".format(field))
            if resolver is not None:
                resolver(domain, str(artifact[path_key]), artifact)
        if (
            record.get("runner_artifact_key") != pin["runner_artifact_key"]
            or record.get("lock_artifact_key") != pin["lock_artifact_key"]
        ):
            _fail("execution provenance runner or lock artifact key differs from pins")
        model_asset = _mapping(record.get("model_asset"), "execution model_asset")
        if model_asset.get("t9_sealed_path_key") != pin["model_asset_key"]:
            _fail("execution model asset key differs from its role pin")
        if candidate_record is not None:
            asset_record = _mapping(model_asset.get("record"), "candidate model asset record")
            if (
                asset_record.get("sha256") != candidate_record.get("model_asset_sha256")
                or asset_record.get("bytes") != candidate_record.get("model_asset_bytes")
            ):
                _fail("inner candidate model asset differs from sealed R3 candidate_source")
        if resolver is not None:
            t13_artifacts = _mapping(
                state_values["t13_state"].get("artifacts"), "T13 artifacts"
            )
            for artifact_field, key_field, path_field in (
                ("runner", "runner_artifact_key", "run_path"),
                ("lock", "lock_artifact_key", "repo_path"),
            ):
                selected = _mapping(
                    t13_artifacts.get(str(record.get(key_field))),
                    "T13 {} artifact".format(artifact_field),
                )
                cited = _mapping(record.get(artifact_field), artifact_field)
                if selected != {
                    "path": cited.get(path_field), "sha256": cited.get("sha256"),
                    "bytes": cited.get("bytes"),
                }:
                    _fail("execution {} differs from cited T13 artifact".format(artifact_field))
            sealed_paths = _mapping(
                state_values["t9_state"].get("sealed_paths"), "T9 sealed_paths"
            )
            sealed_asset = _mapping(
                sealed_paths.get(str(model_asset.get("t9_sealed_path_key"))),
                "T9 sealed model asset",
            )
            if sealed_asset != {
                "path": model_asset.get("path"), "record": model_asset.get("record")
            }:
                _fail("execution model asset differs from cited T9 sealed path")
            try:
                from .preflight import artifact_record
                actual_record = artifact_record(Path(str(model_asset.get("path"))), immutable=True)
            except Exception as exc:
                _fail("cannot replay execution model asset: {}".format(exc))
            if actual_record != model_asset.get("record") or actual_record.get("kind") != model_asset.get("kind"):
                _fail("execution model asset bytes or tree differ from T9 record")
        model_manifest = _mapping(record.get("model_manifest"), "execution model_manifest")
        _string(model_manifest.get("run_path"), "model manifest run_path")
        _sha(model_manifest.get("sha256"), "model manifest SHA")
        if resolver is not None:
            payload = resolver("run", str(model_manifest["run_path"]), model_manifest)
            parsed = _loads_json_object(payload.decode("utf-8"), "model acquisition manifest")
            expected = {
                "schema_version": "model-acquisition-manifest-v1",
                "model_role": role,
                "model_id": record.get("model_id"),
                "model_revision": record.get("model_revision"),
                "model_asset_record_sha256": _canonical_sha(model_asset.get("record")),
            }
            if parsed != expected:
                _fail("model acquisition manifest differs from pinned provenance")
        index[provenance_id] = {**record, "_execution_basis": basis_values}
        roles.add(role)
    required_roles = {_arm_execution_role(arm) for arm in _list(document.get("arms"), "arms")}
    if roles != required_roles:
        _fail("execution provenance does not equal the exact model-role roster")
    return index


def _filesystem_evidence_resolver(run_root: Path, repo_root: Path) -> EvidenceResolver:
    seen: set[Tuple[str, str]] = set()

    def resolve(domain: str, relative: str, record: Mapping[str, Any]) -> bytes:
        if domain not in ("run", "run_absolute", "repo"):
            _fail("unknown evidence domain {}".format(domain))
        if domain != "run_absolute" and Path(relative).is_absolute():
            _fail("evidence artifact path must be relative")
        if domain == "run_absolute":
            if not Path(relative).is_absolute():
                _fail("absolute run evidence path must be absolute")
            expected_relative = _string(
                record.get("run_path"), "absolute run evidence record.run_path"
            )
            expected_path = _contained_path(
                run_root, expected_relative, "run evidence record path", run_root
            )
            path = _contained_path(
                run_root, relative, "absolute run evidence path", run_root
            )
            if path != expected_path:
                _fail("absolute T10 evidence path differs from its run-relative artifact ref")
            _verify_file(path, record.get("sha256"), record.get("bytes"))
            return path.read_bytes()
        key = (domain, relative)
        if domain == "run" and key in seen:
            _fail("duplicate raw evidence artifact path {}".format(relative))
        if domain == "run":
            seen.add(key)
        root = run_root if domain == "run" else repo_root
        path = _contained_path(root, relative, "{} evidence path".format(domain), root)
        _verify_file(path, record.get("sha256"), record.get("bytes"))
        if domain == "run" and relative in ("task-state/T9.json", "task-state/T13.json"):
            if stat.S_IMODE(path.stat().st_mode) & 0o222:
                _fail("execution basis state must be immutable: {}".format(relative))
        return path.read_bytes()

    return resolve


def _verify_community_pack(
    document: Mapping[str, Any], resolver: Optional[EvidenceResolver]
) -> None:
    community = _mapping(document.get("community1"), "experiment.community1")
    pack_ref = _mapping(community.get("pack_manifest"), "community1.pack_manifest")
    _string(pack_ref.get("run_path"), "community pack run_path")
    _sha(pack_ref.get("sha256"), "community pack SHA")
    if resolver is None:
        return
    payload = resolver("run", str(pack_ref["run_path"]), pack_ref)
    pack = _loads_json_object(payload.decode("utf-8"), "Community evidence pack")
    if pack.get("schema_version") != "community1-evidence-pack-v2":
        _fail("Community evidence pack has the wrong schema")
    if (
        pack.get("model_id") != community.get("model_id")
        or pack.get("model_revision") != community.get("revision")
    ):
        _fail("Community evidence pack model identity differs from experiment")
    sandbox_path = Path(__file__).resolve().parents[4] / (
        "benchmarks/scripts/dicow/diarizer/deny-network.sb"
    )
    if community.get("sandbox_profile_sha256") != _digest(sandbox_path):
        _fail("Community sandbox identity differs from the tracked network-denial profile")
    if community.get("raw_evidence_sha256") != pack_ref.get("sha256"):
        _fail("Community raw pack identity differs from its cited bytes")

    t9_ref = _mapping(community.get("t9_canonical"), "Community T9 canonical")
    if pack.get("t9_canonical") != t9_ref:
        _fail("Community evidence pack cites a different T9 canonical")
    t9_payload = resolver("run", _string(t9_ref.get("run_path"), "T9 canonical path"), t9_ref)
    t9 = _loads_json_object(t9_payload.decode("utf-8"), "Community T9 canonical")
    runtime_bindings = _mapping(t9.get("runtime_bindings"), "T9 runtime_bindings")
    runtime = _mapping(runtime_bindings.get("community1"), "T9 Community runtime")
    if runtime.get("model_id") != community.get("model_id") or runtime.get(
        "model_revision"
    ) != community.get("revision"):
        _fail("Community T9 runtime model identity differs from the experiment")
    try:
        from .preflight import artifact_record
    except ImportError as exc:
        _fail("cannot import the Community artifact verifier: {}".format(exc))
    verified_runtime: Dict[str, Mapping[str, Any]] = {}
    for field in ("binary", "model_tree", "sandbox_profile"):
        cited = _mapping(runtime.get(field), "T9 Community {}".format(field))
        path = Path(_string(cited.get("path"), "T9 Community {} path".format(field)))
        try:
            actual = artifact_record(path, immutable=field != "sandbox_profile")
        except Exception as exc:
            _fail("cannot replay Community {} artifact: {}".format(field, exc))
        if cited.get("record") != actual:
            _fail("Community {} bytes or tree differ from T9 canonical".format(field))
        verified_runtime[field] = {"path": str(path), "record": actual}
    binary_record = verified_runtime["binary"]["record"]
    model_record = verified_runtime["model_tree"]["record"]
    sandbox_record = verified_runtime["sandbox_profile"]["record"]
    if (
        binary_record.get("sha256") != community.get("binary_sha256")
        or model_record.get("tree_sha256") != community.get("model_tree_sha256")
        or sandbox_record.get("sha256") != community.get("sandbox_profile_sha256")
        or Path(str(verified_runtime["sandbox_profile"]["path"])).resolve()
        != sandbox_path.resolve()
    ):
        _fail("Community runtime artifact digests differ from T9 or the experiment")

    t10_ref = _mapping(pack.get("t10_pack_manifest"), "Community T10 pack manifest")
    t10_payload = resolver(
        "run", _string(t10_ref.get("run_path"), "T10 pack path"), t10_ref
    )
    t10 = _loads_json_object(t10_payload.decode("utf-8"), "T10 pack manifest")
    if (
        t10.get("schema_version") != "1.0.0"
        or t10.get("pack_id") != "overlap-pack-v1"
        or t10.get("mixture_count") != 10
        or t10.get("pair_target_count") != 20
        or t10.get("community_process_count") != 10
    ):
        _fail("Community T10 pack manifest has the wrong frozen identity or counts")
    mixtures = _list(t10.get("constructed_mixtures"), "T10 constructed_mixtures")
    mixture_index = {
        _string(item.get("window_id"), "T10 window_id"): item for item in mixtures
    }
    if len(mixtures) != 10 or len(mixture_index) != 10:
        _fail("Community T10 pack must contain ten unique constructed windows")

    records = _list(pack.get("records"), "Community evidence pack records")
    windows = [_string(item.get("window_id"), "Community evidence window") for item in records]
    if len(windows) != len(set(windows)):
        _fail("Community evidence pack repeats a window")
    mapping_index = {
        str(item.get("window_id")): item
        for item in _list(document.get("mappings"), "experiment.mappings")
    }
    if set(windows) != set(mapping_index):
        _fail("Community evidence pack does not cover the exact mapping windows")
    activity_hashes: List[str] = []
    spurious_hashes: List[str] = []
    replay_by_window: Dict[str, Mapping[str, Any]] = {}
    for item in records:
        mapping = mapping_index[str(item.get("window_id"))]
        window_id = str(item.get("window_id"))
        mixture = _mapping(mixture_index.get(window_id), "T10 constructed mixture")
        slots = _list(mapping.get("slots"), "mapping slots")
        reference_ids = [str(slot.get("reference_id")) for slot in slots]
        if [mixture.get("target_a"), mixture.get("target_b")] != reference_ids:
            _fail("Community T10 target order differs from the frozen mapping")
        resolved: Dict[str, bytes] = {}
        for field in (
            "audio", "stdout", "stderr", "evidence", "oracle_activity",
            "community_activity", "community_spurious_activity",
        ):
            ref = _mapping(item.get(field), "Community evidence {}".format(field))
            resolved[field] = resolver(
                "run", _string(ref.get("run_path"), "Community {} run_path".format(field)), ref
            )
        try:
            stdout = resolved["stdout"].decode("utf-8")
            stderr = resolved["stderr"].decode("utf-8")
            evidence = _loads_json_object(
                resolved["evidence"].decode("utf-8"), "Community process evidence"
            )
        except UnicodeDecodeError as exc:
            _fail("Community process evidence is not UTF-8: {}".format(exc))
        try:
            from benchmarks.scripts.dicow.diarizer.community1_reference import (
                command_for, merge_segments, parse_segments, rasterize, validate_elapsed,
            )
            segments = parse_segments(stdout)
            labels, provider_activity = rasterize(segments)
            validate_elapsed(float(evidence.get("elapsed_s", float("nan"))))
        except Exception as exc:
            _fail("Community stdout cannot reproduce a valid 50Hz raster: {}".format(exc))
        provider_bytes = bytes(sum(provider_activity, []))
        if resolved["community_activity"] != provider_bytes:
            _fail("Community 50Hz activity artifact differs from parsed stdout")
        if len(resolved["oracle_activity"]) != 2 * 1500:
            _fail("Community oracle activity must have shape [2,1500]")
        oracle_activity = [
            list(resolved["oracle_activity"][offset:offset + 1500])
            for offset in (0, 1500)
        ]
        if any(value not in (0, 1) for row in oracle_activity for value in row):
            _fail("Community oracle activity is not binary")
        if len(resolved["community_spurious_activity"]) != (len(labels) + 1) * 1500:
            _fail("Community spurious activity has the wrong shape")
        spurious_activity = [
            list(resolved["community_spurious_activity"][offset:offset + 1500])
            for offset in range(0, len(resolved["community_spurious_activity"]), 1500)
        ]
        if spurious_activity[:-1] != provider_activity or any(
            value not in (0, 1) for row in spurious_activity for value in row
        ):
            _fail("Community spurious activity does not extend the parsed raster")
        frame_range = _list(
            _mapping(mixture.get("spurious_target"), "T10 spurious target").get("frame_range"),
            "T10 spurious frame range",
        )
        if (
            len(frame_range) != 2 or not all(isinstance(value, int) for value in frame_range)
            or not 0 <= frame_range[0] < frame_range[1] <= 1500
            or spurious_activity[-1]
            != [int(frame_range[0] <= frame < frame_range[1]) for frame in range(1500)]
        ):
            _fail("Community spurious activity does not reproduce its T10 frame range")
        overlap_matrix = {
            str(label): {
                reference_ids[reference_index]: sum(
                    int(a) & int(b)
                    for a, b in zip(provider_activity[label_index], oracle_activity[reference_index])
                )
                for reference_index in range(2)
            }
            for label_index, label in enumerate(labels)
        }
        try:
            from benchmarks.scripts.scoring.speaker_attributed import derive_frozen_mapping
            expected_mapping = derive_frozen_mapping(
                reference_ids, overlap_matrix, window_id=window_id
            )
        except Exception as exc:
            _fail("Community mapping cannot be derived from actual activity: {}".format(exc))
        if expected_mapping != mapping:
            _fail("Community actual activity does not reproduce frozen mapping")
        producer_mapping = _mapping(mixture.get("mapping"), "T10 producer mapping")
        if (
            producer_mapping.get("reference_ids") != reference_ids
            or producer_mapping.get("real_labels") != list(labels)
            or producer_mapping.get("activity_matrix")
            != [[overlap_matrix[label][ref] for ref in reference_ids] for label in labels]
        ):
            _fail("Community T10 mapping does not reproduce actual provider activity")
        t10_providers = _mapping(
            mixture.get("activity_providers"), "T10 activity providers"
        )
        exact_provider_records = {
            "oracle": (
                "oracle_activity", [2, 1500], hashlib.sha256(resolved["oracle_activity"]).hexdigest()
            ),
            "community1": (
                "community_activity", [len(labels), 1500], hashlib.sha256(provider_bytes).hexdigest()
            ),
            "community1_spurious": (
                "community_spurious_activity", [len(labels) + 1, 1500],
                hashlib.sha256(resolved["community_spurious_activity"]).hexdigest(),
            ),
        }
        for provider_name, (record_field, shape, digest) in exact_provider_records.items():
            provider = _mapping(
                t10_providers.get(provider_name), "T10 {} provider".format(provider_name)
            )
            record_ref = _mapping(item.get(record_field), "Community {} ref".format(record_field))
            if provider != {
                "path": record_ref.get("run_path"), "shape": shape, "sha256": digest
            }:
                _fail("Community activity artifact differs from its exact T10 activity-provider tuple")
        if (
            mixture.get("audio_path") != item.get("producer_audio_path")
            or evidence.get("audio_path") != item.get("producer_audio_path")
        ):
            _fail("Community audio artifact differs from the exact T10 mixture path")
        audio_ref = _mapping(item.get("audio"), "Community audio ref")
        t10_audio = resolver(
            "run_absolute",
            _string(mixture.get("audio_path"), "T10 mixture audio_path"),
            audio_ref,
        )
        if t10_audio != resolved["audio"]:
            _fail("Community T10 audio bytes differ from the resolved v2 audio ref")
        expected_segments = [segment.__dict__ for segment in merge_segments(segments)]
        expected_evidence = {
            "schema_version": "1.0.0",
            "argv": list(command_for(
                Path(str(verified_runtime["binary"]["path"])),
                Path(str(evidence.get("audio_path", ""))),
            )),
            "stdout_sha256": hashlib.sha256(resolved["stdout"]).hexdigest(),
            "stderr_sha256": hashlib.sha256(resolved["stderr"]).hexdigest(),
            "exit_status": 0,
            "elapsed_s": evidence.get("elapsed_s"),
            "labels": list(labels),
            "segments": expected_segments,
            "activity_sha256": hashlib.sha256(provider_bytes).hexdigest(),
            "activity": provider_activity,
            "binary_path": str(verified_runtime["binary"]["path"]),
            "binary_sha256": community.get("binary_sha256"),
            "audio_path": evidence.get("audio_path"),
            "audio_sha256": hashlib.sha256(resolved["audio"]).hexdigest(),
            "model_tree_path": str(verified_runtime["model_tree"]["path"]),
            "model_tree_sha256": community.get("model_tree_sha256"),
            "sandbox_sha256": community.get("sandbox_profile_sha256"),
            "t9_canonical_path": item.get("t9_canonical_path"),
            "t9_canonical_sha256": t9_ref.get("sha256"),
        }
        if evidence != expected_evidence:
            _fail("Community process evidence does not match actual producer output")
        community_record = _mapping(mixture.get("community1"), "T10 Community record")
        if (
            community_record.get("raw_stdout") != item.get("producer_stdout_path")
            or community_record.get("evidence_path") != item.get("producer_evidence_path")
            or community_record.get("raw_evidence_sha256")
            != hashlib.sha256(resolved["evidence"]).hexdigest()
            or community_record.get("labels") != list(labels)
            or community_record.get("activity_sha256")
            != hashlib.sha256(provider_bytes).hexdigest()
        ):
            _fail("Community T10 record differs from actual raw evidence")
        activity_hashes.append(hashlib.sha256(provider_bytes).hexdigest())
        spurious_hashes.append(hashlib.sha256(resolved["community_spurious_activity"]).hexdigest())
        replay_by_window[window_id] = {
            "labels": list(labels), "activity": provider_activity,
            "spurious_activity": spurious_activity,
        }
    if community.get("raw_evidence_index_sha256") != _canonical_sha(records):
        _fail("Community raw evidence index hash differs from verified pack")
    if community.get("activity_provider_sha256") != _canonical_sha(activity_hashes):
        _fail("Community activity provider hash differs from verified pack")
    providers = _mapping(document.get("activity_providers"), "activity providers")
    if providers.get("community1_spurious") != _canonical_sha(spurious_hashes):
        _fail("Community spurious activity provider differs from verified pack")

    mapping_slots = {
        str(mapping.get("window_id")): _list(mapping.get("slots"), "mapping slots")
        for mapping in mapping_index.values()
    }
    for raw_arm in _list(document.get("arms"), "experiment arms"):
        arm = _mapping(raw_arm, "experiment arm")
        condition = str(arm.get("condition"))
        if condition not in (
            "dicow-mix-O-community1", "dicow-full-mix-community1",
            "surplus-diagnostic", "dicow-full-spurious",
        ) or arm.get("model") != "dicow" or arm.get("availability", {}).get("status") != "available":
            continue
        execution = _mapping(arm.get("execution_input"), "arm execution_input")
        if execution.get("execution_kind") == "virtual_absent":
            continue
        window_id = str(arm.get("window_id"))
        replay = replay_by_window[window_id]
        labels = list(replay["labels"])
        activity = replay["activity"]
        if condition == "dicow-full-spurious":
            activity = replay["spurious_activity"]
            target_row = len(activity) - 1
        elif condition == "surplus-diagnostic":
            if str(arm.get("target_id")) not in labels:
                _fail("surplus diagnostic label is absent from actual Community activity")
            target_row = labels.index(str(arm.get("target_id")))
        else:
            slots = mapping_slots[window_id]
            slot_index = next(
                index for index, slot in enumerate(slots)
                if slot.get("reference_id") == arm.get("target_id")
            )
            if arm.get("provider_assignment") == "swapped":
                slot_index = 1 - slot_index
            provider_label = slots[slot_index].get("provider_label")
            if provider_label not in labels:
                _fail("arm consumes a provider label absent from actual Community activity")
            target_row = labels.index(provider_label)
        crop = None
        if arm.get("arm_kind") == "crop":
            geometry = _mapping(arm.get("geometry"), "Community crop geometry")
            crop = (
                int(geometry.get("k_start_sample")), int(geometry.get("k_end_sample"))
            )
        stno = _mapping(arm.get("stno"), "Community arm STNO")
        expected_sha, non_target_or_overlap = _community_stno_replay(
            activity, target_row, crop
        )
        if (
            stno.get("sha256") != expected_sha
            or stno.get("class_order") != ["silence", "target", "non_target", "overlap"]
            or stno.get("logical_shape") != [4, 1500]
            or stno.get("runtime_shape") != [1, 4, 1500]
            or stno.get("non_target_or_overlap_frames") != non_target_or_overlap
            or execution.get("stno_sha256") != expected_sha
        ):
            _fail("Community arm STNO does not reproduce actual 50Hz activity")


def _verify_arm_raw_execution(
    arm: Mapping[str, Any], execution: Mapping[str, Any],
    provenance_index: Mapping[str, Mapping[str, Any]], resolver: Optional[EvidenceResolver],
) -> None:
    kind = _string(execution.get("execution_kind"), "arm execution_kind")
    if kind == "virtual_absent":
        if (
            arm.get("availability", {}).get("status") != "available"
            or arm.get("termination", {}).get("terminal_reason") != "diarizer_target_absent"
            or execution.get("result") != {"text": "", "token_ids": []}
            or execution.get("parsed_result_sha256") != _canonical_sha(
                {"text": "", "token_ids": []}
            )
            or execution.get("receipt") is not None
        ):
            _fail("virtual ABSENT execution must be a typed available no-invocation row")
        return
    provenance_id = _string(execution.get("provenance_id"), "arm provenance_id")
    provenance = provenance_index.get(provenance_id)
    if provenance is None or provenance.get("model_role") != _arm_execution_role(arm):
        _fail("arm execution provenance differs from its model role")
    argv = _list(execution.get("argv"), "arm execution argv")
    if argv != _expected_execution_argv(arm, execution, provenance):
        _fail("arm execution argv differs from the frozen invocation")
    status = execution.get("exit_status")
    if not isinstance(status, int) or isinstance(status, bool):
        _fail("arm execution exit status must be an integer")
    if kind == "process" and (
        status != 0 or arm.get("availability", {}).get("status") != "available"
    ):
        _fail("available process execution requires exit status zero")
    if kind == "typed_failure" and arm.get("availability", {}).get("status") == "available":
        _fail("typed failure execution cannot support an available arm")
    stdout = _mapping(execution.get("raw_stdout"), "arm raw_stdout")
    stderr = _mapping(execution.get("raw_stderr"), "arm raw_stderr")
    if execution.get("raw_output_sha256") != stdout.get("sha256"):
        _fail("arm raw output identity must equal its stdout artifact SHA")
    if resolver is None:
        return
    receipt = _mapping(execution.get("receipt"), "arm runner receipt")
    receipt_bytes = resolver(
        "run", _string(receipt.get("run_path"), "runner receipt run_path"), receipt
    )
    try:
        receipt_value = _loads_json_object(
            receipt_bytes.decode("utf-8"), "arm runner receipt"
        )
    except UnicodeDecodeError as exc:
        _fail("arm runner receipt is not UTF-8: {}".format(exc))
    if receipt_value != _expected_execution_receipt(arm, execution, provenance):
        _fail("arm runner receipt differs from frozen execution identity")
    stdout_bytes = resolver("run", _string(stdout.get("run_path"), "stdout run_path"), stdout)
    resolver("run", _string(stderr.get("run_path"), "stderr run_path"), stderr)
    try:
        terminal = _loads_json_object(stdout_bytes.decode("utf-8"), "terminal stdout JSON")
    except UnicodeDecodeError as exc:
        _fail("terminal stdout is not UTF-8: {}".format(exc))
    if kind == "typed_failure":
        if status == 0:
            _fail("typed failure execution requires a nonzero exit status")
        if set(terminal) != {"schema_version", "failure"} or terminal.get(
            "schema_version"
        ) != "dicow-terminal-failure-v1":
            _fail("typed failure stdout must contain one exact terminal failure")
        failure = _mapping(terminal.get("failure"), "terminal stdout failure")
        if set(failure) != {"code", "message"}:
            _fail("typed failure stdout has an invalid failure shape")
        _string(failure.get("code"), "typed failure code")
        _string(failure.get("message"), "typed failure message")
        if execution.get("result") is not None:
            _fail("typed failure execution result must be null")
        if execution.get("parsed_result_sha256") != _canonical_sha(failure):
            _fail("typed failure parsed-result SHA differs from raw stdout")
        return
    if set(terminal) != {"schema_version", "result"} or terminal.get(
        "schema_version"
    ) != "dicow-terminal-output-v1":
        _fail("terminal stdout must contain one exact terminal result")
    result = _mapping(terminal.get("result"), "terminal stdout result")
    if result != execution.get("result"):
        _fail("inline execution result differs from raw stdout")
    if execution.get("parsed_result_sha256") != _canonical_sha(result):
        _fail("parsed result SHA differs from raw stdout result")


def _semantic_frontier_changes(
    base: Mapping[str, Any], current: Mapping[str, Any]
) -> List[Mapping[str, Any]]:
    sections = (
        ("families", "family", {"query_utc", "official_sources"}),
        ("qwen_branches", "kind", {"query_utc", "official_source"}),
        ("qwen_seed_queries", "name", set()),
        ("queries", "query_id", {"queried_at_utc"}),
    )
    changes: List[Mapping[str, Any]] = []
    for section, key_field, ignored in sections:
        old_items = {
            _string(item.get(key_field), "{}.{}".format(section, key_field)): item
            for item in _list(base.get(section), "base ledger {}".format(section))
        }
        new_items = {
            _string(item.get(key_field), "{}.{}".format(section, key_field)): item
            for item in _list(current.get(section), "current ledger {}".format(section))
        }
        for key in sorted(set(old_items) | set(new_items)):
            old = old_items.get(key)
            new = new_items.get(key)
            old_semantic = {k: v for k, v in old.items() if k not in ignored} if old else None
            new_semantic = {k: v for k, v in new.items() if k not in ignored} if new else None
            if old_semantic == new_semantic:
                continue
            record: Dict[str, Any] = {
                "section": section,
                "key": key,
                "change": "added" if old is None else ("removed" if new is None else "changed"),
            }
            if old_semantic is not None:
                record["before_sha256"] = _canonical_sha(old_semantic)
            if new_semantic is not None:
                record["after_sha256"] = _canonical_sha(new_semantic)
            changes.append(record)
    return changes


def _artifact_from_provenance(
    provenance: Mapping[str, Any],
    key: str,
    evidence_dir: Path,
    run_root: Path,
    default_name: str,
) -> Path:
    paths = provenance.get("artifact_paths", {})
    if paths is not None and not isinstance(paths, dict):
        _fail("fable-provenance.artifact_paths must be an object")
    raw = paths.get(key) if isinstance(paths, dict) else None
    if raw is None:
        raw = provenance.get("{}_path".format(key), default_name)
    return _contained_path(evidence_dir, raw, "path for {}".format(key), run_root)


def _canonical_j1_prompt(
    artifact_paths: Mapping[str, Any], input_hashes: Mapping[str, Any],
    evidence_dir: Path, run_root: Path, plan_prefix_bytes: int,
) -> str:
    """Render the exact length-delimited J1 input bytes supplied to Fable."""

    if set(artifact_paths) != set(J1_REQUIRED_INPUT_KEYS):
        _fail("J1 prompt artifact paths do not equal the exact frozen readiness roster")
    if set(input_hashes) != set(J1_REQUIRED_INPUT_KEYS):
        _fail("J1 prompt input hashes do not equal the exact frozen readiness roster")
    records = []
    bodies: List[str] = []
    top_level_paths: Dict[Path, str] = {}
    loaded: Dict[str, Tuple[Path, bytes]] = {}
    for key in J1_REQUIRED_INPUT_KEYS:
        raw_path = _string(artifact_paths.get(key), "J1 prompt path {}".format(key))
        path_value = Path(raw_path)
        if path_value.is_absolute():
            path = path_value.absolute()
        else:
            evidence_candidate = (evidence_dir / path_value).absolute()
            run_candidate = (run_root / path_value).absolute()
            path = evidence_candidate if evidence_candidate.is_file() else run_candidate
        if path.is_symlink() or not path.is_file():
            _fail("J1 prompt input is missing or a symlink: {}".format(key))
        canonical = path.resolve()
        if canonical in top_level_paths:
            _fail("J1 prompt inputs {} and {} alias the same artifact".format(
                top_level_paths[canonical], key
            ))
        top_level_paths[canonical] = key
        raw = path.read_bytes()
        if key == "plan_contract":
            raw = raw[:plan_prefix_bytes]
        expected_sha = _sha(input_hashes.get(key), "J1 prompt hash {}".format(key))
        if hashlib.sha256(raw).hexdigest() != expected_sha:
            _fail("J1 prompt input bytes differ from sealed hash {}".format(key))
        try:
            body = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            _fail("J1 prompt input {} is not UTF-8: {}".format(key, exc))
        records.append({
            "key": key,
            "path": raw_path,
            "sha256": expected_sha,
            "bytes": len(raw),
        })
        bodies.append("INPUT {} {}\n{}".format(key, len(raw), body))
        loaded[key] = (path, raw)

    plan_path = loaded["plan_contract"][0]
    repo_root = plan_path.parent.parent.resolve()

    def append_transitive(key: str, path: Path, expected_sha: Any, expected_bytes: Any) -> None:
        if path.is_symlink() or not path.is_file():
            _fail("J1 transitive input is missing or a symlink: {}".format(key))
        raw = path.read_bytes()
        if hashlib.sha256(raw).hexdigest() != _sha(expected_sha, key + " sha256"):
            _fail("J1 transitive input hash differs: {}".format(key))
        if (
            not isinstance(expected_bytes, int) or isinstance(expected_bytes, bool)
            or expected_bytes != len(raw)
        ):
            _fail("J1 transitive input byte count differs: {}".format(key))
        try:
            body = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            _fail("J1 transitive input {} is not UTF-8: {}".format(key, exc))
        records.append({
            "key": key, "path": str(path), "sha256": hashlib.sha256(raw).hexdigest(),
            "bytes": len(raw),
        })
        bodies.append("INPUT {} {}\n{}".format(key, len(raw), body))

    def append_historical_record(key: str, relative: str, record: Mapping[str, Any]) -> None:
        """Include a superseded historical tuple without reopening current repo bytes."""

        historical = {
            "schema_version": "dicow-historical-artifact-record-v1",
            "path": relative,
            "sha256": _sha(record.get("sha256"), key + " sha256"),
            "bytes": record.get("bytes"),
            "mode": record.get("mode"),
        }
        if (
            not isinstance(historical["bytes"], int)
            or isinstance(historical["bytes"], bool)
            or historical["bytes"] < 0
        ):
            _fail("J1 historical artifact byte count differs: {}".format(key))
        raw = json.dumps(
            historical, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode("utf-8")
        records.append({
            "key": key, "path": relative, "sha256": hashlib.sha256(raw).hexdigest(),
            "bytes": len(raw), "historical_tuple": True,
        })
        bodies.append("INPUT {} {}\n{}".format(key, len(raw), raw.decode("utf-8")))

    initial = _loads_json_object(
        loaded["t0_initial_fable_inputs"][1].decode("utf-8"),
        "J1 initial Fable input manifest",
    )
    for index, raw_item in enumerate(_list(initial.get("inputs"), "initial Fable inputs")):
        item = _mapping(raw_item, "initial Fable input")
        append_transitive(
            "t0_initial_fable_result_{}".format(index),
            Path(_string(item.get("path"), "initial Fable result path")).absolute(),
            item.get("sha256"), item.get("bytes"),
        )

    state_keys = (
        "t0_state", "t1_state", "t1_contract_amendment_1", "t2_state", "t3_state",
        "t4_state", "t5_state", "t6_state", "t7_state",
    )
    for state_key in state_keys:
        state = _loads_json_object(loaded[state_key][1].decode("utf-8"), state_key)
        task_name = _string(state.get("task"), state_key + " task")
        for artifact_name, raw_record in sorted(
            _mapping(state.get("artifacts"), state_key + " artifacts").items()
        ):
            record = _mapping(raw_record, state_key + " artifact")
            relative = _string(record.get("path"), state_key + " artifact path")
            repo_relative = (
                relative in set(J1_STATE_REPO_ARTIFACT_PATHS.get(task_name, ()))
                or (task_name == "T1" and relative.startswith(("docs/", "benchmarks/")))
            )
            transitive_key = "{}:artifact:{}".format(state_key, artifact_name)
            if task_name == "T1" and repo_relative:
                append_historical_record(transitive_key, relative, record)
                continue
            root = repo_root if repo_relative else run_root.resolve()
            path = _contained_path(root, relative, state_key + " artifact path", root)
            append_transitive(
                transitive_key, path,
                record.get("sha256"), record.get("bytes"),
            )
    block = json.dumps(
        {"schema_version": "dicow-j1-fable-inputs-v1", "inputs": records},
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    )
    return (
        "Review every sealed J1 input below. The length-delimited bodies are the exact "
        "bytes supplied for judgment.\n{}\n{}\n".format(block, "\n".join(bodies))
    )


def _verify_j1_inputs(
    provenance: Mapping[str, Any], evidence_dir: Path, run_root: Path,
    input_hashes: Mapping[str, Any], run_manifest: Mapping[str, Any],
) -> None:
    if set(input_hashes) != set(J1_REQUIRED_INPUT_KEYS):
        _fail("J1 input hashes do not equal the exact frozen readiness roster")
    paths = _mapping(provenance.get("artifact_paths"), "J1 artifact_paths")
    if set(paths) != set(J1_REQUIRED_INPUT_KEYS):
        _fail("J1 artifact paths do not equal the exact frozen readiness roster")

    plan_contract = _mapping(run_manifest.get("plan_contract"), "run-manifest.plan_contract")
    plan_path = Path(_string(plan_contract.get("path"), "plan contract path")).absolute()
    if plan_path.is_symlink() or not plan_path.is_file():
        _fail("plan contract path is missing or a symlink")
    plan_bytes = plan_contract.get("bytes")
    if not isinstance(plan_bytes, int) or isinstance(plan_bytes, bool) or plan_bytes <= 0:
        _fail("plan contract byte boundary must be a positive integer")
    raw_plan = plan_path.read_bytes()
    if len(raw_plan) <= plan_bytes or not raw_plan[plan_bytes:].startswith(b"## Results\n"):
        _fail("plan contract boundary is not immediately before the final Results section")
    prefix_sha = hashlib.sha256(raw_plan[:plan_bytes]).hexdigest()
    if (
        plan_contract.get("boundary") != "bytes-before-final-## Results-heading"
        or plan_contract.get("sha256") != prefix_sha
        or run_manifest.get("plan_contract_sha256") != prefix_sha
        or run_manifest.get("plan_contract_bytes") != plan_bytes
        or input_hashes.get("plan_contract") != prefix_sha
    ):
        _fail("J1 plan contract does not authenticate the immutable original prefix")
    repo_root = plan_path.parent.parent.resolve()
    repo_artifacts = {
        "experiment_schema": "docs/contracts/dicow-experiment.schema.json",
        "gate_schema": "docs/contracts/dicow-gate.schema.json",
        "pins": "benchmarks/scripts/dicow/common/pins.py",
        "manifest": "benchmarks/scripts/dicow/common/manifest.py",
        "test_contract": "benchmarks/scripts/dicow/tests/test_contract.py",
        "conversion_lane": "docs/dicow-conversion-lane.md",
        "run_with_env": "benchmarks/scripts/dicow/run_with_env.py",
        "test_run_with_env": "benchmarks/scripts/dicow/tests/test_run_with_env.py",
        "speaker_attributed": "benchmarks/scripts/scoring/speaker_attributed.py",
        "test_speaker_attributed": "benchmarks/scripts/scoring/tests/test_speaker_attributed.py",
        "ctc_invariance": "benchmarks/scripts/dicow/reference/ctc_invariance.py",
        "test_ctc_invariance": "benchmarks/scripts/dicow/tests/test_ctc_invariance.py",
    }
    advisory_paths = {
        "advisory_ctc_value": "fable-checkpoints/20260830T0818-contract-value-ctc-review.md",
        "advisory_target_recovery": "fable-checkpoints/20260830T0829-target-recovery-threshold.md",
        "advisory_qwen3tts_value": "fable-checkpoints/20260830T0855-qwen3tts-j1-value.md",
    }
    run_manifest_path = run_root / "run-manifest.json"
    raw_run_manifest_path = Path(
        _string(paths.get("run_manifest"), "J1 artifact path run_manifest")
    )
    if raw_run_manifest_path.is_absolute():
        candidate_run_manifest = raw_run_manifest_path.absolute()
    else:
        candidate_run_manifest = (run_root / raw_run_manifest_path).absolute()
    if (
        candidate_run_manifest.is_symlink()
        or candidate_run_manifest.resolve() != run_manifest_path.resolve()
        or input_hashes.get("run_manifest") != _digest(run_manifest_path)
    ):
        _fail("J1 run_manifest must bind the exact run-root run-manifest.json")
    for key in J1_REQUIRED_INPUT_KEYS:
        if key in (
            "query_manifest", "frontier_ledger", "source_capture_manifest", "frontier_delta",
            "plan_contract", "run_manifest",
        ):
            continue
        raw_path = _string(paths.get(key), "J1 artifact path {}".format(key))
        if key in repo_artifacts:
            path = (repo_root / repo_artifacts[key]).resolve()
            raw_candidate = Path(raw_path).absolute()
            if raw_candidate.is_symlink() or raw_candidate.resolve() != path:
                _fail("J1 {} path is not the exact repository artifact".format(key))
        else:
            if key in advisory_paths and raw_path != advisory_paths[key]:
                _fail("J1 {} path is not the frozen advisory artifact".format(key))
            path = _contained_path(run_root, raw_path, "J1 artifact path {}".format(key), run_root)
        _verify_file(path, input_hashes.get(key))

    def verify_state_artifacts(state: Mapping[str, Any], task_name: str) -> None:
        artifacts = _mapping(state.get("artifacts"), "{} artifacts".format(task_name))
        recorded_paths: set[str] = set()
        for artifact_name, raw_record in artifacts.items():
            record = _mapping(raw_record, "{} artifact {}".format(task_name, artifact_name))
            relative = _string(record.get("path"), "{} artifact path".format(task_name))
            if relative in recorded_paths:
                _fail("{} state contains duplicate artifact paths".format(task_name))
            recorded_paths.add(relative)
            repo_relative = (
                relative in set(J1_STATE_REPO_ARTIFACT_PATHS.get(task_name, ()))
                or (task_name == "T1" and relative.startswith(("docs/", "benchmarks/")))
            )
            candidate = _contained_path(
                repo_root if repo_relative else run_root,
                relative,
                "{} artifact path".format(task_name),
                repo_root if repo_relative else run_root,
            )
            # The original T1 state remains authenticated as history; its tracked
            # contract bytes are superseded only by the separate amendment state.
            if task_name == "T1" and candidate.is_relative_to(repo_root):
                continue
            _verify_file(candidate, record.get("sha256"), record.get("bytes"))
            expected_mode = record.get("mode")
            if expected_mode is not None and "0{:03o}".format(
                stat.S_IMODE(candidate.stat().st_mode)
            ) != expected_mode:
                _fail("{} artifact mode differs for {}".format(task_name, relative))
        fresh_path = _string(state.get("fresh_check_output_path"), "fresh check output path")
        if fresh_path not in recorded_paths:
            _fail("{} state omits its fresh check output artifact".format(task_name))
        if state.get("fresh_check_output_sha256") != next(
            record.get("sha256") for record in artifacts.values()
            if isinstance(record, dict) and record.get("path") == fresh_path
        ):
            _fail("{} fresh check output hash differs from its artifact tuple".format(task_name))
        required_repo = set(J1_STATE_REPO_ARTIFACT_PATHS.get(task_name, ()))
        if required_repo and not required_repo.issubset(recorded_paths):
            _fail("{} state omits a plan-owned repository artifact".format(task_name))

    states: Dict[str, Mapping[str, Any]] = {}
    for task_key, task_name in (
        ("t0_state", "T0"), ("t1_state", "T1"),
        ("t1_contract_amendment_1", "T1-contract-amendment-1"),
        ("t2_state", "T2"), ("t3_state", "T3"), ("t4_state", "T4"),
        ("t5_state", "T5"), ("t6_state", "T6"), ("t7_state", "T7"),
    ):
        if paths.get(task_key) != "task-state/{}.json".format(task_name):
            _fail("J1 {} path is not the exact task-state artifact".format(task_key))
        state_path = _contained_path(run_root, paths.get(task_key), task_key, run_root)
        state = _load_immutable_json(state_path, task_key)
        states[task_key] = state
        if (
            state.get("task") != task_name or state.get("state") != "done"
            or state.get("branch_disposition") != "executed"
            or state.get("run_id") != run_manifest.get("run_id")
        ):
            _fail("J1 {} is not a completed immutable state for this run".format(task_key))
        if (
            state.get("run_manifest_path") != "run-manifest.json"
            or state.get("run_manifest_sha256") != input_hashes["run_manifest"]
        ):
            _fail("J1 {} does not bind the exact run manifest".format(task_key))
        sources = _mapping(
            state.get("source_input_hashes"), "{} source_input_hashes".format(task_key)
        )
        if set(sources) != set(J1_STATE_SOURCE_KEYS[task_name]):
            _fail("{} dependency keyset differs from the frozen roster".format(task_key))
        verify_state_artifacts(state, task_name)

    def state_artifact_sha(state_key: str, relative: str) -> str:
        artifacts = _mapping(states[state_key].get("artifacts"), state_key + " artifacts")
        matches = [
            _mapping(record, state_key + " artifact")
            for record in artifacts.values()
            if isinstance(record, dict) and record.get("path") == relative
        ]
        if len(matches) != 1:
            _fail("{} must cite exactly one {} artifact".format(state_key, relative))
        return _sha(matches[0].get("sha256"), state_key + " " + relative)

    predecessors = _mapping(
        run_manifest.get("tracked_predecessors"), "run-manifest.tracked_predecessors"
    )
    project_predecessor = _mapping(predecessors.get("PROJECT.md"), "PROJECT predecessor")
    research_predecessor = _mapping(
        predecessors.get("docs/research-digest.md"), "research predecessor"
    )
    conversion_predecessor = _mapping(
        predecessors.get("docs/dicow-conversion-lane.md"), "conversion predecessor"
    )
    scoring_lock = _mapping(run_manifest.get("scoring_lock"), "run-manifest.scoring_lock")
    host_hf = _mapping(
        _mapping(run_manifest.get("host_tools"), "run-manifest.host_tools").get("hf"),
        "run-manifest.host_tools.hf",
    )
    exact_sources: Dict[str, Mapping[str, Any]] = {
        "t0_state": {
            "PROJECT.md": _sha(project_predecessor.get("sha256"), "PROJECT predecessor"),
            "docs/dicow-conversion-lane.md": dict(conversion_predecessor),
            "docs/research-digest.md": _sha(
                research_predecessor.get("sha256"), "research predecessor"
            ),
            "host_hf": _sha(host_hf.get("sha256"), "host hf"),
            "plan_contract": input_hashes["plan_contract"],
            "scoring_uv_lock": _sha(scoring_lock.get("sha256"), "scoring lock"),
        },
        "t1_state": {
            "J0_gate": state_artifact_sha("t0_state", "frontier-j0/gate.json"),
            "T0_state": input_hashes["t0_state"],
            "plan_contract": input_hashes["plan_contract"],
            "run_manifest": input_hashes["run_manifest"],
            "scoring_uv_lock": _sha(scoring_lock.get("sha256"), "scoring lock"),
        },
        "t2_state": {
            "T1_state": input_hashes["t1_state"],
            "aligner_uv_lock": state_artifact_sha(
                "t2_state", "benchmarks/env/dicow-aligner/uv.lock"
            ),
            "plan_contract": input_hashes["plan_contract"],
            "reference_uv_lock": state_artifact_sha(
                "t2_state", "benchmarks/env/dicow-reference/uv.lock"
            ),
            "run_manifest": input_hashes["run_manifest"],
            "source_manifest": state_artifact_sha(
                "t2_state", "t2-source-metadata/manifest.json"
            ),
        },
        "t3_state": {
            "T1_state": input_hashes["t1_state"],
            "docs/research-digest.md": _sha(
                research_predecessor.get("sha256"), "research predecessor"
            ),
            "plan_contract": input_hashes["plan_contract"],
        },
    }
    for state_key, expected in exact_sources.items():
        actual = _mapping(
            states[state_key].get("source_input_hashes"), state_key + " source_input_hashes"
        )
        if actual != expected:
            _fail("{} dependency values differ from the exact frozen sources".format(state_key))

    verify_tracked_transition("T1-contract-amendment-1", run_root, repo_root)

    amendment_sha = input_hashes["t1_contract_amendment_1"]
    t2_sha = input_hashes["t2_state"]
    for task_key in ("t4_state", "t5_state", "t6_state", "t7_state"):
        sources = _mapping(states[task_key].get("source_input_hashes"), "{} sources".format(task_key))
        if sources.get("T1_contract_amendment_1") != amendment_sha:
            _fail("{} does not consume the exact T1 contract amendment".format(task_key))
        if task_key in ("t4_state", "t6_state") and sources.get("T2_state") != t2_sha:
            _fail("{} does not consume the exact T2 state".format(task_key))
    amendment_sources = _mapping(
        states["t1_contract_amendment_1"].get("source_input_hashes"),
        "T1 contract amendment sources",
    )
    expected_amendment_sources = {
        "T1_state": input_hashes["t1_state"],
        "plan_contract": input_hashes["plan_contract"],
        "run_manifest": input_hashes["run_manifest"],
        "advisory_ctc_value": input_hashes["advisory_ctc_value"],
        "advisory_target_recovery": input_hashes["advisory_target_recovery"],
        "advisory_qwen3tts_value": input_hashes["advisory_qwen3tts_value"],
    }
    if amendment_sources != expected_amendment_sources:
        _fail("T1 contract amendment does not bind its exact predecessor and advisories")

    initial_path = _contained_path(
        run_root, paths.get("t0_initial_fable_inputs"), "t0_initial_fable_inputs", run_root
    )
    if paths.get("t0_initial_fable_inputs") != "frontier-j0/initial-fable-inputs.json":
        _fail("J1 initial Fable input manifest path differs from the frozen artifact")
    initial = _load_json(initial_path)
    if initial.get("schema_version") != "fable-starting-inputs-v1":
        _fail("J1 initial Fable input manifest has the wrong schema")
    initial_inputs = _list(initial.get("inputs"), "initial Fable inputs")
    if len(initial_inputs) != 4:
        _fail("J1 initial Fable input manifest must contain exactly four results")
    expected_initial_paths = [
        repo_root / ".plans" / name for name in (
            "fable-product-result.md", "fable-architecture-result.md",
            "fable-skeptic-result.md", "fable-synthesis-result.md",
        )
    ]
    for record, expected_path in zip(initial_inputs, expected_initial_paths):
        item = _mapping(record, "initial Fable input")
        path_value = _string(item.get("path"), "initial Fable input path")
        path = Path(path_value).absolute()
        if path.is_symlink() or path.resolve() != expected_path.resolve():
            _fail("J1 initial Fable input path is not the frozen four-result roster")
        _string(item.get("session_id"), "initial Fable input session_id")
        _verify_file(path, item.get("sha256"), item.get("bytes"))

    readiness_path = _contained_path(
        run_root, paths.get("j1_readiness"), "j1_readiness", run_root
    )
    readiness = _load_json(readiness_path)
    expected_readiness = {
        "schema_version": "dicow-j1-readiness-v1",
        "run_id": run_manifest.get("run_id"),
        "input_hashes": {
            key: input_hashes[key] for key in J1_REQUIRED_INPUT_KEYS if key != "j1_readiness"
        },
        "model_output_count": 0,
        "contract_readiness": 1,
    }
    if readiness != expected_readiness:
        _fail("J1 readiness does not equal the derived immutable input roster")
    forbidden_roots = (
        "e4-upstream", "e6-shipped-stop-only", "mlx-conversion", "control-parity",
        "dicow-parity",
    )
    if any((run_root / name).exists() for name in forbidden_roots):
        _fail("J1 run root already contains model-output namespaces")


def verify_fable(evidence_dir: Path) -> None:
    evidence_dir = evidence_dir.absolute()
    if evidence_dir.is_symlink() or not evidence_dir.is_dir():
        _fail("Fable evidence directory is missing or a symlink: {}".format(evidence_dir))
    run_root = _find_run_root(evidence_dir)
    evidence_dir = evidence_dir.resolve()
    run_manifest = _load_json(run_root / "run-manifest.json")
    provenance_path = evidence_dir / "fable-provenance.json"
    provenance = _load_json(provenance_path)
    if provenance.get("schema_version") != "fable-provenance-v1":
        _fail("fable-provenance schema_version must be fable-provenance-v1")
    if provenance.get("requested_model") != "fable" or provenance.get("actual_model") != FABLE_ACTUAL_MODEL:
        _fail("Fable requested or actual model is wrong")
    if provenance.get("effort") != "max" or provenance.get("fallback") is not False:
        _fail("Fable must use max effort with fallback=false")
    checkpoint = _string(provenance.get("checkpoint"), "fable-provenance.checkpoint")
    if checkpoint not in ("J1", "J2", "J3", "J4", "J5"):
        _fail("verify-fable accepts only J1-J5 checkpoint evidence")
    _string(provenance.get("cli_version"), "fable-provenance.cli_version")
    session_id = _string(provenance.get("session_id"), "fable-provenance.session_id")
    session_start_raw = provenance.get("session_started_at_utc", provenance.get("session_start_utc"))
    session_start = _timestamp(session_start_raw, "fable-provenance.session_started_at_utc")

    prompt_path = _artifact_from_provenance(
        provenance, "prompt", evidence_dir, run_root, "fable-prompt.txt"
    )
    _verify_file(prompt_path, provenance.get("prompt_sha256"))
    raw_path = _artifact_from_provenance(
        provenance, "raw_result", evidence_dir, run_root, "fable-raw.json"
    )
    _verify_file(raw_path, provenance.get("raw_result_sha256"))
    raw_result = _load_json(raw_path)
    usage = _mapping(raw_result.get("modelUsage"), "fable raw modelUsage")
    if list(usage.keys()) != [FABLE_ACTUAL_MODEL]:
        _fail("raw Fable modelUsage must have the sole key {}".format(FABLE_ACTUAL_MODEL))
    if raw_result.get("session_id") != session_id or raw_result.get("is_error") is not False:
        _fail("raw Fable session or error state does not match provenance")
    decision_path = _artifact_from_provenance(
        provenance, "parsed_decision", evidence_dir, run_root, "fable-decision.json"
    )
    decision_sha = provenance.get("parsed_decision_sha256", provenance.get("decision_sha256"))
    _verify_file(decision_path, decision_sha)
    decision_object = _load_json(decision_path)
    raw_decision_text = raw_result.get("result")
    if not isinstance(raw_decision_text, str):
        _fail("raw Fable result must contain the canonical decision JSON string")
    raw_decision = _loads_json_object(raw_decision_text, "raw Fable decision")
    if raw_decision != decision_object:
        _fail("fable-decision.json does not exactly match authenticated raw result bytes")

    base_query_path = _contained_path(
        run_root,
        run_manifest.get("query_manifest_path"),
        "run-manifest.query_manifest_path",
        run_root,
    )
    _verify_file(
        base_query_path,
        run_manifest.get("query_manifest_sha256"),
        run_manifest.get("query_manifest_bytes"),
    )
    base_query_manifest = _load_json(base_query_path)
    base_capture_path = _contained_path(
        run_root,
        run_manifest.get("source_capture_manifest_path"),
        "run-manifest.source_capture_manifest_path",
        run_root,
    )
    _verify_file(
        base_capture_path,
        run_manifest.get("source_capture_manifest_sha256"),
        run_manifest.get("source_capture_manifest_bytes"),
    )
    base_capture_manifest = _load_json(base_capture_path)
    ledger_path = _artifact_from_provenance(
        provenance, "frontier_ledger", evidence_dir, run_root, "frontier-ledger.json"
    )
    query_path = _artifact_from_provenance(
        provenance, "query_manifest", evidence_dir, run_root, "query-manifest.json"
    )
    capture_path = _artifact_from_provenance(
        provenance, "source_capture_manifest", evidence_dir, run_root,
        "source-capture-manifest.json",
    )
    _verify_file(ledger_path, provenance.get("frontier_ledger_sha256"))
    _verify_file(query_path, provenance.get("query_manifest_sha256"))
    capture_hash = provenance.get("source_capture_manifest_sha256")
    if capture_hash is None:
        capture_hash = _mapping(provenance.get("input_hashes"), "fable-provenance.input_hashes").get(
            "source_capture_manifest"
        )
    _verify_file(capture_path, capture_hash)
    ledger = _load_json(ledger_path)
    query_manifest = _load_json(query_path)
    capture_manifest = _load_json(capture_path)
    max_age, replay_failure_count = _verify_frontier(
        ledger_path.parent,
        ledger,
        query_manifest,
        capture_manifest,
        session_start,
        base_query_manifest,
        base_capture_manifest,
    )
    authenticated_decision = _string(raw_decision.get("decision"), "raw Fable decision")
    authenticated_outcome = _string(
        raw_decision.get("evidence_outcome"), "raw Fable evidence outcome"
    )
    _verify_verdict_pair(authenticated_decision, authenticated_outcome)
    if replay_failure_count and (
        authenticated_decision != "revise" or authenticated_outcome != "evidence_blocker"
    ):
        _fail("frontier replay failures permit only revise/evidence_blocker")
    recorded_age = provenance.get("max_capture_age_seconds")
    if not isinstance(recorded_age, int) or isinstance(recorded_age, bool):
        _fail("fable-provenance.max_capture_age_seconds must be an integer")
    if recorded_age != max_age or recorded_age > MAX_FRONTIER_CAPTURE_AGE_SECONDS:
        _fail("recorded max capture age does not match fresh calculation")

    initial_cutoff = _timestamp(
        run_manifest.get("query_manifest_cutoff_utc"), "run-manifest.query_manifest_cutoff_utc"
    )
    current_cutoff = _timestamp(ledger.get("search_cutoff_utc"), "ledger.search_cutoff_utc")
    if checkpoint != "J4" and current_cutoff <= initial_cutoff:
        _fail("{} did not replay the T0 query manifest at a newer cutoff".format(checkpoint))

    delta_path = _artifact_from_provenance(
        provenance, "frontier_delta", evidence_dir, run_root, "frontier-delta.json"
    )
    _verify_file(delta_path, provenance.get("frontier_delta_sha256"))
    delta = _load_json(delta_path)
    if delta.get("schema_version") != "frontier-delta-v1":
        _fail("frontier delta schema_version must be frontier-delta-v1")
    base_ledger_path = _contained_path(
        run_root,
        run_manifest.get("frontier_ledger_path"),
        "run-manifest.frontier_ledger_path",
        run_root,
    )
    _verify_file(
        base_ledger_path,
        run_manifest.get("frontier_ledger_sha256"),
        run_manifest.get("frontier_ledger_bytes"),
    )
    base_ledger = _load_json(base_ledger_path)
    base_hash = delta.get("base_frontier_ledger_sha256", delta.get("previous_frontier_ledger_sha256"))
    if _sha(base_hash, "frontier delta base hash") != _sha(
        run_manifest.get("frontier_ledger_sha256"), "run-manifest.frontier_ledger_sha256"
    ):
        _fail("frontier delta is not based on the sealed T0 ledger")
    current_hash = delta.get("current_frontier_ledger_sha256", delta.get("frontier_ledger_sha256"))
    if _sha(current_hash, "frontier delta current hash") != _digest(ledger_path):
        _fail("frontier delta current hash does not identify the verified ledger")
    recorded_changes = _list(delta.get("changes"), "frontier_delta.changes")
    computed_changes = _semantic_frontier_changes(base_ledger, ledger)
    if recorded_changes != computed_changes:
        _fail("frontier delta changes do not match the recomputed old/new ledger delta")

    input_hashes = _mapping(provenance.get("input_hashes"), "fable-provenance.input_hashes")
    expected_inputs = {
        "query_manifest": _digest(query_path),
        "frontier_ledger": _digest(ledger_path),
        "source_capture_manifest": _digest(capture_path),
        "frontier_delta": _digest(delta_path),
    }
    for key, actual in expected_inputs.items():
        if _sha(input_hashes.get(key), "input_hashes.{}".format(key)) != actual:
            _fail("Fable input hash {} does not match verified evidence".format(key))
    if checkpoint == "J1":
        expected_prompt = _canonical_j1_prompt(
            _mapping(provenance.get("artifact_paths"), "J1 artifact_paths"), input_hashes,
            evidence_dir, run_root, int(run_manifest.get("plan_contract_bytes")),
        )
        if prompt_path.read_text(encoding="utf-8") != expected_prompt:
            _fail("J1 prompt does not contain the exact sealed input path/hash roster")
        _verify_j1_inputs(provenance, evidence_dir, run_root, input_hashes, run_manifest)

    decision = _string(provenance.get("decision"), "fable-provenance.decision")
    outcome = _string(provenance.get("evidence_outcome"), "fable-provenance.evidence_outcome")
    _verify_verdict_pair(decision, outcome)
    reversal = _string(provenance.get("reversal_condition"), "fable-provenance.reversal_condition")
    canonical_evidence = decision_object.get("decisive_evidence", decision_object.get("evidence"))
    canonical_caveats = decision_object.get("caveats", decision_object.get("caveat"))
    comparisons = {
        "decision": decision,
        "evidence_outcome": outcome,
        "reversal_condition": reversal,
        "next_task_ids": _list(provenance.get("next_task_ids"), "provenance.next_task_ids"),
        "skip_tasks": _list(provenance.get("skip_tasks"), "provenance.skip_tasks"),
    }
    for field, value in comparisons.items():
        if decision_object.get(field) != value:
            _fail("provenance {} differs from authenticated Fable decision".format(field))
    if provenance.get("evidence") != canonical_evidence:
        _fail("provenance evidence differs from authenticated Fable decision")
    if provenance.get("caveats") != canonical_caveats:
        _fail("provenance caveats differ from authenticated Fable decision")
    expected_skips = _checkpoint_skip_set(checkpoint, decision)
    if comparisons["skip_tasks"] != expected_skips:
        _fail("{} {} does not carry the exact plan skip set".format(checkpoint, decision))
    expected_next = _checkpoint_next_tasks(checkpoint, decision)
    if comparisons["next_task_ids"] != expected_next:
        _fail("{} {} does not carry the exact next-task set".format(checkpoint, decision))
    print(
        "verified Fable {} session {} with {} captures (max age {}s)".format(
            checkpoint, session_id, len(capture_manifest["captures"]), max_age
        )
    )


def _checkpoint_skip_set(checkpoint: str, verdict: str) -> List[str]:
    if verdict in ("proceed", "revise"):
        return []
    ranges = {
        "J0": ["T{}".format(index) for index in range(1, 29)],
        "J1": ["T{}".format(index) for index in range(9, 29)],
        "J2": ["T{}".format(index) for index in range(17, 29)],
        "J3": ["T26", "T27"],
        "J4": ["T27"],
        "J5": [],
    }
    return ranges[checkpoint]


def _checkpoint_next_tasks(checkpoint: str, verdict: str) -> List[str]:
    if verdict == "revise":
        return []
    return {
        "J0": ["T1"],
        "J1": ["T9"],
        "J2": ["T17"],
        "J3": ["T26"],
        "J4": ["T27"],
        "J5": ["T30"],
    }[checkpoint]


def _checkpoint_allowed_scope(checkpoint: str, verdict: str) -> List[str]:
    if checkpoint == "J0":
        if verdict == "closeout":
            _fail("J0 cannot issue closeout")
        if verdict == "proceed":
            return ["T{}".format(index) for index in range(1, 31)]
        return [] if verdict == "revise" else ["T29", "T30"]
    if checkpoint == "J1":
        if verdict == "proceed":
            return ["T{}".format(index) for index in range(9, 17)]
        return [] if verdict == "revise" else ["T29", "T30"]
    if checkpoint == "J2":
        if verdict == "proceed":
            return ["T{}".format(index) for index in range(17, 29)]
        return [] if verdict == "revise" else ["T29", "T30"]
    if checkpoint == "J3":
        if verdict == "proceed":
            return ["T26", "T27", "T28"]
        return ["T28", "T29", "T30"]
    if checkpoint == "J4":
        if verdict == "proceed":
            return ["T27", "T28"]
        return ["T28", "T29", "T30"]
    if checkpoint == "J5":
        return ["T30"]
    _fail("unknown checkpoint {}".format(checkpoint))
    raise AssertionError("unreachable")


_PARTIAL_PHASE_A_GATES = {
    "PA-T9": ("T9", ["T10", "T11", "T12", "T13", "T14", "T15"]),
    "PA-T11": ("T11", ["T13", "T14", "T15"]),
    "PA-T12": ("T12", ["T13", "T14", "T15"]),
    "PA-T14": ("T14", ["T15"]),
    "PA-T15": ("T15", []),
}


def _partial_pending_skips(gate_path: Path, gate_id: str) -> List[str]:
    del gate_path
    return list(_PARTIAL_PHASE_A_GATES[gate_id][1])


def _verify_non_fable_gate_shape(
    gate_path: Path,
    gate: Mapping[str, Any],
    gate_id: str,
    verdict: str,
    outcome: str,
    next_tasks: List[str],
    skip_tasks: List[str],
    executable_scope: List[str],
) -> None:
    if gate.get("fable") is not None or gate.get("frontier_refresh") not in (None, {}):
        _fail("non-Fable gate may not claim Fable or frontier provenance")
    if gate_id in _PARTIAL_PHASE_A_GATES:
        task, _ = _PARTIAL_PHASE_A_GATES[gate_id]
        if gate.get("gate_kind") != "partial_phase_a_stop" or gate.get("task") != task:
            _fail("partial Phase A gate kind or task is wrong")
        if verdict != "stop" or outcome != "not_supported":
            _fail("partial Phase A gate must be not_supported/stop")
        expected_skips = _partial_pending_skips(gate_path, gate_id)
        if skip_tasks != expected_skips:
            _fail("partial Phase A gate does not exactly name its stage-barrier descendants")
        if next_tasks != ["T16"] or executable_scope != ["T16"]:
            _fail("partial Phase A gate must keep only T16 executable next")
    elif gate_id == "CONTROL-T23":
        if gate.get("gate_kind") != "control_envelope_closeout" or gate.get("task") != "T23":
            _fail("control-envelope gate kind or task is wrong")
        if verdict != "closeout" or outcome != "evidence_blocker":
            _fail("control-envelope gate must be evidence_blocker/closeout")
        if skip_tasks != ["T24"] or next_tasks != ["T25"] or executable_scope != ["T25"]:
            _fail("control-envelope closeout must skip T24 and execute T25")
    else:
        _fail("unknown non-Fable gate {}".format(gate_id))
    if gate.get("skipped_descendants") != skip_tasks:
        _fail("non-Fable skipped_descendants must exactly equal skip_tasks")


def _verify_verdict_pair(verdict: str, outcome: str) -> None:
    if verdict not in BRANCH_VERDICTS:
        _fail("invalid branch verdict {}".format(verdict))
    if outcome not in EVIDENCE_OUTCOMES:
        _fail("invalid evidence outcome {}".format(outcome))
    allowed = {
        "proceed": {"supported"},
        "stop": {"not_supported"},
        "retarget": {"not_supported"},
        "revise": {"evidence_blocker", "unresolved"},
        "closeout": {"evidence_blocker", "unresolved", "not_supported"},
    }
    if outcome not in allowed[verdict]:
        _fail("verdict {} is incompatible with evidence outcome {}".format(verdict, outcome))


def _verify_availability_records(value: Any, trail: str = "gate") -> None:
    if isinstance(value, dict):
        availability = value.get("availability", value.get("status"))
        if availability in ("unavailable", "uncertain"):
            reason = value.get("reason", value.get("unavailable_reason"))
            _string(reason, "{}.reason".format(trail))
        if "metric" in value and value.get("metric") is None:
            _fail("{}.metric may not be null".format(trail))
        if "value" in value and value.get("value") is None and availability not in (
            "unavailable", "not_applicable", "uncertain"
        ):
            _fail("{}.value may be null only for a typed unavailable state".format(trail))
        for key, child in value.items():
            _verify_availability_records(child, "{}.{}".format(trail, key))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _verify_availability_records(child, "{}[{}]".format(trail, index))


def verify_gate(gate_path: Path) -> None:
    gate_path = gate_path.absolute()
    if gate_path.is_symlink() or not gate_path.is_file():
        _fail("gate is missing, not regular, or a symlink: {}".format(gate_path))
    _find_run_root(gate_path.parent)
    gate_path = gate_path.resolve()
    gate = _load_json(gate_path)
    if gate.get("schema_version") == "dicow-r2-gate-envelope-v1":
        _validate_schema_definition(
            gate, "dicow-gate.schema.json", "r2_gate_envelope"
        )
        verify_r2_gate_envelope_document(gate)
        run_root = _find_run_root(gate_path.parent)
        if gate.get("gate_id") == "J1-r2" and {
            entry.name for entry in gate_path.parent.iterdir()
        } != {
            "machine-graph.json", "judgment-packet.txt", "estimator.json",
            "raw.json", "decision.json", "gate.json",
        }:
            _fail("J1-r2 envelope must contain exactly its six canonical files")
        fable = _mapping(gate.get("fable_result"), "r2 fable_result")
        graph_record = _mapping(gate.get("machine_evidence_graph"), "r2 machine graph")
        graph_path = _contained_path(
            gate_path.parent, graph_record.get("path"), "r2 machine graph", run_root
        )
        _verify_file(graph_path, graph_record.get("sha256"), graph_record.get("bytes"))
        packet_record = _mapping(gate.get("judgment_packet"), "r2 judgment packet")
        packet_path = _contained_path(
            gate_path.parent, packet_record.get("path"), "r2 judgment packet", run_root
        )
        _verify_file(packet_path, packet_record.get("sha256"), packet_record.get("bytes"))
        estimator_record = _mapping(gate.get("estimator_artifact"), "r2 estimator artifact")
        estimator_path = _contained_path(
            gate_path.parent, estimator_record.get("path"), "r2 estimator artifact", run_root
        )
        _verify_file(
            estimator_path, estimator_record.get("sha256"), estimator_record.get("bytes")
        )
        if gate.get("gate_id") == "J1-r2":
            _verify_r2_j1_machine_graph(
                graph_path, estimator_path, packet_path, gate, run_root
            )
        raw_path = _contained_path(
            gate_path.parent, fable.get("raw_path"), "r2 Fable raw", run_root
        )
        raw_payload = raw_path.read_bytes()
        _verify_file(raw_path, fable.get("raw_sha256"))
        decision_path = _contained_path(
            gate_path.parent, fable.get("decision_path"), "r2 Fable decision", run_root
        )
        _verify_file(decision_path, fable.get("decision_sha256"))
        decision = _load_json(decision_path)
        if decision != gate.get("decision"):
            _fail("r2 decision artifact differs from the gate")
        raw = _loads_json_object(raw_payload.decode("utf-8"), "r2 Fable raw")
        if raw.get("session_id") != fable.get("session_id"):
            _fail("r2 raw Fable session ID differs from the fresh invocation")
        parsed = _loads_json_object(
            _string(raw.get("result"), "r2 Fable raw.result"), "r2 Fable raw.result"
        )
        if parsed != decision:
            _fail("r2 raw Fable decision differs semantically from the gate")
        provenance = {
            "requested_model": fable.get("requested_model"),
            "actual_model": fable.get("actual_model"),
            "effort": fable.get("effort"),
            "fallback": fable.get("fallback"),
            "prompt_sha256": fable.get("prompt_sha256"),
            "raw_result_sha256": fable.get("raw_sha256"),
            "input_hashes": fable.get("input_hashes"),
            "estimated_input_tokens": fable.get("estimated_input_tokens"),
            "cli_version": fable.get("cli_version"),
            "estimator_version": fable.get("estimator_version"),
            "estimator_source_sha256": fable.get("estimator_source_sha256"),
        }
        verify_r2_fable_judgment(
            packet_path.read_bytes(), fable.get("estimated_input_tokens"), raw_payload, provenance
        )
        print("verified r2 gate {}".format(gate.get("gate_id")))
        return
    _validate_schema(gate, "dicow-gate.schema.json")
    if gate.get("schema_version") != "dicow-gate-v1":
        _fail("gate schema_version must be dicow-gate-v1")
    gate_id = _string(gate.get("gate_id"), "gate.gate_id")
    _string(gate.get("task"), "gate.task")
    verdict = _string(gate.get("branch_verdict"), "gate.branch_verdict")
    outcome = _string(gate.get("evidence_outcome"), "gate.evidence_outcome")
    _verify_verdict_pair(verdict, outcome)
    evidence_ids = _unique_strings(gate.get("evidence_ids"), "gate.evidence_ids")
    if not evidence_ids:
        _fail("gate requires at least one evidence ID")
    evidence_hashes = _mapping(gate.get("evidence_hashes"), "gate.evidence_hashes")
    if not evidence_hashes:
        _fail("gate requires evidence hashes")
    for key, value in evidence_hashes.items():
        _sha(value, "gate.evidence_hashes.{}".format(key))
    _list(gate.get("assumptions"), "gate.assumptions")
    allowed_scope = _mapping(gate.get("allowed_scope"), "gate.allowed_scope")
    executable_scope = _unique_strings(
        allowed_scope.get("execute"), "gate.allowed_scope.execute"
    )
    next_tasks = _unique_strings(gate.get("next_task_ids"), "gate.next_task_ids")
    skip_tasks = _unique_strings(gate.get("skip_tasks"), "gate.skip_tasks")
    if verdict == "proceed" and set(next_tasks) & set(skip_tasks):
        _fail("gate next tasks and skipped tasks overlap")
    if verdict == "proceed" and not next_tasks:
        _fail("proceed gate requires a next task")
    if verdict in ("stop", "retarget") and not skip_tasks and gate_id not in ("J5", "PA-T15"):
        _fail("stop or retarget gate must name skipped descendants")
    _string(gate.get("reversal_condition"), "gate.reversal_condition")
    _timestamp(gate.get("issued_at_utc"), "gate.issued_at_utc")
    _verify_availability_records(gate)

    if gate_id in ("J0", "J1", "J2", "J3", "J4", "J5"):
        expected_skips = _checkpoint_skip_set(gate_id, verdict)
        if skip_tasks != expected_skips:
            _fail("{} {} does not carry the exact plan skip set".format(gate_id, verdict))
        if next_tasks != _checkpoint_next_tasks(gate_id, verdict):
            _fail("{} {} does not carry the exact next-task set".format(gate_id, verdict))
        if executable_scope != _checkpoint_allowed_scope(gate_id, verdict):
            _fail("{} {} does not carry the exact executable scope".format(gate_id, verdict))
        skipped_descendants = gate.get("skipped_descendants", skip_tasks if gate_id == "J0" else None)
        if skipped_descendants != skip_tasks:
            _fail("gate skipped_descendants must exactly equal skip_tasks")
    else:
        _verify_non_fable_gate_shape(
            gate_path, gate, gate_id, verdict, outcome, next_tasks, skip_tasks,
            executable_scope,
        )

    artifact_index = _bind_gate_artifacts(gate_path, gate, evidence_hashes)
    if gate_id == "J1" and set(artifact_index) != {
        "thresholds", "j1_readiness", "fable_decision",
    }:
        _fail("J1 gate evidence roster must be thresholds, j1_readiness, and fable_decision")
    if gate_id != "J0":
        thresholds = _verify_gate_thresholds(gate, artifact_index)
        _verify_gate_metrics(gate, artifact_index, thresholds)

    if gate_id not in ("J0", "J1", "J2", "J3", "J4", "J5"):
        print("verified gate {}: {}/{}".format(gate_id, verdict, outcome))
        return

    fable = _mapping(gate.get("fable"), "gate.fable")
    if fable.get("requested_model") != "fable" or fable.get("actual_model") != FABLE_ACTUAL_MODEL:
        _fail("gate Fable model provenance is wrong")
    if fable.get("effort") != "max" or fable.get("fallback") is not False:
        _fail("gate Fable effort/fallback provenance is wrong")
    for field in ("cli_version", "session_id"):
        _string(fable.get(field), "gate.fable.{}".format(field))
    _sha(fable.get("prompt_sha256"), "gate.fable.prompt_sha256")
    _sha(fable.get("raw_result_sha256"), "gate.fable.raw_result_sha256")
    _mapping(fable.get("input_hashes"), "gate.fable.input_hashes")
    provenance_path = _contained_path(
        gate_path.parent,
        fable.get("provenance_path", "fable-provenance.json"),
        "gate.fable.provenance_path",
        _find_run_root(gate_path.parent),
    )
    _verify_file(provenance_path, fable.get("provenance_sha256"))
    provenance = _load_json(provenance_path)
    comparisons = {
        "requested_model": "requested_model",
        "actual_model": "actual_model",
        "effort": "effort",
        "fallback": "fallback",
        "cli_version": "cli_version",
        "session_id": "session_id",
        "prompt_sha256": "prompt_sha256",
        "raw_result_sha256": "raw_result_sha256",
    }
    for gate_field, provenance_field in comparisons.items():
        if fable.get(gate_field) != provenance.get(provenance_field):
            _fail("gate Fable {} differs from provenance".format(gate_field))
    if fable.get("input_hashes") != provenance.get("input_hashes"):
        _fail("gate Fable input hashes differ from provenance")
    if verdict != provenance.get("decision") or outcome != provenance.get("evidence_outcome"):
        _fail("gate verdict differs from Fable provenance")
    if gate_id in ("J1", "J2", "J3", "J4", "J5"):
        if fable.get("decision_authenticated") is not True:
            _fail("future Fable gate does not authenticate its decision file")
        decision_path = _contained_path(
            gate_path.parent,
            fable.get("decision_path"),
            "gate.fable.decision_path",
            _find_run_root(gate_path.parent),
        )
        _verify_file(decision_path, fable.get("decision_sha256"))
        if artifact_index.get("fable_decision", (None,))[0] != decision_path:
            _fail("gate Fable decision is not bound by evidence_artifacts")
        verify_fable(provenance_path.parent)
        decision_object = _load_json(decision_path)
        for field, expected in (
            ("decision", verdict),
            ("evidence_outcome", outcome),
            ("next_task_ids", next_tasks),
            ("skip_tasks", skip_tasks),
            ("reversal_condition", gate.get("reversal_condition")),
        ):
            if decision_object.get(field) != expected:
                _fail("gate {} differs from authenticated Fable decision".format(field))
        _verify_gate_frontier_refresh(gate, provenance, provenance_path.parent)
    print("verified gate {}: {}/{}".format(gate.get("gate_id"), verdict, outcome))


def _bind_gate_artifacts(
    gate_path: Path, gate: Mapping[str, Any], evidence_hashes: Mapping[str, Any]
) -> Mapping[str, Tuple[Path, Mapping[str, Any]]]:
    run_root = _find_run_root(gate_path.parent)
    artifacts = gate.get("evidence_artifacts")
    if gate.get("gate_id") == "J0" and artifacts is None:
        defaults = {
            "query_manifest": "query-manifest.json",
            "frontier_ledger": "frontier-ledger.json",
            "source_capture_manifest": "source-capture-manifest.json",
            "fable_raw": "fable-raw.json",
            "fable_decision": "fable-decision.json",
        }
        if set(evidence_hashes) - set(defaults):
            _fail("J0 gate contains an unknown or unbound evidence hash key")
        bound: Dict[str, Tuple[Path, Mapping[str, Any]]] = {}
        for key, expected_sha in evidence_hashes.items():
            path = _contained_path(gate_path.parent, defaults[key], "J0 evidence", run_root)
            _verify_file(path, expected_sha)
            bound[key] = (path, {"key": key, "path": defaults[key], "sha256": expected_sha, "bytes": path.stat().st_size})
        return bound
    records = _list(artifacts, "gate.evidence_artifacts")
    bound = {}
    seen_paths: set[Path] = set()
    for raw in records:
        record = _mapping(raw, "gate.evidence_artifacts[]")
        key = _string(record.get("key"), "evidence artifact key")
        if key in bound:
            _fail("duplicate evidence artifact key {}".format(key))
        path = _contained_path(gate_path.parent, record.get("path"), "evidence artifact path", run_root)
        if path in seen_paths:
            _fail("duplicate evidence artifact path {}".format(path))
        seen_paths.add(path)
        _verify_file(path, record.get("sha256"), record.get("bytes"))
        bound[key] = (path, record)
    if set(bound) != set(evidence_hashes):
        _fail("evidence_hashes and evidence_artifacts keys must match exactly")
    for key, (_, record) in bound.items():
        if record.get("sha256") != evidence_hashes[key]:
            _fail("evidence artifact {} hash differs from evidence_hashes".format(key))
    return bound


def _expected_threshold_document() -> Mapping[str, Any]:
    schema = _load_json(Path(__file__).resolve().parents[4] / "docs/contracts/dicow-experiment.schema.json")
    definitions = _mapping(schema.get("$defs"), "experiment schema $defs")
    phase_a_schema = _mapping(definitions.get("phase_a_thresholds"), "phase_a_thresholds")
    phase_b_schema = _mapping(definitions.get("phase_b_thresholds"), "phase_b_thresholds")
    phase_a = {
        key: {name: prop["const"] for name, prop in value["properties"].items()}
        for key, value in phase_a_schema["properties"].items()
    }
    blocker = _mapping(definitions.get("evidence_blocker_gate"), "evidence_blocker_gate")["const"]
    phase_b = {}
    for key, value in phase_b_schema["properties"].items():
        phase_b[key] = value.get("const", blocker)
    return {"phase_a": phase_a, "phase_b": phase_b}


def _verify_gate_thresholds(
    gate: Mapping[str, Any], artifact_index: Mapping[str, Tuple[Path, Mapping[str, Any]]]
) -> Mapping[str, Any]:
    threshold_hash = _sha(gate.get("thresholds_sha256"), "gate.thresholds_sha256")
    if "thresholds" not in artifact_index:
        _fail("future gate has no bound thresholds artifact")
    path, record = artifact_index["thresholds"]
    if record.get("sha256") != threshold_hash:
        _fail("thresholds artifact hash differs from gate.thresholds_sha256")
    thresholds = _load_json(path)
    if thresholds != _expected_threshold_document():
        _fail("threshold artifact content differs from the frozen schema constants")
    return thresholds


def _metric_lower(metric: Mapping[str, Any]) -> Optional[float]:
    interval = metric.get("interval")
    return interval.get("lower") if isinstance(interval, dict) else None


def _metric_upper(metric: Mapping[str, Any]) -> Optional[float]:
    interval = metric.get("interval")
    return interval.get("upper") if isinstance(interval, dict) else None


def _recompute_metric_passed(metric: Mapping[str, Any]) -> bool:
    _reject_nonfinite_numbers(metric, "gate metric")
    point = metric["point"]
    lower = _metric_lower(metric)
    upper = _metric_upper(metric)
    proportion = metric.get("target_proportion")
    criterion = metric["criterion_id"]
    if criterion in (
        "J1.contract_readiness", "S0.repeat_identity", "S8.warm_order_identity",
        "G1.repeat_identity", "G6.semantic_parity", "G9.runtime_topology",
        "G10.pin_provenance", "G11.lock_provenance", "G12.source_provenance",
        "G13.fixture_sidecar_provenance", "G14.parity_mode_provenance",
        "J4.explicit_language", "J4.prompt_every_window", "J4.fixed_window",
        "PA-T9.preflight_stop", "PA-T12.local_derivative_permission",
        "CONTROL-T23.control_envelope",
    ):
        return point == 1
    if criterion == "S3.shipped_korean_overlap_penalty":
        return point <= 0.05
    if criterion == "S4.d_turbo_o":
        return point > 0 and lower is not None and lower > 0
    if criterion == "S4.g_oracle_o":
        return point >= 0.10 and lower is not None and lower > 0 and proportion is not None and proportion >= 0.70
    if criterion in ("S4.p_oracle_n", "S4.p_community1_n"):
        return point <= 0.02 and upper is not None and upper <= 0.02
    if criterion in (
        "S4.target_character_preservation_oracle",
        "S5.target_character_preservation_community1",
    ):
        return point >= 0.75 and lower is not None and lower >= 0.75
    if criterion == "S5.swap_margin":
        return (
            point >= 0.20 and lower is not None and lower > 0
            and proportion is not None and proportion >= 0.90
        )
    if criterion == "S5.g_community1_o":
        return point > 0 and lower is not None and lower > 0
    if criterion == "S5.half_oracle_margin":
        return point >= 0 and lower is not None and lower > 0
    if criterion == "S5.spurious_empty_proportion":
        return point >= 0.80
    if criterion == "S6.dicow_over_turbo_cer":
        return point <= 0.02
    if criterion == "S7.prompt_recall_delta":
        return point >= 0.10
    if criterion == "S7.absent_term_insertions":
        return point == 0
    if criterion == "S7b.prompt_recall_delta":
        return point >= 0 and lower is not None and lower > -0.02
    if criterion == "S7b.cross_speaker_insertions":
        return point == 0
    if criterion == "S9.dicow_cer_improvement":
        return point >= 0.05
    if criterion == "S9.cache_degradation":
        return point <= 0.10
    if criterion == "G2.conversion_contract":
        return point == 12
    if criterion in ("G3.fp32_parity", "G4.bf16_parity"):
        return point <= 2
    if criterion == "G5.mask_sensitivity":
        return 0.5 <= point <= 2 and lower is not None and lower >= 10
    if criterion == "G7.peak_memory_ratio":
        return point <= 2
    if criterion == "G8.window_rtf_ratio":
        return point <= 1.5
    if criterion in (
        "J5.final_value", "PA-T14.upstream_utility", "PA-T15.shipped_stop",
    ):
        return point > 0
    if criterion == "PA-T11.correction_burden":
        return point >= 0.05
    _fail("cannot recompute pass semantics for {}".format(criterion))
    raise AssertionError("unreachable")


def _criterion(
    criterion_id: str, gate: str, estimand: str, strata: Iterable[str]
) -> set[Tuple[str, str, str, str]]:
    return {(criterion_id, gate, estimand, stratum) for stratum in strata}


def _required_metric_matrix(gate_id: str) -> set[Tuple[str, str, str, str]]:
    overall = ("overall",)
    languages = ("overall", "ko", "it", "en")
    not_applicable = ("not_applicable",)
    matrices: Dict[str, set[Tuple[str, str, str, str]]] = {
        "J1": _criterion("J1.contract_readiness", "J1", "contract_readiness", not_applicable),
        "J2": set(),
        "J3": set(),
        "J4": set(),
        "J5": _criterion("J5.final_value", "J5", "final_value", not_applicable),
        "PA-T9": _criterion("PA-T9.preflight_stop", "E0", "preflight", not_applicable),
        "PA-T11": _criterion("PA-T11.correction_burden", "E3", "correction_burden", not_applicable),
        "PA-T12": _criterion("PA-T12.local_derivative_permission", "E5", "license_permission", not_applicable),
        "PA-T14": _criterion("PA-T14.upstream_utility", "E4", "upstream_utility", not_applicable),
        "PA-T15": _criterion("PA-T15.shipped_stop", "E6", "shipped_comparison", not_applicable),
        "CONTROL-T23": _criterion("CONTROL-T23.control_envelope", "CONTROL", "control_envelope", not_applicable),
    }
    j2 = matrices["J2"]
    j2.update(_criterion("S0.repeat_identity", "S0", "repeat_identity", overall))
    j2.update(_criterion("S3.shipped_korean_overlap_penalty", "S3", "cer_delta", ("ko",)))
    for criterion_id, estimand in (
        ("S4.d_turbo_o", "D_turbo^O"),
        ("S4.g_oracle_o", "G_oracle^O"),
        ("S4.p_oracle_n", "P_oracle^N"),
        ("S4.p_community1_n", "P_community1^N"),
        ("S4.target_character_preservation_oracle", "target_character_preservation_oracle"),
        ("S5.swap_margin", "swap_margin"),
        ("S5.g_community1_o", "G_community1^O"),
        ("S5.half_oracle_margin", "half_oracle_margin"),
        ("S5.spurious_empty_proportion", "spurious_empty_proportion"),
        ("S5.target_character_preservation_community1", "target_character_preservation_community1"),
    ):
        j2.update(_criterion(criterion_id, criterion_id.split(".")[0], estimand, languages))
    for criterion_id, gate, estimand, strata in (
        ("S6.dicow_over_turbo_cer", "S6", "cer_delta", ("ko",)),
        ("S7.prompt_recall_delta", "S7", "prompt_recall_delta", ("ko",)),
        ("S7.absent_term_insertions", "S7", "absent_term_insertions", ("ko",)),
        ("S7b.prompt_recall_delta", "S7b", "prompt_recall_delta", ("ko",)),
        ("S7b.cross_speaker_insertions", "S7b", "cross_speaker_insertions", ("ko",)),
        ("S8.warm_order_identity", "S8", "repeat_identity", overall),
        ("S9.dicow_cer_improvement", "S9", "cer_delta", ("ko", "it")),
        ("S9.cache_degradation", "S9", "cache_degradation", ("ko", "it")),
    ):
        j2.update(_criterion(criterion_id, gate, estimand, strata))
    for index, criterion_id, estimand in (
        (1, "G1.repeat_identity", "repeat_identity"),
        (2, "G2.conversion_contract", "conversion_contract"),
        (3, "G3.fp32_parity", "parity"),
        (4, "G4.bf16_parity", "parity"),
        (5, "G5.mask_sensitivity", "mask_sensitivity"),
        (6, "G6.semantic_parity", "parity"),
        (7, "G7.peak_memory_ratio", "resource_ratio"),
        (8, "G8.window_rtf_ratio", "resource_ratio"),
        (9, "G9.runtime_topology", "runtime_contract"),
        (10, "G10.pin_provenance", "provenance"),
        (11, "G11.lock_provenance", "provenance"),
        (12, "G12.source_provenance", "provenance"),
        (13, "G13.fixture_sidecar_provenance", "provenance"),
        (14, "G14.parity_mode_provenance", "provenance"),
    ):
        matrices["J3"].update(_criterion(criterion_id, "G{}".format(index), estimand, not_applicable))
    for criterion_id, estimand in (
        ("J4.explicit_language", "language_behavior"),
        ("J4.prompt_every_window", "prompt_behavior"),
        ("J4.fixed_window", "window_behavior"),
    ):
        matrices["J4"].update(_criterion(criterion_id, "J4", estimand, not_applicable))
    if gate_id not in matrices:
        _fail("gate {} has no frozen metric criterion matrix".format(gate_id))
    return matrices[gate_id]


def _verify_gate_metrics(
    gate: Mapping[str, Any],
    artifact_index: Mapping[str, Tuple[Path, Mapping[str, Any]]],
    thresholds: Mapping[str, Any],
) -> None:
    del thresholds
    _reject_nonfinite_numbers(gate, "gate")
    metrics = _list(gate.get("metrics"), "gate.metrics")
    metric_ids: set[str] = set()
    signatures: set[Tuple[str, str, str, str]] = set()
    metrics_by_signature: Dict[Tuple[str, str, str, str], Mapping[str, Any]] = {}
    experiment_cache: Dict[Path, Mapping[str, Any]] = {}
    threshold_hash = gate.get("thresholds_sha256")
    for raw in metrics:
        metric = _mapping(raw, "gate.metrics[]")
        metric_id = _string(metric.get("metric_id"), "gate metric ID")
        if metric_id in metric_ids:
            _fail("duplicate gate metric ID {}".format(metric_id))
        metric_ids.add(metric_id)
        signature = (
            _string(metric.get("criterion_id"), "gate metric criterion_id"),
            _string(metric.get("gate"), "gate metric gate"),
            _string(metric.get("estimand"), "gate metric estimand"),
            _string(metric.get("stratum"), "gate metric stratum"),
        )
        if signature in signatures:
            _fail("duplicate gate metric criterion cell {}".format(signature))
        signatures.add(signature)
        metrics_by_signature[signature] = metric
        if metric.get("thresholds_sha256") != threshold_hash:
            _fail("gate metric thresholds hash differs from frozen thresholds")
        evidence_key = _string(metric.get("evidence_key"), "gate metric evidence_key")
        if evidence_key not in artifact_index:
            _fail("gate metric cites an unbound evidence key")
        if metric.get("evidence_sha256") != artifact_index[evidence_key][1].get("sha256"):
            _fail("gate metric evidence hash differs from its bound artifact")
        if gate.get("gate_id") in ("J2", "J3"):
            evidence_path = artifact_index[evidence_key][0]
            experiment = experiment_cache.get(evidence_path)
            if experiment is None:
                experiment = verify_experiment_path(evidence_path)
                experiment_cache[evidence_path] = experiment
            matches = [
                item for item in _list(experiment.get("metrics"), "experiment.metrics")
                if isinstance(item, dict) and item.get("metric_id") == metric_id
            ]
            if len(matches) != 1:
                _fail("gate metric ID does not identify exactly one experiment metric")
            experiment_metric = matches[0]
            for field in (
                "criterion_id", "gate", "estimand", "stratum", "availability",
                "point", "interval", "target_proportion", "cluster_count",
            ):
                if metric.get(field) != experiment_metric.get(field):
                    _fail("gate metric {} differs from bound experiment metric".format(field))
        if signature[0] == "PA-T11.correction_burden":
            evidence_path = artifact_index[evidence_key][0]
            experiment = experiment_cache.get(evidence_path)
            if experiment is None:
                experiment = verify_experiment_path(evidence_path)
                experiment_cache[evidence_path] = experiment
            burden = _mapping(
                experiment.get("correction_burden"), "PA-T11 correction_burden evidence"
            )
            burden_availability = _mapping(
                burden.get("availability"), "PA-T11 correction_burden availability"
            )
            if metric.get("availability") != burden_availability:
                _fail("PA-T11 metric availability differs from correction burden evidence")
            if metric.get("point") != burden.get("ratio"):
                _fail("PA-T11 metric point must equal the bound correction burden ratio")
        availability = _mapping(metric.get("availability"), "gate metric availability")
        if availability.get("status") == "available":
            criterion_id = signature[0]
            interval = metric.get("interval")
            two_sided = {
                "S4.d_turbo_o", "S4.g_oracle_o", "S5.swap_margin", "S5.g_community1_o",
                "S5.half_oracle_margin", "S7b.prompt_recall_delta",
                "S4.target_character_preservation_oracle",
                "S5.target_character_preservation_community1",
                "G5.mask_sensitivity",
            }
            one_sided = {"S4.p_oracle_n", "S4.p_community1_n"}
            if criterion_id in two_sided:
                if not isinstance(interval, dict) or interval.get("kind") != "two_sided_95_percentile":
                    _fail("{} requires a two-sided numeric interval".format(criterion_id))
                if metric.get("cluster_count", 0) < 2:
                    _fail("{} requires at least two paired clusters".format(criterion_id))
            if criterion_id in one_sided:
                if not isinstance(interval, dict) or interval.get("kind") != "one_sided_upper_95_percentile":
                    _fail("{} requires a one-sided upper interval".format(criterion_id))
                if metric.get("cluster_count", 0) < 2:
                    _fail("{} requires at least two paired clusters".format(criterion_id))
            recomputed = _recompute_metric_passed(metric)
            if metric.get("passed") is not recomputed:
                _fail("gate metric asserted pass differs from frozen threshold recomputation")
    gate_id = gate.get("gate_id")
    required = _required_metric_matrix(_string(gate_id, "gate.gate_id"))
    if signatures != required:
        missing = sorted(required - signatures)
        unexpected = sorted(signatures - required)
        _fail("gate metric criterion matrix mismatch; missing={} unexpected={}".format(
            missing, unexpected
        ))
    if gate.get("branch_verdict") == "proceed":
        for signature in sorted(required):
            metric = metrics_by_signature[signature]
            must_pass = signature[0] != "S3.shipped_korean_overlap_penalty"
            if metric.get("availability", {}).get("status") != "available" or (
                must_pass and metric.get("passed") is not True
            ):
                _fail("proceed gate has unavailable or nonpassing required criterion {}".format(signature))
    if gate.get("gate_kind") == "partial_phase_a_stop":
        for signature in sorted(required):
            metric = metrics_by_signature[signature]
            if metric.get("availability", {}).get("status") != "available" or metric.get("passed") is not False:
                _fail("non-Fable stop gate lacks an available failing criterion {}".format(signature))
    if gate.get("gate_kind") == "control_envelope_closeout":
        for signature in sorted(required):
            metric = metrics_by_signature[signature]
            if metric.get("availability", {}).get("status") == "available" and metric.get("passed") is not False:
                _fail("control closeout may not assert a passing envelope criterion {}".format(signature))


def _verify_gate_frontier_refresh(
    gate: Mapping[str, Any], provenance: Mapping[str, Any], evidence_dir: Path
) -> None:
    refresh = _mapping(gate.get("frontier_refresh"), "gate.frontier_refresh")
    expected = {
        "query_manifest_sha256": provenance.get("query_manifest_sha256"),
        "ledger_sha256": provenance.get("frontier_ledger_sha256"),
        "source_capture_manifest_sha256": provenance.get("source_capture_manifest_sha256", provenance.get("input_hashes", {}).get("source_capture_manifest")),
        "fable_session_start_utc": provenance.get("session_started_at_utc", provenance.get("session_start_utc")),
    }
    for field, value in expected.items():
        if refresh.get(field) != value:
            _fail("gate frontier_refresh {} differs from verified Fable package".format(field))
    run_root = _find_run_root(evidence_dir)
    ledger_path = _artifact_from_provenance(
        provenance, "frontier_ledger", evidence_dir, run_root, "frontier-ledger.json"
    )
    ledger = _load_json(ledger_path)
    if refresh.get("search_cutoff_utc") != ledger.get("search_cutoff_utc"):
        _fail("gate frontier cutoff differs from verified ledger")
    if refresh.get("maximum_capture_age_hours") != 6:
        _fail("gate frontier capture-age ceiling is not six hours")
    if set(refresh.get("required_families", [])) != set(REQUIRED_FRONTIER_FAMILIES):
        _fail("gate frontier family set differs from frozen roster")
    if set(refresh.get("qwen_branches", [])) != set(QWEN_BRANCH_KINDS):
        _fail("gate Qwen branch set differs from frozen roster")
    if set(refresh.get("qwen_seed_queries", [])) != set(QWEN_SEED_NAMES):
        _fail("gate Qwen seed set differs from frozen roster")


_J2_CAUSAL_ROLES: Mapping[str, Tuple[Tuple[str, str, str, str, str], ...]] = {
    "S3.shipped_korean_overlap_penalty": (
        ("shipped", "shipped-ko-meeting-single", "shipped_comparator", "not_applicable", "single"),
        ("shipped", "shipped-ko-meeting-mix", "shipped_comparator", "not_applicable", "full_window"),
    ),
    "S4.d_turbo_o": (
        ("turbo", "turbo-clean-O", "corrected_prompt_on", "not_applicable", "crop"),
        ("turbo", "turbo-mix-O", "corrected_prompt_on", "not_applicable", "crop"),
    ),
    "S4.g_oracle_o": (
        ("turbo", "turbo-clean-O", "corrected_prompt_on", "not_applicable", "crop"),
        ("turbo", "turbo-mix-O", "corrected_prompt_on", "not_applicable", "crop"),
        ("dicow", "dicow-clean-O", "corrected_prompt_on", "not_applicable", "crop"),
        ("dicow", "dicow-mix-O-oracle", "corrected_prompt_on", "correct", "crop"),
    ),
    "S4.p_oracle_n": (
        ("dicow", "dicow-clean-single-utility", "corrected_prompt_on", "not_applicable", "full_window"),
        ("dicow", "dicow-full-mix-oracle", "corrected_prompt_on", "correct", "full_window"),
    ),
    "S4.p_community1_n": (
        ("dicow", "dicow-clean-single-utility", "corrected_prompt_on", "not_applicable", "full_window"),
        ("dicow", "dicow-full-mix-community1", "corrected_prompt_on", "correct", "full_window"),
    ),
    "S4.target_character_preservation_oracle": (
        ("dicow", "dicow-clean-O", "corrected_prompt_on", "not_applicable", "crop"),
        ("dicow", "dicow-mix-O-oracle", "corrected_prompt_on", "correct", "crop"),
    ),
    "S5.swap_margin": (
        ("dicow", "dicow-mix-O-community1", "corrected_prompt_on", "correct", "crop"),
        ("dicow", "dicow-mix-O-community1", "corrected_prompt_on", "swapped", "crop"),
    ),
    "S5.g_community1_o": (
        ("turbo", "turbo-clean-O", "corrected_prompt_on", "not_applicable", "crop"),
        ("turbo", "turbo-mix-O", "corrected_prompt_on", "not_applicable", "crop"),
        ("dicow", "dicow-clean-O", "corrected_prompt_on", "not_applicable", "crop"),
        ("dicow", "dicow-mix-O-community1", "corrected_prompt_on", "correct", "crop"),
    ),
    "S5.half_oracle_margin": (
        ("turbo", "turbo-clean-O", "corrected_prompt_on", "not_applicable", "crop"),
        ("turbo", "turbo-mix-O", "corrected_prompt_on", "not_applicable", "crop"),
        ("dicow", "dicow-clean-O", "corrected_prompt_on", "not_applicable", "crop"),
        ("dicow", "dicow-mix-O-oracle", "corrected_prompt_on", "correct", "crop"),
        ("dicow", "dicow-mix-O-community1", "corrected_prompt_on", "correct", "crop"),
    ),
    "S5.target_character_preservation_community1": (
        ("dicow", "dicow-clean-O", "corrected_prompt_on", "not_applicable", "crop"),
        ("dicow", "dicow-mix-O-community1", "corrected_prompt_on", "correct", "crop"),
    ),
    "S5.spurious_empty_proportion": (
        ("dicow", "dicow-full-spurious", "diagnostic", "not_applicable", "full_window"),
    ),
    "S6.dicow_over_turbo_cer": (
        ("turbo", "turbo-hike-single", "automatic_language_control", "not_applicable", "single"),
        ("turbo", "turbo-hike-single", "explicit_language_control", "not_applicable", "single"),
        ("dicow", "dicow-hike-single", "automatic_language_control", "not_applicable", "single"),
        ("dicow", "dicow-hike-single", "explicit_language_control", "not_applicable", "single"),
    ),
    "S7.prompt_recall_delta": (
        ("dicow", "dicow-hike-single", "prompt_off_control", "not_applicable", "single"),
        ("dicow", "dicow-hike-single", "corrected_prompt_on", "not_applicable", "single"),
    ),
    "S7.absent_term_insertions": (
        ("dicow", "dicow-fleurs-ko-clean", "corrected_prompt_on", "not_applicable", "single"),
    ),
    "S7b.prompt_recall_delta": (
        ("dicow", "dicow-full-mix-community1", "prompt_off_control", "correct", "full_window"),
        ("dicow", "dicow-full-mix-community1", "corrected_prompt_on", "correct", "full_window"),
    ),
    "S7b.cross_speaker_insertions": (
        ("dicow", "dicow-full-mix-community1", "corrected_prompt_on", "correct", "full_window"),
    ),
    "S8.warm_order_identity": (
        ("dicow", "dicow-full-mix-community1", "warm_order_a_then_b", "correct", "full_window"),
        ("dicow", "dicow-full-mix-community1", "warm_order_b_then_a", "correct", "full_window"),
    ),
    "S9.dicow_cer_improvement": (
        ("shipped", "shipped-full-mix-community1", "shipped_comparator", "not_applicable", "full_window"),
        ("dicow", "dicow-full-mix-community1", "corrected_prompt_on", "correct", "full_window"),
    ),
    "S9.cache_degradation": (
        ("shipped", "shipped-ko-meeting-single", "shipped_comparator", "not_applicable", "single"),
        ("dicow", "dicow-hike-single", "automatic_language_control", "not_applicable", "single"),
        ("dicow", "dicow-hike-single", "explicit_language_control", "not_applicable", "single"),
    ),
}

_J2_STRATUM_CAUSAL_ROLES: Mapping[
    Tuple[str, str], Tuple[Tuple[str, str, str, str, str], ...]
] = {
    ("S9.cache_degradation", "it"): (
        ("shipped", "shipped-it-dialogue-single", "shipped_comparator", "not_applicable", "single"),
        ("dicow", "dicow-it-dialogue-single", "corrected_prompt_on", "not_applicable", "single"),
    ),
}


def _nearest_rank(values: Sequence[float], probability: float) -> float:
    ordered = sorted(values)
    return ordered[max(1, math.ceil(probability * len(ordered))) - 1]


def _numeric_output(arm: Mapping[str, Any], field: str) -> float:
    output = _mapping(arm.get("output"), "cited arm output")
    value = output.get(field)
    if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value):
        _fail("cited arm output {} must be finite numeric evidence".format(field))
    return float(value)


def _bootstrap_interval(
    rows: Sequence[Tuple[str, str, str, int, float]]
) -> Tuple[float, float, float]:
    if not rows:
        _fail("metric has no rows for frozen bootstrap recomputation")
    grouped: Dict[Tuple[str, str, int], List[float]] = {}
    for fixture_family, language, _window_id, repetition, value in rows:
        grouped.setdefault((fixture_family, language, repetition), []).append(value)
    rng = random.Random(20_260_830)
    replicates: List[float] = []
    for _ in range(10_000):
        sampled: List[float] = []
        for group_rows in grouped.values():
            sampled.extend(group_rows[rng.randrange(len(group_rows))] for _ in group_rows)
        replicates.append(sum(sampled) / len(sampled))
    return (
        _nearest_rank(replicates, 0.025),
        _nearest_rank(replicates, 0.95),
        _nearest_rank(replicates, 0.975),
    )


def _aggregate_window_rows(
    chunks: Sequence[Sequence[Mapping[str, Any]]], values: Sequence[float]
) -> List[Tuple[str, str, str, int, float]]:
    grouped: Dict[Tuple[str, str, str, int], List[Tuple[str, float]]] = {}
    for chunk, value in zip(chunks, values):
        arm = chunk[0]
        key = (
            str(arm.get("fixture_family")), str(arm.get("language")),
            str(arm.get("window_id")), int(arm.get("repetition")),
        )
        grouped.setdefault(key, []).append((str(arm.get("target_id")), value))
    rows: List[Tuple[str, str, str, int, float]] = []
    for key, members in sorted(grouped.items()):
        if len(members) != 2 or len({target_id for target_id, _ in members}) != 2:
            _fail("paired metric window does not contain exactly two frozen targets")
        rows.append((*key, sum(value for _, value in members) / 2))
    return rows


def _assert_metric_value(recorded: Any, computed: float, field: str) -> None:
    if not isinstance(recorded, (int, float)) or isinstance(recorded, bool) or not math.isclose(
        float(recorded), computed, rel_tol=1e-12, abs_tol=1e-12
    ):
        _fail("metric {} differs from bound arm recomputation".format(field))


def _verify_scorer_evidence(
    arm: Mapping[str, Any], inventory_item: Mapping[str, Any]
) -> None:
    """Replay every scorer-owned field from the exact reference and result text."""

    output = _mapping(arm.get("output"), "available arm output")
    execution = _mapping(arm.get("execution_input"), "arm execution_input")
    result = _mapping(execution.get("result"), "arm execution result")
    replay = _mapping(output.get("score_replay"), "arm score_replay")
    if output.get("score_replay_sha256") != _canonical_sha(replay):
        _fail("arm score_replay_sha256 differs from its exact replay payload")
    score_reference = _mapping(
        inventory_item.get("score_reference"), "sealed fixture score_reference"
    )
    if inventory_item.get("score_reference_sha256") != _canonical_sha(score_reference):
        _fail("sealed fixture score reference hash differs from its payload")
    replay_reference = {
        key: replay.get(key) for key in (
            "reference", "expected_terms", "absent_terms", "other_target_terms",
            "reference_regions",
        )
    }
    if replay_reference != score_reference:
        _fail("arm score replay inputs differ from sealed fixture reference evidence")
    if replay.get("hypothesis") != result.get("text"):
        _fail("arm score replay hypothesis differs from the exact execution result text")
    if output.get("token_ids_sha256") != _canonical_sha(result.get("token_ids")):
        _fail("arm token ID hash differs from the exact execution result")
    try:
        from benchmarks.scripts.scoring.speaker_attributed import (
            score_empty_reference_diagnostic, score_target,
        )

        condition = str(arm.get("condition"))
        if condition in ("surplus-diagnostic", "dicow-full-spurious"):
            replayed = score_empty_reference_diagnostic(
                str(replay.get("hypothesis")),
                kind="surplus" if condition == "surplus-diagnostic" else "spurious",
            )
        else:
            replayed = score_target(
                str(replay.get("reference")),
                str(replay.get("hypothesis")),
                expected_terms=_list(replay.get("expected_terms"), "scorer expected_terms"),
                absent_terms=_list(replay.get("absent_terms"), "scorer absent_terms"),
                other_target_terms=_list(
                    replay.get("other_target_terms"), "scorer other_target_terms"
                ),
                reference_regions=replay.get("reference_regions"),
            )
    except Exception as exc:
        _fail("arm scorer evidence cannot be replayed: {}".format(exc))

    expected_output = dict(replayed)
    expected_output.setdefault("regional", None)
    expected_output.setdefault("stable_o_counts", None)
    if isinstance(replayed.get("cer_counts"), dict):
        expected_output["character_insertions"] = replayed["cer_counts"].get("insertions")
        expected_output["word_insertions"] = _mapping(
            replayed.get("wer_counts"), "replayed WER counts"
        ).get("insertions")
    for field, expected in expected_output.items():
        if output.get(field) != expected:
            _fail("arm output {} differs from scorer replay".format(field))
    normalized = str(replayed.get("normalized_text", ""))
    if output.get("normalized_text_sha256") != hashlib.sha256(
        normalized.encode("utf-8")
    ).hexdigest():
        _fail("arm normalized text hash differs from scorer replay")


def _verify_execution_input(
    arm: Mapping[str, Any], fixture_hash: str, consumed_slot: Optional[Mapping[str, Any]]
) -> Tuple[Optional[str], Optional[str]]:
    execution = _mapping(arm.get("execution_input"), "arm.execution_input")
    payload = {key: value for key, value in execution.items() if key != "sha256"}
    if execution.get("sha256") != _canonical_sha(payload):
        _fail("arm execution input hash differs from its exact record")
    stno = arm.get("stno")
    expected = {
        "fixture_manifest_sha256": fixture_hash,
        "fixture_family": arm.get("fixture_family"),
        "window_id": arm.get("window_id"),
        "target_id": arm.get("target_id"),
        "reference_id": arm.get("reference_id"),
        "language": arm.get("language"),
        "audio_sha256": arm.get("audio_sha256"),
        "provider_assignment": arm.get("provider_assignment"),
        "stno_sha256": stno.get("sha256") if isinstance(stno, dict) else None,
        "repetition": arm.get("repetition"),
    }
    for field, value in expected.items():
        if execution.get(field) != value:
            _fail("arm execution input {} differs from the bound arm".format(field))
    prompt = execution.get("prompt_payload")
    if execution.get("prompt_sha256") != hashlib.sha256(str(prompt).encode("utf-8")).hexdigest():
        _fail("arm execution prompt hash differs from its exact payload")
    role = str(arm.get("evaluation_role"))
    if role == "prompt_off_control":
        if prompt != "":
            _fail("prompt-off execution contains a prompt payload")
    elif role in ("corrected_prompt_on", "warm_order_a_then_b", "warm_order_b_then_a"):
        if not isinstance(prompt, str) or not prompt:
            _fail("prompt-on execution omits its exact prompt payload")
    if role == "automatic_language_control":
        if execution.get("language_mode") != "automatic" or execution.get("forced_language") is not None:
            _fail("automatic-language execution contains an explicit language")
    elif role in ("shipped_comparator", "diagnostic"):
        if execution.get("language_mode") != "not_applicable" or execution.get("forced_language") is not None:
            _fail("shipped execution invents DiCoW language control")
    elif execution.get("language_mode") != "explicit" or execution.get("forced_language") != arm.get("language"):
        _fail("explicit-language execution is not bound to the arm language")
    if consumed_slot is not None:
        if (
            execution.get("provider_slot") != consumed_slot.get("slot")
            or execution.get("provider_label") != consumed_slot.get("provider_label")
        ):
            _fail("arm execution consumes the wrong frozen provider slot")
    if execution.get("execution_kind") == "virtual_absent":
        if any(execution.get(field) is not None for field in (
            "attempt_id", "process_id", "session_id", "provenance_id", "raw_stdout",
            "raw_stderr", "raw_output_sha256", "exit_status",
        )) or execution.get("argv") != []:
            _fail("virtual ABSENT execution invents process evidence")
        invocation_id = None
        process_id = None
    else:
        invocation_id = _string(execution.get("attempt_id"), "execution attempt_id")
        process_id = _string(execution.get("process_id"), "execution process_id")
    return invocation_id, process_id


def _verify_recomputed_metric(
    metric: Mapping[str, Any], chunks: Sequence[Sequence[Mapping[str, Any]]]
) -> None:
    criterion = str(metric.get("criterion_id"))
    values: List[float] = []
    if criterion == "S3.shipped_korean_overlap_penalty":
        values = [_numeric_output(chunk[1], "cer") - _numeric_output(chunk[0], "cer") for chunk in chunks]
    elif criterion == "S4.d_turbo_o":
        values = [_numeric_output(chunk[1], "cer") - _numeric_output(chunk[0], "cer") for chunk in chunks]
    elif criterion in ("S4.g_oracle_o", "S5.g_community1_o"):
        values = [
            (_numeric_output(chunk[1], "cer") - _numeric_output(chunk[0], "cer"))
            - (_numeric_output(chunk[3], "cer") - _numeric_output(chunk[2], "cer"))
            for chunk in chunks
        ]
    elif criterion in ("S4.p_oracle_n", "S4.p_community1_n"):
        values = [_numeric_output(chunk[1], "cer") - _numeric_output(chunk[0], "cer") for chunk in chunks]
    elif criterion == "S5.swap_margin":
        values = [_numeric_output(chunk[1], "cer") - _numeric_output(chunk[0], "cer") for chunk in chunks]
    elif criterion == "S5.half_oracle_margin":
        values = [
            (
                (_numeric_output(chunk[1], "cer") - _numeric_output(chunk[0], "cer"))
                - (_numeric_output(chunk[4], "cer") - _numeric_output(chunk[2], "cer"))
            )
            - 0.5 * (
                (_numeric_output(chunk[1], "cer") - _numeric_output(chunk[0], "cer"))
                - (_numeric_output(chunk[3], "cer") - _numeric_output(chunk[2], "cer"))
            )
            for chunk in chunks
        ]
    elif criterion == "S5.spurious_empty_proportion":
        values = [1.0 if chunk[0].get("output", {}).get("normalized_text_empty") is True else 0.0 for chunk in chunks]
    elif criterion == "S6.dicow_over_turbo_cer":
        mode_means: Dict[Tuple[int, str, str], List[float]] = {}
        for chunk in chunks:
            repetition = int(chunk[0].get("repetition"))
            for arm in chunk:
                mode_means.setdefault(
                    (repetition, str(arm.get("model")), str(arm.get("evaluation_role"))), []
                ).append(_numeric_output(arm, "cer"))
        repetition_values = []
        for repetition in (1, 2):
            turbo = min(
                sum(mode_means[(repetition, "turbo", role)]) / len(mode_means[(repetition, "turbo", role)])
                for role in ("automatic_language_control", "explicit_language_control")
            )
            dicow = min(
                sum(mode_means[(repetition, "dicow", role)]) / len(mode_means[(repetition, "dicow", role)])
                for role in ("automatic_language_control", "explicit_language_control")
            )
            repetition_values.append(dicow - turbo)
        values = repetition_values
    elif criterion in ("S7.prompt_recall_delta", "S7b.prompt_recall_delta"):
        values = [_numeric_output(chunk[1], "term_recall") - _numeric_output(chunk[0], "term_recall") for chunk in chunks]
    elif criterion == "S7.absent_term_insertions":
        values = [_numeric_output(chunk[0], "absent_term_insertions") for chunk in chunks]
    elif criterion == "S7b.cross_speaker_insertions":
        values = [_numeric_output(chunk[0], "cross_speaker_insertions") for chunk in chunks]
    elif criterion == "S8.warm_order_identity":
        values = [
            1.0 if chunk[0].get("output", {}).get("token_ids_sha256")
            == chunk[1].get("output", {}).get("token_ids_sha256") else 0.0
            for chunk in chunks
        ]
    elif criterion == "S9.dicow_cer_improvement":
        values = [_numeric_output(chunk[0], "cer") - _numeric_output(chunk[1], "cer") for chunk in chunks]
    elif criterion == "S9.cache_degradation":
        if metric.get("stratum") == "it":
            values = [
                _numeric_output(chunk[0], "cer") - _numeric_output(chunk[1], "cer")
                for chunk in chunks
            ]
        else:
            mode_means = {}
            shipped_by_repetition: Dict[int, List[float]] = {}
            for chunk in chunks:
                repetition = int(chunk[0].get("repetition"))
                shipped_by_repetition.setdefault(repetition, []).append(_numeric_output(chunk[0], "cer"))
                for arm in chunk[1:]:
                    mode_means.setdefault((repetition, str(arm.get("evaluation_role"))), []).append(
                        _numeric_output(arm, "cer")
                    )
            values = []
            for repetition in (1, 2):
                shipped = sum(shipped_by_repetition[repetition]) / len(shipped_by_repetition[repetition])
                dicow = min(
                    sum(mode_means[(repetition, role)]) / len(mode_means[(repetition, role)])
                    for role in ("automatic_language_control", "explicit_language_control")
                )
                values.append(shipped - dicow)
    else:
        return
    if not values:
        _fail("metric has no bound values for recomputation")
    window_clustered = criterion in {
        "S4.d_turbo_o", "S4.g_oracle_o", "S4.p_oracle_n", "S4.p_community1_n",
        "S5.swap_margin", "S5.g_community1_o", "S5.half_oracle_margin",
        "S7b.prompt_recall_delta",
    }
    if window_clustered:
        rows = _aggregate_window_rows(chunks, values)
        point_values = [row[4] for row in rows]
    else:
        rows = [
            (
                str(chunk[0].get("fixture_family")), str(chunk[0].get("language")),
                str(chunk[0].get("window_id")), int(chunk[0].get("repetition")), value,
            )
            for chunk, value in zip(chunks, values)
        ] if len(values) == len(chunks) else []
        point_values = values
    point = sum(point_values) / len(point_values)
    _assert_metric_value(metric.get("point"), point, "{} point".format(criterion))
    if criterion in {
        "S4.d_turbo_o", "S4.g_oracle_o", "S4.p_oracle_n", "S4.p_community1_n",
        "S5.swap_margin", "S5.g_community1_o", "S5.half_oracle_margin",
        "S7b.prompt_recall_delta",
    }:
        lower, upper_one_sided, upper = _bootstrap_interval(rows)
        interval = _mapping(metric.get("interval"), "recomputed metric interval")
        if criterion in ("S4.p_oracle_n", "S4.p_community1_n"):
            _assert_metric_value(interval.get("upper"), upper_one_sided, "{} interval.upper".format(criterion))
        else:
            _assert_metric_value(interval.get("lower"), lower, "{} interval.lower".format(criterion))
            _assert_metric_value(interval.get("upper"), upper, "{} interval.upper".format(criterion))
    if criterion in ("S4.g_oracle_o", "S5.swap_margin"):
        positive = sum(value > 0 for value in values) / len(values)
        _assert_metric_value(
            metric.get("target_proportion"), positive, "{} target_proportion".format(criterion)
        )
    for repetition in (1, 2):
        repetition_values = [
            value for chunk, value in zip(chunks, values)
            if int(chunk[0].get("repetition")) == repetition
        ] if len(values) == len(chunks) else [values[repetition - 1]]
        if not repetition_values:
            _fail("metric omits a frozen repetition")
        per_rep = dict(metric)
        per_rep["point"] = sum(repetition_values) / len(repetition_values)
        if criterion in {
            "S4.d_turbo_o", "S4.g_oracle_o", "S4.p_oracle_n", "S4.p_community1_n",
            "S5.swap_margin", "S5.g_community1_o", "S5.half_oracle_margin",
            "S7b.prompt_recall_delta",
        }:
            repetition_rows = [row for row in rows if row[3] == repetition]
            lower_rep, upper_one_sided_rep, upper_rep = _bootstrap_interval(repetition_rows)
            per_rep["interval"] = (
                {"kind": "one_sided_upper_95_percentile", "upper": upper_one_sided_rep}
                if criterion in ("S4.p_oracle_n", "S4.p_community1_n")
                else {
                    "kind": "two_sided_95_percentile",
                    "lower": lower_rep,
                    "upper": upper_rep,
                }
            )
        if criterion in ("S4.g_oracle_o", "S5.swap_margin"):
            per_rep["target_proportion"] = sum(value > 0 for value in repetition_values) / len(repetition_values)
        if _recompute_metric_passed(per_rep) is not True and criterion != "S3.shipped_korean_overlap_penalty":
            _fail("a required repetition independently fails {}".format(criterion))


def _verify_character_preservation(
    metric: Mapping[str, Any], citation_arms: Sequence[Mapping[str, Any]],
    expected_target_ids: set[str],
) -> None:
    criterion = str(metric.get("criterion_id"))
    roles = _J2_CAUSAL_ROLES[criterion]
    if len(citation_arms) % len(roles):
        _fail("character preservation citations do not form exact clean/mix pairs")
    rows: Dict[Tuple[str, str, str, int], List[int]] = {}
    seen_targets: set[Tuple[str, str, str, int, str]] = set()
    for offset in range(0, len(citation_arms), len(roles)):
        clean, mixed = citation_arms[offset:offset + len(roles)]
        coordinate = (
            str(clean.get("window_id")), str(clean.get("target_id")),
            str(clean.get("reference_id")), int(clean.get("repetition")),
            str(clean.get("fixture_family")),
        )
        if any(
            mixed.get(field) != clean.get(field)
            for field in ("window_id", "target_id", "reference_id", "repetition", "fixture_family")
        ):
            _fail("character preservation clean/mix arms do not share exact causal coordinates")
        if coordinate in seen_targets:
            _fail("character preservation repeats a target/repetition pair")
        seen_targets.add(coordinate)
        clean_counts = _mapping(clean.get("output", {}).get("stable_o_counts"), "clean stable-O counts")
        mixed_counts = _mapping(mixed.get("output", {}).get("stable_o_counts"), "mixed stable-O counts")
        if clean_counts.get("reference_chars") != mixed_counts.get("reference_chars"):
            _fail("character preservation clean/mix reference character counts differ")
        group = (
            str(clean.get("fixture_family")), str(clean.get("language")),
            str(clean.get("window_id")), int(clean.get("repetition")),
        )
        aggregate = rows.setdefault(group, [0, 0])
        aggregate[0] += int(mixed_counts.get("hits"))
        aggregate[1] += int(clean_counts.get("hits"))
    expected_target_repetitions = {
        (target_id, repetition) for target_id in expected_target_ids for repetition in (1, 2)
    }
    if {(coordinate[1], coordinate[3]) for coordinate in seen_targets} != expected_target_repetitions:
        _fail("character preservation citations do not cover the exact eligible target stratum")
    if not rows or sum(row[1] for row in rows.values()) <= 0:
        _fail("character preservation has a zero whole-stratum clean denominator")
    point = sum(row[0] for row in rows.values()) / sum(row[1] for row in rows.values())
    grouped: Dict[Tuple[str, str], List[Tuple[int, int]]] = {}
    for (fixture_family, language, _window, _repetition), row in sorted(rows.items()):
        grouped.setdefault((fixture_family, language), []).append((row[0], row[1]))
    rng = random.Random(20_260_830)
    replicates: List[float] = []
    for _ in range(10_000):
        numerator = 0
        denominator = 0
        for group_rows in grouped.values():
            for _sample in range(len(group_rows)):
                sampled = group_rows[rng.randrange(len(group_rows))]
                numerator += sampled[0]
                denominator += sampled[1]
        replicates.append(numerator / denominator if denominator else 0.0)
    lower = _nearest_rank(replicates, 0.025)
    upper = _nearest_rank(replicates, 0.975)
    interval = _mapping(metric.get("interval"), "character preservation interval")
    for field, recorded, computed in (
        ("point", metric.get("point"), point),
        ("interval.lower", interval.get("lower"), lower),
        ("interval.upper", interval.get("upper"), upper),
    ):
        if not isinstance(recorded, (int, float)) or isinstance(recorded, bool) or not math.isclose(
            float(recorded), computed, rel_tol=1e-12, abs_tol=1e-12
        ):
            _fail("character preservation {} differs from frozen pooled recomputation".format(field))
    if metric.get("cluster_count") != len(rows):
        _fail("character preservation cluster count differs from selected window rows")
    for repetition in (1, 2):
        selected_items = [(key, row) for key, row in rows.items() if key[3] == repetition]
        selected = [row for _key, row in selected_items]
        denominator = sum(row[1] for row in selected)
        ratio = sum(row[0] for row in selected) / denominator if denominator else 0.0
        repetition_groups: Dict[Tuple[str, str], List[List[int]]] = {}
        for key, row in selected_items:
            repetition_groups.setdefault((key[0], key[1]), []).append(row)
        repetition_rng = random.Random(20_260_830)
        repetition_replicates: List[float] = []
        for _ in range(10_000):
            numerator = 0
            sampled_denominator = 0
            for group_rows in repetition_groups.values():
                for _sample in range(len(group_rows)):
                    sampled = group_rows[repetition_rng.randrange(len(group_rows))]
                    numerator += sampled[0]
                    sampled_denominator += sampled[1]
            repetition_replicates.append(
                numerator / sampled_denominator if sampled_denominator else 0.0
            )
        repetition_lower = _nearest_rank(repetition_replicates, 0.025)
        if denominator <= 0 or ratio < 0.75 or repetition_lower < 0.75:
            _fail("a required repetition independently fails character preservation")


def verify_experiment_document(
    document: Mapping[str, Any], resolver: Optional[EvidenceResolver] = None,
    *, r2_candidate_context: Optional[Mapping[str, Any]] = None,
) -> None:
    """Verify schema plus cross-record constraints that JSON Schema cannot express."""
    _reject_nonfinite_numbers(document, "experiment")
    if document.get("schema_version") == "dicow-r2-experiment-envelope-v1":
        _validate_schema_definition(
            document, "dicow-experiment.schema.json", "r2_experiment_envelope"
        )
        verify_r2_experiment_envelope_document(document)
        return
    _validate_schema(document, "dicow-experiment.schema.json")
    provenance_index = _verify_execution_provenance(
        document, resolver, r2_candidate_context
    )
    _verify_community_pack(document, resolver)
    fixture = _mapping(document.get("fixture"), "experiment.fixture")
    if fixture.get("target_count") != 20 or set(fixture.get("strata", [])) != {"ko", "it", "en"}:
        _fail("experiment must preserve all 20 targets and ko/it/en strata")
    inventory = _list(fixture.get("inventory"), "fixture.inventory")
    if fixture.get("manifest_sha256") != _canonical_sha(inventory):
        _fail("fixture manifest hash differs from its exact embedded inventory")
    fixture_hash = _sha(fixture.get("manifest_sha256"), "fixture.manifest_sha256")
    inventory_index: Dict[str, Mapping[str, Any]] = {}
    for raw_item in inventory:
        item = _mapping(raw_item, "fixture.inventory[]")
        key = _string(item.get("arm_id"), "fixture inventory arm_id")
        if key in inventory_index:
            _fail("fixture inventory repeats an arm identity")
        inventory_index[key] = item
    bootstrap = _mapping(document.get("bootstrap"), "experiment.bootstrap")
    if (
        bootstrap.get("seed") != 20_260_830
        or bootstrap.get("resamples") != 10_000
        or bootstrap.get("cluster_unit") != "constructed_window"
        or set(bootstrap.get("stratify_by", [])) != {"fixture_family", "language"}
    ):
        _fail("experiment bootstrap contract differs from the frozen pins")

    utility = _mapping(document.get("utility_contract"), "experiment.utility_contract")
    utility_hash = _sha(utility.get("sha256"), "utility_contract.sha256")
    expected_pass_order = ["prompt_off_complete", "freeze_budget", "preflight_prompts", "prompt_on"]
    if utility.get("prompt_budget_pass_order") != expected_pass_order:
        _fail("prompt budget pass order differs from the frozen contract")
    community = _mapping(document.get("community1"), "experiment.community1")
    activity_hash = _sha(
        community.get("activity_provider_sha256"), "community1.activity_provider_sha256"
    )
    activity_providers = _mapping(
        document.get("activity_providers"), "experiment.activity_providers"
    )
    provider_keys = {"oracle", "community1", "community1_spurious", "clean_target"}
    if set(activity_providers) != provider_keys:
        _fail("experiment activity providers must be the exact frozen four-key set")
    provider_hashes = {
        key: _sha(activity_providers.get(key), "activity_providers.{}".format(key))
        for key in sorted(provider_keys)
    }
    if len(set(provider_hashes.values())) != len(provider_hashes):
        _fail("experiment activity provider hashes must be pairwise distinct")
    if provider_hashes["community1"] != activity_hash:
        _fail("Community evidence hash differs from the community1 activity provider")

    mappings = _list(document.get("mappings"), "experiment.mappings")
    if len(mappings) != 10:
        _fail("experiment requires ten constructed-window mappings")
    mapping_hash_by_window: Dict[str, str] = {}
    mapping_refs_by_window: Dict[str, set[str]] = {}
    mapping_slots_by_window: Dict[str, Dict[str, Mapping[str, Any]]] = {}
    surplus_by_window: Dict[str, set[str]] = {}
    spurious_by_window: Dict[str, str] = {}
    target_window: Dict[str, str] = {}
    expected_targets: set[str] = set()
    all_provider_labels: set[str] = set()
    all_surplus_labels: set[str] = set()
    for raw_mapping in mappings:
        mapping = _mapping(raw_mapping, "experiment.mappings[]")
        try:
            from benchmarks.scripts.scoring.speaker_attributed import validate_frozen_mapping
            validate_frozen_mapping(mapping)
        except Exception as exc:
            _fail("Community mapping cannot be replayed from immutable activity: {}".format(exc))
        window_id = _string(mapping.get("window_id"), "mapping.window_id")
        if window_id in mapping_hash_by_window:
            _fail("duplicate mapping window {}".format(window_id))
        mapping_hash_by_window[window_id] = _sha(
            mapping.get("mapping_sha256"), "mapping.mapping_sha256"
        )
        if mapping.get("transcript_conditioned") is not False:
            _fail("Community mapping may not be transcript-conditioned")
        slots = _list(mapping.get("slots"), "mapping.slots")
        if {slot.get("slot") for slot in slots if isinstance(slot, dict)} != {"A", "B"}:
            _fail("each mapping must preserve exactly target slots A and B")
        provider_labels: List[str] = []
        slots_by_reference: Dict[str, Mapping[str, Any]] = {}
        for raw_slot in slots:
            slot = _mapping(raw_slot, "mapping.slots[]")
            target_id = _string(slot.get("reference_id"), "mapping slot reference_id")
            if target_id in expected_targets:
                _fail("target {} appears in more than one mapping".format(target_id))
            expected_targets.add(target_id)
            target_window[target_id] = window_id
            slots_by_reference[target_id] = slot
            if slot.get("provider_kind") == "real_label":
                provider_labels.append(_string(slot.get("provider_label"), "provider_label"))
            elif slot.get("provider_kind") == "ABSENT":
                if slot.get("absent_id") != "ABSENT:{}".format(slot.get("slot")):
                    _fail("ABSENT sentinel does not match its target slot")
                if slot.get("asr_invoked") is not False or slot.get("terminal_reason") != "diarizer_target_absent":
                    _fail("ABSENT mapping is not typed and non-invoking")
            else:
                _fail("mapping provider kind is invalid")
        if len(provider_labels) != len(set(provider_labels)):
            _fail("one Community label may not map to duplicate target slots")
        surplus = _unique_strings(mapping.get("surplus_labels"), "mapping.surplus_labels")
        if set(provider_labels) & set(surplus):
            _fail("mapped Community labels may not also be surplus")
        if mapping.get("real_label_count") != len(provider_labels) + len(surplus):
            _fail("mapping real_label_count does not equal mapped plus surplus labels")
        spurious_target_id = _string(
            mapping.get("spurious_target_id"), "mapping.spurious_target_id"
        )
        refs = {
            _string(slot.get("reference_id"), "mapping slot reference_id")
            for slot in slots
        }
        if spurious_target_id in refs or spurious_target_id in provider_labels or spurious_target_id in surplus:
            _fail("spurious target collides with a reference, provider, or surplus label")
        mapping_refs_by_window[window_id] = refs
        mapping_slots_by_window[window_id] = slots_by_reference
        surplus_by_window[window_id] = set(surplus)
        spurious_by_window[window_id] = spurious_target_id
        all_provider_labels.update(provider_labels)
        all_surplus_labels.update(surplus)
    if len(expected_targets) != fixture.get("target_count"):
        _fail("mapping target count differs from fixture target_count")
    spurious_ids = list(spurious_by_window.values())
    if len(spurious_ids) != len(set(spurious_ids)):
        _fail("spurious target IDs must be unique across mapping windows")
    if set(spurious_ids) & (expected_targets | all_provider_labels | all_surplus_labels):
        _fail("spurious target collides with a sealed reference, provider, or surplus label")
    if all_surplus_labels & expected_targets:
        _fail("surplus diagnostic target may never be an ordinary mapping reference")

    arms = _list(document.get("arms"), "experiment.arms")
    arms_by_id: Dict[str, Mapping[str, Any]] = {}
    observed_targets: set[str] = set()
    languages: set[str] = set()
    language_by_target: Dict[str, str] = {}
    fixture_family_by_target: Dict[str, str] = {}
    surplus_diagnostics: List[Tuple[str, str]] = []
    spurious_diagnostics: List[Tuple[str, str, int]] = []
    ordinary_repetitions: Dict[Tuple[str, str, str, str, str, str, str], List[int]] = {}
    ordinary_availability: Dict[Tuple[str, str, str, str, str, str, str], List[str]] = {}
    surplus_availability: Dict[Tuple[str, str], List[str]] = {}
    spurious_availability: Dict[Tuple[str, str, int], List[str]] = {}
    diagnostic_language_by_window: Dict[str, str] = {}
    invocation_ids: set[str] = set()
    process_ids_by_repetition: Dict[int, set[str]] = {1: set(), 2: set()}
    execution_by_signature: Dict[Tuple[str, str, str, str, str, str, str], Dict[int, Tuple[str, str]]] = {}
    diagnostic_conditions = {"surplus-diagnostic", "dicow-full-spurious"}
    for raw_arm in arms:
        arm = _mapping(raw_arm, "experiment.arms[]")
        arm_id = _string(arm.get("arm_id"), "arm.arm_id")
        if arm_id in arms_by_id:
            _fail("duplicate arm ID {}".format(arm_id))
        arms_by_id[arm_id] = arm
        target_id = _string(arm.get("target_id"), "arm.target_id")
        condition = _string(arm.get("condition"), "arm.condition")
        repetition = arm.get("repetition")
        consumed_slot: Optional[Mapping[str, Any]] = None
        window_id = _string(arm.get("window_id"), "arm.window_id")
        if window_id not in mapping_hash_by_window:
            _fail("arm cites unknown mapping window {}".format(window_id))
        inventory_item = inventory_index.get(arm_id)
        if inventory_item is None:
            _fail("arm target/family is absent from the sealed fixture inventory")
        for field in (
            "window_id", "target_id", "reference_id", "fixture_family", "language", "audio_sha256",
        ):
            if inventory_item.get(field) != arm.get(field):
                _fail("arm {} differs from the sealed fixture inventory".format(field))
        if condition == "surplus-diagnostic":
            if target_id not in surplus_by_window[window_id]:
                _fail("surplus diagnostic target is not a surplus label in its mapping window")
            if target_id in mapping_refs_by_window[window_id]:
                _fail("surplus diagnostic target may not be an ordinary mapping reference")
            surplus_diagnostics.append((window_id, target_id))
            surplus_availability.setdefault((window_id, target_id), []).append(
                str(arm.get("availability", {}).get("status"))
            )
        elif condition == "dicow-full-spurious":
            if target_id != spurious_by_window[window_id]:
                _fail("spurious diagnostic target differs from its sealed mapping target")
            spurious_diagnostics.append((window_id, target_id, repetition))
            spurious_availability.setdefault((window_id, target_id, repetition), []).append(
                str(arm.get("availability", {}).get("status"))
            )
            language = _string(arm.get("language"), "spurious diagnostic language")
            prior_language = diagnostic_language_by_window.setdefault(window_id, language)
            if prior_language != language:
                _fail("spurious diagnostic changes language across repetitions")
        else:
            source_control = condition == "dicow-fleurs-ko-clean"
            if source_control:
                if (
                    arm.get("fixture_family") != "fleurs-ko-clean-v1"
                    or arm.get("reference_id") != target_id
                    or target_id in expected_targets
                ):
                    _fail("FLEURS clean source control must preserve its sealed target/reference identity")
            elif target_id not in mapping_refs_by_window[window_id] or target_window.get(target_id) != window_id:
                _fail("arm target ID is bound to the wrong mapping window")
            if arm.get("reference_id") != target_id:
                _fail("ordinary arm reference ID must equal its frozen target reference")
            if not source_control:
                observed_targets.add(target_id)
            language = _string(arm.get("language"), "arm.language")
            languages.add(language)
            if not source_control:
                prior_language = language_by_target.setdefault(target_id, language)
                if prior_language != language:
                    _fail("ordinary target changes language across its required arms")
                if (
                    condition == "dicow-mix-O-community1"
                    and arm.get("provider_assignment") == "correct"
                    and arm.get("evaluation_role") == "corrected_prompt_on"
                ):
                    fixture_family_by_target[target_id] = _string(
                        arm.get("fixture_family"), "ordinary target fixture family"
                    )
            assignment = _string(arm.get("provider_assignment"), "arm.provider_assignment")
            ordinary_signature = (
                window_id, target_id, str(arm.get("model")), condition,
                str(arm.get("arm_kind")), assignment, str(arm.get("evaluation_role")),
            )
            ordinary_repetitions.setdefault(ordinary_signature, []).append(repetition)
            ordinary_availability.setdefault(ordinary_signature, []).append(
                str(arm.get("availability", {}).get("status"))
            )
            if condition in ("dicow-mix-O-community1", "dicow-full-mix-community1"):
                target_slot = mapping_slots_by_window[window_id][target_id]
                consumed_slot = target_slot
                if assignment == "swapped":
                    opposite = "B" if target_slot.get("slot") == "A" else "A"
                    consumed_slot = next(
                        slot for slot in mapping_slots_by_window[window_id].values()
                        if slot.get("slot") == opposite
                    )
                if (
                    consumed_slot.get("provider_kind") == "ABSENT"
                    and arm.get("availability", {}).get("status") != "available"
                ):
                    _fail("ordinary ABSENT mapping slot must retain its virtual numeric row")
        if arm.get("mapping_sha256") != mapping_hash_by_window[window_id]:
            _fail("arm mapping hash differs from its frozen mapping")
        if arm.get("utility_contract_sha256") != utility_hash:
            _fail("arm utility-contract hash differs from the shared contract")
        invocation_id, process_id = _verify_execution_input(arm, fixture_hash, consumed_slot)
        _verify_arm_raw_execution(
            arm,
            _mapping(arm.get("execution_input"), "arm execution_input"),
            provenance_index,
            resolver,
        )
        is_virtual_absent = (
            consumed_slot is not None and consumed_slot.get("provider_kind") == "ABSENT"
        )
        execution_kind = arm.get("execution_input", {}).get("execution_kind")
        if is_virtual_absent != (execution_kind == "virtual_absent"):
            _fail("arm execution kind differs from its frozen ABSENT/non-ABSENT slot")
        if invocation_id is not None:
            if invocation_id in invocation_ids:
                _fail("arm execution attempt ID is reused")
            invocation_ids.add(invocation_id)
        if process_id is not None:
            if process_id in process_ids_by_repetition[int(repetition)]:
                _fail("arm execution process ID is reused within a repetition")
            process_ids_by_repetition[int(repetition)].add(process_id)
        if condition not in diagnostic_conditions and not is_virtual_absent:
            execution_by_signature.setdefault(ordinary_signature, {})[int(repetition)] = (
                invocation_id, process_id
            )
        model = arm.get("model")
        activity_provider_hash = arm.get("activity_provider_sha256")
        stno = arm.get("stno")
        if model in ("turbo", "shipped"):
            if activity_provider_hash is not None or stno is not None:
                _fail("turbo and shipped arms must not carry an activity provider or STNO")
        elif model == "dicow" and arm.get("availability", {}).get("status") == "available":
            if activity_provider_hash is None or stno is None:
                _fail("available DiCoW arm must carry an activity provider and STNO")
        provider_binding = {
            "dicow-clean-O": ("clean_target", "clean_target"),
            "dicow-clean-single-utility": ("clean_target", "clean_target"),
            "dicow-mix-O-oracle": ("oracle", "oracle"),
            "dicow-full-mix-oracle": ("oracle", "oracle"),
            "dicow-mix-O-community1": ("community1", "community1"),
            "dicow-full-mix-community1": ("community1", "community1"),
            "surplus-diagnostic": ("community1", "community1"),
            "dicow-full-spurious": ("community1_spurious", "community1+spurious"),
            "dicow-hike-single": ("clean_target", "clean_target"),
            "dicow-fleurs-ko-clean": ("clean_target", "clean_target"),
        }.get(condition)
        if provider_binding is not None:
            provider_key, stno_provider = provider_binding
            if activity_provider_hash != provider_hashes[provider_key]:
                _fail("arm activity-provider hash differs from its semantic provider")
            if not isinstance(stno, dict) or stno.get("provider") != stno_provider:
                _fail("arm STNO provider differs from its semantic provider")
        token_bounds = _mapping(arm.get("token_bounds"), "arm.token_bounds")
        init_tokens = token_bounds.get("init_tokens")
        output_cap = token_bounds.get("effective_output_cap")
        generated_tokens = token_bounds.get("generated_tokens")
        prompt_budget = token_bounds.get("prompt_budget")
        prompt_budget_status = token_bounds.get("prompt_budget_status")
        prompt_token_count = token_bounds.get("prompt_token_count")
        prompt_off_generated_p99 = token_bounds.get("prompt_off_generated_p99")
        decoder_context = token_bounds.get("decoder_context")
        if init_tokens + output_cap + 1 > decoder_context:
            _fail("arm token bounds exceed decoder context")
        if generated_tokens is not None and generated_tokens > output_cap:
            _fail("generated token count exceeds the effective output cap")
        if prompt_budget_status == "frozen":
            if not all(
                isinstance(value, int) and not isinstance(value, bool)
                for value in (prompt_budget, prompt_token_count, prompt_off_generated_p99)
            ):
                _fail("frozen prompt budget requires integer budget, prompt count, and prompt-off p99")
            reserved_generated = (3 * prompt_off_generated_p99 + 1) // 2
            expected_prompt_budget = decoder_context - init_tokens - reserved_generated - 1
            if prompt_budget != expected_prompt_budget:
                _fail("prompt budget differs from the frozen 448-init-ceil(1.5*p99)-1 formula")
            if prompt_token_count > prompt_budget:
                _fail("frozen prompt token count exceeds the prompt budget")
            if (
                generated_tokens is not None
                and init_tokens + prompt_token_count + generated_tokens + 1 > decoder_context
            ):
                _fail("actual prompt and generation occupancy exceeds decoder context")
        elif prompt_budget_status == "not_applicable":
            if any(value is not None for value in (
                prompt_budget, prompt_token_count, prompt_off_generated_p99
            )):
                _fail("not-applicable prompt budget must carry null numeric fields")
        else:
            _fail("arm prompt budget status is invalid")
        if output_cap != utility.get("effective_token_cap"):
            _fail("arm output cap differs from the shared utility contract")
        kind = arm.get("arm_kind")
        geometry = arm.get("geometry")
        if kind == "crop":
            geometry_record = _mapping(geometry, "crop arm geometry")
            if model == "dicow":
                stno_record = _mapping(stno, "crop DiCoW arm STNO")
                if stno_record.get("kind") != "crop":
                    _fail("crop DiCoW arm must consume a crop STNO")
            if geometry_record.get("audio_crop_sha256") != arm.get("audio_sha256"):
                _fail("crop arm audio hash differs from frozen crop geometry")
            if geometry_record.get("zero_outside_k") is not True or geometry_record.get("outside_k_class") != "silence":
                _fail("crop arm contains a non-silence frame outside K")
        else:
            if geometry is not None:
                _fail("full-window or single arm may not carry crop geometry")
            if stno is not None and _mapping(stno, "full arm STNO").get("kind") != "full_window":
                _fail("full-window or single arm may not consume crop STNO")
        if arm.get("condition") == "dicow-clean-O":
            if _mapping(stno, "clean arm STNO").get("non_target_or_overlap_frames") != 0:
                _fail("clean DiCoW arm contains non-target or overlap activity")
        if condition in diagnostic_conditions and kind != "full_window":
            _fail("diagnostic arm must be a full-window arm")
        if arm.get("availability", {}).get("status") == "available":
            termination = _mapping(arm.get("termination"), "available arm termination")
            if termination.get("typed") is not True or termination.get("complete") is not True:
                _fail("available arm termination is not typed and complete")
            output = _mapping(arm.get("output"), "available arm output")
            virtual_absent = (
                consumed_slot is not None and consumed_slot.get("provider_kind") == "ABSENT"
            )
            if not virtual_absent:
                _verify_scorer_evidence(arm, inventory_index[arm_id])
            if condition in diagnostic_conditions:
                if any(output.get(field) is not None for field in ("cer", "wer", "term_recall")):
                    _fail("diagnostic empty-reference output may not coerce rates to numeric values")
            else:
                for field in ("cer", "wer", "term_recall"):
                    value = output.get(field)
                    if not isinstance(value, (int, float)) or isinstance(value, bool):
                        _fail("ordinary available arm requires numeric {}".format(field))
                counts = _mapping(output.get("stable_o_counts"), "ordinary stable-O counts")
                _sha(
                    counts.get("regional_edit_path_sha256"),
                    "ordinary stable-O regional edit path",
                )
                if counts.get("hits") != (
                    counts.get("reference_chars") - counts.get("substitutions") - counts.get("deletions")
                ):
                    _fail("stable-O hits must equal reference characters minus substitutions and deletions")
            for field in ("character_insertions", "word_insertions", "absent_term_insertions"):
                value = output.get(field)
                if not isinstance(value, int) or isinstance(value, bool) or value < 0:
                    _fail("arm output {} must be a non-negative integer".format(field))
            if consumed_slot is not None and consumed_slot.get("provider_kind") == "ABSENT":
                expected_absent = "ABSENT:{}".format(consumed_slot.get("slot"))
                if (
                    consumed_slot.get("absent_id") != expected_absent
                    or consumed_slot.get("asr_invoked") is not False
                ):
                    _fail("ordinary ABSENT arm is not bound to its exact non-invoking mapping slot")
                termination = _mapping(arm.get("termination"), "ordinary ABSENT termination")
                if (
                    token_bounds.get("generated_tokens") != 0
                    or output.get("normalized_text_empty") is not True
                    or output.get("cer") != 1
                    or output.get("wer") != 1
                    or output.get("term_recall") != 0
                    or any(output.get(field) != 0 for field in (
                        "character_insertions", "word_insertions", "absent_term_insertions"
                    ))
                    or termination.get("terminal_reason") != "diarizer_target_absent"
                    or termination.get("complete") is not True
                    or termination.get("typed") is not True
                ):
                    _fail("ordinary ABSENT arm invented ASR output instead of the sealed virtual result")
    if observed_targets != expected_targets:
        missing = sorted(expected_targets - observed_targets)
        _fail("experiment dropped target arms: {}".format(", ".join(missing)))
    if process_ids_by_repetition[1] & process_ids_by_repetition[2]:
        _fail("reference repetitions reuse an execution process")
    for signature, executions in execution_by_signature.items():
        if set(executions) != {1, 2}:
            _fail("ordinary execution identity omits a repetition: {}".format(signature))
        if executions[1][0] == executions[2][0] or executions[1][1] == executions[2][1]:
            _fail("ordinary repetitions are not independent executions")
    if languages != {"ko", "it", "en"}:
        _fail("experiment dropped a required language stratum")
    reference_repetitions = document.get("thresholds", {}).get("phase_a", {}).get("S0", {}).get("reference_repetitions")
    if reference_repetitions != 2:
        _fail("diagnostic coverage requires the frozen two reference repetitions")
    required_repetitions = range(1, reference_repetitions + 1)
    required_repetition_set = set(required_repetitions)
    for signature, repetitions in ordinary_repetitions.items():
        if len(repetitions) != len(set(repetitions)) or set(repetitions) != required_repetition_set:
            _fail("ordinary arm matrix is not complete for both frozen repetitions: {}".format(signature))
    if document.get("task") == "T14" and document.get("evidence_id") == "E4":
        core_roles = (
            ("turbo", "turbo-clean-O", "crop", "not_applicable", "corrected_prompt_on"),
            ("turbo", "turbo-mix-O", "crop", "not_applicable", "corrected_prompt_on"),
            ("dicow", "dicow-clean-O", "crop", "not_applicable", "corrected_prompt_on"),
            ("dicow", "dicow-mix-O-oracle", "crop", "correct", "corrected_prompt_on"),
            ("dicow", "dicow-mix-O-oracle", "crop", "swapped", "corrected_prompt_on"),
            ("dicow", "dicow-mix-O-community1", "crop", "correct", "corrected_prompt_on"),
            ("dicow", "dicow-mix-O-community1", "crop", "swapped", "corrected_prompt_on"),
            ("dicow", "dicow-clean-single-utility", "full_window", "not_applicable", "corrected_prompt_on"),
            ("dicow", "dicow-full-mix-oracle", "full_window", "correct", "corrected_prompt_on"),
            ("dicow", "dicow-full-mix-community1", "full_window", "correct", "corrected_prompt_on"),
        )
        expected_core = {
            (window_id, target_id, model, condition, kind, assignment, evaluation_role)
            for window_id, references in mapping_refs_by_window.items()
            for target_id in references
            for model, condition, kind, assignment, evaluation_role in core_roles
        }
        missing_core = expected_core - set(ordinary_repetitions)
        if missing_core:
            _fail("complete E4 ordinary matrix is missing required condition cells: {}".format(
                sorted(missing_core)
            ))
        if document.get("availability", {}).get("status") == "available":
            unavailable_core = [
                signature for signature in expected_core
                if ordinary_availability.get(signature) != ["available", "available"]
            ]
            if unavailable_core:
                _fail("gate-ready E4 matrix contains unavailable required ordinary cells")
    expected_spurious = {
        (window_id, spurious_by_window[window_id], repetition)
        for window_id in mapping_hash_by_window
        for repetition in required_repetitions
    }
    expected_surplus = {
        (window_id, surplus)
        for window_id in mapping_hash_by_window
        for surplus in surplus_by_window[window_id]
    }
    if len(spurious_diagnostics) != len(set(spurious_diagnostics)):
        _fail("duplicate spurious diagnostic arm for a window and repetition")
    if len(surplus_diagnostics) != len(set(surplus_diagnostics)):
        _fail("duplicate surplus diagnostic arm for a sealed label")
    if set(spurious_diagnostics) != expected_spurious:
        _fail("spurious diagnostics do not cover exactly every required window and repetition")
    if set(surplus_diagnostics) != expected_surplus:
        _fail("surplus diagnostics do not cover exactly every sealed surplus label once")
    if document.get("availability", {}).get("status") == "available":
        if any(spurious_availability.get(key) != ["available"] for key in expected_spurious):
            _fail("gate-ready experiment contains unavailable required spurious diagnostics")
        if any(surplus_availability.get(key) != ["available"] for key in expected_surplus):
            _fail("gate-ready experiment contains unavailable required surplus diagnostics")

    correction = document.get("correction_burden")
    if correction is not None:
        burden = _mapping(correction, "experiment.correction_burden")
        available = burden.get("availability", {}).get("status") == "available"
        ratio = burden.get("ratio")
        percentage = burden.get("percentage")
        if available:
            overlap = burden.get("overlap_caused_seconds")
            total = burden.get("total_seconds")
            if not all(isinstance(value, (int, float)) and not isinstance(value, bool) for value in (overlap, total, ratio, percentage)):
                _fail("available correction burden requires numeric overlap, total, ratio, and percentage")
            if total <= 0 or not 0 <= ratio <= 1 or not 0 <= percentage <= 100:
                _fail("available correction burden values are outside the frozen bounds")
            if not math.isclose(ratio, overlap / total, rel_tol=1e-12, abs_tol=1e-12):
                _fail("correction burden ratio differs from overlap divided by total")
            if not math.isclose(percentage, 100 * ratio, rel_tol=1e-12, abs_tol=1e-12):
                _fail("correction burden percentage differs from 100 times the ratio")
        elif ratio is not None or percentage is not None:
            _fail("unavailable correction burden must carry null ratio and percentage")

    metrics = _list(document.get("metrics"), "experiment.metrics")
    if document.get("availability", {}).get("status") == "available" and not metrics:
        _fail("available experiment must contain gate metrics")
    if metrics and {metric.get("stratum") for metric in metrics if isinstance(metric, dict)} != {
        "overall", "ko", "it", "en"
    }:
        _fail("available metric set must preserve overall and ko/it/en strata")
    metric_ids: set[str] = set()
    metric_signatures: set[Tuple[Any, Any, Any, Any]] = set()
    allowed_metric_signatures = _required_metric_matrix("J2") | _required_metric_matrix("J3")
    for raw_metric in metrics:
        metric = _mapping(raw_metric, "experiment.metrics[]")
        metric_id = _string(metric.get("metric_id"), "metric.metric_id")
        if metric_id in metric_ids:
            _fail("duplicate metric ID {}".format(metric_id))
        metric_ids.add(metric_id)
        if metric.get("utility_contract_sha256") != utility_hash:
            _fail("metric utility-contract hash differs from the shared contract")
        signature = (
            metric.get("criterion_id"), metric.get("gate"), metric.get("estimand"),
            metric.get("stratum"),
        )
        if signature in metric_signatures:
            _fail("duplicate experiment metric criterion cell {}".format(signature))
        metric_signatures.add(signature)
        if signature not in allowed_metric_signatures:
            _fail("experiment metric criterion/gate/estimand/stratum binding is invalid")
        availability = _mapping(metric.get("availability"), "metric.availability")
        if availability.get("status") == "available" and metric.get("point") is None:
            _fail("available gate metric may not have a null point")
        citation_roles: List[Tuple[str, str, str, str, str]] = []
        citation_coordinates: List[Tuple[str, str, Any, int, str]] = []
        citation_arms: List[Mapping[str, Any]] = []
        cited_arm_ids: set[str] = set()
        for raw_citation in _list(metric.get("arm_citations"), "metric.arm_citations"):
            citation = _mapping(raw_citation, "metric.arm_citations[]")
            arm_id = _string(citation.get("arm_id"), "arm citation ID")
            if arm_id not in arms_by_id:
                _fail("metric cites an unknown arm {}".format(arm_id))
            if arm_id in cited_arm_ids:
                _fail("metric repeats the same arm citation {}".format(arm_id))
            cited_arm_ids.add(arm_id)
            arm = arms_by_id[arm_id]
            citation_arms.append(arm)
            if availability.get("status") == "available" and (
                arm.get("availability", {}).get("status") != "available"
                or not isinstance(arm.get("output"), dict)
                or not isinstance(arm.get("termination"), dict)
                or arm.get("termination", {}).get("typed") is not True
                or arm.get("termination", {}).get("complete") is not True
            ):
                _fail("available metric cites an unavailable or incomplete arm")
            if citation.get("arm_kind") != arm.get("arm_kind"):
                _fail("metric citation arm kind differs from the cited arm")
            citation_roles.append((
                str(arm.get("model")), str(arm.get("condition")),
                str(arm.get("evaluation_role")), str(arm.get("provider_assignment")),
                str(arm.get("arm_kind")),
            ))
            citation_coordinates.append((
                str(arm.get("window_id")), str(arm.get("target_id")),
                arm.get("reference_id"), arm.get("repetition"),
                str(arm.get("fixture_family")),
            ))
            if metric.get("stratum") in ("ko", "it", "en") and arm.get("language") != metric.get("stratum"):
                _fail("metric cites an arm outside its declared language stratum")
            if arm.get("condition") in diagnostic_conditions:
                if not (
                    metric.get("criterion_id") == "S5.spurious_empty_proportion"
                    and arm.get("condition") == "dicow-full-spurious"
                ):
                    _fail("diagnostic empty-reference output is gate-ineligible")
            expected = {
                "fixture_family": arm.get("fixture_family"),
                "window_id": arm.get("window_id"),
                "target_id": arm.get("target_id"),
                "reference_id": arm.get("reference_id"),
                "repetition": arm.get("repetition"),
                "model": arm.get("model"),
                "condition": arm.get("condition"),
                "evaluation_role": arm.get("evaluation_role"),
                "provider_assignment": arm.get("provider_assignment"),
                "audio_sha256": arm.get("audio_sha256"),
                "activity_provider_sha256": arm.get("activity_provider_sha256"),
                "stno_sha256": arm.get("stno", {}).get("sha256") if isinstance(arm.get("stno"), dict) else None,
                "k_sha256": arm.get("geometry", {}).get("k_sha256") if isinstance(arm.get("geometry"), dict) else None,
                "k_frames_sha256": arm.get("geometry", {}).get("k_frames_sha256") if isinstance(arm.get("geometry"), dict) else None,
                "regional_edit_path_sha256": (
                    arm.get("output", {}).get("stable_o_counts", {}).get("regional_edit_path_sha256")
                    if isinstance(arm.get("output"), dict)
                    and isinstance(arm.get("output", {}).get("stable_o_counts"), dict)
                    else None
                ),
            }
            for field, expected_value in expected.items():
                if citation.get(field) != expected_value:
                    _fail("metric citation {} differs from cited arm".format(field))
        criterion_id = str(metric.get("criterion_id"))
        exact_roles = _J2_STRATUM_CAUSAL_ROLES.get(
            (criterion_id, str(metric.get("stratum"))), _J2_CAUSAL_ROLES.get(criterion_id)
        )
        if exact_roles is not None:
            role_count = len(exact_roles)
            if not citation_roles or len(citation_roles) % role_count:
                _fail("metric citations do not preserve exact causal role multiplicity")
            seen_coordinates: set[Tuple[str, str, Any, int, str]] = set()
            causal_chunks: List[Sequence[Mapping[str, Any]]] = []
            for offset in range(0, len(citation_roles), role_count):
                role_chunk = tuple(citation_roles[offset:offset + role_count])
                coordinate_chunk = citation_coordinates[offset:offset + role_count]
                arm_chunk = citation_arms[offset:offset + role_count]
                if role_chunk != exact_roles:
                    _fail("metric citations do not match the exact ordered causal arm-role matrix")
                if criterion_id == "S3.shipped_korean_overlap_penalty":
                    if (
                        len({coordinate[:4] for coordinate in coordinate_chunk}) != 1
                        or tuple(coordinate[4] for coordinate in coordinate_chunk)
                        != ("hike-single-v1", "hike-pair-v1")
                    ):
                        _fail("S3 citations do not preserve the exact single/mix fixture pairing")
                    coordinate = coordinate_chunk[0]
                elif len(set(coordinate_chunk)) != 1:
                    _fail("metric causal arms cross target, window, reference, repetition, or fixture coordinates")
                else:
                    coordinate = coordinate_chunk[0]
                if coordinate in seen_coordinates:
                    _fail("metric repeats a causal coordinate group")
                seen_coordinates.add(coordinate)
                causal_chunks.append(arm_chunk)
                if availability.get("status") == "available" and criterion_id != "S5.spurious_empty_proportion":
                    reference_counts = {
                        _mapping(arm.get("output", {}).get("stable_o_counts"), "cited stable-O counts").get(
                            "reference_chars"
                        )
                        for arm in arm_chunk
                    }
                    if len(reference_counts) != 1:
                        _fail("paired causal arms do not share stable-O reference characters")
            stratum = str(metric.get("stratum"))
            if criterion_id == "S5.spurious_empty_proportion":
                expected_coordinates = {
                    (
                        window_id, spurious_by_window[window_id], None, repetition,
                        next(
                            str(arm.get("fixture_family")) for arm in arms_by_id.values()
                            if arm.get("condition") == "dicow-full-spurious"
                            and arm.get("window_id") == window_id
                        ),
                    )
                    for window_id in mapping_hash_by_window
                    if stratum == "overall" or diagnostic_language_by_window.get(window_id) == stratum
                    for repetition in required_repetitions
                }
                if seen_coordinates != expected_coordinates:
                    _fail("spurious purity citations do not cover every sealed window and repetition")
            elif criterion_id == "S7.absent_term_insertions":
                source_coordinates = {
                    (
                        str(arm.get("window_id")), str(arm.get("target_id")),
                        arm.get("reference_id"), arm.get("repetition"),
                        str(arm.get("fixture_family")),
                    )
                    for arm in arms_by_id.values()
                    if arm.get("condition") == "dicow-fleurs-ko-clean"
                }
                if seen_coordinates != source_coordinates:
                    _fail("clean absent-term citations do not cover the sealed FLEURS source controls")
            else:
                eligible_role_targets = {
                    target_id for target_id in expected_targets
                    if stratum == "overall" or language_by_target.get(target_id) == stratum
                }
                if criterion_id in (
                    "S6.dicow_over_turbo_cer", "S7.prompt_recall_delta",
                    "S9.cache_degradation",
                ):
                    expected_families = {
                        target_id: (
                            "fleurs-it-single-v1"
                            if criterion_id == "S9.cache_degradation" and stratum == "it"
                            else "hike-single-v1"
                        )
                        for target_id in eligible_role_targets
                    }
                elif criterion_id.startswith("S7b."):
                    expected_families = {target_id: "hike-pair-v1" for target_id in eligible_role_targets}
                else:
                    expected_families = {
                        target_id: fixture_family_by_target[target_id]
                        for target_id in eligible_role_targets
                    }
                if criterion_id == "S3.shipped_korean_overlap_penalty":
                    observed = {coordinate[:4] for coordinate in seen_coordinates}
                    expected = {
                        (target_window[target_id], target_id, target_id, repetition)
                        for target_id in eligible_role_targets
                        for repetition in required_repetitions
                    }
                else:
                    observed = seen_coordinates
                    expected = {
                        (
                            target_window[target_id], target_id, target_id, repetition,
                            expected_families[target_id],
                        )
                        for target_id in eligible_role_targets
                        for repetition in required_repetitions
                    }
                if observed != expected:
                    _fail("metric causal citations do not cover the exact eligible target stratum")
            if criterion_id in (
                "S4.target_character_preservation_oracle",
                "S5.target_character_preservation_community1",
            ) and availability.get("status") == "available":
                stratum = str(metric.get("stratum"))
                eligible_targets = {
                    target_id for target_id in expected_targets
                    if stratum == "overall" or language_by_target.get(target_id) == stratum
                }
                _verify_character_preservation(metric, citation_arms, eligible_targets)
            if availability.get("status") == "available" and criterion_id not in (
                "S4.target_character_preservation_oracle",
                "S5.target_character_preservation_community1",
            ):
                _verify_recomputed_metric(metric, causal_chunks)
        elif criterion_id == "S0.repeat_identity":
            if not citation_roles or len(citation_roles) % 2:
                _fail("S0 repeat identity requires exact repetition pairs")
            seen_repeat_coordinates: set[Tuple[str, str, Any, str]] = set()
            for offset in range(0, len(citation_roles), 2):
                roles = citation_roles[offset:offset + 2]
                coordinates = citation_coordinates[offset:offset + 2]
                if roles[0] != roles[1] or coordinates[0][:3] != coordinates[1][:3] or (
                    coordinates[0][3], coordinates[1][3]
                ) != (1, 2) or coordinates[0][4] != coordinates[1][4]:
                    _fail("S0 citations must pair the same causal arm across repetitions 1 and 2")
                repeat_coordinate = (*coordinates[0][:3], coordinates[0][4])
                if repeat_coordinate in seen_repeat_coordinates:
                    _fail("S0 repeats a target repeat-identity pair")
                seen_repeat_coordinates.add(repeat_coordinate)
            if {coordinate[1] for coordinate in seen_repeat_coordinates} != expected_targets:
                _fail("S0 repeat identity does not cover every frozen target")
            repeat_equal = all(
                citation_arms[offset].get("output", {}).get("token_ids_sha256")
                == citation_arms[offset + 1].get("output", {}).get("token_ids_sha256")
                for offset in range(0, len(citation_arms), 2)
            )
            _assert_metric_value(
                metric.get("point"), 1.0 if repeat_equal else 0.0, "S0.repeat_identity point"
            )


def verify_experiment_path(experiment_path: Path) -> Mapping[str, Any]:
    """Verify an experiment and every run/repository evidence artifact it cites."""

    experiment_path = experiment_path.absolute()
    if experiment_path.is_symlink() or not experiment_path.is_file():
        _fail("experiment is missing, not regular, or a symlink: {}".format(experiment_path))
    run_root = _find_run_root(experiment_path.parent)
    repo_root = Path(__file__).resolve().parents[4]
    document = _load_json(experiment_path)
    verify_experiment_document(
        document, _filesystem_evidence_resolver(run_root, repo_root)
    )
    if document.get("schema_version") == "dicow-r2-experiment-envelope-v1":
        basis = _mapping(document.get("execution_basis"), "r2 execution basis")
        basis_states = {}
        for task in ("R3", "R5", "R6"):
            basis_states[task], state_path = verify_r2_task_state(task, run_root)
            _verify_file(state_path, basis.get(task))
        source = _mapping(document.get("candidate_source"), "r2 candidate source")
        source_path = _contained_path(
            run_root,
            source.get("source_artifact_path"),
            "r2 candidate source artifact",
            run_root,
        )
        _verify_file(
            source_path, source.get("source_artifact_sha256"),
            source.get("source_artifact_bytes"),
        )
        source_document = _load_immutable_json(source_path, "R3 candidate source artifact")
        if set(source_document) != {"schema_version", "models"} or (
            source_document.get("schema_version") != source.get("source_artifact_format")
        ):
            _fail("R3 candidate source artifact has the wrong named format or identity")
        r3_artifacts = _mapping(basis_states["R3"].get("artifacts"), "R3 artifacts")
        expected_source_record = {
            "path": source.get("source_artifact_path"),
            "sha256": source.get("source_artifact_sha256"),
            "bytes": source.get("source_artifact_bytes"),
        }
        if r3_artifacts.get(source.get("source_artifact_id")) != expected_source_record:
            _fail("R3 state does not seal the named candidate source artifact")
        source_candidates = _list(source_document.get("models"), "R3 source models")
        matches = [
            _mapping(item, "R3 source candidate") for item in source_candidates
            if isinstance(item, dict) and item.get("candidate") == document.get("candidate_id")
        ]
        if len(matches) != 1 or (
            matches[0].get("model_id") != source.get("model_id")
            or matches[0].get("revision") != source.get("revision")
            or matches[0].get("model_file_lfs_sha256") != source.get("weights_sha256")
            or matches[0].get("model_file_bytes") != source.get("weights_bytes")
        ):
            _fail("R3 candidate source artifact does not contain the exact candidate tuple")
        evidence = _mapping(document.get("evidence"), "r2 evidence")
        evidence_path = _contained_path(
            run_root, evidence.get("path"), "r2 evidence path", run_root
        )
        _verify_file(evidence_path, evidence.get("sha256"), evidence.get("bytes"))
        evidence_document = _load_json(evidence_path)
        if evidence_document.get("schema_version") != evidence.get("format"):
            _fail("r2 evidence format differs from the referenced experiment")
        verify_experiment_document(
            evidence_document, _filesystem_evidence_resolver(run_root, repo_root),
            r2_candidate_context={
                "model_role": evidence.get("candidate_model"),
                "model_id": source.get("model_id"),
                "revision": source.get("revision"),
                "model_asset_sha256": source.get("weights_sha256"),
                "model_asset_bytes": source.get("weights_bytes"),
            },
        )
        if (
            evidence_document.get("run_id") != document.get("run_id")
            or evidence_document.get("evidence_id") != evidence.get("evidence_id")
        ):
            _fail("r2 evidence run/evidence identity differs from its envelope")
        candidate_model = evidence.get("candidate_model")
        arms = _list(evidence_document.get("arms"), "r2 referenced evidence arms")
        if not any(
            isinstance(arm, dict) and arm.get("model") == candidate_model for arm in arms
        ):
            _fail("r2 evidence does not contain its exactly linked candidate model")
    return document


def _effective_r2_state_path(task: str, run_root: Path) -> Path:
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


def _verify_r2_r0_state(
    state: Mapping[str, Any], state_path: Path, run_root: Path,
    manifest_doc: Mapping[str, Any], manifest_path: Path,
) -> None:
    if (
        state.get("schema_version") != "dicow-r2-task-state-v1"
        or state.get("task") != "R0"
        or state.get("state") != "done"
        or state.get("branch_disposition") != "executed"
        or state.get("evidence_outcome") != "supported"
        or state.get("run_id") != manifest_doc.get("run_id")
        or state.get("next_task_ids") != ["R1"]
        or state.get("no_valid_r1_j1_gate") is not True
        or state.get("run_manifest_sha256") != _digest(manifest_path)
    ):
        _fail("R0 does not authenticate the exact r2 bootstrap handoff")
    plan = _mapping(manifest_doc.get("plan_contract"), "r2 plan contract")
    sources = _mapping(state.get("source_input_hashes"), "R0 source_input_hashes")
    if sources.get("plan_contract") != plan.get("sha256"):
        _fail("R0 does not bind the exact r2 plan contract")
    for name, value in sources.items():
        _sha(value, "R0 source_input_hashes.{}".format(name))
    imported = _mapping(manifest_doc.get("r1_import"), "r2 r1_import")
    artifact = _mapping(
        _mapping(state.get("artifacts"), "R0 artifacts").get("import-manifest"),
        "R0 import-manifest",
    )
    if artifact != imported:
        _fail("R0 import artifact differs from the run manifest")
    import_path = _contained_path(
        run_root, imported.get("path"), "R0 import manifest", run_root
    )
    _verify_file(import_path, imported.get("sha256"), imported.get("bytes"))
    if "0{:03o}".format(stat.S_IMODE(import_path.stat().st_mode)) != imported.get("mode"):
        _fail("R0 import manifest mode differs from the run manifest")


def _verify_r2_r1_chain(
    run_root: Path, manifest_doc: Mapping[str, Any], effective_path: Path
) -> Mapping[str, Any]:
    repo_root = Path(__file__).resolve().parents[4]
    original_path = run_root / "task-state/R1.json"
    original = _load_immutable_json(original_path, "original R1 state")
    r0_path = run_root / "task-state/R0.json"
    if (
        original.get("schema_version") != "dicow-r2-task-state-v1"
        or original.get("task") != "R1"
        or original.get("state") != "done"
        or original.get("branch_disposition") != "executed"
        or original.get("evidence_outcome") != "supported"
        or original.get("run_id") != manifest_doc.get("run_id")
        or original.get("next_task_ids") != ["R2"]
        or original.get("source_input_hashes") != {
            "R0_state": _digest(r0_path),
            "run_manifest": _digest(run_root / "run-manifest.json"),
        }
    ):
        _fail("original R1 does not authenticate its exact R0/manifest transition")
    amendment_names = []
    if (run_root / "task-state/R1-contract-amendment-1.json").exists():
        amendment_names.append("R1-contract-amendment-1")
    if (run_root / "task-state/R1-contract-amendment-2.json").exists():
        if not amendment_names:
            _fail("R1 amendment-2 cannot exist without amendment-1")
        amendment_names.append("R1-contract-amendment-2")
    if (run_root / "task-state/R1-contract-amendment-3.json").exists():
        if len(amendment_names) != 2:
            _fail("R1 amendment-3 requires amendment-1 and amendment-2")
        amendment_names.append("R1-contract-amendment-3")
    if (run_root / "task-state/R1-contract-amendment-4.json").exists():
        if len(amendment_names) != 3:
            _fail("R1 amendment-4 requires amendments 1 through 3")
        amendment_names.append("R1-contract-amendment-4")
    if (run_root / "task-state/R1-contract-amendment-5.json").exists():
        if len(amendment_names) != 4:
            _fail("R1 amendment-5 requires amendments 1 through 4")
        amendment_names.append("R1-contract-amendment-5")
    if (run_root / "task-state/R1-contract-amendment-6.json").exists():
        if len(amendment_names) != 5:
            _fail("R1 amendment-6 requires amendments 1 through 5")
        amendment_names.append("R1-contract-amendment-6")
    if (run_root / "task-state/R1-contract-amendment-7.json").exists():
        if len(amendment_names) != 6:
            _fail("R1 amendment-7 requires amendments 1 through 6")
        amendment_names.append("R1-contract-amendment-7")
    if (run_root / "task-state/R1-contract-amendment-8.json").exists():
        if len(amendment_names) != 7:
            _fail("R1 amendment-8 requires amendments 1 through 7")
        amendment_names.append("R1-contract-amendment-8")
    if (run_root / "task-state/R1-contract-amendment-9.json").exists():
        if len(amendment_names) != 8:
            _fail("R1 amendment-9 requires amendments 1 through 8")
        amendment_names.append("R1-contract-amendment-9")
    if (run_root / "task-state/R1-contract-amendment-10.json").exists():
        if len(amendment_names) != 9:
            _fail("R1 amendment-10 requires amendments 1 through 9")
        amendment_names.append("R1-contract-amendment-10")
    _verify_r2_tracked_transition(
        "R1", run_root, repo_root, manifest_doc, verify_fresh_output=not amendment_names
    )
    prior_name = "R1"
    prior_path = original_path
    effective = original
    for index, amendment_name in enumerate(amendment_names):
        amendment_path = run_root / "task-state/{}.json".format(amendment_name)
        amendment = _load_immutable_json(amendment_path, amendment_name)
        prior_sha = _digest(prior_path)
        if (
            amendment.get("schema_version") != "dicow-r2-task-state-v1"
            or amendment.get("task") != amendment_name
            or amendment.get("state") != "done"
            or amendment.get("branch_disposition") != "executed"
            or amendment.get("evidence_outcome") != "supported"
            or amendment.get("run_id") != manifest_doc.get("run_id")
            or amendment.get("next_task_ids") != ["R2"]
            or amendment.get("original_state_sha256") != prior_sha
            or amendment.get("predecessor_state_hashes") != {prior_name: prior_sha}
        ):
            _fail("{} is not an exact effective R1 amendment".format(amendment_name))
        _verify_r2_tracked_transition(
            amendment_name, run_root, repo_root, manifest_doc,
            verify_fresh_output=index == len(amendment_names) - 1,
        )
        prior_name, prior_path, effective = amendment_name, amendment_path, amendment
    if effective_path != prior_path.resolve():
        _fail("effective R1 path does not name the last authenticated amendment")
    return effective


def _r3_selected_audit_paths(
    run_root: Path, run_id: str, *, replay: bool
) -> Tuple[Path, Path, Mapping[str, Any]]:
    audit_root = run_root / "pre-model-audit"
    replay_result = {}  # type: Mapping[str, Any]
    if replay:
        try:
            from benchmarks.scripts.dicow.reference import inspect as r2_inspect
            replay_result = _mapping(
                r2_inspect.verify_r2_audit(audit_root), "R3 pre-model audit replay"
            )
        except Exception as error:
            _fail("R3 pre-model audit replay failed: {}".format(error))
        summary = _mapping(replay_result.get("summary"), "R3 audit replay summary")
        decision = _mapping(summary.get("decision"), "R3 audit replay decision")
        if (
            replay_result.get("status") != "verified"
            or replay_result.get("run_id") != run_id
            or decision.get("dicow_scope") != "evidence_blocker"
        ):
            _fail("R3 pre-model audit replay does not prove the DiCoW evidence blocker")
    canonical_path = audit_root / "canonical.json"
    canonical = _load_immutable_json(canonical_path, "R3 pre-model audit selector")
    if (
        set(canonical) != {"schema_version", "run_id", "attempt", "manifest_record"}
        or canonical.get("schema_version") != "dicow-r2-pre-model-audit-canonical-v1"
        or canonical.get("run_id") != run_id
    ):
        _fail("R3 pre-model audit selector identity differs")
    attempt_value = canonical.get("attempt")
    if not isinstance(attempt_value, str):
        _fail("R3 pre-model audit selector lacks an absolute attempt")
    attempt = Path(attempt_value)
    try:
        attempt.relative_to(audit_root / "attempts")
    except ValueError:
        _fail("R3 selected audit attempt escapes the canonical attempts root")
    manifest_path = attempt / "manifest.json"
    manifest_tuple = _file_tuple(manifest_path)
    expected_manifest = _mapping(
        canonical.get("manifest_record"), "R3 selected audit manifest record"
    )
    if set(expected_manifest) != {"sha256", "bytes"} or {
        "sha256": manifest_tuple.get("sha256"), "bytes": manifest_tuple.get("bytes")
    } != expected_manifest:
        _fail("R3 selected audit manifest tuple differs")
    selected_manifest = _load_immutable_json(manifest_path, "R3 selected audit manifest")
    if (
        selected_manifest.get("schema_version")
        != "dicow-r2-pre-model-audit-manifest-v1"
        or selected_manifest.get("run_id") != run_id
    ):
        _fail("R3 selected audit manifest identity differs")
    spec_path = _contained_path(
        run_root,
        R2_R3_FIXED_SOURCE_PATHS[_R2_R3_ACTIVE_SPEC_SOURCE_KEY],
        "R3 active audit spec",
        run_root,
    )
    spec_tuple = _file_tuple(spec_path)
    expected_spec_record = {
        "bytes": spec_tuple.get("bytes"), "sha256": spec_tuple.get("sha256")
    }
    if (
        spec_tuple.get("absent") is True
        or spec_tuple.get("mode") != "0444"
        or selected_manifest.get("spec_record") != expected_spec_record
    ):
        _fail("R3 selected audit manifest does not bind the active frozen spec")
    return manifest_path, attempt / "audit" / "model-identities.json", replay_result


def _verify_r3_publication_state(
    state: Mapping[str, Any], run_root: Path, manifest_doc: Mapping[str, Any], repo_root: Path
) -> None:
    run_id = _string(manifest_doc.get("run_id"), "r2 run id")
    manifest_path = run_root / "run-manifest.json"
    effective_r1_path = _effective_r2_state_path("R1", run_root)
    r2_path = run_root / "task-state/R2.json"
    selected_manifest_path, identities_path, _ = _r3_selected_audit_paths(
        run_root, run_id, replay=True
    )
    plan = _mapping(manifest_doc.get("plan_contract"), "r2 plan contract")
    expected_sources = {
        "plan_contract": _sha(plan.get("sha256"), "r2 plan contract sha256"),
        "run_manifest": _digest(manifest_path),
        "R1_effective_state": _digest(effective_r1_path),
        "R2_state": _digest(r2_path),
    }
    for key, relative in R2_R3_FIXED_SOURCE_PATHS.items():
        source_path = _contained_path(run_root, relative, "R3 source {}".format(key), run_root)
        source_tuple = _file_tuple(source_path)
        if source_tuple.get("absent") is True or source_tuple.get("mode") != "0444":
            _fail("R3 fixed source {} must be an immutable file".format(key))
        expected_sources[key] = source_tuple["sha256"]
    expected_sources["pre_model_audit_manifest"] = _digest(selected_manifest_path)
    if tuple(expected_sources) != R2_R3_SOURCE_INPUT_KEYS:
        _fail("internal R3 source-input key order differs from the contract")
    sources = _mapping(state.get("source_input_hashes"), "R3 source_input_hashes")
    if sources != expected_sources:
        _fail("R3 source_input_hashes do not match the exact immutable source roster")

    identity_tuple = _file_tuple(identities_path)
    if identity_tuple.get("absent") is True or identity_tuple.get("mode") != "0444":
        _fail("R3 selected model-identities artifact must be immutable")
    expected_identity_path = str(identities_path.relative_to(run_root))
    expected_artifact = {
        "path": expected_identity_path,
        "sha256": identity_tuple["sha256"],
        "bytes": identity_tuple["bytes"],
    }
    artifacts = _mapping(state.get("artifacts"), "R3 artifacts")
    if set(artifacts) != {"model-identities"} or artifacts.get("model-identities") != expected_artifact:
        _fail("R3 artifacts must bind exactly the selected model-identities file")

    fragment_proposal_path = run_root / "r3-runtime.staging/sealed-fragment-record.json"
    fragment_proposal = _load_immutable_json(fragment_proposal_path, "R3 fragment proposal")
    if set(fragment_proposal) != set(R2_R3_SEALED_FRAGMENT_KEYS):
        _fail("R3 runtime fragment proposal roster differs")
    fragment_path = run_root / "env.d/R3-runtimes.env"
    fragment_tuple = _file_tuple(fragment_path)
    expected_fragment = {
        "path": "env.d/R3-runtimes.env",
        "sha256": fragment_tuple.get("sha256"),
        "bytes": fragment_tuple.get("bytes"),
        "mode": fragment_tuple.get("mode"),
    }
    if (
        fragment_tuple.get("absent") is True
        or fragment_tuple.get("mode") != "0444"
        or expected_fragment != fragment_proposal.get("R3-runtimes.env")
    ):
        _fail("R3 canonical runtime fragment differs from its sealed proposal")
    sealed_fragments = _mapping(state.get("sealed_fragments"), "R3 sealed_fragments")
    if sealed_fragments != {"R3-runtimes.env": expected_fragment}:
        _fail("R3 sealed_fragments must contain exactly the canonical runtime fragment")

    path_proposal = _load_immutable_json(
        run_root / "r3-runtime.staging/sealed-path-records.json", "R3 sealed path proposal"
    )
    if set(path_proposal) != set(R2_R3_SEALED_PATH_KINDS):
        _fail("R3 runtime sealed-path proposal roster differs")
    sealed_paths = _mapping(state.get("sealed_paths"), "R3 sealed_paths")
    if sealed_paths != path_proposal:
        _fail("R3 sealed_paths must exactly match the runtime proposal")
    from benchmarks.scripts.dicow.run_with_env import LauncherError, sealed_path_record
    for key, kind in R2_R3_SEALED_PATH_KINDS.items():
        record = _mapping(sealed_paths.get(key), "R3 sealed path {}".format(key))
        if set(record) != {"path", "sha256", "bytes", "mode"}:
            _fail("R3 sealed path {} has the wrong fields".format(key))
        try:
            actual = sealed_path_record(Path(_string(record.get("path"), key)), kind)
        except LauncherError as error:
            _fail("R3 sealed path {} cannot be replayed: {}".format(key, error))
        if actual != record:
            _fail("R3 sealed path {} differs from fresh disk".format(key))


def _load_r2_gate_authority(
    authority_task: str,
    gate_id: str,
    gate_relative: str,
    run_id: str,
    run_root: Path,
) -> Tuple[Mapping[str, Any], Mapping[str, Any], Path]:
    authority_path = _effective_r2_state_path(authority_task, run_root)
    authority = _load_immutable_json(
        authority_path, "effective {} gate authority".format(authority_task)
    )
    if (
        authority.get("schema_version") != "dicow-r2-task-state-v1"
        or authority.get("task") != authority_task
        or authority.get("state") != "done"
        or authority.get("run_id") != run_id
        or authority.get("branch_disposition") != "executed"
    ):
        _fail("{} gate authority state is invalid".format(authority_task))
    if authority.get("gate_path") != gate_relative:
        _fail("{} gate authority path is not canonical".format(authority_task))
    gate_path = _contained_path(
        run_root, gate_relative, "{} gate authority".format(authority_task), run_root
    )
    _verify_file(gate_path, authority.get("gate_sha256"))
    verify_gate(gate_path)
    gate = _load_json(gate_path)
    decision = _mapping(gate.get("decision"), "r2 governing gate decision")
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
        _fail("{} gate authority is not an authenticated {} transition".format(
            authority_task, gate_id
        ))
    semantics = R2_GATE_TASK_SEMANTICS[(gate_id, scope)]
    if (
        decision.get("next_task_ids") != list(semantics["next"])
        or _unique_strings(decision.get("skip_task_ids"), "r2 gate skip task IDs")
        != list(semantics["skip"])
    ):
        _fail("{} gate authority has the wrong task transition".format(authority_task))
    if (
        authority.get("evidence_outcome") != decision.get("evidence_outcome")
        or authority.get("next_task_ids") != decision.get("next_task_ids")
    ):
        _fail("{} differs from its authenticated gate transition".format(authority_task))
    return authority, decision, gate_path


def _verify_r2_skip_gate_authority(
    task: str, state: Mapping[str, Any], run_root: Path
) -> None:
    gate_relative = state.get("gate_path")
    if task in {"R11", "R12"} and gate_relative == R2_J2_GATE_PATH:
        authority_task, gate_id = "R10", "J2-r2"
    else:
        authority_task, gate_id = "R4", "J1-r2"
        if gate_relative != R2_J1_GATE_PATH:
            expected = "canonical J1-r2 or J2-r2" if task in {"R11", "R12"} else "canonical J1-r2"
            _fail("{} skip must reference the {} gate path".format(task, expected))
    authority, decision, _ = _load_r2_gate_authority(
        authority_task, gate_id, str(gate_relative), str(state.get("run_id")), run_root
    )
    if state.get("gate_sha256") != authority.get("gate_sha256"):
        if authority_task == "R4":
            _fail("{} skip gate hash differs from the effective R4 gate".format(task))
        _fail("{} skip gate hash differs from {}".format(task, authority_task))
    if state.get("evidence_outcome") != decision.get("evidence_outcome"):
        _fail("{} skip outcome differs from its authenticated gate".format(task))
    skip_tasks = _unique_strings(decision.get("skip_task_ids"), "r2 skip task IDs")
    if task not in skip_tasks:
        _fail("{} is absent from its authenticated skip gate".format(task))


def _verify_r2_executed_gate_authority(
    task: str, state: Mapping[str, Any], run_root: Path
) -> None:
    governed = {
        governed_task
        for (gate_id, _), semantics in R2_GATE_TASK_SEMANTICS.items()
        if gate_id == "J1-r2"
        for governed_task in semantics["next"] + semantics["skip"]
    }
    if task not in governed or task == "R4":
        return
    _, j1_decision, _ = _load_r2_gate_authority(
        "R4", "J1-r2", R2_J1_GATE_PATH, str(state.get("run_id")), run_root
    )
    if task in _unique_strings(j1_decision.get("skip_task_ids"), "J1-r2 skip tasks"):
        _fail("{} executes despite the authenticated J1-r2 skip decision".format(task))
    j2_active = task in {"R10", "R11", "R12"}
    if task == "R13":
        r10_path = _effective_r2_state_path("R10", run_root)
        if r10_path.exists():
            r10_state = _load_immutable_json(r10_path, "effective R10 state")
            j2_active = r10_state.get("branch_disposition") == "executed"
    if j2_active:
        _, j2_decision, _ = _load_r2_gate_authority(
            "R10", "J2-r2", R2_J2_GATE_PATH, str(state.get("run_id")), run_root
        )
        if task in {"R11", "R12", "R13"} and task in _unique_strings(
            j2_decision.get("skip_task_ids"), "J2-r2 skip tasks"
        ):
            _fail("{} executes despite the authenticated J2-r2 skip decision".format(task))
    if task == "R13":
        _load_r2_gate_authority(
            "R13", "FINAL-r2", R2_FINAL_GATE_PATH,
            str(state.get("run_id")), run_root,
        )


def verify_r2_task_state(
    task: str, run_root: Path
) -> Tuple[Mapping[str, Any], Path]:
    """Verify one r2 state and the exact hashes of all declared predecessors."""

    if task not in R2_TASK_DEPENDENCIES:
        _fail("unknown r2 task {}".format(task))
    run_root = run_root.resolve()
    repo_root = Path(__file__).resolve().parents[4]
    manifest_path = run_root / "run-manifest.json"
    manifest_doc = _load_immutable_json(manifest_path, "r2 run manifest")
    state_path = _effective_r2_state_path(task, run_root)
    state = _load_immutable_json(state_path, "effective {} state".format(task))
    if task == "R0":
        _verify_r2_r0_state(state, state_path, run_root, manifest_doc, manifest_path)
    elif task == "R1":
        verify_r2_task_state("R0", run_root)
        state = _verify_r2_r1_chain(run_root, manifest_doc, state_path)
    elif state.get("task") != task:
        _fail("effective r2 task-state identity mismatch for {}".format(task))
    if (
        state.get("schema_version") != "dicow-r2-task-state-v1"
        or state.get("state") != "done"
        or state.get("run_id") != manifest_doc.get("run_id")
    ):
        _fail("{} state identity or completion is invalid".format(task))
    if task not in ("R0", "R1"):
        expected_predecessors = {}
        for predecessor in R2_TASK_DEPENDENCIES[task]:
            _, predecessor_path = verify_r2_task_state(predecessor, run_root)
            expected_predecessors[predecessor] = _digest(predecessor_path)
        if state.get("predecessor_state_hashes") != expected_predecessors:
            _fail("{} predecessor state hashes are not exact".format(task))
    if task == "R3":
        if state.get("next_task_ids") != ["R4"]:
            _fail("R3 must authorize exactly R4")
        if state.get("branch_disposition") != "executed":
            _fail("R3 must be an executed publication state")
        _verify_r3_publication_state(state, run_root, manifest_doc, repo_root)
        _verify_r2_tracked_transition(task, run_root, repo_root, manifest_doc)
        if state.get("evidence_outcome") != "evidence_blocker":
            _fail("R3 must publish the exact DiCoW evidence-blocker outcome")
    if task == "R4":
        if state.get("branch_disposition") != "executed":
            _fail("R4 must publish an executed J1-r2 transition")
        if state.get("gate_path") != R2_J1_GATE_PATH:
            _fail("R4 state must reference the canonical J1-r2 gate path")
        gate_path = _contained_path(
            run_root, state.get("gate_path"), "R4 gate path", run_root
        )
        _verify_file(gate_path, state.get("gate_sha256"))
        verify_gate(gate_path)
        gate = _load_json(gate_path)
        decision = _mapping(gate.get("decision"), "R4 J1-r2 decision")
        scope = decision.get("scope")
        outcome = decision.get("evidence_outcome")
        next_tasks = decision.get("next_task_ids")
        if scope == "proceed_dicow_and_qwen":
            _fail("R4 cannot proceed with DiCoW while the R3 blocker stands")
        if scope == "proceed_qwen_only":
            if outcome != "evidence_blocker" or next_tasks != ["Q1"]:
                _fail("R4 Qwen-only gate has an invalid transition")
        elif scope == "revise_or_stop_all":
            if outcome not in {"not_supported", "evidence_blocker", "unresolved"} or next_tasks != ["R13"]:
                _fail("R4 stop gate has an invalid typed transition")
        else:
            _fail("R4 state does not reference an accepted J1-r2 scope")
        if (
            state.get("evidence_outcome") != outcome
            or state.get("next_task_ids") != next_tasks
        ):
            _fail("R4 state differs from its authenticated J1-r2 transition")
    disposition = state.get("branch_disposition")
    if disposition == "executed":
        if state.get("evidence_outcome") not in EVIDENCE_OUTCOMES:
            _fail("{} executed state lacks a typed evidence outcome".format(task))
        _verify_r2_executed_gate_authority(task, state, run_root)
        return state, state_path
    if disposition != "skipped":
        _fail("{} has an invalid branch disposition".format(task))
    _verify_r2_skip_gate_authority(task, state, run_root)
    return state, state_path


def _file_tuple(path: Path) -> Mapping[str, Any]:
    if path.is_symlink():
        _fail("tracked path may not be a symlink: {}".format(path))
    if not path.exists():
        return {"absent": True}
    if not path.is_file():
        _fail("tracked path is not a regular file: {}".format(path))
    details = path.stat()
    return {
        "sha256": _digest(path),
        "bytes": details.st_size,
        "mode": "0{:03o}".format(stat.S_IMODE(details.st_mode)),
    }


def _verify_tuple(value: Any, field: str) -> Mapping[str, Any]:
    record = _mapping(value, field)
    if record == {"absent": True}:
        return record
    if set(record) != {"sha256", "bytes", "mode"}:
        _fail("{} must be an exact file tuple or absent marker".format(field))
    _sha(record.get("sha256"), "{}.sha256".format(field))
    size = record.get("bytes")
    if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
        _fail("{}.bytes must be a positive integer".format(field))
    mode = _string(record.get("mode"), "{}.mode".format(field))
    if _MODE.fullmatch(mode) is None:
        _fail("{}.mode must be a four-digit octal string".format(field))
    return record


def _expected_predecessor(
    task: str, relative: str, run_root: Path, run_manifest: Mapping[str, Any]
) -> Mapping[str, Any]:
    chain = TRACKED_FILE_PREDECESSORS[relative]
    if task not in chain:
        _fail("task {} is not allowed to own {}".format(task, relative))
    prior = chain[: chain.index(task)]
    predecessors = _mapping(run_manifest.get("tracked_predecessors"), "run-manifest.tracked_predecessors")
    expected = _verify_tuple(
        predecessors.get(relative), "initial predecessor for {}".format(relative)
    )
    for predecessor in prior:
        state_path = run_root / "task-state" / "{}.json".format(predecessor)
        if not state_path.is_file() or state_path.is_symlink():
            _fail("required predecessor task-state is missing or a symlink: {}".format(predecessor))
        state = _load_immutable_json(state_path, "predecessor task-state")
        if state.get("task") != predecessor:
            _fail("task-state identity mismatch for {}".format(predecessor))
        if state.get("run_id") != run_manifest.get("run_id"):
            _fail("predecessor {} belongs to another run".format(predecessor))
        if state.get("state") != "done":
            _fail("predecessor {} exists but is not done".format(predecessor))
        disposition = state.get("branch_disposition")
        if disposition == "skipped":
            _verify_skipped_state(state, predecessor, run_root)
            continue
        if disposition != "executed":
            _fail("predecessor {} has invalid branch disposition".format(predecessor))
        files = _mapping(state.get("tracked_files"), "{}.tracked_files".format(predecessor))
        entry = _mapping(files.get(relative), "{} tracked entry for {}".format(predecessor, relative))
        recorded_input = _verify_tuple(
            entry.get("input"), "{} input for {}".format(predecessor, relative)
        )
        if recorded_input != expected:
            _fail("{} recorded input breaks the predecessor chain for {}".format(
                predecessor, relative
            ))
        expected = _verify_tuple(
            entry.get("output"), "{} output for {}".format(predecessor, relative)
        )
    return expected


def _verify_skipped_state(
    state: Mapping[str, Any], task: str, run_root: Path
) -> None:
    gate_path = _contained_path(
        run_root, state.get("gate_path"), "{}.gate_path".format(task), run_root
    )
    _verify_file(gate_path, state.get("gate_sha256"))
    gate = _load_json(gate_path)
    if task not in _list(gate.get("skip_tasks"), "skip gate.skip_tasks"):
        _fail("skip gate does not name {}".format(task))
    verify_gate(gate_path)
    evidence_id = _string(state.get("evidence_id"), "{}.evidence_id".format(task))
    gate_evidence_ids = _unique_strings(gate.get("evidence_ids"), "skip gate.evidence_ids")
    if evidence_id not in gate_evidence_ids:
        _fail("skipped task {} cites evidence absent from its gate".format(task))
    _string(state.get("reason"), "{}.reason".format(task))
    source_hashes = _mapping(
        state.get("source_input_hashes"), "{}.source_input_hashes".format(task)
    )
    if not source_hashes:
        _fail("skipped task {} has no source-input hashes".format(task))
    gate_hashes = _mapping(gate.get("evidence_hashes"), "skip gate.evidence_hashes")
    for name, value in source_hashes.items():
        source_sha = _sha(value, "{}.source_input_hashes.{}".format(task, name))
        if name not in gate_hashes or source_sha != gate_hashes[name]:
            _fail("skipped task source hash {} is not bound to its gate".format(name))


def verify_tracked_transition(task: str, run_root: Path, repo: Path) -> None:
    run_root = run_root.resolve()
    repo = repo.resolve()
    run_manifest = _load_json(run_root / "run-manifest.json")
    if run_manifest.get("schema_version") == "dicow-r2-run-manifest-v1":
        _verify_r2_tracked_transition(task, run_root, repo, run_manifest)
        return
    allowed = TASK_TRACKED_FILES.get(task)
    if allowed is None:
        _fail("task {} has no tracked-file transition contract".format(task))
    state_path = run_root / "task-state" / "{}.json".format(task)
    state = _load_immutable_json(state_path, "current task-state")
    if state.get("schema_version") != "dicow-task-state-v1" or state.get("task") != task:
        _fail("{} task-state identity is wrong".format(task))
    if state.get("state") != "done" or state.get("branch_disposition") != "executed":
        _fail("tracked transition requires a done, executed task-state")
    if state.get("run_id") != run_manifest.get("run_id"):
        _fail("task-state run ID differs from run manifest")
    tracked = _mapping(state.get("tracked_files"), "task-state.tracked_files")
    if set(tracked) != set(allowed):
        _fail("{} tracked_files must be exactly {}".format(task, sorted(allowed)))
    for relative in allowed:
        if Path(relative).is_absolute() or ".." in Path(relative).parts:
            _fail("invalid tracked relative path {}".format(relative))
        entry = _mapping(tracked.get(relative), "tracked_files.{}".format(relative))
        if set(entry) != {"input", "output"}:
            _fail("tracked entry {} must contain only input and output".format(relative))
        recorded_input = _verify_tuple(entry.get("input"), "tracked input {}".format(relative))
        expected_input = _expected_predecessor(task, relative, run_root, run_manifest)
        if recorded_input != expected_input:
            _fail("{} input is not the last executed predecessor".format(relative))
        recorded_output = _verify_tuple(entry.get("output"), "tracked output {}".format(relative))
        current = _file_tuple(repo / relative)
        if recorded_output != current:
            _fail("{} output does not match fresh disk bytes".format(relative))
    print("verified {} tracked transition for {}".format(task, ", ".join(allowed)))


def _verify_r2_tracked_transition(
    task: str,
    run_root: Path,
    repo: Path,
    run_manifest: Mapping[str, Any],
    verify_fresh_output: bool = True,
) -> None:
    allowed = R2_TASK_TRACKED_FILES.get(task)
    if allowed is None:
        _fail("r2 task {} has no tracked-file transition contract".format(task))
    state_path = run_root / "task-state/{}.json".format(task)
    state = _load_immutable_json(state_path, "R1 task-state")
    expected_identity = task
    if (
        state.get("schema_version") != "dicow-r2-task-state-v1"
        or state.get("task") != expected_identity
        or state.get("state") != "done"
        or state.get("branch_disposition") != "executed"
        or (
            state.get("evidence_outcome") != "supported"
            if task in (
                "R1", "R1-contract-amendment-1", "R1-contract-amendment-2",
                "R1-contract-amendment-3", "R1-contract-amendment-4",
                "R1-contract-amendment-5", "R1-contract-amendment-6",
                "R1-contract-amendment-7", "R1-contract-amendment-8",
                "R1-contract-amendment-9", "R1-contract-amendment-10",
            )
            else (
                state.get("evidence_outcome") != "evidence_blocker"
                if task == "R3"
                else state.get("evidence_outcome") not in EVIDENCE_OUTCOMES
            )
        )
        or state.get("run_id") != run_manifest.get("run_id")
    ):
        _fail("{} task-state does not close its r2 tracked task".format(task))
    if task in (
        "R1-contract-amendment-1", "R1-contract-amendment-2",
        "R1-contract-amendment-3", "R1-contract-amendment-4",
        "R1-contract-amendment-5", "R1-contract-amendment-6",
        "R1-contract-amendment-7", "R1-contract-amendment-8",
        "R1-contract-amendment-9", "R1-contract-amendment-10",
    ):
        predecessor_task = {
            "R1-contract-amendment-1": "R1",
            "R1-contract-amendment-2": "R1-contract-amendment-1",
            "R1-contract-amendment-3": "R1-contract-amendment-2",
            "R1-contract-amendment-4": "R1-contract-amendment-3",
            "R1-contract-amendment-5": "R1-contract-amendment-4",
            "R1-contract-amendment-6": "R1-contract-amendment-5",
            "R1-contract-amendment-7": "R1-contract-amendment-6",
            "R1-contract-amendment-8": "R1-contract-amendment-7",
            "R1-contract-amendment-9": "R1-contract-amendment-8",
            "R1-contract-amendment-10": "R1-contract-amendment-9",
        }[task]
        original_path = run_root / "task-state/{}.json".format(predecessor_task)
        if (
            state.get("original_state_sha256") != _digest(original_path)
            or state.get("predecessor_state_hashes") != {
                predecessor_task: _digest(original_path)
            }
        ):
            _fail("R1 amendment does not bind its immutable predecessor")
        original = _load_immutable_json(original_path, "prior effective R1 state")
        expected_inputs = {
            relative: _mapping(original.get("tracked_files"), "original R1 tracked")[relative]["output"]
            for relative in allowed
        }
    elif task in ("R10", "R13"):
        verify_r2_task_state(task, run_root)
        chain = ("R10", "R13")
        expected_inputs = {}
        for relative in allowed:
            if relative in R2_TRACKED_FILES:
                r1_effective = _load_immutable_json(
                    _effective_r2_state_path("R1", run_root), "effective R1 state"
                )
                expected = _mapping(
                    r1_effective.get("tracked_files"), "effective R1 tracked"
                )[relative]["output"]
            else:
                expected = None
            for predecessor in chain[:chain.index(task)]:
                predecessor_path = run_root / "task-state/{}.json".format(predecessor)
                if predecessor_path.exists():
                    predecessor_state = _load_immutable_json(predecessor_path, predecessor)
                    predecessor_tracked = _mapping(
                        predecessor_state.get("tracked_files"), predecessor
                    )
                    if relative in predecessor_tracked:
                        expected = predecessor_tracked[relative]["output"]
            expected_inputs[relative] = expected
    else:
        expected_inputs = None
    r0_path = run_root / "task-state/R0.json"
    _load_immutable_json(r0_path, "R0 task-state")
    manifest_path = run_root / "run-manifest.json"
    if task == "R1" and state.get("source_input_hashes") != {
        "R0_state": _digest(r0_path),
        "run_manifest": _digest(manifest_path),
    }:
        _fail("R1 source dependency is not the exact R0/manifest pair")
    before_record = _mapping(
        run_manifest.get("repository_before_state"), "repository_before_state"
    )
    if set(before_record) != {"path", "run_path", "sha256", "bytes", "mode"}:
        _fail("repository-before-state tuple has the wrong fields")
    before_path = _contained_path(
        run_root,
        before_record.get("run_path"),
        "repository-before-state",
        run_root,
    )
    if str(before_path) != before_record.get("path"):
        _fail("repository-before-state absolute path differs from its run tuple")
    _verify_file(before_path, before_record.get("sha256"), before_record.get("bytes"))
    if "0{:03o}".format(stat.S_IMODE(before_path.stat().st_mode)) != before_record.get("mode"):
        _fail("repository-before-state mode differs from its run tuple")
    before = _load_immutable_json(before_path, "repository-before-state")
    before_index = {}
    for collection_name in ("untracked_worktree", "tracked_worktree"):
        entries = _list(before.get(collection_name, []), collection_name)
        for raw in entries:
            record = _mapping(raw, "{}[]".format(collection_name))
            if set(record) != {"repo_path", "sha256", "bytes", "mode"}:
                _fail("{} before-state tuple has the wrong fields".format(collection_name))
            relative = _string(record.get("repo_path"), "{} repo_path".format(collection_name))
            if relative in before_index:
                _fail("repository before-state repeats {}".format(relative))
            before_index[relative] = {
                "sha256": record.get("sha256"),
                "bytes": record.get("bytes"),
                "mode": record.get("mode"),
            }
    for relative in allowed:
        if task in ("R10", "R13") and expected_inputs[relative] is None:
            expected_inputs[relative] = before_index.get(relative)
    tracked = _mapping(state.get("tracked_files"), "{} tracked_files".format(task))
    if set(tracked) != set(allowed):
        _fail("{} tracked-file roster differs from the frozen r2 set".format(task))
    for relative in allowed:
        transition = _mapping(tracked.get(relative), "R1 tracked {}".format(relative))
        if set(transition) != {"input", "output"}:
            _fail("R1 transition for {} must contain input and output".format(relative))
        expected_input = before_index.get(relative) if expected_inputs is None else expected_inputs[relative]
        if transition.get("input") != expected_input:
            _fail("R1 input does not match imported before-state for {}".format(relative))
        output = _verify_tuple(transition.get("output"), "R1 output {}".format(relative))
        if verify_fresh_output and output != _file_tuple(repo / relative):
            _fail("R1 output differs from fresh disk for {}".format(relative))
    print("verified {} r2 tracked transition for {} files".format(task, len(allowed)))


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    fable = subparsers.add_parser("verify-fable")
    fable.add_argument("evidence_dir", type=Path)
    gate = subparsers.add_parser("verify-gate")
    gate.add_argument("gate", type=Path)
    tracked = subparsers.add_parser("verify-tracked-transition")
    tracked.add_argument("--task", required=True)
    tracked.add_argument("--run", required=True, type=Path)
    tracked.add_argument("--repo", required=True, type=Path)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "verify-fable":
            verify_fable(args.evidence_dir)
        elif args.command == "verify-gate":
            verify_gate(args.gate)
        elif args.command == "verify-tracked-transition":
            verify_tracked_transition(args.task, args.run, args.repo)
        else:
            _fail("unknown command {}".format(args.command))
    except VerificationError as exc:
        print("verification failed: {}".format(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
