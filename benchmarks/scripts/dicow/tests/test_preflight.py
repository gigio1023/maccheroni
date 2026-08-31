"""Adversarial tests for the E0 resource and promotion substrate."""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from benchmarks.scripts.dicow.common import preflight


class Completed:
    def __init__(self, returncode: int, stdout: str = "", stderr: str = "") -> None:
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


class PreflightTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(dir="/private/tmp")
        self.root = Path(self.temporary.name)
        self.addCleanup(self._cleanup)

    def _cleanup(self) -> None:
        if self.root.exists():
            for parent, directories, files in os.walk(str(self.root), topdown=False):
                for name in files + directories:
                    path = Path(parent) / name
                    if not path.is_symlink():
                        try:
                            os.chmod(str(path), 0o700 if path.is_dir() else 0o600)
                        except FileNotFoundError:
                            pass
            os.chmod(str(self.root), 0o700)
        self.temporary.cleanup()

    def _seal(self, path: Path) -> None:
        if path.is_dir():
            for parent, directories, files in os.walk(str(path), topdown=False):
                for name in files:
                    item = Path(parent) / name
                    if not item.is_symlink():
                        os.chmod(str(item), 0o444)
                for name in directories:
                    item = Path(parent) / name
                    if not item.is_symlink():
                        os.chmod(str(item), 0o555)
            os.chmod(str(path), 0o555)
        else:
            os.chmod(str(path), 0o444)

    def _promotion_fixture(self):
        attempt = self.root / "e0-preflight" / "attempts" / "attempt-a"
        attempt.mkdir(parents=True)
        final_parent = self.root / "final"
        final_parent.mkdir()
        promotions = []
        for index, name in enumerate(("hf", "speech-cache", "speech-runtime", "T9-fragment")):
            staged = attempt / name
            final = final_parent / name
            if index == 3:
                staged.write_text("DICOW_SPEECH_BIN=/private/tmp/speech\n", encoding="utf-8")
            else:
                staged.mkdir()
                (staged / "payload").write_bytes(name.encode("ascii"))
            self._seal(staged)
            promotions.append(
                preflight.Promotion(name, staged, final, preflight.artifact_record(staged, immutable=True))
            )
        canonical = attempt.parent.parent / "canonical.json"
        payload = {"attempt": "attempt-a", "generation": 1}
        return attempt, promotions, canonical, payload

    def test_strict_json_rejects_duplicate_nonfinite_and_symlink(self) -> None:
        duplicate = self.root / "duplicate.json"
        duplicate.write_text('{"a":1,"a":2}\n')
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.strict_load_json(duplicate)
        self.assertEqual("duplicate_json_key", raised.exception.code)

        nonfinite = self.root / "nonfinite.json"
        nonfinite.write_text('{"a":NaN}\n')
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.strict_load_json(nonfinite)
        self.assertEqual("nonfinite_json", raised.exception.code)
        nonfinite.write_text('{"a":[1e999]}\n')
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.strict_load_json(nonfinite)
        self.assertEqual("nonfinite_json", raised.exception.code)

        link = self.root / "link.json"
        link.symlink_to(duplicate.name)
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.strict_load_json(link)
        self.assertEqual("symlink_component", raised.exception.code)

    def test_error_has_machine_readable_branch_semantics(self) -> None:
        error = preflight.PreflightError("drift", "changed")
        self.assertEqual(
            {
                "code": "drift",
                "detail": "changed",
                "evidence_outcome": "evidence_blocker",
                "branch_verdict": "revise",
            },
            error.as_record(),
        )

    def test_stable_read_detects_path_replacement_during_read(self) -> None:
        path = self.root / "value.bin"
        path.write_bytes(b"old")
        real_read = os.read
        called = False

        def racing_read(descriptor, size):
            nonlocal called
            data = real_read(descriptor, size)
            if not called:
                called = True
                replacement = self.root / "replacement.bin"
                replacement.write_bytes(b"new")
                os.replace(str(replacement), str(path))
            return data

        with mock.patch.object(preflight.os, "read", side_effect=racing_read):
            with self.assertRaises(preflight.PreflightError) as raised:
                preflight.stable_read(path)
        self.assertEqual("unstable_read", raised.exception.code)

    def test_stable_read_never_follows_parent_swapped_after_validation(self) -> None:
        parent = self.root / "parent"
        outside = self.root / "outside"
        parent.mkdir()
        outside.mkdir()
        path = parent / "value"
        path.write_bytes(b"inside")
        (outside / "value").write_bytes(b"outside")
        real_open = os.open
        swapped = False

        def racing_open(name, flags, *args, **kwargs):
            nonlocal swapped
            if name == "value" and kwargs.get("dir_fd") is not None and not swapped:
                swapped = True
                parent.rename(self.root / "old-parent")
                parent.symlink_to(outside, target_is_directory=True)
            return real_open(name, flags, *args, **kwargs)

        with mock.patch.object(preflight.os, "open", side_effect=racing_open):
            with self.assertRaises(preflight.PreflightError) as raised:
                preflight.stable_read(path)
        self.assertEqual("symlink_component", raised.exception.code)

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO requires POSIX")
    def test_stable_read_rejects_fifo_without_blocking(self) -> None:
        fifo = self.root / "blocking.fifo"
        os.mkfifo(fifo)
        script = (
            "from pathlib import Path\n"
            "from benchmarks.scripts.dicow.common import preflight\n"
            "try:\n"
            "    preflight.stable_read(Path(__import__('sys').argv[1]), 'fifo')\n"
            "except preflight.PreflightError as error:\n"
            "    print(error.code)\n"
            "else:\n"
            "    raise SystemExit(3)\n"
        )
        completed = subprocess.run(
            [sys.executable, "-c", script, str(fifo)],
            cwd=preflight.REPOSITORY_ROOT,
            capture_output=True,
            text=True,
            timeout=1.0,
            check=False,
        )
        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertEqual("not_regular_file", completed.stdout.strip())

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO requires POSIX")
    def test_stable_read_rejects_regular_file_replaced_by_fifo_before_open(self) -> None:
        path = self.root / "raced.bin"
        path.write_bytes(b"regular")
        real_open = os.open
        replaced = False

        def racing_open(name, flags, *args, **kwargs):
            nonlocal replaced
            if name == path.name and kwargs.get("dir_fd") is not None and not replaced:
                replaced = True
                path.unlink()
                os.mkfifo(path)
            return real_open(name, flags, *args, **kwargs)

        with mock.patch.object(preflight.os, "open", side_effect=racing_open):
            with self.assertRaises(preflight.PreflightError) as raised:
                preflight.stable_read(path, "raced fifo")
        self.assertEqual("not_regular_file", raised.exception.code)

    def test_external_path_rejects_relative_normalized_escape_and_all_symlink_components(self) -> None:
        with self.assertRaises(preflight.PreflightError):
            preflight.validate_external_path(Path("relative"), "relative")
        with self.assertRaises(preflight.PreflightError):
            preflight.validate_external_path(self.root / "a" / ".." / "b", "dotdot", must_exist=False)
        checkout = self.root / "checkout"
        checkout.mkdir()
        (checkout / "README.md").write_text("fixture\n", encoding="utf-8")
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.validate_external_path(checkout / "README.md", "runtime", forbidden_roots=(checkout,))
        self.assertEqual("path_not_external", raised.exception.code)
        real = self.root / "real"
        real.mkdir()
        link = self.root / "parent-link"
        link.symlink_to(real.name)
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.validate_external_path(link / "future" / "file", "nested", must_exist=False)
        self.assertEqual("symlink_component", raised.exception.code)
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.validate_runtime_path(preflight.REPOSITORY_ROOT / "runtime", "runtime", must_exist=False)
        self.assertEqual("path_not_external", raised.exception.code)
        case_alias = Path(str(preflight.REPOSITORY_ROOT).lower()) / "runtime"
        if case_alias.parent.exists():
            with self.assertRaises(preflight.PreflightError) as raised:
                preflight.validate_runtime_path(case_alias, "case alias", must_exist=False)
            self.assertEqual("path_not_external", raised.exception.code)

    def test_tree_manifest_accepts_only_contained_relative_symlinks_and_checks_immutability(self) -> None:
        tree = self.root / "tree"
        (tree / "nested").mkdir(parents=True)
        (tree / "nested" / "payload").write_bytes(b"payload")
        (tree / "alias").symlink_to("nested/payload")
        self._seal(tree)
        manifest = preflight.tree_manifest(tree, immutable=True)
        self.assertEqual(3, manifest["entry_count"])
        self.assertEqual("symlink", [row for row in manifest["entries"] if row["path"] == "alias"][0]["kind"])

        self._cleanup_tree_permissions(tree)
        (tree / "escape").symlink_to("../../outside")
        self._seal(tree)
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.tree_manifest(tree, immutable=True)
        self.assertEqual("unsafe_tree_symlink", raised.exception.code)

    def _cleanup_tree_permissions(self, tree: Path) -> None:
        for parent, directories, files in os.walk(str(tree), topdown=False):
            for name in files + directories:
                item = Path(parent) / name
                if not item.is_symlink():
                    os.chmod(str(item), 0o700 if item.is_dir() else 0o600)
        os.chmod(str(tree), 0o700)

    def test_tree_manifest_rejects_dangling_and_writable_payloads(self) -> None:
        tree = self.root / "tree"
        tree.mkdir()
        (tree / "dangling").symlink_to("missing")
        self._seal(tree)
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.tree_manifest(tree, immutable=True)
        self.assertEqual("dangling_tree_symlink", raised.exception.code)

        self._cleanup_tree_permissions(tree)
        (tree / "dangling").unlink()
        (tree / "payload").write_bytes(b"x")
        os.chmod(str(tree), 0o555)
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.tree_manifest(tree, immutable=True)
        self.assertEqual("mutable_materialization", raised.exception.code)

    def test_tree_manifest_rejects_deletion_after_file_read(self) -> None:
        tree = self.root / "tree"
        tree.mkdir()
        payload = tree / "payload"
        payload.write_bytes(b"payload")
        self._seal(tree)
        original = preflight.stable_read

        def delete_after_read(path, label="file"):
            record = original(path, label)
            tree.chmod(0o755)
            os.unlink(str(path))
            tree.chmod(0o555)
            return record

        with mock.patch.object(preflight, "stable_read", side_effect=delete_after_read):
            with self.assertRaises(preflight.PreflightError) as raised:
                preflight.tree_manifest(tree, immutable=True)
        self.assertEqual("unstable_tree", raised.exception.code)

    def test_tree_manifest_rejects_root_mode_change_before_walk(self) -> None:
        tree = self.root / "tree"
        tree.mkdir()
        (tree / "payload").write_bytes(b"payload")
        self._seal(tree)
        original = os.walk

        def mutate_before_walk(*args, **kwargs):
            tree.chmod(0o755)
            return original(*args, **kwargs)

        with mock.patch.object(preflight.os, "walk", side_effect=mutate_before_walk):
            with self.assertRaises(preflight.PreflightError) as raised:
                preflight.tree_manifest(tree, immutable=True)
        self.assertIn(raised.exception.code, ("mutable_materialization", "unstable_tree"))

    def test_exact_six_conversion_payload_regression(self) -> None:
        record = preflight.conversion_payload_regression()
        self.assertEqual(12_966_174_720, record["total_payload_bytes"])
        self.assertEqual(
            [
                3_235_512_320,
                1_622_743_040,
                1_623_142_400,
                3_236_864_000,
                1_623_418_880,
                1_624_494_080,
            ],
            list(record["payload_bytes"].values()),
        )
        self.assertEqual("conditional", record["dicow_budget_status"])
        self.assertIn("10-tensor CTC omission", record["dicow_budget_note"])

    def test_resource_formula_counts_absent_exact_final_and_peak_stage_in_integer_bytes(self) -> None:
        final = self.root / "final"
        final.mkdir()
        components = (
            preflight.ResourceComponent("source-a", "source", 10, final / "source-a"),
            preflight.ResourceComponent("converted-a", "converted_output", 20, final / "converted-a"),
            preflight.ResourceComponent("env-a", "environment", 30, final / "env-a"),
            preflight.ResourceComponent("golden-a", "named_golden", 40, final / "golden-a"),
            preflight.ResourceComponent("download-a", "staging", 50, final / "download-a", staging_group="download"),
            preflight.ResourceComponent("download-b", "staging", 60, final / "download-b", staging_group="download"),
            preflight.ResourceComponent("convert-a", "staging", 100, final / "convert-a", staging_group="convert"),
        )
        policy = preflight.ResourcePolicy(components, tuple(item.name for item in components))
        fake_fs = {"anchor": str(final), "device": 7, "available_bytes": 10**15, "fragment_size": 4096, "available_blocks": 10**9}
        with mock.patch.object(preflight, "filesystem_free_bytes", return_value=fake_fs):
            result = preflight.calculate_required_free_bytes(policy)
        device = result["filesystems"][0]
        self.assertEqual(100, result["remaining_source_bytes"] + result["converted_outputs_bytes"] + result["remaining_environments_bytes"] + result["named_goldens_bytes"])
        self.assertEqual({"convert": 100, "download": 110}, device["staging_groups"])
        self.assertEqual(110, device["staging_peak_bytes"])
        self.assertEqual(100 + 110 + 2**31, device["required_free_bytes"])

    def test_exact_immutable_final_counts_zero(self) -> None:
        final = self.root / "final.bin"
        final.write_bytes(b"12345")
        self._seal(final)
        expected = preflight.artifact_record(final, immutable=True)
        component = preflight.ResourceComponent("source", "source", 5, final, expected)
        fake_fs = {"anchor": str(self.root), "device": 7, "available_bytes": 10**15, "fragment_size": 4096, "available_blocks": 10**9}
        with mock.patch.object(preflight, "filesystem_free_bytes", return_value=fake_fs):
            result = preflight.calculate_required_free_bytes(preflight.ResourcePolicy((component,), ("source",)))
        self.assertEqual(0, result["components"][0]["remaining_bytes"])
        self.assertEqual("exact_immutable", result["components"][0]["state"])

    def _sealed_venv_fixture(self):
        from benchmarks.scripts.dicow import run_with_env

        environment = self.root / "venv"
        (environment / "bin").mkdir(parents=True)
        (environment / "bin" / "python").write_bytes(b"python")
        record = run_with_env.sealed_path_record(environment, "venv")
        state = self.root / "T2.json"
        state.write_text(json.dumps({
            "schema_version": "dicow-task-state-v1",
            "state": "done",
            "branch_disposition": "executed",
            "task": "T2",
            "run_id": "test-run",
            "sealed_paths": {"DICOW_REFERENCE_VENV": record},
        }, sort_keys=True) + "\n")
        state.chmod(0o444)
        return environment, record, state

    def test_sealed_existing_environment_uses_actual_path_record_and_counts_zero(self) -> None:
        environment, record, state = self._sealed_venv_fixture()
        component = preflight.sealed_venv_component_from_state(
            state, "DICOW_REFERENCE_VENV", "measured_reference_venv",
            expected_task="T2", expected_run_id="test-run",
        )
        self.assertEqual(environment, component.final_path)
        self.assertEqual(record, component.expected_record)
        self.assertEqual(record["bytes"], component.declared_bytes)
        fake_fs = {"anchor": str(self.root), "device": 1, "available_bytes": 10**15, "fragment_size": 1, "available_blocks": 10**15}
        with mock.patch.object(preflight, "filesystem_free_bytes", return_value=fake_fs):
            result = preflight.calculate_required_free_bytes(
                preflight.ResourcePolicy((component,), (component.name,))
            )
        self.assertEqual(0, result["remaining_environments_bytes"])
        self.assertEqual("exact_immutable", result["components"][0]["state"])

    def test_absent_sealed_environment_counts_real_declared_bytes_without_zero_shortcut(self) -> None:
        environment, record, state = self._sealed_venv_fixture()
        component = preflight.sealed_venv_component_from_state(
            state, "DICOW_REFERENCE_VENV", "measured_reference_venv",
            expected_task="T2", expected_run_id="test-run",
        )
        environment.rename(self.root / "venv-preserved")
        fake_fs = {"anchor": str(self.root), "device": 1, "available_bytes": 10**15, "fragment_size": 1, "available_blocks": 10**15}
        with mock.patch.object(preflight, "filesystem_free_bytes", return_value=fake_fs):
            result = preflight.calculate_required_free_bytes(
                preflight.ResourcePolicy((component,), (component.name,))
            )
        self.assertEqual(record["bytes"], result["remaining_environments_bytes"])
        self.assertGreater(result["remaining_environments_bytes"], 0)
        self.assertEqual("absent", result["components"][0]["state"])

    def test_drifted_sealed_environment_is_an_evidence_blocker(self) -> None:
        environment, _, state = self._sealed_venv_fixture()
        component = preflight.sealed_venv_component_from_state(
            state, "DICOW_REFERENCE_VENV", "measured_reference_venv",
            expected_task="T2", expected_run_id="test-run",
        )
        (environment / "bin" / "python").write_bytes(b"drift")
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.calculate_required_free_bytes(
                preflight.ResourcePolicy((component,), (component.name,))
            )
        self.assertEqual("resource_materialization_mismatch", raised.exception.code)
        self.assertEqual("evidence_blocker", raised.exception.evidence_outcome)

    def test_sealed_environment_state_cannot_redirect_or_change_declared_bytes(self) -> None:
        _, _, state = self._sealed_venv_fixture()
        state.chmod(0o644)
        value = json.loads(state.read_text())
        value["sealed_paths"]["DICOW_REFERENCE_VENV"]["bytes"] = 0
        state.write_text(json.dumps(value) + "\n")
        state.chmod(0o444)
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.sealed_venv_component_from_state(
                state, "DICOW_REFERENCE_VENV", "measured_reference_venv",
                expected_task="T2", expected_run_id="test-run",
            )
        self.assertEqual("resource_formula_unresolved", raised.exception.code)

    def test_sealed_environment_state_is_bound_to_task_and_run_provenance(self) -> None:
        _, _, state = self._sealed_venv_fixture()
        for task, run_id in (("T1", "test-run"), ("T2", "other-run")):
            with self.subTest(task=task, run_id=run_id):
                with self.assertRaises(preflight.PreflightError) as raised:
                    preflight.sealed_venv_component_from_state(
                        state, "DICOW_REFERENCE_VENV", "measured_reference_venv",
                        expected_task=task, expected_run_id=run_id,
                    )
                self.assertEqual("resource_formula_unresolved", raised.exception.code)

    def _resource_ledger_v2_fixture(self):
        environment, environment_record, _ = self._sealed_venv_fixture()
        request_universe = self.root / "control-requests.json"
        request_universe.write_text(json.dumps({
            "schema_version": "dicow-golden-request-universe-v1",
            "golden_name": "control_named_goldens",
            "request_ids": ["r1", "r2"],
        }, sort_keys=True) + "\n")
        request_universe.chmod(0o444)
        serializer_layout = self.root / "control-layout.json"
        serializer_layout.write_text(json.dumps({
            "schema_version": "dicow-golden-serializer-layout-v1",
            "golden_name": "control_named_goldens",
            "max_attempts": 2,
            "successful_attempt": {
                "requests": [
                    {"request_id": "r1", "tensors": [{"name": "mel", "dtype": "float32", "shape": [2, 3]}], "json_caps": [{"name": "tokens", "max_utf8_bytes": 10}]},
                    {"request_id": "r2", "tensors": [{"name": "ids", "dtype": "int64", "shape": [2]}], "json_caps": [{"name": "segments", "max_utf8_bytes": 11}]},
                ],
                "json_caps": [{"name": "attempt-index", "max_utf8_bytes": 12}],
            },
            "failed_attempt": {
                "requests": [
                    {"request_id": "r1", "tensors": [{"name": "partial-mel", "dtype": "uint8", "shape": [5]}], "json_caps": [{"name": "failure", "max_utf8_bytes": 6}]},
                    {"request_id": "r2", "tensors": [{"name": "partial-ids", "dtype": "bool", "shape": [1]}], "json_caps": [{"name": "failure", "max_utf8_bytes": 7}]},
                ],
                "json_caps": [{"name": "attempt-failure", "max_utf8_bytes": 8}],
            },
            "root_metadata": [{"name": "canonical-selector", "max_utf8_bytes": 9}],
        }, sort_keys=True) + "\n")
        serializer_layout.chmod(0o444)
        request_record = preflight.file_record(request_universe, immutable=True)
        layout_record = preflight.file_record(serializer_layout, immutable=True)
        golden_derivation = {
            "kind": "golden_authority_layout_v1",
            "request_universe_record": request_record,
            "serializer_layout_record": layout_record,
            "max_attempts": 2,
            "successful_attempt_max": 73,
            "failed_attempt_max": 27,
            "root_metadata_max": 9,
            "bytes": 109,
        }
        producer_state = self.root / "T8R.json"
        producer_state.write_text(json.dumps({
            "schema_version": "dicow-task-state-v1",
            "state": "done",
            "branch_disposition": "executed",
            "task": "T8R",
            "run_id": "test-run",
            "sealed_paths": {"MLX_ENVIRONMENT": environment_record},
            "resource_authorities": {
                "control_named_goldens": {
                    "request_universe_record": request_record,
                    "serializer_layout_record": layout_record,
                },
            },
            "golden_derivations": {"control": golden_derivation},
        }, sort_keys=True) + "\n")
        producer_state.chmod(0o444)
        producer_record = preflight.file_record(producer_state, immutable=True)
        ledger = {
            "schema_version": "dicow-e0-future-resource-ledger-v2",
            "components": [
                {
                    "name": "mlx_environment",
                    "category": "environment",
                    "final_path": str(environment),
                    "expected_record": environment_record,
                    "staging_group": None,
                    "record_kind": "sealed_venv",
                    "provenance": {
                        "path": str(producer_state),
                        "record": producer_record,
                        "json_pointer": ["sealed_paths", "MLX_ENVIRONMENT"],
                    },
                    "derivation": {"kind": "sealed_path_bytes", "bytes": environment_record["bytes"]},
                },
                {
                    "name": "control_named_goldens",
                    "category": "named_golden",
                    "final_path": str(self.root / "future-control-goldens"),
                    "expected_record": None,
                    "staging_group": None,
                    "record_kind": "immutable_artifact",
                    "provenance": {
                        "path": str(producer_state),
                        "record": producer_record,
                        "json_pointer": ["golden_derivations", "control"],
                    },
                    "derivation": golden_derivation,
                },
            ],
        }
        required = {"mlx_environment": "environment", "control_named_goldens": "named_golden"}
        ledger_path = self.root / "resource-ledger.json"
        ledger_path.write_text(json.dumps(ledger, sort_keys=True) + "\n")
        ledger_path.chmod(0o444)
        arguments = {
            "expected_ledger_record": preflight.file_record(ledger_path, immutable=True),
            "required_names": required,
            "expected_final_paths": {
                "mlx_environment": environment,
                "control_named_goldens": self.root / "future-control-goldens",
            },
            "expected_task": "T8R",
            "expected_run_id": "test-run",
            "expected_provenance_path": producer_state,
        }
        return ledger_path, arguments

    def test_resource_ledger_v2_refuses_r1_named_golden_authority(self) -> None:
        ledger_path, arguments = self._resource_ledger_v2_fixture()
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.parse_resource_ledger_v2(ledger_path, **arguments)
        self.assertEqual("resource_formula_unresolved", raised.exception.code)

    def test_resource_ledger_v2_replays_provenance_for_environment_only(self) -> None:
        ledger_path, arguments = self._resource_ledger_v2_fixture()
        ledger = json.loads(ledger_path.read_text())
        ledger["components"] = [ledger["components"][0]]
        environment_ledger = self.root / "environment-ledger.json"
        environment_ledger.write_text(json.dumps(ledger, sort_keys=True) + "\n")
        environment_ledger.chmod(0o444)
        environment_arguments = dict(arguments)
        environment_arguments["expected_ledger_record"] = preflight.file_record(environment_ledger, immutable=True)
        environment_arguments["required_names"] = {"mlx_environment": "environment"}
        environment_arguments["expected_final_paths"] = {
            "mlx_environment": arguments["expected_final_paths"]["mlx_environment"],
        }
        components = preflight.parse_resource_ledger_v2(environment_ledger, **environment_arguments)
        self.assertEqual(1, len(components))
        self.assertEqual("sealed_venv", components[0].record_kind)
        fake_fs = {"anchor": str(self.root), "device": 1, "available_bytes": 10**15, "fragment_size": 1, "available_blocks": 10**15}
        with mock.patch.object(preflight, "filesystem_free_bytes", return_value=fake_fs):
            result = preflight.calculate_required_free_bytes(
                preflight.ResourcePolicy(components, ("mlx_environment",))
            )
        self.assertEqual(0, result["remaining_environments_bytes"])

    def test_resource_ledger_v2_rejects_self_asserted_bytes_provenance_and_golden_math(self) -> None:
        ledger_path, arguments = self._resource_ledger_v2_fixture()
        ledger = json.loads(ledger_path.read_text())
        mutations = []
        added_declared = json.loads(json.dumps(ledger))
        added_declared["components"][0]["declared_bytes"] = 0
        mutations.append(added_declared)
        forged_provenance = json.loads(json.dumps(ledger))
        forged_provenance["components"][0]["provenance"]["record"]["sha256"] = "0" * 64
        mutations.append(forged_provenance)
        forged_expected = json.loads(json.dumps(ledger))
        forged_expected["components"][0]["expected_record"]["bytes"] = 0
        mutations.append(forged_expected)
        false_golden = json.loads(json.dumps(ledger))
        false_golden["components"][1]["derivation"]["bytes"] = 1
        mutations.append(false_golden)
        claimed_existing = json.loads(json.dumps(ledger))
        claimed_existing["components"][1]["expected_record"] = {"kind": "file", "bytes": 1, "mode": "0444", "sha256": "0" * 64}
        mutations.append(claimed_existing)
        for index, mutation in enumerate(mutations):
            with self.subTest(mutation=mutation):
                mutation_path = self.root / "mutation-{}.json".format(index)
                mutation_path.write_text(json.dumps(mutation, sort_keys=True) + "\n")
                mutation_path.chmod(0o444)
                mutation_arguments = dict(arguments)
                mutation_arguments["expected_ledger_record"] = preflight.file_record(mutation_path, immutable=True)
                with self.assertRaises(preflight.PreflightError) as raised:
                    preflight.parse_resource_ledger_v2(
                        mutation_path,
                        **mutation_arguments,
                    )
                self.assertEqual("resource_formula_unresolved", raised.exception.code)

    def test_resource_ledger_v2_cannot_redirect_or_forge_producer_identity(self) -> None:
        ledger_path, base_arguments = self._resource_ledger_v2_fixture()
        ledger = json.loads(ledger_path.read_text())
        producer_state = base_arguments["expected_provenance_path"]
        redirected = self.root / "forged-T8R.json"
        redirected.write_bytes(producer_state.read_bytes())
        redirected.chmod(0o444)
        redirected_record = preflight.file_record(redirected, immutable=True)
        for row in ledger["components"]:
            row["provenance"] = dict(row["provenance"])
            row["provenance"]["path"] = str(redirected)
            row["provenance"]["record"] = redirected_record
        redirected_ledger = self.root / "redirected-ledger.json"
        redirected_ledger.write_text(json.dumps(ledger, sort_keys=True) + "\n")
        redirected_ledger.chmod(0o444)
        cases = (
            {"expected_task": "T8R", "expected_run_id": "test-run", "expected_provenance_path": producer_state},
            {"expected_task": "T9", "expected_run_id": "test-run", "expected_provenance_path": redirected},
            {"expected_task": "T8R", "expected_run_id": "other-run", "expected_provenance_path": redirected},
        )
        for overrides in cases:
            with self.subTest(overrides=overrides):
                arguments = dict(base_arguments)
                arguments.update(overrides)
                arguments["expected_ledger_record"] = preflight.file_record(redirected_ledger, immutable=True)
                with self.assertRaises(preflight.PreflightError) as raised:
                    preflight.parse_resource_ledger_v2(
                        redirected_ledger,
                        **arguments,
                    )
                self.assertEqual("resource_formula_unresolved", raised.exception.code)

    def test_resource_ledger_v1_is_not_accepted_as_v2(self) -> None:
        ledger_path = self.root / "v1-ledger.json"
        ledger_path.write_text(json.dumps({"schema_version": "dicow-e0-future-resource-ledger-v1", "components": []}) + "\n")
        ledger_path.chmod(0o444)
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.parse_resource_ledger_v2(
                ledger_path,
                expected_ledger_record=preflight.file_record(ledger_path, immutable=True),
                required_names={},
                expected_final_paths={},
                expected_task="T8R",
                expected_run_id="test-run",
                expected_provenance_path=self.root / "absent-T8R.json",
            )
        self.assertEqual("resource_formula_unresolved", raised.exception.code)

    def test_r1_rejects_arbitrary_small_or_hash_only_golden_authority(self) -> None:
        ledger_path, arguments = self._resource_ledger_v2_fixture()
        ledger = json.loads(ledger_path.read_text())
        candidates = (
            {"kind": "golden_authority_layout_v1", "bytes": 1, "max_attempts": 2},
            {
                "kind": "tracked_golden_calculator_v1",
                "calculator_sha256": "0" * 64,
                "serializer_sha256": "1" * 64,
                "bytes": 1,
            },
        )
        for index, derivation in enumerate(candidates):
            mutated = json.loads(json.dumps(ledger))
            mutated["components"][1]["derivation"] = derivation
            producer_path = arguments["expected_provenance_path"]
            producer = json.loads(producer_path.read_text())
            producer["golden_derivations"]["control"] = derivation
            producer_path.chmod(0o644)
            producer_path.write_text(json.dumps(producer, sort_keys=True) + "\n")
            producer_path.chmod(0o444)
            producer_record = preflight.file_record(producer_path, immutable=True)
            for row in mutated["components"]:
                row["provenance"]["record"] = producer_record
            candidate_path = self.root / "candidate-ledger-{}.json".format(index)
            candidate_path.write_text(json.dumps(mutated, sort_keys=True) + "\n")
            candidate_path.chmod(0o444)
            with self.assertRaises(preflight.PreflightError) as raised:
                preflight.parse_resource_ledger_v2(
                    candidate_path,
                    **{
                        **arguments,
                        "expected_ledger_record": preflight.file_record(candidate_path, immutable=True),
                    },
                )
            self.assertEqual("resource_formula_unresolved", raised.exception.code)

    def test_resource_ledger_v2_rejects_mutable_or_changed_ledger_and_existing_golden(self) -> None:
        ledger_path, arguments = self._resource_ledger_v2_fixture()
        ledger_path.chmod(0o644)
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.parse_resource_ledger_v2(ledger_path, **arguments)
        self.assertEqual("mutable_materialization", raised.exception.code)
        ledger_path.chmod(0o444)

        existing = arguments["expected_final_paths"]["control_named_goldens"]
        existing.write_bytes(b"x")
        existing.chmod(0o444)
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.parse_resource_ledger_v2(ledger_path, **arguments)
        self.assertEqual("resource_formula_unresolved", raised.exception.code)
        existing.unlink()

        original_record = arguments["expected_ledger_record"]
        ledger_path.chmod(0o644)
        ledger_path.write_bytes(ledger_path.read_bytes() + b" \n")
        ledger_path.chmod(0o444)
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.parse_resource_ledger_v2(
                ledger_path,
                **{**arguments, "expected_ledger_record": original_record},
            )
        self.assertEqual("resource_formula_unresolved", raised.exception.code)

    def test_partial_mismatch_mutability_and_symlink_fail_closed(self) -> None:
        final = self.root / "final.bin"
        final.write_bytes(b"partial")
        expected = {"kind": "file", "bytes": 4, "mode": "0444", "sha256": "0" * 64}
        component = preflight.ResourceComponent("source", "source", 4, final, expected)
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.calculate_required_free_bytes(preflight.ResourcePolicy((component,), ("source",)))
        self.assertEqual("mutable_materialization", raised.exception.code)
        self._seal(final)
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.calculate_required_free_bytes(preflight.ResourcePolicy((component,), ("source",)))
        self.assertEqual("resource_materialization_mismatch", raised.exception.code)

        final.unlink()
        target = self.root / "target.bin"
        target.write_bytes(b"data")
        final.symlink_to(target.name)
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.calculate_required_free_bytes(preflight.ResourcePolicy((component,), ("source",)))
        self.assertEqual("symlink_component", raised.exception.code)

    def test_formula_refuses_missing_duplicate_extra_unknown_or_unresolved_components(self) -> None:
        path = self.root / "absent"
        valid = preflight.ResourceComponent("one", "source", 1, path)
        cases = (
            preflight.ResourcePolicy((valid,), ("one", "two")),
            preflight.ResourcePolicy((valid, valid), ("one",)),
            preflight.ResourcePolicy((preflight.ResourceComponent("one", "unknown", 1, path),), ("one",)),
            preflight.ResourcePolicy((preflight.ResourceComponent("one", "source", -1, path),), ("one",)),
        )
        for policy in cases:
            with self.subTest(policy=policy):
                with self.assertRaises(preflight.PreflightError) as raised:
                    preflight.calculate_required_free_bytes(policy)
                self.assertEqual("resource_formula_unresolved", raised.exception.code)

    def test_statvfs_is_compared_per_filesystem_and_insufficient_is_typed(self) -> None:
        paths = (self.root / "a", self.root / "b")
        components = (
            preflight.ResourceComponent("a", "source", 10, paths[0]),
            preflight.ResourceComponent("b", "environment", 20, paths[1]),
        )

        def fake_fs(path):
            index = paths.index(path)
            return {"anchor": str(self.root), "device": index + 1, "available_bytes": 2**31 + (100 if index == 0 else 10), "fragment_size": 4096, "available_blocks": 1}

        with mock.patch.object(preflight, "filesystem_free_bytes", side_effect=fake_fs):
            with self.assertRaises(preflight.PreflightError) as raised:
                preflight.calculate_required_free_bytes(preflight.ResourcePolicy(components, ("a", "b")))
        self.assertEqual("insufficient_free_space", raised.exception.code)
        self.assertIn('"device":2', raised.exception.detail)

    def test_headroom_boundary_minus_exact_plus_one(self) -> None:
        component = preflight.ResourceComponent("a", "source", 1, self.root / "a")
        policy = preflight.ResourcePolicy((component,), ("a",))
        for available, passes in ((2**31, False), (2**31 + 1, True), (2**31 + 2, True)):
            fake = {"anchor": str(self.root), "device": 1, "available_bytes": available, "fragment_size": 1, "available_blocks": available}
            with self.subTest(available=available), mock.patch.object(preflight, "filesystem_free_bytes", return_value=fake):
                if passes:
                    self.assertTrue(preflight.calculate_required_free_bytes(policy)["sufficient"])
                else:
                    with self.assertRaises(preflight.PreflightError) as raised:
                        preflight.calculate_required_free_bytes(policy)
                    self.assertEqual("insufficient_free_space", raised.exception.code)

    def test_sequential_process_lock_rejects_concurrent_holder_and_verify_mode_does_not_create(self) -> None:
        lock = self.root / "e0.lock"
        with preflight.SequentialProcessLock(lock, create=True, anchor=self.root):
            with self.assertRaises(preflight.PreflightError) as raised:
                with preflight.SequentialProcessLock(lock, create=False, anchor=self.root):
                    pass
            self.assertEqual("sequential_process_lock_busy", raised.exception.code)
        missing = self.root / "missing.lock"
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.SequentialProcessLock(missing, create=False, anchor=self.root)
        self.assertEqual("missing_path", raised.exception.code)
        self.assertFalse(missing.exists())

    def test_lock_path_replacement_cannot_bypass_parent_lock(self) -> None:
        lock = self.root / "e0.lock"
        with preflight.SequentialProcessLock(lock, create=True, anchor=self.root):
            replaced = self.root / "old.lock"
            os.rename(str(lock), str(replaced))
            lock.write_bytes(b"replacement")
            with self.assertRaises(preflight.PreflightError) as raised:
                with preflight.SequentialProcessLock(lock, create=False, anchor=self.root):
                    pass
            self.assertEqual("sequential_process_lock_busy", raised.exception.code)

    def test_lock_parent_replacement_cannot_bypass_explicit_stable_anchor(self) -> None:
        parent = self.root / "e0-preflight"
        parent.mkdir()
        lock = parent / "e0.lock"
        with preflight.SequentialProcessLock(lock, create=True, anchor=self.root):
            parent.rename(self.root / "old-e0-preflight")
            parent.mkdir()
            (parent / "e0.lock").write_bytes(b"replacement")
            with self.assertRaises(preflight.PreflightError) as raised:
                with preflight.SequentialProcessLock(parent / "e0.lock", create=False, anchor=self.root):
                    pass
            self.assertEqual("sequential_process_lock_busy", raised.exception.code)

    def test_deny_network_requires_static_rules_and_two_failed_socket_probes(self) -> None:
        profile = self.root / "deny.sb"
        profile.write_text("(version 1)\n(allow default)\n(deny network*)\n")
        executable = self.root / "sandbox-exec"
        executable.write_text("#!/bin/sh\nexit 1\n")
        executable.chmod(0o755)
        def denied(command, **kwargs):
            code = command[-1]
            name = next(name for name in ("inet_datagram_connect", "inet_stream_bind") if name in code)
            return Completed(73, "DICOW_NETWORK_DENIED_V1:{}\n".format(name), "")

        runner = mock.Mock(side_effect=denied)
        record = preflight.verify_deny_network(profile, sandbox_exec=executable, runner=runner)
        self.assertEqual(["inet_datagram_connect", "inet_stream_bind"], [row["name"] for row in record["socket_probes"]])
        self.assertEqual(2, runner.call_count)

        profile.write_text("(version 1)\n(deny default)\n(allow network*)\n(deny network*)\n")
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.verify_deny_network(profile, sandbox_exec=executable, runner=runner)
        self.assertEqual("invalid_sandbox_profile", raised.exception.code)
        profile.write_text(
            '(version 1)\n(allow default)\n(deny network*)\n(allow\n network-outbound (remote ip "8.8.8.8:53"))\n'
        )
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.verify_deny_network(profile, sandbox_exec=executable, runner=runner)
        self.assertEqual("invalid_sandbox_profile", raised.exception.code)

    def test_deny_network_does_not_mistake_arbitrary_child_failure_for_denial(self) -> None:
        profile = self.root / "deny.sb"
        profile.write_text("(version 1)\n(allow default)\n(deny network*)\n")
        executable = self.root / "sandbox-exec"
        executable.write_text("#!/bin/sh\nexit 2\n")
        executable.chmod(0o755)
        result = Completed(2, "", "python executable is broken")
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.verify_deny_network(profile, sandbox_exec=executable, runner=mock.Mock(return_value=result))
        self.assertEqual("sandbox_network_probe_invalid", raised.exception.code)

    def test_deny_network_rejects_successful_probe(self) -> None:
        profile = self.root / "deny.sb"
        profile.write_text("(version 1)\n(deny default)\n(deny network*)\n")
        executable = self.root / "sandbox-exec"
        executable.write_text("#!/bin/sh\nexit 0\n")
        executable.chmod(0o755)
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.verify_deny_network(profile, sandbox_exec=executable, runner=mock.Mock(return_value=Completed(0)))
        self.assertEqual("sandbox_network_probe_escaped", raised.exception.code)

    def test_four_object_promotion_is_create_only_durable_and_verify_only_is_idempotent(self) -> None:
        attempt, promotions, canonical, payload = self._promotion_fixture()
        result = preflight.promote_create_only(attempt, promotions, canonical, payload)
        self.assertEqual("complete", result["status"])
        self.assertEqual([item.name for item in promotions], result["promoted"])
        self.assertTrue(canonical.exists())
        self.assertEqual(0, stat.S_IMODE(canonical.stat().st_mode) & 0o222)
        journal = attempt / "partial_materialization.json"
        self.assertEqual(0, stat.S_IMODE(journal.stat().st_mode) & 0o222)

        observed_before = self._path_observation([canonical, journal] + [item.final_path for item in promotions])
        self.assertEqual("complete", preflight.verify_promotion(attempt, promotions, canonical, payload)["status"])
        self.assertEqual("complete", preflight.verify_promotion(attempt, promotions, canonical, payload)["status"])
        self.assertEqual(observed_before, self._path_observation([canonical, journal] + [item.final_path for item in promotions]))

    def _path_observation(self, paths):
        result = []
        for path in paths:
            info = os.lstat(str(path))
            record = preflight.artifact_record(path, immutable=True)
            result.append((str(path), info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, stat.S_IMODE(info.st_mode), record))
        return result

    def test_promotion_refuses_preexisting_final_without_overwrite(self) -> None:
        attempt, promotions, canonical, payload = self._promotion_fixture()
        promotions[1].final_path.write_text("owner data")
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.promote_create_only(attempt, promotions, canonical, payload)
        self.assertEqual("preexisting_final", raised.exception.code)
        self.assertEqual("owner data", promotions[1].final_path.read_text())
        self.assertFalse((attempt / "partial_materialization.json").exists())

    def test_mid_promotion_failure_rolls_back_only_matching_tuples_in_reverse(self) -> None:
        attempt, promotions, canonical, payload = self._promotion_fixture()
        original = preflight._rename_exclusive
        order = []

        def fail_second(source, destination):
            order.append((Path(source).name, Path(destination).name))
            if len(order) == 2:
                raise OSError("injected")
            return original(source, destination)

        with mock.patch.object(preflight, "_rename_exclusive", side_effect=fail_second):
            with self.assertRaises(preflight.PreflightError) as raised:
                preflight.promote_create_only(attempt, promotions, canonical, payload)
        self.assertEqual("partial_materialization", raised.exception.code)
        self.assertTrue(all(item.staged_path.exists() for item in promotions))
        self.assertTrue(all(not item.final_path.exists() for item in promotions))
        self.assertFalse(canonical.exists())
        journal = preflight.strict_load_json(attempt / "partial_materialization.json")
        self.assertEqual("rolled_back", journal["status"])

    def test_canonical_write_failure_rolls_back_all_four_objects(self) -> None:
        attempt, promotions, canonical, payload = self._promotion_fixture()
        original = preflight._create_only_json

        def fail_canonical(path, value, mode=0o444):
            if Path(path).name == ".canonical-selector.json":
                raise OSError("injected canonical failure")
            return original(path, value, mode)

        with mock.patch.object(preflight, "_create_only_json", side_effect=fail_canonical):
            with self.assertRaises(preflight.PreflightError) as raised:
                preflight.promote_create_only(attempt, promotions, canonical, payload)
        self.assertEqual("partial_materialization", raised.exception.code)
        self.assertTrue(all(item.staged_path.exists() for item in promotions))
        self.assertTrue(all(not item.final_path.exists() for item in promotions))
        self.assertFalse(canonical.exists())
        self.assertEqual("rolled_back", preflight.strict_load_json(attempt / "partial_materialization.json")["status"])

    def test_partial_create_only_write_removes_only_its_own_incomplete_file(self) -> None:
        output = self.root / "partial.json"
        real_write = os.write
        calls = 0

        def partial_then_fail(descriptor, data):
            nonlocal calls
            calls += 1
            if calls == 1:
                real_write(descriptor, data[:1])
                raise OSError("injected short write")
            return real_write(descriptor, data)

        with mock.patch.object(preflight.os, "write", side_effect=partial_then_fail):
            with self.assertRaises(OSError):
                preflight._create_only_json(output, {"value": 1})
        self.assertFalse(output.exists())

    def test_post_rename_fsync_failure_rolls_back_first_move(self) -> None:
        attempt, promotions, canonical, payload = self._promotion_fixture()
        original = preflight._fsync_artifact
        calls = 0

        def fail_first(path):
            nonlocal calls
            calls += 1
            if calls == 1:
                raise OSError("injected fsync failure")
            return original(path)

        with mock.patch.object(preflight, "_fsync_artifact", side_effect=fail_first):
            with self.assertRaises(preflight.PreflightError) as raised:
                preflight.promote_create_only(attempt, promotions, canonical, payload)
        self.assertEqual("partial_materialization", raised.exception.code)
        self.assertTrue(all(item.staged_path.exists() for item in promotions))
        self.assertTrue(all(not item.final_path.exists() for item in promotions))
        self.assertEqual("rolled_back", preflight.strict_load_json(attempt / "partial_materialization.json")["status"])

    def test_mutation_between_precheck_and_rename_never_reaches_canonical(self) -> None:
        attempt, promotions, canonical, payload = self._promotion_fixture()
        original = preflight._rename_exclusive
        mutated = False

        def mutate_then_rename(source, destination):
            nonlocal mutated
            if not mutated and Path(source) == promotions[0].staged_path:
                mutated = True
                file = Path(source) / "payload"
                file.chmod(0o644)
                file.write_bytes(b"changed")
                file.chmod(0o444)
            return original(source, destination)

        with mock.patch.object(preflight, "_rename_exclusive", side_effect=mutate_then_rename):
            with self.assertRaises(preflight.PreflightError) as raised:
                preflight.promote_create_only(attempt, promotions, canonical, payload)
        self.assertEqual("unresolved_partial_materialization", raised.exception.code)
        self.assertFalse(canonical.exists())
        self.assertEqual("unresolved", preflight.strict_load_json(attempt / "partial_materialization.json")["status"])

    def test_mutation_during_final_fsync_is_caught_before_canonical(self) -> None:
        attempt, promotions, canonical, payload = self._promotion_fixture()
        original = preflight._fsync_artifact
        mutated = False

        def mutate_during_fsync(path):
            nonlocal mutated
            if Path(path) == promotions[0].final_path and not mutated:
                mutated = True
                file = Path(path) / "payload"
                file.chmod(0o644)
                file.write_bytes(b"fsync-race")
                file.chmod(0o444)
            return original(path)

        with mock.patch.object(preflight, "_fsync_artifact", side_effect=mutate_during_fsync):
            with self.assertRaises(preflight.PreflightError) as raised:
                preflight.promote_create_only(attempt, promotions, canonical, payload)
        self.assertEqual("unresolved_partial_materialization", raised.exception.code)
        self.assertFalse(canonical.exists())

    def test_mutation_during_rollback_fsync_cannot_report_rolled_back(self) -> None:
        attempt, promotions, canonical, payload = self._promotion_fixture()
        original_rename = preflight._rename_exclusive
        original_fsync = preflight._fsync_artifact
        rename_calls = 0
        mutated = False

        def fail_second_rename(source, destination):
            nonlocal rename_calls
            rename_calls += 1
            if rename_calls == 2:
                raise OSError("start rollback")
            return original_rename(source, destination)

        def mutate_recovered(path):
            nonlocal mutated
            if Path(path) == promotions[0].staged_path and not mutated:
                mutated = True
                file = Path(path) / "payload"
                file.chmod(0o644)
                file.write_bytes(b"rollback-race")
                file.chmod(0o444)
            return original_fsync(path)

        with mock.patch.object(preflight, "_rename_exclusive", side_effect=fail_second_rename), mock.patch.object(
            preflight, "_fsync_artifact", side_effect=mutate_recovered
        ):
            with self.assertRaises(preflight.PreflightError) as raised:
                preflight.promote_create_only(attempt, promotions, canonical, payload)
        self.assertEqual("unresolved_partial_materialization", raised.exception.code)
        self.assertEqual("unresolved", preflight.strict_load_json(attempt / "partial_materialization.json")["status"])

    def test_promotion_rejects_duplicate_or_nested_paths_before_journaling(self) -> None:
        attempt, promotions, canonical, payload = self._promotion_fixture()
        duplicate = list(promotions)
        duplicate[1] = preflight.Promotion(
            duplicate[1].name,
            duplicate[1].staged_path,
            duplicate[0].final_path,
            duplicate[1].expected_record,
        )
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.promote_create_only(attempt, duplicate, canonical, payload)
        self.assertEqual("invalid_promotion", raised.exception.code)
        self.assertFalse((attempt / "partial_materialization.json").exists())

    def test_changed_promoted_tuple_leaves_unresolved_partial_and_refuses_retry(self) -> None:
        attempt, promotions, canonical, payload = self._promotion_fixture()
        original = preflight._rename_exclusive
        calls = 0

        def tamper_then_fail(source, destination):
            nonlocal calls
            calls += 1
            if calls == 2:
                first = promotions[0].final_path / "payload"
                first.chmod(0o644)
                first.write_bytes(b"changed")
                first.chmod(0o444)
                raise OSError("injected")
            return original(source, destination)

        with mock.patch.object(preflight, "_rename_exclusive", side_effect=tamper_then_fail):
            with self.assertRaises(preflight.PreflightError) as raised:
                preflight.promote_create_only(attempt, promotions, canonical, payload)
        self.assertEqual("unresolved_partial_materialization", raised.exception.code)
        self.assertTrue(promotions[0].final_path.exists())
        journal = preflight.strict_load_json(attempt / "partial_materialization.json")
        self.assertEqual("unresolved", journal["status"])
        with self.assertRaises(preflight.PreflightError) as retry:
            preflight.promote_create_only(attempt, promotions, canonical, payload)
        self.assertEqual("unresolved_partial_materialization", retry.exception.code)

    def test_rollback_rechecks_tuple_after_rename_and_moves_raced_bytes_back_to_final(self) -> None:
        attempt, promotions, canonical, payload = self._promotion_fixture()
        original = preflight._rename_exclusive
        calls = 0

        def race_rollback(source, destination):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise OSError("start rollback")
            if calls == 3:
                payload_file = Path(source) / "payload"
                payload_file.chmod(0o644)
                payload_file.write_bytes(b"attacker")
                payload_file.chmod(0o444)
            return original(source, destination)

        with mock.patch.object(preflight, "_rename_exclusive", side_effect=race_rollback):
            with self.assertRaises(preflight.PreflightError) as raised:
                preflight.promote_create_only(attempt, promotions, canonical, payload)
        self.assertEqual("unresolved_partial_materialization", raised.exception.code)
        self.assertTrue(promotions[0].final_path.exists())
        self.assertFalse(promotions[0].staged_path.exists())
        self.assertEqual("attacker", (promotions[0].final_path / "payload").read_text())

    def test_atomic_no_replace_rename_rejects_raced_destination(self) -> None:
        source = self.root / "source"
        destination = self.root / "destination"
        source.write_text("source")
        destination.write_text("owner")
        with self.assertRaises(OSError):
            preflight._rename_exclusive(source, destination)
        self.assertEqual("source", source.read_text())
        self.assertEqual("owner", destination.read_text())

    def test_verify_refuses_forged_or_mutable_journal_and_never_repairs(self) -> None:
        attempt, promotions, canonical, payload = self._promotion_fixture()
        preflight.promote_create_only(attempt, promotions, canonical, payload)
        journal = attempt / "partial_materialization.json"
        journal.chmod(0o644)
        before = journal.read_bytes()
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.verify_promotion(attempt, promotions, canonical, payload)
        self.assertEqual("promotion_verification_failed", raised.exception.code)
        self.assertEqual(before, journal.read_bytes())

    def test_verify_uses_exact_json_types_and_bytes(self) -> None:
        attempt, promotions, canonical, payload = self._promotion_fixture()
        preflight.promote_create_only(attempt, promotions, canonical, payload)
        canonical.chmod(0o644)
        canonical.write_text('{"attempt":"attempt-a","generation":true}\n')
        canonical.chmod(0o444)
        before = canonical.read_bytes()
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.verify_promotion(attempt, promotions, canonical, payload)
        self.assertEqual("promotion_verification_failed", raised.exception.code)
        self.assertEqual(before, canonical.read_bytes())


