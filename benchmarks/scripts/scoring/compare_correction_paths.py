#!/usr/bin/env python3
"""Compare two sealed source runs and their selected correction derivations."""

from __future__ import annotations

import argparse
from hashlib import sha256
import json
from pathlib import Path
import sys
from typing import Any, Sequence

from check_run import validate_completed_run_manifest, validate_segments_document
from metrics import term_recall, text_error_rate, utterance_omissions
from score_corrected import (
    _reject_output_within_inputs,
    _validate_canonical_source_artifacts,
    _validate_completed_source_coverage,
    _validate_reference_document,
    _validate_source_root,
    _validate_source_tree_seal,
    score_corrected_run,
)


SCHEMA_VERSION = "1.0.0"
METRIC_DIRECTIONS = {
    "cer.error_rate": "lower",
    "wer.error_rate": "lower",
    "terms.term_recall": "higher",
    "omissions.omitted_utterances": "lower",
}
COMPARISON_ENDPOINTS = {
    "decode_time_injection_gain": (
        {"state": "no_glossary", "output": "raw"},
        {"state": "decode_glossary", "output": "raw"},
    ),
    "correction_gain": (
        {"state": "decode_glossary_corrected", "output": "raw"},
        {"state": "decode_glossary_corrected", "output": "corrected"},
    ),
    "correction_gain_without_decode_time_injection": (
        {"state": "no_glossary_corrected", "output": "raw"},
        {"state": "no_glossary_corrected", "output": "corrected"},
    ),
}
STATE_REQUIREMENTS = {
    "no_glossary": {"decode_glossary": False, "corrected": False},
    "decode_glossary": {"decode_glossary": True, "corrected": False},
}


def _load_json(path: Path, *, label: str) -> Any:
    def reject_nonfinite(value: str) -> None:
        raise ValueError(f"non-finite JSON number is forbidden: {value}")

    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            parse_constant=reject_nonfinite,
        )
    except (OSError, ValueError) as error:
        raise ValueError(f"cannot read {label}: {error}") from error


def _file_sha256(path: Path) -> str:
    digest = sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _joined_text(document: dict[str, Any]) -> str:
    segments = sorted(
        document["segments"],
        key=lambda segment: (
            float(segment["start_s"]),
            float(segment["end_s"]),
        ),
    )
    return " ".join(str(segment["text"]) for segment in segments)


def _score_document(
    reference: dict[str, Any],
    hypothesis: dict[str, Any],
    terms: list[dict[str, object]],
) -> dict[str, Any]:
    reference_text = _joined_text(reference)
    hypothesis_text = _joined_text(hypothesis)
    return {
        "cer": text_error_rate(
            reference_text, hypothesis_text, unit="character"
        ).as_dict(),
        "omissions": utterance_omissions(
            reference["segments"], hypothesis["segments"]
        ),
        "terms": term_recall(terms, hypothesis_text),
        "wer": text_error_rate(
            reference_text, hypothesis_text, unit="word"
        ).as_dict(),
    }


def _path_value(document: dict[str, Any], path: str) -> Any:
    value: Any = document
    for component in path.split("."):
        value = value[component]
    return value


def _artifact_hash(run: Path, relative: str) -> str:
    path = run / relative
    if not path.is_file():
        raise ValueError(f"run artifact is missing: {relative}")
    return _file_sha256(path)


