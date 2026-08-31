from __future__ import annotations

import hashlib
import json
import os
import stat
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

from benchmarks.scripts.dicow.reference import ctc_invariance


def _strict_bytes(value: object) -> bytes:
    return (json.dumps(value, allow_nan=False, sort_keys=True, indent=2) + "\n").encode()


class CtcInvarianceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(dir=Path(tempfile.gettempdir()).resolve())
        self.root = Path(self.temporary.name)
        self.runner = self.root / "fake_runner.py"
        self.runner.write_text(textwrap.dedent(r'''
            import hashlib
            import json
            import os
            import sys

            scenario = os.environ["DICOW_CTC_PROOF_SCENARIO"]
            request = json.load(sys.stdin)
            request_sha = hashlib.sha256(
                (json.dumps(request, allow_nan=False, ensure_ascii=False,
                            separators=(",", ":"), sort_keys=True) + "\n").encode()
            ).hexdigest()
            mode = os.environ.get("DICOW_TEST_MODE", "pass")

            def tensor(label):
                digest = hashlib.sha256((request_sha + ":" + label).encode()).hexdigest()
                return {"shape": [1, 2], "dtype": "float32", "byte_order": "little",
                        "layout": "c_contiguous", "bytes": 8,
                        "sha256": digest, "finite": True}

            observables = {
                "encoder_post_layernorm": tensor("encoder"),
                "r1_captures": {"r1-block0-input": tensor("r1")},
                "r2_captures": {"r2-full-encoder": tensor("r2")},
                "decoder_input_ids": [50258, 50259, 42],
                "teacher_forced_logits": tensor("logits"),
                "greedy_token_ids": [42, 43],
                "greedy_timestamp_ids": [50364, 50365],
                "greedy_text": "hello",
                "segments": [{"start_seconds": 0.0, "end_seconds": 1.0,
                              "text": "hello",
                              "text_token_ids": [42, 43],
                              "timestamp_token_ids": [50364, 50365]}],
                "boundaries": [{"segment_index": 0, "start_seconds": 0.0,
                                "end_seconds": 1.0}],
            }
            if mode == "missing_observable":
                observables.pop("teacher_forced_logits")
            if mode == "changed_sequence" and scenario in {"nan_perturbation", "branch_bypass"}:
                observables["decoder_input_ids"] = [50258, 99]
            if mode == "token_only_equal" and scenario == "nan_perturbation":
                observables["encoder_post_layernorm"] = tensor("changed-encoder")
            if mode == "changed_text_only" and scenario == "nan_perturbation":
                observables["greedy_text"] = "changed"
            if mode == "nondeterministic" and scenario == "baseline_b":
                observables["r2_captures"]["r2-full-encoder"] = tensor("unstable")
            if mode == "invalid_boundary":
                observables["boundaries"][0]["segment_index"] = 1
            observables["teacher_forced_input_ids_sha256"] = hashlib.sha256(
                (json.dumps(observables["decoder_input_ids"], allow_nan=False,
                            ensure_ascii=False, separators=(",", ":"),
                            sort_keys=True) + "\n").encode()
            ).hexdigest()

            names = [
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
            ]
            if scenario == "nan_perturbation":
                perturbed = names[:-1] if mode == "wrong_tensor_set" else names
                branch = {"calls": 1, "processor_present": False,
                          "perturbed_tensor_names": perturbed, "bypassed": False,
                          "output_summary": {"all_nan": True, "shape": [1, 3, 51866],
                                             "dtype": "float32"}}
            elif scenario == "branch_bypass":
                branch = {"calls": 0, "processor_present": False,
                          "perturbed_tensor_names": [], "bypassed": True,
                          "output_summary": None}
            else:
                branch = {"calls": 1, "processor_present": False,
                          "perturbed_tensor_names": [], "bypassed": False,
                          "output_summary": {"all_nan": False, "shape": [1, 3, 51866],
                                             "dtype": "float32"}}
            if mode == "branch_payload" and scenario == "nan_perturbation":
                branch["payload"] = [1.0]

            record = {
                "schema_version": "dicow-ctc-observation-v1",
                "request_sha256": request_sha,
                "scenario": scenario,
                "process": {"pid": os.getpid(), "device": "cpu", "dtype": "float32",
                            "attention": "eager", "deterministic_algorithms": True,
                            "threads": 1, "seed": 0, "decode": "greedy",
                            "previous_token_conditioning": False},
                "execution_binding": {
                    "runner_sha256": os.environ["DICOW_CTC_PROOF_RUNNER_SHA256"],
                    "model_sha256": "2" * 64,
                    "model_config_sha256": "3" * 64,
                    "input_sha256": request_sha,
                    "instrumentation_sha256": os.environ.get(
                        "DICOW_TEST_INSTRUMENTATION_SHA256", "4" * 64
                    ),
                },
                "ctc_branch": branch,
                "observables": observables,
            }
            if mode == "runner_failure":
                print("FORBIDDEN-BRANCH-PAYLOAD-SENTINEL", file=sys.stderr)
                raise SystemExit(7)
            if mode == "raw_nan" and scenario == "nan_perturbation":
                record["observables"]["segments"][0]["start_seconds"] = float("nan")
                print(json.dumps(record, allow_nan=True))
            else:
                print(json.dumps(record, allow_nan=False, sort_keys=True))
        '''), encoding="utf-8")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def _universe_value(self) -> dict:
        t10_dicow = {"fixture": "hike-pair-v1", "window": "00", "target": "A", "prompt": "off"}
        t10_control = {"fixture": "hike-pair-v1", "window": "00", "target": "control"}
        absent = {"fixture": "hike-pair-v1", "window": "00", "target": "ABSENT"}
        ami = {"fixture": "ami-in1009", "window": "95-125", "target": "A", "replay": True}
        proof = sorted(
            hashlib.sha256(ctc_invariance._canonical(item)).hexdigest()
            for item in (t10_dicow, ami)
        )
        t10_rows = [
            {"request_id": "t10-dicow", "model_kind": "dicow", "invocation_kind": "actual", "signature": t10_dicow},
            {"request_id": "t10-control", "model_kind": "vanilla_control", "invocation_kind": "actual", "signature": t10_control},
            {"request_id": "t10-absent", "model_kind": "dicow", "invocation_kind": "virtual_absent", "signature": absent},
        ]
        ami_rows = [
            {"request_id": "ami-dicow", "model_kind": "dicow", "invocation_kind": "actual", "signature": ami},
        ]
        source_records = {}
        for role, rows in (("t10", t10_rows), ("ami_parity", ami_rows)):
            source_path = self.root / (role + "-requests.json")
            if source_path.exists():
                source_path.chmod(0o644)
            source_raw = _strict_bytes({
                "schema_version": ctc_invariance.SOURCE_SCHEMA_VERSION,
                "source": role,
                "requests": rows,
            })
            source_path.write_bytes(source_raw)
            source_path.chmod(0o444)
            source_records[role] = {
                "path": str(source_path),
                "sha256": hashlib.sha256(source_raw).hexdigest(),
            }
        return {
            "schema_version": ctc_invariance.UNIVERSE_SCHEMA_VERSION,
            "capture_contract": {"r1": ["r1-block0-input"], "r2": ["r2-full-encoder"]},
            "source_manifests": source_records,
            "proof_request_sha256s": proof,
        }

    def _write_universe(self, value: dict | None = None, *, mode: int = 0o444) -> tuple[Path, str]:
        path = self.root / "universe.json"
        raw = _strict_bytes(value if value is not None else self._universe_value())
        if path.exists():
            path.chmod(0o644)
        path.write_bytes(raw)
        path.chmod(mode)
        return path, hashlib.sha256(raw).hexdigest()

    def _load(self, value: dict | None = None) -> ctc_invariance.RequestUniverse:
        path, digest = self._write_universe(value)
        actual = value if value is not None else json.loads(path.read_text())
        return ctc_invariance.load_universe(
            path,
            digest,
            expected_t10_sha256=actual["source_manifests"]["t10"]["sha256"],
            expected_ami_sha256=actual["source_manifests"]["ami_parity"]["sha256"],
        )

    def _rewrite_source(self, universe: dict, role: str, mutate) -> None:
        path = Path(universe["source_manifests"][role]["path"])
        value = json.loads(path.read_text(encoding="utf-8"))
        mutate(value["requests"])
        raw = _strict_bytes(value)
        path.chmod(0o644)
        path.write_bytes(raw)
        path.chmod(0o444)
        universe["source_manifests"][role]["sha256"] = hashlib.sha256(raw).hexdigest()

    def _run(self, mode: str = "pass", *, repair_mode: str | None = None) -> dict:
        universe = self._load()
        return ctc_invariance.execute_proof(
            universe,
            [sys.executable, str(self.runner)],
            runner_env={
                "DICOW_TEST_MODE": mode,
                "DICOW_TEST_INSTRUMENTATION_SHA256": "4" * 64,
            },
            repair_runner_argv=[sys.executable, str(self.runner)] if repair_mode is not None else None,
            repair_runner_env={
                "DICOW_TEST_MODE": repair_mode,
                "DICOW_TEST_INSTRUMENTATION_SHA256": "5" * 64,
            } if repair_mode is not None else None,
            timeout_seconds=10,
        )

    def test_complete_contract_pass_is_only_eligible_pending_actual_invariance(self) -> None:
        report = self._run()
        self.assertEqual(report["evidence_outcome"], "eligible_pending_invariance")
        self.assertEqual(report["branch_verdict"], "proceed")
        self.assertFalse(report["actual_model_proof_completed"])
        self.assertEqual(report["universe"]["request_count"], 2)
        self.assertEqual(sum(row["process_count"] for row in report["attempts"][0]["requests"]), 8)
        json.dumps(report, allow_nan=False)

    def test_universe_is_hash_and_mode_bound_and_strict_json(self) -> None:
        path, digest = self._write_universe(mode=0o644)
        value = json.loads(path.read_text(encoding="utf-8"))
        with self.assertRaisesRegex(ctc_invariance.ContractError, "0444"):
            ctc_invariance.load_universe(
                path, digest,
                expected_t10_sha256=value["source_manifests"]["t10"]["sha256"],
                expected_ami_sha256=value["source_manifests"]["ami_parity"]["sha256"],
            )
        path.chmod(0o444)
        with self.assertRaisesRegex(ctc_invariance.ContractError, "SHA-256 mismatch"):
            ctc_invariance.load_universe(
                path, "0" * 64,
                expected_t10_sha256="0" * 64, expected_ami_sha256="0" * 64,
            )
        path.chmod(0o644)
        path.write_text('{"schema_version":"x","schema_version":"y"}', encoding="utf-8")
        path.chmod(0o444)
        duplicate_digest = hashlib.sha256(path.read_bytes()).hexdigest()
        with self.assertRaisesRegex(ctc_invariance.ContractError, "duplicate JSON key"):
            ctc_invariance.load_universe(
                path, duplicate_digest,
                expected_t10_sha256="0" * 64, expected_ami_sha256="0" * 64,
            )
        path.chmod(0o644)
        path.write_text('{"schema_version":NaN}', encoding="utf-8")
        path.chmod(0o444)
        nonfinite_digest = hashlib.sha256(path.read_bytes()).hexdigest()
        with self.assertRaisesRegex(ctc_invariance.ContractError, "non-finite"):
            ctc_invariance.load_universe(
                path, nonfinite_digest,
                expected_t10_sha256="0" * 64, expected_ami_sha256="0" * 64,
            )

    def test_universe_rejects_duplicates_and_exact_coverage_mismatch(self) -> None:
        value = self._universe_value()
        def duplicate(rows):
            rows.append(dict(rows[0]))
            rows[-1]["request_id"] = "duplicate-signature"
        self._rewrite_source(value, "t10", duplicate)
        with self.assertRaisesRegex(ctc_invariance.ContractError, "duplicate request signature"):
            self._load(value)
        value = self._universe_value()
        value["proof_request_sha256s"] = value["proof_request_sha256s"][:-1]
        with self.assertRaisesRegex(ctc_invariance.ContractError, "does not exactly match"):
            self._load(value)
        value = self._universe_value()
        self._rewrite_source(
            value, "ami_parity",
            lambda rows: rows[0].__setitem__("invocation_kind", "virtual_absent"),
        )
        with self.assertRaisesRegex(ctc_invariance.ContractError, "AMI parity"):
            self._load(value)

    def test_independent_t10_source_cannot_omit_all_actual_dicow_requests(self) -> None:
        value = self._universe_value()
        self._rewrite_source(
            value, "t10",
            lambda rows: [row.__setitem__("model_kind", "vanilla_control")
                          for row in rows if row["invocation_kind"] == "actual"],
        )
        value["proof_request_sha256s"] = value["proof_request_sha256s"][1:]
        with self.assertRaisesRegex(ctc_invariance.ContractError, "no actual DiCoW"):
            self._load(value)

    def test_missing_observable_wrong_tensor_set_and_nan_output_are_blockers(self) -> None:
        for mode, expected in (
            ("missing_observable", "keys differ"),
            ("wrong_tensor_set", "exact ten-tensor"),
            ("raw_nan", "non-finite"),
            ("branch_payload", "keys differ"),
        ):
            with self.subTest(mode=mode):
                report = self._run(mode)
                self.assertEqual(report["evidence_outcome"], "evidence_blocker")
                self.assertEqual(report["branch_verdict"], "revise")
                self.assertIn(expected, report["reason"])

    def test_nondeterministic_baseline_is_blocker_not_negative_model_evidence(self) -> None:
        report = self._run("nondeterministic")
        self.assertEqual(report["evidence_outcome"], "evidence_blocker")
        self.assertIn("nondeterministic", report["reason"])
        self.assertNotEqual(report["evidence_outcome"], "not_supported")

    def test_changed_common_sequence_needs_repair_then_retargets(self) -> None:
        without_repair = self._run("changed_sequence")
        self.assertEqual(without_repair["evidence_outcome"], "evidence_blocker")
        self.assertIn("bounded harness repair", without_repair["reason"])
        with_repair = self._run("changed_sequence", repair_mode="changed_sequence")
        self.assertEqual(with_repair["evidence_outcome"], "not_supported")
        self.assertEqual(with_repair["branch_verdict"], "retarget")
        self.assertEqual(with_repair["repair_attempts"], 1)

    def test_token_only_equality_cannot_hide_encoder_difference(self) -> None:
        report = self._run("token_only_equal", repair_mode="token_only_equal")
        self.assertEqual(report["evidence_outcome"], "not_supported")
        rows = report["attempts"][1]["requests"]
        self.assertIn("encoder_post_layernorm", rows[0]["perturbation_mismatches"])
        self.assertNotIn("greedy_token_ids", rows[0]["perturbation_mismatches"])

    def test_text_only_difference_is_compared_and_boundary_mismatch_is_blocker(self) -> None:
        text_report = self._run("changed_text_only", repair_mode="changed_text_only")
        self.assertEqual(text_report["evidence_outcome"], "not_supported")
        self.assertIn(
            "greedy_text",
            text_report["attempts"][1]["requests"][0]["perturbation_mismatches"],
        )
        boundary_report = self._run("invalid_boundary")
        self.assertEqual(boundary_report["evidence_outcome"], "evidence_blocker")
        self.assertIn("boundary indices", boundary_report["reason"])

    def test_successful_bounded_harness_repair_restores_pending_eligibility(self) -> None:
        report = self._run("changed_sequence", repair_mode="pass")
        self.assertEqual(report["evidence_outcome"], "eligible_pending_invariance")
        self.assertEqual(report["repair_attempts"], 1)
        self.assertFalse(report["actual_model_proof_completed"])

    def test_repair_without_hashed_instrumentation_change_is_blocker(self) -> None:
        universe = self._load()
        common = {
            "DICOW_TEST_INSTRUMENTATION_SHA256": "4" * 64,
        }
        report = ctc_invariance.execute_proof(
            universe,
            [sys.executable, str(self.runner)],
            runner_env={**common, "DICOW_TEST_MODE": "changed_sequence"},
            repair_runner_argv=[sys.executable, str(self.runner)],
            repair_runner_env={**common, "DICOW_TEST_MODE": "pass"},
            timeout_seconds=10,
        )
        self.assertEqual(report["evidence_outcome"], "evidence_blocker")
        self.assertIn("hashed instrumentation change", report["reason"])

    def test_repair_that_introduces_a_different_mismatch_is_blocker(self) -> None:
        report = self._run("changed_sequence", repair_mode="token_only_equal")
        self.assertEqual(report["evidence_outcome"], "evidence_blocker")
        self.assertIn("mismatch identity", report["reason"])

    def test_tensor_shape_bytes_and_dtype_must_describe_cpu_fp32_payload(self) -> None:
        value = {
            "shape": [2, 3], "dtype": "float32", "byte_order": "little",
            "layout": "c_contiguous", "bytes": 24,
            "sha256": "a" * 64, "finite": True,
        }
        ctc_invariance._tensor(value, "capture")
        for key, replacement in (("bytes", 12), ("dtype", "float16"), ("finite", False)):
            with self.subTest(key=key):
                changed = dict(value)
                changed[key] = replacement
                with self.assertRaises(ctc_invariance.ContractError):
                    ctc_invariance._tensor(changed, "capture")

    def test_failed_runner_stderr_is_digest_only(self) -> None:
        report = self._run("runner_failure")
        serialized = json.dumps(report, allow_nan=False)
        self.assertEqual(report["evidence_outcome"], "evidence_blocker")
        self.assertNotIn("FORBIDDEN-BRANCH-PAYLOAD-SENTINEL", serialized)
        self.assertIn("stderr_sha256=", report["reason"])

    def test_relative_runner_code_file_is_not_hash_bound(self) -> None:
        with self.assertRaisesRegex(ctc_invariance.ContractError, "absolute files"):
            ctc_invariance._runner_command_sha256([sys.executable, "relative/runner.py"])


if __name__ == "__main__":
    unittest.main()
