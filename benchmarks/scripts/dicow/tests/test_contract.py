from __future__ import annotations

import hashlib
import json
import os
import tempfile
import unittest
from copy import deepcopy
from pathlib import Path
from unittest import mock

from benchmarks.scripts.dicow import run_with_env
from benchmarks.scripts.dicow.common import manifest, pins
from benchmarks.scripts.scoring.speaker_attributed import (
    derive_frozen_mapping,
    score_empty_reference_diagnostic,
    score_target,
)


_REAL_VERIFY_R2_TASK_STATE = manifest.verify_r2_task_state


def _sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


class PinTests(unittest.TestCase):
    def test_frontier_and_qwen_sets_are_exact(self) -> None:
        self.assertEqual(len(pins.REQUIRED_FRONTIER_FAMILIES), 16)
        self.assertEqual(len(set(pins.REQUIRED_FRONTIER_FAMILIES)), 16)
        self.assertEqual(pins.QWEN_BRANCH_KINDS, ("asr", "audio", "omni"))
        self.assertEqual(len(pins.QWEN_SEED_NAMES), 6)
        self.assertEqual(pins.MAX_FRONTIER_CAPTURE_AGE_SECONDS, 21_600)

    def test_exact_model_and_experiment_pins(self) -> None:
        self.assertEqual(
            pins.MODEL_PINS["dicow"]["revision"],
            "99c64e8dc409a158816e808a1ee556cdfd0af51c",
        )
        self.assertEqual(
            pins.MODEL_PINS["dicow"]["model_file"]["sha256"],
            "bc3ff21a41ebdb9dbe637815740c4edcf77bfbfe962c601ca33071340fd77bd9",
        )
        self.assertEqual(pins.GRAPH_PINS["fddt_channel_order"], (
            "silence", "target", "non_target", "overlap"
        ))
        self.assertNotIn("ctc_weight", pins.GRAPH_PINS)
        self.assertEqual(pins.GRAPH_PINS["model_config_ctc_weight"], 0.3)
        self.assertEqual(pins.GRAPH_PINS["generation_config_ctc_weight"], 0.0)
        self.assertEqual(pins.GRAPH_PINS["ctc_tensor_names"], (
            "model.encoder.additional_self_attention_layer.k_proj.weight",
            "model.encoder.additional_self_attention_layer.out_proj.bias",
            "model.encoder.additional_self_attention_layer.out_proj.weight",
            "model.encoder.additional_self_attention_layer.q_proj.bias",
            "model.encoder.additional_self_attention_layer.q_proj.weight",
            "model.encoder.additional_self_attention_layer.v_proj.bias",
            "model.encoder.additional_self_attention_layer.v_proj.weight",
            "model.encoder.lm_head.weight",
            "model.encoder.subsample_conv1.weight",
            "model.encoder.subsample_conv2.weight",
        ))
        self.assertEqual(pins.EXPERIMENT_PINS["bootstrap_seed"], 20_260_830)
        self.assertEqual(pins.EXPERIMENT_PINS["bootstrap_cluster_unit"], "constructed_window")
        self.assertEqual(pins.EXPERIMENT_PINS["concurrent_model_processes"], 1)
        self.assertEqual(pins.PROMPT_BUDGET_PINS["pass_order"][0], "prompt_off_complete")
        self.assertEqual(pins.PHASE_A_THRESHOLDS["S4"]["mean_G_oracle_O_min"], "0.10")
        self.assertEqual(
            pins.PHASE_A_THRESHOLDS["S4"]["target_character_preservation_oracle_point_min"],
            "0.75",
        )
        self.assertEqual(
            pins.PHASE_A_THRESHOLDS["S4"]["target_character_preservation_oracle_lower_min"],
            "0.75",
        )
        self.assertEqual(
            pins.PHASE_A_THRESHOLDS["S5"]["target_character_preservation_community1_point_min"],
            "0.75",
        )
        self.assertEqual(
            pins.PHASE_A_THRESHOLDS["S5"]["target_character_preservation_community1_lower_min"],
            "0.75",
        )
        self.assertEqual(pins.PHASE_A_THRESHOLDS["S7b"]["lower_bound"], ">-0.02")
        self.assertEqual(pins.PHASE_B_THRESHOLDS["G5"]["mask_sensitivity_ratio_max"], "2.0")