def _load_state(run: Path, name: str) -> dict[str, Any]:
    run = Path(run)
    manifest_path = run / "manifest.json"
    _validate_source_root(run)
    prevalidated_manifest = _load_json(manifest_path, label=f"{name} source manifest")
    if not isinstance(prevalidated_manifest, dict):
        raise ValueError(f"{name} source manifest must be a JSON object")
    _validate_source_tree_seal(run, prevalidated_manifest)
    manifest, artifact_paths = validate_completed_run_manifest(run)
    if manifest.get("run_id") != run.name:
        raise ValueError(f"{name} run ID differs from its directory name")
    if "merged/segments.json" not in artifact_paths:
        raise ValueError(f"{name} merged transcript is unlisted in manifest")
    _validate_completed_source_coverage(manifest)
    _validate_canonical_source_artifacts(manifest, artifact_paths)

    merged_path = run / "merged/segments.json"
    merged = _load_json(merged_path, label=f"{name} merged transcript")
    merged = validate_segments_document(
        merged, label=f"{name} merged transcript"
    )
    source = merged.get("source")
    if not isinstance(source, dict):
        raise ValueError(f"{name} merged transcript has no source identity")
    if source.get("file_name") != manifest.get("input", {}).get("file_name"):
        raise ValueError(f"{name} merged source file differs from its manifest")
    if source.get("sha256") != manifest.get("input", {}).get("sha256"):
        raise ValueError(f"{name} merged source hash differs from its manifest")
    input_duration = manifest.get("coverage", {}).get("input_duration_s")
    if not isinstance(input_duration, (int, float)) or isinstance(input_duration, bool):
        raise ValueError(f"{name} manifest has no numeric input duration")
    if abs(float(source.get("duration_s", -1)) - float(input_duration)) > 0.01:
        raise ValueError(f"{name} merged source duration differs from its manifest")

    requirement = STATE_REQUIREMENTS[name]
    glossary = manifest.get("glossary")
    if not isinstance(glossary, dict):
        raise ValueError(f"{name} manifest has no glossary record")
    glossary_enabled = (
        glossary.get("provided") is True and glossary.get("applied") is True
    )
    glossary_absent = (
        glossary.get("provided") is False
        and glossary.get("applied") is False
        and glossary.get("sha256") is None
        and glossary.get("item_count") == 0
        and glossary.get("injection_mode") == "none"
    )
    if requirement["decode_glossary"] and not glossary_enabled:
        raise ValueError(f"{name} glossary must be provided and applied at decode time")
    if not requirement["decode_glossary"] and not glossary_absent:
        raise ValueError(f"{name} glossary must be absent from decode-time ASR")

    if manifest.get("postprocess") is not None:
        raise ValueError(f"{name} source run unexpectedly has postprocess metadata")
    legacy_postprocess = run / "postprocess"
    if legacy_postprocess.exists() or legacy_postprocess.is_symlink():
        raise ValueError(f"{name} source run contains mutable root postprocess output")

    models = manifest.get("models")
    if not isinstance(models, list):
        raise ValueError(f"{name} manifest has no model list")
    asr_models = [model for model in models if model.get("role") == "asr"]
    if not asr_models:
        raise ValueError(f"{name} manifest has no ASR model provenance")
    model_identities = [
        (
            model.get("role"),
            model.get("hf_model_id"),
            model.get("revision"),
            model.get("quantization"),
        )
        for model in models
    ]
    if len(set(model_identities)) != len(model_identities):
        raise ValueError(f"{name} manifest has duplicate model identities")
    for field in ("backend", "preprocessing", "chunk_boundaries", "coverage"):
        if field not in manifest:
            raise ValueError(f"{name} manifest has no {field} record")

    return {
        "run": run,
        "manifest": manifest,
        "manifest_sha256": _file_sha256(manifest_path),
        "merged": merged,
        "source": source,
        "compatibility": {
            "models": sorted(model_identities),
            "backend": manifest["backend"],
            "preprocessing": manifest["preprocessing"],
            "chunk_policy": {
                "boundaries": manifest["chunk_boundaries"],
                "strategy": manifest["coverage"].get("strategy"),
                "chunks_planned": manifest["coverage"].get("chunks_planned"),
            },
        },
    }


def _validate_across_states(states: dict[str, dict[str, Any]]) -> None:
    baseline = states["no_glossary"]
    for name, state in states.items():
        if state["source"] != baseline["source"]:
            raise ValueError(f"{name} has a different source identity")
        if state["compatibility"] != baseline["compatibility"]:
            raise ValueError(
                f"{name} has incompatible ASR, backend, preprocessing, or chunk policy"
            )

    decode_hash = states["decode_glossary"]["manifest"]["glossary"].get(
        "sha256"
    )
    if not isinstance(decode_hash, str):
        raise ValueError("decode glossary source has no glossary hash")