class R2PreflightTests(unittest.TestCase):
    def resource_source(self):
        return {
            "candidate": "fixture",
            "model_id": "example/fixture",
            "revision": "a" * 40,
            "model_file_bytes": 1_000_000,
            "model_file_lfs_sha256": "b" * 64,
            "header_record": {"bytes": 1_000, "sha256": "c" * 64},
            "lfs_record": {"bytes": 2_000, "sha256": "d" * 64},
        }

    def resource_bound(self, extractor):
        expected = {
            "sum_model_file_bytes_upper_bound_v1": (1_000_000, "upper_bound"),
            "sum_safetensors_header_bytes_exact_v1": (1_000, "exact"),
            "zero_by_phase_contract_v1": (0, "exact"),
        }[extractor]
        return {
            "state": "source_derived",
            "bytes": expected[0],
            "bound_kind": expected[1],
            "extractor_id": extractor,
        }

    def execution(self, producer="only"):
        return {
            "duration_seconds": 30,
            "requested_output_tokens": 128,
            "effective_output_tokens": 128,
            "context_tokens": {"state": "unavailable", "reason": "upstream config does not publish a hard context"},
            "prompt_tokens": 12,
            "timeout_seconds": 120,
            "maximum_attempts": 2,
            "peak_resident_bytes": {"state": "unavailable", "reason": "deferred until execution"},
            "cancellation_contract": "terminate the sole process and retain its failed attempt",
            "concurrent_model_processes": {"state": "planned_limit", "maximum": 1},
            "plan_state": "planned_unverified",
            "receipt": {
                "state": "deferred",
                "producer_task": producer,
                "schema_version": "dicow-r2-execution-receipt-v1",
            },
        }

    def ledger(self):
        model = self.resource_bound("sum_model_file_bytes_upper_bound_v1")
        header = self.resource_bound("sum_safetensors_header_bytes_exact_v1")
        zero = self.resource_bound("zero_by_phase_contract_v1")
        phases = [
            {
                "name": "acquire",
                "final_bytes": model,
                "staging_bytes": model,
                "retained_failure_bytes": model,
                "retry_bytes": zero,
                "serializer_bytes": header,
                "simultaneously_retained_prior_outputs": zero,
            },
            {
                "name": "convert",
                "final_bytes": model,
                "staging_bytes": model,
                "retained_failure_bytes": model,
                "retry_bytes": zero,
                "serializer_bytes": header,
                "simultaneously_retained_prior_outputs": zero,
            },
        ]
        return {
            "schema_version": "dicow-r2-writer-resource-plan-v2",
            "writers": [{
                "writer": "only",
                "destination_path": str(Path("/private/tmp") / "maccheroni-r2-preflight-only"),
                "sources": [self.resource_source()],
                "phases": phases,
                "execution": self.execution(),
                "planning_state": "source_bounds_frozen_receipt_deferred",
            }],
        }

    def test_r2_resource_plan_freezes_source_bounds_and_defers_receipts(self) -> None:
        result = preflight.calculate_r2_writer_resource_ledger(self.ledger(), required_writers=("only",))
        self.assertEqual("sufficient", result["resource_gate_state"])
        self.assertEqual(3_001_000 + 2 ** 31, result["writers"][0]["required_free_bytes"])
        self.assertEqual("deferred", result["writers"][0]["execution"]["receipt"]["state"])

    def test_r2_resource_rejects_free_integer_and_observed_concurrency_claims(self) -> None:
        ledger = self.ledger()
        ledger["writers"][0]["phases"][0]["final_bytes"] = 10
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.calculate_r2_writer_resource_ledger(ledger, required_writers=("only",))
        self.assertEqual("r2_resource_formula_mismatch", raised.exception.code)

        ledger = self.ledger()
        ledger["writers"][0]["execution"]["concurrent_model_processes"] = 2
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.calculate_r2_writer_resource_ledger(ledger, required_writers=("only",))
        self.assertEqual("r2_model_concurrency", raised.exception.code)

    def test_r2_resource_rejects_source_and_extractor_drift(self) -> None:
        for mutate in (
            lambda ledger: ledger["writers"][0]["sources"][0].__setitem__("model_file_bytes", 999_999),
            lambda ledger: ledger["writers"][0]["phases"][0]["final_bytes"].__setitem__("bytes", 999_999),
            lambda ledger: ledger["writers"][0]["phases"][0]["final_bytes"].__setitem__("extractor_id", "zero_by_phase_contract_v1"),
        ):
            ledger = self.ledger()
            mutate(ledger)
            with self.assertRaises(preflight.PreflightError) as raised:
                preflight.calculate_r2_writer_resource_ledger(ledger, required_writers=("only",))
            self.assertIn(raised.exception.code, {"r2_resource_formula_mismatch", "r2_resource_shape"})

    def test_r2_timestamp_attribution_is_unique_half_open_and_gap_safe(self) -> None:
        utterances = [
            {"utterance_id": "a", "start_sample": 0, "end_sample": 16_000},
            {"utterance_id": "b", "start_sample": 20_000, "end_sample": 32_000},
        ]
        words = [
            {"word_id": "w1", "start_sample": 15_000, "end_sample": 16_800},
            {"word_id": "w2", "start_sample": 20_000, "end_sample": 21_000},
        ]
        result = preflight.attribute_r2_words_to_utterances(utterances, words)
        self.assertEqual(["a", "b"], [row["utterance_id"] for row in result])

        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.attribute_r2_words_to_utterances(
                utterances,
                [{"word_id": "gap", "start_sample": 17_000, "end_sample": 18_000}],
            )
        self.assertEqual("r2_timestamp_gap_word", raised.exception.code)

        close = [
            {"utterance_id": "a", "start_sample": 0, "end_sample": 16_000},
            {"utterance_id": "b", "start_sample": 16_100, "end_sample": 32_000},
        ]
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.attribute_r2_words_to_utterances(
                close,
                [{"word_id": "ambiguous", "start_sample": 15_900, "end_sample": 16_200}],
            )
        self.assertEqual("r2_timestamp_ambiguous_attribution", raised.exception.code)

    def test_r2_timestamp_contract_rejects_self_truth_and_tolerance_drift(self) -> None:
        drift = dict(preflight.R2_TIMESTAMP_CONTRACT)
        drift["boundary_tolerance_samples"] = 1281
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.validate_r2_timestamp_contract(drift)
        self.assertEqual("r2_timestamp_contract", raised.exception.code)

        self_truth = dict(preflight.R2_TIMESTAMP_CONTRACT)
        self_truth["truth_authority"] = "Qwen/Qwen3-ForcedAligner-0.6B-hf"
        with self.assertRaises(preflight.PreflightError):
            preflight.validate_r2_timestamp_contract(self_truth)

        unavailable = {
            "status": "timestamp_truth_unavailable",
            "reason": "no independent public acoustic authority was captured",
            "forced_aligner_self_truth_forbidden": True,
        }
        self.assertEqual(
            "timestamp_truth_unavailable",
            preflight.validate_r2_timestamp_contract(unavailable)["status"],
        )

    def test_r2_timestamp_rejects_duplicate_or_reordered_words(self) -> None:
        utterances = [{"utterance_id": "u", "start_sample": 0, "end_sample": 1000}]
        for words in (
            [
                {"word_id": "w", "start_sample": 100, "end_sample": 200},
                {"word_id": "w", "start_sample": 300, "end_sample": 400},
            ],
            [
                {"word_id": "a", "start_sample": 300, "end_sample": 400},
                {"word_id": "b", "start_sample": 100, "end_sample": 200},
            ],
        ):
            with self.assertRaises(preflight.PreflightError) as raised:
                preflight.attribute_r2_words_to_utterances(utterances, words)
            self.assertEqual("r2_timestamp_shape", raised.exception.code)

    def test_r2_candidate_constraints_plan_one_sample_boundary_and_defer_receipt(self) -> None:
        maximum = 30 * 16_000
        row = {
            "path": "only",
            "execution": self.execution(),
            "unit_contract": {
                "unit": "audio_file",
                "batch_size": {"state": "planned_limit", "maximum": 1},
                "sample_rate_hz": 16_000,
            },
        }
        row["constraints"] = [{
            "constraint_id": "duration",
            "variable": "wall audio duration",
            "unit": "samples",
            "scope": "only",
            "kind": "operator_choice",
            "source": "R3 unverified execution plan",
            "formula": "floor(planned_seconds*16000)",
            "headroom": "none in planned cap",
            "observed_range": "not_observed_at_R3",
            "planned_maximum_samples": maximum,
            "failure_mode": "reject or split",
            "telemetry": "planned seconds",
            "review_trigger": "model revision",
        }]
        row["supported_range"] = {
            "state": "planned_unverified",
            "maximum_samples": maximum,
            "limiting_constraints": ["duration"],
            "reason": "boundary receipt deferred to producing task",
        }
        row["boundary_probe_plans"] = [{
            "constraint_id": "duration",
            "sample_rate_hz": 16_000,
            "epsilon_unit": "one_sample",
            "below_samples": maximum - 1,
            "at_samples": maximum,
            "above_samples": maximum + 1,
            "receipt_state": "deferred",
            "producer_task": "only",
            "receipt_schema_version": "dicow-r2-boundary-receipt-v1",
        }]
        ledger = {"schema_version": "dicow-r2-candidate-constraint-plan-v2", "paths": [row]}
        result = preflight.validate_r2_candidate_constraint_ledger(ledger, required_paths=("only",))
        self.assertEqual(maximum, result["paths"]["only"]["supported_range"]["maximum_samples"])

        row["boundary_probe_plans"][0]["below_samples"] = maximum - 16_000
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.validate_r2_candidate_constraint_ledger(ledger, required_paths=("only",))
        self.assertEqual("r2_constraint_invalid", raised.exception.code)

        fake = json.loads(json.dumps(ledger))
        fake["paths"][0]["boundary_probe_plans"][0]["below_samples"] = maximum - 1
        fake["paths"][0]["boundary_probe_plans"][0]["accepted"] = True
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.validate_r2_candidate_constraint_ledger(fake, required_paths=("only",))
        self.assertEqual("r2_constraint_invalid", raised.exception.code)

        row["boundary_probe_plans"][0]["below_samples"] = maximum - 1
        probe = row["boundary_probe_plans"][0]
        receipt = {
            "schema_version": "dicow-r2-boundary-receipt-v1",
            "constraint_id": "duration",
            "producer_task": "only",
            "runner_fingerprint": "a" * 64,
            "observations": [
                {"input_samples": maximum - 1, "outcome": "supported", "terminal_reason": "completed"},
                {"input_samples": maximum, "outcome": "supported", "terminal_reason": "completed"},
                {"input_samples": maximum + 1, "outcome": "reject_or_split", "terminal_reason": "planned_limit_exceeded"},
            ],
            "record": {"path": "later/boundary-receipt.json", "bytes": 10, "sha256": "b" * 64},
        }
        self.assertEqual("duration", preflight.validate_r2_boundary_receipt(probe, receipt)["constraint_id"])
        receipt["observations"][0]["input_samples"] = maximum - 16_000
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.validate_r2_boundary_receipt(probe, receipt)
        self.assertEqual("r2_constraint_invalid", raised.exception.code)


if __name__ == "__main__":
    unittest.main()