class FableVerificationTests(unittest.TestCase):
    @staticmethod
    def _reseal_j1_input(evidence: Path, key: str) -> None:
        root = evidence.parent
        provenance_path = evidence / "fable-provenance.json"
        provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
        if key not in provenance["artifact_paths"]:
            raise AssertionError("unknown J1 fixture key {}".format(key))
        for name, raw_path in provenance["artifact_paths"].items():
            if name in ("plan_contract", "j1_readiness"):
                continue
            if Path(raw_path).is_absolute():
                path = Path(raw_path)
            else:
                evidence_path = evidence / raw_path
                path = evidence_path if evidence_path.is_file() else root / raw_path
            provenance["input_hashes"][name] = _sha(path)
        readiness_path = root / provenance["artifact_paths"]["j1_readiness"]
        readiness = json.loads(readiness_path.read_text(encoding="utf-8"))
        readiness["input_hashes"] = {
            name: value for name, value in provenance["input_hashes"].items()
            if name != "j1_readiness"
        }
        _write_json(readiness_path, readiness)
        provenance["input_hashes"]["j1_readiness"] = _sha(readiness_path)
        prompt_path = evidence / "fable-prompt.txt"
        prompt_path.write_text(
            manifest._canonical_j1_prompt(
                provenance["artifact_paths"], provenance["input_hashes"],
                evidence, root,
                json.loads((root / "run-manifest.json").read_text())["plan_contract_bytes"],
            ),
            encoding="utf-8",
        )
        provenance["prompt_sha256"] = _sha(prompt_path)
        _write_json(provenance_path, provenance)

    @staticmethod
    def _turn_frontier_into_typed_failure(evidence: Path) -> None:
        root = evidence.parent
        capture_path = evidence / "source-capture-manifest.json"
        capture_manifest = json.loads(capture_path.read_text())
        capture = capture_manifest["captures"][0]
        capture.update({"success": False, "status": 599})
        replay_record_path = evidence / capture["replay_record_path"]
        replay_record = json.loads(replay_record_path.read_text())
        replay_record.update({"success": False, "status": 599})
        _write_json(replay_record_path, replay_record)
        replay_provenance_path = evidence / capture_manifest["replay_provenance_path"]
        replay_provenance = json.loads(replay_provenance_path.read_text())
        replay_provenance.update({
            "failure_count": 1, "failure_paths": [capture["capture_path"]],
            "records": [replay_record],
        })
        _write_json(replay_provenance_path, replay_provenance)
        capture_manifest["replay_provenance_sha256"] = _sha(replay_provenance_path)
        _write_json(capture_path, capture_manifest)

        ledger_path = evidence / "frontier-ledger.json"
        ledger = json.loads(ledger_path.read_text())
        ledger["source_captures"] = [deepcopy(capture)]
        for family in ledger["families"]:
            family["official_sources"] = [deepcopy(capture)]
        for branch in ledger["qwen_branches"]:
            branch["official_source"] = deepcopy(capture)
        ledger["replay_status"].update({
            "outcome": "evidence_blocker", "transport_failure_count": 1,
        })
        _write_json(ledger_path, ledger)
        query_path = evidence / "query-manifest.json"
        query = json.loads(query_path.read_text())
        query["replay_status"].update({
            "outcome": "evidence_blocker", "transport_failure_count": 1,
            "source_capture_manifest_sha256": _sha(capture_path),
        })
        _write_json(query_path, query)
        delta_path = evidence / "frontier-delta.json"
        delta = json.loads(delta_path.read_text())
        delta["current_frontier_ledger_sha256"] = _sha(ledger_path)
        _write_json(delta_path, delta)

        decision_path = evidence / "fable-decision.json"
        decision = json.loads(decision_path.read_text())
        decision.update({
            "decision": "revise", "evidence_outcome": "evidence_blocker",
            "next_task_ids": [], "skip_tasks": [],
        })
        _write_json(decision_path, decision)
        raw_path = evidence / "fable-raw.json"
        raw = json.loads(raw_path.read_text())
        raw["result"] = json.dumps(decision, sort_keys=True)
        _write_json(raw_path, raw)
        provenance_path = evidence / "fable-provenance.json"
        provenance = json.loads(provenance_path.read_text())
        provenance.update({
            "decision": "revise", "evidence_outcome": "evidence_blocker",
            "next_task_ids": [], "skip_tasks": [],
            "raw_result_sha256": _sha(raw_path),
            "parsed_decision_sha256": _sha(decision_path),
            "source_capture_manifest_sha256": _sha(capture_path),
            "query_manifest_sha256": _sha(query_path),
            "frontier_ledger_sha256": _sha(ledger_path),
            "frontier_delta_sha256": _sha(delta_path),
        })
        for key, path in (
            ("source_capture_manifest", capture_path), ("query_manifest", query_path),
            ("frontier_ledger", ledger_path), ("frontier_delta", delta_path),
        ):
            provenance["input_hashes"][key] = _sha(path)
        readiness_path = root / provenance["artifact_paths"]["j1_readiness"]
        readiness = json.loads(readiness_path.read_text())
        readiness["input_hashes"] = {
            key: value for key, value in provenance["input_hashes"].items()
            if key != "j1_readiness"
        }
        _write_json(readiness_path, readiness)
        provenance["input_hashes"]["j1_readiness"] = _sha(readiness_path)
        prompt_path = evidence / "fable-prompt.txt"
        prompt_path.write_text(
            manifest._canonical_j1_prompt(
                provenance["artifact_paths"], provenance["input_hashes"],
                evidence, root,
                json.loads((root / "run-manifest.json").read_text())["plan_contract_bytes"],
            ),
            encoding="utf-8",
        )
        provenance["prompt_sha256"] = _sha(prompt_path)
        _write_json(provenance_path, provenance)

    def _fixture(self, root: Path, stale: bool = False, usage_key: str = "claude-fable-5") -> Path:
        evidence = root / "fable-j1"
        captures_dir = evidence / "source-captures"
        captures_dir.mkdir(parents=True)
        source = captures_dir / "source.txt"
        source.write_text("official source\n", encoding="utf-8")
        capture = {
            "url": "https://example.test/official",
            "effective_url": "https://example.test/official",
            "capture_path": "source-captures/source.txt",
            "replay_record_path": "replay-records/source.json",
            "sha256": _sha(source),
            "bytes": source.stat().st_size,
            "captured_at_utc": "2026-08-29T00:00:00Z" if stale else "2026-08-30T11:00:00Z",
            "role": "primary_or_official_registry_capture",
            "status": 200,
            "success": True,
            "transport": "curl-https",
        }
        queries = []
        families = []
        for index, family_name in enumerate(pins.REQUIRED_FRONTIER_FAMILIES):
            queries.append({
                "query_id": "Q{:02d}".format(index + 1),
                "family": family_name,
                "branch": "discovery",
                "registry_url": capture["url"],
                "query": "family={}".format(family_name),
                "queried_at_utc": "2026-08-30T11:30:00Z",
                "included": ["{}/current".format(family_name)],
                "excluded": [{"result": "old", "reason": "superseded"}],
            })
            families.append({
                "family": family_name,
                "query_utc": "2026-08-30T11:30:00Z",
                "latest_checkpoint": "{}/current".format(family_name),
                "release_date": "2026-08-30",
                "exact_revision": "revision-{}".format(family_name),
                "license": "test-license",
                "predecessor": "none",
                "non_dominated_disposition": {"decision": "retain", "reason": "fixture"},
                "official_sources": [capture],
                "apple_paths": [],
                "pillar_evidence": {"P1": {}, "P2": {}, "P4": {}},
                "conversion_feasibility": {"status": "unknown"},
                "maccheroni_role": "fixture",
                "included": [],
                "excluded": [],
            })
        query_seed_records = [
            {"name": name, "official_query": "https://example.test/seed/{}".format(index)}
            for index, name in enumerate(pins.QWEN_SEED_NAMES)
        ]
        ledger_seed_records = []
        for seed in query_seed_records:
            record = dict(seed)
            record["status"] = "current"
            ledger_seed_records.append(record)
        query_manifest = {
            "schema_version": "frontier-query-manifest-v1",
            "search_cutoff_utc": "2026-08-30T11:30:00Z",
            "required_roster": list(pins.REQUIRED_FRONTIER_FAMILIES),
            "qwen_seed_names": list(pins.QWEN_SEED_NAMES),
            "qwen_seed_queries": query_seed_records,
            "queries": queries,
            "replay_policy": "replay every exact query",
        }
        capture_manifest = {
            "schema_version": "source-capture-manifest-v1",
            "search_cutoff_utc": "2026-08-30T11:30:00Z",
            "capture_count": 1,
            "captures": [capture],
            "policy": "official sources with frozen bytes",
            "fail_closed": True,
        }
        ledger = {
            "schema_version": "frontier-ledger-v1",
            "search_cutoff_utc": "2026-08-30T11:30:00Z",
            "required_roster": list(pins.REQUIRED_FRONTIER_FAMILIES),
            "qwen_branches": [
                {
                    "kind": kind,
                    "official_source": capture,
                    "query_utc": "2026-08-30T11:30:00Z",
                    "latest_checkpoint": "qwen/{}".format(kind),
                    "exact_revision": "rev-{}".format(kind),
                    "d37_disposition": "fixture disposition",
                }
                for kind in pins.QWEN_BRANCH_KINDS
            ],
            "qwen_seed_queries": ledger_seed_records,
            "queries": queries,
            "families": families,
            "source_captures": [capture],
            "replay_status": {
                "outcome": "supported",
                "reason": "complete_exact_replay",
                "transport_failure_count": 0,
            },
        }
        query_path = evidence / "query-manifest.json"
        capture_manifest_path = evidence / "source-capture-manifest.json"
        ledger_path = evidence / "frontier-ledger.json"
        replay_record = {
            "source_capture_path": capture["capture_path"],
            "url": capture["url"],
            "effective_url": capture["effective_url"],
            "status": 200,
            "success": True,
            "transport": capture["transport"],
            "sha256": capture["sha256"],
            "bytes": capture["bytes"],
            "captured_at_utc": capture["captured_at_utc"],
        }
        _write_json(evidence / capture["replay_record_path"], replay_record)
        replay_provenance_path = evidence / "replay-provenance.json"
        _write_json(replay_provenance_path, {
            "schema_version": "frontier-replay-v1",
            "fail_closed": True,
            "capture_count": 1,
            "failure_count": 0,
            "failure_paths": [],
            "records": [replay_record],
        })
        capture_manifest["replay_provenance_path"] = replay_provenance_path.name
        capture_manifest["replay_provenance_sha256"] = _sha(replay_provenance_path)
        _write_json(capture_manifest_path, capture_manifest)
        query_manifest["replay_status"] = {
            "capture_count": 1,
            "outcome": "supported",
            "source_capture_manifest_sha256": _sha(capture_manifest_path),
            "transport_failure_count": 0,
        }
        _write_json(query_path, query_manifest)
        _write_json(ledger_path, ledger)
        base_dir = root / "frontier-j0"
        base_query = deepcopy(query_manifest)
        base_query["search_cutoff_utc"] = "2026-08-30T10:00:00Z"
        for query in base_query["queries"]:
            query["queried_at_utc"] = "2026-08-30T10:00:00Z"
        base_ledger = deepcopy(ledger)
        base_ledger["search_cutoff_utc"] = "2026-08-30T10:00:00Z"
        for query in base_ledger["queries"]:
            query["queried_at_utc"] = "2026-08-30T10:00:00Z"
        for family in base_ledger["families"]:
            family["query_utc"] = "2026-08-30T10:00:00Z"
        for branch in base_ledger["qwen_branches"]:
            branch["query_utc"] = "2026-08-30T10:00:00Z"
        base_query_path = base_dir / "query-manifest.json"
        base_ledger_path = base_dir / "frontier-ledger.json"
        base_capture_path = base_dir / "source-capture-manifest.json"
        _write_json(base_query_path, base_query)
        _write_json(base_ledger_path, base_ledger)
        _write_json(base_capture_path, {
            "schema_version": "source-capture-manifest-v1",
            "search_cutoff_utc": "2026-08-30T10:00:00Z",
            "capture_count": 1,
            "captures": [capture],
            "policy": "sealed T0 fixture",
        })
        base_hash = _sha(base_ledger_path)
        delta_path = evidence / "frontier-delta.json"
        _write_json(delta_path, {
            "schema_version": "frontier-delta-v1",
            "base_frontier_ledger_sha256": base_hash,
            "current_frontier_ledger_sha256": _sha(ledger_path),
            "changes": [],
        })
        prompt = evidence / "fable-prompt.txt"
        prompt.write_text("judge the sealed evidence\n", encoding="utf-8")
        decision = {
            "decision": "proceed",
            "evidence_outcome": "supported",
            "decisive_evidence": [],
            "caveats": [],
            "reversal_condition": "new contrary evidence",
            "next_task_ids": ["T9"],
            "skip_tasks": [],
        }
        decision_path = evidence / "fable-decision.json"
        _write_json(decision_path, decision)
        raw = evidence / "fable-raw.json"
        _write_json(raw, {
            "is_error": False,
            "session_id": "session-1",
            "modelUsage": {usage_key: {"canonicalModel": usage_key}},
            "result": json.dumps(decision, sort_keys=True),
        })
        repo = root / "repo"
        plan_path = repo / ".plans" / "dicow-v3-mlx-value-and-parity.md"
        plan_prefix = b"# Synthetic immutable plan\n\ncontract body\n\n"
        plan_path.parent.mkdir(parents=True, exist_ok=True)
        plan_path.write_bytes(plan_prefix + b"## Results\n\nnot in the contract prefix\n")
        plan_sha = hashlib.sha256(plan_prefix).hexdigest()
        run_manifest = {
            "run_id": "run-1",
            "plan_contract": {
                "path": str(plan_path),
                "sha256": plan_sha,
                "bytes": len(plan_prefix),
                "boundary": "bytes-before-final-## Results-heading",
            },
            "plan_contract_sha256": plan_sha,
            "plan_contract_bytes": len(plan_prefix),
            "query_manifest_cutoff_utc": "2026-08-30T10:00:00Z",
            "query_manifest_path": "frontier-j0/query-manifest.json",
            "query_manifest_sha256": _sha(base_query_path),
            "query_manifest_bytes": base_query_path.stat().st_size,
            "frontier_ledger_path": "frontier-j0/frontier-ledger.json",
            "frontier_ledger_sha256": base_hash,
            "frontier_ledger_bytes": base_ledger_path.stat().st_size,
            "source_capture_manifest_path": "frontier-j0/source-capture-manifest.json",
            "source_capture_manifest_sha256": _sha(base_capture_path),
            "source_capture_manifest_bytes": base_capture_path.stat().st_size,
            "tracked_predecessors": {
                "PROJECT.md": {
                    "sha256": hashlib.sha256(b"synthetic PROJECT.md\n").hexdigest(),
                    "bytes": len(b"synthetic PROJECT.md\n"), "mode": "0644",
                },
                "docs/research-digest.md": {
                    "sha256": hashlib.sha256(
                        b"synthetic docs/research-digest.md\n"
                    ).hexdigest(),
                    "bytes": len(b"synthetic docs/research-digest.md\n"), "mode": "0644",
                },
                "docs/dicow-conversion-lane.md": {"absent": True},
            },
            "scoring_lock": {
                "path": str(repo / "benchmarks/scripts/scoring/uv.lock"),
                "sha256": hashlib.sha256(b"synthetic scoring lock\n").hexdigest(),
                "bytes": len(b"synthetic scoring lock\n"), "mode": "0644",
            },
            "host_tools": {
                "hf": {
                    "path": "/synthetic/hf", "realpath": "/synthetic/hf",
                    "sha256": hashlib.sha256(b"synthetic hf\n").hexdigest(),
                    "version": "fixture",
                },
            },
        }
        run_manifest_path = root / "run-manifest.json"
        _write_json(run_manifest_path, run_manifest)

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
        for relative in set(repo_artifacts.values()).union(
            path for values in pins.J1_STATE_REPO_ARTIFACT_PATHS.values() for path in values
        ):
            path = repo / relative
            if not path.exists():
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("synthetic {}\n".format(relative), encoding="utf-8")
        scoring_lock_path = repo / "benchmarks/scripts/scoring/uv.lock"
        scoring_lock_path.parent.mkdir(parents=True, exist_ok=True)
        scoring_lock_path.write_bytes(b"synthetic scoring lock\n")
        base_gate_path = root / "frontier-j0" / "gate.json"
        _write_json(base_gate_path, {"fixture": "sealed J0 gate"})
        source_manifest_path = root / "t2-source-metadata" / "manifest.json"
        _write_json(source_manifest_path, {"fixture": "sealed source manifest"})

        initial_records = []
        for index, name in enumerate((
            "fable-product-result.md", "fable-architecture-result.md",
            "fable-skeptic-result.md", "fable-synthesis-result.md",
        )):
            path = repo / ".plans" / name
            path.write_text("synthetic initial Fable result {}\n".format(index), encoding="utf-8")
            initial_records.append({
                "path": str(path), "session_id": "initial-session-{}".format(index),
                "sha256": _sha(path), "bytes": path.stat().st_size,
            })
        initial_path = root / "frontier-j0" / "initial-fable-inputs.json"
        _write_json(initial_path, {
            "schema_version": "fable-starting-inputs-v1",
            "captured_at_utc": "2026-08-30T10:00:00Z",
            "inputs": initial_records,
        })

        artifact_paths = {
            "query_manifest": query_path.name,
            "frontier_ledger": ledger_path.name,
            "source_capture_manifest": capture_manifest_path.name,
            "frontier_delta": delta_path.name,
            "run_manifest": "run-manifest.json",
            "plan_contract": str(plan_path),
            "t0_initial_fable_inputs": str(initial_path.relative_to(root)),
        }
        for key, relative in repo_artifacts.items():
            artifact_paths[key] = str(repo / relative)
        advisory_names = {
            "advisory_ctc_value": "20260830T0818-contract-value-ctc-review.md",
            "advisory_target_recovery": "20260830T0829-target-recovery-threshold.md",
            "advisory_qwen3tts_value": "20260830T0855-qwen3tts-j1-value.md",
        }
        for key, filename in advisory_names.items():
            path = root / "fable-checkpoints" / filename
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("synthetic advisory {}\n".format(key), encoding="utf-8")
            artifact_paths[key] = str(path.relative_to(root))

        state_specs = (
            ("t0_state", "T0"), ("t1_state", "T1"),
            ("t1_contract_amendment_1", "T1-contract-amendment-1"),
            ("t2_state", "T2"), ("t3_state", "T3"), ("t4_state", "T4"),
            ("t5_state", "T5"), ("t6_state", "T6"), ("t7_state", "T7"),
        )
        state_hashes = {}
        for state_key, task_name in state_specs:
            check_path = root / "task-state" / (task_name + "-check-output.txt")
            check_path.parent.mkdir(parents=True, exist_ok=True)
            check_path.write_text("fresh {} checks passed\n".format(task_name), encoding="utf-8")
            check_path.chmod(0o444)
            artifacts = {
                "check-output": {
                    "path": str(check_path.relative_to(root)), "sha256": _sha(check_path),
                    "bytes": check_path.stat().st_size, "mode": "0444",
                }
            }
            if task_name == "T1":
                artifacts["historical-experiment-schema"] = {
                    "path": "docs/contracts/dicow-experiment.schema.json",
                    "sha256": hashlib.sha256(b"historical T1 schema\n").hexdigest(),
                    "bytes": len(b"historical T1 schema\n"),
                    "mode": "0644",
                }
            if task_name == "T0":
                artifacts["gate.json"] = {
                    "path": "frontier-j0/gate.json", "sha256": _sha(base_gate_path),
                    "bytes": base_gate_path.stat().st_size, "mode": "0644",
                }
            if task_name == "T2":
                artifacts["source-manifest"] = {
                    "path": "t2-source-metadata/manifest.json",
                    "sha256": _sha(source_manifest_path),
                    "bytes": source_manifest_path.stat().st_size, "mode": "0644",
                }
            for relative in pins.J1_STATE_REPO_ARTIFACT_PATHS.get(task_name, ()):
                path = repo / relative
                artifacts[relative.replace("/", "__")] = {
                    "path": relative, "sha256": _sha(path), "bytes": path.stat().st_size,
                    "mode": "0644",
                }
            state_path = root / "task-state" / (task_name + ".json")
            source_input_hashes = {
                key: hashlib.sha256(
                    "{}-source-{}".format(task_name, key).encode("utf-8")
                ).hexdigest()
                for key in pins.J1_STATE_SOURCE_KEYS[task_name]
            }
            if task_name == "T1-contract-amendment-1":
                source_input_hashes = {
                    "T1_state": state_hashes["t1_state"],
                    "plan_contract": plan_sha,
                    "run_manifest": _sha(run_manifest_path),
                    "advisory_ctc_value": _sha(root / artifact_paths["advisory_ctc_value"]),
                    "advisory_target_recovery": _sha(root / artifact_paths["advisory_target_recovery"]),
                    "advisory_qwen3tts_value": _sha(root / artifact_paths["advisory_qwen3tts_value"]),
                }
            elif task_name in ("T4", "T5", "T6", "T7"):
                source_input_hashes = {
                    "T1_contract_amendment_1": state_hashes["t1_contract_amendment_1"]
                }
                if task_name in ("T4", "T6"):
                    source_input_hashes["T2_state"] = state_hashes["t2_state"]
            elif task_name == "T1":
                source_input_hashes.update({
                    "T0_state": state_hashes["t0_state"],
                    "plan_contract": plan_sha,
                    "run_manifest": _sha(run_manifest_path),
                    "J0_gate": _sha(base_gate_path),
                    "scoring_uv_lock": run_manifest["scoring_lock"]["sha256"],
                })
            elif task_name == "T2":
                source_input_hashes.update({
                    "T1_state": state_hashes["t1_state"],
                    "plan_contract": plan_sha,
                    "run_manifest": _sha(run_manifest_path),
                    "aligner_uv_lock": next(
                        record["sha256"] for record in artifacts.values()
                        if record["path"] == "benchmarks/env/dicow-aligner/uv.lock"
                    ),
                    "reference_uv_lock": next(
                        record["sha256"] for record in artifacts.values()
                        if record["path"] == "benchmarks/env/dicow-reference/uv.lock"
                    ),
                    "source_manifest": _sha(source_manifest_path),
                })
            elif task_name == "T3":
                source_input_hashes.update({
                    "T1_state": state_hashes["t1_state"],
                    "plan_contract": plan_sha,
                    "docs/research-digest.md": run_manifest[
                        "tracked_predecessors"
                    ]["docs/research-digest.md"]["sha256"],
                })
            elif task_name == "T0":
                source_input_hashes.update({
                    "plan_contract": plan_sha,
                    "PROJECT.md": run_manifest["tracked_predecessors"]["PROJECT.md"]["sha256"],
                    "docs/research-digest.md": run_manifest["tracked_predecessors"]["docs/research-digest.md"]["sha256"],
                    "docs/dicow-conversion-lane.md": {"absent": True},
                    "scoring_uv_lock": run_manifest["scoring_lock"]["sha256"],
                    "host_hf": run_manifest["host_tools"]["hf"]["sha256"],
                })
            state = {
                "schema_version": "dicow-task-state-v1", "task": task_name,
                "state": "done", "branch_disposition": "executed", "run_id": "run-1",
                "artifacts": artifacts,
                "source_input_hashes": source_input_hashes,
                "run_manifest_path": "run-manifest.json",
                "run_manifest_sha256": _sha(run_manifest_path),
                "fresh_check_output_path": str(check_path.relative_to(root)),
                "fresh_check_output_sha256": _sha(check_path),
            }
            if task_name in ("T1", "T1-contract-amendment-1"):
                lane_path = repo / "docs/dicow-conversion-lane.md"
                lane_tuple = {
                    "sha256": _sha(lane_path), "bytes": lane_path.stat().st_size,
                    "mode": "0644",
                }
                state["tracked_files"] = {
                    "docs/dicow-conversion-lane.md": {
                        "input": (
                            {"absent": True} if task_name == "T1" else deepcopy(lane_tuple)
                        ),
                        "output": deepcopy(lane_tuple),
                    }
                }
            _write_json(state_path, state)
            state_path.chmod(0o444)
            artifact_paths[state_key] = str(state_path.relative_to(root))
            state_hashes[state_key] = _sha(state_path)

        evidence_paths = {
            "query_manifest": query_path,
            "frontier_ledger": ledger_path,
            "source_capture_manifest": capture_manifest_path,
            "frontier_delta": delta_path,
        }
        input_hashes = {}
        for key, raw_path in artifact_paths.items():
            if key == "plan_contract":
                continue
            path = (
                repo / repo_artifacts[key] if key in repo_artifacts
                else evidence_paths.get(key, root / raw_path)
            )
            input_hashes[key] = _sha(path)
        input_hashes["plan_contract"] = plan_sha
        readiness_path = evidence / "j1-readiness.json"
        artifact_paths["j1_readiness"] = str(readiness_path.relative_to(root))
        readiness = {
            "schema_version": "dicow-j1-readiness-v1", "run_id": "run-1",
            "input_hashes": dict(input_hashes), "model_output_count": 0,
            "contract_readiness": 1,
        }
        _write_json(readiness_path, readiness)
        input_hashes["j1_readiness"] = _sha(readiness_path)
        self.assertEqual(set(input_hashes), set(pins.J1_REQUIRED_INPUT_KEYS))
        prompt.write_text(
            manifest._canonical_j1_prompt(
                artifact_paths, input_hashes, evidence, root, len(plan_prefix)
            ),
            encoding="utf-8",
        )

        _write_json(evidence / "fable-provenance.json", {
            "schema_version": "fable-provenance-v1",
            "checkpoint": "J1",
            "requested_model": "fable",
            "actual_model": "claude-fable-5",
            "effort": "max",
            "fallback": False,
            "cli_version": "fixture",
            "session_id": "session-1",
            "session_started_at_utc": "2026-08-30T12:00:00Z",
            "prompt_sha256": _sha(prompt),
            "raw_result_sha256": _sha(raw),
            "parsed_decision_sha256": _sha(decision_path),
            "frontier_ledger_sha256": _sha(ledger_path),
            "query_manifest_sha256": _sha(query_path),
            "source_capture_manifest_sha256": _sha(capture_manifest_path),
            "frontier_delta_sha256": _sha(delta_path),
            "max_capture_age_seconds": 129_600 if stale else 3_600,
            "artifact_paths": artifact_paths,
            "input_hashes": input_hashes,
            "decision": "proceed",
            "evidence_outcome": "supported",
            "evidence": [],
            "caveats": [],
            "next_task_ids": ["T9"],
            "skip_tasks": [],
            "reversal_condition": "new contrary evidence",
        })
        return evidence

    def test_verifies_fresh_complete_fable_package(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            manifest.verify_fable(self._fixture(Path(temporary)))

    def test_frontier_replay_rejects_failures_false_status_and_incomplete_universe(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            evidence = self._fixture(Path(temporary))
            capture_path = evidence / "source-capture-manifest.json"
            capture_manifest = json.loads(capture_path.read_text(encoding="utf-8"))
            capture_manifest["fail_closed"] = False
            _write_json(capture_path, capture_manifest)
            query_path = evidence / "query-manifest.json"
            query = json.loads(query_path.read_text(encoding="utf-8"))
            query["replay_status"]["source_capture_manifest_sha256"] = _sha(capture_path)
            _write_json(query_path, query)
            provenance_path = evidence / "fable-provenance.json"
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            for key, path in (("source_capture_manifest", capture_path), ("query_manifest", query_path)):
                provenance[key + "_sha256"] = _sha(path)
                provenance["input_hashes"][key] = _sha(path)
            _write_json(provenance_path, provenance)
            with self.assertRaisesRegex(manifest.VerificationError, "fail_closed"):
                manifest.verify_fable(evidence)

    def test_frontier_failures_authenticate_only_revise_evidence_blocker(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            evidence = self._fixture(Path(temporary))
            self._turn_frontier_into_typed_failure(evidence)
            manifest.verify_fable(evidence)

            decision_path = evidence / "fable-decision.json"
            decision = json.loads(decision_path.read_text())
            decision.update({
                "decision": "proceed", "evidence_outcome": "supported",
                "next_task_ids": ["T9"],
            })
            _write_json(decision_path, decision)
            raw_path = evidence / "fable-raw.json"
            raw = json.loads(raw_path.read_text())
            raw["result"] = json.dumps(decision, sort_keys=True)
            _write_json(raw_path, raw)
            provenance_path = evidence / "fable-provenance.json"
            provenance = json.loads(provenance_path.read_text())
            provenance.update({
                "decision": "proceed", "evidence_outcome": "supported",
                "next_task_ids": ["T9"], "raw_result_sha256": _sha(raw_path),
                "parsed_decision_sha256": _sha(decision_path),
            })
            _write_json(provenance_path, provenance)
            with self.assertRaisesRegex(manifest.VerificationError, "only revise/evidence_blocker"):
                manifest.verify_fable(evidence)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = self._fixture(root)
            capture_path = evidence / "source-capture-manifest.json"
            capture_manifest = json.loads(capture_path.read_text(encoding="utf-8"))
            changed = capture_manifest["captures"][0]
            changed.update({"success": False, "status": 599})
            _write_json(capture_path, capture_manifest)
            ledger_path = evidence / "frontier-ledger.json"
            ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
            ledger["source_captures"][0] = deepcopy(changed)
            for family in ledger["families"]:
                family["official_sources"] = [deepcopy(changed)]
            for branch in ledger["qwen_branches"]:
                branch["official_source"] = deepcopy(changed)
            _write_json(ledger_path, ledger)
            delta_path = evidence / "frontier-delta.json"
            delta = json.loads(delta_path.read_text(encoding="utf-8"))
            delta["current_frontier_ledger_sha256"] = _sha(ledger_path)
            _write_json(delta_path, delta)
            query_path = evidence / "query-manifest.json"
            query = json.loads(query_path.read_text(encoding="utf-8"))
            query["replay_status"]["source_capture_manifest_sha256"] = _sha(capture_path)
            _write_json(query_path, query)
            provenance_path = evidence / "fable-provenance.json"
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            for key, path in (
                ("source_capture_manifest", capture_path), ("query_manifest", query_path),
                ("frontier_ledger", ledger_path), ("frontier_delta", delta_path),
            ):
                provenance[key + "_sha256"] = _sha(path)
                provenance["input_hashes"][key] = _sha(path)
            _write_json(provenance_path, provenance)
            with self.assertRaisesRegex(manifest.VerificationError, "(?:replay record|failure summary|replay failures)"):
                manifest.verify_fable(evidence)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = self._fixture(root)
            base_path = root / "frontier-j0" / "source-capture-manifest.json"
            base = json.loads(base_path.read_text(encoding="utf-8"))
            omitted = deepcopy(base["captures"][0])
            omitted.update({
                "capture_path": "source-captures/omitted.txt",
                "url": "https://example.test/omitted",
            })
            base["captures"].append(omitted)
            base["capture_count"] = 2
            _write_json(base_path, base)
            run_path = root / "run-manifest.json"
            run = json.loads(run_path.read_text(encoding="utf-8"))
            run["source_capture_manifest_sha256"] = _sha(base_path)
            run["source_capture_manifest_bytes"] = base_path.stat().st_size
            _write_json(run_path, run)
            with self.assertRaisesRegex(manifest.VerificationError, "omitted or relabeled"):
                manifest.verify_fable(evidence)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = self._fixture(root)
            capture_path = evidence / "source-capture-manifest.json"
            capture_manifest = json.loads(capture_path.read_text(encoding="utf-8"))
            capture = capture_manifest["captures"][0]
            capture["transport"] = "fabricated-local"
            replay_path = evidence / capture["replay_record_path"]
            replay = json.loads(replay_path.read_text(encoding="utf-8"))
            replay["transport"] = "fabricated-local"
            _write_json(replay_path, replay)
            replay_provenance_path = evidence / capture_manifest["replay_provenance_path"]
            replay_provenance = json.loads(replay_provenance_path.read_text(encoding="utf-8"))
            replay_provenance["records"] = [deepcopy(replay)]
            _write_json(replay_provenance_path, replay_provenance)
            capture_manifest["replay_provenance_sha256"] = _sha(replay_provenance_path)
            _write_json(capture_path, capture_manifest)
            ledger_path = evidence / "frontier-ledger.json"
            ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
            ledger["source_captures"] = [deepcopy(capture)]
            for family in ledger["families"]:
                family["official_sources"] = [deepcopy(capture)]
            for branch in ledger["qwen_branches"]:
                branch["official_source"] = deepcopy(capture)
            _write_json(ledger_path, ledger)
            query_path = evidence / "query-manifest.json"
            query = json.loads(query_path.read_text(encoding="utf-8"))
            query["replay_status"]["source_capture_manifest_sha256"] = _sha(capture_path)
            _write_json(query_path, query)
            delta_path = evidence / "frontier-delta.json"
            delta = json.loads(delta_path.read_text(encoding="utf-8"))
            delta["current_frontier_ledger_sha256"] = _sha(ledger_path)
            _write_json(delta_path, delta)
            for key in (
                "source_capture_manifest", "query_manifest", "frontier_ledger",
                "frontier_delta",
            ):
                self._reseal_j1_input(evidence, key)
            provenance_path = evidence / "fable-provenance.json"
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            provenance.update({
                "source_capture_manifest_sha256": _sha(capture_path),
                "query_manifest_sha256": _sha(query_path),
                "frontier_ledger_sha256": _sha(ledger_path),
                "frontier_delta_sha256": _sha(delta_path),
            })
            _write_json(provenance_path, provenance)
            with self.assertRaisesRegex(manifest.VerificationError, "unsupported transport"):
                manifest.verify_fable(evidence)

    def test_j1_rejects_plan_initial_state_and_roster_forgery(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            evidence = self._fixture(Path(temporary))
            provenance = json.loads((evidence / "fable-provenance.json").read_text())
            plan_path = Path(provenance["artifact_paths"]["plan_contract"])
            raw = plan_path.read_bytes()
            plan_path.write_bytes(b"X" + raw[1:])
            with self.assertRaisesRegex(manifest.VerificationError, "plan[_ ]contract"):
                manifest.verify_fable(evidence)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = self._fixture(root)
            provenance = json.loads((evidence / "fable-provenance.json").read_text())
            initial_path = root / provenance["artifact_paths"]["t0_initial_fable_inputs"]
            initial = json.loads(initial_path.read_text())
            rogue = root / "rogue-fable.md"
            rogue.write_text("rogue\n", encoding="utf-8")
            initial["inputs"][0].update({
                "path": str(rogue), "sha256": _sha(rogue), "bytes": rogue.stat().st_size,
            })
            _write_json(initial_path, initial)
            self._reseal_j1_input(evidence, "t0_initial_fable_inputs")
            with self.assertRaisesRegex(manifest.VerificationError, "four-result roster"):
                manifest.verify_fable(evidence)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = self._fixture(root)
            provenance = json.loads((evidence / "fable-provenance.json").read_text())
            state_path = root / provenance["artifact_paths"]["t4_state"]
            state_path.chmod(0o644)
            state = json.loads(state_path.read_text())
            state["artifacts"].pop(next(
                key for key in state["artifacts"] if key != "check-output"
            ))
            _write_json(state_path, state)
            state_path.chmod(0o444)
            self._reseal_j1_input(evidence, "t4_state")
            with self.assertRaisesRegex(manifest.VerificationError, "omits a plan-owned"):
                manifest.verify_fable(evidence)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = self._fixture(root)
            provenance = json.loads((evidence / "fable-provenance.json").read_text())
            state_path = root / provenance["artifact_paths"]["t4_state"]
            state_path.chmod(0o644)
            state = json.loads(state_path.read_text())
            state["source_input_hashes"]["T1_contract_amendment_1"] = "0" * 64
            _write_json(state_path, state)
            state_path.chmod(0o444)
            self._reseal_j1_input(evidence, "t4_state")
            with self.assertRaisesRegex(manifest.VerificationError, "exact T1 contract amendment"):
                manifest.verify_fable(evidence)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = self._fixture(root)
            provenance = json.loads((evidence / "fable-provenance.json").read_text())
            state_path = root / provenance["artifact_paths"]["t4_state"]
            state_path.chmod(0o644)
            state = json.loads(state_path.read_text())
            record = next(
                value for value in state["artifacts"].values()
                if value["path"].startswith("benchmarks/")
            )
            record["path"] = "../escaped-artifact"
            _write_json(state_path, state)
            state_path.chmod(0o444)
            with self.assertRaisesRegex(manifest.VerificationError, "(?:escapes allowed root|parent traversal)"):
                self._reseal_j1_input(evidence, "t4_state")

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = self._fixture(root)
            provenance_path = evidence / "fable-provenance.json"
            provenance = json.loads(provenance_path.read_text())
            provenance["input_hashes"].pop("t1_contract_amendment_1")
            _write_json(provenance_path, provenance)
            with self.assertRaisesRegex(manifest.VerificationError, "exact frozen readiness roster"):
                manifest.verify_fable(evidence)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = self._fixture(root)
            provenance = json.loads((evidence / "fable-provenance.json").read_text())
            amendment_path = root / provenance["artifact_paths"]["t1_contract_amendment_1"]
            amendment_path.chmod(0o644)
            amendment = json.loads(amendment_path.read_text())
            amendment.pop("tracked_files")
            _write_json(amendment_path, amendment)
            amendment_path.chmod(0o444)
            self._reseal_j1_input(evidence, "t1_contract_amendment_1")
            with self.assertRaisesRegex(manifest.VerificationError, "tracked_files"):
                manifest.verify_fable(evidence)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = self._fixture(root)
            decoy = root / "not-the-run-manifest.txt"
            decoy.write_text("internally consistent decoy\n", encoding="utf-8")
            provenance_path = evidence / "fable-provenance.json"
            provenance = json.loads(provenance_path.read_text())
            provenance["artifact_paths"]["run_manifest"] = decoy.name
            _write_json(provenance_path, provenance)
            self._reseal_j1_input(evidence, "run_manifest")
            with self.assertRaisesRegex(manifest.VerificationError, "exact run-root"):
                manifest.verify_fable(evidence)

        with tempfile.TemporaryDirectory() as temporary:
            evidence = self._fixture(Path(temporary))
            prompt_path = evidence / "fable-prompt.txt"
            prompt_path.write_text("judge the sealed evidence\n", encoding="utf-8")
            provenance_path = evidence / "fable-provenance.json"
            provenance = json.loads(provenance_path.read_text())
            provenance["prompt_sha256"] = _sha(prompt_path)
            _write_json(provenance_path, provenance)
            with self.assertRaisesRegex(manifest.VerificationError, "exact sealed input"):
                manifest.verify_fable(evidence)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = self._fixture(root)
            provenance = json.loads((evidence / "fable-provenance.json").read_text())
            state_path = root / provenance["artifact_paths"]["t2_state"]
            state_path.chmod(0o644)
            state = json.loads(state_path.read_text())
            state["source_input_hashes"]["unreviewed_extra"] = "0" * 64
            _write_json(state_path, state)
            state_path.chmod(0o444)
            self._reseal_j1_input(evidence, "t2_state")
            with self.assertRaisesRegex(manifest.VerificationError, "dependency keyset"):
                manifest.verify_fable(evidence)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = self._fixture(root)
            provenance = json.loads((evidence / "fable-provenance.json").read_text())
            state_path = root / provenance["artifact_paths"]["t2_state"]
            state_path.chmod(0o644)
            state = json.loads(state_path.read_text())
            state["source_input_hashes"]["aligner_uv_lock"] = "0" * 64
            _write_json(state_path, state)
            state_path.chmod(0o444)
            self._reseal_j1_input(evidence, "t2_state")
            with self.assertRaisesRegex(manifest.VerificationError, "dependency values"):
                manifest.verify_fable(evidence)

        with tempfile.TemporaryDirectory() as temporary:
            evidence = self._fixture(Path(temporary))
            provenance_path = evidence / "fable-provenance.json"
            provenance = json.loads(provenance_path.read_text())
            provenance["artifact_paths"]["advisory_target_recovery"] = (
                provenance["artifact_paths"]["advisory_ctc_value"]
            )
            provenance["input_hashes"]["advisory_target_recovery"] = (
                provenance["input_hashes"]["advisory_ctc_value"]
            )
            _write_json(provenance_path, provenance)
            with self.assertRaisesRegex(manifest.VerificationError, "alias the same artifact"):
                self._reseal_j1_input(evidence, "advisory_target_recovery")

    def test_rejects_stale_capture(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(manifest.VerificationError, "maximum"):
                manifest.verify_fable(self._fixture(Path(temporary), stale=True))

    def test_rejects_fallback_model_usage(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(manifest.VerificationError, "sole key"):
                manifest.verify_fable(
                    self._fixture(Path(temporary), usage_key="claude-sonnet-4-6")
                )

    def test_rejects_forged_provenance_decision(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            evidence = self._fixture(Path(temporary))
            path = evidence / "fable-provenance.json"
            provenance = json.loads(path.read_text(encoding="utf-8"))
            provenance["decision"] = "stop"
            provenance["evidence_outcome"] = "not_supported"
            provenance["skip_tasks"] = ["T{}".format(index) for index in range(9, 29)]
            _write_json(path, provenance)
            with self.assertRaisesRegex(manifest.VerificationError, "authenticated Fable decision"):
                manifest.verify_fable(evidence)

    def test_rejects_duplicate_keys_inside_raw_fable_decision(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            evidence = self._fixture(Path(temporary))
            raw_path = evidence / "fable-raw.json"
            raw = json.loads(raw_path.read_text(encoding="utf-8"))
            raw["result"] = raw["result"].replace(
                '"decision": "proceed"',
                '"decision": "stop", "decision": "proceed"',
                1,
            )
            _write_json(raw_path, raw)
            provenance_path = evidence / "fable-provenance.json"
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            provenance["raw_result_sha256"] = _sha(raw_path)
            _write_json(provenance_path, provenance)
            with self.assertRaisesRegex(manifest.VerificationError, "duplicate object key decision"):
                manifest.verify_fable(evidence)

    def test_rejects_replaced_frozen_query_and_forged_delta(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            evidence = self._fixture(Path(temporary))
            query_path = evidence / "query-manifest.json"
            query = json.loads(query_path.read_text(encoding="utf-8"))
            query["queries"][0]["registry_url"] = "https://attacker.test/replacement"
            _write_json(query_path, query)
            ledger_path = evidence / "frontier-ledger.json"
            ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
            ledger["queries"][0]["registry_url"] = "https://attacker.test/replacement"
            _write_json(ledger_path, ledger)
            delta_path = evidence / "frontier-delta.json"
            delta = json.loads(delta_path.read_text(encoding="utf-8"))
            delta["current_frontier_ledger_sha256"] = _sha(ledger_path)
            _write_json(delta_path, delta)
            provenance_path = evidence / "fable-provenance.json"
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            provenance["query_manifest_sha256"] = _sha(query_path)
            provenance["input_hashes"]["query_manifest"] = _sha(query_path)
            provenance["frontier_ledger_sha256"] = _sha(ledger_path)
            provenance["input_hashes"]["frontier_ledger"] = _sha(ledger_path)
            provenance["frontier_delta_sha256"] = _sha(delta_path)
            provenance["input_hashes"]["frontier_delta"] = _sha(delta_path)
            _write_json(provenance_path, provenance)
            with self.assertRaisesRegex(manifest.VerificationError, "replaced frozen query"):
                manifest.verify_fable(evidence)
        with tempfile.TemporaryDirectory() as temporary:
            evidence = self._fixture(Path(temporary))
            delta_path = evidence / "frontier-delta.json"
            delta = json.loads(delta_path.read_text(encoding="utf-8"))
            delta["changes"] = [{"section": "families", "key": "qwen", "change": "changed"}]
            _write_json(delta_path, delta)
            provenance_path = evidence / "fable-provenance.json"
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            provenance["frontier_delta_sha256"] = _sha(delta_path)
            provenance["input_hashes"]["frontier_delta"] = _sha(delta_path)
            _write_json(provenance_path, provenance)
            with self.assertRaisesRegex(manifest.VerificationError, "recomputed"):
                manifest.verify_fable(evidence)

    def test_rejects_query_timestamp_different_from_refresh_cutoff(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            evidence = self._fixture(Path(temporary))
            query_path = evidence / "query-manifest.json"
            ledger_path = evidence / "frontier-ledger.json"
            query = json.loads(query_path.read_text(encoding="utf-8"))
            ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
            query["queries"][0]["queried_at_utc"] = "2026-08-30T11:29:59Z"
            ledger["queries"][0]["queried_at_utc"] = "2026-08-30T11:29:59Z"
            _write_json(query_path, query)
            _write_json(ledger_path, ledger)
            provenance_path = evidence / "fable-provenance.json"
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            provenance["query_manifest_sha256"] = _sha(query_path)
            provenance["frontier_ledger_sha256"] = _sha(ledger_path)
            provenance["input_hashes"]["query_manifest"] = _sha(query_path)
            provenance["input_hashes"]["frontier_ledger"] = _sha(ledger_path)
            _write_json(provenance_path, provenance)
            with self.assertRaisesRegex(manifest.VerificationError, "fresh search cutoff"):
                manifest.verify_fable(evidence)

    def test_rejects_symlinked_evidence_directory_and_artifact(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = self._fixture(root)
            alias = root / "fable-alias"
            alias.symlink_to(evidence, target_is_directory=True)
            with self.assertRaisesRegex(manifest.VerificationError, "symlink"):
                manifest.verify_fable(alias)
            prompt = evidence / "fable-prompt.txt"
            prompt_target = evidence / "fable-prompt-real.txt"
            prompt.rename(prompt_target)
            prompt.symlink_to(prompt_target.name)
            with self.assertRaisesRegex(manifest.VerificationError, "symlink"):
                manifest.verify_fable(evidence)


class ExperimentContractTests(unittest.TestCase):
    _DOCUMENT_CACHE = None

    @staticmethod
    def _h(label: str) -> str:
        return hashlib.sha256(label.encode("utf-8")).hexdigest()

    def _thresholds(self) -> dict:
        blocker = {"negative_outcome": "evidence_blocker", "bounded_repair_limit": 1}
        return {
            "phase_a": {
                "S0": {"reference_repetitions": 2, "bitwise_identical": True},
                "S3": {"shipped_mean_korean_overlap_penalty_max": 0.05, "role": "informational_without_restored_absolute_single_speech_envelope"},
                "S4": {"d_turbo_o_point_min_exclusive": 0, "d_turbo_o_lower_min_exclusive": 0, "g_oracle_o_point_min": 0.1, "g_oracle_o_lower_min_exclusive": 0, "g_oracle_o_positive_target_proportion_min": 0.7, "p_q_n_point_max": 0.02, "p_q_n_upper_max": 0.02, "target_character_preservation_oracle_point_min": 0.75, "target_character_preservation_oracle_lower_min": 0.75},
                "S5": {"swapped_minus_correct_cer_min": 0.2, "swapped_target_proportion_min": 0.9, "g_community1_o_point_min_exclusive": 0, "g_community1_o_lower_min_exclusive": 0, "half_oracle_margin_point_min": 0, "half_oracle_margin_lower_min_exclusive": 0, "spurious_empty_window_proportion_min": 0.8, "target_character_preservation_community1_point_min": 0.75, "target_character_preservation_community1_lower_min": 0.75},
                "S6": {"dicow_cer_over_turbo_max": 0.02},
                "S7": {"prompt_on_minus_off_term_recall_min": 0.1, "clean_absent_term_insertions_max": 0},
                "S7b": {"prompt_on_minus_off_point_min": 0, "bootstrap_lower_min_exclusive": -0.02, "cross_speaker_insertions_max": 0},
                "S8": {"warm_order_token_ids_identical": True},
                "S9": {"dicow_cer_improvement_per_claimed_language_min": 0.05, "degraded_cache_delta": 0.1},
            },
            "phase_b": {
                "G1": {"reference_repeat_bitwise_identical": True},
                "G2": {"conversion_contract_count": 12, "failure_finalizes_artifact": False},
                "G3": {"fp32_control_envelope_multiplier": 2, "bounded_repair_limit": 1, "negative_outcome": "evidence_blocker"},
                "G4": {"bf16_precision_envelope_multiplier": 2, "negative_outcome": "unresolved"},
                "G5": {"mask_sensitivity_ratio_min": 0.5, "mask_sensitivity_ratio_max": 2, "mask_distance_over_parity_noise_min": 10, "bounded_repair_limit": 1, "negative_outcome": "evidence_blocker"},
                "G6": {"semantic_parity_required": True, "bounded_repair_limit": 1, "negative_outcome": "evidence_blocker"},
                "G7": {"dicow_peak_over_vanilla_max": 2, "negative_outcome": "not_supported"},
                "G8": {"dicow_window_rtf_over_control_max": 1.5, "negative_outcome": "not_supported"},
                "G9": {"forbid_cpu_fallback": True, "forbid_python_per_frame_hot_loop": True, "forbid_ctc_prefix_scoring": True, "forbid_new_handwritten_kernel": True, "negative_outcome": "not_supported_retarget"},
                "G10": blocker,
                "G11": blocker,
                "G12": blocker,
                "G13": blocker,
                "G14": blocker,
            },
        }

    def _reseal_fixture_and_executions(self, document: dict) -> None:
        inventory = []
        for arm in document["arms"]:
            replay = arm["output"]["score_replay"]
            score_reference = {
                key: deepcopy(replay[key]) for key in (
                    "reference", "expected_terms", "absent_terms", "other_target_terms",
                    "reference_regions",
                )
            }
            inventory.append({
                "arm_id": arm["arm_id"],
                "window_id": arm["window_id"],
                "target_id": arm["target_id"],
                "reference_id": arm["reference_id"],
                "fixture_family": arm["fixture_family"],
                "language": arm["language"],
                "audio_sha256": arm["audio_sha256"],
                "score_reference": score_reference,
                "score_reference_sha256": manifest._canonical_sha(score_reference),
            })
        inventory.sort(key=lambda item: item["arm_id"])
        fixture_hash = manifest._canonical_sha(inventory)
        document["fixture"]["inventory"] = inventory
        document["fixture"]["manifest_sha256"] = fixture_hash
        slots_by_window = {
            mapping["window_id"]: {slot["reference_id"]: slot for slot in mapping["slots"]}
            for mapping in document["mappings"]
        }
        for arm in document["arms"]:
            execution = arm["execution_input"]
            execution.update({
                "fixture_manifest_sha256": fixture_hash,
                "fixture_family": arm["fixture_family"],
                "window_id": arm["window_id"],
                "target_id": arm["target_id"],
                "reference_id": arm["reference_id"],
                "language": arm["language"],
                "audio_sha256": arm["audio_sha256"],
                "provider_assignment": arm["provider_assignment"],
                "stno_sha256": arm["stno"]["sha256"] if arm["stno"] else None,
                "repetition": arm["repetition"],
            })
            if arm["condition"] in ("dicow-mix-O-community1", "dicow-full-mix-community1"):
                target_slot = slots_by_window[arm["window_id"]][arm["target_id"]]
                consumed = target_slot
                if arm["provider_assignment"] == "swapped":
                    opposite = "B" if target_slot["slot"] == "A" else "A"
                    consumed = next(
                        slot for slot in slots_by_window[arm["window_id"]].values()
                        if slot["slot"] == opposite
                    )
                execution["provider_slot"] = consumed["slot"]
                execution["provider_label"] = consumed["provider_label"]
                if consumed["provider_kind"] == "ABSENT":
                    execution.update({
                        "execution_kind": "virtual_absent",
                        "provenance_id": None,
                        "argv": [],
                        "exit_status": None,
                        "receipt": None,
                        "raw_stdout": None,
                        "raw_stderr": None,
                        "raw_output_sha256": None,
                        "attempt_id": None,
                        "process_id": None,
                        "session_id": None,
                        "result": {"text": "", "token_ids": []},
                        "parsed_result_sha256": manifest._canonical_sha(
                            {"text": "", "token_ids": []}
                        ),
                    })
                    arm["output"]["token_ids_sha256"] = manifest._canonical_sha([])
            if execution["execution_kind"] != "virtual_absent":
                terminal_bytes = json.dumps(
                    {
                        "schema_version": "dicow-terminal-output-v1",
                        "result": execution["result"],
                    },
                    sort_keys=True, separators=(",", ":"), ensure_ascii=False,
                ).encode("utf-8")
                execution["parsed_result_sha256"] = manifest._canonical_sha(
                    execution["result"]
                )
                execution["raw_stdout"].update({
                    "sha256": hashlib.sha256(terminal_bytes).hexdigest(),
                    "bytes": len(terminal_bytes),
                })
                execution["raw_output_sha256"] = execution["raw_stdout"]["sha256"]
                provenance = next(
                    record for record in document["execution_provenance"]
                    if record["provenance_id"] == execution["provenance_id"]
                )
                execution["argv"] = manifest._expected_execution_argv(
                    arm, execution, provenance
                )
                receipt_bytes = json.dumps(
                    manifest._expected_execution_receipt(
                        arm, execution,
                        {**provenance, "_execution_basis": document["execution_basis"]},
                    ),
                    sort_keys=True, separators=(",", ":"), ensure_ascii=False,
                ).encode("utf-8")
                execution["receipt"] = {
                    "run_path": "runner-receipts/{}.json".format(arm["arm_id"]),
                    "sha256": hashlib.sha256(receipt_bytes).hexdigest(),
                    "bytes": len(receipt_bytes),
                }
            execution["sha256"] = manifest._canonical_sha({
                key: value for key, value in execution.items() if key != "sha256"
            })
        arm_by_id = {arm["arm_id"]: arm for arm in document["arms"]}
        for metric in document["metrics"]:
            for citation in metric["arm_citations"]:
                stable = arm_by_id[citation["arm_id"]]["output"].get("stable_o_counts")
                citation["regional_edit_path_sha256"] = (
                    stable["regional_edit_path_sha256"] if stable is not None else None
                )

    def _document(self) -> dict:
        if self._DOCUMENT_CACHE is not None:
            return deepcopy(self._DOCUMENT_CACHE)
        utility_hash = self._h("utility")
        activity_providers = {
            "oracle": self._h("activity-oracle"),
            "community1": self._h("activity-community1"),
            "community1_spurious": self._h("activity-community1-spurious"),
            "clean_target": self._h("activity-clean-target"),
        }
        activity_hash = activity_providers["community1"]
        mappings = []
        arms = []
        ordinary_arms = []
        for window_index in range(10):
            window_id = "window-{:02d}".format(window_index)
            reference_ids = [
                "target-{:02d}".format(window_index * 2 + slot_index)
                for slot_index in range(2)
            ]
            labels = ["speaker-{}-{}".format(window_index, name) for name in ("A", "B")]
            activity_matrix = {
                labels[0]: {reference_ids[0]: 850, reference_ids[1]: 100},
                labels[1]: {reference_ids[0]: 100, reference_ids[1]: 700},
            }
            frozen_mapping = derive_frozen_mapping(
                reference_ids, activity_matrix, window_id=window_id
            )
            mapping_hash = frozen_mapping["mapping_sha256"]
            slots = deepcopy(frozen_mapping["slots"])
            for slot_index, slot_name in enumerate(("A", "B")):
                target_index = window_index * 2 + slot_index
                target_id = "target-{:02d}".format(target_index)
                language = "ko" if target_index < 12 else ("it" if target_index < 16 else "en")
                fixture_family = (
                    "hike-pair-v1" if target_index < 12
                    else ("fleurs-it-pair-v1" if target_index < 16 else "fleurs-en-pair-v1")
                )
                audio_hash = self._h("audio-{}".format(target_index))
                k_hash = self._h("k-{}".format(target_index))
                k_frames_hash = self._h("k-frames-{}".format(target_index))
                stno_hash = self._h("stno-{}".format(target_index))
                ordinary_arm = {
                    "arm_id": "arm-{:02d}".format(target_index),
                    "fixture_family": fixture_family,
                    "window_id": window_id,
                    "target_id": target_id,
                    "reference_id": target_id,
                    "repetition": 1,
                    "model": "dicow",
                    "condition": "dicow-mix-O-community1",
                    "evaluation_role": "corrected_prompt_on",
                    "provider_assignment": "correct",
                    "arm_kind": "crop",
                    "language": language,
                    "mapping_sha256": mapping_hash,
                    "utility_contract_sha256": utility_hash,
                    "availability": {"status": "available", "reason": None},
                    "alignment_sha256": self._h("alignment-{}".format(target_index)),
                    "region_labels_sha256": self._h("regions-{}".format(target_index)),
                    "geometry": {
                        "k_start_sample": 100,
                        "k_end_sample": 1000,
                        "k_sha256": k_hash,
                        "k_frames_sha256": k_frames_hash,
                        "audio_crop_sha256": audio_hash,
                        "audio_crop_gain": 1.0,
                        "post_crop_gain": 1,
                        "zero_outside_k": True,
                        "outside_k_class": "silence",
                    },
                    "activity_provider_sha256": activity_hash,
                    "stno": {
                        "kind": "crop",
                        "provider": "community1",
                        "sha256": stno_hash,
                        "logical_shape": [4, 1500],
                        "runtime_shape": [1, 4, 1500],
                        "class_order": ["silence", "target", "non_target", "overlap"],
                        "non_target_or_overlap_frames": 20,
                    },
                    "audio_sha256": audio_hash,
                    "token_bounds": {
                        "decoder_context": 448,
                        "upstream_prompt_cutoff": 223,
                        "init_tokens": 10,
                        "effective_output_cap": 80,
                        "generated_tokens": 20,
                        "prompt_budget_status": "frozen",
                        "prompt_token_count": 20,
                        "prompt_off_generated_p99": 238,
                        "prompt_budget": 80,
                        "prompt_truncated": False,
                        "unavailable_reason": None,
                    },
                    "termination": {"terminal_reason": "eos", "complete": True, "typed": True},
                    "output": {
                        "token_ids_sha256": self._h("tokens-{}".format(target_index)),
                        "normalized_text_sha256": self._h("text-{}".format(target_index)),
                        "normalized_text_empty": False,
                        "cer": 0.25,
                        "wer": 0.2,
                        "term_recall": 0.8,
                        "character_insertions": 0,
                        "word_insertions": 0,
                        "absent_term_insertions": 0,
                        "stable_o_counts": {
                            "regional_edit_path_sha256": self._h("edit-path-{}".format(target_index)),
                            "reference_chars": 100,
                            "substitutions": 5,
                            "deletions": 5,
                            "insertions": 1,
                            "hits": 90,
                        },
                    },
                }
                arms.append(ordinary_arm)
                ordinary_arms.append(ordinary_arm)
            spurious_target_id = frozen_mapping["spurious_target_id"]
            diagnostic = deepcopy(ordinary_arms[-1])
            diagnostic.update({
                "arm_id": "spurious-arm-{:02d}".format(window_index),
                "target_id": spurious_target_id,
                "reference_id": None,
                "condition": "dicow-full-spurious",
                "evaluation_role": "diagnostic",
                "provider_assignment": "not_applicable",
                "arm_kind": "full_window",
                "geometry": None,
                "activity_provider_sha256": activity_providers["community1_spurious"],
                "alignment_sha256": self._h("spurious-alignment-{}".format(window_index)),
                "region_labels_sha256": self._h("spurious-regions-{}".format(window_index)),
                "audio_sha256": self._h("spurious-audio-{}".format(window_index)),
            })
            diagnostic["stno"] = deepcopy(diagnostic["stno"])
            diagnostic["stno"].update({
                "kind": "full_window",
                "provider": "community1+spurious",
                "sha256": self._h("spurious-stno-{}".format(window_index)),
            })
            diagnostic["output"] = deepcopy(diagnostic["output"])
            diagnostic["output"].update({
                "token_ids_sha256": self._h("spurious-tokens-{}".format(window_index)),
                "normalized_text_sha256": self._h("spurious-text-{}".format(window_index)),
                "normalized_text_empty": True,
                "cer": None,
                "wer": None,
                "term_recall": None,
                "character_insertions": 0,
                "word_insertions": 0,
                "stable_o_counts": None,
            })
            arms.append(diagnostic)
            repeated_diagnostic = deepcopy(diagnostic)
            repeated_diagnostic.update({
                "arm_id": "spurious-arm-{:02d}-r2".format(window_index),
                "repetition": 2,
            })
            repeated_diagnostic["stno"] = deepcopy(repeated_diagnostic["stno"])
            repeated_diagnostic["stno"]["sha256"] = self._h(
                "spurious-stno-{}-r2".format(window_index)
            )
            arms.append(repeated_diagnostic)
            mappings.append(frozen_mapping)

        arms_by_role = {
            (
                arm["target_id"], arm["condition"], arm["provider_assignment"],
                arm["arm_kind"], arm["evaluation_role"], arm["repetition"],
            ): arm
            for arm in ordinary_arms
        }
        role_specs = (
            ("turbo-clean-O", "not_applicable", "crop", "turbo", None, None, "corrected_prompt_on", None, None),
            ("turbo-mix-O", "not_applicable", "crop", "turbo", None, None, "corrected_prompt_on", None, None),
            ("dicow-clean-O", "not_applicable", "crop", "dicow", "clean_target", "clean_target", "corrected_prompt_on", None, None),
            ("dicow-mix-O-oracle", "correct", "crop", "dicow", "oracle", "oracle", "corrected_prompt_on", None, None),
            ("dicow-mix-O-oracle", "swapped", "crop", "dicow", "oracle", "oracle", "corrected_prompt_on", None, None),
            ("dicow-clean-single-utility", "not_applicable", "full_window", "dicow", "clean_target", "clean_target", "corrected_prompt_on", None, None),
            ("dicow-full-mix-oracle", "correct", "full_window", "dicow", "oracle", "oracle", "corrected_prompt_on", None, None),
            ("dicow-full-mix-community1", "correct", "full_window", "dicow", "community1", "community1", "corrected_prompt_on", None, None),
            ("dicow-mix-O-community1", "swapped", "crop", "dicow", "community1", "community1", "corrected_prompt_on", None, None),
            ("shipped-ko-meeting-single", "not_applicable", "single", "shipped", None, None, "shipped_comparator", "hike-single-v1", {"ko"}),
            ("shipped-ko-meeting-mix", "not_applicable", "full_window", "shipped", None, None, "shipped_comparator", "hike-pair-v1", {"ko"}),
            ("shipped-it-dialogue-single", "not_applicable", "single", "shipped", None, None, "shipped_comparator", "fleurs-it-single-v1", {"it"}),
            ("dicow-it-dialogue-single", "not_applicable", "single", "dicow", "clean_target", "clean_target", "corrected_prompt_on", "fleurs-it-single-v1", {"it"}),
            ("shipped-full-mix-community1", "not_applicable", "full_window", "shipped", None, None, "shipped_comparator", None, None),
            ("turbo-hike-single", "not_applicable", "single", "turbo", None, None, "automatic_language_control", "hike-single-v1", {"ko"}),
            ("turbo-hike-single", "not_applicable", "single", "turbo", None, None, "explicit_language_control", "hike-single-v1", {"ko"}),
            ("dicow-hike-single", "not_applicable", "single", "dicow", "clean_target", "clean_target", "automatic_language_control", "hike-single-v1", {"ko"}),
            ("dicow-hike-single", "not_applicable", "single", "dicow", "clean_target", "clean_target", "explicit_language_control", "hike-single-v1", {"ko"}),
            ("dicow-hike-single", "not_applicable", "single", "dicow", "clean_target", "clean_target", "prompt_off_control", "hike-single-v1", {"ko"}),
            ("dicow-hike-single", "not_applicable", "single", "dicow", "clean_target", "clean_target", "corrected_prompt_on", "hike-single-v1", {"ko"}),
            ("dicow-full-mix-community1", "correct", "full_window", "dicow", "community1", "community1", "prompt_off_control", "hike-pair-v1", {"ko"}),
            ("dicow-full-mix-community1", "correct", "full_window", "dicow", "community1", "community1", "warm_order_a_then_b", None, None),
            ("dicow-full-mix-community1", "correct", "full_window", "dicow", "community1", "community1", "warm_order_b_then_a", None, None),
        )
        for base in list(ordinary_arms):
            for repetition in (1, 2):
                if repetition == 2:
                    repeated = deepcopy(base)
                    repeated.update({
                        "arm_id": "{}-r2".format(base["arm_id"]),
                        "repetition": 2,
                    })
                    repeated["stno"] = deepcopy(repeated["stno"])
                    repeated["stno"]["sha256"] = self._h("{}-stno-r2".format(base["arm_id"]))
                    repeated["output"] = deepcopy(repeated["output"])
                    repeated["output"]["stable_o_counts"]["regional_edit_path_sha256"] = self._h(
                        "{}-edit-path-r2".format(base["arm_id"])
                    )
                    arms.append(repeated)
                    arms_by_role[(
                        base["target_id"], base["condition"], base["provider_assignment"],
                        base["arm_kind"], base["evaluation_role"], 2,
                    )] = repeated
                for (
                    condition, assignment, kind, model, provider_key, stno_provider,
                    evaluation_role, fixture_override, allowed_languages,
                ) in role_specs:
                    if allowed_languages is not None and base["language"] not in allowed_languages:
                        continue
                    role_key = (
                        base["target_id"], condition, assignment, kind, evaluation_role,
                        repetition,
                    )
                    if role_key in arms_by_role:
                        continue
                    role = deepcopy(base)
                    role_slug = "{}-{}-{}-{}-r{}".format(
                        base["target_id"], condition, assignment, evaluation_role,
                        repetition,
                    )
                    role.update({
                        "arm_id": role_slug,
                        "repetition": repetition,
                        "model": model,
                        "condition": condition,
                        "evaluation_role": evaluation_role,
                        "provider_assignment": assignment,
                        "arm_kind": kind,
                        "fixture_family": fixture_override or base["fixture_family"],
                        "activity_provider_sha256": (
                            activity_providers[provider_key] if provider_key else None
                        ),
                    })
                    role["output"] = deepcopy(role["output"])
                    role["output"]["stable_o_counts"]["regional_edit_path_sha256"] = self._h(
                        "{}-edit-path".format(role_slug)
                    )
                    cer_by_condition = {
                        "turbo-clean-O": 0.10,
                        "turbo-mix-O": 0.50,
                        "dicow-clean-O": 0.10,
                        "dicow-mix-O-oracle": 0.20 if assignment == "correct" else 0.55,
                        "dicow-clean-single-utility": 0.10,
                        "dicow-full-mix-oracle": 0.11,
                        "dicow-full-mix-community1": 0.11,
                        "dicow-mix-O-community1": 0.25 if assignment == "correct" else 0.55,
                        "shipped-ko-meeting-single": 0.20,
                        "shipped-ko-meeting-mix": 0.21,
                        "shipped-it-dialogue-single": 0.20,
                        "dicow-it-dialogue-single": 0.10,
                        "shipped-full-mix-community1": 0.21,
                        "turbo-hike-single": 0.10 if evaluation_role == "automatic_language_control" else 0.12,
                        "dicow-hike-single": 0.11 if evaluation_role in ("automatic_language_control", "prompt_off_control", "corrected_prompt_on") else 0.13,
                    }
                    role["output"]["cer"] = cer_by_condition[condition]
                    if evaluation_role == "prompt_off_control":
                        role["output"]["term_recall"] = 0.60 if condition == "dicow-hike-single" else 0.70
                    elif evaluation_role == "corrected_prompt_on":
                        role["output"]["term_recall"] = 0.80
                    if model == "turbo":
                        role["stno"] = None
                    elif model == "shipped":
                        role["stno"] = None
                        role["token_bounds"] = deepcopy(role["token_bounds"])
                        role["token_bounds"].update({
                            "prompt_budget_status": "not_applicable",
                            "prompt_token_count": None,
                            "prompt_off_generated_p99": None,
                            "prompt_budget": None,
                        })
                    else:
                        role["stno"] = deepcopy(role["stno"])
                        role["stno"].update({
                            "kind": "crop" if kind == "crop" else "full_window",
                            "provider": stno_provider,
                            "sha256": self._h("{}-stno".format(role_slug)),
                            "non_target_or_overlap_frames": 0 if condition == "dicow-clean-O" else 20,
                        })
                    if kind != "crop":
                        role["geometry"] = None
                        role["audio_sha256"] = self._h("{}-audio".format(role_slug))
                    arms.append(role)
                    arms_by_role[role_key] = role

        for source_index in (1, 2):
            for repetition in (1, 2):
                source_control = deepcopy(ordinary_arms[(source_index - 1) * 2])
                source_id = "fleurs-ko-clean-source-{:02d}".format(source_index)
                source_control.update({
                    "arm_id": "{}-r{}".format(source_id, repetition),
                    "fixture_family": "fleurs-ko-clean-v1",
                    "target_id": source_id,
                    "reference_id": source_id,
                    "repetition": repetition,
                    "condition": "dicow-fleurs-ko-clean",
                    "evaluation_role": "corrected_prompt_on",
                    "provider_assignment": "not_applicable",
                    "arm_kind": "single",
                    "geometry": None,
                    "activity_provider_sha256": activity_providers["clean_target"],
                    "audio_sha256": self._h("{}-audio".format(source_id)),
                })
                source_control["stno"] = deepcopy(source_control["stno"])
                source_control["stno"].update({
                    "kind": "full_window",
                    "provider": "clean_target",
                    "sha256": self._h("{}-stno-r{}".format(source_id, repetition)),
                })
                source_control["output"] = deepcopy(source_control["output"])
                source_control["output"]["stable_o_counts"]["regional_edit_path_sha256"] = self._h(
                    "{}-edit-path-r{}".format(source_id, repetition)
                )
                arms.append(source_control)

        metrics = []
        for stratum, arm_index in (("overall", 0), ("ko", 1), ("it", 12), ("en", 16)):
            arm = ordinary_arms[arm_index]
            eligible_arms = [
                candidate for candidate in ordinary_arms
                if stratum == "overall" or candidate["language"] == stratum
            ]
            role_keys = (
                ("turbo-clean-O", "not_applicable", "crop", "corrected_prompt_on"),
                ("turbo-mix-O", "not_applicable", "crop", "corrected_prompt_on"),
                ("dicow-clean-O", "not_applicable", "crop", "corrected_prompt_on"),
                ("dicow-mix-O-oracle", "correct", "crop", "corrected_prompt_on"),
            )
            cited_arms = [
                arms_by_role[(candidate["target_id"], condition, assignment, kind, role, repetition)]
                for candidate in eligible_arms
                for repetition in (1, 2)
                for condition, assignment, kind, role in role_keys
            ]
            metrics.append({
                "metric_id": "metric-{}".format(stratum),
                "criterion_id": "S4.g_oracle_o",
                "gate": "S4",
                "estimand": "G_oracle^O",
                "availability": {"status": "available", "reason": None},
                "point": 0.3,
                "interval": {"kind": "two_sided_95_percentile", "lower": 0.3, "upper": 0.3},
                "target_proportion": 1.0,
                "stratum": stratum,
                "cluster_count": 2 * len({candidate["window_id"] for candidate in eligible_arms}),
                "arm_citations": [{
                    "arm_id": cited["arm_id"],
                    "fixture_family": cited["fixture_family"],
                    "window_id": cited["window_id"],
                    "target_id": cited["target_id"],
                    "reference_id": cited["reference_id"],
                    "repetition": cited["repetition"],
                    "model": cited["model"],
                    "condition": cited["condition"],
                    "evaluation_role": cited["evaluation_role"],
                    "provider_assignment": cited["provider_assignment"],
                    "arm_kind": cited["arm_kind"],
                    "audio_sha256": cited["audio_sha256"],
                    "activity_provider_sha256": cited["activity_provider_sha256"],
                    "stno_sha256": cited["stno"]["sha256"] if cited["stno"] else None,
                    "k_sha256": cited["geometry"]["k_sha256"] if cited["geometry"] else None,
                    "k_frames_sha256": cited["geometry"]["k_frames_sha256"] if cited["geometry"] else None,
                    "regional_edit_path_sha256": cited["output"]["stable_o_counts"]["regional_edit_path_sha256"],
                } for cited in cited_arms],
                "utility_contract_sha256": utility_hash,
            })
        document = {
            "schema_version": "dicow-experiment-v1",
            "experiment_id": "experiment-1",
            "run_id": "run-1",
            "task": "T14",
            "evidence_id": "E4",
            "created_at_utc": "2026-08-30T12:00:00Z",
            "availability": {"status": "available", "reason": None},
            "failure": None,
            "fixture": {
                "pack_id": "overlap-pack-v1",
                "manifest_sha256": self._h("fixture"),
                "sample_rate_hz": 16000,
                "window_samples": 480000,
                "mask_frames": 1500,
                "mask_rate_hz": 50,
                "decoder_context_tokens": 448,
                "target_count": 20,
                "strata": ["ko", "it", "en"],
            },
            "bootstrap": {
                "seed": 20260830,
                "resamples": 10000,
                "confidence": 0.95,
                "method": "deterministic_percentile",
                "cluster_unit": "constructed_window",
                "single_control_cluster_unit": "source_item",
                "stratify_by": ["fixture_family", "language"],
            },
            "thresholds": self._thresholds(),
            "utility_contract": {
                "sha256": utility_hash,
                "mode": "corrected",
                "explicit_language": "ko",
                "prompt_on_every_window": True,
                "greedy_decode": True,
                "seed": 0,
                "previous_token_conditioning": False,
                "prompt_budget_pass_order": ["prompt_off_complete", "freeze_budget", "preflight_prompts", "prompt_on"],
                "effective_token_cap": 80,
                "termination_policy": self._h("termination-policy"),
            },
            "activity_providers": activity_providers,
            "community1": {
                "model_id": "aufklarer/Pyannote-Community-1-CoreML",
                "revision": "a14e6c420d56e8472850649b016a486fd0acbe81",
                "binary_sha256": pins.MODEL_PINS["diarizer"]["archive"]["sha256"],
                "model_tree_sha256": self._h("community-model-tree"),
                "sandbox_profile_sha256": _sha(
                    Path(__file__).resolve().parents[4]
                    / "benchmarks/scripts/dicow/diarizer/deny-network.sb"
                ),
                "t9_canonical": {
                    "run_path": "e0-preflight/canonical.json",
                    "sha256": self._h("community-t9-canonical"),
                    "bytes": 1,
                },
                "raw_evidence_sha256": self._h("raw"),
                "activity_provider_sha256": activity_hash,
                "network_denied": True,
            },
            "mappings": mappings,
            "arms": arms,
            "metrics": metrics,
            "resources": [],
        }

        repo_root = Path(__file__).resolve().parents[4]
        execution_provenance = []
        t9_sealed_paths = {}
        t13_artifacts = {}
        for role in sorted({
            "dicow", "turbo", "shipped_ko", "shipped_it",
        }):
            pin = pins.EXECUTION_PROVENANCE_PINS[role]
            lock = repo_root / pin["lock_path"]
            runner_bytes = "synthetic {} runner\n".format(role).encode("utf-8")
            runner_ref = {
                "run_path": "execution-runtime/{}-runner.py".format(role),
                "sha256": hashlib.sha256(runner_bytes).hexdigest(),
                "bytes": len(runner_bytes),
            }
            model_payload = "synthetic {} model asset\n".format(role).encode("utf-8")
            model_record = {
                "kind": "file", "bytes": len(model_payload), "mode": "0444",
                "sha256": hashlib.sha256(model_payload).hexdigest(),
            }
            model_asset = {
                "kind": "file", "path": "/synthetic/{}.model".format(role),
                "record": model_record,
                "t9_sealed_path_key": pin["model_asset_key"],
            }
            model_manifest = {
                "schema_version": "model-acquisition-manifest-v1",
                "model_role": role,
                "model_id": pin["model_id"],
                "model_revision": pin["model_revision"],
                "model_asset_record_sha256": manifest._canonical_sha(model_record),
            }
            model_bytes = json.dumps(
                model_manifest, sort_keys=True, separators=(",", ":"), ensure_ascii=False
            ).encode("utf-8")
            execution_provenance.append({
                "provenance_id": "provenance-{}".format(role),
                "model_role": role,
                "model_id": pin["model_id"],
                "model_revision": pin["model_revision"],
                "runner": runner_ref,
                "runner_artifact_key": pin["runner_artifact_key"],
                "lock": {
                    "repo_path": pin["lock_path"], "sha256": _sha(lock),
                    "bytes": lock.stat().st_size,
                },
                "lock_artifact_key": pin["lock_artifact_key"],
                "model_manifest": {
                    "run_path": "model-manifests/{}.json".format(role),
                    "sha256": hashlib.sha256(model_bytes).hexdigest(),
                    "bytes": len(model_bytes),
                },
                "model_asset": model_asset,
                "runner_interface": "dicow-runner-receipt-v1",
                "parser_id": "dicow-terminal-json-v1",
            })
            t13_artifacts[pin["runner_artifact_key"]] = {
                "path": runner_ref["run_path"], "sha256": runner_ref["sha256"],
                "bytes": runner_ref["bytes"],
            }
            t9_sealed_paths[pin["model_asset_key"]] = {
                "path": model_asset["path"], "record": model_record,
            }
        lock_pin = pins.EXECUTION_PROVENANCE_PINS["dicow"]
        lock = repo_root / lock_pin["lock_path"]
        t13_artifacts[lock_pin["lock_artifact_key"]] = {
            "path": lock_pin["lock_path"], "sha256": _sha(lock), "bytes": lock.stat().st_size,
        }
        synthetic_t9 = {
            "task": "T9", "state": "done", "branch_disposition": "executed",
            "run_id": "run-1", "sealed_paths": t9_sealed_paths,
        }
        synthetic_t9_bytes = json.dumps(
            synthetic_t9, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode("utf-8")
        synthetic_t13 = {
            "task": "T13", "state": "done", "branch_disposition": "executed",
            "run_id": "run-1", "artifacts": t13_artifacts,
            "source_input_hashes": {
                "T9_state": hashlib.sha256(synthetic_t9_bytes).hexdigest(),
            },
        }
        synthetic_t13_bytes = json.dumps(
            synthetic_t13, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode("utf-8")
        document["execution_basis"] = {
            "t9_state": {
                "run_path": "task-state/T9.json",
                "sha256": hashlib.sha256(synthetic_t9_bytes).hexdigest(),
                "bytes": len(synthetic_t9_bytes),
            },
            "t13_state": {
                "run_path": "task-state/T13.json",
                "sha256": hashlib.sha256(synthetic_t13_bytes).hexdigest(),
                "bytes": len(synthetic_t13_bytes),
            },
        }
        document["execution_provenance"] = execution_provenance

        community_records = []
        for mapping in mappings:
            window_id = mapping["window_id"]
            stdout_bytes = json.dumps({
                "schema_version": "community1-window-output-v1",
                "window_id": window_id,
                "activity_matrix": mapping["activity_matrix"],
            }, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
            evidence_bytes = json.dumps({
                "schema_version": "community1-window-evidence-v1",
                "window_id": window_id,
                "activity_matrix": mapping["activity_matrix"],
            }, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
            community_records.append({
                "window_id": window_id,
                "audio_sha256": self._h("community-audio-{}".format(window_id)),
                "stdout": {
                    "run_path": "community1/windows/{}.stdout.json".format(window_id),
                    "sha256": hashlib.sha256(stdout_bytes).hexdigest(), "bytes": len(stdout_bytes),
                },
                "stderr": {
                    "run_path": "community1/windows/{}.stderr.txt".format(window_id),
                    "sha256": hashlib.sha256(b"").hexdigest(), "bytes": 0,
                },
                "evidence": {
                    "run_path": "community1/windows/{}.evidence.json".format(window_id),
                    "sha256": hashlib.sha256(evidence_bytes).hexdigest(),
                    "bytes": len(evidence_bytes),
                },
                "activity_sha256": mapping["activity_matrix_sha256"],
            })
        community_pack = {
            "schema_version": "community1-evidence-pack-v1",
            "model_id": document["community1"]["model_id"],
            "model_revision": document["community1"]["revision"],
            "records": community_records,
        }
        community_pack_bytes = json.dumps(
            community_pack, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode("utf-8")
        community_activity_sha = manifest._canonical_sha(
            [record["activity_sha256"] for record in community_records]
        )
        document["community1"].update({
            "pack_manifest": {
                "run_path": "community1/evidence-pack.json",
                "sha256": hashlib.sha256(community_pack_bytes).hexdigest(),
                "bytes": len(community_pack_bytes),
            },
            "raw_evidence_index_sha256": manifest._canonical_sha(community_records),
            "activity_provider_sha256": community_activity_sha,
            "raw_evidence_sha256": hashlib.sha256(community_pack_bytes).hexdigest(),
        })
        document["activity_providers"]["community1"] = community_activity_sha
        for arm in arms:
            if arm.get("activity_provider_sha256") == activity_hash:
                arm["activity_provider_sha256"] = community_activity_sha

        inventory_by_key = {}
        for arm in arms:
            key = arm["arm_id"]
            inventory_by_key[key] = {
                "arm_id": arm["arm_id"],
                "window_id": arm["window_id"],
                "target_id": arm["target_id"],
                "reference_id": arm["reference_id"],
                "fixture_family": arm["fixture_family"],
                "language": arm["language"],
                "audio_sha256": arm["audio_sha256"],
            }
        inventory = [inventory_by_key[key] for key in sorted(inventory_by_key)]
        fixture_hash = manifest._canonical_sha(inventory)
        document["fixture"]["inventory"] = inventory
        document["fixture"]["manifest_sha256"] = fixture_hash

        reference_tokens = [chr(0x4E00 + index) for index in range(100)]
        reference_text = " ".join(reference_tokens)
        regions = ["O"] * 100
        mapping_slots = {
            (mapping["window_id"], slot["reference_id"]): slot
            for mapping in mappings for slot in mapping["slots"]
        }
        for arm in arms:
            old_output = arm["output"]
            desired = old_output.get("cer")
            error_count = int(round(float(desired or 0) * 100)) if desired is not None else 0
            hypothesis_tokens = list(reference_tokens)
            prompt_off = arm["evaluation_role"] == "prompt_off_control"
            start = 0 if prompt_off else 1
            for offset in range(error_count):
                index = (start + offset) % len(hypothesis_tokens)
                hypothesis_tokens[index] = chr(0x5200 + index)
            hypothesis_text = " ".join(hypothesis_tokens)
            if arm["condition"] in ("surplus-diagnostic", "dicow-full-spurious"):
                hypothesis_text = ""
                scored = score_empty_reference_diagnostic(
                    hypothesis_text,
                    kind="surplus" if arm["condition"] == "surplus-diagnostic" else "spurious",
                )
            else:
                scored = score_target(
                    reference_text,
                    hypothesis_text,
                    expected_terms=[{"term": reference_tokens[0], "reference_count": 1}],
                    absent_terms=[],
                    other_target_terms=[],
                    reference_regions=regions,
                )
            result = {"text": hypothesis_text, "token_ids": [1, 2, 3]}
            scored.update({
                "token_ids_sha256": manifest._canonical_sha(result["token_ids"]),
                "normalized_text_sha256": hashlib.sha256(
                    str(scored["normalized_text"]).encode("utf-8")
                ).hexdigest(),
                "character_insertions": (
                    scored["cer_counts"]["insertions"]
                    if isinstance(scored.get("cer_counts"), dict)
                    else scored["character_insertions"]
                ),
                "word_insertions": (
                    scored["wer_counts"]["insertions"]
                    if isinstance(scored.get("wer_counts"), dict)
                    else scored["word_insertions"]
                ),
            })
            arm["output"] = scored
            role = arm["evaluation_role"]
            slot = mapping_slots.get((arm["window_id"], arm["target_id"]))
            if slot is not None and arm["provider_assignment"] == "swapped":
                wanted = "B" if slot["slot"] == "A" else "A"
                slot = next(
                    candidate for (candidate_window, _reference), candidate in mapping_slots.items()
                    if candidate_window == arm["window_id"] and candidate["slot"] == wanted
                )
            prompt = "glossary" if role in (
                "corrected_prompt_on", "warm_order_a_then_b", "warm_order_b_then_a"
            ) else ""
            language_mode = (
                "automatic" if role == "automatic_language_control"
                else ("not_applicable" if role in ("shipped_comparator", "diagnostic") else "explicit")
            )
            execution = {
                "execution_kind": "process",
                "fixture_manifest_sha256": fixture_hash,
                "fixture_family": arm["fixture_family"],
                "window_id": arm["window_id"],
                "target_id": arm["target_id"],
                "reference_id": arm["reference_id"],
                "language": arm["language"],
                "audio_sha256": arm["audio_sha256"],
                "language_mode": language_mode,
                "forced_language": arm["language"] if language_mode == "explicit" else None,
                "prompt_payload": prompt,
                "prompt_sha256": hashlib.sha256(prompt.encode("utf-8")).hexdigest(),
                "provider_assignment": arm["provider_assignment"],
                "provider_slot": slot["slot"] if slot is not None else None,
                "provider_label": slot["provider_label"] if slot is not None else None,
                "stno_sha256": arm["stno"]["sha256"] if isinstance(arm["stno"], dict) else None,
                "attempt_id": "attempt-{}".format(arm["arm_id"]),
                "process_id": "process-{}".format(arm["arm_id"]),
                "session_id": "session-{}".format(arm["arm_id"]),
                "order_index": 0 if role != "warm_order_b_then_a" else 1,
                "result": result,
                "repetition": arm["repetition"],
            }
            execution_role = manifest._arm_execution_role(arm)
            provenance = next(
                item for item in execution_provenance if item["model_role"] == execution_role
            )
            terminal_bytes = json.dumps(
                {"schema_version": "dicow-terminal-output-v1", "result": result},
                sort_keys=True, separators=(",", ":"), ensure_ascii=False,
            ).encode("utf-8")
            stdout_sha = hashlib.sha256(terminal_bytes).hexdigest()
            execution.update({
                "provenance_id": provenance["provenance_id"],
                "exit_status": 0,
                "raw_stdout": {
                    "run_path": "raw-output/{}.stdout.json".format(arm["arm_id"]),
                    "sha256": stdout_sha, "bytes": len(terminal_bytes),
                },
                "raw_stderr": {
                    "run_path": "raw-output/{}.stderr.txt".format(arm["arm_id"]),
                    "sha256": hashlib.sha256(b"").hexdigest(), "bytes": 0,
                },
                "parsed_result_sha256": manifest._canonical_sha(result),
                "raw_output_sha256": stdout_sha,
            })
            execution["argv"] = manifest._expected_execution_argv(
                arm, execution, provenance
            )
            receipt_bytes = json.dumps(
                manifest._expected_execution_receipt(
                    arm, execution,
                    {**provenance, "_execution_basis": document["execution_basis"]},
                ),
                sort_keys=True, separators=(",", ":"), ensure_ascii=False,
            ).encode("utf-8")
            execution["receipt"] = {
                "run_path": "runner-receipts/{}.json".format(arm["arm_id"]),
                "sha256": hashlib.sha256(receipt_bytes).hexdigest(),
                "bytes": len(receipt_bytes),
            }
            execution["sha256"] = manifest._canonical_sha(execution)
            arm["execution_input"] = execution

        for metric in metrics:
            arm_by_id = {arm["arm_id"]: arm for arm in arms}
            for citation in metric["arm_citations"]:
                stable = arm_by_id[citation["arm_id"]]["output"].get("stable_o_counts")
                citation["regional_edit_path_sha256"] = (
                    stable["regional_edit_path_sha256"] if stable is not None else None
                )
            if metric["criterion_id"] == "S7.prompt_recall_delta":
                metric["point"] = 1.0
            elif metric["criterion_id"] == "S7b.prompt_recall_delta":
                metric["point"] = 1.0
                metric["interval"] = {
                    "kind": "two_sided_95_percentile", "lower": 1.0, "upper": 1.0,
                }
        self._reseal_fixture_and_executions(document)
        type(self)._DOCUMENT_CACHE = document
        return deepcopy(document)

    def test_valid_document_passes_schema_and_cross_record_checks(self) -> None:
        manifest.verify_experiment_document(self._document())

    def test_rejects_asserted_score_replay_execution_and_termination_forgery(self) -> None:
        arithmetic = self._document()
        arithmetic["arms"][0]["output"]["cer"] += 0.01
        with self.assertRaisesRegex(manifest.VerificationError, "scorer replay"):
            manifest.verify_experiment_document(arithmetic)

        reference = self._document()
        arm = reference["arms"][0]
        arm["output"]["score_replay"]["reference"] += " forged"
        arm["output"]["score_replay_sha256"] = manifest._canonical_sha(
            arm["output"]["score_replay"]
        )
        with self.assertRaisesRegex(manifest.VerificationError, "sealed fixture reference"):
            manifest.verify_experiment_document(reference)

        prompt = self._document()
        arm = next(item for item in prompt["arms"] if item["evaluation_role"] == "prompt_off_control")
        arm["execution_input"]["prompt_payload"] = "forged glossary"
        arm["execution_input"]["prompt_sha256"] = hashlib.sha256(b"forged glossary").hexdigest()
        arm["execution_input"]["sha256"] = manifest._canonical_sha({
            key: value for key, value in arm["execution_input"].items() if key != "sha256"
        })
        with self.assertRaisesRegex(manifest.VerificationError, "prompt-off"):
            manifest.verify_experiment_document(prompt)

        incomplete = self._document()
        incomplete["arms"][0]["termination"]["complete"] = False
        with self.assertRaisesRegex(manifest.VerificationError, "typed and complete"):
            manifest.verify_experiment_document(incomplete)

    def test_rejects_activity_mapping_relabel_and_repetition_execution_reuse(self) -> None:
        mapping_forgery = self._document()
        mapping = mapping_forgery["mappings"][0]
        first_label = sorted(mapping["activity_matrix"])[0]
        first_reference = sorted(mapping["activity_matrix"][first_label])[0]
        mapping["activity_matrix"][first_label][first_reference] += 1
        mapping["activity_matrix_sha256"] = manifest._canonical_sha(mapping["activity_matrix"])
        mapping["mapping_sha256"] = manifest._canonical_sha({
            key: value for key, value in mapping.items() if key != "mapping_sha256"
        })
        with self.assertRaisesRegex(manifest.VerificationError, "activity-derived replay"):
            manifest.verify_experiment_document(mapping_forgery)

        reused = self._document()
        rep1 = next(arm for arm in reused["arms"] if arm["arm_id"] == "arm-00")
        rep2 = next(arm for arm in reused["arms"] if arm["arm_id"] == "arm-00-r2")
        rep2["execution_input"]["attempt_id"] = rep1["execution_input"]["attempt_id"]
        rep2["execution_input"]["process_id"] = rep1["execution_input"]["process_id"]
        self._reseal_fixture_and_executions(reused)
        with self.assertRaisesRegex(manifest.VerificationError, "(?:attempt ID is reused|reuse an execution process)"):
            manifest.verify_experiment_document(reused)

    def test_schema_rejects_transcript_conditioned_mapping(self) -> None:
        document = self._document()
        document["mappings"][0]["transcript_conditioned"] = True
        with self.assertRaises(manifest.VerificationError):
            manifest.verify_experiment_document(document)

    def test_rejects_duplicate_community_mapping_and_dropped_target(self) -> None:
        duplicate = self._document()
        duplicate["mappings"][0]["slots"][1]["provider_label"] = duplicate["mappings"][0]["slots"][0]["provider_label"]
        with self.assertRaisesRegex(manifest.VerificationError, "one real label cannot fill both"):
            manifest.verify_experiment_document(duplicate)
        dropped = self._document()
        dropped["arms"] = [
            arm for arm in dropped["arms"]
            if not (
                arm["target_id"] == "target-19"
                and arm["condition"] not in ("surplus-diagnostic", "dicow-full-spurious")
            )
        ]
        with self.assertRaisesRegex(manifest.VerificationError, "dropped target"):
            manifest.verify_experiment_document(dropped)

    def test_rejects_dropped_stratum_and_untyped_absent_target(self) -> None:
        dropped = self._document()
        dropped["metrics"] = [item for item in dropped["metrics"] if item["stratum"] != "en"]
        with self.assertRaisesRegex(manifest.VerificationError, "strata"):
            manifest.verify_experiment_document(dropped)
        absent = self._document()
        slot = absent["mappings"][0]["slots"][0]
        slot.update({"provider_kind": "ABSENT", "provider_label": None, "absent_id": None, "asr_invoked": True, "terminal_reason": None})
        with self.assertRaises(manifest.VerificationError):
            manifest.verify_experiment_document(absent)

    def test_rejects_wrong_absent_sentinel_and_real_label_count(self) -> None:
        absent = self._document()
        slot = absent["mappings"][0]["slots"][0]
        slot.update({"provider_kind": "ABSENT", "provider_label": None, "absent_id": "ABSENT:B", "asr_invoked": False, "terminal_reason": "diarizer_target_absent"})
        absent["mappings"][0]["real_label_count"] = 1
        with self.assertRaises(manifest.VerificationError):
            manifest.verify_experiment_document(absent)
        wrong_count = self._document()
        wrong_count["mappings"][0]["real_label_count"] = 3
        with self.assertRaisesRegex(manifest.VerificationError, "real_label_count"):
            manifest.verify_experiment_document(wrong_count)

    def test_rejects_wrong_target_window_and_impossible_token_arithmetic(self) -> None:
        wrong_window = self._document()
        wrong_window["arms"][0]["window_id"] = "window-01"
        wrong_window["arms"][0]["mapping_sha256"] = wrong_window["mappings"][1]["mapping_sha256"]
        with self.assertRaisesRegex(manifest.VerificationError, "window_id differs"):
            manifest.verify_experiment_document(wrong_window)
        impossible = self._document()
        impossible["arms"][0]["token_bounds"]["effective_output_cap"] = 440
        with self.assertRaisesRegex(manifest.VerificationError, "decoder context"):
            manifest.verify_experiment_document(impossible)
        source_alias = self._document()
        for arm in source_alias["arms"]:
            if arm["condition"] == "dicow-fleurs-ko-clean":
                arm["target_id"] = "target-00"
                arm["reference_id"] = "target-00"
        with self.assertRaisesRegex(manifest.VerificationError, "(?:FLEURS clean source|target_id differs)"):
            manifest.verify_experiment_document(source_alias)

    def test_prompt_budget_formula_and_447_448_449_occupancy_boundaries(self) -> None:
        def with_bounds(init_tokens: int, p99: int, budget: int) -> dict:
            document = self._document()
            bounds = document["arms"][0]["token_bounds"]
            bounds.update({
                "init_tokens": init_tokens,
                "effective_output_cap": 80,
                "generated_tokens": 80,
                "prompt_budget_status": "frozen",
                "prompt_token_count": 223,
                "prompt_off_generated_p99": p99,
                "prompt_budget": budget,
            })
            return document

        manifest.verify_experiment_document(with_bounds(143, 54, 223))  # occupancy 447
        manifest.verify_experiment_document(with_bounds(144, 53, 223))  # occupancy 448
        with self.assertRaisesRegex(manifest.VerificationError, "occupancy"):
            manifest.verify_experiment_document(with_bounds(145, 52, 224))  # occupancy 449
        tampered = self._document()
        tampered["arms"][0]["token_bounds"]["prompt_budget"] = 81
        with self.assertRaisesRegex(manifest.VerificationError, "formula"):
            manifest.verify_experiment_document(tampered)

    def test_rejects_empty_metrics_metric_contract_drift_and_duplicate_ids(self) -> None:
        empty = self._document()
        empty["metrics"] = []
        with self.assertRaises(manifest.VerificationError):
            manifest.verify_experiment_document(empty)
        drifted = self._document()
        drifted["metrics"][0]["utility_contract_sha256"] = self._h("other-utility")
        with self.assertRaisesRegex(manifest.VerificationError, "metric utility-contract"):
            manifest.verify_experiment_document(drifted)
        duplicate = self._document()
        duplicate["metrics"][1]["metric_id"] = duplicate["metrics"][0]["metric_id"]
        with self.assertRaisesRegex(manifest.VerificationError, "duplicate metric ID"):
            manifest.verify_experiment_document(duplicate)
        wrong_criterion = self._document()
        wrong_criterion["metrics"][0]["criterion_id"] = "S4.d_turbo_o"
        with self.assertRaises(manifest.VerificationError):
            manifest.verify_experiment_document(wrong_criterion)

    def test_rejects_crop_geometry_clean_activity_and_full_window_crop_stno(self) -> None:
        outside = self._document()
        outside["arms"][0]["geometry"]["outside_k_class"] = "target"
        with self.assertRaises(manifest.VerificationError):
            manifest.verify_experiment_document(outside)
        clean = self._document()
        clean["arms"][0]["condition"] = "dicow-clean-O"
        with self.assertRaises(manifest.VerificationError):
            manifest.verify_experiment_document(clean)
        full = self._document()
        full["arms"][0]["arm_kind"] = "full_window"
        full["arms"][0]["condition"] = "dicow-full-mix-community1"
        full["arms"][0]["geometry"] = None
        with self.assertRaisesRegex(manifest.VerificationError, "consume crop STNO"):
            manifest.verify_experiment_document(full)

    def test_rejects_mismatched_hashes_and_spurious_citation(self) -> None:
        mismatched = self._document()
        mismatched["arms"][0]["audio_sha256"] = self._h("different-audio")
        with self.assertRaisesRegex(manifest.VerificationError, "audio_sha256"):
            manifest.verify_experiment_document(mismatched)
        spurious = self._document()
        arm = next(item for item in spurious["arms"] if item["condition"] == "dicow-full-spurious")
        spurious["metrics"][0]["arm_citations"] = [{
            "arm_id": arm["arm_id"],
            "fixture_family": arm["fixture_family"],
            "window_id": arm["window_id"],
            "target_id": arm["target_id"],
            "reference_id": arm["reference_id"],
            "repetition": arm["repetition"],
            "model": arm["model"],
            "condition": arm["condition"],
            "evaluation_role": arm["evaluation_role"],
            "provider_assignment": arm["provider_assignment"],
            "arm_kind": arm["arm_kind"],
            "audio_sha256": arm["audio_sha256"],
            "activity_provider_sha256": arm["activity_provider_sha256"],
            "stno_sha256": arm["stno"]["sha256"],
            "k_sha256": None,
            "k_frames_sha256": None,
            "regional_edit_path_sha256": None,
        }]
        with self.assertRaises(manifest.VerificationError):
            manifest.verify_experiment_document(spurious)

    def test_diagnostic_identity_coverage_and_empty_reference_rates(self) -> None:
        collision = self._document()
        collision["mappings"][0]["spurious_target_id"] = "target-00"
        with self.assertRaisesRegex(manifest.VerificationError, "collid"):
            manifest.verify_experiment_document(collision)

        missing = self._document()
        missing["arms"] = [
            arm for arm in missing["arms"] if arm["arm_id"] != "spurious-arm-00"
        ]
        with self.assertRaisesRegex(manifest.VerificationError, "spurious diagnostics"):
            manifest.verify_experiment_document(missing)

        duplicate = self._document()
        clone = deepcopy(next(arm for arm in duplicate["arms"] if arm["arm_id"] == "spurious-arm-00"))
        clone["arm_id"] = "spurious-arm-00-copy"
        clone["execution_input"]["attempt_id"] += "-copy"
        clone["execution_input"]["process_id"] += "-copy"
        duplicate["arms"].append(clone)
        self._reseal_fixture_and_executions(duplicate)
        with self.assertRaisesRegex(manifest.VerificationError, "duplicate spurious"):
            manifest.verify_experiment_document(duplicate)

        coerced = self._document()
        diagnostic = next(arm for arm in coerced["arms"] if arm["arm_id"] == "spurious-arm-00")
        diagnostic["output"]["cer"] = 0
        with self.assertRaises(manifest.VerificationError):
            manifest.verify_experiment_document(coerced)

        ordinary_null = self._document()
        ordinary_null["arms"][0]["output"]["cer"] = None
        with self.assertRaises(manifest.VerificationError):
            manifest.verify_experiment_document(ordinary_null)

    def test_surplus_diagnostics_cover_each_sealed_label_once(self) -> None:
        document = self._document()
        mapping = document["mappings"][0]
        activity = deepcopy(mapping["activity_matrix"])
        references = [slot["reference_id"] for slot in mapping["slots"]]
        activity["surplus-window-00"] = {reference: 0.01 for reference in references}
        mapping.clear()
        mapping.update(derive_frozen_mapping(references, activity, window_id="window-00"))
        for arm in document["arms"]:
            if arm["window_id"] == "window-00":
                arm["mapping_sha256"] = mapping["mapping_sha256"]
        template = deepcopy(next(arm for arm in document["arms"] if arm["arm_id"] == "spurious-arm-00"))
        template.update({
            "arm_id": "surplus-arm-00",
            "target_id": "surplus-window-00",
            "condition": "surplus-diagnostic",
            "activity_provider_sha256": document["activity_providers"]["community1"],
        })
        template["stno"] = deepcopy(template["stno"])
        template["stno"].update({"provider": "community1", "sha256": self._h("surplus-stno")})
        template["output"] = score_empty_reference_diagnostic("", kind="surplus")
        template["output"].update({
            "token_ids_sha256": manifest._canonical_sha(template["execution_input"]["result"]["token_ids"]),
            "normalized_text_sha256": hashlib.sha256(b"").hexdigest(),
            "character_insertions": 0,
            "word_insertions": 0,
        })
        template["execution_input"]["result"]["text"] = ""
        template["execution_input"]["attempt_id"] = "attempt-surplus-arm-00"
        template["execution_input"]["process_id"] = "process-surplus-arm-00"
        template["execution_input"]["session_id"] = "session-surplus-arm-00"
        missing = deepcopy(document)
        with self.assertRaisesRegex(manifest.VerificationError, "surplus diagnostics"):
            manifest.verify_experiment_document(missing)
        document["arms"].append(template)
        self._reseal_fixture_and_executions(document)
        manifest.verify_experiment_document(document)
        duplicate = deepcopy(template)
        duplicate["arm_id"] = "surplus-arm-00-copy"
        duplicate["execution_input"]["attempt_id"] = "attempt-surplus-arm-00-copy"
        duplicate["execution_input"]["process_id"] = "process-surplus-arm-00-copy"
        duplicate["execution_input"]["session_id"] = "session-surplus-arm-00-copy"
        document["arms"].append(duplicate)
        self._reseal_fixture_and_executions(document)
        with self.assertRaisesRegex(manifest.VerificationError, "duplicate surplus"):
            manifest.verify_experiment_document(document)

    def test_activity_provider_and_stno_bindings_are_semantic(self) -> None:
        wrong_hash = self._document()
        wrong_hash["arms"][0]["activity_provider_sha256"] = wrong_hash["activity_providers"]["oracle"]
        with self.assertRaisesRegex(manifest.VerificationError, "semantic provider"):
            manifest.verify_experiment_document(wrong_hash)

        wrong_stno = self._document()
        wrong_stno["arms"][0]["stno"]["provider"] = "oracle"
        with self.assertRaises(manifest.VerificationError):
            manifest.verify_experiment_document(wrong_stno)

        turbo_null = self._document()
        arm = next(
            item for item in turbo_null["arms"]
            if item["target_id"] == "target-02"
            and item["condition"] == "turbo-mix-O"
            and item["repetition"] == 1
        )
        self.assertIsNone(arm["activity_provider_sha256"])
        self.assertIsNone(arm["stno"])
        manifest.verify_experiment_document(turbo_null)
        baseline_with_provider = deepcopy(turbo_null)
        arm = next(
            item for item in baseline_with_provider["arms"]
            if item["target_id"] == "target-02"
            and item["condition"] == "turbo-mix-O"
            and item["repetition"] == 1
        )
        arm.update({
            "activity_provider_sha256": baseline_with_provider["activity_providers"]["community1"],
            "stno": deepcopy(baseline_with_provider["arms"][0]["stno"]),
        })
        with self.assertRaises(manifest.VerificationError):
            manifest.verify_experiment_document(baseline_with_provider)

        community_drift = self._document()
        community_drift["community1"]["activity_provider_sha256"] = self._h("forged-community")
        with self.assertRaisesRegex(manifest.VerificationError, "Community evidence hash"):
            manifest.verify_experiment_document(community_drift)

        provider_collision = self._document()
        provider_collision["activity_providers"]["oracle"] = provider_collision["activity_providers"]["community1"]
        with self.assertRaisesRegex(manifest.VerificationError, "pairwise distinct"):
            manifest.verify_experiment_document(provider_collision)

    def test_absent_mapping_emits_only_the_virtual_empty_result(self) -> None:
        document = self._document()
        mapping = document["mappings"][0]
        slot_a = next(slot for slot in mapping["slots"] if slot["slot"] == "A")
        removed_label = slot_a["provider_label"]
        activity = {
            label: row for label, row in mapping["activity_matrix"].items()
            if label != removed_label
        }
        references = [slot["reference_id"] for slot in mapping["slots"]]
        mapping.clear()
        mapping.update(derive_frozen_mapping(references, activity, window_id="window-00"))
        for arm in document["arms"]:
            if arm["window_id"] == "window-00":
                arm["mapping_sha256"] = mapping["mapping_sha256"]
        absent_arms = []
        for arm in document["arms"]:
            if arm["condition"] not in ("dicow-mix-O-community1", "dicow-full-mix-community1"):
                continue
            consumes_a = (
                arm["target_id"] == "target-00" and arm["provider_assignment"] == "correct"
            ) or (
                arm["target_id"] == "target-01" and arm["provider_assignment"] == "swapped"
            )
            if not consumes_a:
                continue
            absent_arms.append(arm)
            arm["token_bounds"]["generated_tokens"] = 0
            arm["termination"] = {
                "terminal_reason": "diarizer_target_absent", "complete": True, "typed": True,
            }
            arm["output"].update({
                "normalized_text_empty": True,
                "cer": 1,
                "wer": 1,
                "term_recall": 0,
                "character_insertions": 0,
                "word_insertions": 0,
                "absent_term_insertions": 0,
                "stable_o_counts": {
                    "regional_edit_path_sha256": self._h("absent-virtual-edit-path"),
                    "reference_chars": 100,
                    "substitutions": 0,
                    "deletions": 100,
                    "insertions": 0,
                    "hits": 0,
                },
            })
        self._reseal_fixture_and_executions(document)
        self.assertTrue(absent_arms)
        manifest.verify_experiment_document(document)
        invented = deepcopy(document)
        bad_arm = next(
            arm for arm in invented["arms"]
            if arm["termination"] and arm["termination"]["terminal_reason"] == "diarizer_target_absent"
        )
        bad_arm["token_bounds"]["generated_tokens"] = 1
        with self.assertRaises(manifest.VerificationError):
            manifest.verify_experiment_document(invented)

    def test_ordinary_arm_matrix_requires_exactly_two_repetitions(self) -> None:
        missing = self._document()
        missing["arms"] = [
            arm for arm in missing["arms"]
            if arm["arm_id"] != "arm-00-r2"
        ]
        with self.assertRaisesRegex(manifest.VerificationError, "(?:both frozen repetitions|omits a repetition)"):
            manifest.verify_experiment_document(missing)
        duplicate = self._document()
        clone = deepcopy(next(arm for arm in duplicate["arms"] if arm["arm_id"] == "arm-00-r2"))
        clone["arm_id"] = "arm-00-r2-copy"
        clone["execution_input"]["attempt_id"] += "-copy"
        clone["execution_input"]["process_id"] += "-copy"
        duplicate["arms"].append(clone)
        self._reseal_fixture_and_executions(duplicate)
        with self.assertRaisesRegex(manifest.VerificationError, "both frozen repetitions"):
            manifest.verify_experiment_document(duplicate)
        missing_both = self._document()
        missing_both["arms"] = [
            arm for arm in missing_both["arms"]
            if not (
                arm["target_id"] == "target-00"
                and arm["condition"] == "dicow-mix-O-oracle"
                and arm["provider_assignment"] == "swapped"
            )
        ]
        with self.assertRaisesRegex(manifest.VerificationError, "missing required condition cells"):
            manifest.verify_experiment_document(missing_both)

    def test_gate_ready_matrix_and_metric_citations_require_available_arms(self) -> None:
        unavailable_matrix = self._document()
        arm = next(
            item for item in unavailable_matrix["arms"]
            if item["target_id"] == "target-00"
            and item["condition"] == "dicow-mix-O-oracle"
            and item["provider_assignment"] == "swapped"
            and item["repetition"] == 1
        )
        arm["availability"] = {"status": "unavailable", "reason": "mapped real output missing"}
        arm["termination"] = None
        arm["output"] = None
        with self.assertRaisesRegex(
            manifest.VerificationError,
            "(?:unavailable required ordinary|typed_failure.*expected)",
        ):
            manifest.verify_experiment_document(unavailable_matrix)

        unavailable_diagnostic = self._document()
        diagnostic = next(
            item for item in unavailable_diagnostic["arms"]
            if item["condition"] == "dicow-full-spurious" and item["repetition"] == 1
        )
        diagnostic["availability"] = {"status": "unavailable", "reason": "diagnostic output missing"}
        diagnostic["termination"] = None
        diagnostic["output"] = None
        with self.assertRaisesRegex(
            manifest.VerificationError,
            "(?:unavailable required spurious|typed_failure.*expected)",
        ):
            manifest.verify_experiment_document(unavailable_diagnostic)

        unavailable_citation = self._document()
        unavailable_citation["task"] = "T13"
        cited_id = unavailable_citation["metrics"][0]["arm_citations"][0]["arm_id"]
        cited = next(arm for arm in unavailable_citation["arms"] if arm["arm_id"] == cited_id)
        cited["availability"] = {"status": "unavailable", "reason": "cited output missing"}
        cited["termination"] = None
        cited["output"] = None
        with self.assertRaisesRegex(
            manifest.VerificationError,
            "(?:available metric cites|typed_failure.*expected)",
        ):
            manifest.verify_experiment_document(unavailable_citation)

    def test_nonfinite_numbers_and_nonstandard_json_constants_fail_closed(self) -> None:
        direct = self._document()
        direct["mappings"][0]["objective_values"][0] = float("nan")
        with self.assertRaisesRegex(manifest.VerificationError, "non-finite"):
            manifest.verify_experiment_document(direct)
        direct_metric = self._document()
        direct_metric["metrics"][0]["point"] = float("inf")
        with self.assertRaisesRegex(manifest.VerificationError, "non-finite"):
            manifest.verify_experiment_document(direct_metric)
        direct_rate = self._document()
        direct_rate["arms"][0]["output"]["cer"] = float("nan")
        with self.assertRaisesRegex(manifest.VerificationError, "non-finite"):
            manifest.verify_experiment_document(direct_rate)
        direct_correction = self._document()
        direct_correction["correction_burden"] = {
            "availability": {"status": "available", "reason": None},
            "unit": "seconds",
            "allowed_causes": [
                "missed_target_in_overlap", "other_speaker_intrusion", "duplicate_overlap",
            ],
            "overlap_caused_seconds": float("inf"),
            "total_seconds": 100,
            "ratio": 0.05,
            "percentage": 5,
            "uncertain_seconds": 0,
            "meeting_sha256": self._h("meeting"),
        }
        with self.assertRaisesRegex(manifest.VerificationError, "non-finite"):
            manifest.verify_experiment_document(direct_correction)
        with self.assertRaisesRegex(manifest.VerificationError, "non-finite"):
            manifest._recompute_metric_passed({
                "criterion_id": "S5.swap_margin",
                "point": float("nan"),
                "interval": {"kind": "two_sided_95_percentile", "lower": 0.1, "upper": 0.2},
                "target_proportion": 0.95,
            })
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "nonstandard.json"
            path.write_text('{"value": NaN}\n', encoding="utf-8")
            with self.assertRaisesRegex(manifest.VerificationError, "forbidden non-finite"):
                manifest._load_json(path)
            duplicate_path = Path(temporary) / "duplicate.json"
            duplicate_path.write_text(
                '{"outer": {"value": 1, "value": 2}}\n', encoding="utf-8"
            )
            with self.assertRaisesRegex(manifest.VerificationError, "duplicate object key"):
                manifest._load_json(duplicate_path)

    def test_metric_citations_require_exact_causal_arm_roles(self) -> None:
        document = self._document()
        metric = next(
            item for item in document["metrics"]
            if item["criterion_id"] == "S4.g_oracle_o" and item["stratum"] == "overall"
        )
        target_id = next(
            arm["target_id"] for arm in document["arms"]
            if arm["arm_id"] == metric["arm_citations"][0]["arm_id"]
        )
        community = next(
            arm for arm in document["arms"]
            if arm["target_id"] == target_id
            and arm["condition"] == "dicow-mix-O-community1"
            and arm["provider_assignment"] == "correct"
            and arm["repetition"] == 1
        )
        metric["arm_citations"][-1] = {
            "arm_id": community["arm_id"],
            "fixture_family": community["fixture_family"],
            "window_id": community["window_id"],
            "target_id": community["target_id"],
            "reference_id": community["reference_id"],
            "repetition": community["repetition"],
            "model": community["model"],
            "condition": community["condition"],
            "evaluation_role": community["evaluation_role"],
            "provider_assignment": community["provider_assignment"],
            "arm_kind": community["arm_kind"],
            "audio_sha256": community["audio_sha256"],
            "activity_provider_sha256": community["activity_provider_sha256"],
            "stno_sha256": community["stno"]["sha256"],
            "k_sha256": community["geometry"]["k_sha256"],
            "k_frames_sha256": community["geometry"]["k_frames_sha256"],
            "regional_edit_path_sha256": community["output"]["stable_o_counts"]["regional_edit_path_sha256"],
        }
        with self.assertRaises(manifest.VerificationError):
            manifest.verify_experiment_document(document)

        cross_target = self._document()
        overall = next(
            item for item in cross_target["metrics"]
            if item["criterion_id"] == "S4.g_oracle_o" and item["stratum"] == "overall"
        )
        overall["arm_citations"][-1], overall["arm_citations"][-5] = (
            overall["arm_citations"][-5], overall["arm_citations"][-1]
        )
        with self.assertRaisesRegex(manifest.VerificationError, "cross target"):
            manifest.verify_experiment_document(cross_target)

        cross_repetition = self._document()
        metric = next(
            item for item in cross_repetition["metrics"]
            if item["criterion_id"] == "S4.g_oracle_o" and item["stratum"] == "overall"
        )
        metric["arm_citations"][-1], metric["arm_citations"][-5] = (
            metric["arm_citations"][-5], metric["arm_citations"][-1]
        )
        with self.assertRaisesRegex(manifest.VerificationError, "repetition"):
            manifest.verify_experiment_document(cross_repetition)

        repeated_role = self._document()
        repeated_role["metrics"][0]["arm_citations"].append(
            deepcopy(repeated_role["metrics"][0]["arm_citations"][0])
        )
        with self.assertRaisesRegex(manifest.VerificationError, "repeats the same arm"):
            manifest.verify_experiment_document(repeated_role)

        forged_coordinate = self._document()
        forged_coordinate["metrics"][0]["arm_citations"][0]["reference_id"] = "target-01"
        with self.assertRaisesRegex(manifest.VerificationError, "reference_id differs"):
            manifest.verify_experiment_document(forged_coordinate)

    def test_correction_burden_ratio_and_percentage_are_bound(self) -> None:
        document = self._document()
        document["correction_burden"] = {
            "availability": {"status": "available", "reason": None},
            "unit": "seconds",
            "allowed_causes": [
                "missed_target_in_overlap", "other_speaker_intrusion", "duplicate_overlap",
            ],
            "overlap_caused_seconds": 5,
            "total_seconds": 100,
            "ratio": 0.05,
            "percentage": 5,
            "uncertain_seconds": 0,
            "meeting_sha256": self._h("meeting"),
        }
        manifest.verify_experiment_document(document)
        wrong_ratio = deepcopy(document)
        wrong_ratio["correction_burden"]["ratio"] = 0.0499
        with self.assertRaisesRegex(manifest.VerificationError, "ratio differs"):
            manifest.verify_experiment_document(wrong_ratio)
        wrong_percentage = deepcopy(document)
        wrong_percentage["correction_burden"]["percentage"] = 4.99
        with self.assertRaisesRegex(manifest.VerificationError, "percentage differs"):
            manifest.verify_experiment_document(wrong_percentage)

    def test_gate_schema_rejects_available_null_metric(self) -> None:
        gate_value = os.environ.get("MACCHERONI_DICOW_T0_GATE")
        if not gate_value:
            self.skipTest("set MACCHERONI_DICOW_T0_GATE for sealed T0 integration evidence")
        gate_path = Path(gate_value)
        if not gate_path.exists():
            self.skipTest("sealed T0 gate is not present")
        gate = json.loads(gate_path.read_text(encoding="utf-8"))
        gate["metrics"] = [{
            "gate": "S4",
            "availability": {"status": "available", "reason": None},
            "point": None,
            "interval": None,
            "passed": True,
            "evidence_sha256": self._h("metric"),
        }]
        with self.assertRaises(manifest.VerificationError):
            manifest._validate_schema(gate, "dicow-gate.schema.json")


class GateVerificationTests(unittest.TestCase):
    @staticmethod
    def _materialize_experiment_evidence(root: Path, document: dict) -> None:
        root = root.resolve()
        _write_json(root / "run-manifest.json", {"run_id": document["run_id"]})
        from benchmarks.scripts.dicow.common.preflight import artifact_record

        t9_sealed_paths = {}
        t13_artifacts = {}
        for provenance in document["execution_provenance"]:
            role = provenance["model_role"]
            runner_bytes = "{} future runner interface\n".format(role).encode("utf-8")
            runner_path = root / "execution-runtime" / (role + "-runner.py")
            runner_path.parent.mkdir(parents=True, exist_ok=True)
            if runner_path.exists():
                runner_path.chmod(0o644)
            runner_path.write_bytes(runner_bytes)
            runner_path.chmod(0o444)
            provenance["runner"].update({
                "run_path": str(runner_path.relative_to(root)),
                "sha256": hashlib.sha256(runner_bytes).hexdigest(),
                "bytes": len(runner_bytes),
            })
            model_path = root / "model-assets" / (role + ".model")
            model_path.parent.mkdir(parents=True, exist_ok=True)
            if model_path.exists():
                model_path.chmod(0o644)
            model_path.write_bytes("{} sealed model\n".format(role).encode("utf-8"))
            model_path.chmod(0o444)
            model_record = artifact_record(model_path, immutable=True)
            provenance["model_asset"].update({
                "kind": model_record["kind"], "path": str(model_path),
                "record": model_record,
            })
            payload = {
                "schema_version": "model-acquisition-manifest-v1",
                "model_role": role,
                "model_id": provenance["model_id"],
                "model_revision": provenance["model_revision"],
                "model_asset_record_sha256": manifest._canonical_sha(model_record),
            }
            raw = json.dumps(
                payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False
            ).encode("utf-8")
            ref = provenance["model_manifest"]
            path = root / ref["run_path"]
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(raw)
            ref.update({"sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw)})
            t13_artifacts[provenance["runner_artifact_key"]] = {
                "path": provenance["runner"]["run_path"],
                "sha256": provenance["runner"]["sha256"],
                "bytes": provenance["runner"]["bytes"],
            }
            t13_artifacts[provenance["lock_artifact_key"]] = {
                "path": provenance["lock"]["repo_path"],
                "sha256": provenance["lock"]["sha256"],
                "bytes": provenance["lock"]["bytes"],
            }
            t9_sealed_paths[provenance["model_asset"]["t9_sealed_path_key"]] = {
                "path": str(model_path), "record": model_record,
            }

        t9_state = {
            "task": "T9", "state": "done", "branch_disposition": "executed",
            "run_id": document["run_id"], "sealed_paths": t9_sealed_paths,
        }
        t9_path = root / "task-state" / "T9.json"
        if t9_path.exists():
            t9_path.chmod(0o644)
        _write_json(t9_path, t9_state)
        t9_path.chmod(0o444)
        t13_state = {
            "task": "T13", "state": "done", "branch_disposition": "executed",
            "run_id": document["run_id"], "artifacts": t13_artifacts,
            "source_input_hashes": {"T9_state": _sha(t9_path)},
        }
        t13_path = root / "task-state" / "T13.json"
        if t13_path.exists():
            t13_path.chmod(0o644)
        _write_json(t13_path, t13_state)
        t13_path.chmod(0o444)
        document["execution_basis"] = {
            "t9_state": {
                "run_path": "task-state/T9.json", "sha256": _sha(t9_path),
                "bytes": t9_path.stat().st_size,
            },
            "t13_state": {
                "run_path": "task-state/T13.json", "sha256": _sha(t13_path),
                "bytes": t13_path.stat().st_size,
            },
        }

        community = document["community1"]
        from benchmarks.scripts.dicow.diarizer.community1_reference import (
            command_for, freeze_mapping, merge_segments, parse_segments, rasterize,
        )

        binary_path = root / "community1/runtime/speech"
        binary_path.parent.mkdir(parents=True, exist_ok=True)
        if binary_path.exists():
            binary_path.chmod(0o644)
        binary_path.write_bytes(b"synthetic Community speech runtime\n")
        binary_path.chmod(0o444)
        model_tree = root / "community1/model-tree"
        if model_tree.exists():
            model_tree.chmod(0o755)
        model_tree.mkdir(parents=True, exist_ok=True)
        if (model_tree / "model.bin").exists():
            (model_tree / "model.bin").chmod(0o644)
        (model_tree / "model.bin").write_bytes(b"synthetic Community model tree\n")
        (model_tree / "model.bin").chmod(0o444)
        model_tree.chmod(0o555)
        sandbox_path = (
            Path(__file__).resolve().parents[4]
            / "benchmarks/scripts/dicow/diarizer/deny-network.sb"
        )
        binary_record = artifact_record(binary_path, immutable=True)
        model_tree_record = artifact_record(model_tree, immutable=True)
        sandbox_record = artifact_record(sandbox_path, immutable=False)
        canonical_path = root / "e0-preflight/canonical.json"
        canonical = {
            "schema_version": "dicow-e0-preflight-v1",
            "run_id": document["run_id"],
            "runtime_bindings": {
                "aligner": {},
                "community1": {
                    "model_id": community["model_id"],
                    "model_revision": community["revision"],
                    "binary": {"path": str(binary_path), "record": binary_record},
                    "model_tree": {"path": str(model_tree), "record": model_tree_record},
                    "sandbox_profile": {"path": str(sandbox_path), "record": sandbox_record},
                },
            },
        }
        _write_json(canonical_path, canonical)
        canonical_ref = {
            "run_path": "e0-preflight/canonical.json", "sha256": _sha(canonical_path),
            "bytes": canonical_path.stat().st_size,
        }
        community.update({
            "binary_sha256": binary_record["sha256"],
            "model_tree_sha256": model_tree_record["tree_sha256"],
            "sandbox_profile_sha256": sandbox_record["sha256"],
            "t9_canonical": canonical_ref,
        })

        records = []
        constructed_mixtures = []
        activity_hashes = []
        spurious_hashes = []
        replay_by_window = {}
        for mapping in document["mappings"]:
            window_id = mapping["window_id"]
            slots = mapping["slots"]
            reference_ids = [slot["reference_id"] for slot in slots]
            labels = sorted(mapping["activity_matrix"])
            if len(labels) != 2:
                raise AssertionError("path fixture requires two actual Community labels")
            segments_value = [
                {"speaker": labels[0], "start": 0.0, "end": 17.0},
                {"speaker": labels[1], "start": 16.0, "end": 30.0},
            ]
            stdout_bytes = (
                "community runtime log\n" + json.dumps(
                    {"segments": segments_value}, sort_keys=True, separators=(",", ":")
                )
            ).encode("utf-8")
            segments = parse_segments(stdout_bytes.decode("utf-8"))
            parsed_labels, provider_activity = rasterize(segments)
            self_mapping = {
                str(label): {
                    reference_ids[0]: (850 if index == 0 else 100),
                    reference_ids[1]: (100 if index == 0 else 700),
                }
                for index, label in enumerate(parsed_labels)
            }
            if self_mapping != mapping["activity_matrix"]:
                raise AssertionError("synthetic Community raster differs from frozen mapping")
            provider_bytes = bytes(sum(provider_activity, []))
            oracle = [
                [int(frame < 900) for frame in range(1500)],
                [int(frame >= 750) for frame in range(1500)],
            ]
            oracle_bytes = bytes(sum(oracle, []))
            spurious_row = [int(1450 <= frame < 1500) for frame in range(1500)]
            spurious_activity = provider_activity + [spurious_row]
            spurious_bytes = bytes(sum(spurious_activity, []))
            audio_bytes = ("synthetic audio {}\n".format(window_id)).encode("utf-8")
            window_root = "community1/windows/{}".format(window_id)
            audio_relative = window_root + "/mix.wav"
            stdout_relative = window_root + "/stdout.txt"
            stderr_relative = window_root + "/stderr.txt"
            evidence_relative = window_root + "/evidence.json"
            oracle_relative = "activity/{}/oracle.u8".format(window_id)
            activity_relative = "activity/{}/community1.u8".format(window_id)
            spurious_relative = "activity/{}/community1-spurious.u8".format(window_id)
            stderr_bytes = b"synthetic Community diagnostic\n"
            audio_path = root / audio_relative
            audio_path.parent.mkdir(parents=True, exist_ok=True)
            audio_path.write_bytes(audio_bytes)
            evidence_value = {
                "schema_version": "1.0.0",
                "argv": list(command_for(binary_path, audio_path)),
                "stdout_sha256": hashlib.sha256(stdout_bytes).hexdigest(),
                "stderr_sha256": hashlib.sha256(stderr_bytes).hexdigest(),
                "exit_status": 0,
                "elapsed_s": 0.25,
                "labels": list(parsed_labels),
                "segments": [segment.__dict__ for segment in merge_segments(segments)],
                "activity_sha256": hashlib.sha256(provider_bytes).hexdigest(),
                "activity": provider_activity,
                "binary_path": str(binary_path),
                "binary_sha256": binary_record["sha256"],
                "audio_path": str(audio_path),
                "audio_sha256": hashlib.sha256(audio_bytes).hexdigest(),
                "model_tree_path": str(model_tree),
                "model_tree_sha256": model_tree_record["tree_sha256"],
                "sandbox_sha256": sandbox_record["sha256"],
                "t9_canonical_path": str(canonical_path),
                "t9_canonical_sha256": canonical_ref["sha256"],
            }
            evidence_bytes = (
                json.dumps(evidence_value, indent=2, sort_keys=True) + "\n"
            ).encode("utf-8")
            refs = {
                "audio": (audio_relative, audio_bytes),
                "stdout": (stdout_relative, stdout_bytes),
                "stderr": (stderr_relative, stderr_bytes),
                "evidence": (evidence_relative, evidence_bytes),
                "oracle_activity": (oracle_relative, oracle_bytes),
                "community_activity": (activity_relative, provider_bytes),
                "community_spurious_activity": (spurious_relative, spurious_bytes),
            }
            record = {
                "window_id": window_id,
                "t9_canonical_path": str(canonical_path),
                "producer_audio_path": str(audio_path),
                "producer_stdout_path": stdout_relative,
                "producer_evidence_path": evidence_relative,
            }
            for field, (relative, payload) in refs.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(payload)
                record[field] = {
                    "run_path": relative, "sha256": hashlib.sha256(payload).hexdigest(),
                    "bytes": len(payload),
                }
            records.append(record)
            activity_hashes.append(hashlib.sha256(provider_bytes).hexdigest())
            spurious_hashes.append(hashlib.sha256(spurious_bytes).hexdigest())
            replay_by_window[window_id] = {
                "labels": list(parsed_labels), "activity": provider_activity,
                "spurious_activity": spurious_activity,
            }
            producer_mapping = freeze_mapping(
                parsed_labels, provider_activity, reference_ids, oracle
            )
            constructed_mixtures.append({
                "window_id": window_id,
                "target_a": reference_ids[0],
                "target_b": reference_ids[1],
                "audio_path": str(audio_path),
                "community1": {
                    "raw_stdout": stdout_relative,
                    "evidence_path": evidence_relative,
                    "raw_evidence_sha256": hashlib.sha256(evidence_bytes).hexdigest(),
                    "labels": list(parsed_labels),
                    "activity_sha256": hashlib.sha256(provider_bytes).hexdigest(),
                },
                "mapping": producer_mapping,
                "activity_providers": {
                    "oracle": {"path": oracle_relative, "shape": [2, 1500], "sha256": hashlib.sha256(oracle_bytes).hexdigest()},
                    "community1": {"path": activity_relative, "shape": [2, 1500], "sha256": hashlib.sha256(provider_bytes).hexdigest()},
                    "community1_spurious": {"path": spurious_relative, "shape": [3, 1500], "sha256": hashlib.sha256(spurious_bytes).hexdigest()},
                },
                "spurious_target": {
                    "target_id": "SPURIOUS_PADDED_SILENCE",
                    "frame_range": [1450, 1500],
                    "mapping_member": False,
                },
                "targets": [],
            })
        t10 = {
            "schema_version": "1.0.0", "pack_id": "overlap-pack-v1",
            "constructed_mixtures": constructed_mixtures,
            "mixture_count": 10, "pair_target_count": 20,
            "aligner_row_count": 28, "aligner_process_count": 2,
            "community_process_count": 10,
            "korean_geometry": {}, "singles": [], "single_count": 0,
            "korean_absent_terms": [], "ami_parity_windows": [],
            "fleurs_selection": {}, "source_hashes_before": {},
            "source_hashes_after": {}, "fleurs_source_hashes_before": {},
            "fleurs_source_hashes_after": {},
        }
        t10_path = root / "overlap-pack/pack-manifest.json"
        _write_json(t10_path, t10)
        t10_ref = {
            "run_path": "overlap-pack/pack-manifest.json", "sha256": _sha(t10_path),
            "bytes": t10_path.stat().st_size,
        }
        pack = {
            "schema_version": "community1-evidence-pack-v2",
            "model_id": community["model_id"],
            "model_revision": community["revision"],
            "t9_canonical": canonical_ref,
            "t10_pack_manifest": t10_ref,
            "records": records,
        }
        raw_pack = json.dumps(
            pack, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode("utf-8")
        pack_ref = community["pack_manifest"]
        pack_path = root / pack_ref["run_path"]
        pack_path.parent.mkdir(parents=True, exist_ok=True)
        pack_path.write_bytes(raw_pack)
        pack_ref.update({
            "sha256": hashlib.sha256(raw_pack).hexdigest(), "bytes": len(raw_pack),
        })
        community["raw_evidence_index_sha256"] = manifest._canonical_sha(records)
        community["activity_provider_sha256"] = manifest._canonical_sha(activity_hashes)
        community["raw_evidence_sha256"] = pack_ref["sha256"]
        document["activity_providers"]["community1"] = community["activity_provider_sha256"]
        document["activity_providers"]["community1_spurious"] = manifest._canonical_sha(
            spurious_hashes
        )

        mapping_index = {item["window_id"]: item for item in document["mappings"]}
        for arm in document["arms"]:
            condition = arm["condition"]
            if arm["model"] != "dicow" or condition not in (
                "dicow-mix-O-community1", "dicow-full-mix-community1",
                "surplus-diagnostic", "dicow-full-spurious",
            ) or arm["availability"]["status"] != "available":
                continue
            execution = arm["execution_input"]
            if execution["execution_kind"] == "virtual_absent":
                continue
            window_id = arm["window_id"]
            replay = replay_by_window[window_id]
            labels = replay["labels"]
            activity = replay["activity"]
            if condition == "dicow-full-spurious":
                activity = replay["spurious_activity"]
                target_row = len(activity) - 1
                arm["activity_provider_sha256"] = document["activity_providers"]["community1_spurious"]
            elif condition == "surplus-diagnostic":
                target_row = labels.index(arm["target_id"])
                arm["activity_provider_sha256"] = document["activity_providers"]["community1"]
            else:
                slots = mapping_index[window_id]["slots"]
                slot_index = next(
                    index for index, slot in enumerate(slots)
                    if slot["reference_id"] == arm["target_id"]
                )
                if arm["provider_assignment"] == "swapped":
                    slot_index = 1 - slot_index
                target_row = labels.index(slots[slot_index]["provider_label"])
                arm["activity_provider_sha256"] = document["activity_providers"]["community1"]
            crop = None
            if arm["arm_kind"] == "crop":
                geometry = arm["geometry"]
                crop = (geometry["k_start_sample"], geometry["k_end_sample"])
            stno_sha, non_target_or_overlap = manifest._community_stno_replay(
                activity, target_row, crop
            )
            arm["stno"].update({
                "sha256": stno_sha,
                "non_target_or_overlap_frames": non_target_or_overlap,
            })
            execution["stno_sha256"] = arm["stno"]["sha256"]

        arms_by_id = {arm["arm_id"]: arm for arm in document["arms"]}
        for metric in document["metrics"]:
            for citation in metric["arm_citations"]:
                cited = arms_by_id[citation["arm_id"]]
                citation["activity_provider_sha256"] = cited["activity_provider_sha256"]
                citation["stno_sha256"] = (
                    cited["stno"]["sha256"] if isinstance(cited["stno"], dict) else None
                )

        for arm in document["arms"]:
            execution = arm["execution_input"]
            if execution["execution_kind"] == "virtual_absent":
                continue
            if execution["execution_kind"] == "typed_failure":
                parsed_value = {"code": "runner_error", "message": "typed fixture failure"}
                terminal_value = {
                    "schema_version": "dicow-terminal-failure-v1",
                    "failure": parsed_value,
                }
            else:
                parsed_value = execution["result"]
                terminal_value = {
                    "schema_version": "dicow-terminal-output-v1",
                    "result": parsed_value,
                }
            terminal = json.dumps(
                terminal_value,
                sort_keys=True, separators=(",", ":"), ensure_ascii=False,
            ).encode("utf-8")
            stdout = root / execution["raw_stdout"]["run_path"]
            stderr = root / execution["raw_stderr"]["run_path"]
            stdout.parent.mkdir(parents=True, exist_ok=True)
            stderr.parent.mkdir(parents=True, exist_ok=True)
            stdout.write_bytes(terminal)
            stderr.write_bytes(b"")
            execution["raw_stdout"].update({
                "sha256": hashlib.sha256(terminal).hexdigest(), "bytes": len(terminal),
            })
            execution["raw_stderr"].update({
                "sha256": hashlib.sha256(b"").hexdigest(), "bytes": 0,
            })
            execution["raw_output_sha256"] = execution["raw_stdout"]["sha256"]
            execution["parsed_result_sha256"] = manifest._canonical_sha(parsed_value)
            provenance = next(
                item for item in document["execution_provenance"]
                if item["provenance_id"] == execution["provenance_id"]
            )
            execution["argv"] = manifest._expected_execution_argv(
                arm, execution, provenance
            )
            receipt_value = manifest._expected_execution_receipt(
                arm, execution,
                {**provenance, "_execution_basis": document["execution_basis"]},
            )
            receipt_bytes = json.dumps(
                receipt_value, sort_keys=True, separators=(",", ":"), ensure_ascii=False
            ).encode("utf-8")
            receipt = execution["receipt"]
            receipt_path = root / receipt["run_path"]
            receipt_path.parent.mkdir(parents=True, exist_ok=True)
            receipt_path.write_bytes(receipt_bytes)
            receipt.update({
                "sha256": hashlib.sha256(receipt_bytes).hexdigest(),
                "bytes": len(receipt_bytes),
            })
            execution["sha256"] = manifest._canonical_sha({
                key: value for key, value in execution.items() if key != "sha256"
            })

    def _future_gate_fixture(self, root: Path) -> Path:
        evidence = FableVerificationTests()._fixture(root)
        provenance_path = evidence / "fable-provenance.json"
        provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
        thresholds_path = evidence / "thresholds.json"
        metric_path = evidence / "j1-readiness.json"
        _write_json(thresholds_path, manifest._expected_threshold_document())
        artifact_paths = {
            "thresholds": thresholds_path,
            "fable_decision": evidence / "fable-decision.json",
            "j1_readiness": metric_path,
        }
        evidence_artifacts = [
            {
                "key": key,
                "path": path.name,
                "sha256": _sha(path),
                "bytes": path.stat().st_size,
            }
            for key, path in artifact_paths.items()
        ]
        threshold_sha = _sha(thresholds_path)
        gate = {
            "schema_version": "dicow-gate-v1",
            "gate_id": "J1",
            "gate_kind": "fable_checkpoint",
            "task": "T8",
            "branch_verdict": "proceed",
            "evidence_outcome": "supported",
            "evidence_ids": ["j1-contract-readiness"],
            "evidence_hashes": {
                record["key"]: record["sha256"] for record in evidence_artifacts
            },
            "evidence_artifacts": evidence_artifacts,
            "assumptions": [],
            "allowed_scope": {
                "execute": ["T{}".format(index) for index in range(9, 17)],
                "constraints": ["sealed evidence only"],
            },
            "next_task_ids": ["T9"],
            "skip_tasks": [],
            "skipped_descendants": [],
            "reversal_condition": "new contrary evidence",
            "fable": {
                "requested_model": "fable",
                "actual_model": "claude-fable-5",
                "effort": "max",
                "fallback": False,
                "cli_version": "fixture",
                "session_id": "session-1",
                "prompt_sha256": provenance["prompt_sha256"],
                "input_hashes": provenance["input_hashes"],
                "raw_result_sha256": provenance["raw_result_sha256"],
                "decision_path": "fable-decision.json",
                "decision_sha256": _sha(evidence / "fable-decision.json"),
                "decision_authenticated": True,
                "provenance_path": "fable-provenance.json",
                "provenance_sha256": _sha(provenance_path),
            },
            "frontier_refresh": {
                "query_manifest_sha256": provenance["query_manifest_sha256"],
                "ledger_sha256": provenance["frontier_ledger_sha256"],
                "source_capture_manifest_sha256": provenance["source_capture_manifest_sha256"],
                "search_cutoff_utc": "2026-08-30T11:30:00Z",
                "fable_session_start_utc": provenance["session_started_at_utc"],
                "maximum_capture_age_hours": 6,
                "required_families": list(pins.REQUIRED_FRONTIER_FAMILIES),
                "qwen_branches": list(pins.QWEN_BRANCH_KINDS),
                "qwen_seed_queries": list(pins.QWEN_SEED_NAMES),
            },
            "metrics": [{
                "metric_id": "j1-readiness",
                "criterion_id": "J1.contract_readiness",
                "gate": "J1",
                "estimand": "contract_readiness",
                "stratum": "not_applicable",
                "availability": {"status": "available", "reason": None},
                "point": 1,
                "interval": None,
                "target_proportion": None,
                "cluster_count": 0,
                "passed": True,
                "evidence_key": "j1_readiness",
                "evidence_sha256": _sha(metric_path),
                "thresholds_sha256": threshold_sha,
            }],
            "thresholds_sha256": threshold_sha,
            "issued_at_utc": "2026-08-30T12:00:00Z",
        }
        gate_path = evidence / "gate.json"
        _write_json(gate_path, gate)
        return gate_path

    def _non_fable_gate_fixture(self, root: Path, gate_id: str) -> Path:
        _write_json(root / "run-manifest.json", {"run_id": "run-1"})
        gate_dir = root / gate_id.lower()
        thresholds_path = gate_dir / "thresholds.json"
        evidence_path = gate_dir / "negative-evidence.json"
        _write_json(thresholds_path, manifest._expected_threshold_document())
        _write_json(evidence_path, {"result": "typed negative"})
        threshold_sha = _sha(thresholds_path)
        artifacts = [
            {"key": "thresholds", "path": "thresholds.json", "sha256": threshold_sha, "bytes": thresholds_path.stat().st_size},
            {"key": "negative", "path": "negative-evidence.json", "sha256": _sha(evidence_path), "bytes": evidence_path.stat().st_size},
        ]
        partial = {
            "PA-T9": ("T9", ["T10", "T11", "T12", "T13", "T14", "T15"], "PA-T9.preflight_stop", "E0", "preflight"),
            "PA-T11": ("T11", ["T13", "T14", "T15"], "PA-T11.correction_burden", "E3", "correction_burden"),
            "PA-T12": ("T12", ["T13", "T14", "T15"], "PA-T12.local_derivative_permission", "E5", "license_permission"),
            "PA-T14": ("T14", ["T15"], "PA-T14.upstream_utility", "E4", "upstream_utility"),
            "PA-T15": ("T15", [], "PA-T15.shipped_stop", "E6", "shipped_comparison"),
        }
        if gate_id in partial:
            task, skips, criterion_id, metric_gate, estimand = partial[gate_id]
            kind = "partial_phase_a_stop"
            verdict = "stop"
            outcome = "not_supported"
            next_tasks = ["T16"]
            executable = ["T16"]
            availability = {"status": "available", "reason": None}
            point = 0
            passed = False
            if gate_id == "PA-T11":
                correction_document = ExperimentContractTests()._document()
                correction_document["correction_burden"] = {
                    "availability": availability,
                    "unit": "seconds",
                    "allowed_causes": [
                        "missed_target_in_overlap", "other_speaker_intrusion", "duplicate_overlap",
                    ],
                    "overlap_caused_seconds": 4.99,
                    "total_seconds": 100,
                    "ratio": 0.0499,
                    "percentage": 4.99,
                    "uncertain_seconds": 0,
                    "meeting_sha256": ExperimentContractTests()._h("meeting"),
                }
                self._materialize_experiment_evidence(root, correction_document)
                _write_json(evidence_path, correction_document)
                artifacts[1].update({
                    "sha256": _sha(evidence_path),
                    "bytes": evidence_path.stat().st_size,
                })
                point = 0.0499
        elif gate_id == "CONTROL-T23":
            task = "T23"
            kind = "control_envelope_closeout"
            verdict = "closeout"
            outcome = "evidence_blocker"
            next_tasks = ["T25"]
            skips = ["T24"]
            executable = ["T25"]
            criterion_id = "CONTROL-T23.control_envelope"
            metric_gate = "CONTROL"
            estimand = "control_envelope"
            availability = {"status": "unavailable", "reason": "control envelope invalid after bounded repair"}
            point = None
            passed = None
        else:
            raise AssertionError("unsupported fixture gate {}".format(gate_id))
        gate = {
            "schema_version": "dicow-gate-v1",
            "gate_id": gate_id,
            "gate_kind": kind,
            "task": task,
            "branch_verdict": verdict,
            "evidence_outcome": outcome,
            "evidence_ids": ["typed-negative"],
            "evidence_hashes": {item["key"]: item["sha256"] for item in artifacts},
            "evidence_artifacts": artifacts,
            "assumptions": [],
            "allowed_scope": {"execute": executable, "constraints": ["bounded closure"]},
            "next_task_ids": next_tasks,
            "skip_tasks": skips,
            "skipped_descendants": skips,
            "reversal_condition": "valid replacement evidence",
            "fable": None,
            "frontier_refresh": None,
            "metrics": [{
                "metric_id": "negative-criterion",
                "criterion_id": criterion_id,
                "gate": metric_gate,
                "estimand": estimand,
                "stratum": "not_applicable",
                "availability": availability,
                "point": point,
                "interval": None,
                "target_proportion": None,
                "cluster_count": 0,
                "passed": passed,
                "evidence_key": "negative",
                "evidence_sha256": _sha(evidence_path),
                "thresholds_sha256": threshold_sha,
            }],
            "thresholds_sha256": threshold_sha,
            "issued_at_utc": "2026-08-30T12:00:00Z",
        }
        gate_path = gate_dir / "gate.json"
        _write_json(gate_path, gate)
        return gate_path

    def _j2_metric_fixture(self, root: Path) -> tuple[dict, dict, Path]:
        document = ExperimentContractTests()._document()
        arms_by_id = {arm["arm_id"]: arm for arm in document["arms"]}
        target_by_stratum = {
            metric["stratum"]: arms_by_id[metric["arm_citations"][0]["arm_id"]]["target_id"]
            for metric in document["metrics"]
        }

        def citation(arm: dict) -> dict:
            return {
                "arm_id": arm["arm_id"],
                "fixture_family": arm["fixture_family"],
                "window_id": arm["window_id"],
                "target_id": arm["target_id"],
                "reference_id": arm["reference_id"],
                "repetition": arm["repetition"],
                "model": arm["model"],
                "condition": arm["condition"],
                "evaluation_role": arm["evaluation_role"],
                "provider_assignment": arm["provider_assignment"],
                "arm_kind": arm["arm_kind"],
                "audio_sha256": arm["audio_sha256"],
                "activity_provider_sha256": arm["activity_provider_sha256"],
                "stno_sha256": arm["stno"]["sha256"] if arm["stno"] else None,
                "k_sha256": arm["geometry"]["k_sha256"] if arm["geometry"] else None,
                "k_frames_sha256": arm["geometry"]["k_frames_sha256"] if arm["geometry"] else None,
                "regional_edit_path_sha256": (
                    arm["output"]["stable_o_counts"]["regional_edit_path_sha256"]
                    if arm["output"]["stable_o_counts"] else None
                ),
            }

        def citations_for(criterion_id: str, stratum: str) -> list[dict]:
            target_id = target_by_stratum.get(stratum, target_by_stratum["overall"])
            target_arm = next(arm for arm in document["arms"] if arm["target_id"] == target_id)
            if criterion_id == "S5.spurious_empty_proportion":
                selected = [
                    arm for arm in document["arms"]
                    if arm["condition"] == "dicow-full-spurious"
                    and (stratum == "overall" or arm["language"] == stratum)
                ]
            elif criterion_id == "S0.repeat_identity":
                selected = [
                    next(
                        arm for arm in document["arms"]
                        if arm["target_id"] == selected_target
                        and arm["condition"] == "dicow-full-mix-community1"
                        and arm["evaluation_role"] == "corrected_prompt_on"
                        and arm["repetition"] == repetition
                    )
                    for selected_target in sorted({
                        arm["target_id"] for arm in document["arms"]
                        if arm["condition"] == "dicow-mix-O-community1"
                        and arm["provider_assignment"] == "correct"
                        and arm["evaluation_role"] == "corrected_prompt_on"
                        and arm["repetition"] == 1
                    })
                    for repetition in (1, 2)
                ]
            elif criterion_id == "S7.absent_term_insertions":
                selected = [
                    arm for arm in document["arms"]
                    if arm["condition"] == "dicow-fleurs-ko-clean"
                ]
            else:
                roles = manifest._J2_STRATUM_CAUSAL_ROLES.get(
                    (criterion_id, stratum), manifest._J2_CAUSAL_ROLES[criterion_id]
                )
                target_ids = [
                    arm["target_id"] for arm in document["arms"]
                    if arm["condition"] == "dicow-mix-O-community1"
                    and arm["provider_assignment"] == "correct"
                    and arm["evaluation_role"] == "corrected_prompt_on"
                    and arm["repetition"] == 1
                    and (stratum == "overall" or arm["language"] == stratum)
                ]
                selected = []
                for selected_target in target_ids:
                    for repetition in (1, 2):
                        for model, condition, evaluation_role, assignment, kind in roles:
                            matched = next((
                                arm for arm in document["arms"]
                                if arm["target_id"] == selected_target
                                and arm["model"] == model
                                and arm["condition"] == condition
                                and arm["evaluation_role"] == evaluation_role
                                and arm["provider_assignment"] == assignment
                                and arm["arm_kind"] == kind
                                and arm["repetition"] == repetition
                            ), None)
                            if matched is None:
                                raise AssertionError(
                                    "missing fixture role {} {} {}".format(
                                        criterion_id, stratum,
                                        (model, condition, evaluation_role, assignment, kind),
                                    )
                                )
                            selected.append(matched)
            return [citation(arm) for arm in selected]
        utility_sha = document["utility_contract"]["sha256"]
        experiment_metrics = []
        gate_metrics = []
        for index, (criterion_id, gate_name, estimand, stratum) in enumerate(
            sorted(manifest._required_metric_matrix("J2"))
        ):
            point = 1.0
            interval = None
            proportion = None
            if criterion_id == "S3.shipped_korean_overlap_penalty":
                point = 0.01
            elif criterion_id == "S4.d_turbo_o":
                point = 0.4
                interval = {"kind": "two_sided_95_percentile", "lower": 0.4, "upper": 0.4}
            elif criterion_id == "S4.g_oracle_o":
                point = 0.3
                interval = {"kind": "two_sided_95_percentile", "lower": 0.3, "upper": 0.3}
                proportion = 1.0
            elif criterion_id in ("S4.p_oracle_n", "S4.p_community1_n"):
                point = 0.01
                interval = {"kind": "one_sided_upper_95_percentile", "upper": 0.01}
            elif criterion_id == "S5.swap_margin":
                point = 0.3
                interval = {"kind": "two_sided_95_percentile", "lower": 0.3, "upper": 0.3}
                proportion = 1.0
            elif criterion_id == "S5.g_community1_o":
                point = 0.25
                interval = {"kind": "two_sided_95_percentile", "lower": 0.25, "upper": 0.25}
            elif criterion_id == "S5.half_oracle_margin":
                point = 0.1
                interval = {"kind": "two_sided_95_percentile", "lower": 0.1, "upper": 0.1}
            elif criterion_id == "S5.spurious_empty_proportion":
                point = 1.0
            elif criterion_id in (
                "S4.target_character_preservation_oracle",
                "S5.target_character_preservation_community1",
            ):
                point = (
                    80 / 90 if criterion_id == "S4.target_character_preservation_oracle"
                    else 75 / 90
                )
                interval = {"kind": "two_sided_95_percentile", "lower": point, "upper": point}
            elif criterion_id == "S6.dicow_over_turbo_cer":
                point = 0.01
            elif criterion_id == "S7.prompt_recall_delta":
                point = 1.0
            elif criterion_id in ("S7.absent_term_insertions", "S7b.cross_speaker_insertions"):
                point = 0
            elif criterion_id == "S7b.prompt_recall_delta":
                point = 1.0
                interval = {"kind": "two_sided_95_percentile", "lower": 1.0, "upper": 1.0}
            elif criterion_id == "S9.dicow_cer_improvement":
                point = 0.1
            elif criterion_id == "S9.cache_degradation":
                point = 0.10 if stratum == "it" else 0.09
            metric_id = "j2-{:02d}".format(index)
            arm_citations = citations_for(criterion_id, stratum)
            cluster_count = len({
                (item["window_id"], item["repetition"]) for item in arm_citations
            })
            experiment_metric = {
                "metric_id": metric_id,
                "criterion_id": criterion_id,
                "gate": gate_name,
                "estimand": estimand,
                "availability": {"status": "available", "reason": None},
                "point": point,
                "interval": interval,
                "target_proportion": proportion,
                "stratum": stratum,
                "cluster_count": cluster_count,
                "arm_citations": arm_citations,
                "utility_contract_sha256": utility_sha,
            }
            experiment_metrics.append(experiment_metric)
        document["metrics"] = experiment_metrics
        self._materialize_experiment_evidence(root, document)
        experiment_path = root / "phase-a-experiment.json"
        _write_json(experiment_path, document)
        evidence_sha = _sha(experiment_path)
        threshold_sha = "a" * 64
        for experiment_metric in experiment_metrics:
            metric = {
                key: deepcopy(experiment_metric[key])
                for key in (
                    "metric_id", "criterion_id", "gate", "estimand", "stratum",
                    "availability", "point", "interval", "target_proportion", "cluster_count",
                )
            }
            metric.update({
                "passed": True,
                "evidence_key": "phase_a_experiment",
                "evidence_sha256": evidence_sha,
                "thresholds_sha256": threshold_sha,
            })
            gate_metrics.append(metric)
        gate = {
            "gate_id": "J2",
            "gate_kind": "fable_checkpoint",
            "branch_verdict": "proceed",
            "thresholds_sha256": threshold_sha,
            "metrics": gate_metrics,
        }
        artifact_index = {
            "phase_a_experiment": (
                experiment_path,
                {"key": "phase_a_experiment", "sha256": evidence_sha},
            ),
        }
        return gate, artifact_index, experiment_path

    def test_real_t0_gate_is_structurally_and_cryptographically_valid(self) -> None:
        gate_value = os.environ.get("MACCHERONI_DICOW_T0_GATE")
        if not gate_value:
            self.skipTest("set MACCHERONI_DICOW_T0_GATE for sealed T0 integration evidence")
        gate = Path(gate_value)
        if not gate.exists():
            self.skipTest("sealed T0 evidence is not present")
        manifest.verify_gate(gate)

    def test_future_gate_verifies_complete_fable_and_frontier_package(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            manifest.verify_gate(self._future_gate_fixture(Path(temporary)))

    def test_non_fable_partial_stop_and_control_closeout_verify(self) -> None:
        for gate_id in ("PA-T9", "PA-T11", "PA-T12", "PA-T14", "PA-T15", "CONTROL-T23"):
            with self.subTest(gate_id=gate_id), tempfile.TemporaryDirectory() as temporary:
                manifest.verify_gate(self._non_fable_gate_fixture(Path(temporary), gate_id))

    def test_pa_t11_correction_ratio_boundary_is_frozen(self) -> None:
        def metric(point: float) -> dict:
            return {
                "criterion_id": "PA-T11.correction_burden",
                "point": point,
                "interval": None,
                "target_proportion": None,
            }

        self.assertFalse(manifest._recompute_metric_passed(metric(0.0499)))
        self.assertTrue(manifest._recompute_metric_passed(metric(0.05)))
        self.assertTrue(manifest._recompute_metric_passed(metric(0.0501)))
        with tempfile.TemporaryDirectory() as temporary:
            gate_path = self._non_fable_gate_fixture(Path(temporary), "PA-T11")
            gate = json.loads(gate_path.read_text(encoding="utf-8"))
            gate["metrics"][0]["point"] = 0.04
            _write_json(gate_path, gate)
            with self.assertRaisesRegex(manifest.VerificationError, "must equal"):
                manifest.verify_gate(gate_path)

    def test_partial_stop_rejects_omitted_pending_descendant(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            gate_path = self._non_fable_gate_fixture(Path(temporary), "PA-T14")
            gate = json.loads(gate_path.read_text(encoding="utf-8"))
            gate["skip_tasks"] = []
            gate["skipped_descendants"] = []
            _write_json(gate_path, gate)
            with self.assertRaises(manifest.VerificationError):
                manifest.verify_gate(gate_path)

    def test_j2_exact_criterion_matrix_and_bound_experiment_metrics(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            gate, artifacts, experiment_path = self._j2_metric_fixture(Path(temporary))
            manifest._verify_gate_metrics(gate, artifacts, {})
            informational = next(
                metric for metric in gate["metrics"]
                if metric["criterion_id"] == "S3.shipped_korean_overlap_penalty"
            )
            informational["point"] = 0.2
            informational["passed"] = False
            document = json.loads(experiment_path.read_text(encoding="utf-8"))
            bound = next(metric for metric in document["metrics"] if metric["metric_id"] == informational["metric_id"])
            bound["point"] = 0.2
            cited_ids = {citation["arm_id"] for citation in bound["arm_citations"]}
            for arm in document["arms"]:
                if arm["arm_id"] in cited_ids and arm["condition"] == "shipped-ko-meeting-mix":
                    replay = arm["output"]["score_replay"]
                    tokens = replay["reference"].split()
                    hypothesis = list(tokens)
                    for index in range(40):
                        hypothesis[index] = chr(0x6200 + index)
                    hypothesis_text = " ".join(hypothesis)
                    scored = score_target(
                        replay["reference"], hypothesis_text,
                        expected_terms=replay["expected_terms"],
                        absent_terms=replay["absent_terms"],
                        other_target_terms=replay["other_target_terms"],
                        reference_regions=replay["reference_regions"],
                    )
                    arm["execution_input"]["result"]["text"] = hypothesis_text
                    scored.update({
                        "token_ids_sha256": manifest._canonical_sha(
                            arm["execution_input"]["result"]["token_ids"]
                        ),
                        "normalized_text_sha256": hashlib.sha256(
                            scored["normalized_text"].encode("utf-8")
                        ).hexdigest(),
                        "character_insertions": scored["cer_counts"]["insertions"],
                        "word_insertions": scored["wer_counts"]["insertions"],
                    })
                    arm["output"] = scored
            ExperimentContractTests()._reseal_fixture_and_executions(document)
            self._materialize_experiment_evidence(Path(temporary), document)
            _write_json(experiment_path, document)
            evidence_sha = _sha(experiment_path)
            artifacts["phase_a_experiment"][1]["sha256"] = evidence_sha
            for metric in gate["metrics"]:
                metric["evidence_sha256"] = evidence_sha
            manifest._verify_gate_metrics(gate, artifacts, {})
            wrong_estimand = deepcopy(gate)
            cell = next(
                metric for metric in wrong_estimand["metrics"]
                if metric["criterion_id"] == "S4.g_oracle_o" and metric["stratum"] == "overall"
            )
            cell["estimand"] = "contract_readiness"
            with self.assertRaises(manifest.VerificationError):
                manifest._verify_gate_metrics(wrong_estimand, artifacts, {})
            missing = deepcopy(gate)
            missing["metrics"] = [
                metric for metric in missing["metrics"]
                if not (metric["criterion_id"] == "S5.half_oracle_margin" and metric["stratum"] == "en")
            ]
            with self.assertRaisesRegex(manifest.VerificationError, "matrix mismatch"):
                manifest._verify_gate_metrics(missing, artifacts, {})

    def test_experiment_path_rejects_self_consistent_inline_result_without_raw_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            _gate, _artifacts, experiment_path = self._j2_metric_fixture(Path(temporary))
            manifest.verify_experiment_path(experiment_path)
            document = json.loads(experiment_path.read_text(encoding="utf-8"))
            arm = next(
                item for item in document["arms"]
                if item["execution_input"]["execution_kind"] == "process"
            )
            execution = arm["execution_input"]
            execution["result"] = {"text": "forged", "token_ids": [999]}
            execution["parsed_result_sha256"] = manifest._canonical_sha(execution["result"])
            execution["sha256"] = manifest._canonical_sha({
                key: value for key, value in execution.items() if key != "sha256"
            })
            _write_json(experiment_path, document)
            with self.assertRaisesRegex(manifest.VerificationError, "runner receipt"):
                manifest.verify_experiment_path(experiment_path)

    def test_experiment_path_rejects_raw_path_escape_and_community_pack_forgery(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            _gate, _artifacts, experiment_path = self._j2_metric_fixture(Path(temporary))
            document = json.loads(experiment_path.read_text(encoding="utf-8"))
            arm = next(
                item for item in document["arms"]
                if item["execution_input"]["execution_kind"] == "process"
            )
            arm["execution_input"]["raw_stdout"]["run_path"] = "../escape.json"
            arm["execution_input"]["sha256"] = manifest._canonical_sha({
                key: value for key, value in arm["execution_input"].items() if key != "sha256"
            })
            _write_json(experiment_path, document)
            with self.assertRaisesRegex(manifest.VerificationError, "schema violation"):
                manifest.verify_experiment_path(experiment_path)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _gate, _artifacts, experiment_path = self._j2_metric_fixture(root)
            document = json.loads(experiment_path.read_text(encoding="utf-8"))
            pack_ref = document["community1"]["pack_manifest"]
            pack_path = root / pack_ref["run_path"]
            pack = json.loads(pack_path.read_text(encoding="utf-8"))
            raw_ref = pack["records"][0]["stdout"]
            forged_window = {
                "schema_version": "community1-window-output-v1",
                "window_id": pack["records"][0]["window_id"],
                "activity_matrix": {"forged-label": {"forged-target": 1.0}},
            }
            forged_bytes = json.dumps(
                forged_window, sort_keys=True, separators=(",", ":"), ensure_ascii=False
            ).encode("utf-8")
            (root / raw_ref["run_path"]).write_bytes(forged_bytes)
            raw_ref.update({
                "sha256": hashlib.sha256(forged_bytes).hexdigest(),
                "bytes": len(forged_bytes),
            })
            raw = json.dumps(
                pack, sort_keys=True, separators=(",", ":"), ensure_ascii=False
            ).encode("utf-8")
            pack_path.write_bytes(raw)
            pack_ref.update({
                "sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw),
            })
            document["community1"]["raw_evidence_sha256"] = pack_ref["sha256"]
            document["community1"]["raw_evidence_index_sha256"] = manifest._canonical_sha(
                pack["records"]
            )
            _write_json(experiment_path, document)
            with self.assertRaisesRegex(
                manifest.VerificationError, "(?:reproduce frozen mapping|valid 50Hz raster)"
            ):
                manifest.verify_experiment_path(experiment_path)

    def test_experiment_path_accepts_and_authenticates_typed_failure_stdout(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _gate, _artifacts, experiment_path = self._j2_metric_fixture(root)
            document = json.loads(experiment_path.read_text(encoding="utf-8"))
            document.update({
                "availability": {"status": "unavailable", "reason": "typed runner failure"},
                "failure": {
                    "code": "runner_error", "message": "typed fixture failure",
                    "evidence_outcome": "evidence_blocker",
                },
                "metrics": [],
            })
            arm = next(
                item for item in document["arms"]
                if item["execution_input"]["execution_kind"] == "process"
            )
            arm["availability"] = {"status": "unavailable", "reason": "runner failed"}
            arm["output"] = None
            arm["termination"] = None
            execution = arm["execution_input"]
            execution.update({"execution_kind": "typed_failure", "exit_status": 7, "result": None})
            self._materialize_experiment_evidence(root, document)
            _write_json(experiment_path, document)
            manifest.verify_experiment_path(experiment_path)

            receipt_path = root / execution["receipt"]["run_path"]
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            receipt["exit_status"] = 0
            _write_json(receipt_path, receipt)
            execution["receipt"].update({
                "sha256": _sha(receipt_path), "bytes": receipt_path.stat().st_size,
            })
            execution["sha256"] = manifest._canonical_sha({
                key: value for key, value in execution.items() if key != "sha256"
            })
            _write_json(experiment_path, document)
            with self.assertRaisesRegex(manifest.VerificationError, "runner receipt"):
                manifest.verify_experiment_path(experiment_path)

    def test_experiment_path_directly_rehashes_runner_and_model_asset(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _gate, _artifacts, experiment_path = self._j2_metric_fixture(root)
            manifest.verify_experiment_path(experiment_path)
            document = json.loads(experiment_path.read_text(encoding="utf-8"))
            provenance = document["execution_provenance"][0]

            model_path = Path(provenance["model_asset"]["path"])
            original_model = model_path.read_bytes()
            model_path.chmod(0o644)
            model_path.write_bytes(original_model + b"forged")
            model_path.chmod(0o444)
            with self.assertRaisesRegex(manifest.VerificationError, "model asset"):
                manifest.verify_experiment_path(experiment_path)
            model_path.chmod(0o644)
            model_path.write_bytes(original_model)
            model_path.chmod(0o444)

            runner_path = root / provenance["runner"]["run_path"]
            original_runner = runner_path.read_bytes()
            runner_path.chmod(0o644)
            runner_path.write_bytes(original_runner + b"forged")
            runner_path.chmod(0o444)
            with self.assertRaisesRegex(manifest.VerificationError, "SHA-256 mismatch"):
                manifest.verify_experiment_path(experiment_path)

    def test_community_oracle_bytes_must_equal_exact_t10_provider_tuple(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _gate, _artifacts, experiment_path = self._j2_metric_fixture(root)
            document = json.loads(experiment_path.read_text(encoding="utf-8"))
            pack_ref = document["community1"]["pack_manifest"]
            pack_path = root / pack_ref["run_path"]
            pack = json.loads(pack_path.read_text(encoding="utf-8"))
            oracle_ref = pack["records"][0]["oracle_activity"]
            first = [
                int(frame < 850 or 900 <= frame < 950) for frame in range(1500)
            ]
            second = [
                int(frame < 50 or frame >= 800) for frame in range(1500)
            ]
            forged = bytes(first + second)
            oracle_path = root / oracle_ref["run_path"]
            oracle_path.write_bytes(forged)
            oracle_ref.update({
                "sha256": hashlib.sha256(forged).hexdigest(), "bytes": len(forged),
            })
            raw_pack = json.dumps(
                pack, sort_keys=True, separators=(",", ":"), ensure_ascii=False
            ).encode("utf-8")
            pack_path.write_bytes(raw_pack)
            pack_ref.update({
                "sha256": hashlib.sha256(raw_pack).hexdigest(), "bytes": len(raw_pack),
            })
            document["community1"]["raw_evidence_sha256"] = pack_ref["sha256"]
            document["community1"]["raw_evidence_index_sha256"] = manifest._canonical_sha(
                pack["records"]
            )
            _write_json(experiment_path, document)
            with self.assertRaisesRegex(
                manifest.VerificationError, "exact T10 activity-provider tuple"
            ):
                manifest.verify_experiment_path(experiment_path)

    def test_community_audio_ref_must_resolve_the_exact_t10_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            _gate, _artifacts, experiment_path = self._j2_metric_fixture(root)
            document = json.loads(experiment_path.read_text(encoding="utf-8"))
            pack_ref = document["community1"]["pack_manifest"]
            pack_path = root / pack_ref["run_path"]
            pack = json.loads(pack_path.read_text(encoding="utf-8"))
            record = pack["records"][0]
            original = root / record["audio"]["run_path"]
            decoy = root / "community1/decoy-audio.wav"
            decoy.write_bytes(original.read_bytes())
            original.unlink()
            record["audio"]["run_path"] = str(decoy.relative_to(root))
            raw_pack = json.dumps(
                pack, sort_keys=True, separators=(",", ":"), ensure_ascii=False
            ).encode("utf-8")
            pack_path.write_bytes(raw_pack)
            pack_ref.update({
                "sha256": hashlib.sha256(raw_pack).hexdigest(), "bytes": len(raw_pack),
            })
            document["community1"]["raw_evidence_sha256"] = pack_ref["sha256"]
            document["community1"]["raw_evidence_index_sha256"] = manifest._canonical_sha(
                pack["records"]
            )
            _write_json(experiment_path, document)
            with self.assertRaisesRegex(
                manifest.VerificationError, "absolute T10 evidence path differs"
            ):
                manifest.verify_experiment_path(experiment_path)

    def test_j2_proceed_rejects_unavailable_and_duplicate_language_cell(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            gate, artifacts, experiment_path = self._j2_metric_fixture(Path(temporary))
            unavailable = next(
                metric for metric in gate["metrics"]
                if metric["criterion_id"] == "S4.p_oracle_n" and metric["stratum"] == "en"
            )
            unavailable.update({
                "availability": {"status": "unavailable", "reason": "eligible English cell missing"},
                "point": None,
                "interval": None,
                "target_proportion": None,
                "passed": None,
            })
            document = json.loads(experiment_path.read_text(encoding="utf-8"))
            bound = next(metric for metric in document["metrics"] if metric["metric_id"] == unavailable["metric_id"])
            for field in ("availability", "point", "interval", "target_proportion"):
                bound[field] = deepcopy(unavailable[field])
            _write_json(experiment_path, document)
            evidence_sha = _sha(experiment_path)
            artifacts["phase_a_experiment"][1]["sha256"] = evidence_sha
            for metric in gate["metrics"]:
                metric["evidence_sha256"] = evidence_sha
            with self.assertRaisesRegex(manifest.VerificationError, "proceed gate"):
                manifest._verify_gate_metrics(gate, artifacts, {})
        with tempfile.TemporaryDirectory() as temporary:
            gate, artifacts, experiment_path = self._j2_metric_fixture(Path(temporary))
            duplicate = next(
                metric for metric in gate["metrics"]
                if metric["criterion_id"] == "S4.d_turbo_o" and metric["stratum"] == "en"
            )
            duplicate["stratum"] = "it"
            document = json.loads(experiment_path.read_text(encoding="utf-8"))
            bound = next(metric for metric in document["metrics"] if metric["metric_id"] == duplicate["metric_id"])
            bound["stratum"] = "it"
            bound["arm_citations"] = deepcopy(next(
                metric["arm_citations"] for metric in document["metrics"]
                if metric["criterion_id"] == duplicate["criterion_id"]
                and metric["stratum"] == "it"
                and metric["metric_id"] != duplicate["metric_id"]
            ))
            _write_json(experiment_path, document)
            evidence_sha = _sha(experiment_path)
            artifacts["phase_a_experiment"][1]["sha256"] = evidence_sha
            for metric in gate["metrics"]:
                metric["evidence_sha256"] = evidence_sha
            with self.assertRaisesRegex(manifest.VerificationError, "duplicate (?:gate|experiment) metric criterion cell"):
                manifest._verify_gate_metrics(gate, artifacts, {})

    def test_j2_swap_margin_rejects_interval_touching_zero(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            gate, artifacts, experiment_path = self._j2_metric_fixture(Path(temporary))
            swap = next(
                metric for metric in gate["metrics"]
                if metric["criterion_id"] == "S5.swap_margin" and metric["stratum"] == "overall"
            )
            swap["interval"]["lower"] = 0.0
            document = json.loads(experiment_path.read_text(encoding="utf-8"))
            bound = next(metric for metric in document["metrics"] if metric["metric_id"] == swap["metric_id"])
            bound["interval"]["lower"] = 0.0
            _write_json(experiment_path, document)
            evidence_sha = _sha(experiment_path)
            artifacts["phase_a_experiment"][1]["sha256"] = evidence_sha
            for metric in gate["metrics"]:
                metric["evidence_sha256"] = evidence_sha
            with self.assertRaisesRegex(manifest.VerificationError, "(?:recomputation|asserted pass)"):
                manifest._verify_gate_metrics(gate, artifacts, {})

    def test_j2_metrics_reject_assertions_that_differ_from_bound_arm_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            _gate, _artifacts, experiment_path = self._j2_metric_fixture(Path(temporary))
            document = json.loads(experiment_path.read_text(encoding="utf-8"))
            criteria = sorted({metric["criterion_id"] for metric in document["metrics"]})
            for criterion_id in criteria:
                if criterion_id in {
                    "S4.target_character_preservation_oracle",
                    "S5.target_character_preservation_community1",
                }:
                    continue
                with self.subTest(criterion=criterion_id):
                    forged = deepcopy(document)
                    metric = next(item for item in forged["metrics"] if item["criterion_id"] == criterion_id)
                    metric["point"] = 0.123 if metric["point"] in (0, 1) else metric["point"] + 0.123
                    with self.assertRaisesRegex(manifest.VerificationError, "bound arm recomputation"):
                        manifest.verify_experiment_document(forged)

    def test_j2_rejects_single_repetition_fixture_relabel_and_edit_path_forgery(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            _gate, _artifacts, experiment_path = self._j2_metric_fixture(Path(temporary))
            document = json.loads(experiment_path.read_text(encoding="utf-8"))
            metric = next(item for item in document["metrics"] if item["criterion_id"] == "S7.prompt_recall_delta")
            metric["arm_citations"] = [
                citation for citation in metric["arm_citations"] if citation["repetition"] == 1
            ]
            with self.assertRaises(manifest.VerificationError):
                manifest.verify_experiment_document(document)

        with tempfile.TemporaryDirectory() as temporary:
            _gate, _artifacts, experiment_path = self._j2_metric_fixture(Path(temporary))
            document = json.loads(experiment_path.read_text(encoding="utf-8"))
            changed_ids = set()
            for arm in document["arms"]:
                if (
                    arm["target_id"] == "target-00"
                    and arm["condition"] == "turbo-clean-O"
                ):
                    arm["fixture_family"] = "fleurs-it-pair-v1"
                    changed_ids.add(arm["arm_id"])
            for metric in document["metrics"]:
                for citation in metric["arm_citations"]:
                    if citation["arm_id"] in changed_ids:
                        citation["fixture_family"] = "fleurs-it-pair-v1"
            with self.assertRaisesRegex(manifest.VerificationError, "fixture"):
                manifest.verify_experiment_document(document)

        with tempfile.TemporaryDirectory() as temporary:
            _gate, _artifacts, experiment_path = self._j2_metric_fixture(Path(temporary))
            document = json.loads(experiment_path.read_text(encoding="utf-8"))
            citation = document["metrics"][0]["arm_citations"][0]
            citation["regional_edit_path_sha256"] = "f" * 64
            with self.assertRaisesRegex(manifest.VerificationError, "regional_edit_path_sha256 differs"):
                manifest.verify_experiment_document(document)

    def test_j2_recomputes_prompt_and_warm_output_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            _gate, _artifacts, experiment_path = self._j2_metric_fixture(Path(temporary))
            document = json.loads(experiment_path.read_text(encoding="utf-8"))
            for arm in document["arms"]:
                if arm["condition"] != "dicow-hike-single":
                    continue
                if arm["evaluation_role"] == "prompt_off_control":
                    arm["output"]["term_recall"] = 0.6 if arm["repetition"] == 1 else 0.3
                elif arm["evaluation_role"] == "corrected_prompt_on":
                    arm["output"]["term_recall"] = 0.5 if arm["repetition"] == 1 else 0.8
            with self.assertRaisesRegex(
                manifest.VerificationError, "required repetition|scorer replay"
            ):
                manifest.verify_experiment_document(document)

        with tempfile.TemporaryDirectory() as temporary:
            _gate, _artifacts, experiment_path = self._j2_metric_fixture(Path(temporary))
            document = json.loads(experiment_path.read_text(encoding="utf-8"))
            for arm in document["arms"]:
                if arm["evaluation_role"] == "warm_order_b_then_a":
                    arm["output"]["token_ids_sha256"] = hashlib.sha256(
                        (arm["arm_id"] + "-different").encode("utf-8")
                    ).hexdigest()
            with self.assertRaisesRegex(
                manifest.VerificationError, "bound arm recomputation|token ID hash"
            ):
                manifest.verify_experiment_document(document)

    def test_preservation_rejects_reference_character_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            _gate, _artifacts, experiment_path = self._j2_metric_fixture(Path(temporary))
            document = json.loads(experiment_path.read_text(encoding="utf-8"))
            metric = next(
                item for item in document["metrics"]
                if item["criterion_id"] == "S4.target_character_preservation_oracle"
            )
            mixed_id = metric["arm_citations"][1]["arm_id"]
            mixed = next(arm for arm in document["arms"] if arm["arm_id"] == mixed_id)
            counts = mixed["output"]["stable_o_counts"]
            counts["reference_chars"] += 1
            counts["substitutions"] += 1
            with self.assertRaisesRegex(
                manifest.VerificationError, "reference character|stable_o_counts"
            ):
                manifest.verify_experiment_document(document)

    def test_every_j2_criterion_rejects_a_wrong_causal_role(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            _gate, _artifacts, experiment_path = self._j2_metric_fixture(Path(temporary))
            document = json.loads(experiment_path.read_text(encoding="utf-8"))
            ordinary = next(
                citation for metric in document["metrics"]
                if metric["criterion_id"] == "S4.g_oracle_o"
                for citation in metric["arm_citations"]
            )
            spurious = next(
                citation for metric in document["metrics"]
                if metric["criterion_id"] == "S5.spurious_empty_proportion"
                for citation in metric["arm_citations"]
            )
            for name in sorted({item[0] for item in manifest._required_metric_matrix("J2")}):
                with self.subTest(criterion=name):
                    forged = deepcopy(document)
                    metric = next(item for item in forged["metrics"] if item["criterion_id"] == name)
                    metric["arm_citations"] = [
                        deepcopy(ordinary if name == "S5.spurious_empty_proportion" else spurious)
                    ]
                    with self.assertRaises(manifest.VerificationError):
                        manifest.verify_experiment_document(forged)

    def test_character_preservation_recomputes_pooled_point_and_interval_boundaries(self) -> None:
        def set_constant_ratio(document: dict, numerator: int, denominator: int) -> None:
            preservation = {
                "S4.target_character_preservation_oracle",
                "S5.target_character_preservation_community1",
            }
            cited_ids = {
                citation["arm_id"]
                for metric in document["metrics"] if metric["criterion_id"] in preservation
                for citation in metric["arm_citations"]
            }
            cited_coordinates = {
                (citation["target_id"], citation["repetition"])
                for metric in document["metrics"] if metric["criterion_id"] in preservation
                for citation in metric["arm_citations"]
            }
            for arm in document["arms"]:
                if (
                    (arm["target_id"], arm["repetition"]) not in cited_coordinates
                    or arm["output"]["stable_o_counts"] is None
                ):
                    continue
                counts = arm["output"]["stable_o_counts"]
                is_preservation_mix = (
                    arm["arm_id"] in cited_ids and arm["condition"] in (
                        "dicow-mix-O-oracle", "dicow-mix-O-community1",
                    )
                )
                hits = numerator if is_preservation_mix else denominator
                counts.update({
                    "reference_chars": denominator,
                    "substitutions": denominator - hits,
                    "deletions": 0,
                    "insertions": 0,
                    "hits": hits,
                })
            ratio = numerator / denominator
            for metric in document["metrics"]:
                if metric["criterion_id"] in preservation:
                    metric["point"] = ratio
                    metric["interval"] = {
                        "kind": "two_sided_95_percentile", "lower": ratio, "upper": ratio,
                    }

        for numerator, expected in ((7499, False), (7500, True), (7501, True)):
            with self.subTest(numerator=numerator), tempfile.TemporaryDirectory() as temporary:
                _gate, _artifacts, experiment_path = self._j2_metric_fixture(Path(temporary))
                document = json.loads(experiment_path.read_text(encoding="utf-8"))
                set_constant_ratio(document, numerator, 10_000)
                metric = next(
                    item for item in document["metrics"]
                    if item["criterion_id"] == "S4.target_character_preservation_oracle"
                )
                self.assertIs(manifest._recompute_metric_passed(metric), expected)
                arm_by_id = {arm["arm_id"]: arm for arm in document["arms"]}
                citation_arms = [
                    arm_by_id[citation["arm_id"]] for citation in metric["arm_citations"]
                ]
                eligible_targets = {
                    citation["target_id"] for citation in metric["arm_citations"]
                }
                if expected:
                    manifest._verify_character_preservation(
                        metric, citation_arms, eligible_targets
                    )
                else:
                    with self.assertRaisesRegex(manifest.VerificationError, "required repetition"):
                        manifest._verify_character_preservation(
                            metric, citation_arms, eligible_targets
                        )

    def test_character_preservation_rejects_macro_average_bypass(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            _gate, _artifacts, experiment_path = self._j2_metric_fixture(Path(temporary))
            document = json.loads(experiment_path.read_text(encoding="utf-8"))
            preservation = next(
                metric for metric in document["metrics"]
                if metric["criterion_id"] == "S4.target_character_preservation_oracle"
                and metric["stratum"] == "overall"
            )
            keep = [preservation]
            for stratum in ("ko", "it", "en"):
                keep.append(next(
                    metric for metric in document["metrics"]
                    if metric["criterion_id"] == "S4.g_oracle_o" and metric["stratum"] == stratum
                ))
            document["metrics"] = keep
            cited_ids = {citation["arm_id"] for citation in preservation["arm_citations"]}
            cited_coordinates = {
                (citation["target_id"], citation["repetition"])
                for citation in preservation["arm_citations"]
            }
            for arm in document["arms"]:
                if (
                    (arm["target_id"], arm["repetition"]) not in cited_coordinates
                    or arm["output"]["stable_o_counts"] is None
                ):
                    continue
                counts = arm["output"]["stable_o_counts"]
                if arm["fixture_family"] == "hike-pair-v1":
                    denominator, numerator = 10_000, 7_400
                else:
                    denominator, numerator = 10, 10
                is_preservation_mix = (
                    arm["arm_id"] in cited_ids and arm["condition"] == "dicow-mix-O-oracle"
                )
                hits = numerator if is_preservation_mix else denominator
                counts.update({
                    "reference_chars": denominator,
                    "substitutions": denominator - hits,
                    "deletions": 0,
                    "insertions": 0,
                    "hits": hits,
                })
            macro = (0.74 + 1.0 + 1.0) / 3
            preservation["point"] = macro
            preservation["interval"] = {
                "kind": "two_sided_95_percentile", "lower": macro, "upper": macro,
            }
            arm_by_id = {arm["arm_id"]: arm for arm in document["arms"]}
            citation_arms = [
                arm_by_id[citation["arm_id"]] for citation in preservation["arm_citations"]
            ]
            eligible_targets = {
                citation["target_id"] for citation in preservation["arm_citations"]
            }
            with self.assertRaisesRegex(manifest.VerificationError, "pooled recomputation"):
                manifest._verify_character_preservation(
                    preservation, citation_arms, eligible_targets
                )

    def test_character_preservation_requires_complete_target_and_window_pairing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            _gate, _artifacts, experiment_path = self._j2_metric_fixture(Path(temporary))
            document = json.loads(experiment_path.read_text(encoding="utf-8"))
            metric = next(
                item for item in document["metrics"]
                if item["criterion_id"] == "S4.target_character_preservation_oracle"
                and item["stratum"] == "overall"
            )
            metric["arm_citations"] = metric["arm_citations"][:-2]
            with self.assertRaisesRegex(manifest.VerificationError, "exact eligible target stratum"):
                manifest.verify_experiment_document(document)

    def test_future_gate_rejects_provenance_that_overrides_raw_decision(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            gate_path = self._future_gate_fixture(Path(temporary))
            provenance_path = gate_path.parent / "fable-provenance.json"
            provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
            provenance["decision"] = "stop"
            provenance["evidence_outcome"] = "not_supported"
            provenance["skip_tasks"] = ["T{}".format(index) for index in range(9, 29)]
            _write_json(provenance_path, provenance)
            gate = json.loads(gate_path.read_text(encoding="utf-8"))
            gate["branch_verdict"] = "stop"
            gate["evidence_outcome"] = "not_supported"
            gate["skip_tasks"] = provenance["skip_tasks"]
            gate["skipped_descendants"] = provenance["skip_tasks"]
            gate["allowed_scope"]["execute"] = ["T29", "T30"]
            gate["fable"]["provenance_sha256"] = _sha(provenance_path)
            _write_json(gate_path, gate)
            with self.assertRaisesRegex(manifest.VerificationError, "authenticated Fable decision"):
                manifest.verify_gate(gate_path)

    def test_future_gate_rejects_unbound_evidence_hash(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            gate_path = self._future_gate_fixture(Path(temporary))
            gate = json.loads(gate_path.read_text(encoding="utf-8"))
            gate["evidence_hashes"]["forged"] = "a" * 64
            _write_json(gate_path, gate)
            with self.assertRaisesRegex(manifest.VerificationError, "keys must match exactly"):
                manifest.verify_gate(gate_path)

    def test_future_gate_rejects_partial_executable_scope(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            gate_path = self._future_gate_fixture(Path(temporary))
            gate = json.loads(gate_path.read_text(encoding="utf-8"))
            gate["allowed_scope"]["execute"] = ["T9"]
            _write_json(gate_path, gate)
            with self.assertRaisesRegex(manifest.VerificationError, "executable scope"):
                manifest.verify_gate(gate_path)

    def test_rejects_symlinked_gate_leaf(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            gate_path = self._future_gate_fixture(Path(temporary))
            alias = gate_path.parent / "gate-alias.json"
            alias.symlink_to(gate_path.name)
            with self.assertRaisesRegex(manifest.VerificationError, "symlink"):
                manifest.verify_gate(alias)

    def test_rejects_incompatible_verdict_and_outcome(self) -> None:
        with self.assertRaisesRegex(manifest.VerificationError, "incompatible"):
            manifest._verify_verdict_pair("proceed", "not_supported")

    def test_unavailable_requires_reason(self) -> None:
        with self.assertRaisesRegex(manifest.VerificationError, "reason"):
            manifest._verify_availability_records({"availability": "unavailable"})

    def test_rejects_unknown_j0_evidence_hash_key(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            gate_path = Path(temporary) / "frontier-j0" / "gate.json"
            gate_path.parent.mkdir(parents=True)
            _write_json(Path(temporary) / "run-manifest.json", {})
            with self.assertRaisesRegex(manifest.VerificationError, "unknown or unbound"):
                manifest._bind_gate_artifacts(
                    gate_path,
                    {"gate_id": "J0"},
                    {"forged_evidence": "a" * 64},
                )

    def test_recomputes_available_metric_instead_of_trusting_passed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            evidence_path = Path(temporary) / "metric.json"
            _write_json(evidence_path, {"fixture": "metric evidence"})
            evidence_sha = _sha(evidence_path)
            threshold_sha = "a" * 64
            gate = {
                "gate_id": "J1",
                "thresholds_sha256": threshold_sha,
                "metrics": [{
                    "metric_id": "forged-s4",
                    "criterion_id": "S4.g_oracle_o",
                    "gate": "S4",
                    "estimand": "G_q^O",
                    "stratum": "overall",
                    "availability": {"status": "available", "reason": None},
                    "point": -999.0,
                    "interval": {"kind": "two_sided_95_percentile", "lower": -1000.0, "upper": -998.0},
                    "target_proportion": 1.0,
                    "cluster_count": 20,
                    "passed": True,
                    "evidence_key": "metric_evidence",
                    "evidence_sha256": evidence_sha,
                    "thresholds_sha256": threshold_sha,
                }],
            }
            artifact_index = {
                "metric_evidence": (
                    evidence_path,
                    {"key": "metric_evidence", "sha256": evidence_sha},
                ),
            }
            with self.assertRaisesRegex(manifest.VerificationError, "asserted pass"):
                manifest._verify_gate_metrics(gate, artifact_index, {})


class TrackedTransitionTests(unittest.TestCase):
    def _fixture(self, root: Path) -> tuple[Path, Path]:
        run = root / "run"
        repo = root / "repo"
        lane = repo / "docs" / "dicow-conversion-lane.md"
        lane.parent.mkdir(parents=True)
        lane.write_text("sealed lane\n", encoding="utf-8")
        os.chmod(lane, 0o644)
        _write_json(run / "run-manifest.json", {
            "run_id": "run-1",
            "tracked_predecessors": {
                "docs/dicow-conversion-lane.md": {"absent": True},
            },
        })
        _write_json(run / "task-state" / "T1.json", {
            "schema_version": "dicow-task-state-v1",
            "task": "T1",
            "state": "done",
            "branch_disposition": "executed",
            "run_id": "run-1",
            "tracked_files": {
                "docs/dicow-conversion-lane.md": {
                    "input": {"absent": True},
                    "output": {
                        "sha256": _sha(lane),
                        "bytes": lane.stat().st_size,
                        "mode": "0644",
                    },
                },
            },
        })
        os.chmod(run / "task-state" / "T1.json", 0o444)
        return run, repo

    def _write_skip_gate(self, run: Path) -> tuple[Path, str]:
        gate_dir = run / "frontier-j0"
        gate_dir.mkdir(parents=True, exist_ok=True)
        evidence_hashes = {}
        for key, filename in (
            ("query_manifest", "query-manifest.json"),
            ("frontier_ledger", "frontier-ledger.json"),
            ("source_capture_manifest", "source-capture-manifest.json"),
            ("fable_raw", "fable-raw.json"),
            ("fable_decision", "fable-decision.json"),
        ):
            path = gate_dir / filename
            _write_json(path, {"fixture": key})
            evidence_hashes[key] = _sha(path)
        input_hashes = {"fixture": hashlib.sha256(b"fixture-input").hexdigest()}
        provenance = {
            "requested_model": "fable",
            "actual_model": "claude-fable-5",
            "effort": "max",
            "fallback": False,
            "cli_version": "fixture",
            "session_id": "skip-session",
            "prompt_sha256": hashlib.sha256(b"prompt").hexdigest(),
            "input_hashes": input_hashes,
            "raw_result_sha256": evidence_hashes["fable_raw"],
            "decision": "stop",
            "evidence_outcome": "not_supported",
        }
        provenance_path = gate_dir / "fable-provenance.json"
        _write_json(provenance_path, provenance)
        skips = ["T{}".format(index) for index in range(1, 29)]
        gate = {
            "schema_version": "dicow-gate-v1",
            "gate_id": "J0",
            "task": "T0",
            "branch_verdict": "stop",
            "evidence_outcome": "not_supported",
            "evidence_ids": ["fixture-stop"],
            "evidence_hashes": evidence_hashes,
            "assumptions": [],
            "allowed_scope": {"execute": ["T29", "T30"], "constraints": ["skip closure only"]},
            "next_task_ids": ["T1"],
            "skip_tasks": skips,
            "skipped_descendants": skips,
            "reversal_condition": "new evidence",
            "fable": {
                "requested_model": "fable",
                "actual_model": "claude-fable-5",
                "effort": "max",
                "fallback": False,
                "cli_version": "fixture",
                "session_id": "skip-session",
                "prompt_sha256": hashlib.sha256(b"prompt").hexdigest(),
                "input_hashes": input_hashes,
                "raw_result_sha256": evidence_hashes["fable_raw"],
                "provenance_path": "fable-provenance.json",
                "provenance_sha256": _sha(provenance_path),
            },
            "issued_at_utc": "2026-08-30T12:00:00Z",
        }
        gate_path = gate_dir / "gate.json"
        _write_json(gate_path, gate)
        return gate_path, _sha(gate_path)

    def test_accepts_initial_absence_to_t1_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run, repo = self._fixture(Path(temporary))
            manifest.verify_tracked_transition("T1", run, repo)

    def test_rejects_fresh_disk_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run, repo = self._fixture(Path(temporary))
            (repo / "docs" / "dicow-conversion-lane.md").write_text(
                "drifted lane\n", encoding="utf-8"
            )
            with self.assertRaisesRegex(manifest.VerificationError, "fresh disk"):
                manifest.verify_tracked_transition("T1", run, repo)

    def test_skipped_task_is_not_a_predecessor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run, repo = self._fixture(root)
            lane = repo / "docs" / "dicow-conversion-lane.md"
            t1 = json.loads((run / "task-state" / "T1.json").read_text())
            os.chmod(run / "task-state" / "T1.json", 0o644)
            t1["branch_disposition"] = "skipped"
            t1.pop("tracked_files")
            gate_path, gate_sha = self._write_skip_gate(run)
            t1.update({
                "gate_path": str(gate_path.relative_to(run)),
                "gate_sha256": gate_sha,
                "evidence_id": "fixture-stop",
                "reason": "J0 stop closure",
                "source_input_hashes": json.loads(gate_path.read_text())["evidence_hashes"],
            })
            _write_json(run / "task-state" / "T1.json", t1)
            os.chmod(run / "task-state" / "T1.json", 0o444)
            lane_tuple = {
                "sha256": _sha(lane), "bytes": lane.stat().st_size, "mode": "0644",
            }
            _write_json(run / "task-state" / "T1-contract-amendment-1.json", {
                "schema_version": "dicow-task-state-v1",
                "task": "T1-contract-amendment-1",
                "state": "done",
                "branch_disposition": "executed",
                "run_id": "run-1",
                "tracked_files": {
                    "docs/dicow-conversion-lane.md": {
                        "input": {"absent": True},
                        "output": deepcopy(lane_tuple),
                    },
                },
            })
            os.chmod(run / "task-state" / "T1-contract-amendment-1.json", 0o444)
            _write_json(run / "task-state" / "T16.json", {
                "schema_version": "dicow-task-state-v1",
                "task": "T16",
                "state": "done",
                "branch_disposition": "executed",
                "run_id": "run-1",
                "tracked_files": {
                    "docs/dicow-conversion-lane.md": {
                        "input": deepcopy(lane_tuple),
                        "output": deepcopy(lane_tuple),
                    },
                },
            })
            os.chmod(run / "task-state" / "T16.json", 0o444)
            manifest.verify_tracked_transition("T16", run, repo)

    def test_rejects_mutable_or_unverified_skip_state(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            run, repo = self._fixture(Path(temporary))
            os.chmod(run / "task-state" / "T1.json", 0o644)
            with self.assertRaisesRegex(manifest.VerificationError, "immutable"):
                manifest.verify_tracked_transition("T1", run, repo)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run, repo = self._fixture(root)
            lane = repo / "docs" / "dicow-conversion-lane.md"
            state_path = run / "task-state" / "T1.json"
            state = json.loads(state_path.read_text())
            os.chmod(state_path, 0o644)
            state["branch_disposition"] = "skipped"
            state.pop("tracked_files")
            gate_path, gate_sha = self._write_skip_gate(run)
            state.update({
                "gate_path": str(gate_path.relative_to(run)),
                "gate_sha256": gate_sha,
                "evidence_id": "fixture-stop",
                "source_input_hashes": json.loads(gate_path.read_text())["evidence_hashes"],
            })
            _write_json(state_path, state)
            os.chmod(state_path, 0o444)
            _write_json(run / "task-state" / "T16.json", {
                "schema_version": "dicow-task-state-v1",
                "task": "T16",
                "state": "done",
                "branch_disposition": "executed",
                "run_id": "run-1",
                "tracked_files": {"docs/dicow-conversion-lane.md": {
                    "input": {"absent": True},
                    "output": {"sha256": _sha(lane), "bytes": lane.stat().st_size, "mode": "0644"},
                }},
            })
            os.chmod(run / "task-state" / "T16.json", 0o444)
            with self.assertRaisesRegex(manifest.VerificationError, "reason"):
                manifest.verify_tracked_transition("T16", run, repo)
            os.chmod(state_path, 0o644)
            state["reason"] = "J0 stop closure"
            state["source_input_hashes"]["query_manifest"] = "a" * 64
            _write_json(state_path, state)
            os.chmod(state_path, 0o444)
            with self.assertRaisesRegex(manifest.VerificationError, "not bound"):
                manifest.verify_tracked_transition("T16", run, repo)


class R2ContractDeltaTests(unittest.TestCase):
    def _contract(self):
        return json.loads(json.dumps(manifest.r2_contract_template()))

    def _r4_gate_fixture(
        self,
        run: Path,
        *,
        scope: str = "proceed_qwen_only",
        evidence_outcome: str | None = None,
    ) -> tuple[Path, dict[str, Path]]:
        run = run.resolve()
        run_id = "r2-run"
        plan_path = run / "plan.md"
        plan_path.write_text("sealed plan contract\n", encoding="utf-8")
        plan_bytes = plan_path.stat().st_size
        run_manifest_path = run / "run-manifest.json"
        _write_json(run_manifest_path, {
            "run_id": run_id,
            "plan_contract": {
                "path": str(plan_path), "bytes": plan_bytes,
                "sha256": _sha(plan_path),
            },
        })
        states = run / "task-state"
        r1_path = states / "R1-contract-amendment-10.json"
        _write_json(r1_path, {
            "task": "R1-contract-amendment-10", "run_id": run_id, "state": "done",
        })
        r2_path = states / "R2.json"
        _write_json(r2_path, {
            "task": "R2", "run_id": run_id, "state": "done",
            "predecessor_state_hashes": {"R1": _sha(r1_path)},
        })
        spec_path = run / pins.R2_R3_FIXED_SOURCE_PATHS[
            manifest._R2_R3_ACTIVE_SPEC_SOURCE_KEY
        ]
        _write_json(spec_path, {"schema_version": "fixture-spec"})
        self._seal(spec_path)
        r3_path = states / "R3.json"
        _write_json(r3_path, {
            "task": "R3", "run_id": run_id, "state": "done",
            "branch_disposition": "executed", "evidence_outcome": "evidence_blocker",
            "next_task_ids": ["R4"],
            "predecessor_state_hashes": {"R1": _sha(r1_path), "R2": _sha(r2_path)},
            "source_input_hashes": {
                manifest._R2_R3_ACTIVE_SPEC_SOURCE_KEY: _sha(spec_path),
            },
        })
        attempt = (run / "pre-model-audit/attempts/fixture-0001").resolve()
        decision_path = attempt / "audit/decision.json"
        _write_json(decision_path, {
            "dicow_scope": "evidence_blocker",
            "qwen_asr_scope": "implementation_ready",
            "qwen_aligner_scope": "implementation_ready",
        })
        identities_path = attempt / "audit/model-identities.json"
        _write_json(identities_path, {"schema_version": "fixture"})
        selected_manifest = attempt / "manifest.json"
        _write_json(selected_manifest, {
            "schema_version": "dicow-r2-pre-model-audit-manifest-v1",
            "run_id": run_id,
            "spec_record": {"sha256": _sha(spec_path), "bytes": spec_path.stat().st_size},
        })
        self._seal(selected_manifest)
        canonical_path = run / "pre-model-audit/canonical.json"
        _write_json(canonical_path, {
            "schema_version": "dicow-r2-pre-model-audit-canonical-v1",
            "run_id": run_id, "attempt": str(attempt),
            "manifest_record": {
                "sha256": _sha(selected_manifest),
                "bytes": selected_manifest.stat().st_size,
            },
        })
        self._seal(canonical_path)

        cutoff = "2026-08-30T18:23:54Z"
        refresh = run / "r4-frontier-refresh.staging"
        refresh_documents = {
            "capture-manifest.json": {"search_cutoff_utc": cutoff},
            "frontier-delta.json": {"search_cutoff_utc": cutoff},
            "qwen-rights-and-identity.json": {"cutoff_utc": cutoff},
            "roster.json": {"search_cutoff_utc": cutoff},
            "three-axis-candidates.json": {"cutoff_utc": cutoff},
        }
        for name, value in refresh_documents.items():
            _write_json(refresh / name, value)
        (refresh / "synthesis.md").write_text(
            "# R4 refresh\n\nCutoff: `{}`\n".format(cutoff), encoding="utf-8"
        )
        (refresh / "verify-output.txt").write_text(
            "PASS r4 frontier delta offline verification: cutoff {}\n".format(cutoff),
            encoding="utf-8",
        )
        summed_names = (
            "capture-manifest.json", "frontier-delta.json",
            "qwen-rights-and-identity.json", "roster.json",
            "synthesis.md", "three-axis-candidates.json",
        )
        (refresh / "SHA256SUMS").write_text("".join(
            "{}  {}\n".format(_sha(refresh / name), name) for name in summed_names
        ), encoding="utf-8")
        advisory = run / pins.R2_J1_ADVISORY_PATH
        advisory.parent.mkdir(parents=True, exist_ok=True)
        advisory.write_text("advisory only\n", encoding="utf-8")

        gate_dir = run / "fable-j1"
        packet_path = gate_dir / "judgment-packet.txt"
        packet_path.parent.mkdir(parents=True, exist_ok=True)
        packet_path.write_text("bounded J1 judgment packet\n", encoding="utf-8")
        schema_bytes = len(json.dumps(
            manifest._r2_j1_output_schema(), sort_keys=True,
            separators=(",", ":"), ensure_ascii=False,
        ).encode("utf-8"))
        estimated = packet_path.stat().st_size + schema_bytes + pins.R2_J1_ESTIMATOR_OVERHEAD
        estimator_path = gate_dir / "estimator.json"
        _write_json(estimator_path, {
            "packet_utf8_bytes": packet_path.stat().st_size,
            "output_schema_utf8_bytes": schema_bytes,
            "overhead": pins.R2_J1_ESTIMATOR_OVERHEAD,
            "estimated_input_tokens": estimated,
            "packet_max_utf8_bytes": pins.R2_J1_PACKET_MAX_UTF8_BYTES,
            "operational_max_estimated_input_tokens": (
                pins.R2_J1_OPERATIONAL_MAX_ESTIMATED_INPUT_TOKENS
            ),
            "contract_max_estimated_input_tokens": pins.R2_FABLE_MAX_ESTIMATED_INPUT_TOKENS,
        })
        session_id = "11111111-1111-4111-8111-111111111111"
        session_start = "2026-08-30T18:25:54Z"
        latest = "2026-08-31T00:23:54Z"
        repo = Path(__file__).resolve().parents[4]
        authority_paths = {
            "plan_contract": (plan_path, str(plan_path), plan_bytes),
            "run_manifest": (run_manifest_path, "run-manifest.json", None),
            "effective_r1_state": (r1_path, "task-state/R1-contract-amendment-10.json", None),
            "r2_state": (r2_path, "task-state/R2.json", None),
            "r3_state": (r3_path, "task-state/R3.json", None),
            "pre_model_audit_manifest": (
                selected_manifest, str(selected_manifest.relative_to(run)), None,
            ),
            "pre_model_decision": (
                decision_path, str(decision_path.relative_to(run)), None,
            ),
            "active_spec": (spec_path, str(spec_path.relative_to(run)), None),
            "gate_schema": (
                repo / "docs/contracts/dicow-gate.schema.json",
                str(repo / "docs/contracts/dicow-gate.schema.json"), None,
            ),
            "pins": (
                repo / "benchmarks/scripts/dicow/common/pins.py",
                str(repo / "benchmarks/scripts/dicow/common/pins.py"), None,
            ),
            "manifest_verifier": (
                Path(manifest.__file__).resolve(), str(Path(manifest.__file__).resolve()), None,
            ),
            "advisory_checkpoint": (advisory, pins.R2_J1_ADVISORY_PATH, None),
        }
        for key, relative in pins.R2_J1_REFRESH_PATHS.items():
            authority_paths[key] = (run / relative, relative, None)
        roles = manifest._r2_j1_authority_roles()
        authorities = []
        for key, (path, display, prefix) in authority_paths.items():
            record = dict(manifest._r2_j1_record(path, display, prefix_bytes=prefix))
            record.update({
                "key": key, "role": roles[key][0], "claim_ceiling": roles[key][1],
            })
            authorities.append(record)
        graph_path = gate_dir / "machine-graph.json"
        _write_json(graph_path, {
            "schema_version": "dicow-r2-j1-machine-graph-v1",
            "run_id": run_id, "checkpoint": "J1-r2",
            "prepared_at_utc": "2026-08-30T18:24:54Z",
            "latest_permitted_session_start_utc": latest,
            "authorities": authorities,
            "derived_facts": {
                "r3_dicow_scope": "evidence_blocker",
                "qwen_asr_scope": "implementation_ready",
                "qwen_aligner_scope": "implementation_ready",
                "qwen_aligner_semantic_scope": "unestablished",
                "dicow_probe_scope": "successor_plan_reversal_only",
                "server_scope": "excluded", "baseline_scope": "excluded",
            },
            "claim_ceilings": [pins.R2_J1_QWEN_CLAIM_CEILING],
            "forbidden_pre_verdict_outputs": list(
                pins.R2_J1_FORBIDDEN_PRE_VERDICT_OUTPUTS
            ),
            "verification": {
                "status": "verified", "refresh_cutoff_utc": cutoff,
                "session_started_at_utc": session_start,
                "authority_count": len(roles),
            },
        })
        graph_record = {
            "path": graph_path.name, "sha256": _sha(graph_path),
            "bytes": graph_path.stat().st_size,
        }
        packet_path.write_bytes(manifest._r2_j1_packet(graph_record))
        estimated = packet_path.stat().st_size + schema_bytes + pins.R2_J1_ESTIMATOR_OVERHEAD
        _write_json(estimator_path, {
            "packet_utf8_bytes": packet_path.stat().st_size,
            "output_schema_utf8_bytes": schema_bytes,
            "overhead": pins.R2_J1_ESTIMATOR_OVERHEAD,
            "estimated_input_tokens": estimated,
            "packet_max_utf8_bytes": pins.R2_J1_PACKET_MAX_UTF8_BYTES,
            "operational_max_estimated_input_tokens": (
                pins.R2_J1_OPERATIONAL_MAX_ESTIMATED_INPUT_TOKENS
            ),
            "contract_max_estimated_input_tokens": pins.R2_FABLE_MAX_ESTIMATED_INPUT_TOKENS,
        })
        semantics = pins.R2_GATE_TASK_SEMANTICS[("J1-r2", scope)]
        if evidence_outcome is None:
            evidence_outcome = (
                "evidence_blocker"
                if scope == "proceed_qwen_only"
                else "not_supported" if scope == "revise_or_stop_all" else "supported"
            )
        decision = {
            "checkpoint": "J1-r2", "scope": scope,
            "evidence_outcome": evidence_outcome,
            "next_task_ids": list(semantics["next"]),
            "skip_task_ids": list(semantics["skip"]),
            "reversal_condition": (
                pins.R2_J1_REVERSAL_CONDITION
                if scope == "proceed_qwen_only"
                else "Fixture-specific typed reversal condition."
            ),
        }
        decision_path_out = gate_dir / "decision.json"
        decision_bytes = json.dumps(decision, sort_keys=True, separators=(",", ":")).encode()
        decision_path_out.write_bytes(decision_bytes)
        raw_path = gate_dir / "raw.json"
        _write_json(raw_path, {
            "terminal_reason": "completed", "is_error": False,
            "session_id": session_id,
            "modelUsage": {"claude-fable-5": {"inputTokens": estimated}},
            "result": decision_bytes.decode(),
        })
        artifact = lambda key, path: {
            "key": key, "path": path.name, "sha256": _sha(path),
            "bytes": path.stat().st_size,
        }
        gate = {
            "schema_version": "dicow-r2-gate-envelope-v1", "gate_id": "J1-r2",
            "task": "R4", "scope": scope,
            "evidence_outcome": evidence_outcome,
            "machine_evidence_graph": artifact("machine_graph", graph_path),
            "judgment_packet": artifact("judgment_packet", packet_path),
            "estimator_artifact": artifact("estimator", estimator_path),
            "decision": decision,
            "fable_result": {
                "terminal_reason": "completed", "is_error": False,
                "requested_model": "fable", "actual_model": "claude-fable-5",
                "effort": "max", "fallback": False, "context_tokens": 1_000_000,
                "usable_input_tokens": 996_678, "estimated_input_tokens": estimated,
                "cli_path": pins.R2_J1_CLAUDE_CLI, "cli_version": "2.1.251",
                "session_id": session_id, "session_started_at_utc": session_start,
                "fresh_session": True, "resumed": False,
                "argv": manifest._r2_j1_argv(str(run.resolve()), session_id),
                "tool_allowlist": ["Read"], "estimator_version": "j1-byte-formula-v1",
                "estimator_source_sha256": _sha(Path(manifest.__file__).resolve()),
                "prompt_sha256": _sha(packet_path), "raw_path": raw_path.name,
                "raw_sha256": _sha(raw_path), "decision_path": decision_path_out.name,
                "decision_sha256": _sha(decision_path_out),
                "input_hashes": {"machine_graph": _sha(graph_path)},
            },
            "r2_contract": self._contract(),
        }
        gate_path = gate_dir / "gate.json"
        _write_json(gate_path, gate)
        return gate_path, {
            "graph": graph_path, "packet": packet_path, "estimator": estimator_path,
            "raw": raw_path, "decision": decision_path_out,
            "spec": spec_path, "r3": r3_path,
        }

    @staticmethod
    def _seal(path: Path) -> None:
        os.chmod(path, 0o444)

    def _r2_bootstrap_fixture(self, run: Path) -> dict[str, Path]:
        repo = Path(__file__).resolve().parents[4]
        import_path = run / "import-r1/manifest.json"
        if import_path.exists():
            os.chmod(import_path, 0o644)
        _write_json(import_path, {"schema_version": "dicow-r1-import-v1"})
        self._seal(import_path)
        untracked = []
        tracked = {}
        before_paths = tuple(dict.fromkeys(
            pins.R2_TRACKED_FILES + pins.R2_TASK_TRACKED_FILES["R3"]
        ))
        for relative in before_paths:
            path = repo / relative
            record = {
                "sha256": _sha(path), "bytes": path.stat().st_size,
                "mode": "0{:03o}".format(path.stat().st_mode & 0o777),
            }
            untracked.append({"repo_path": relative, **record})
            if relative in pins.R2_TRACKED_FILES:
                tracked[relative] = {"input": record, "output": record}
        digest_path = repo / "docs/research-digest.md"
        before = run / "import-r1/repository-before-state.json"
        if before.exists():
            os.chmod(before, 0o644)
        _write_json(before, {
            "untracked_worktree": untracked,
            "tracked_worktree": [{
                "repo_path": "docs/research-digest.md", "sha256": _sha(digest_path),
                "bytes": digest_path.stat().st_size,
                "mode": "0{:03o}".format(digest_path.stat().st_mode & 0o777),
            }],
        })
        self._seal(before)
        manifest_path = run / "run-manifest.json"
        if manifest_path.exists():
            os.chmod(manifest_path, 0o644)
        _write_json(manifest_path, {
            "schema_version": "dicow-r2-run-manifest-v1", "run_id": "r2-run",
            "run_root": str(run.resolve()),
            "plan_contract": {"sha256": "a" * 64},
            "r1_import": {
                "path": "import-r1/manifest.json", "sha256": _sha(import_path),
                "bytes": import_path.stat().st_size, "mode": "0444",
            },
            "repository_before_state": {
                "path": str(before.resolve()),
                "run_path": "import-r1/repository-before-state.json",
                "sha256": _sha(before), "bytes": before.stat().st_size, "mode": "0444",
            },
        })
        self._seal(manifest_path)
        r0 = run / "task-state/R0.json"
        if r0.exists():
            os.chmod(r0, 0o644)
        _write_json(r0, {
            "schema_version": "dicow-r2-task-state-v1", "task": "R0",
            "state": "done", "branch_disposition": "executed",
            "evidence_outcome": "supported", "run_id": "r2-run",
            "next_task_ids": ["R1"], "no_valid_r1_j1_gate": True,
            "run_manifest_sha256": _sha(manifest_path),
            "source_input_hashes": {
                "plan_contract": "a" * 64,
                "r2_plan_review": "b" * 64,
            },
            "artifacts": {"import-manifest": {
                "path": "import-r1/manifest.json", "sha256": _sha(import_path),
                "bytes": import_path.stat().st_size, "mode": "0444",
            }},
        })
        self._seal(r0)
        r1 = run / "task-state/R1.json"
        if r1.exists():
            os.chmod(r1, 0o644)
        _write_json(r1, {
            "schema_version": "dicow-r2-task-state-v1", "task": "R1",
            "state": "done", "branch_disposition": "executed",
            "evidence_outcome": "supported", "run_id": "r2-run",
            "next_task_ids": ["R2"],
            "source_input_hashes": {"R0_state": _sha(r0), "run_manifest": _sha(manifest_path)},
            "tracked_files": tracked,
        })
        self._seal(r1)
        return {"R0": r0, "R1": r1}

    def _r3_publication_fields(self, run: Path, paths: dict[str, Path]) -> dict:
        for key, relative in pins.R2_R3_FIXED_SOURCE_PATHS.items():
            path = run / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            if path.exists():
                os.chmod(path, 0o644)
            path.write_text("{} fixture\n".format(key), encoding="utf-8")
            os.chmod(path, 0o444)

        resource_root = (run.parent / (run.name + "-r3-resources")).resolve()
        aligner = resource_root / "aligner"
        reference = resource_root / "reference"
        speech = resource_root / "speech"
        for directory, payload in ((aligner, b"aligner\n"), (reference, b"reference\n")):
            directory.mkdir(parents=True, exist_ok=True)
            (directory / "payload").write_bytes(payload)
        speech.parent.mkdir(parents=True, exist_ok=True)
        if speech.exists():
            os.chmod(speech, 0o644)
        speech.write_bytes(b"#!/bin/sh\nexit 0\n")
        os.chmod(speech, 0o555)
        sealed_paths = {
            "DICOW_R2_ALIGNER_VENV": run_with_env.sealed_path_record(aligner, "venv"),
            "DICOW_R2_REFERENCE_VENV": run_with_env.sealed_path_record(reference, "venv"),
            "DICOW_R2_SPEECH_BIN": run_with_env.sealed_path_record(speech, "file"),
        }
        path_proposal = run / "r3-runtime.staging/sealed-path-records.json"
        if path_proposal.exists():
            os.chmod(path_proposal, 0o644)
        _write_json(path_proposal, sealed_paths)
        os.chmod(path_proposal, 0o444)

        fragment = run / "env.d/R3-runtimes.env"
        fragment.parent.mkdir(parents=True, exist_ok=True)
        if fragment.exists():
            os.chmod(fragment, 0o644)
        fragment.write_text("fixture=runtime\n", encoding="utf-8")
        os.chmod(fragment, 0o444)
        fragment_record = manifest._file_tuple(fragment)
        fragment_record["path"] = "env.d/R3-runtimes.env"
        fragment_proposal = run / "r3-runtime.staging/sealed-fragment-record.json"
        if fragment_proposal.exists():
            os.chmod(fragment_proposal, 0o644)
        _write_json(fragment_proposal, {"R3-runtimes.env": fragment_record})
        os.chmod(fragment_proposal, 0o444)

        attempt = (run / "pre-model-audit/attempts/fixture").resolve()
        for directory in (attempt.parent, attempt, attempt / "audit"):
            if directory.exists():
                os.chmod(directory, 0o755)
        identities = attempt / "audit/model-identities.json"
        if not identities.exists():
            _write_json(identities, {"schema_version": "fixture", "models": []})
            os.chmod(identities, 0o444)
        selected_manifest = attempt / "manifest.json"
        if selected_manifest.exists():
            os.chmod(selected_manifest, 0o644)
        _write_json(selected_manifest, {
            "schema_version": "dicow-r2-pre-model-audit-manifest-v1",
            "run_id": "r2-run",
            "spec_record": {
                "bytes": (
                    run / pins.R2_R3_FIXED_SOURCE_PATHS[
                        manifest._R2_R3_ACTIVE_SPEC_SOURCE_KEY
                    ]
                ).stat().st_size,
                "sha256": _sha(
                    run / pins.R2_R3_FIXED_SOURCE_PATHS[
                        manifest._R2_R3_ACTIVE_SPEC_SOURCE_KEY
                    ]
                ),
            },
        })
        os.chmod(selected_manifest, 0o444)
        for directory in (attempt / "audit", attempt, attempt.parent):
            os.chmod(directory, 0o555)
        canonical = run / "pre-model-audit/canonical.json"
        if canonical.exists():
            os.chmod(canonical, 0o644)
        _write_json(canonical, {
            "schema_version": "dicow-r2-pre-model-audit-canonical-v1",
            "run_id": "r2-run", "attempt": str(attempt),
            "manifest_record": {
                "sha256": _sha(selected_manifest), "bytes": selected_manifest.stat().st_size,
            },
        })
        os.chmod(canonical, 0o444)

        run_manifest = run / "run-manifest.json"
        run_manifest_document = json.loads(run_manifest.read_text())
        effective_r1 = manifest._effective_r2_state_path("R1", run)
        sources = {
            "plan_contract": run_manifest_document["plan_contract"]["sha256"],
            "run_manifest": _sha(run_manifest),
            "R1_effective_state": _sha(effective_r1),
            "R2_state": _sha(paths["R2"]),
        }
        for key, relative in pins.R2_R3_FIXED_SOURCE_PATHS.items():
            sources[key] = _sha(run / relative)
        sources["pre_model_audit_manifest"] = _sha(selected_manifest)
        return {
            "source_input_hashes": sources,
            "artifacts": {"model-identities": {
                "path": str(identities.relative_to(run.resolve())),
                "sha256": _sha(identities), "bytes": identities.stat().st_size,
            }},
            "sealed_fragments": {"R3-runtimes.env": fragment_record},
            "sealed_paths": sealed_paths,
        }

    def _materialize_r4_task_state_fixture(
        self,
        run: Path,
        *,
        scope: str,
        evidence_outcome: str,
    ) -> tuple[Path, Path]:
        run = run.resolve()
        gate_path, gate_paths = self._r4_gate_fixture(
            run, scope=scope, evidence_outcome=evidence_outcome
        )
        paths = self._r2_bootstrap_fixture(run)

        plan_path = run / "plan.md"
        run_manifest_path = run / "run-manifest.json"
        run_manifest = json.loads(run_manifest_path.read_text())
        run_manifest["plan_contract"] = {
            "path": str(plan_path.resolve()),
            "bytes": plan_path.stat().st_size,
            "sha256": _sha(plan_path),
        }
        os.chmod(run_manifest_path, 0o644)
        _write_json(run_manifest_path, run_manifest)
        os.chmod(run_manifest_path, 0o444)

        r0_path = paths["R0"]
        r0 = json.loads(r0_path.read_text())
        r0["run_manifest_sha256"] = _sha(run_manifest_path)
        r0["source_input_hashes"]["plan_contract"] = _sha(plan_path)
        os.chmod(r0_path, 0o644)
        _write_json(r0_path, r0)
        os.chmod(r0_path, 0o444)

        prior_name = "R1"
        prior_path = paths["R1"]
        r1 = json.loads(prior_path.read_text())
        r1["source_input_hashes"] = {
            "R0_state": _sha(r0_path),
            "run_manifest": _sha(run_manifest_path),
        }
        os.chmod(prior_path, 0o644)
        _write_json(prior_path, r1)
        os.chmod(prior_path, 0o444)
        for index in range(1, 11):
            name = "R1-contract-amendment-{}".format(index)
            prior = json.loads(prior_path.read_text())
            amendment_path = run / "task-state/{}.json".format(name)
            _write_json(amendment_path, {
                "schema_version": "dicow-r2-task-state-v1",
                "task": name,
                "state": "done",
                "branch_disposition": "executed",
                "evidence_outcome": "supported",
                "run_id": "r2-run",
                "next_task_ids": ["R2"],
                "original_state_sha256": _sha(prior_path),
                "predecessor_state_hashes": {prior_name: _sha(prior_path)},
                "tracked_files": {
                    relative: {"input": entry["output"], "output": entry["output"]}
                    for relative, entry in prior["tracked_files"].items()
                },
            })
            os.chmod(amendment_path, 0o444)
            prior_name, prior_path = name, amendment_path
        paths["R1"] = prior_path

        r2_path = run / "task-state/R2.json"
        os.chmod(r2_path, 0o644)
        _write_json(r2_path, {
            "schema_version": "dicow-r2-task-state-v1",
            "task": "R2",
            "state": "done",
            "branch_disposition": "executed",
            "evidence_outcome": "supported",
            "run_id": "r2-run",
            "predecessor_state_hashes": {
                "R0": _sha(r0_path), "R1": _sha(prior_path),
            },
            "next_task_ids": ["R3"],
        })
        os.chmod(r2_path, 0o444)
        paths["R2"] = r2_path

        repo = Path(__file__).resolve().parents[4]
        r3_path = run / "task-state/R3.json"
        r3 = {
            "schema_version": "dicow-r2-task-state-v1",
            "task": "R3",
            "state": "done",
            "branch_disposition": "executed",
            "evidence_outcome": "evidence_blocker",
            "run_id": "r2-run",
            "predecessor_state_hashes": {
                "R1": _sha(prior_path), "R2": _sha(r2_path),
            },
            "next_task_ids": ["R4"],
            "tracked_files": {
                relative: {
                    "input": manifest._file_tuple(repo / relative),
                    "output": manifest._file_tuple(repo / relative),
                }
                for relative in pins.R2_TASK_TRACKED_FILES["R3"]
            },
        }
        r3.update(self._r3_publication_fields(run, paths))
        os.chmod(r3_path, 0o644)
        _write_json(r3_path, r3)
        os.chmod(r3_path, 0o444)
        paths["R3"] = r3_path

        attempt = run / "pre-model-audit/attempts/fixture"
        audit = attempt / "audit"
        for directory in (attempt.parent, attempt, audit):
            os.chmod(directory, 0o755)
        audit_decision = audit / "decision.json"
        _write_json(audit_decision, {
            "dicow_scope": "evidence_blocker",
            "qwen_asr_scope": "implementation_ready",
            "qwen_aligner_scope": "implementation_ready",
        })
        for directory in (audit, attempt, attempt.parent):
            os.chmod(directory, 0o555)

        graph_path = gate_paths["graph"]
        graph = json.loads(graph_path.read_text())
        roles = manifest._r2_j1_authority_roles()
        selected_manifest = attempt / "manifest.json"
        authority_paths = {
            "plan_contract": (plan_path, str(plan_path.resolve()), plan_path.stat().st_size),
            "run_manifest": (run_manifest_path, "run-manifest.json", None),
            "effective_r1_state": (
                prior_path, "task-state/R1-contract-amendment-10.json", None,
            ),
            "r2_state": (r2_path, "task-state/R2.json", None),
            "r3_state": (r3_path, "task-state/R3.json", None),
            "pre_model_audit_manifest": (
                selected_manifest, str(selected_manifest.relative_to(run)), None,
            ),
            "pre_model_decision": (
                audit_decision, str(audit_decision.relative_to(run)), None,
            ),
            "active_spec": (
                run / pins.R2_R3_FIXED_SOURCE_PATHS[
                    manifest._R2_R3_ACTIVE_SPEC_SOURCE_KEY
                ],
                pins.R2_R3_FIXED_SOURCE_PATHS[manifest._R2_R3_ACTIVE_SPEC_SOURCE_KEY],
                None,
            ),
            "gate_schema": (
                repo / "docs/contracts/dicow-gate.schema.json",
                str(repo / "docs/contracts/dicow-gate.schema.json"), None,
            ),
            "pins": (
                repo / "benchmarks/scripts/dicow/common/pins.py",
                str(repo / "benchmarks/scripts/dicow/common/pins.py"), None,
            ),
            "manifest_verifier": (
                Path(manifest.__file__).resolve(), str(Path(manifest.__file__).resolve()), None,
            ),
            "advisory_checkpoint": (
                run / pins.R2_J1_ADVISORY_PATH, pins.R2_J1_ADVISORY_PATH, None,
            ),
        }
        for key, relative in pins.R2_J1_REFRESH_PATHS.items():
            authority_paths[key] = (run / relative, relative, None)
        authorities = []
        for key, (path, display, prefix) in authority_paths.items():
            record = dict(manifest._r2_j1_record(path, display, prefix_bytes=prefix))
            record.update({
                "key": key, "role": roles[key][0], "claim_ceiling": roles[key][1],
            })
            authorities.append(record)
        graph["authorities"] = authorities
        graph["verification"]["authority_count"] = len(authorities)
        _write_json(graph_path, graph)

        gate = json.loads(gate_path.read_text())
        graph_record = {
            "path": graph_path.name, "sha256": _sha(graph_path),
            "bytes": graph_path.stat().st_size,
        }
        packet_path = gate_paths["packet"]
        packet_path.write_bytes(manifest._r2_j1_packet(graph_record))
        estimator_path = gate_paths["estimator"]
        estimator = json.loads(estimator_path.read_text())
        estimator["packet_utf8_bytes"] = packet_path.stat().st_size
        estimator["output_schema_utf8_bytes"] = len(json.dumps(
            manifest._r2_j1_output_schema(), sort_keys=True,
            separators=(",", ":"), ensure_ascii=False,
        ).encode("utf-8"))
        estimator["estimated_input_tokens"] = (
            estimator["packet_utf8_bytes"]
            + estimator["output_schema_utf8_bytes"]
            + estimator["overhead"]
        )
        _write_json(estimator_path, estimator)
        decision_path = gate_paths["decision"]
        decision = gate["decision"]
        decision_bytes = json.dumps(
            decision, sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
        decision_path.write_bytes(decision_bytes)
        raw_path = gate_paths["raw"]
        _write_json(raw_path, {
            "terminal_reason": "completed", "is_error": False,
            "session_id": gate["fable_result"]["session_id"],
            "modelUsage": {"claude-fable-5": {
                "inputTokens": estimator["estimated_input_tokens"],
            }},
            "result": decision_bytes.decode(),
        })
        artifact = lambda key, path: {
            "key": key, "path": path.name, "sha256": _sha(path),
            "bytes": path.stat().st_size,
        }
        gate["machine_evidence_graph"] = artifact("machine_graph", graph_path)
        gate["judgment_packet"] = artifact("judgment_packet", packet_path)
        gate["estimator_artifact"] = artifact("estimator", estimator_path)
        gate["fable_result"].update({
            "estimated_input_tokens": estimator["estimated_input_tokens"],
            "estimator_source_sha256": _sha(Path(manifest.__file__).resolve()),
            "prompt_sha256": _sha(packet_path),
            "raw_sha256": _sha(raw_path),
            "decision_sha256": _sha(decision_path),
            "input_hashes": {"machine_graph": _sha(graph_path)},
        })
        _write_json(gate_path, gate)
        os.chmod(gate_path, 0o444)

        r4_path = run / "task-state/R4.json"
        _write_json(r4_path, {
            "schema_version": "dicow-r2-task-state-v1",
            "task": "R4",
            "state": "done",
            "branch_disposition": "executed",
            "evidence_outcome": evidence_outcome,
            "run_id": "r2-run",
            "predecessor_state_hashes": {"R3": _sha(r3_path)},
            "next_task_ids": list(
                pins.R2_GATE_TASK_SEMANTICS[("J1-r2", scope)]["next"]
            ),
            "gate_path": pins.R2_J1_GATE_PATH,
            "gate_sha256": _sha(gate_path),
        })
        os.chmod(r4_path, 0o444)
        return r4_path, gate_path

    def test_r2_contract_is_exact_and_keeps_qwen_independent(self):
        value = self._contract()
        manifest.verify_r2_contract_document(value)
        self.assertEqual(value["dependencies"]["Q2"], ["Q1", "R4"])
        self.assertEqual(value["dependencies"]["R13"], ["Q2", "R12"])
        self.assertEqual(
            pins.R2_GATE_TASK_SEMANTICS[("J1-r2", "proceed_qwen_only")]["next"],
            ("Q1",),
        )
        self.assertTrue(value["qwen_lane"]["mandatory"])
        self.assertEqual(
            [item["component"] for item in value["qwen_lane"]["components"]],
            ["asr_adapter", "aligner"],
        )
        self.assertEqual(
            pins.R2_TASK_TRACKED_FILES["R10"], ("docs/dicow-conversion-lane.md",)
        )
        self.assertEqual(pins.R2_TASK_TRACKED_FILES["R3"], (
            "benchmarks/scripts/dicow/common/preflight.py",
            "benchmarks/scripts/dicow/reference/inspect.py",
            "benchmarks/scripts/dicow/tests/test_inspect.py",
            "benchmarks/scripts/dicow/tests/test_preflight.py",
        ))
        self.assertEqual(
            pins.R2_TASK_TRACKED_FILES["R13"],
            ("docs/dicow-conversion-lane.md", "docs/research-digest.md"),
        )
        self.assertNotIn("run-manifest.json", pins.R2_TASK_TRACKED_FILES["R13"])

    def test_r2_j1_output_schema_preserves_all_value_judgment_branches(self):
        expected = {
            "proceed_dicow_and_qwen": {
                "outcomes": ("supported",),
                "next": ("R5", "Q1", "R6"),
                "skip": (),
            },
            "proceed_qwen_only": {
                "outcomes": ("evidence_blocker",),
                "next": ("Q1",),
                "skip": ("R5", "R6", "R7", "R8", "R9", "R10", "R11", "R12"),
            },
            "revise_or_stop_all": {
                "outcomes": ("not_supported", "evidence_blocker", "unresolved"),
                "next": ("R13",),
                "skip": ("R5", "Q1", "R6", "R7", "R8", "R9", "R10", "Q2", "R11", "R12"),
            },
        }

        runtime_schema = manifest._r2_j1_output_schema()
        runtime_branches = {
            branch["properties"]["scope"]["const"]: branch
            for branch in runtime_schema["oneOf"]
        }
        public_schema = json.loads(
            (Path(__file__).resolve().parents[4] / "docs/contracts/dicow-gate.schema.json")
            .read_text(encoding="utf-8")
        )["$defs"]["r2_j1_decision"]
        public_branches = {
            branch["properties"]["scope"]["const"]: branch
            for branch in public_schema["oneOf"]
        }

        self.assertEqual(set(expected), set(runtime_branches))
        self.assertEqual(set(expected), set(public_branches))
        self.assertEqual(runtime_schema, public_schema)
        for scope, contract in expected.items():
            for branch in (runtime_branches[scope], public_branches[scope]):
                properties = branch["properties"]
                outcome_schema = properties["evidence_outcome"]
                outcomes = tuple(
                    outcome_schema.get("enum", [outcome_schema.get("const")])
                )
                self.assertEqual(contract["outcomes"], outcomes)
                self.assertEqual(contract["next"], tuple(properties["next_task_ids"]["const"]))
                self.assertEqual(contract["skip"], tuple(properties["skip_task_ids"]["const"]))

    @mock.patch(
        "benchmarks.scripts.dicow.reference.inspect.verify_r2_audit",
        return_value={
            "status": "verified", "run_id": "r2-run",
            "summary": {"decision": {
                "dicow_scope": "evidence_blocker",
                "qwen_asr_scope": "implementation_ready",
                "qwen_aligner_scope": "implementation_ready",
            }},
        },
    )
    def test_r4_task_state_and_launcher_accept_both_authenticated_transitions(
        self, _audit_replay
    ):
        repo = Path(__file__).resolve().parents[4]
        for scope, outcome, next_tasks in (
            ("proceed_qwen_only", "evidence_blocker", ["Q1"]),
            ("revise_or_stop_all", "not_supported", ["R13"]),
        ):
            with self.subTest(scope=scope), tempfile.TemporaryDirectory() as directory:
                run = Path(directory)
                state_path, _ = self._materialize_r4_task_state_fixture(
                    run, scope=scope, evidence_outcome=outcome
                )
                state, verified_path = manifest.verify_r2_task_state("R4", run)
                self.assertEqual(state["evidence_outcome"], outcome)
                self.assertEqual(state["next_task_ids"], next_tasks)
                self.assertEqual(verified_path, state_path.resolve())
                run_with_env._verify_r2_task_dependencies(
                    run.resolve(), "r2-run", "R4", state, repo
                )

        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            state_path, gate_path = self._materialize_r4_task_state_fixture(
                run, scope="revise_or_stop_all", evidence_outcome="not_supported"
            )
            state, verified_path = manifest.verify_r2_task_state("R4", run)
            self.assertEqual(state["evidence_outcome"], "not_supported")
            self.assertEqual(state["next_task_ids"], ["R13"])
            self.assertEqual(verified_path, state_path.resolve())
            self.assertEqual(json.loads(gate_path.read_text())["scope"], "revise_or_stop_all")

            original = json.loads(state_path.read_text())
            for field, value in (
                ("evidence_outcome", "evidence_blocker"),
                ("next_task_ids", ["Q1"]),
            ):
                malformed = deepcopy(original)
                malformed[field] = value
                os.chmod(state_path, 0o644)
                _write_json(state_path, malformed)
                os.chmod(state_path, 0o444)
                with self.subTest(field=field), self.assertRaisesRegex(
                    manifest.VerificationError, "differs from its authenticated"
                ):
                    manifest.verify_r2_task_state("R4", run)
            os.chmod(state_path, 0o644)
            _write_json(state_path, original)
            os.chmod(state_path, 0o444)

            alternate_dir = run / "fable-j1-reroll"
            alternate_dir.mkdir()
            for source in gate_path.parent.iterdir():
                target = alternate_dir / source.name
                target.write_bytes(source.read_bytes())
                os.chmod(target, source.stat().st_mode & 0o777)
                self.assertEqual(
                    target.stat().st_mode & 0o777, source.stat().st_mode & 0o777
                )
            os.chmod(alternate_dir, gate_path.parent.stat().st_mode & 0o777)
            alternate_gate = alternate_dir / "gate.json"
            manifest.verify_gate(alternate_gate)
            alternate_state = deepcopy(original)
            alternate_state.update({
                "gate_path": str(alternate_gate.relative_to(run)),
                "gate_sha256": _sha(alternate_gate),
            })
            os.chmod(state_path, 0o644)
            _write_json(state_path, alternate_state)
            os.chmod(state_path, 0o444)
            with self.assertRaisesRegex(
                manifest.VerificationError, "canonical J1-r2 gate path"
            ):
                manifest.verify_r2_task_state("R4", run)

        with tempfile.TemporaryDirectory() as directory:
            gate_path, _ = self._r4_gate_fixture(
                Path(directory), scope="proceed_dicow_and_qwen",
                evidence_outcome="supported",
            )
            with self.assertRaisesRegex(
                manifest.VerificationError, "cannot proceed with DiCoW"
            ):
                manifest.verify_gate(gate_path)

    @mock.patch(
        "benchmarks.scripts.dicow.reference.inspect.verify_r2_audit",
        return_value={
            "status": "verified", "run_id": "r2-run",
            "summary": {"decision": {
                "dicow_scope": "evidence_blocker",
                "qwen_asr_scope": "implementation_ready",
                "qwen_aligner_scope": "implementation_ready",
            }},
        },
    )
    def test_skipped_descendant_inherits_the_exact_effective_r4_gate(
        self, _audit_replay
    ):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory).resolve()
            r4_path, gate_path = self._materialize_r4_task_state_fixture(
                run, scope="proceed_qwen_only", evidence_outcome="evidence_blocker"
            )
            gate_sha = _sha(gate_path)
            r5_path = run / "task-state/R5.json"
            valid = {
                "schema_version": "dicow-r2-task-state-v1",
                "task": "R5",
                "state": "done",
                "branch_disposition": "skipped",
                "evidence_outcome": "evidence_blocker",
                "run_id": "r2-run",
                "predecessor_state_hashes": {"R4": _sha(r4_path)},
                "gate_path": pins.R2_J1_GATE_PATH,
                "gate_sha256": gate_sha,
            }
            _write_json(r5_path, valid)
            os.chmod(r5_path, 0o444)
            state, verified_path = manifest.verify_r2_task_state("R5", run)
            self.assertEqual(state["branch_disposition"], "skipped")
            self.assertEqual(verified_path, r5_path.resolve())

            executed_r5 = deepcopy(valid)
            executed_r5.update({
                "branch_disposition": "executed", "evidence_outcome": "supported",
            })
            os.chmod(r5_path, 0o644)
            _write_json(r5_path, executed_r5)
            os.chmod(r5_path, 0o444)
            with self.assertRaisesRegex(
                manifest.VerificationError, "J1-r2 skip decision"
            ):
                manifest.verify_r2_task_state("R5", run)

            q1_path = run / "task-state/Q1.json"
            _write_json(q1_path, {
                "schema_version": "dicow-r2-task-state-v1", "task": "Q1",
                "state": "done", "branch_disposition": "executed",
                "evidence_outcome": "supported", "run_id": "r2-run",
                "predecessor_state_hashes": {"R4": _sha(r4_path)},
            })
            os.chmod(q1_path, 0o444)
            q1_state, _ = manifest.verify_r2_task_state("Q1", run)
            self.assertEqual(q1_state["branch_disposition"], "executed")

            os.chmod(r5_path, 0o644)
            _write_json(r5_path, valid)
            os.chmod(r5_path, 0o444)

            wrong_hash = deepcopy(valid)
            wrong_hash["gate_sha256"] = "0" * 64
            os.chmod(r5_path, 0o644)
            _write_json(r5_path, wrong_hash)
            os.chmod(r5_path, 0o444)
            with self.assertRaisesRegex(
                manifest.VerificationError, "differs from the effective R4 gate"
            ):
                manifest.verify_r2_task_state("R5", run)

            alternate_dir = run / "fable-j1-descendant-reroll"
            alternate_dir.mkdir()
            for source in gate_path.parent.iterdir():
                target = alternate_dir / source.name
                target.write_bytes(source.read_bytes())
                os.chmod(target, source.stat().st_mode & 0o777)
            os.chmod(alternate_dir, gate_path.parent.stat().st_mode & 0o777)
            alternate_gate = alternate_dir / "gate.json"
            manifest.verify_gate(alternate_gate)
            rerolled = deepcopy(valid)
            rerolled.update({
                "gate_path": str(alternate_gate.relative_to(run)),
                "gate_sha256": _sha(alternate_gate),
            })
            os.chmod(r5_path, 0o644)
            _write_json(r5_path, rerolled)
            os.chmod(r5_path, 0o444)
            with self.assertRaisesRegex(
                manifest.VerificationError, "canonical J1-r2 gate path"
            ):
                manifest.verify_r2_task_state("R5", run)

        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory).resolve()
            r4_path, _ = self._materialize_r4_task_state_fixture(
                run, scope="revise_or_stop_all", evidence_outcome="not_supported"
            )
            q1_path = run / "task-state/Q1.json"
            _write_json(q1_path, {
                "schema_version": "dicow-r2-task-state-v1", "task": "Q1",
                "state": "done", "branch_disposition": "executed",
                "evidence_outcome": "supported", "run_id": "r2-run",
                "predecessor_state_hashes": {"R4": _sha(r4_path)},
            })
            os.chmod(q1_path, 0o444)
            with self.assertRaisesRegex(
                manifest.VerificationError, "J1-r2 skip decision"
            ):
                manifest.verify_r2_task_state("Q1", run)

    def test_skip_authority_preserves_canonical_j2_and_rejects_rerolls(self):
        for scope, task in (("select_none", "R11"), ("retarget", "R12")):
            with self.subTest(scope=scope, task=task), tempfile.TemporaryDirectory() as directory:
                run = Path(directory).resolve()
                gate_path = run / pins.R2_J2_GATE_PATH
                gate = {
                    "gate_id": "J2-r2", "task": "R10", "scope": scope,
                    "evidence_outcome": "not_supported",
                    "decision": {
                        "checkpoint": "J2-r2", "scope": scope,
                        "evidence_outcome": "not_supported",
                        "next_task_ids": ["R13"],
                        "skip_task_ids": ["R11", "R12"],
                        "reversal_condition": "fixture reversal condition",
                    },
                }
                _write_json(gate_path, gate)
                self._seal(gate_path)
                r10_path = run / "task-state/R10.json"
                _write_json(r10_path, {
                    "schema_version": "dicow-r2-task-state-v1", "task": "R10",
                    "state": "done", "branch_disposition": "executed",
                    "evidence_outcome": "not_supported", "run_id": "r2-run",
                    "next_task_ids": ["R13"], "gate_path": pins.R2_J2_GATE_PATH,
                    "gate_sha256": _sha(gate_path),
                })
                self._seal(r10_path)
                skipped = {
                    "schema_version": "dicow-r2-task-state-v1", "task": task,
                    "state": "done", "branch_disposition": "skipped",
                    "evidence_outcome": "not_supported", "run_id": "r2-run",
                    "gate_path": pins.R2_J2_GATE_PATH,
                    "gate_sha256": _sha(gate_path),
                }
                with mock.patch.object(manifest, "verify_gate") as gate_replay:
                    manifest._verify_r2_skip_gate_authority(task, skipped, run)
                    gate_replay.assert_called_once_with(gate_path)

        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory).resolve()
            canonical = run / pins.R2_J2_GATE_PATH
            gate = {
                "gate_id": "J2-r2", "task": "R10", "scope": "select_none",
                "evidence_outcome": "not_supported",
                "decision": {
                    "checkpoint": "J2-r2", "scope": "select_none",
                    "evidence_outcome": "not_supported", "next_task_ids": ["R13"],
                    "skip_task_ids": ["R11", "R12"],
                    "reversal_condition": "fixture reversal condition",
                },
            }
            _write_json(canonical, gate)
            self._seal(canonical)
            alternate_relative = "fable-j2-reroll/gate.json"
            alternate = run / alternate_relative
            _write_json(alternate, gate)
            self._seal(alternate)
            r10_path = run / "task-state/R10.json"
            _write_json(r10_path, {
                "schema_version": "dicow-r2-task-state-v1", "task": "R10",
                "state": "done", "branch_disposition": "executed",
                "evidence_outcome": "not_supported", "run_id": "r2-run",
                "next_task_ids": ["R13"], "gate_path": pins.R2_J2_GATE_PATH,
                "gate_sha256": _sha(canonical),
            })
            self._seal(r10_path)
            j1_path = run / pins.R2_J1_GATE_PATH
            j1_gate = {
                "gate_id": "J1-r2", "task": "R4",
                "scope": "proceed_dicow_and_qwen", "evidence_outcome": "supported",
                "decision": {
                    "checkpoint": "J1-r2", "scope": "proceed_dicow_and_qwen",
                    "evidence_outcome": "supported",
                    "next_task_ids": ["R5", "Q1", "R6"], "skip_task_ids": [],
                    "reversal_condition": "fixture reversal condition",
                },
            }
            _write_json(j1_path, j1_gate)
            self._seal(j1_path)
            r4_path = run / "task-state/R4.json"
            _write_json(r4_path, {
                "schema_version": "dicow-r2-task-state-v1", "task": "R4",
                "state": "done", "branch_disposition": "executed",
                "evidence_outcome": "supported", "run_id": "r2-run",
                "next_task_ids": ["R5", "Q1", "R6"],
                "gate_path": pins.R2_J1_GATE_PATH, "gate_sha256": _sha(j1_path),
            })
            self._seal(r4_path)
            with mock.patch.object(manifest, "verify_gate"):
                manifest._verify_r2_executed_gate_authority(
                    "R10", {"run_id": "r2-run"}, run
                )
                with self.assertRaisesRegex(
                    manifest.VerificationError, "J2-r2 skip decision"
                ):
                    manifest._verify_r2_executed_gate_authority(
                        "R11", {"run_id": "r2-run"}, run
                    )

            malformed_r10 = json.loads(r10_path.read_text(encoding="utf-8"))
            malformed_r10["next_task_ids"] = ["R11"]
            os.chmod(r10_path, 0o644)
            _write_json(r10_path, malformed_r10)
            self._seal(r10_path)
            with mock.patch.object(manifest, "verify_gate"), self.assertRaisesRegex(
                manifest.VerificationError,
                "differs from its authenticated gate transition",
            ):
                manifest._verify_r2_executed_gate_authority(
                    "R10", {"run_id": "r2-run"}, run
                )

            selected = deepcopy(gate)
            selected.update({
                "scope": "select_dicow_mlc", "evidence_outcome": "supported",
            })
            selected["decision"].update({
                "scope": "select_dicow_mlc", "evidence_outcome": "supported",
                "next_task_ids": ["R11"], "skip_task_ids": [],
            })
            os.chmod(canonical, 0o644)
            _write_json(canonical, selected)
            self._seal(canonical)
            os.chmod(r10_path, 0o644)
            _write_json(r10_path, {
                "schema_version": "dicow-r2-task-state-v1", "task": "R10",
                "state": "done", "branch_disposition": "executed",
                "evidence_outcome": "supported", "run_id": "r2-run",
                "next_task_ids": ["R11"], "gate_path": pins.R2_J2_GATE_PATH,
                "gate_sha256": _sha(canonical),
            })
            self._seal(r10_path)
            with mock.patch.object(manifest, "verify_gate"):
                manifest._verify_r2_executed_gate_authority(
                    "R11", {"run_id": "r2-run"}, run
                )

            os.chmod(r10_path, 0o644)
            _write_json(r10_path, {
                "schema_version": "dicow-r2-task-state-v1", "task": "R10",
                "state": "done", "branch_disposition": "executed",
                "evidence_outcome": "not_supported", "run_id": "r2-run",
                "next_task_ids": ["R13"], "gate_path": alternate_relative,
                "gate_sha256": _sha(alternate),
            })
            self._seal(r10_path)
            skipped = {
                "schema_version": "dicow-r2-task-state-v1", "task": "R11",
                "state": "done", "branch_disposition": "skipped",
                "evidence_outcome": "not_supported", "run_id": "r2-run",
                "gate_path": alternate_relative, "gate_sha256": _sha(alternate),
            }
            with mock.patch.object(manifest, "verify_gate") as gate_replay, \
                    self.assertRaisesRegex(manifest.VerificationError, "canonical"):
                manifest._verify_r2_skip_gate_authority("R11", skipped, run)
            gate_replay.assert_not_called()

            j1_gate = deepcopy(gate)
            j1_gate.update({
                "gate_id": "J1-r2", "task": "R4", "scope": "proceed_qwen_only",
                "evidence_outcome": "evidence_blocker",
            })
            j1_gate["decision"].update({
                "checkpoint": "J1-r2", "scope": "proceed_qwen_only",
                "evidence_outcome": "evidence_blocker", "next_task_ids": ["Q1"],
                "skip_task_ids": [
                    "R5", "R6", "R7", "R8", "R9", "R10", "R11", "R12",
                ],
            })
            os.chmod(canonical, 0o644)
            _write_json(canonical, j1_gate)
            self._seal(canonical)
            os.chmod(r10_path, 0o644)
            _write_json(r10_path, {
                "schema_version": "dicow-r2-task-state-v1", "task": "R10",
                "state": "done", "branch_disposition": "executed",
                "evidence_outcome": "evidence_blocker", "run_id": "r2-run",
                "next_task_ids": ["Q1"], "gate_path": pins.R2_J2_GATE_PATH,
                "gate_sha256": _sha(canonical),
            })
            self._seal(r10_path)
            skipped.update({
                "evidence_outcome": "evidence_blocker",
                "gate_path": pins.R2_J2_GATE_PATH,
                "gate_sha256": _sha(canonical),
            })
            with mock.patch.object(manifest, "verify_gate") as gate_replay, \
                    self.assertRaisesRegex(
                        manifest.VerificationError,
                        "not an authenticated J2-r2 transition",
                    ):
                manifest._verify_r2_skip_gate_authority("R11", skipped, run)
            gate_replay.assert_called_once_with(canonical)

    def test_r13_requires_canonical_authenticated_final_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory).resolve()
            j1_path = run / pins.R2_J1_GATE_PATH
            _write_json(j1_path, {
                "gate_id": "J1-r2", "task": "R4", "scope": "proceed_qwen_only",
                "evidence_outcome": "evidence_blocker",
                "decision": {
                    "checkpoint": "J1-r2", "scope": "proceed_qwen_only",
                    "evidence_outcome": "evidence_blocker", "next_task_ids": ["Q1"],
                    "skip_task_ids": [
                        "R5", "R6", "R7", "R8", "R9", "R10", "R11", "R12",
                    ],
                    "reversal_condition": "fixture J1 condition",
                },
            })
            self._seal(j1_path)
            r4_path = run / "task-state/R4.json"
            _write_json(r4_path, {
                "schema_version": "dicow-r2-task-state-v1", "task": "R4",
                "state": "done", "branch_disposition": "executed",
                "evidence_outcome": "evidence_blocker", "run_id": "r2-run",
                "next_task_ids": ["Q1"], "gate_path": pins.R2_J1_GATE_PATH,
                "gate_sha256": _sha(j1_path),
            })
            self._seal(r4_path)
            final_path = run / pins.R2_FINAL_GATE_PATH
            _write_json(final_path, {
                "gate_id": "FINAL-r2", "task": "R13", "scope": "final_review",
                "evidence_outcome": "supported",
                "decision": {
                    "checkpoint": "FINAL-r2", "scope": "final_review",
                    "evidence_outcome": "supported", "next_task_ids": [],
                    "skip_task_ids": [], "reversal_condition": "fixture final condition",
                },
            })
            self._seal(final_path)
            r13_path = run / "task-state/R13.json"
            state = {
                "schema_version": "dicow-r2-task-state-v1", "task": "R13",
                "state": "done", "branch_disposition": "executed",
                "evidence_outcome": "supported", "run_id": "r2-run",
                "next_task_ids": [], "gate_path": pins.R2_FINAL_GATE_PATH,
                "gate_sha256": _sha(final_path),
            }
            _write_json(r13_path, state)
            self._seal(r13_path)
            with mock.patch.object(manifest, "verify_gate") as gate_replay:
                manifest._verify_r2_executed_gate_authority("R13", state, run)
            self.assertEqual(
                gate_replay.call_args_list, [mock.call(j1_path), mock.call(final_path)]
            )

            mismatched = deepcopy(state)
            mismatched["evidence_outcome"] = "unresolved"
            os.chmod(r13_path, 0o644)
            _write_json(r13_path, mismatched)
            self._seal(r13_path)
            with mock.patch.object(manifest, "verify_gate"), self.assertRaisesRegex(
                manifest.VerificationError,
                "R13 differs from its authenticated gate transition",
            ):
                manifest._verify_r2_executed_gate_authority("R13", mismatched, run)

            alternate = run / "fable-final-reroll/gate.json"
            _write_json(alternate, json.loads(final_path.read_text(encoding="utf-8")))
            self._seal(alternate)
            rerolled = deepcopy(state)
            rerolled.update({
                "gate_path": "fable-final-reroll/gate.json",
                "gate_sha256": _sha(alternate),
            })
            os.chmod(r13_path, 0o644)
            _write_json(r13_path, rerolled)
            self._seal(r13_path)
            with mock.patch.object(manifest, "verify_gate"), self.assertRaisesRegex(
                manifest.VerificationError, "canonical"
            ):
                manifest._verify_r2_executed_gate_authority("R13", rerolled, run)

    def test_r2_contract_rejects_result_derived_selection_and_false_ties(self):
        mutations = []
        pairwise = self._contract()
        pairwise["candidate_matrix"]["selection"]["pairwise_superiority_margin"] = 0.05
        mutations.append(pairwise)
        equivalence = self._contract()
        equivalence["candidate_matrix"]["selection"]["population_equivalence_claim"] = True
        mutations.append(equivalence)
        denominator = self._contract()
        denominator["candidate_matrix"]["complete_denominator_required"] = False
        mutations.append(denominator)
        repetitions = self._contract()
        repetitions["candidate_matrix"]["repetitions"] = [1]
        mutations.append(repetitions)
        qwen = self._contract()
        qwen["qwen_lane"]["components"].pop()
        mutations.append(qwen)
        ctc = self._contract()
        ctc["ctc"]["process_roles"].remove("bypass")
        mutations.append(ctc)
        premature = self._contract()
        premature["ctc"]["numeric_state_at_R3"] = "measured_without_inference"
        mutations.append(premature)
        for value in mutations:
            with self.subTest(value=value):
                with self.assertRaisesRegex(manifest.VerificationError, "frozen pre-output"):
                    manifest.verify_r2_contract_document(value)

    def test_r2_resource_uses_max_phase_not_doubled_global_sum(self):
        empty = {
            "final_bytes": 0,
            "staging_bytes": 0,
            "retained_failure_bytes": 0,
            "retry_bytes": 0,
            "serializer_bytes": 0,
            "simultaneously_retained_prior_outputs": 0,
        }
        first = dict(empty, final_bytes=10, staging_bytes=20)
        second = dict(empty, final_bytes=100, retry_bytes=7)
        self.assertEqual(manifest.r2_required_free_bytes([first, second]), 107 + 2**31)
        self.assertNotEqual(
            manifest.r2_required_free_bytes([first, second]),
            2 * (30 + 107) + 2**31,
        )

    def test_r2_fable_requires_completed_max_no_fallback_and_rejects_prompt_too_long(self):
        packet = b"bounded judgment packet"
        raw = json.dumps({
            "terminal_reason": "completed",
            "is_error": False,
            "modelUsage": {"claude-fable-5": {"inputTokens": 1}},
            "result": "ACCEPT",
        }, sort_keys=True).encode()
        provenance = {
            "requested_model": "fable",
            "actual_model": "claude-fable-5",
            "effort": "max",
            "fallback": False,
            "prompt_sha256": hashlib.sha256(packet).hexdigest(),
            "raw_result_sha256": hashlib.sha256(raw).hexdigest(),
            "input_hashes": {"machine_graph": "a" * 64},
            "estimated_input_tokens": pins.R2_FABLE_MAX_ESTIMATED_INPUT_TOKENS,
            "cli_version": "2.1.251",
            "estimator_version": "claude-code-preflight-v1",
            "estimator_source_sha256": "b" * 64,
        }
        manifest.verify_r2_fable_judgment(
            packet, pins.R2_FABLE_MAX_ESTIMATED_INPUT_TOKENS, raw, provenance
        )
        with self.assertRaisesRegex(manifest.VerificationError, "usable-context"):
            manifest.verify_r2_fable_judgment(
                packet, pins.R2_FABLE_MAX_ESTIMATED_INPUT_TOKENS + 1, raw, provenance
            )
        bad = json.dumps({
            "terminal_reason": "prompt_too_long",
            "is_error": True,
            "modelUsage": {},
            "result": "estimated request exceeds context",
        }, sort_keys=True).encode()
        provenance["raw_result_sha256"] = hashlib.sha256(bad).hexdigest()
        with self.assertRaisesRegex(manifest.VerificationError, "not a model judgment"):
            manifest.verify_r2_fable_judgment(
                packet, pins.R2_FABLE_MAX_ESTIMATED_INPUT_TOKENS, bad, provenance
            )

    def test_r2_candidate_wrapper_does_not_widen_r1_candidate_identity(self):
        value = {
            "schema_version": "dicow-r2-experiment-envelope-v1",
            "experiment_id": "r2-fixture",
            "run_id": "r2-run",
            "task": "R8",
            "candidate_id": "dicow_mlc",
            "candidate_source": {
                "model_id": pins.R2_MODEL_PINS["dicow_mlc"]["model_id"],
                "revision": pins.R2_MODEL_PINS["dicow_mlc"]["revision"],
                "weights_sha256": "b" * 64,
                "weights_bytes": 1,
                "source_task": "R3",
                "source_artifact_format": "dicow-r2-model-identities-v1",
                "source_artifact_id": "model-identities",
                "source_artifact_path": "pre-model-audit/candidates.json",
                "source_artifact_sha256": "c" * 64,
                "source_artifact_bytes": 1,
            },
            "execution_basis": {"R3": "d" * 64, "R5": "e" * 64, "R6": "f" * 64},
            "r2_contract": self._contract(),
            "evidence": {
                "format": "dicow-experiment-v1", "candidate_model": "dicow",
                "evidence_id": "E4", "path": "phase-a-mlc/evidence.json",
                "sha256": "1" * 64, "bytes": 1,
            },
        }
        manifest.verify_experiment_document(value)
        value["candidate_id"] = "dicow_v3_3"
        with self.assertRaisesRegex(manifest.VerificationError, "task/candidate"):
            manifest.verify_experiment_document(value)

    @mock.patch(
        "benchmarks.scripts.dicow.reference.inspect.verify_r2_audit",
        return_value={
            "status": "verified", "run_id": "r2-run",
            "summary": {"decision": {
                "dicow_scope": "evidence_blocker",
                "qwen_asr_scope": "implementation_ready",
                "qwen_aligner_scope": "implementation_ready",
            }},
        },
    )
    def test_r2_fable_checkpoint_scope_and_parsed_decision_are_exact(self, audit_replay):
        with tempfile.TemporaryDirectory() as directory:
            gate_path, paths = self._r4_gate_fixture(Path(directory))
            manifest.verify_gate(gate_path)
            audit_replay.assert_called_once()
            gate = json.loads(gate_path.read_text())
            for field, value in (
                ("scope", "proceed_dicow_and_qwen"),
                ("evidence_outcome", "supported"),
            ):
                malformed = deepcopy(gate)
                malformed[field] = value
                with self.subTest(field=field), self.assertRaises(manifest.VerificationError):
                    manifest.verify_r2_gate_envelope_document(malformed)
            for field, value in (
                ("next_task_ids", ["Q1", "R5"]),
                ("skip_task_ids", ["R6", "R7", "R8", "R9", "R10", "R11", "R12"]),
            ):
                malformed = deepcopy(gate)
                malformed["decision"][field] = value
                with self.subTest(decision_field=field), self.assertRaises(
                    manifest.VerificationError
                ):
                    manifest.verify_r2_gate_envelope_document(malformed)
            for field, value in (
                ("resumed", True),
                ("session_id", "arbitrary-session"),
                ("actual_model", "claude-sonnet-4-6"),
            ):
                malformed = deepcopy(gate)
                malformed["fable_result"][field] = value
                with self.subTest(fable_field=field), self.assertRaises(manifest.VerificationError):
                    manifest.verify_r2_gate_envelope_document(malformed)
            for argv_mutation in (
                lambda argv: argv[:-1],
                lambda argv: argv + ["--continue"],
                lambda argv: [item for item in argv if item != "--restricted"],
            ):
                malformed = deepcopy(gate)
                malformed["fable_result"]["argv"] = argv_mutation(
                    malformed["fable_result"]["argv"]
                )
                with self.assertRaises(manifest.VerificationError):
                    manifest.verify_r2_gate_envelope_document(malformed)
            paths["graph"].write_text('{"fabricated":true}\n', encoding="utf-8")
            gate["machine_evidence_graph"].update({
                "sha256": _sha(paths["graph"]), "bytes": paths["graph"].stat().st_size,
            })
            gate["fable_result"]["input_hashes"] = {"machine_graph": _sha(paths["graph"])}
            _write_json(gate_path, gate)
            with self.assertRaisesRegex(manifest.VerificationError, "machine graph"):
                manifest.verify_gate(gate_path)

    @mock.patch(
        "benchmarks.scripts.dicow.reference.inspect.verify_r2_audit",
        return_value={
            "status": "verified", "run_id": "r2-run",
            "summary": {"decision": {
                "dicow_scope": "evidence_blocker",
                "qwen_asr_scope": "implementation_ready",
                "qwen_aligner_scope": "implementation_ready",
            }},
        },
    )
    def test_r2_j1_rejects_opaque_graph_estimator_refresh_and_session_attacks(
        self, _audit_replay
    ):
        def mutate_and_reseal(gate_path, paths, target, mutation):
            value = json.loads(paths[target].read_text())
            mutation(value)
            _write_json(paths[target], value)
            gate = json.loads(gate_path.read_text())
            if target == "graph":
                gate["machine_evidence_graph"].update({
                    "sha256": _sha(paths[target]), "bytes": paths[target].stat().st_size,
                })
                gate["fable_result"]["input_hashes"] = {
                    "machine_graph": _sha(paths[target])
                }
            elif target == "estimator":
                gate["estimator_artifact"].update({
                    "sha256": _sha(paths[target]), "bytes": paths[target].stat().st_size,
                })
                gate["fable_result"]["estimator_source_sha256"] = _sha(paths[target])
            elif target == "raw":
                gate["fable_result"]["raw_sha256"] = _sha(paths[target])
            _write_json(gate_path, gate)

        attacks = (
            ("estimator", lambda value: value.clear(), "estimator"),
            ("estimator", lambda value: value.update(overhead=1), "estimator"),
            ("estimator", lambda value: value.update(packet_max_utf8_bytes=24_575), "estimator"),
            ("graph", lambda value: value.update(authorities=[
                item for item in value["authorities"]
                if item["key"] != "r4_capture_manifest"
            ]), "authority roster"),
            ("graph", lambda value: value["authorities"][4].update(sha256="0" * 64), "authority"),
            ("graph", lambda value: value["authorities"][7].update(sha256="1" * 64), "authority"),
            ("graph", lambda value: value["authorities"][8].update(sha256="2" * 64), "authority"),
            ("graph", lambda value: value.update(claim_ceilings=[]), "claim ceiling"),
            ("graph", lambda value: value["derived_facts"].update(server_scope="included"), "derived facts"),
            ("graph", lambda value: value["derived_facts"].update(baseline_scope="included"), "derived facts"),
            ("graph", lambda value: value["derived_facts"].update(dicow_probe_scope="next_task"), "derived facts"),
            ("graph", lambda value: value.update(latest_permitted_session_start_utc="2026-08-30T18:23:55Z"), "latest session"),
            ("raw", lambda value: value.update(session_id="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"), "session ID"),
            ("raw", lambda value: value.update(modelUsage={"claude-sonnet-4-6": {}}), "sole frozen actual model"),
        )
        for target, mutation, message in attacks:
            with self.subTest(target=target, message=message), tempfile.TemporaryDirectory() as directory:
                gate_path, paths = self._r4_gate_fixture(Path(directory))
                mutate_and_reseal(gate_path, paths, target, mutation)
                with self.assertRaisesRegex(manifest.VerificationError, message):
                    manifest.verify_gate(gate_path)

        with tempfile.TemporaryDirectory() as directory:
            gate_path, paths = self._r4_gate_fixture(Path(directory))
            paths["packet"].write_text("arbitrary prompt\n", encoding="utf-8")
            gate = json.loads(gate_path.read_text())
            gate["judgment_packet"].update({
                "sha256": _sha(paths["packet"]), "bytes": paths["packet"].stat().st_size,
            })
            gate["fable_result"]["prompt_sha256"] = _sha(paths["packet"])
            _write_json(gate_path, gate)
            with self.assertRaisesRegex(manifest.VerificationError, "graph-bound"):
                manifest.verify_gate(gate_path)

        with tempfile.TemporaryDirectory() as directory:
            gate_path, paths = self._r4_gate_fixture(Path(directory))
            graph = json.loads(paths["graph"].read_text())
            stale = "2026-08-31T00:23:55Z"
            graph["verification"]["session_started_at_utc"] = stale
            _write_json(paths["graph"], graph)
            gate = json.loads(gate_path.read_text())
            gate["machine_evidence_graph"].update({
                "sha256": _sha(paths["graph"]), "bytes": paths["graph"].stat().st_size,
            })
            gate["fable_result"]["input_hashes"] = {"machine_graph": _sha(paths["graph"])}
            gate["fable_result"]["session_started_at_utc"] = stale
            _write_json(gate_path, gate)
            with self.assertRaisesRegex(manifest.VerificationError, "refresh window"):
                manifest.verify_gate(gate_path)

        with tempfile.TemporaryDirectory() as directory:
            gate_path, paths = self._r4_gate_fixture(Path(directory))
            extra = gate_path.parent / "resume.json"
            _write_json(extra, {"resume": True})
            with self.assertRaisesRegex(manifest.VerificationError, "exactly its six"):
                manifest.verify_gate(gate_path)

    def test_r2_task_state_requires_exact_predecessor_hash_set_and_effective_amendment(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            paths = self._r2_bootstrap_fixture(run)
            r0, r1 = paths["R0"], paths["R1"]
            r2 = run / "task-state/R2.json"
            _write_json(r2, {
                "schema_version": "dicow-r2-task-state-v1", "task": "R2",
                "state": "done", "branch_disposition": "executed",
                "evidence_outcome": "supported", "run_id": "r2-run",
                "predecessor_state_hashes": {"R0": _sha(r0), "R1": _sha(r1)},
            })
            os.chmod(r2, 0o444)
            manifest.verify_r2_task_state("R2", run)
            value = json.loads(r2.read_text())
            value["predecessor_state_hashes"]["extra"] = "a" * 64
            os.chmod(r2, 0o644)
            _write_json(r2, value)
            os.chmod(r2, 0o444)
            with self.assertRaisesRegex(manifest.VerificationError, "not exact"):
                manifest.verify_r2_task_state("R2", run)

            amendment = run / "task-state/R1-contract-amendment-1.json"
            original = json.loads(r1.read_text())
            _write_json(amendment, {
                "schema_version": "dicow-r2-task-state-v1",
                "task": "R1-contract-amendment-1", "state": "done",
                "branch_disposition": "executed", "evidence_outcome": "supported",
                "run_id": "r2-run", "next_task_ids": ["R2"],
                "original_state_sha256": _sha(r1),
                "predecessor_state_hashes": {"R1": _sha(r1)},
                "tracked_files": {
                    relative: {"input": entry["output"], "output": entry["output"]}
                    for relative, entry in original["tracked_files"].items()
                },
            })
            os.chmod(amendment, 0o444)
            effective, effective_path = manifest.verify_r2_task_state("R1", run)
            self.assertEqual(effective["task"], "R1-contract-amendment-1")
            self.assertEqual(effective_path, amendment.resolve())

            amendment2 = run / "task-state/R1-contract-amendment-2.json"
            amendment1 = json.loads(amendment.read_text())
            _write_json(amendment2, {
                "schema_version": "dicow-r2-task-state-v1",
                "task": "R1-contract-amendment-2", "state": "done",
                "branch_disposition": "executed", "evidence_outcome": "supported",
                "run_id": "r2-run", "next_task_ids": ["R2"],
                "original_state_sha256": _sha(amendment),
                "predecessor_state_hashes": {"R1-contract-amendment-1": _sha(amendment)},
                "tracked_files": {
                    relative: {"input": entry["output"], "output": entry["output"]}
                    for relative, entry in amendment1["tracked_files"].items()
                },
            })
            os.chmod(amendment2, 0o444)
            effective, effective_path = manifest.verify_r2_task_state("R1", run)
            self.assertEqual(effective["task"], "R1-contract-amendment-2")
            self.assertEqual(effective_path, amendment2.resolve())
            amendment3 = run / "task-state/R1-contract-amendment-3.json"
            amendment2_value = json.loads(amendment2.read_text())
            _write_json(amendment3, {
                "schema_version": "dicow-r2-task-state-v1",
                "task": "R1-contract-amendment-3", "state": "done",
                "branch_disposition": "executed", "evidence_outcome": "supported",
                "run_id": "r2-run", "next_task_ids": ["R2"],
                "original_state_sha256": _sha(amendment2),
                "predecessor_state_hashes": {"R1-contract-amendment-2": _sha(amendment2)},
                "tracked_files": {
                    relative: {"input": entry["output"], "output": entry["output"]}
                    for relative, entry in amendment2_value["tracked_files"].items()
                },
            })
            os.chmod(amendment3, 0o444)
            effective, effective_path = manifest.verify_r2_task_state("R1", run)
            self.assertEqual(effective["task"], "R1-contract-amendment-3")
            self.assertEqual(effective_path, amendment3.resolve())
            amendment4 = run / "task-state/R1-contract-amendment-4.json"
            amendment3_value = json.loads(amendment3.read_text())
            _write_json(amendment4, {
                "schema_version": "dicow-r2-task-state-v1",
                "task": "R1-contract-amendment-4", "state": "done",
                "branch_disposition": "executed", "evidence_outcome": "supported",
                "run_id": "r2-run", "next_task_ids": ["R2"],
                "original_state_sha256": _sha(amendment3),
                "predecessor_state_hashes": {"R1-contract-amendment-3": _sha(amendment3)},
                "tracked_files": {
                    relative: {"input": entry["output"], "output": entry["output"]}
                    for relative, entry in amendment3_value["tracked_files"].items()
                },
            })
            os.chmod(amendment4, 0o444)
            effective, effective_path = manifest.verify_r2_task_state("R1", run)
            self.assertEqual(effective["task"], "R1-contract-amendment-4")
            self.assertEqual(effective_path, amendment4.resolve())
            amendment5 = run / "task-state/R1-contract-amendment-5.json"
            amendment4_value = json.loads(amendment4.read_text())
            _write_json(amendment5, {
                "schema_version": "dicow-r2-task-state-v1",
                "task": "R1-contract-amendment-5", "state": "done",
                "branch_disposition": "executed", "evidence_outcome": "supported",
                "run_id": "r2-run", "next_task_ids": ["R2"],
                "original_state_sha256": _sha(amendment4),
                "predecessor_state_hashes": {"R1-contract-amendment-4": _sha(amendment4)},
                "tracked_files": {
                    relative: {"input": entry["output"], "output": entry["output"]}
                    for relative, entry in amendment4_value["tracked_files"].items()
                },
            })
            os.chmod(amendment5, 0o444)
            effective, effective_path = manifest.verify_r2_task_state("R1", run)
            self.assertEqual(effective["task"], "R1-contract-amendment-5")
            self.assertEqual(effective_path, amendment5.resolve())
            amendment6 = run / "task-state/R1-contract-amendment-6.json"
            amendment5_value = json.loads(amendment5.read_text())
            _write_json(amendment6, {
                "schema_version": "dicow-r2-task-state-v1",
                "task": "R1-contract-amendment-6", "state": "done",
                "branch_disposition": "executed", "evidence_outcome": "supported",
                "run_id": "r2-run", "next_task_ids": ["R2"],
                "original_state_sha256": _sha(amendment5),
                "predecessor_state_hashes": {"R1-contract-amendment-5": _sha(amendment5)},
                "tracked_files": {
                    relative: {"input": entry["output"], "output": entry["output"]}
                    for relative, entry in amendment5_value["tracked_files"].items()
                },
            })
            os.chmod(amendment6, 0o444)
            effective, effective_path = manifest.verify_r2_task_state("R1", run)
            self.assertEqual(effective["task"], "R1-contract-amendment-6")
            self.assertEqual(effective_path, amendment6.resolve())
            amendment7 = run / "task-state/R1-contract-amendment-7.json"
            amendment6_value = json.loads(amendment6.read_text())
            _write_json(amendment7, {
                "schema_version": "dicow-r2-task-state-v1",
                "task": "R1-contract-amendment-7", "state": "done",
                "branch_disposition": "executed", "evidence_outcome": "supported",
                "run_id": "r2-run", "next_task_ids": ["R2"],
                "original_state_sha256": _sha(amendment6),
                "predecessor_state_hashes": {"R1-contract-amendment-6": _sha(amendment6)},
                "tracked_files": {
                    relative: {"input": entry["output"], "output": entry["output"]}
                    for relative, entry in amendment6_value["tracked_files"].items()
                },
            })
            os.chmod(amendment7, 0o444)
            effective, effective_path = manifest.verify_r2_task_state("R1", run)
            self.assertEqual(effective["task"], "R1-contract-amendment-7")
            self.assertEqual(effective_path, amendment7.resolve())
            amendment8 = run / "task-state/R1-contract-amendment-8.json"
            amendment7_value = json.loads(amendment7.read_text())
            _write_json(amendment8, {
                "schema_version": "dicow-r2-task-state-v1",
                "task": "R1-contract-amendment-8", "state": "done",
                "branch_disposition": "executed", "evidence_outcome": "supported",
                "run_id": "r2-run", "next_task_ids": ["R2"],
                "original_state_sha256": _sha(amendment7),
                "predecessor_state_hashes": {"R1-contract-amendment-7": _sha(amendment7)},
                "tracked_files": {
                    relative: {"input": entry["output"], "output": entry["output"]}
                    for relative, entry in amendment7_value["tracked_files"].items()
                },
            })
            os.chmod(amendment8, 0o444)
            effective, effective_path = manifest.verify_r2_task_state("R1", run)
            self.assertEqual(effective["task"], "R1-contract-amendment-8")
            self.assertEqual(effective_path, amendment8.resolve())
            amendment9 = run / "task-state/R1-contract-amendment-9.json"
            amendment8_value = json.loads(amendment8.read_text())
            _write_json(amendment9, {
                "schema_version": "dicow-r2-task-state-v1",
                "task": "R1-contract-amendment-9", "state": "done",
                "branch_disposition": "executed", "evidence_outcome": "supported",
                "run_id": "r2-run", "next_task_ids": ["R2"],
                "original_state_sha256": _sha(amendment8),
                "predecessor_state_hashes": {"R1-contract-amendment-8": _sha(amendment8)},
                "tracked_files": {
                    relative: {"input": entry["output"], "output": entry["output"]}
                    for relative, entry in amendment8_value["tracked_files"].items()
                },
            })
            os.chmod(amendment9, 0o444)
            effective, effective_path = manifest.verify_r2_task_state("R1", run)
            self.assertEqual(effective["task"], "R1-contract-amendment-9")
            self.assertEqual(effective_path, amendment9.resolve())
            amendment10 = run / "task-state/R1-contract-amendment-10.json"
            amendment9_value = json.loads(amendment9.read_text())
            _write_json(amendment10, {
                "schema_version": "dicow-r2-task-state-v1",
                "task": "R1-contract-amendment-10", "state": "done",
                "branch_disposition": "executed", "evidence_outcome": "supported",
                "run_id": "r2-run", "next_task_ids": ["R2"],
                "original_state_sha256": _sha(amendment9),
                "predecessor_state_hashes": {
                    "R1-contract-amendment-9": _sha(amendment9)
                },
                "tracked_files": {
                    relative: {"input": entry["output"], "output": entry["output"]}
                    for relative, entry in amendment9_value["tracked_files"].items()
                },
            })
            os.chmod(amendment10, 0o444)
            with mock.patch.dict(
                pins.R2_TASK_TRACKED_FILES,
                {"R1-contract-amendment-10": pins.R2_TRACKED_FILES},
            ):
                effective, effective_path = manifest.verify_r2_task_state("R1", run)
                self.assertEqual(effective["task"], "R1-contract-amendment-10")
                self.assertEqual(effective_path, amendment10.resolve())
            amendment10.unlink()
            malformed = json.loads(amendment9.read_text())
            malformed.pop("tracked_files")
            os.chmod(amendment9, 0o644)
            _write_json(amendment9, malformed)
            os.chmod(amendment9, 0o444)
            with self.assertRaises(manifest.VerificationError):
                manifest.verify_r2_task_state("R1", run)

    @mock.patch(
        "benchmarks.scripts.dicow.reference.inspect.verify_r2_audit",
        return_value={
            "status": "verified", "run_id": "r2-run",
            "summary": {"decision": {"dicow_scope": "evidence_blocker"}},
        },
    )
    def test_r3_state_requires_exact_next_and_tracked_transition(self, _audit_replay):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            paths = self._r2_bootstrap_fixture(run)
            r2 = run / "task-state/R2.json"
            _write_json(r2, {
                "schema_version": "dicow-r2-task-state-v1", "task": "R2",
                "state": "done", "branch_disposition": "executed",
                "evidence_outcome": "supported", "run_id": "r2-run",
                "predecessor_state_hashes": {
                    "R0": _sha(paths["R0"]), "R1": _sha(paths["R1"]),
                },
                "next_task_ids": ["R3"],
            })
            os.chmod(r2, 0o444)
            paths["R2"] = r2
            repo = Path(__file__).resolve().parents[4]
            tracked = {
                relative: {
                    "input": manifest._file_tuple(repo / relative),
                    "output": manifest._file_tuple(repo / relative),
                }
                for relative in pins.R2_TASK_TRACKED_FILES["R3"]
            }
            valid = {
                "schema_version": "dicow-r2-task-state-v1", "task": "R3",
                "state": "done", "branch_disposition": "executed",
                "evidence_outcome": "evidence_blocker", "run_id": "r2-run",
                "predecessor_state_hashes": {
                    "R1": _sha(paths["R1"]), "R2": _sha(r2),
                },
                "next_task_ids": ["R4"], "tracked_files": tracked,
            }
            valid.update(self._r3_publication_fields(run, paths))
            r3 = run / "task-state/R3.json"
            _write_json(r3, valid)
            os.chmod(r3, 0o444)
            manifest.verify_r2_task_state("R3", run)
            _audit_replay.assert_called_with(run.resolve() / "pre-model-audit")

            for outcome in ("supported", "not_supported", "unresolved", None):
                malformed = deepcopy(valid)
                if outcome is None:
                    malformed.pop("evidence_outcome")
                else:
                    malformed["evidence_outcome"] = outcome
                os.chmod(r3, 0o644)
                _write_json(r3, malformed)
                os.chmod(r3, 0o444)
                _audit_replay.reset_mock()
                with self.subTest(outcome=outcome), self.assertRaises(
                    manifest.VerificationError
                ):
                    manifest.verify_r2_task_state("R3", run)
                _audit_replay.assert_called_once_with(run.resolve() / "pre-model-audit")
                with self.subTest(
                    standalone_outcome=outcome
                ), self.assertRaises(manifest.VerificationError):
                    manifest.verify_tracked_transition("R3", run, repo)
            os.chmod(r3, 0o644)
            _write_json(r3, valid)
            os.chmod(r3, 0o444)

            first = pins.R2_TASK_TRACKED_FILES["R3"][0]
            mutations = {}
            missing = deepcopy(valid)
            missing["tracked_files"].pop(first)
            mutations["missing"] = missing
            extra = deepcopy(valid)
            extra["tracked_files"]["unexpected.py"] = deepcopy(tracked[first])
            mutations["extra"] = extra
            wrong_input = deepcopy(valid)
            wrong_input["tracked_files"][first]["input"]["sha256"] = "0" * 64
            mutations["wrong_input"] = wrong_input
            wrong_output = deepcopy(valid)
            wrong_output["tracked_files"][first]["output"]["sha256"] = "0" * 64
            mutations["wrong_output"] = wrong_output
            source_missing = deepcopy(valid)
            source_missing["source_input_hashes"].pop("r3_runtime_checksums")
            mutations["source_missing"] = source_missing
            source_extra = deepcopy(valid)
            source_extra["source_input_hashes"]["forged"] = "0" * 64
            mutations["source_extra"] = source_extra
            source_non_sha = deepcopy(valid)
            source_non_sha["source_input_hashes"]["r3_runtime_checksums"] = "not-a-sha"
            mutations["source_non_sha"] = source_non_sha
            source_wrong = deepcopy(valid)
            source_wrong["source_input_hashes"]["r3_runtime_checksums"] = "0" * 64
            mutations["source_wrong"] = source_wrong
            source_predecessor = deepcopy(valid)
            source_predecessor["source_input_hashes"]["R2_state"] = source_predecessor[
                "source_input_hashes"
            ]["R1_effective_state"]
            mutations["source_substituted_predecessor"] = source_predecessor
            artifact_missing = deepcopy(valid)
            artifact_missing["artifacts"] = {}
            mutations["artifact_missing"] = artifact_missing
            artifact_extra = deepcopy(valid)
            artifact_extra["artifacts"]["forged"] = deepcopy(
                artifact_extra["artifacts"]["model-identities"]
            )
            mutations["artifact_extra"] = artifact_extra
            artifact_detached = deepcopy(valid)
            artifact_detached["artifacts"]["model-identities"]["path"] = (
                "pre-model-audit/detached/model-identities.json"
            )
            mutations["artifact_detached"] = artifact_detached
            artifact_wrong = deepcopy(valid)
            artifact_wrong["artifacts"]["model-identities"]["sha256"] = "0" * 64
            mutations["artifact_wrong"] = artifact_wrong
            artifact_wrong_bytes = deepcopy(valid)
            artifact_wrong_bytes["artifacts"]["model-identities"]["bytes"] = 1
            mutations["artifact_wrong_bytes"] = artifact_wrong_bytes
            fragment_missing = deepcopy(valid)
            fragment_missing["sealed_fragments"] = {}
            mutations["fragment_missing"] = fragment_missing
            fragment_extra = deepcopy(valid)
            fragment_extra["sealed_fragments"]["forged.env"] = deepcopy(
                fragment_extra["sealed_fragments"]["R3-runtimes.env"]
            )
            mutations["fragment_extra"] = fragment_extra
            for field, value in (
                ("path", "env.d/forged.env"), ("sha256", "0" * 64),
                ("bytes", 1), ("mode", "0644"),
            ):
                changed = deepcopy(valid)
                changed["sealed_fragments"]["R3-runtimes.env"][field] = value
                mutations["fragment_wrong_{}".format(field)] = changed
            path_missing = deepcopy(valid)
            path_missing["sealed_paths"].pop("DICOW_R2_ALIGNER_VENV")
            mutations["path_missing"] = path_missing
            path_extra = deepcopy(valid)
            path_extra["sealed_paths"]["FORGED"] = deepcopy(
                path_extra["sealed_paths"]["DICOW_R2_ALIGNER_VENV"]
            )
            mutations["path_extra"] = path_extra
            for field, value in (
                ("path", "/tmp/forged"), ("sha256", "0" * 64),
                ("bytes", 1), ("mode", "0700"),
            ):
                changed = deepcopy(valid)
                changed["sealed_paths"]["DICOW_R2_ALIGNER_VENV"][field] = value
                mutations["path_wrong_{}".format(field)] = changed
            for next_tasks in (None, [], ["R4", "R5"], ["R5"]):
                changed = deepcopy(valid)
                if next_tasks is None:
                    changed.pop("next_task_ids")
                else:
                    changed["next_task_ids"] = next_tasks
                mutations["next_{}".format(next_tasks)] = changed
            for name, malformed in mutations.items():
                os.chmod(r3, 0o644)
                _write_json(r3, malformed)
                os.chmod(r3, 0o444)
                with self.subTest(name=name), self.assertRaises(manifest.VerificationError):
                    manifest.verify_r2_task_state("R3", run)
            os.chmod(r3, 0o644)
            _write_json(r3, valid)
            os.chmod(r3, 0o444)

            good_replay = {
                "status": "verified", "run_id": "r2-run",
                "summary": {"decision": {"dicow_scope": "evidence_blocker"}},
            }
            _audit_replay.return_value = {
                "status": "verified", "run_id": "r2-run",
                "summary": {"decision": {"dicow_scope": "proceed"}},
            }
            with self.assertRaisesRegex(
                manifest.VerificationError, "does not prove.*evidence blocker"
            ):
                manifest.verify_r2_task_state("R3", run)
            _audit_replay.return_value = good_replay
            for attack in (
                "minimal audit", "detached audit", "malformed document",
                "malformed model identity", "extra attempt", "noncanonical attempt",
            ):
                _audit_replay.side_effect = RuntimeError(attack)
                with self.subTest(attack=attack), self.assertRaisesRegex(
                    manifest.VerificationError, "audit replay failed"
                ):
                    manifest.verify_r2_task_state("R3", run)
            _audit_replay.side_effect = None

            selected_path = run / "pre-model-audit/attempts/fixture/manifest.json"
            canonical_path = run / "pre-model-audit/canonical.json"
            selected = json.loads(selected_path.read_text())
            canonical = json.loads(canonical_path.read_text())
            malformed_selected = deepcopy(selected)
            malformed_selected.pop("spec_record")
            os.chmod(selected_path, 0o644)
            _write_json(selected_path, malformed_selected)
            os.chmod(selected_path, 0o444)
            changed_canonical = deepcopy(canonical)
            changed_canonical["manifest_record"] = {
                "sha256": _sha(selected_path), "bytes": selected_path.stat().st_size,
            }
            os.chmod(canonical_path, 0o644)
            _write_json(canonical_path, changed_canonical)
            os.chmod(canonical_path, 0o444)
            changed_state = deepcopy(valid)
            changed_state["source_input_hashes"]["pre_model_audit_manifest"] = _sha(
                selected_path
            )
            os.chmod(r3, 0o644)
            _write_json(r3, changed_state)
            os.chmod(r3, 0o444)
            with self.assertRaisesRegex(
                manifest.VerificationError, "active frozen spec"
            ):
                manifest.verify_r2_task_state("R3", run)
            os.chmod(selected_path, 0o644)
            _write_json(selected_path, selected)
            os.chmod(selected_path, 0o444)
            os.chmod(canonical_path, 0o644)
            _write_json(canonical_path, canonical)
            os.chmod(canonical_path, 0o444)
            os.chmod(r3, 0o644)
            _write_json(r3, valid)
            os.chmod(r3, 0o444)

            forged = deepcopy(canonical)
            forged["attempt"] = str(run / "pre-model-audit/attempts/forged")
            os.chmod(canonical_path, 0o644)
            _write_json(canonical_path, forged)
            os.chmod(canonical_path, 0o444)
            with self.assertRaises(manifest.VerificationError):
                manifest.verify_r2_task_state("R3", run)
            os.chmod(canonical_path, 0o644)
            _write_json(canonical_path, canonical)
            os.chmod(canonical_path, 0o444)

    def test_r2_r0_accepts_provenance_superset_but_requires_exact_plan_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            paths = self._r2_bootstrap_fixture(run)
            r0 = paths["R0"]
            manifest.verify_r2_task_state("R0", run)
            original = json.loads(r0.read_text())
            for mutation in ("missing", "wrong"):
                malformed = deepcopy(original)
                if mutation == "missing":
                    malformed["source_input_hashes"].pop("plan_contract")
                else:
                    malformed["source_input_hashes"]["plan_contract"] = "c" * 64
                os.chmod(r0, 0o644)
                _write_json(r0, malformed)
                os.chmod(r0, 0o444)
                with self.subTest(mutation=mutation), self.assertRaisesRegex(
                    manifest.VerificationError, "exact r2 plan contract"
                ):
                    manifest.verify_r2_task_state("R0", run)
            os.chmod(r0, 0o644)
            _write_json(r0, original)
            os.chmod(r0, 0o444)

    def test_r2_task_state_rejects_minimal_resealed_r0_and_r1(self):
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            paths = self._r2_bootstrap_fixture(run)
            manifest.verify_r2_task_state("R1", run)
            for task, removed in (("R0", "artifacts"), ("R1", "tracked_files")):
                path = paths[task]
                original = json.loads(path.read_text())
                malformed = deepcopy(original)
                malformed.pop(removed)
                os.chmod(path, 0o644)
                _write_json(path, malformed)
                os.chmod(path, 0o444)
                with self.assertRaises(manifest.VerificationError):
                    manifest.verify_r2_task_state(task, run)
                os.chmod(path, 0o644)
                _write_json(path, original)
                os.chmod(path, 0o444)

    @mock.patch("benchmarks.scripts.dicow.common.manifest.verify_gate")
    @mock.patch("benchmarks.scripts.dicow.common.manifest.verify_r2_task_state")
    @mock.patch(
        "benchmarks.scripts.dicow.reference.inspect.verify_r2_audit",
        return_value={
            "status": "verified", "run_id": "r2-run",
            "summary": {"decision": {"dicow_scope": "evidence_blocker"}},
        },
    )
    def test_r2_experiment_path_replays_states_source_and_evidence_bytes(
        self, _audit_replay, state_replay, _gate_replay
    ):
        def replay_with_legacy_hypothetical_r4(task, run_root):
            if task == "R4":
                path = Path(run_root) / "task-state/R4.json"
                return json.loads(path.read_text()), path
            return _REAL_VERIFY_R2_TASK_STATE(task, run_root)

        state_replay.side_effect = replay_with_legacy_hypothetical_r4
        with tempfile.TemporaryDirectory() as directory:
            run = Path(directory)
            evidence_document = ExperimentContractTests()._document()
            evidence_document["run_id"] = "r2-run"
            GateVerificationTests._materialize_experiment_evidence(run, evidence_document)
            evidence_path = run / "phase-a-mlc/evidence.json"
            _write_json(evidence_path, evidence_document)
            paths = self._r2_bootstrap_fixture(run)
            j1_path = run / pins.R2_J1_GATE_PATH
            _write_json(j1_path, {
                "gate_id": "J1-r2", "task": "R4",
                "decision": {
                    "scope": "proceed_dicow_and_qwen",
                    "evidence_outcome": "supported",
                    "next_task_ids": ["R5", "Q1", "R6"],
                    "skip_task_ids": [],
                },
            })
            os.chmod(j1_path, 0o444)
            dependencies = {
                "R2": ("R0", "R1"),
                "R3": ("R1", "R2"), "R4": ("R3",),
                "R5": ("R4",), "R6": ("R4",),
            }
            for task, needs in dependencies.items():
                state = {
                    "schema_version": "dicow-r2-task-state-v1", "task": task,
                    "state": "done", "branch_disposition": "executed",
                    "evidence_outcome": "supported", "run_id": "r2-run",
                }
                if task not in ("R0", "R1"):
                    state["predecessor_state_hashes"] = {need: _sha(paths[need]) for need in needs}
                if task == "R3":
                    state["evidence_outcome"] = "evidence_blocker"
                    state["next_task_ids"] = ["R4"]
                    state["tracked_files"] = {
                        relative: {
                            "input": manifest._file_tuple(Path(__file__).resolve().parents[4] / relative),
                            "output": manifest._file_tuple(Path(__file__).resolve().parents[4] / relative),
                        }
                        for relative in pins.R2_TASK_TRACKED_FILES["R3"]
                    }
                    state.update(self._r3_publication_fields(run, paths))
                if task == "R4":
                    state.update({
                        "next_task_ids": ["R5", "Q1", "R6"],
                        "gate_path": pins.R2_J1_GATE_PATH,
                        "gate_sha256": _sha(j1_path),
                    })
                path = run / "task-state" / (task + ".json")
                _write_json(path, state)
                os.chmod(path, 0o444)
                paths[task] = path
            source_path = (
                run / "pre-model-audit/attempts/fixture/audit/model-identities.json"
            ).resolve()
            dicow_provenance = next(
                row for row in evidence_document["execution_provenance"]
                if row["model_role"] == "dicow"
            )
            mlc_asset = dicow_provenance["model_asset"]["record"]
            mlc_source = {
                "model_id": dicow_provenance["model_id"],
                "revision": dicow_provenance["model_revision"],
                "weights_sha256": mlc_asset["sha256"],
                "weights_bytes": mlc_asset["bytes"],
            }
            os.chmod(source_path, 0o644)
            _write_json(source_path, {
                "schema_version": "dicow-r2-model-identities-v1",
                "models": [{
                    "candidate": "dicow_mlc",
                    "model_id": mlc_source["model_id"],
                    "revision": mlc_source["revision"],
                    "model_file_lfs_sha256": mlc_source["weights_sha256"],
                    "model_file_bytes": mlc_source["weights_bytes"],
                }],
            })
            os.chmod(source_path, 0o444)

            def reseal_source_binding() -> None:
                r3 = json.loads(paths["R3"].read_text())
                r3["artifacts"] = {"model-identities": {
                    "path": str(source_path.relative_to(run.resolve())),
                    "sha256": _sha(source_path),
                    "bytes": source_path.stat().st_size,
                }}
                os.chmod(paths["R3"], 0o644)
                _write_json(paths["R3"], r3)
                os.chmod(paths["R3"], 0o444)
                for task, predecessor in (("R4", "R3"), ("R5", "R4"), ("R6", "R4")):
                    state = json.loads(paths[task].read_text())
                    state["predecessor_state_hashes"] = {predecessor: _sha(paths[predecessor])}
                    os.chmod(paths[task], 0o644)
                    _write_json(paths[task], state)
                    os.chmod(paths[task], 0o444)

            reseal_source_binding()

            experiment = {
                "schema_version": "dicow-r2-experiment-envelope-v1",
                "experiment_id": "r2-fixture", "run_id": "r2-run", "task": "R8",
                "candidate_id": "dicow_mlc",
                "candidate_source": {
                    **mlc_source,
                    "source_task": "R3",
                    "source_artifact_format": "dicow-r2-model-identities-v1",
                    "source_artifact_id": "model-identities",
                    "source_artifact_path": str(source_path.relative_to(run.resolve())),
                    "source_artifact_sha256": _sha(source_path),
                    "source_artifact_bytes": source_path.stat().st_size,
                },
                "execution_basis": {task: _sha(paths[task]) for task in ("R3", "R5", "R6")},
                "r2_contract": self._contract(),
                "evidence": {
                    "format": "dicow-experiment-v1", "candidate_model": "dicow",
                    "evidence_id": "E4", "path": "phase-a-mlc/evidence.json",
                    "sha256": _sha(evidence_path),
                    "bytes": evidence_path.stat().st_size,
                },
            }
            experiment_path = run / "phase-a-mlc/envelope.json"
            _write_json(experiment_path, experiment)
            manifest.verify_experiment_path(experiment_path)
            source_value = json.loads(source_path.read_text())
            source_value["models"][0]["revision"] = "semantic-forgery"
            os.chmod(source_path, 0o644)
            _write_json(source_path, source_value)
            os.chmod(source_path, 0o444)
            reseal_source_binding()
            experiment["candidate_source"]["source_artifact_sha256"] = _sha(source_path)
            experiment["candidate_source"]["source_artifact_bytes"] = source_path.stat().st_size
            experiment["execution_basis"] = {
                task: _sha(paths[task]) for task in ("R3", "R5", "R6")
            }
            _write_json(experiment_path, experiment)
            with self.assertRaisesRegex(manifest.VerificationError, "exact candidate tuple"):
                manifest.verify_experiment_path(experiment_path)
            source_value["models"][0]["revision"] = pins.R2_MODEL_PINS["dicow_mlc"]["revision"]
            os.chmod(source_path, 0o644)
            _write_json(source_path, source_value)
            os.chmod(source_path, 0o444)
            reseal_source_binding()
            experiment["candidate_source"]["source_artifact_sha256"] = _sha(source_path)
            experiment["candidate_source"]["source_artifact_bytes"] = source_path.stat().st_size
            experiment["execution_basis"] = {
                task: _sha(paths[task]) for task in ("R3", "R5", "R6")
            }
            _write_json(experiment_path, experiment)
            evidence_path.write_text('{"tampered":true}\n')
            with self.assertRaisesRegex(manifest.VerificationError, "SHA-256 mismatch"):
                manifest.verify_experiment_path(experiment_path)

            # A valid inner MLC experiment cannot be relabeled as v3.3. R9 must change
            # the inner provenance, model manifest, T9/T13 basis, and raw receipts.
            _write_json(evidence_path, evidence_document)
            source_value = json.loads(source_path.read_text())
            v33_source = {
                "model_id": pins.R2_MODEL_PINS["dicow_v3_3"]["model_id"],
                "revision": "v33-revision",
                "weights_sha256": mlc_asset["sha256"],
                "weights_bytes": mlc_asset["bytes"],
            }
            source_value["models"].append({
                "candidate": "dicow_v3_3", "model_id": v33_source["model_id"],
                "revision": v33_source["revision"],
                "model_file_lfs_sha256": v33_source["weights_sha256"],
                "model_file_bytes": v33_source["weights_bytes"],
            })
            os.chmod(source_path, 0o644)
            _write_json(source_path, source_value)
            os.chmod(source_path, 0o444)
            reseal_source_binding()
            experiment.update({"task": "R9", "candidate_id": "dicow_v3_3"})
            experiment["candidate_source"].update(v33_source)
            experiment["candidate_source"].update({
                "source_artifact_sha256": _sha(source_path),
                "source_artifact_bytes": source_path.stat().st_size,
            })
            experiment["execution_basis"] = {
                task: _sha(paths[task]) for task in ("R3", "R5", "R6")
            }
            experiment["evidence"].update({
                "sha256": _sha(evidence_path), "bytes": evidence_path.stat().st_size,
            })
            _write_json(experiment_path, experiment)
            with self.assertRaisesRegex(manifest.VerificationError, "differs from pins"):
                manifest.verify_experiment_path(experiment_path)

            v33_evidence = deepcopy(evidence_document)
            v33_provenance = next(
                row for row in v33_evidence["execution_provenance"]
                if row["model_role"] == "dicow"
            )
            v33_provenance.update({
                "model_id": v33_source["model_id"],
                "model_revision": v33_source["revision"],
            })
            with self.assertRaisesRegex(manifest.VerificationError, "differs from pins"):
                manifest.verify_experiment_document(v33_evidence)
            os.chmod(run / "run-manifest.json", 0o644)
            GateVerificationTests._materialize_experiment_evidence(run, v33_evidence)
            mlc_execution_hashes = {
                arm["arm_id"]: arm["execution_input"]["sha256"]
                for arm in evidence_document["arms"] if arm["model"] == "dicow"
            }
            self.assertTrue(any(
                arm["execution_input"]["sha256"] != mlc_execution_hashes[arm["arm_id"]]
                for arm in v33_evidence["arms"] if arm["model"] == "dicow"
            ))
            _write_json(evidence_path, v33_evidence)
            paths = self._r2_bootstrap_fixture(run)
            for task, needs in dependencies.items():
                state = {
                    "schema_version": "dicow-r2-task-state-v1", "task": task,
                    "state": "done", "branch_disposition": "executed",
                    "evidence_outcome": "supported", "run_id": "r2-run",
                    "predecessor_state_hashes": {need: _sha(paths[need]) for need in needs},
                }
                if task == "R3":
                    state["evidence_outcome"] = "evidence_blocker"
                    state["next_task_ids"] = ["R4"]
                    state["tracked_files"] = {
                        relative: {
                            "input": manifest._file_tuple(
                                Path(__file__).resolve().parents[4] / relative
                            ),
                            "output": manifest._file_tuple(
                                Path(__file__).resolve().parents[4] / relative
                            ),
                        }
                        for relative in pins.R2_TASK_TRACKED_FILES["R3"]
                    }
                    state.update(self._r3_publication_fields(run, paths))
                if task == "R4":
                    state.update({
                        "next_task_ids": ["R5", "Q1", "R6"],
                        "gate_path": pins.R2_J1_GATE_PATH,
                        "gate_sha256": _sha(j1_path),
                    })
                path = run / "task-state" / (task + ".json")
                if path.exists():
                    os.chmod(path, 0o644)
                _write_json(path, state)
                os.chmod(path, 0o444)
                paths[task] = path
            reseal_source_binding()
            experiment["execution_basis"] = {
                task: _sha(paths[task]) for task in ("R3", "R5", "R6")
            }
            experiment["evidence"].update({
                "sha256": _sha(evidence_path), "bytes": evidence_path.stat().st_size,
            })
            _write_json(experiment_path, experiment)
            manifest.verify_experiment_path(experiment_path)


if __name__ == "__main__":
    unittest.main()