def _correct_to_incorrect(direction: dict[str, Any]) -> int:
    count = 0
    for segment in direction.get("segments", []):
        raw = segment.get("raw", {})
        corrected = segment.get("corrected", {})
        if (
            raw.get("cer_errors") == 0
            and raw.get("wer_errors") == 0
            and (
                int(corrected.get("cer_errors", 0)) > 0
                or int(corrected.get("wer_errors", 0)) > 0
            )
        ):
            count += 1
    return count


def _corrected_state_result(
    state: dict[str, Any],
    derived_id: str,
    reference_path: Path,
    terms_path: Path,
) -> dict[str, Any]:
    run = state["run"]
    scored = score_corrected_run(
        run, reference_path, terms_path, derived_id=derived_id
    )
    scores = scored["scores"]
    outcomes = scored["correction_outcomes"]
    direction = scored["applied_correction_direction"]
    corrected_relative = f"derived/{derived_id}/postprocess/segments.json"
    conflicts_relative = f"derived/{derived_id}/postprocess/conflicts.json"
    activity = {
        "applied": outcomes["applied_text_changes"],
        "review": outcomes["flagged_for_review"],
        "total_proposals": outcomes["observable_proposal_outcomes"],
        "applied_fraction": outcomes["applied_fraction"],
        "review_fraction": outcomes["review_fraction"],
        "applied_count_basis": outcomes["applied_count_basis"],
    }
    effects = {
        "alignment_method": direction["alignment_method"],
        "classification_method": direction["classification_method"],
        "aligned": direction["evaluated_applied_text_changes"],
        "unscorable": direction["unevaluated_applied_text_changes"],
        "closer": direction["closer"],
        "worse": direction["further"],
        "mixed": direction["mixed"],
        "unchanged": direction["unchanged"],
        "correct_to_incorrect": (
            None
            if direction["unevaluated_applied_text_changes"]
            else _correct_to_incorrect(direction)
        ),
        "observed_correct_to_incorrect": _correct_to_incorrect(direction),
        "correction_made_worse_count": direction[
            "correction_made_worse_count"
        ],
        "details": direction["segments"],
        "unscorable_details": direction.get("unevaluated_segments", []),
    }
    return {
        "run_id": state["manifest"]["run_id"],
        "manifest_sha256": state["manifest_sha256"],
        "derived_id": derived_id,
        "derived_manifest_sha256": scored["run"]["derived_manifest_sha256"],
        "operation": scored["run"]["operation"],
        "postprocess_identity": scored["run"]["postprocess_identity"],
        "selected_output": "corrected",
        "raw": {
            "artifact": "merged/segments.json",
            "sha256": _artifact_hash(run, "merged/segments.json"),
            "metrics": scores["raw"],
        },
        "corrected": {
            "artifact": corrected_relative,
            "sha256": _artifact_hash(run, corrected_relative),
            "conflicts_sha256": _artifact_hash(run, conflicts_relative),
            "metrics": scores["corrected"],
        },
        "correction_activity": activity,
        "correction_effects": effects,
    }


def _raw_state_result(
    state: dict[str, Any],
    reference: dict[str, Any],
    terms: list[dict[str, object]],
) -> dict[str, Any]:
    run = state["run"]
    return {
        "run_id": state["manifest"]["run_id"],
        "manifest_sha256": state["manifest_sha256"],
        "selected_output": "raw",
        "raw": {
            "artifact": "merged/segments.json",
            "sha256": _artifact_hash(run, "merged/segments.json"),
            "metrics": _score_document(reference, state["merged"], terms),
        },
        "corrected": None,
        "correction_activity": None,
        "correction_effects": None,
    }


