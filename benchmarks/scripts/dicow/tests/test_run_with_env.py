import json
import hashlib
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from benchmarks.scripts.dicow import run_with_env
from benchmarks.scripts.dicow.common import manifest
from benchmarks.scripts.dicow.reference import inspect as r2_inspect


_REAL_VERIFY_R2_AUDIT = r2_inspect.verify_r2_audit


class RunWithEnvTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.cache = self.root / "benchmarks"
        self.checkout = self.root / "checkout"
        self.checkout.mkdir()
        self.lock_paths = {
            "DICOW_SCORING_VENV": self.checkout / "benchmarks/scripts/scoring/uv.lock",
            "DICOW_ALIGNER_VENV": self.checkout / "benchmarks/env/dicow-aligner/uv.lock",
            "DICOW_REFERENCE_VENV": self.checkout / "benchmarks/env/dicow-reference/uv.lock",
            "DICOW_MLX_VENV": self.checkout / "benchmarks/env/dicow-mlx/uv.lock",
        }
        self.lock_hashes = {}
        for key, path in self.lock_paths.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            data = (key + " locked\n").encode("utf-8")
            path.write_bytes(data)
            self.lock_hashes[key] = hashlib.sha256(data).hexdigest()
        self.dicow = self.cache / "dicow"
        self.run_id = "unit-r1"
        self.run_root = self.dicow / "runs" / self.run_id
        self.env_directory = self.run_root / "env.d"
        self.env_directory.mkdir(parents=True)
        (self.dicow / "run-envs").mkdir(parents=True)
        self.env_file = self.dicow / "run-envs" / "unit.env"
        self.base = {
            "MACCHERONI_BENCHMARK_CACHE": str(self.cache),
            "HF_HOME": str(self.dicow / "models" / "huggingface"),
            "DICOW_CACHE_ROOT": str(self.dicow),
            "DICOW_RUN_ID": self.run_id,
            "DICOW_RUN_ROOT": str(self.run_root),
            "DICOW_UV_CACHE": str(self.dicow / "uv-cache" / self.run_id),
            "DICOW_SPEECH_CACHE": str(self.dicow / "models" / "speech-swift"),
            "DICOW_SPEECH_RUNTIME_ROOT": str(
                self.dicow / "runtimes" / "speech-swift" / "sealed-release"
            ),
            "DICOW_SCORING_VENV": str(
                self.dicow / "venvs" / "scoring" / self.lock_hashes["DICOW_SCORING_VENV"]
            ),
        }
        self._write_base()
        self._write_t0_binding()

    def _seal(self, path):
        path.chmod(stat.S_IRUSR | stat.S_IRGRP | stat.S_IROTH)

    def _write_assignments(self, path, values, order):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join("{}={}\n".format(key, values[key]) for key in order), encoding="utf-8")
        self._seal(path)

    def _write_json(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists():
            path.chmod(0o644)
        path.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
        self._seal(path)

    def _record(self, path, sealed=True):
        data = path.read_bytes()
        return {
            "path": str(path),
            "sha256": hashlib.sha256(data).hexdigest(),
            "bytes": len(data),
            "mode": "0{:03o}".format(stat.S_IMODE(path.stat().st_mode)),
        }

    def _write_t0_binding(self):
        gate_path = self.run_root / "frontier-j0/gate.json"
        self._write_json(gate_path, {"branch_verdict": "proceed", "next_task_ids": ["T1"]})
        manifest_path = self.run_root / "run-manifest.json"
        base_record = self._record(self.env_file)
        base_record["keys"] = list(run_with_env.BASE_KEYS)
        self._write_json(
            manifest_path,
            {
                "schema_version": "dicow-run-manifest-v1",
                "run_id": self.run_id,
                "run_root": str(self.run_root),
                "base_env": base_record,
                "scoring_lock": self._record(self.lock_paths["DICOW_SCORING_VENV"]),
            },
        )
        self._write_json(
            self.run_root / "task-state/T0.json",
            {
                "schema_version": "dicow-task-state-v1",
                "task": "T0",
                "state": "done",
                "branch_disposition": "executed",
                "run_id": self.run_id,
                "branch_verdict": "proceed",
                "run_manifest_path": "run-manifest.json",
                "run_manifest_sha256": self._record(manifest_path)["sha256"],
                "gate_path": "frontier-j0/gate.json",
                "gate_sha256": self._record(gate_path)["sha256"],
            },
        )

    def _write_r2_binding(self, include_r1=True):
        plan_path = self.root / "r2-plan.md"
        plan_prefix = b"# r2 plan\n\n"
        plan_path.write_bytes(plan_prefix + b"## Results\n")
        import_path = self.run_root / "import-r1/manifest.json"
        self._write_json(import_path, {"schema_version": "r1-import-fixture-v1"})
        untracked = []
        outputs = {}
        before_paths = tuple(dict.fromkeys(
            run_with_env.R2_TRACKED_FILES + run_with_env.R2_TASK_TRACKED_FILES["R3"]
        ))
        for relative in before_paths:
            path = self.checkout / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            before = ("before " + relative + "\n").encode()
            path.write_bytes(before)
            untracked.append({
                "repo_path": relative,
                "sha256": hashlib.sha256(before).hexdigest(),
                "bytes": len(before),
                "mode": "0644",
            })
        before_path = self.run_root / "import-r1/repository-before-state.json"
        self._write_json(before_path, {"untracked_worktree": untracked})
        for relative in run_with_env.R2_TRACKED_FILES:
            path = self.checkout / relative
            path.write_text("after " + relative + "\n", encoding="utf-8")
            outputs[relative] = {
                "input": next(
                    {key: value for key, value in item.items() if key != "repo_path"}
                    for item in untracked if item["repo_path"] == relative
                ),
                "output": {
                    key: value for key, value in self._record(path).items() if key != "path"
                },
            }
        manifest_path = self.run_root / "run-manifest.json"
        manifest_path.chmod(0o644)
        base_record = self._record(self.env_file)
        base_record["keys"] = list(run_with_env.BASE_KEYS)
        before_record = self._record(before_path)
        before_record["run_path"] = "import-r1/repository-before-state.json"
        self._write_json(manifest_path, {
            "schema_version": "dicow-r2-run-manifest-v1",
            "run_id": self.run_id,
            "run_root": str(self.run_root),
            "create_only": True,
            "base_env": base_record,
            "scoring_lock": self._record(self.lock_paths["DICOW_SCORING_VENV"]),
            "plan_contract": {
                "boundary": "bytes-before-final-## Results-heading",
                "bytes": len(plan_prefix),
                "path": str(plan_path),
                "sha256": hashlib.sha256(plan_prefix).hexdigest(),
            },
            "plan_contract_bytes": len(plan_prefix),
            "plan_contract_sha256": hashlib.sha256(plan_prefix).hexdigest(),
            "r1_import": {
                "path": "import-r1/manifest.json",
                "sha256": self._record(import_path)["sha256"],
                "bytes": self._record(import_path)["bytes"],
                "mode": self._record(import_path)["mode"],
            },
            "repository_before_state": before_record,
        })
        r0_path = self.run_root / "task-state/R0.json"
        self._write_json(r0_path, {
            "schema_version": "dicow-r2-task-state-v1",
            "task": "R0",
            "state": "done",
            "branch_disposition": "executed",
            "evidence_outcome": "supported",
            "run_id": self.run_id,
            "next_task_ids": ["R1"],
            "no_valid_r1_j1_gate": True,
            "run_manifest_sha256": self._record(manifest_path)["sha256"],
            "source_input_hashes": {
                "plan_contract": hashlib.sha256(plan_prefix).hexdigest(),
                "r2_plan_review": "b" * 64,
            },
            "artifacts": {
                "import-manifest": {
                    "path": "import-r1/manifest.json",
                    "sha256": self._record(import_path)["sha256"],
                    "bytes": self._record(import_path)["bytes"],
                    "mode": self._record(import_path)["mode"],
                },
            },
        })
        if include_r1:
            self._write_json(self.run_root / "task-state/R1.json", {
                "schema_version": "dicow-r2-task-state-v1",
                "task": "R1",
                "state": "done",
                "branch_disposition": "executed",
                "evidence_outcome": "supported",
                "run_id": self.run_id,
                "next_task_ids": ["R2"],
                "source_input_hashes": {
                    "R0_state": self._record(r0_path)["sha256"],
                    "run_manifest": self._record(manifest_path)["sha256"],
                },
                "tracked_files": outputs,
            })

    def _r3_publication_fields(self):
        self.lock_hashes["DICOW_R2_ALIGNER_VENV"] = self.lock_hashes[
            "DICOW_ALIGNER_VENV"
        ]
        self.lock_hashes["DICOW_R2_REFERENCE_VENV"] = self.lock_hashes[
            "DICOW_REFERENCE_VENV"
        ]
        for key, relative in run_with_env.R2_R3_FIXED_SOURCE_PATHS.items():
            path = self.run_root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            if path.exists():
                path.chmod(0o644)
            path.write_text("{} fixture\n".format(key), encoding="utf-8")
            self._seal(path)

        aligner = self.dicow / "venvs/aligner" / self.lock_hashes["DICOW_ALIGNER_VENV"]
        reference = self.dicow / "venvs/reference" / self.lock_hashes["DICOW_REFERENCE_VENV"]
        for directory, payload in ((aligner, "aligner\n"), (reference, "reference\n")):
            directory.mkdir(parents=True, exist_ok=True)
            (directory / "payload").write_text(payload, encoding="utf-8")
        speech = Path(self.base["DICOW_SPEECH_RUNTIME_ROOT"]) / "speech"
        speech.parent.mkdir(parents=True, exist_ok=True)
        speech.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        speech.chmod(0o555)
        values = {
            "DICOW_R2_ALIGNER_VENV": str(aligner),
            "DICOW_R2_REFERENCE_VENV": str(reference),
            "DICOW_R2_SPEECH_BIN": str(speech),
        }
        fragment = self._fragment("R3-runtimes.env", values)
        fragment_record = self._record(fragment)
        fragment_record["path"] = "env.d/R3-runtimes.env"
        sealed_paths = {
            key: run_with_env.sealed_path_record(Path(value), kind)
            for key, kind in run_with_env.R2_R3_SEALED_PATH_KINDS.items()
            for value in (values[key],)
        }
        self._write_json(
            self.run_root / "r3-runtime.staging/sealed-fragment-record.json",
            {"R3-runtimes.env": fragment_record},
        )
        self._write_json(
            self.run_root / "r3-runtime.staging/sealed-path-records.json",
            sealed_paths,
        )

        attempt = self.run_root / "pre-model-audit/attempts/fixture"
        identities = attempt / "audit/model-identities.json"
        self._write_json(identities, {"schema_version": "fixture", "models": []})
        selected_manifest = attempt / "manifest.json"
        self._write_json(selected_manifest, {
            "schema_version": "dicow-r2-pre-model-audit-manifest-v1",
            "run_id": self.run_id,
            "spec_record": {
                "bytes": self._record(
                    self.run_root
                    / run_with_env.R2_R3_FIXED_SOURCE_PATHS[
                        run_with_env.R2_R3_ACTIVE_SPEC_SOURCE_KEY
                    ]
                )["bytes"],
                "sha256": self._record(
                    self.run_root
                    / run_with_env.R2_R3_FIXED_SOURCE_PATHS[
                        run_with_env.R2_R3_ACTIVE_SPEC_SOURCE_KEY
                    ]
                )["sha256"],
            },
        })
        self._write_json(self.run_root / "pre-model-audit/canonical.json", {
            "schema_version": "dicow-r2-pre-model-audit-canonical-v1",
            "run_id": self.run_id, "attempt": str(attempt),
            "manifest_record": {
                "sha256": self._record(selected_manifest)["sha256"],
                "bytes": self._record(selected_manifest)["bytes"],
            },
        })
        manifest_record = self._record(self.run_root / "run-manifest.json")
        plan_hash = json.loads((self.run_root / "run-manifest.json").read_text())[
            "plan_contract"
        ]["sha256"]
        sources = {
            "plan_contract": plan_hash,
            "run_manifest": manifest_record["sha256"],
            "R1_effective_state": self._record(
                run_with_env._effective_r2_state_path(self.run_root, "R1")
            )["sha256"],
            "R2_state": self._record(self.run_root / "task-state/R2.json")["sha256"],
        }
        for key, relative in run_with_env.R2_R3_FIXED_SOURCE_PATHS.items():
            sources[key] = self._record(self.run_root / relative)["sha256"]
        sources["pre_model_audit_manifest"] = self._record(selected_manifest)["sha256"]
        identity_record = self._record(identities)
        identity_record.pop("mode")
        identity_record["path"] = str(identities.relative_to(self.run_root))
        return {
            "source_input_hashes": sources,
            "artifacts": {"model-identities": identity_record},
            "sealed_fragments": {"R3-runtimes.env": fragment_record},
            "sealed_paths": sealed_paths,
        }

    def _write_valid_r3_state(self):
        self._write_r2_binding(include_r1=True)
        r2_path = self.run_root / "task-state/R2.json"
        self._write_json(r2_path, {
            "schema_version": "dicow-r2-task-state-v1", "task": "R2",
            "state": "done", "branch_disposition": "executed",
            "evidence_outcome": "supported", "run_id": self.run_id,
            "predecessor_state_hashes": {
                "R0": self._record(self.run_root / "task-state/R0.json")["sha256"],
                "R1": self._record(self.run_root / "task-state/R1.json")["sha256"],
            },
        })
        state_path = self.run_root / "task-state/R3.json"
        before = json.loads(
            (self.run_root / "import-r1/repository-before-state.json").read_text()
        )
        before_index = {
            item["repo_path"]: {
                key: value for key, value in item.items() if key != "repo_path"
            }
            for item in before["untracked_worktree"]
        }
        publication = self._r3_publication_fields()
        self._write_json(state_path, {
            "schema_version": "dicow-r2-task-state-v1", "task": "R3",
            "state": "done", "branch_disposition": "executed",
            "evidence_outcome": "evidence_blocker", "run_id": self.run_id,
            "predecessor_state_hashes": {
                "R1": self._record(self.run_root / "task-state/R1.json")["sha256"],
                "R2": self._record(r2_path)["sha256"],
            },
            "next_task_ids": ["R4"],
            "tracked_files": {
                relative: {
                    "input": before_index[relative],
                    "output": {
                        key: value
                        for key, value in self._record(self.checkout / relative).items()
                        if key != "path"
                    },
                }
                for relative in run_with_env.R2_TASK_TRACKED_FILES["R3"]
            },
            **publication,
        })
        return state_path, json.loads(state_path.read_text())

    def _write_r4_transition(
        self,
        r3_path,
        scope,
        outcome,
        next_tasks,
        gate_relative="fable-j1/gate.json",
        skip_tasks=(),
    ):
        gate_path = self.run_root / gate_relative
        self._write_json(gate_path, {
            "gate_id": "J1-r2",
            "task": "R4",
            "scope": scope,
            "evidence_outcome": outcome,
            "decision": {
                "checkpoint": "J1-r2",
                "scope": scope,
                "evidence_outcome": outcome,
                "next_task_ids": next_tasks,
                "skip_task_ids": list(skip_tasks),
                "reversal_condition": "fixture reversal condition",
            },
        })
        return gate_path, {
            "schema_version": "dicow-r2-task-state-v1", "task": "R4",
            "state": "done", "branch_disposition": "executed",
            "evidence_outcome": outcome, "run_id": self.run_id,
            "predecessor_state_hashes": {"R3": self._record(r3_path)["sha256"]},
            "next_task_ids": next_tasks, "gate_path": gate_relative,
            "gate_sha256": self._record(gate_path)["sha256"],
        }

    def _write_r5_skip_state(
        self, r3_path, gate_relative="fable-j1/gate.json", skip_tasks=None
    ):
        if skip_tasks is None:
            skip_tasks = (
                "R5", "R6", "R7", "R8", "R9", "R10", "R11", "R12",
            )
        gate_path, r4_state = self._write_r4_transition(
            r3_path,
            "proceed_qwen_only",
            "evidence_blocker",
            ["Q1"],
            gate_relative=gate_relative,
            skip_tasks=skip_tasks,
        )
        r4_path = self.run_root / "task-state/R4.json"
        self._write_json(r4_path, r4_state)
        return gate_path, {
            "schema_version": "dicow-r2-task-state-v1", "task": "R5",
            "state": "done", "branch_disposition": "skipped",
            "evidence_outcome": "evidence_blocker", "run_id": self.run_id,
            "predecessor_state_hashes": {"R4": self._record(r4_path)["sha256"]},
            "gate_path": gate_relative,
            "gate_sha256": self._record(gate_path)["sha256"],
        }

    def _write_final_authority(self, outcome="supported", gate_relative=None):
        if gate_relative is None:
            gate_relative = manifest.R2_FINAL_GATE_PATH
        gate_path = self.run_root / gate_relative
        self._write_json(gate_path, {
            "gate_id": "FINAL-r2", "task": "R13", "scope": "final_review",
            "evidence_outcome": outcome,
            "decision": {
                "checkpoint": "FINAL-r2", "scope": "final_review",
                "evidence_outcome": outcome, "next_task_ids": [],
                "skip_task_ids": [], "reversal_condition": "fixture final condition",
            },
        })
        state = {
            "schema_version": "dicow-r2-task-state-v1", "task": "R13",
            "state": "done", "branch_disposition": "executed",
            "evidence_outcome": outcome, "run_id": self.run_id,
            "next_task_ids": [], "gate_path": gate_relative,
            "gate_sha256": self._record(gate_path)["sha256"],
        }
        self._write_json(self.run_root / "task-state/R13.json", state)
        return gate_path, state

    def _write_base(self, text=None):
        if self.env_file.exists():
            self.env_file.chmod(stat.S_IRUSR | stat.S_IWUSR)
        if text is None:
            text = "".join(
                "{}={}\n".format(key, self.base[key]) for key in run_with_env.BASE_KEYS
            )
        self.env_file.write_text(text, encoding="utf-8")
        self._seal(self.env_file)

    def _fragment(self, name, values):
        expanded = dict(values)
        for key, kind, _ in run_with_env.FRAGMENT_RESOURCES[name]["resources"]:
            if kind == "venv":
                expanded[key + "_LOCK_SHA256"] = self.lock_hashes[key]
            elif Path(expanded[key]).exists() and not Path(expanded[key]).is_symlink():
                record = run_with_env.sealed_path_record(Path(expanded[key]), kind)
                expanded[key + "_SHA256"] = record["sha256"]
                expanded[key + "_BYTES"] = str(record["bytes"])
                expanded[key + "_MODE"] = record["mode"]
            else:
                expanded[key + "_SHA256"] = "0" * 64
                expanded[key + "_BYTES"] = "0"
                expanded[key + "_MODE"] = "0555"
            if key == "DICOW_SPEECH_BIN":
                runtime = Path(self.base["DICOW_SPEECH_RUNTIME_ROOT"])
                try:
                    expanded[key + "_RELATIVE_PATH"] = str(Path(expanded[key]).relative_to(runtime))
                except ValueError:
                    expanded[key + "_RELATIVE_PATH"] = "speech"
        path = self.env_directory / name
        self._write_assignments(path, expanded, run_with_env.FRAGMENT_KEYS[name])
        return path

    def _speech_fragment(self):
        executable = Path(self.base["DICOW_SPEECH_RUNTIME_ROOT"]) / "bin" / "speech"
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        executable.chmod(0o555)
        record = run_with_env.sealed_path_record(executable, "file")
        canonical = dict(record)
        canonical.pop("path")
        canonical["kind"] = "file"
        self._write_json(
            self.run_root / "e0-preflight/canonical.json",
            {
                "schema_version": "dicow-e0-preflight-v1",
                "run_id": self.run_id,
                "run_root": str(self.run_root),
                "runtime_bindings": {
                    "aligner": {},
                    "community1": {
                        "model_id": run_with_env.COMMUNITY1_MODEL_ID,
                        "model_revision": run_with_env.COMMUNITY1_MODEL_REVISION,
                        "binary": {"path": str(executable), "record": canonical},
                        "model_tree": {},
                        "sandbox_profile": {},
                    },
                },
            },
        )
        return self._fragment("T9-diarizer.env", {"DICOW_SPEECH_BIN": str(executable)})

    def _rewrite_speech_canonical(self, value):
        path = self.run_root / "e0-preflight/canonical.json"
        path.chmod(0o644)
        self._write_json(path, value)

    def _write_producer_state(self, task, fragment_names, path_kinds):
        fragments = {}
        for name in fragment_names:
            record = self._record(self.env_directory / name)
            record["path"] = "env.d/{}".format(name)
            fragments[name] = record
        paths = {
            key: run_with_env.sealed_path_record(Path(path), kind)
            for key, (path, kind) in path_kinds.items()
        }
        self._write_json(
            self.run_root / "task-state/{}.json".format(task),
            {
                "schema_version": "dicow-task-state-v1",
                "task": task,
                "state": "done",
                "branch_disposition": "executed",
                "run_id": self.run_id,
                "sealed_fragments": fragments,
                "sealed_paths": paths,
            },
        )

    def test_base_allowlist_and_scoring_profile(self):
        environment = run_with_env.load_profile(self.env_file, "scoring", self.root / "checkout")
        self.assertEqual(environment["UV_PROJECT_ENVIRONMENT"], self.base["DICOW_SCORING_VENV"])
        self.assertEqual(environment["UV_CACHE_DIR"], self.base["DICOW_UV_CACHE"])
        self.assertEqual(environment["PATH"], run_with_env.SAFE_PATH)

    def test_r2_dispatch_requires_sealed_r1_and_exact_imported_transition(self):
        self._write_r2_binding(include_r1=False)
        with self.assertRaisesRegex(run_with_env.LauncherError, "requires the sealed R1"):
            run_with_env.load_profile(self.env_file, "scoring", self.checkout)
        self._write_r2_binding(include_r1=True)
        environment = run_with_env.load_profile(self.env_file, "scoring", self.checkout)
        self.assertEqual(environment["DICOW_RUN_ID"], self.run_id)
        manifest.verify_tracked_transition("R1", self.run_root, self.checkout)
        state_path = self.run_root / "task-state/R1.json"
        state = json.loads(state_path.read_text())
        state["source_input_hashes"]["extra"] = "a" * 64
        state_path.chmod(0o644)
        self._write_json(state_path, state)
        with self.assertRaisesRegex(run_with_env.LauncherError, "exact R0/manifest pair"):
            run_with_env.load_profile(self.env_file, "scoring", self.checkout)

    def test_r2_dispatch_r0_provenance_superset_still_requires_plan_contract(self):
        self._write_r2_binding(include_r1=True)
        run_with_env.load_profile(self.env_file, "scoring", self.checkout)
        r0_path = self.run_root / "task-state/R0.json"
        original = json.loads(r0_path.read_text())
        for mutation in ("missing", "wrong"):
            malformed = json.loads(json.dumps(original))
            if mutation == "missing":
                malformed["source_input_hashes"].pop("plan_contract")
            else:
                malformed["source_input_hashes"]["plan_contract"] = "c" * 64
            self._write_json(r0_path, malformed)
            with self.subTest(mutation=mutation), self.assertRaisesRegex(
                run_with_env.LauncherError, "exact r2 plan contract"
            ):
                run_with_env.load_profile(self.env_file, "scoring", self.checkout)
        self._write_json(r0_path, original)

    def test_r2_dispatch_rejects_resealed_plan_import_and_output(self):
        self._write_r2_binding(include_r1=True)
        plan_path = self.root / "r2-plan.md"
        plan_path.write_bytes(b"changed plan\n## Results\n")
        with self.assertRaisesRegex(run_with_env.LauncherError, "plan contract prefix"):
            run_with_env.load_profile(self.env_file, "scoring", self.checkout)
        self._write_r2_binding(include_r1=True)
        tracked = self.checkout / run_with_env.R2_TRACKED_FILES[0]
        tracked.write_text("resealed output\n", encoding="utf-8")
        with self.assertRaisesRegex(run_with_env.LauncherError, "differs from sealed state"):
            run_with_env.load_profile(self.env_file, "scoring", self.checkout)

    def test_r2_dispatch_accepts_only_hash_chained_r1_amendment(self):
        self._write_r2_binding(include_r1=True)
        original_path = self.run_root / "task-state/R1.json"
        original = json.loads(original_path.read_text())
        changed = self.checkout / run_with_env.R2_TRACKED_FILES[0]
        changed.write_text("amended output\n", encoding="utf-8")
        transitions = {}
        for relative in run_with_env.R2_TRACKED_FILES:
            transitions[relative] = {
                "input": original["tracked_files"][relative]["output"],
                "output": {
                    key: value for key, value in self._record(self.checkout / relative).items()
                    if key != "path"
                },
            }
        original_sha = self._record(original_path)["sha256"]
        amendment_path = self.run_root / "task-state/R1-contract-amendment-1.json"
        amendment = {
            "schema_version": "dicow-r2-task-state-v1",
            "task": "R1-contract-amendment-1", "state": "done",
            "branch_disposition": "executed", "evidence_outcome": "supported",
            "run_id": self.run_id, "next_task_ids": ["R2"],
            "original_state_sha256": original_sha,
            "predecessor_state_hashes": {"R1": original_sha},
            "tracked_files": transitions,
        }
        self._write_json(amendment_path, amendment)
        run_with_env.load_profile(self.env_file, "scoring", self.checkout)
        manifest.verify_tracked_transition(
            "R1-contract-amendment-1", self.run_root, self.checkout
        )
        amendment2_path = self.run_root / "task-state/R1-contract-amendment-2.json"
        amendment2 = {
            "schema_version": "dicow-r2-task-state-v1",
            "task": "R1-contract-amendment-2", "state": "done",
            "branch_disposition": "executed", "evidence_outcome": "supported",
            "run_id": self.run_id, "next_task_ids": ["R2"],
            "original_state_sha256": self._record(amendment_path)["sha256"],
            "predecessor_state_hashes": {
                "R1-contract-amendment-1": self._record(amendment_path)["sha256"]
            },
            "tracked_files": {
                relative: {
                    "input": transition["output"], "output": transition["output"],
                }
                for relative, transition in transitions.items()
            },
        }
        self._write_json(amendment2_path, amendment2)
        run_with_env.load_profile(self.env_file, "scoring", self.checkout)
        manifest.verify_tracked_transition(
            "R1-contract-amendment-2", self.run_root, self.checkout
        )
        amendment3_path = self.run_root / "task-state/R1-contract-amendment-3.json"
        amendment3 = {
            "schema_version": "dicow-r2-task-state-v1",
            "task": "R1-contract-amendment-3", "state": "done",
            "branch_disposition": "executed", "evidence_outcome": "supported",
            "run_id": self.run_id, "next_task_ids": ["R2"],
            "original_state_sha256": self._record(amendment2_path)["sha256"],
            "predecessor_state_hashes": {
                "R1-contract-amendment-2": self._record(amendment2_path)["sha256"]
            },
            "tracked_files": {
                relative: {
                    "input": transition["output"], "output": transition["output"],
                }
                for relative, transition in transitions.items()
            },
        }
        self._write_json(amendment3_path, amendment3)
        run_with_env.load_profile(self.env_file, "scoring", self.checkout)
        manifest.verify_tracked_transition(
            "R1-contract-amendment-3", self.run_root, self.checkout
        )
        amendment4_path = self.run_root / "task-state/R1-contract-amendment-4.json"
        amendment4 = {
            "schema_version": "dicow-r2-task-state-v1",
            "task": "R1-contract-amendment-4", "state": "done",
            "branch_disposition": "executed", "evidence_outcome": "supported",
            "run_id": self.run_id, "next_task_ids": ["R2"],
            "original_state_sha256": self._record(amendment3_path)["sha256"],
            "predecessor_state_hashes": {
                "R1-contract-amendment-3": self._record(amendment3_path)["sha256"]
            },
            "tracked_files": {
                relative: {
                    "input": transition["output"], "output": transition["output"],
                }
                for relative, transition in transitions.items()
            },
        }
        self._write_json(amendment4_path, amendment4)
        run_with_env.load_profile(self.env_file, "scoring", self.checkout)
        manifest.verify_tracked_transition(
            "R1-contract-amendment-4", self.run_root, self.checkout
        )
        amendment5_path = self.run_root / "task-state/R1-contract-amendment-5.json"
        amendment5 = {
            "schema_version": "dicow-r2-task-state-v1",
            "task": "R1-contract-amendment-5", "state": "done",
            "branch_disposition": "executed", "evidence_outcome": "supported",
            "run_id": self.run_id, "next_task_ids": ["R2"],
            "original_state_sha256": self._record(amendment4_path)["sha256"],
            "predecessor_state_hashes": {
                "R1-contract-amendment-4": self._record(amendment4_path)["sha256"]
            },
            "tracked_files": {
                relative: {
                    "input": transition["output"], "output": transition["output"],
                }
                for relative, transition in transitions.items()
            },
        }
        self._write_json(amendment5_path, amendment5)
        run_with_env.load_profile(self.env_file, "scoring", self.checkout)
        manifest.verify_tracked_transition(
            "R1-contract-amendment-5", self.run_root, self.checkout
        )
        amendment6_path = self.run_root / "task-state/R1-contract-amendment-6.json"
        amendment6 = {
            "schema_version": "dicow-r2-task-state-v1",
            "task": "R1-contract-amendment-6", "state": "done",
            "branch_disposition": "executed", "evidence_outcome": "supported",
            "run_id": self.run_id, "next_task_ids": ["R2"],
            "original_state_sha256": self._record(amendment5_path)["sha256"],
            "predecessor_state_hashes": {
                "R1-contract-amendment-5": self._record(amendment5_path)["sha256"]
            },
            "tracked_files": {
                relative: {
                    "input": transition["output"], "output": transition["output"],
                }
                for relative, transition in transitions.items()
            },
        }
        self._write_json(amendment6_path, amendment6)
        run_with_env.load_profile(self.env_file, "scoring", self.checkout)
        manifest.verify_tracked_transition(
            "R1-contract-amendment-6", self.run_root, self.checkout
        )
        amendment7_path = self.run_root / "task-state/R1-contract-amendment-7.json"
        amendment7 = {
            "schema_version": "dicow-r2-task-state-v1",
            "task": "R1-contract-amendment-7", "state": "done",
            "branch_disposition": "executed", "evidence_outcome": "supported",
            "run_id": self.run_id, "next_task_ids": ["R2"],
            "original_state_sha256": self._record(amendment6_path)["sha256"],
            "predecessor_state_hashes": {
                "R1-contract-amendment-6": self._record(amendment6_path)["sha256"]
            },
            "tracked_files": {
                relative: {
                    "input": transition["output"], "output": transition["output"],
                }
                for relative, transition in amendment6["tracked_files"].items()
            },
        }
        self._write_json(amendment7_path, amendment7)
        run_with_env.load_profile(self.env_file, "scoring", self.checkout)
        manifest.verify_tracked_transition(
            "R1-contract-amendment-7", self.run_root, self.checkout
        )
        amendment8_path = self.run_root / "task-state/R1-contract-amendment-8.json"
        amendment8 = {
            "schema_version": "dicow-r2-task-state-v1",
            "task": "R1-contract-amendment-8", "state": "done",
            "branch_disposition": "executed", "evidence_outcome": "supported",
            "run_id": self.run_id, "next_task_ids": ["R2"],
            "original_state_sha256": self._record(amendment7_path)["sha256"],
            "predecessor_state_hashes": {
                "R1-contract-amendment-7": self._record(amendment7_path)["sha256"]
            },
            "tracked_files": {
                relative: {
                    "input": transition["output"], "output": transition["output"],
                }
                for relative, transition in amendment7["tracked_files"].items()
            },
        }
        self._write_json(amendment8_path, amendment8)
        run_with_env.load_profile(self.env_file, "scoring", self.checkout)
        manifest.verify_tracked_transition(
            "R1-contract-amendment-8", self.run_root, self.checkout
        )
        amendment9_path = self.run_root / "task-state/R1-contract-amendment-9.json"
        amendment9 = {
            "schema_version": "dicow-r2-task-state-v1",
            "task": "R1-contract-amendment-9", "state": "done",
            "branch_disposition": "executed", "evidence_outcome": "supported",
            "run_id": self.run_id, "next_task_ids": ["R2"],
            "original_state_sha256": self._record(amendment8_path)["sha256"],
            "predecessor_state_hashes": {
                "R1-contract-amendment-8": self._record(amendment8_path)["sha256"]
            },
            "tracked_files": {
                relative: {
                    "input": transition["output"], "output": transition["output"],
                }
                for relative, transition in amendment8["tracked_files"].items()
            },
        }
        self._write_json(amendment9_path, amendment9)
        run_with_env.load_profile(self.env_file, "scoring", self.checkout)
        manifest.verify_tracked_transition(
            "R1-contract-amendment-9", self.run_root, self.checkout
        )
        amendment10_path = self.run_root / "task-state/R1-contract-amendment-10.json"
        amendment10 = {
            "schema_version": "dicow-r2-task-state-v1",
            "task": "R1-contract-amendment-10", "state": "done",
            "branch_disposition": "executed", "evidence_outcome": "supported",
            "run_id": self.run_id, "next_task_ids": ["R2"],
            "original_state_sha256": self._record(amendment9_path)["sha256"],
            "predecessor_state_hashes": {
                "R1-contract-amendment-9": self._record(amendment9_path)["sha256"]
            },
            "tracked_files": {
                relative: {
                    "input": transition["output"], "output": transition["output"],
                }
                for relative, transition in amendment9["tracked_files"].items()
            },
        }
        self._write_json(amendment10_path, amendment10)
        with mock.patch.dict(
            manifest.R2_TASK_TRACKED_FILES,
            {"R1-contract-amendment-10": run_with_env.R2_TRACKED_FILES},
        ):
            run_with_env.load_profile(self.env_file, "scoring", self.checkout)
            manifest.verify_tracked_transition(
                "R1-contract-amendment-10", self.run_root, self.checkout
            )
            amendment10["next_task_ids"] = ["R2", "R3"]
            self._write_json(amendment10_path, amendment10)
            with self.assertRaisesRegex(
                run_with_env.LauncherError, "not a valid effective"
            ):
                run_with_env.load_profile(self.env_file, "scoring", self.checkout)

    def test_rejects_unknown_missing_and_duplicate_base_keys(self):
        cases = [
            "".join("{}={}\n".format(key, self.base[key]) for key in run_with_env.BASE_KEYS)
            + "HOME=/private/tmp/home\n",
            "".join(
                "{}={}\n".format(key, self.base[key])
                for key in run_with_env.BASE_KEYS
                if key != "HF_HOME"
            ),
            "".join("{}={}\n".format(key, self.base[key]) for key in run_with_env.BASE_KEYS)
            + "HF_HOME={}\n".format(self.base["HF_HOME"]),
        ]
        for text in cases:
            with self.subTest(text=text[-80:]):
                self._write_base(text)
                with self.assertRaises(run_with_env.LauncherError):
                    run_with_env.load_profile(self.env_file, "base", self.root / "checkout")

    def test_rejects_shell_syntax_instead_of_expanding_it(self):
        for bad_value in ("$HOME/cache", "$(id)", "/private/tmp/a;touch", "/private/tmp/a b"):
            with self.subTest(value=bad_value):
                changed = dict(self.base)
                changed["HF_HOME"] = bad_value
                text = "".join(
                    "{}={}\n".format(key, changed[key]) for key in run_with_env.BASE_KEYS
                )
                self._write_base(text)
                with self.assertRaises(run_with_env.LauncherError):
                    run_with_env.load_profile(self.env_file, "base", self.root / "checkout")

    def test_rejects_writable_base_and_fragment(self):
        self.env_file.chmod(0o644)
        with self.assertRaisesRegex(run_with_env.LauncherError, "read-only"):
            run_with_env.load_profile(self.env_file, "base", self.root / "checkout")
        self._seal(self.env_file)
        fragment = self._speech_fragment()
        fragment.chmod(0o644)
        with self.assertRaisesRegex(run_with_env.LauncherError, "read-only"):
            run_with_env.load_profile(self.env_file, "diarizer", self.root / "checkout")
        fragment.chmod(0o400)
        with self.assertRaisesRegex(run_with_env.LauncherError, "exact mode 0444"):
            run_with_env.load_profile(self.env_file, "diarizer", self.root / "checkout")

    def test_rejects_resealed_base_and_run_manifest(self):
        lines = self.env_file.read_text(encoding="utf-8").splitlines()
        self.env_file.chmod(0o644)
        self.env_file.write_text("\n".join(reversed(lines)) + "\n", encoding="utf-8")
        self._seal(self.env_file)
        with self.assertRaisesRegex(run_with_env.LauncherError, "base env tuple"):
            run_with_env.load_profile(self.env_file, "base", self.checkout)

        self._write_base()
        manifest_path = self.run_root / "run-manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["resealed"] = True
        manifest_path.chmod(0o644)
        manifest_path.write_text(json.dumps(manifest, sort_keys=True) + "\n", encoding="utf-8")
        self._seal(manifest_path)
        with self.assertRaisesRegex(run_with_env.LauncherError, "T0 task-state hash"):
            run_with_env.load_profile(self.env_file, "base", self.checkout)

    def test_rejects_symlinked_file_component_and_checkout_path(self):
        real = self.root / "real"
        real.mkdir()
        link = self.root / "linked"
        link.symlink_to(real, target_is_directory=True)
        changed = dict(self.base)
        changed["HF_HOME"] = str(link / "huggingface")
        self._write_base(
            "".join("{}={}\n".format(key, changed[key]) for key in run_with_env.BASE_KEYS)
        )
        with self.assertRaisesRegex(run_with_env.LauncherError, "symlink"):
            run_with_env.load_profile(self.env_file, "base", self.root / "checkout")

        self._write_base()
        checkout = self.root / "checkout"
        checkout.mkdir(exist_ok=True)
        changed = dict(self.base)
        changed["DICOW_SCORING_VENV"] = str(checkout / "venv")
        self._write_base(
            "".join("{}={}\n".format(key, changed[key]) for key in run_with_env.BASE_KEYS)
        )
        with self.assertRaisesRegex(run_with_env.LauncherError, "checkout"):
            run_with_env.load_profile(self.env_file, "base", checkout)

    def test_rejects_path_escape_and_unknown_fragment(self):
        self._fragment(
            "T2-aligner.env",
            {
                "DICOW_ALIGNER_VENV": str(
                    self.root / self.lock_hashes["DICOW_ALIGNER_VENV"]
                )
            },
        )
        with self.assertRaisesRegex(run_with_env.LauncherError, "venv root"):
            run_with_env.load_profile(self.env_file, "aligner", self.root / "checkout")

        fragment = self.env_directory / "T2-aligner.env"
        fragment.chmod(0o600)
        fragment.unlink()
        unknown = self.env_directory / "source-me.env"
        unknown.write_text("HOME=/private/tmp\n", encoding="utf-8")
        self._seal(unknown)
        with self.assertRaisesRegex(run_with_env.LauncherError, "unknown fragment"):
            run_with_env.load_profile(self.env_file, "base", self.root / "checkout")

    def test_profiles_require_their_sealed_runtime_fragment(self):
        for profile in (
            "aligner", "reference", "diarizer", "mlx",
            "r2-qwen", "r2-aligner-bootstrap", "r2-diarizer-bootstrap",
            "r2-reference-bootstrap", "r2-aligner", "r2-diarizer",
            "r2-reference", "r2-mlx",
        ):
            with self.subTest(profile=profile):
                with self.assertRaisesRegex(run_with_env.LauncherError, "requires sealed fragment"):
                    run_with_env.load_profile(self.env_file, profile, self.root / "checkout")

    def test_r2_profiles_use_only_namespaced_producer_fragments(self):
        self.assertEqual(
            run_with_env.PROFILE_FRAGMENTS["r2-qwen"], ("Q1-qwen-apple.env",)
        )
        self.assertEqual(
            run_with_env.PROFILE_FRAGMENTS["r2-reference-bootstrap"],
            ("R3-runtimes.env",),
        )
        self.assertEqual(
            run_with_env.PROFILE_FRAGMENTS["r2-reference"],
            ("R3-runtimes.env", "R5-natural-pack.env"),
        )
        self.assertNotIn(
            "R5-natural-pack.env",
            run_with_env.PROFILE_FRAGMENTS["r2-reference-bootstrap"],
        )
        self.assertEqual(
            run_with_env.PROFILE_FRAGMENTS["r2-mlx"],
            ("R3-runtimes.env", "R5-natural-pack.env", "R12-dicow-mlx.env"),
        )

    @mock.patch(
        "benchmarks.scripts.dicow.reference.inspect.verify_r2_audit",
        return_value={
            "status": "verified", "run_id": "unit-r1",
            "summary": {"decision": {"dicow_scope": "evidence_blocker"}},
        },
    )
    def test_r2_fragment_producer_requires_r2_state_schema(self, audit_replay):
        state_path, valid = self._write_valid_r3_state()
        audit_replay.reset_mock()
        self.assertEqual(
            run_with_env._producer_state(
                self.run_root, self.run_id, "R3", self.checkout
            )["task"],
            "R3",
        )
        audit_replay.assert_called_once_with(self.run_root / "pre-model-audit")
        for profile in (
            "r2-aligner-bootstrap", "r2-reference-bootstrap", "r2-diarizer-bootstrap"
        ):
            with self.subTest(profile=profile):
                run_with_env.load_profile(self.env_file, profile, self.checkout)
        for outcome in ("supported", "not_supported", "unresolved", None):
            malformed = json.loads(json.dumps(valid))
            if outcome is None:
                malformed.pop("evidence_outcome")
            else:
                malformed["evidence_outcome"] = outcome
            self._write_json(state_path, malformed)
            audit_replay.reset_mock()
            with self.subTest(outcome=outcome), self.assertRaises(
                run_with_env.LauncherError
            ):
                run_with_env._producer_state(
                    self.run_root, self.run_id, "R3", self.checkout
                )
            audit_replay.assert_called_once_with(self.run_root / "pre-model-audit")
            r4_state = {
                "schema_version": "dicow-r2-task-state-v1", "task": "R4",
                "state": "done", "branch_disposition": "executed",
                "evidence_outcome": "supported", "run_id": self.run_id,
                "predecessor_state_hashes": {
                    "R3": self._record(state_path)["sha256"]
                },
            }
            with self.subTest(
                dependency_outcome=outcome
            ), self.assertRaises(run_with_env.LauncherError):
                run_with_env._verify_r2_task_dependencies(
                    self.run_root, self.run_id, "R4", r4_state, self.checkout
                )
        self._write_json(state_path, valid)
        r4_gate_path, r4_state = self._write_r4_transition(
            state_path, "proceed_qwen_only", "evidence_blocker", ["Q1"]
        )
        with mock.patch(
            "benchmarks.scripts.dicow.common.manifest.verify_gate"
        ) as gate_replay:
            run_with_env._verify_r2_task_dependencies(
                self.run_root, self.run_id, "R4", r4_state, self.checkout
            )
            gate_replay.assert_called_once_with(r4_gate_path)
            forged = json.loads(json.dumps(r4_state))
            forged["gate_sha256"] = "0" * 64
            with self.assertRaisesRegex(run_with_env.LauncherError, "gate hash"):
                run_with_env._verify_r2_task_dependencies(
                    self.run_root, self.run_id, "R4", forged, self.checkout
                )
        state = json.loads(state_path.read_text())
        state["schema_version"] = "dicow-task-state-v1"
        self._write_json(state_path, state)
        with self.assertRaisesRegex(run_with_env.LauncherError, "cannot authorize"):
            run_with_env._producer_state(
                self.run_root, self.run_id, "R3", self.checkout
            )
        first = run_with_env.R2_TASK_TRACKED_FILES["R3"][0]
        mutations = {}
        missing = json.loads(json.dumps(valid))
        missing["tracked_files"].pop(first)
        mutations["missing"] = missing
        extra = json.loads(json.dumps(valid))
        extra["tracked_files"]["unexpected.py"] = json.loads(
            json.dumps(valid["tracked_files"][first])
        )
        mutations["extra"] = extra
        wrong_input = json.loads(json.dumps(valid))
        wrong_input["tracked_files"][first]["input"]["sha256"] = "0" * 64
        mutations["wrong_input"] = wrong_input
        wrong_output = json.loads(json.dumps(valid))
        wrong_output["tracked_files"][first]["output"]["sha256"] = "0" * 64
        mutations["wrong_output"] = wrong_output
        source_missing = json.loads(json.dumps(valid))
        source_missing["source_input_hashes"].pop("r3_runtime_checksums")
        mutations["source_missing"] = source_missing
        source_extra = json.loads(json.dumps(valid))
        source_extra["source_input_hashes"]["forged"] = "0" * 64
        mutations["source_extra"] = source_extra
        source_non_sha = json.loads(json.dumps(valid))
        source_non_sha["source_input_hashes"]["r3_runtime_checksums"] = "invalid"
        mutations["source_non_sha"] = source_non_sha
        source_wrong = json.loads(json.dumps(valid))
        source_wrong["source_input_hashes"]["r3_runtime_checksums"] = "0" * 64
        mutations["source_wrong"] = source_wrong
        source_predecessor = json.loads(json.dumps(valid))
        source_predecessor["source_input_hashes"]["R2_state"] = source_predecessor[
            "source_input_hashes"
        ]["R1_effective_state"]
        mutations["source_predecessor"] = source_predecessor
        artifact_missing = json.loads(json.dumps(valid))
        artifact_missing["artifacts"] = {}
        mutations["artifact_missing"] = artifact_missing
        artifact_extra = json.loads(json.dumps(valid))
        artifact_extra["artifacts"]["forged"] = json.loads(
            json.dumps(artifact_extra["artifacts"]["model-identities"])
        )
        mutations["artifact_extra"] = artifact_extra
        artifact_detached = json.loads(json.dumps(valid))
        artifact_detached["artifacts"]["model-identities"]["path"] = (
            "pre-model-audit/detached/model-identities.json"
        )
        mutations["artifact_detached"] = artifact_detached
        for field, value in (("sha256", "0" * 64), ("bytes", 1)):
            changed = json.loads(json.dumps(valid))
            changed["artifacts"]["model-identities"][field] = value
            mutations["artifact_wrong_{}".format(field)] = changed
        fragment_missing = json.loads(json.dumps(valid))
        fragment_missing["sealed_fragments"] = {}
        mutations["fragment_missing"] = fragment_missing
        fragment_extra = json.loads(json.dumps(valid))
        fragment_extra["sealed_fragments"]["forged.env"] = json.loads(
            json.dumps(fragment_extra["sealed_fragments"]["R3-runtimes.env"])
        )
        mutations["fragment_extra"] = fragment_extra
        path_missing = json.loads(json.dumps(valid))
        path_missing["sealed_paths"].pop("DICOW_R2_ALIGNER_VENV")
        mutations["path_missing"] = path_missing
        path_extra = json.loads(json.dumps(valid))
        path_extra["sealed_paths"]["FORGED"] = json.loads(
            json.dumps(path_extra["sealed_paths"]["DICOW_R2_ALIGNER_VENV"])
        )
        mutations["path_extra"] = path_extra
        for collection, key in (
            ("sealed_fragments", "R3-runtimes.env"),
            ("sealed_paths", "DICOW_R2_ALIGNER_VENV"),
        ):
            for field, value in (
                ("path", "/tmp/forged"), ("sha256", "0" * 64),
                ("bytes", 1), ("mode", "0700"),
            ):
                changed = json.loads(json.dumps(valid))
                changed[collection][key][field] = value
                mutations["{}_wrong_{}".format(collection, field)] = changed
        wrong_next = json.loads(json.dumps(valid))
        wrong_next["next_task_ids"] = ["R4", "R5"]
        mutations["wrong_next"] = wrong_next
        for name, malformed in mutations.items():
            self._write_json(state_path, malformed)
            with self.subTest(name=name), self.assertRaises(run_with_env.LauncherError):
                run_with_env._producer_state(
                    self.run_root, self.run_id, "R3", self.checkout
                )
        self._write_json(state_path, valid)

        good_replay = {
            "status": "verified", "run_id": self.run_id,
            "summary": {"decision": {"dicow_scope": "evidence_blocker"}},
        }
        audit_replay.return_value = {
            "status": "verified", "run_id": self.run_id,
            "summary": {"decision": {"dicow_scope": "proceed"}},
        }
        with self.assertRaisesRegex(
            run_with_env.LauncherError, "does not prove.*evidence blocker"
        ):
            run_with_env._producer_state(
                self.run_root, self.run_id, "R3", self.checkout
            )
        audit_replay.return_value = good_replay
        audit_replay.side_effect = _REAL_VERIFY_R2_AUDIT
        with self.assertRaisesRegex(
            run_with_env.LauncherError, "audit replay failed"
        ):
            run_with_env._producer_state(
                self.run_root, self.run_id, "R3", self.checkout
            )
        audit_replay.side_effect = None
        for attack in (
            "detached audit", "malformed manifest",
            "malformed document", "malformed model identity", "extra attempt",
            "noncanonical attempt",
        ):
            audit_replay.side_effect = RuntimeError(attack)
            with self.subTest(attack=attack), self.assertRaisesRegex(
                run_with_env.LauncherError, "audit replay failed"
            ):
                run_with_env._producer_state(
                    self.run_root, self.run_id, "R3", self.checkout
                )
        audit_replay.side_effect = None

        canonical_path = self.run_root / "pre-model-audit/canonical.json"
        canonical = json.loads(canonical_path.read_text(encoding="utf-8"))
        selected_path = self.run_root / "pre-model-audit/attempts/fixture/manifest.json"
        selected = json.loads(selected_path.read_text(encoding="utf-8"))
        malformed_selected = json.loads(json.dumps(selected))
        malformed_selected.pop("spec_record")
        self._write_json(selected_path, malformed_selected)
        changed_canonical = json.loads(json.dumps(canonical))
        changed_canonical["manifest_record"] = {
            "sha256": self._record(selected_path)["sha256"],
            "bytes": self._record(selected_path)["bytes"],
        }
        self._write_json(canonical_path, changed_canonical)
        changed_state = json.loads(json.dumps(valid))
        changed_state["source_input_hashes"]["pre_model_audit_manifest"] = self._record(
            selected_path
        )["sha256"]
        self._write_json(state_path, changed_state)
        with self.assertRaisesRegex(
            run_with_env.LauncherError, "active frozen spec"
        ):
            run_with_env._producer_state(
                self.run_root, self.run_id, "R3", self.checkout
            )
        self._write_json(selected_path, selected)
        self._write_json(canonical_path, canonical)
        self._write_json(state_path, valid)

        forged = json.loads(json.dumps(canonical))
        forged["attempt"] = str(
            self.run_root / "pre-model-audit/attempts/forged"
        )
        self._write_json(canonical_path, forged)
        with self.assertRaises(run_with_env.LauncherError):
            run_with_env._producer_state(
                self.run_root, self.run_id, "R3", self.checkout
            )
        self._write_json(canonical_path, canonical)

    @mock.patch(
        "benchmarks.scripts.dicow.reference.inspect.verify_r2_audit",
        return_value={
            "status": "verified", "run_id": "unit-r1",
            "summary": {"decision": {"dicow_scope": "evidence_blocker"}},
        },
    )
    @mock.patch("benchmarks.scripts.dicow.common.manifest.verify_gate")
    def test_r4_launcher_accepts_authenticated_qwen_only_and_stop_paths(
        self, gate_replay, _audit_replay
    ):
        r3_path, _ = self._write_valid_r3_state()
        transitions = (
            ("proceed_qwen_only", "evidence_blocker", ["Q1"]),
            ("revise_or_stop_all", "not_supported", ["R13"]),
            ("revise_or_stop_all", "evidence_blocker", ["R13"]),
            ("revise_or_stop_all", "unresolved", ["R13"]),
        )
        for scope, outcome, next_tasks in transitions:
            with self.subTest(scope=scope, outcome=outcome):
                gate_path, state = self._write_r4_transition(
                    r3_path, scope, outcome, next_tasks
                )
                gate_replay.reset_mock()
                run_with_env._verify_r2_task_dependencies(
                    self.run_root, self.run_id, "R4", state, self.checkout
                )
                gate_replay.assert_called_once_with(gate_path)

    @mock.patch(
        "benchmarks.scripts.dicow.reference.inspect.verify_r2_audit",
        return_value={
            "status": "verified", "run_id": "unit-r1",
            "summary": {"decision": {"dicow_scope": "evidence_blocker"}},
        },
    )
    @mock.patch("benchmarks.scripts.dicow.common.manifest.verify_gate")
    def test_r4_launcher_rejects_gate_state_mismatches_and_noncanonical_path(
        self, gate_replay, _audit_replay
    ):
        r3_path, _ = self._write_valid_r3_state()
        _, state = self._write_r4_transition(
            r3_path, "proceed_qwen_only", "evidence_blocker", ["Q1"]
        )
        mismatches = (
            ("evidence_outcome", "unresolved"),
            ("next_task_ids", ["R13"]),
        )
        for field, value in mismatches:
            malformed = json.loads(json.dumps(state))
            malformed[field] = value
            with self.subTest(field=field), self.assertRaisesRegex(
                run_with_env.LauncherError,
                "differs from its authenticated J1-r2 transition",
            ):
                run_with_env._verify_r2_task_dependencies(
                    self.run_root, self.run_id, "R4", malformed, self.checkout
                )

        _, alternate = self._write_r4_transition(
            r3_path,
            "proceed_qwen_only",
            "evidence_blocker",
            ["Q1"],
            gate_relative="fable-j1/replayed-gate.json",
        )
        gate_replay.reset_mock()
        with self.assertRaisesRegex(run_with_env.LauncherError, "canonical"):
            run_with_env._verify_r2_task_dependencies(
                self.run_root, self.run_id, "R4", alternate, self.checkout
            )
        gate_replay.assert_not_called()

    @mock.patch(
        "benchmarks.scripts.dicow.reference.inspect.verify_r2_audit",
        return_value={
            "status": "verified", "run_id": "unit-r1",
            "summary": {"decision": {"dicow_scope": "evidence_blocker"}},
        },
    )
    @mock.patch("benchmarks.scripts.dicow.common.manifest.verify_gate")
    def test_r4_launcher_rejects_unauthorized_gate_transitions(
        self, _gate_replay, _audit_replay
    ):
        r3_path, _ = self._write_valid_r3_state()
        invalid = (
            ("proceed_dicow_and_qwen", "supported", ["R5", "Q1", "R6"], "cannot proceed"),
            ("proceed_qwen_only", "unresolved", ["Q1"], "Qwen-only gate"),
            ("proceed_qwen_only", "evidence_blocker", ["R13"], "Qwen-only gate"),
            ("revise_or_stop_all", "supported", ["R13"], "stop gate"),
            ("revise_or_stop_all", "not_supported", ["Q1"], "stop gate"),
        )
        for scope, outcome, next_tasks, message in invalid:
            _, state = self._write_r4_transition(
                r3_path, scope, outcome, next_tasks
            )
            with self.subTest(scope=scope, outcome=outcome, next=next_tasks), \
                    self.assertRaisesRegex(run_with_env.LauncherError, message):
                run_with_env._verify_r2_task_dependencies(
                    self.run_root, self.run_id, "R4", state, self.checkout
                )

    @mock.patch(
        "benchmarks.scripts.dicow.reference.inspect.verify_r2_audit",
        return_value={
            "status": "verified", "run_id": "unit-r1",
            "summary": {"decision": {"dicow_scope": "evidence_blocker"}},
        },
    )
    def test_r2_skipped_state_replays_only_the_canonical_r4_gate(
        self, _audit_replay
    ):
        r3_path, _ = self._write_valid_r3_state()
        gate_path, skipped = self._write_r5_skip_state(r3_path)
        with mock.patch(
            "benchmarks.scripts.dicow.common.manifest.verify_gate"
        ) as gate_replay:
            run_with_env._verify_r2_task_dependencies(
                self.run_root, self.run_id, "R5", skipped, self.checkout
            )
        self.assertEqual(gate_replay.call_args_list, [mock.call(gate_path)] * 2)

    @mock.patch(
        "benchmarks.scripts.dicow.reference.inspect.verify_r2_audit",
        return_value={
            "status": "verified", "run_id": "unit-r1",
            "summary": {"decision": {"dicow_scope": "evidence_blocker"}},
        },
    )
    @mock.patch("benchmarks.scripts.dicow.common.manifest.verify_gate")
    def test_r2_j2_skip_authority_accepts_selection_gate_and_rejects_j1_reroll(
        self, gate_replay, _audit_replay
    ):
        r3_path, _ = self._write_valid_r3_state()
        gate_relative = manifest.R2_J2_GATE_PATH
        gate_path = self.run_root / gate_relative
        self._write_json(gate_path, {
            "gate_id": "J2-r2", "task": "R10", "scope": "select_none",
            "evidence_outcome": "not_supported",
            "decision": {
                "checkpoint": "J2-r2", "scope": "select_none",
                "evidence_outcome": "not_supported",
                "next_task_ids": ["R13"], "skip_task_ids": ["R11", "R12"],
                "reversal_condition": "fixture reversal condition",
            },
        })
        r10_state = {
            "schema_version": "dicow-r2-task-state-v1", "task": "R10",
            "state": "done", "branch_disposition": "executed",
            "evidence_outcome": "not_supported", "run_id": self.run_id,
            "next_task_ids": ["R13"], "gate_path": gate_relative,
            "gate_sha256": self._record(gate_path)["sha256"],
        }
        self._write_json(self.run_root / "task-state/R10.json", r10_state)
        skipped = {
            "schema_version": "dicow-r2-task-state-v1", "task": "R11",
            "state": "done", "branch_disposition": "skipped",
            "evidence_outcome": "not_supported", "run_id": self.run_id,
            "gate_path": gate_relative,
            "gate_sha256": self._record(gate_path)["sha256"],
        }
        run_with_env._verify_r2_skip_gate_authority(
            self.run_root, self.run_id, "R11", skipped
        )
        gate_replay.assert_called_once_with(gate_path)

        _, r4_state = self._write_r4_transition(
            r3_path, "proceed_dicow_and_qwen", "supported", ["R5", "Q1", "R6"]
        )
        self._write_json(self.run_root / "task-state/R4.json", r4_state)
        gate_replay.reset_mock()
        run_with_env._verify_r2_executed_gate_authority(
            self.run_root, self.run_id, "R10"
        )
        with self.assertRaisesRegex(run_with_env.LauncherError, "J2-r2 skip decision"):
            run_with_env._verify_r2_executed_gate_authority(
                self.run_root, self.run_id, "R11"
            )

        malformed_r10 = json.loads(json.dumps(r10_state))
        malformed_r10["next_task_ids"] = ["R11"]
        self._write_json(self.run_root / "task-state/R10.json", malformed_r10)
        with self.assertRaisesRegex(
            run_with_env.LauncherError, "differs from its authenticated gate transition"
        ):
            run_with_env._verify_r2_executed_gate_authority(
                self.run_root, self.run_id, "R10"
            )

        selected_gate = json.loads(gate_path.read_text(encoding="utf-8"))
        selected_gate.update({
            "scope": "select_dicow_mlc", "evidence_outcome": "supported",
        })
        selected_gate["decision"].update({
            "scope": "select_dicow_mlc", "evidence_outcome": "supported",
            "next_task_ids": ["R11"], "skip_task_ids": [],
        })
        self._write_json(gate_path, selected_gate)
        r10_state.update({
            "evidence_outcome": "supported", "next_task_ids": ["R11"],
            "gate_sha256": self._record(gate_path)["sha256"],
        })
        self._write_json(self.run_root / "task-state/R10.json", r10_state)
        run_with_env._verify_r2_executed_gate_authority(
            self.run_root, self.run_id, "R11"
        )

        alternate_j2_relative = "fable-j2-reroll/gate.json"
        alternate_j2_path = self.run_root / alternate_j2_relative
        self._write_json(
            alternate_j2_path, json.loads(gate_path.read_text(encoding="utf-8"))
        )
        r10_state.update({
            "gate_path": alternate_j2_relative,
            "gate_sha256": self._record(alternate_j2_path)["sha256"],
        })
        self._write_json(self.run_root / "task-state/R10.json", r10_state)
        skipped.update({
            "gate_path": alternate_j2_relative,
            "gate_sha256": self._record(alternate_j2_path)["sha256"],
        })
        gate_replay.reset_mock()
        with self.assertRaisesRegex(run_with_env.LauncherError, "canonical"):
            run_with_env._verify_r2_skip_gate_authority(
                self.run_root, self.run_id, "R11", skipped
            )
        gate_replay.assert_not_called()

        reroll_relative = manifest.R2_J2_GATE_PATH
        reroll_path = self.run_root / reroll_relative
        self._write_json(reroll_path, {
            "gate_id": "J1-r2", "task": "R4", "scope": "proceed_qwen_only",
            "evidence_outcome": "evidence_blocker",
            "decision": {
                "checkpoint": "J1-r2", "scope": "proceed_qwen_only",
                "evidence_outcome": "evidence_blocker", "next_task_ids": ["Q1"],
                "skip_task_ids": [
                    "R5", "R6", "R7", "R8", "R9", "R10", "R11", "R12",
                ],
                "reversal_condition": "fixture reversal condition",
            },
        })
        r10_state.update({
            "evidence_outcome": "evidence_blocker", "next_task_ids": ["Q1"],
            "gate_path": reroll_relative,
            "gate_sha256": self._record(reroll_path)["sha256"],
        })
        self._write_json(self.run_root / "task-state/R10.json", r10_state)
        skipped.update({
            "evidence_outcome": "evidence_blocker", "gate_path": reroll_relative,
            "gate_sha256": self._record(reroll_path)["sha256"],
        })
        gate_replay.reset_mock()
        with self.assertRaisesRegex(
            run_with_env.LauncherError, "not an authenticated J2-r2 transition"
        ):
            run_with_env._verify_r2_skip_gate_authority(
                self.run_root, self.run_id, "R11", skipped
            )
        gate_replay.assert_called_once_with(reroll_path)

    @mock.patch(
        "benchmarks.scripts.dicow.reference.inspect.verify_r2_audit",
        return_value={
            "status": "verified", "run_id": "unit-r1",
            "summary": {"decision": {"dicow_scope": "evidence_blocker"}},
        },
    )
    def test_r2_skipped_state_rejects_forgery_mismatch_and_invalid_gate(
        self, _audit_replay
    ):
        r3_path, _ = self._write_valid_r3_state()
        gate_path, skipped = self._write_r5_skip_state(r3_path)
        forged_path = self.run_root / "forged-skip/gate.json"
        self._write_json(forged_path, {
            "decision": {"skip_task_ids": ["R5"]},
        })
        alternate = json.loads(json.dumps(skipped))
        alternate["gate_path"] = "forged-skip/gate.json"
        alternate["gate_sha256"] = self._record(forged_path)["sha256"]
        with mock.patch(
            "benchmarks.scripts.dicow.common.manifest.verify_gate"
        ) as gate_replay, self.assertRaisesRegex(
            run_with_env.LauncherError, "canonical"
        ):
            run_with_env._verify_r2_task_dependencies(
                self.run_root, self.run_id, "R5", alternate, self.checkout
            )
        gate_replay.assert_called_once_with(gate_path)

        gate_path, skipped = self._write_r5_skip_state(r3_path)
        mismatched = json.loads(json.dumps(skipped))
        mismatched["gate_sha256"] = "0" * 64
        with mock.patch(
            "benchmarks.scripts.dicow.common.manifest.verify_gate"
        ) as gate_replay, self.assertRaisesRegex(
            run_with_env.LauncherError, "differs from R4"
        ):
            run_with_env._verify_r2_task_dependencies(
                self.run_root, self.run_id, "R5", mismatched, self.checkout
            )
        self.assertEqual(gate_replay.call_args_list, [mock.call(gate_path)] * 2)

        gate_path, skipped = self._write_r5_skip_state(r3_path)
        with mock.patch(
            "benchmarks.scripts.dicow.common.manifest.verify_gate",
            side_effect=[None, manifest.VerificationError("invalid canonical gate")],
        ) as gate_replay, self.assertRaisesRegex(
            run_with_env.LauncherError, "R4 gate authority semantic replay failed"
        ):
            run_with_env._verify_r2_task_dependencies(
                self.run_root, self.run_id, "R5", skipped, self.checkout
            )
        self.assertEqual(gate_replay.call_args_list, [mock.call(gate_path)] * 2)

        gate_path, skipped = self._write_r5_skip_state(r3_path)
        skipped["task"] = "Q1"
        with mock.patch(
            "benchmarks.scripts.dicow.common.manifest.verify_gate"
        ) as gate_replay, self.assertRaisesRegex(
            run_with_env.LauncherError, "Q1 is absent from its authenticated skip gate"
        ):
            run_with_env._verify_r2_task_dependencies(
                self.run_root, self.run_id, "Q1", skipped, self.checkout
            )
        self.assertEqual(gate_replay.call_args_list, [mock.call(gate_path)] * 2)

    @mock.patch(
        "benchmarks.scripts.dicow.reference.inspect.verify_r2_audit",
        return_value={
            "status": "verified", "run_id": "unit-r1",
            "summary": {"decision": {"dicow_scope": "evidence_blocker"}},
        },
    )
    def test_executed_descendants_cannot_bypass_j1_skip_decisions(
        self, _audit_replay
    ):
        r3_path, _ = self._write_valid_r3_state()
        qwen_skip = ("R5", "R6", "R7", "R8", "R9", "R10", "R11", "R12")
        gate_path, r4_state = self._write_r4_transition(
            r3_path, "proceed_qwen_only", "evidence_blocker", ["Q1"],
            skip_tasks=qwen_skip,
        )
        r4_path = self.run_root / "task-state/R4.json"
        self._write_json(r4_path, r4_state)
        r5_state = {
            "schema_version": "dicow-r2-task-state-v1", "task": "R5",
            "state": "done", "branch_disposition": "executed",
            "evidence_outcome": "supported", "run_id": self.run_id,
            "predecessor_state_hashes": {"R4": self._record(r4_path)["sha256"]},
        }
        with mock.patch(
            "benchmarks.scripts.dicow.common.manifest.verify_gate"
        ), self.assertRaisesRegex(run_with_env.LauncherError, "J1-r2 skip decision"):
            run_with_env._verify_r2_task_dependencies(
                self.run_root, self.run_id, "R5", r5_state, self.checkout
            )

        q1_state = {
            "schema_version": "dicow-r2-task-state-v1", "task": "Q1",
            "state": "done", "branch_disposition": "executed",
            "evidence_outcome": "supported", "run_id": self.run_id,
            "predecessor_state_hashes": {"R4": self._record(r4_path)["sha256"]},
        }
        with mock.patch(
            "benchmarks.scripts.dicow.common.manifest.verify_gate"
        ):
            run_with_env._verify_r2_task_dependencies(
                self.run_root, self.run_id, "Q1", q1_state, self.checkout
            )

        stop_skip = (
            "R5", "Q1", "R6", "R7", "R8", "R9", "R10", "Q2", "R11", "R12",
        )
        _, r4_state = self._write_r4_transition(
            r3_path, "revise_or_stop_all", "not_supported", ["R13"],
            skip_tasks=stop_skip,
        )
        self._write_json(r4_path, r4_state)
        q1_state["predecessor_state_hashes"] = {
            "R4": self._record(r4_path)["sha256"]
        }
        with mock.patch(
            "benchmarks.scripts.dicow.common.manifest.verify_gate"
        ), self.assertRaisesRegex(run_with_env.LauncherError, "J1-r2 skip decision"):
            run_with_env._verify_r2_task_dependencies(
                self.run_root, self.run_id, "Q1", q1_state, self.checkout
            )

    def test_r13_requires_canonical_final_gate_after_each_legal_branch(self):
        r3_path = self.run_root / "task-state/R3.json"
        self._write_json(r3_path, {"fixture": "R3 hash authority"})
        final_path, _ = self._write_final_authority()

        qwen_skip = ("R5", "R6", "R7", "R8", "R9", "R10", "R11", "R12")
        j1_path, r4_state = self._write_r4_transition(
            r3_path, "proceed_qwen_only", "evidence_blocker", ["Q1"],
            skip_tasks=qwen_skip,
        )
        r4_path = self.run_root / "task-state/R4.json"
        self._write_json(self.run_root / "task-state/R4.json", r4_state)
        with mock.patch(
            "benchmarks.scripts.dicow.common.manifest.verify_gate"
        ) as gate_replay:
            run_with_env._verify_r2_executed_gate_authority(
                self.run_root, self.run_id, "R13"
            )
        self.assertEqual(
            gate_replay.call_args_list, [mock.call(j1_path), mock.call(final_path)]
        )

        stop_skip = (
            "R5", "Q1", "R6", "R7", "R8", "R9", "R10", "Q2", "R11", "R12",
        )
        j1_path, r4_state = self._write_r4_transition(
            r3_path, "revise_or_stop_all", "not_supported", ["R13"],
            skip_tasks=stop_skip,
        )
        self._write_json(self.run_root / "task-state/R4.json", r4_state)
        with mock.patch("benchmarks.scripts.dicow.common.manifest.verify_gate"):
            run_with_env._verify_r2_executed_gate_authority(
                self.run_root, self.run_id, "R13"
            )

        j1_path, r4_state = self._write_r4_transition(
            r3_path, "proceed_dicow_and_qwen", "supported", ["R5", "Q1", "R6"]
        )
        self._write_json(self.run_root / "task-state/R4.json", r4_state)
        j2_path = self.run_root / manifest.R2_J2_GATE_PATH
        self._write_json(j2_path, {
            "gate_id": "J2-r2", "task": "R10", "scope": "select_none",
            "evidence_outcome": "not_supported",
            "decision": {
                "checkpoint": "J2-r2", "scope": "select_none",
                "evidence_outcome": "not_supported", "next_task_ids": ["R13"],
                "skip_task_ids": ["R11", "R12"],
                "reversal_condition": "fixture selection condition",
            },
        })
        self._write_json(self.run_root / "task-state/R10.json", {
            "schema_version": "dicow-r2-task-state-v1", "task": "R10",
            "state": "done", "branch_disposition": "executed",
            "evidence_outcome": "not_supported", "run_id": self.run_id,
            "next_task_ids": ["R13"], "gate_path": manifest.R2_J2_GATE_PATH,
            "gate_sha256": self._record(j2_path)["sha256"],
        })
        with mock.patch("benchmarks.scripts.dicow.common.manifest.verify_gate"):
            run_with_env._verify_r2_executed_gate_authority(
                self.run_root, self.run_id, "R13"
            )

        alternate_path, _ = self._write_final_authority(
            gate_relative="fable-final-reroll/gate.json"
        )
        with mock.patch(
            "benchmarks.scripts.dicow.common.manifest.verify_gate"
        ), self.assertRaisesRegex(run_with_env.LauncherError, "canonical"):
            run_with_env._verify_r2_executed_gate_authority(
                self.run_root, self.run_id, "R13"
            )
        self.assertTrue(alternate_path.is_file())

        final_path, final_state = self._write_final_authority()
        mismatched = json.loads(json.dumps(final_state))
        mismatched["evidence_outcome"] = "unresolved"
        self._write_json(self.run_root / "task-state/R13.json", mismatched)
        with mock.patch(
            "benchmarks.scripts.dicow.common.manifest.verify_gate"
        ), self.assertRaisesRegex(
            run_with_env.LauncherError,
            "R13 differs from its authenticated gate transition",
        ):
            run_with_env._verify_r2_executed_gate_authority(
                self.run_root, self.run_id, "R13"
            )

        self._write_json(self.run_root / "task-state/R13.json", final_state)
        with mock.patch(
            "benchmarks.scripts.dicow.common.manifest.verify_gate",
            side_effect=[None, None, manifest.VerificationError("invalid final gate")],
        ), self.assertRaisesRegex(
            run_with_env.LauncherError, "R13 gate authority semantic replay failed"
        ):
            run_with_env._verify_r2_executed_gate_authority(
                self.run_root, self.run_id, "R13"
            )
        self.assertTrue(final_path.is_file())

    def test_diarizer_exposes_no_default_model_or_user_cache(self):
        self._speech_fragment()
        environment = run_with_env.load_profile(self.env_file, "diarizer", self.root / "checkout")
        self.assertEqual(environment["QWEN3_CACHE_DIR"], self.base["DICOW_SPEECH_CACHE"])
        self.assertIn("DICOW_SPEECH_BIN", environment)
        self.assertFalse(any(key.endswith(("_SHA256", "_BYTES", "_MODE", "_RELATIVE_PATH")) for key in environment))
        self.assertEqual(environment["PATH"], run_with_env.SYSTEM_PATH)
        self.assertEqual(environment["HOME"], run_with_env.EMPTY_HOME)
        for forbidden in (
            "HF_HOME",
            "HF_HUB_CACHE",
            "TRANSFORMERS_CACHE",
            "DICOW_SPEECH_CACHE",
            "DICOW_SPEECH_RUNTIME_ROOT",
            "DICOW_SCORING_VENV",
        ):
            self.assertNotIn(forbidden, environment)
        self.assertNotEqual(environment["DICOW_SPEECH_BIN"], "/opt/homebrew/bin/speech")

    def test_diarizer_rejects_legacy_speech_canonical_shape(self):
        self._speech_fragment()
        executable = Path(self.base["DICOW_SPEECH_RUNTIME_ROOT"]) / "bin/speech"
        record = run_with_env.sealed_path_record(executable, "file")
        record["relative_path"] = "bin/speech"
        self._rewrite_speech_canonical(
            {
                "speech_archive_sha256": "0" * 64,
                "speech_binary": record,
            }
        )
        with self.assertRaisesRegex(run_with_env.LauncherError, "canonical schema"):
            run_with_env.load_profile(self.env_file, "diarizer", self.checkout)

    def test_diarizer_rejects_wrong_canonical_run_identity(self):
        self._speech_fragment()
        path = self.run_root / "e0-preflight/canonical.json"
        original = json.loads(path.read_text(encoding="utf-8"))
        for key, value in (
            ("run_id", "other-run"),
            ("run_root", str(self.run_root.parent / "other-run")),
        ):
            with self.subTest(key=key):
                changed = json.loads(json.dumps(original))
                changed[key] = value
                self._rewrite_speech_canonical(changed)
                with self.assertRaisesRegex(run_with_env.LauncherError, "run identity"):
                    run_with_env.load_profile(self.env_file, "diarizer", self.checkout)

    def test_diarizer_rejects_wrong_canonical_model_identity(self):
        self._speech_fragment()
        path = self.run_root / "e0-preflight/canonical.json"
        original = json.loads(path.read_text(encoding="utf-8"))
        for key, value in (
            ("model_id", "other/diarizer"),
            ("model_revision", "0" * 40),
        ):
            with self.subTest(key=key):
                changed = json.loads(json.dumps(original))
                changed["runtime_bindings"]["community1"][key] = value
                self._rewrite_speech_canonical(changed)
                with self.assertRaisesRegex(run_with_env.LauncherError, "model identity"):
                    run_with_env.load_profile(self.env_file, "diarizer", self.checkout)

    def test_diarizer_rejects_wrong_canonical_binary_path_or_record(self):
        self._speech_fragment()
        path = self.run_root / "e0-preflight/canonical.json"
        original = json.loads(path.read_text(encoding="utf-8"))
        changed_path = json.loads(json.dumps(original))
        changed_path["runtime_bindings"]["community1"]["binary"]["path"] = (
            "/private/tmp/other-speech"
        )
        changed_record = json.loads(json.dumps(original))
        changed_record["runtime_bindings"]["community1"]["binary"]["record"][
            "sha256"
        ] = "0" * 64
        for label, changed, message in (
            ("path", changed_path, "binary path"),
            ("record", changed_record, "binary record"),
        ):
            with self.subTest(label=label):
                self._rewrite_speech_canonical(changed)
                with self.assertRaisesRegex(run_with_env.LauncherError, message):
                    run_with_env.load_profile(self.env_file, "diarizer", self.checkout)

    def test_diarizer_rejects_moving_or_unpinned_speech_binary(self):
        for candidate in (
            "/opt/homebrew/bin/speech",
            "/opt/homebrew/Cellar/speech/0.0.26/bin/speech",
        ):
            with self.subTest(candidate=candidate):
                fragment = self.env_directory / "T9-diarizer.env"
                if fragment.exists() or fragment.is_symlink():
                    fragment.chmod(0o600)
                    fragment.unlink()
                self._fragment("T9-diarizer.env", {"DICOW_SPEECH_BIN": candidate})
                with self.assertRaisesRegex(
                    run_with_env.LauncherError,
                    "symlink|outside DICOW_SPEECH_RUNTIME_ROOT",
                ):
                    run_with_env.load_profile(self.env_file, "diarizer", self.root / "checkout")

    def test_rejects_resealed_fragment_and_replaced_speech_binary(self):
        fragment = self._speech_fragment()
        executable = Path(self.base["DICOW_SPEECH_RUNTIME_ROOT"]) / "bin/speech"
        self._write_producer_state(
            "T9",
            ["T9-diarizer.env"],
            {"DICOW_SPEECH_BIN": (executable, "file")},
        )
        lines = fragment.read_text(encoding="utf-8").splitlines()
        fragment.chmod(0o644)
        fragment.write_text("\n".join(reversed(lines)) + "\n", encoding="utf-8")
        self._seal(fragment)
        with self.assertRaisesRegex(run_with_env.LauncherError, "sealed fragment"):
            run_with_env.load_profile(self.env_file, "diarizer", self.checkout)

        fragment.chmod(0o644)
        fragment.write_text("\n".join(lines) + "\n", encoding="utf-8")
        self._seal(fragment)
        executable.chmod(0o755)
        executable.write_text("#!/bin/sh\nexit 7\n", encoding="utf-8")
        executable.chmod(0o555)
        with self.assertRaisesRegex(run_with_env.LauncherError, "evidence does not match disk"):
            run_with_env.load_profile(self.env_file, "diarizer", self.checkout)

    def test_rejects_writable_or_changed_sealed_roots(self):
        aligner_path = (
            self.dicow / "venvs/aligner" / self.lock_hashes["DICOW_ALIGNER_VENV"]
        )
        aligner_path.mkdir(parents=True)
        payload = aligner_path / "installed.txt"
        payload.write_text("one\n", encoding="utf-8")
        self._fragment("T2-aligner.env", {"DICOW_ALIGNER_VENV": str(aligner_path)})
        self._write_producer_state(
            "T2",
            ["T2-aligner.env"],
            {"DICOW_ALIGNER_VENV": (aligner_path, "venv")},
        )
        payload.write_text("two\n", encoding="utf-8")
        with self.assertRaisesRegex(run_with_env.LauncherError, "sealed path"):
            run_with_env.load_profile(self.env_file, "aligner", self.checkout)

        state_path = self.run_root / "task-state/T2.json"
        state_path.chmod(0o600)
        state_path.unlink()
        pack = self.run_root / "pack"
        pack.mkdir()
        pack_file = pack / "canonical.json"
        pack_file.write_text("{}\n", encoding="utf-8")
        pack_file.chmod(0o444)
        pack.chmod(0o555)
        self._fragment("T10-pack.env", {"DICOW_PACK_ROOT": str(pack)})
        pack.chmod(0o755)
        with self.assertRaisesRegex(run_with_env.LauncherError, "root must be read-only"):
            run_with_env.load_profile(self.env_file, "aligner", self.checkout)

    def test_rejects_symlinked_fragment_itself(self):
        real = self.root / "real-fragment.env"
        real.write_text(
            "DICOW_ALIGNER_VENV={}\n".format(
                self.dicow
                / "venvs"
                / "aligner"
                / self.lock_hashes["DICOW_ALIGNER_VENV"]
            ),
            encoding="utf-8",
        )
        self._seal(real)
        (self.env_directory / "T2-aligner.env").symlink_to(real)
        with self.assertRaisesRegex(run_with_env.LauncherError, "symlink"):
            run_with_env.load_profile(self.env_file, "aligner", self.root / "checkout")

    def test_fragment_values_are_profile_scoped(self):
        self._fragment(
            "T2-aligner.env",
            {
                "DICOW_ALIGNER_VENV": str(
                    self.dicow
                    / "venvs"
                    / "aligner"
                    / self.lock_hashes["DICOW_ALIGNER_VENV"]
                )
            },
        )
        self._fragment(
            "T2-reference.env",
            {
                "DICOW_REFERENCE_VENV": str(
                    self.dicow
                    / "venvs"
                    / "reference"
                    / self.lock_hashes["DICOW_REFERENCE_VENV"]
                )
            },
        )
        aligner = run_with_env.load_profile(self.env_file, "aligner", self.root / "checkout")
        reference = run_with_env.load_profile(self.env_file, "reference", self.root / "checkout")
        self.assertIn("DICOW_ALIGNER_VENV", aligner)
        self.assertNotIn("DICOW_REFERENCE_VENV", aligner)
        self.assertIn("DICOW_REFERENCE_VENV", reference)
        self.assertNotIn("DICOW_ALIGNER_VENV", reference)

    def test_exec_uses_a_clean_exact_environment(self):
        launcher = Path(run_with_env.__file__).resolve()
        env_value = os.environ.get("MACCHERONI_DICOW_RUN_ENV")
        if not env_value:
            self.skipTest("set MACCHERONI_DICOW_RUN_ENV for launcher integration")
        env_file = Path(env_value)
        probe = (
            "import json,os; print(json.dumps(dict(os.environ), sort_keys=True, "
            "separators=(',', ':')))"
        )
        parent = dict(os.environ)
        parent.update(
            {
                "HF_TOKEN": "must-not-leak",
                "HTTPS_PROXY": "must-not-leak",
                "DYLD_LIBRARY_PATH": "/must/not/leak",
                "HOME": "/must/not/leak",
                "PATH": "/must/not/leak",
            }
        )
        result = subprocess.run(
            [
                sys.executable,
                str(launcher),
                "--env-file",
                str(env_file),
                "--profile",
                "scoring",
                "--",
                sys.executable,
                "-c",
                probe,
            ],
            cwd=str(Path(__file__).resolve().parents[4]),
            env=parent,
            check=True,
            capture_output=True,
            text=True,
        )
        observed = json.loads(result.stdout)
        expected = run_with_env.load_profile(env_file, "scoring")
        # CoreFoundation may add this process-local locale hint after exec on macOS.
        observed.pop("__CF_USER_TEXT_ENCODING", None)
        self.assertEqual(observed, expected)

    def test_shell_cannot_restore_the_user_home_or_parent_path(self):
        launcher = Path(run_with_env.__file__).resolve()
        env_value = os.environ.get("MACCHERONI_DICOW_RUN_ENV")
        if not env_value:
            self.skipTest("set MACCHERONI_DICOW_RUN_ENV for launcher integration")
        env_file = Path(env_value)
        result = subprocess.run(
            [
                sys.executable,
                str(launcher),
                "--env-file",
                str(env_file),
                "--profile",
                "scoring",
                "--",
                "/bin/zsh",
                "-euc",
                "print -r -- $HOME; print -r -- $PATH",
            ],
            cwd=str(Path(__file__).resolve().parents[4]),
            env={"HOME": "/must/not/leak", "PATH": "/must/not/leak"},
            check=True,
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            result.stdout.splitlines(),
            [run_with_env.EMPTY_HOME, run_with_env.TOOL_PATH],
        )


if __name__ == "__main__":
    unittest.main()