def _metric_delta(
    baseline: float | int | None,
    candidate: float | int | None,
    *,
    better_when: str,
) -> dict[str, Any]:
    if baseline is None or candidate is None:
        return {
            "baseline": baseline,
            "candidate": candidate,
            "candidate_minus_baseline": None,
            "better_when": better_when,
            "improvement": None,
            "status": "unavailable",
        }
    difference = candidate - baseline
    improvement = difference if better_when == "higher" else -difference
    if improvement > 0:
        status = "improved"
    elif improvement < 0:
        status = "regressed"
    else:
        status = "unchanged"
    return {
        "baseline": baseline,
        "candidate": candidate,
        "candidate_minus_baseline": difference,
        "better_when": better_when,
        "improvement": improvement,
        "status": status,
    }


def _metrics_for_endpoint(
    states: dict[str, dict[str, Any]], endpoint: dict[str, str]
) -> dict[str, Any]:
    output = states[endpoint["state"]][endpoint["output"]]
    if not isinstance(output, dict):
        raise ValueError(f"state endpoint has no {endpoint['output']} output")
    return output["metrics"]


def _build_comparisons(
    states: dict[str, dict[str, Any]],
) -> dict[str, dict[str, Any]]:
    comparisons: dict[str, dict[str, Any]] = {}
    for name, (baseline_endpoint, candidate_endpoint) in COMPARISON_ENDPOINTS.items():
        baseline_metrics = _metrics_for_endpoint(states, baseline_endpoint)
        candidate_metrics = _metrics_for_endpoint(states, candidate_endpoint)
        metric_deltas = {
            metric: _metric_delta(
                _path_value(baseline_metrics, metric),
                _path_value(candidate_metrics, metric),
                better_when=direction,
            )
            for metric, direction in METRIC_DIRECTIONS.items()
        }
        for metric in ("cer.error_rate", "wer.error_rate"):
            family = metric.split(".", 1)[0]
            baseline_score = baseline_metrics[family]
            candidate_score = candidate_metrics[family]
            denominator = baseline_score["reference_units"]
            if denominator and denominator == candidate_score["reference_units"]:
                improvement = (
                    baseline_score["errors"] - candidate_score["errors"]
                ) / denominator
                metric_deltas[metric]["improvement"] = improvement
                metric_deltas[metric]["status"] = (
                    "improved"
                    if improvement > 0
                    else "regressed"
                    if improvement < 0
                    else "unchanged"
                )
        comparisons[name] = {
            "baseline": baseline_endpoint,
            "candidate": candidate_endpoint,
            "metrics": metric_deltas,
        }
    return comparisons


def _threshold_leaves(thresholds: dict[str, Any]) -> list[Any]:
    values: list[Any] = []
    comparisons = thresholds.get("comparisons")
    guardrails = thresholds.get("guardrails")
    if not isinstance(comparisons, dict) or not isinstance(guardrails, dict):
        raise ValueError("thresholds must define comparisons and guardrails")
    if set(comparisons) != set(COMPARISON_ENDPOINTS):
        raise ValueError("threshold comparison set does not match the harness")
    for name, metrics in comparisons.items():
        if not isinstance(metrics, dict) or set(metrics) != set(METRIC_DIRECTIONS):
            raise ValueError(f"threshold metrics are incomplete for {name}")
        for metric, specification in metrics.items():
            if not isinstance(specification, dict):
                raise ValueError(f"threshold for {name}.{metric} is not an object")
            if specification.get("better_when") != METRIC_DIRECTIONS[metric]:
                raise ValueError(f"threshold direction is invalid for {name}.{metric}")
            values.append(specification.get("minimum_improvement"))
    expected_guardrails = {
        "decode_glossary_corrected.correct_to_incorrect",
        "no_glossary_corrected.correct_to_incorrect",
    }
    if set(guardrails) != expected_guardrails:
        raise ValueError("threshold guardrail set does not match the harness")
    for name, specification in guardrails.items():
        if not isinstance(specification, dict):
            raise ValueError(f"threshold guardrail {name} is not an object")
        values.append(specification.get("maximum_count"))
    return values


def _evaluate_thresholds(
    thresholds: dict[str, Any],
    comparisons: dict[str, dict[str, Any]],
    states: dict[str, dict[str, Any]],
) -> tuple[str, bool | None, dict[str, Any]]:
    if thresholds.get("schema_version") != SCHEMA_VERSION:
        raise ValueError("threshold schema version is unsupported")
    status = thresholds.get("status")
    leaves = _threshold_leaves(thresholds)
    if status == "placeholder":
        if any(value is not None for value in leaves):
            raise ValueError("placeholder thresholds must all be null")
        return "not_configured", None, {
            "status": "not_configured",
            "passed": None,
            "checks": [],
        }
    if status != "configured":
        raise ValueError("threshold status must be placeholder or configured")
    if any(value is None for value in leaves):
        raise ValueError("configured thresholds must not contain null")

    checks: list[dict[str, Any]] = []
    for comparison_name, metrics in thresholds["comparisons"].items():
        for metric, specification in metrics.items():
            observed = comparisons[comparison_name]["metrics"][metric][
                "improvement"
            ]
            minimum = specification["minimum_improvement"]
            passed = observed is not None and observed >= minimum
            checks.append(
                {
                    "kind": "minimum_improvement",
                    "comparison": comparison_name,
                    "metric": metric,
                    "observed": observed,
                    "threshold": minimum,
                    "passed": passed,
                }
            )
    for path, specification in thresholds["guardrails"].items():
        state_name, _ = path.split(".", 1)
        effects = states[state_name]["correction_effects"]
        observed = effects["correct_to_incorrect"]
        unscorable = effects["unscorable"]
        maximum = specification["maximum_count"]
        if unscorable > 0:
            check_passed = False
            reason = "unscorable > 0"
        elif observed is None:
            check_passed = False
            reason = "safety count unavailable"
        else:
            check_passed = observed <= maximum
            reason = None
        checks.append(
            {
                "kind": "maximum_count",
                "guardrail": path,
                "observed": observed,
                "unscorable": unscorable,
                "threshold": maximum,
                "passed": check_passed,
                "reason": reason,
            }
        )
    passed = all(check["passed"] for check in checks)
    return ("passed" if passed else "failed"), passed, {
        "status": "configured",
        "passed": passed,
        "checks": checks,
    }


def compare_correction_paths(
    *,
    reference_path: Path,
    terms_path: Path,
    no_glossary_run: Path,
    decode_glossary_run: Path,
    decode_glossary_derived_id: str,
    no_glossary_derived_id: str,
    thresholds_path: Path,
) -> dict[str, Any]:
    reference_path = Path(reference_path)
    terms_path = Path(terms_path)
    thresholds_path = Path(thresholds_path)
    reference = _load_json(reference_path, label="reference")
    terms = _load_json(terms_path, label="terms")
    thresholds = _load_json(thresholds_path, label="thresholds")
    if not isinstance(reference, dict) or not isinstance(
        reference.get("segments"), list
    ):
        raise ValueError("reference must be a segment document")
    reference = _validate_reference_document(reference)
    if not isinstance(terms, list) or not all(
        isinstance(term, dict) for term in terms
    ):
        raise ValueError("terms must be an array of objects")
    if not isinstance(thresholds, dict):
        raise ValueError("thresholds must be an object")

    state_inputs = {
        "no_glossary": Path(no_glossary_run),
        "decode_glossary": Path(decode_glossary_run),
    }
    loaded = {
        name: _load_state(run, name) for name, run in state_inputs.items()
    }
    _validate_across_states(loaded)
    if reference.get("source") != loaded["no_glossary"]["source"]:
        raise ValueError("reference source identity differs from both verified source runs")

    states = {
        "no_glossary": _raw_state_result(
            loaded["no_glossary"], reference, terms
        ),
        "decode_glossary": _raw_state_result(
            loaded["decode_glossary"], reference, terms
        ),
        "decode_glossary_corrected": _corrected_state_result(
            loaded["decode_glossary"],
            decode_glossary_derived_id,
            reference_path,
            terms_path,
        ),
        "no_glossary_corrected": _corrected_state_result(
            loaded["no_glossary"],
            no_glossary_derived_id,
            reference_path,
            terms_path,
        ),
    }
    corrected_states = (
        states["decode_glossary_corrected"],
        states["no_glossary_corrected"],
    )
    if corrected_states[0]["operation"] != corrected_states[1]["operation"]:
        raise ValueError("selected derived corrections have mismatched operation profiles")
    decode_glossary = loaded["decode_glossary"]["manifest"]["glossary"]
    operation = corrected_states[0]["operation"]
    if (
        operation.get("glossary_sha256"),
        operation.get("glossary_item_count"),
    ) != (decode_glossary.get("sha256"), decode_glossary.get("item_count")):
        raise ValueError(
            "selected correction glossary differs from the decode-time glossary"
        )
    identity_fields = (
        "backend",
        "model_id",
        "model_revision",
        "quantization",
        "input_mode",
    )
    identities = [
        {field: state["postprocess_identity"].get(field) for field in identity_fields}
        for state in corrected_states
    ]
    if identities[0] != identities[1]:
        raise ValueError("selected derived corrections have mismatched model identities")
    policy_fields = (
        "maximum_prompt_utf8_bytes",
        "maximum_segments_per_batch",
        "maximum_output_tokens",
        "output_token_limit_status",
        "output_token_planning_budget",
        "output_tokens_per_input_utf8_byte_permille",
        "base_output_token_reserve",
        "per_segment_output_token_reserve",
    )
    policies = [
        {
            field: state["postprocess_identity"]["batching"].get(field)
            for field in policy_fields
        }
        for state in corrected_states
    ]
    if policies[0] != policies[1]:
        raise ValueError("selected derived corrections use mismatched batching policies")
    comparisons = _build_comparisons(states)
    status, passed, threshold_evaluation = _evaluate_thresholds(
        thresholds, comparisons, states
    )
    return {
        "schema_version": SCHEMA_VERSION,
        "status": status,
        "passed": passed,
        "inputs": {
            "reference_sha256": _file_sha256(reference_path),
            "terms_sha256": _file_sha256(terms_path),
            "thresholds_sha256": _file_sha256(thresholds_path),
        },
        "states": states,
        "comparisons": comparisons,
        "threshold_evaluation": threshold_evaluation,
    }


def _parse_arguments(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare decode-time glossary injection and correction"
    )
    parser.add_argument("--reference", required=True, type=Path)
    parser.add_argument("--terms", required=True, type=Path)
    parser.add_argument("--no-glossary-run", required=True, type=Path)
    parser.add_argument("--decode-glossary-run", required=True, type=Path)
    parser.add_argument("--decode-glossary-derived-id", required=True)
    parser.add_argument("--no-glossary-derived-id", required=True)
    parser.add_argument("--thresholds", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    arguments = _parse_arguments(sys.argv[1:] if argv is None else argv)
    _reject_output_within_inputs(
        arguments.output,
        [
            arguments.no_glossary_run,
            arguments.decode_glossary_run,
            arguments.no_glossary_run
            / "derived"
            / arguments.no_glossary_derived_id,
            arguments.decode_glossary_run
            / "derived"
            / arguments.decode_glossary_derived_id,
        ],
    )
    if arguments.output.exists() or arguments.output.is_symlink():
        raise FileExistsError(
            f"create-only comparison output exists: {arguments.output}"
        )
    verdict = compare_correction_paths(
        reference_path=arguments.reference,
        terms_path=arguments.terms,
        no_glossary_run=arguments.no_glossary_run,
        decode_glossary_run=arguments.decode_glossary_run,
        decode_glossary_derived_id=arguments.decode_glossary_derived_id,
        no_glossary_derived_id=arguments.no_glossary_derived_id,
        thresholds_path=arguments.thresholds,
    )
    encoded = json.dumps(
        verdict, ensure_ascii=False, indent=2, sort_keys=True
    ) + "\n"
    arguments.output.parent.mkdir(parents=True, exist_ok=True)
    with arguments.output.open("x", encoding="utf-8") as output:
        output.write(encoded)
    print(json.dumps(verdict, ensure_ascii=False, sort_keys=True))
    if verdict["passed"] is False:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
