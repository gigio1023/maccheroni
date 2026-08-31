"""Adversarial tests for the DiCoW source acquisition boundary."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from benchmarks.scripts.dicow.reference import acquire_source


class Completed:
    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = stderr


class SourceAcquisitionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir="/private/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.tool = {
            "path": str(acquire_source.HF_LINK),
            "realpath": str(acquire_source.HF_REALPATH),
            "sha256": "a" * 64,
            "version": acquire_source.HF_VERSION,
        }
        self.runtime = {"runtime": "frozen-test-runtime"}

    def _fake_run(self, command, env, **kwargs):
        expected_env = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.output / "home"),
            "HF_HOME": str(self.output / "hf-home"),
            "HF_HUB_CACHE": str(self.output / "hf-cache"),
            "HF_ENDPOINT": "https://huggingface.co",
            "HF_HUB_OFFLINE": "0",
            "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1",
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "HF_HUB_DISABLE_XET": "1",
            "XDG_CACHE_HOME": str(self.output / "xdg-cache"),
            "XDG_CONFIG_HOME": str(self.output / "xdg-config"),
            "TMPDIR": str(self.output / "tmp"),
            "PYTHONNOUSERSITE": "1",
            "PYTHONUTF8": "1",
            "LC_ALL": "C",
        }
        self.assertEqual(expected_env, env)
        self.assertEqual(
            [
                str(acquire_source.HF_REALPATH),
                "download",
                "BUT-FIT/DiCoW_v3_MLC",
                *acquire_source.FILES,
                "--revision",
                "99c64e8dc409a158816e808a1ee556cdfd0af51c",
                "--local-dir",
                str(self.output / "snapshot"),
            ],
            command,
        )
        self.assertEqual(str(self.output / "home"), kwargs.get("cwd"))
        snapshot = self.output / "snapshot"
        for name in acquire_source.FILES:
            (snapshot / name).write_text(name + "\n", encoding="utf-8")
        self._write_hf_metadata()
        (self.output / "hf-home" / ".check_for_update_done").write_text("checked")
        (self.output / "hf-home" / ".agent_harnesses.json").write_text("{}")
        return Completed()

    def _write_hf_metadata(self):
        root = self.output / "snapshot" / ".cache" / "huggingface"
        (root / "download").mkdir(parents=True)
        (root / "CACHEDIR.TAG").write_text("tag")
        (root / ".gitignore").write_text("*")
        for name in acquire_source.FILES:
            (root / "download" / (name + ".metadata")).write_text(
                acquire_source.REVISION + "\n" + "a" * 40 + "\n1788076692.0\n"
            )

    def _acquire(self, runner=None):
        self.output = self.root / "t2-source-metadata"
        observations = [dict(self.tool), dict(self.tool)]
        with mock.patch.object(acquire_source, "observe_hf_tool", side_effect=observations), mock.patch.object(
            acquire_source, "observe_hf_runtime", side_effect=[self.runtime, self.runtime]
        ), mock.patch.object(
            acquire_source.subprocess, "run", side_effect=runner or self._fake_run
        ):
            acquire_source.acquire(self.output)

    def test_clean_environment_and_exact_command_are_sealed(self):
        poisoned = {
            "HTTP_PROXY": "http://bad",
            "https_proxy": "http://bad",
            "HF_TOKEN": "secret",
            "HUGGING_FACE_HUB_TOKEN": "secret",
            "HF_ENDPOINT": "https://bad.invalid",
            "HF_HUB_OFFLINE": "1",
            "TRANSFORMERS_CACHE": "/bad",
            "XDG_CACHE_HOME": "/bad",
            "REQUESTS_CA_BUNDLE": "/bad",
            "SSL_CERT_FILE": "/bad",
            "PYTHONPATH": "/bad",
            "DYLD_LIBRARY_PATH": "/bad",
            "LD_LIBRARY_PATH": "/bad",
        }
        with mock.patch.dict(os.environ, poisoned, clear=False):
            self._acquire()
        manifest = json.loads((self.output / "manifest.json").read_text())
        self.assertEqual(acquire_source.child_environment(self.output), manifest["child_env"])
        self.assertEqual(list(acquire_source.download_command(self.output)), manifest["command"])
        self.assertEqual(self.tool, manifest["hf_tool_pre"])
        self.assertEqual(manifest["hf_tool_pre"], manifest["hf_tool_post"])
        self.assertEqual(9, len(manifest["payloads"]))

    def test_download_command_uses_local_dir_without_rejected_cache_dir_pair(self):
        self.output = self.root / "t2-source-metadata"
        command = list(acquire_source.download_command(self.output))
        self.assertIn("--local-dir", command)
        self.assertNotIn("--cache-dir", command)
        self.assertEqual(str(self.output / "hf-cache"), acquire_source.child_environment(self.output)["HF_HUB_CACHE"])

    def test_output_must_be_absent(self):
        output = self.root / "t2-source-metadata"
        output.mkdir()
        with self.assertRaisesRegex(acquire_source.AcquisitionError, "absent"):
            acquire_source.acquire(output)

    def test_manifestless_canonical_output_is_never_adopted(self):
        output = self.root / "t2-source-metadata"
        (output / "snapshot").mkdir(parents=True)
        for name in acquire_source.FILES:
            (output / "snapshot" / name).write_text(name)
        with mock.patch.object(acquire_source, "observe_hf_tool", return_value=self.tool):
            with self.assertRaisesRegex(acquire_source.AcquisitionError, "absent"):
                acquire_source.acquire(output)

    def test_relative_output_is_rejected(self):
        with self.assertRaisesRegex(acquire_source.AcquisitionError, "absolute"):
            acquire_source.acquire(Path("relative"))

    def test_failed_download_never_writes_manifest(self):
        self.output = self.root / "t2-source-metadata"
        with mock.patch.object(acquire_source, "observe_hf_tool", side_effect=[self.tool, self.tool]), mock.patch.object(
            acquire_source, "observe_hf_runtime", side_effect=[self.runtime, self.runtime]
        ), mock.patch.object(
            acquire_source.subprocess, "run", return_value=Completed(2, stderr="failure")
        ):
            with self.assertRaisesRegex(acquire_source.AcquisitionError, "download failed"):
                acquire_source.acquire(self.output)
        self.assertTrue(self.output.exists())
        self.assertFalse((self.output / "manifest.json").exists())
        with self.assertRaisesRegex(acquire_source.AcquisitionError, "absent"):
            acquire_source.acquire(self.output)

    def test_tool_drift_never_writes_manifest(self):
        self.output = self.root / "t2-source-metadata"
        drifted = dict(self.tool, sha256="0" * 64)
        with mock.patch.object(acquire_source, "observe_hf_tool", side_effect=[self.tool, drifted]), mock.patch.object(
            acquire_source, "observe_hf_runtime", side_effect=[self.runtime, self.runtime]
        ), mock.patch.object(
            acquire_source.subprocess, "run", side_effect=self._fake_run
        ):
            with self.assertRaisesRegex(acquire_source.AcquisitionError, "changed"):
                acquire_source.acquire(self.output)
        self.assertFalse((self.output / "manifest.json").exists())

    def test_hf_runtime_drift_never_writes_manifest(self):
        self.output = self.root / "t2-source-metadata"
        drifted = {"runtime": "changed"}
        with mock.patch.object(acquire_source, "observe_hf_tool", side_effect=[self.tool, self.tool]), mock.patch.object(
            acquire_source, "observe_hf_runtime", side_effect=[self.runtime, drifted]
        ), mock.patch.object(acquire_source.subprocess, "run", side_effect=self._fake_run):
            with self.assertRaisesRegex(acquire_source.AcquisitionError, "runtime changed"):
                acquire_source.acquire(self.output)
        self.assertFalse((self.output / "manifest.json").exists())

    def test_missing_payload_is_rejected(self):
        def runner(command, env, **kwargs):
            (self.output / "snapshot" / acquire_source.FILES[0]).write_text("only one")
            self._write_hf_metadata()
            return Completed()

        with self.assertRaisesRegex(acquire_source.AcquisitionError, "missing"):
            self._acquire(runner)
        self.assertFalse((self.output / "manifest.json").exists())

    def test_additional_payload_is_rejected(self):
        def runner(command, env, **kwargs):
            result = self._fake_run(command, env, **kwargs)
            (self.output / "snapshot" / "weights.bin").write_bytes(b"bad")
            return result

        with self.assertRaisesRegex(acquire_source.AcquisitionError, "additional"):
            self._acquire(runner)

    def test_exact_hf_metadata_is_removed_before_seal(self):
        def runner(command, env, **kwargs):
            return self._fake_run(command, env, **kwargs)

        self._acquire(runner)
        manifest = json.loads((self.output / "manifest.json").read_text())
        self.assertTrue(manifest["hf_local_dir_metadata"]["removed_before_seal"])
        self.assertFalse((self.output / "snapshot" / ".cache").exists())

    def test_unexpected_hf_metadata_is_rejected(self):
        def runner(command, env, **kwargs):
            result = self._fake_run(command, env, **kwargs)
            root = self.output / "snapshot" / ".cache" / "huggingface"
            (root / "download" / "weights.bin").write_text("payload-like")
            return result

        with self.assertRaisesRegex(acquire_source.AcquisitionError, "exact known"):
            self._acquire(runner)

    def test_hf_metadata_symlink_is_rejected(self):
        def runner(command, env, **kwargs):
            snapshot = self.output / "snapshot"
            for name in acquire_source.FILES:
                (snapshot / name).write_text(name)
            root = self.output / "snapshot" / ".cache" / "huggingface"
            root.mkdir(parents=True)
            (root / "download").symlink_to("/tmp")
            return Completed()

        with self.assertRaisesRegex(acquire_source.AcquisitionError, "symlink"):
            self._acquire(runner)

    def test_failed_metadata_cleanup_never_seals_manifest(self):
        def runner(command, env, **kwargs):
            return self._fake_run(command, env, **kwargs)

        original_unlink = Path.unlink

        def failing_unlink(path, *args, **kwargs):
            if path.name.endswith(".metadata"):
                raise OSError("injected cleanup failure")
            return original_unlink(path, *args, **kwargs)

        with mock.patch.object(Path, "unlink", failing_unlink):
            with self.assertRaisesRegex(OSError, "cleanup failure"):
                self._acquire(runner)
        self.assertFalse((self.output / "manifest.json").exists())

    def test_payload_symlink_is_rejected(self):
        def runner(command, env, **kwargs):
            for name in acquire_source.FILES:
                path = self.output / "snapshot" / name
                if name == acquire_source.FILES[0]:
                    path.symlink_to("/etc/hosts")
                else:
                    path.write_text(name)
            self._write_hf_metadata()
            return Completed()

        with self.assertRaisesRegex(acquire_source.AcquisitionError, "symlink"):
            self._acquire(runner)

    def test_special_payload_file_is_rejected(self):
        def runner(command, env, **kwargs):
            for name in acquire_source.FILES:
                (self.output / "snapshot" / name).write_text(name)
            os.mkfifo(self.output / "snapshot" / "unexpected.fifo")
            self._write_hf_metadata()
            return Completed()

        with self.assertRaisesRegex(acquire_source.AcquisitionError, "special file"):
            self._acquire(runner)

    def test_missing_hf_metadata_is_rejected(self):
        def runner(command, env, **kwargs):
            for name in acquire_source.FILES:
                (self.output / "snapshot" / name).write_text(name)
            return Completed()

        with self.assertRaisesRegex(acquire_source.AcquisitionError, "metadata is missing"):
            self._acquire(runner)

    def test_nonfinite_hf_metadata_timestamp_is_rejected(self):
        def runner(command, env, **kwargs):
            result = self._fake_run(command, env, **kwargs)
            path = self.output / "snapshot" / ".cache" / "huggingface" / "download" / "config.json.metadata"
            path.write_text(acquire_source.REVISION + "\n" + "a" * 40 + "\nNaN\n")
            return result

        with self.assertRaisesRegex(acquire_source.AcquisitionError, "non-finite"):
            self._acquire(runner)

    def test_symlinked_output_parent_is_rejected(self):
        real = self.root / "real"
        real.mkdir()
        linked = self.root / "linked"
        linked.symlink_to(real, target_is_directory=True)
        with self.assertRaisesRegex(acquire_source.AcquisitionError, "symlink component"):
            acquire_source.acquire(linked / "t2-source-metadata")

    def test_verify_manifest_rejects_wrong_schema_and_drifted_sums(self):
        self._acquire()
        manifest_path = self.output / "manifest.json"
        manifest = json.loads(manifest_path.read_text())
        manifest["schema_version"] = "wrong"
        manifest_path.write_text(json.dumps(manifest))
        with mock.patch.object(acquire_source, "observe_hf_tool", return_value=self.tool), mock.patch.object(
            acquire_source, "observe_hf_runtime", return_value=self.runtime
        ):
            with self.assertRaisesRegex(acquire_source.AcquisitionError, "schema version"):
                acquire_source.verify_manifest(manifest_path)
        manifest["schema_version"] = "dicow-source-acquisition-v1"
        manifest_path.write_text(json.dumps(manifest))
        (self.output / "SHA256SUMS").write_text("0" * 64 + "  snapshot/config.json\n")
        with mock.patch.object(acquire_source, "observe_hf_tool", return_value=self.tool), mock.patch.object(
            acquire_source, "observe_hf_runtime", return_value=self.runtime
        ):
            with self.assertRaisesRegex(acquire_source.AcquisitionError, "SHA256SUMS"):
                acquire_source.verify_manifest(manifest_path)

    def test_verify_manifest_rejects_extra_root_payload(self):
        self._acquire()
        (self.output / "weights.bin").write_bytes(b"unexpected")
        with mock.patch.object(acquire_source, "observe_hf_tool", return_value=self.tool), mock.patch.object(
            acquire_source, "observe_hf_runtime", return_value=self.runtime
        ):
            with self.assertRaisesRegex(acquire_source.AcquisitionError, "root inventory"):
                acquire_source.verify_manifest(self.output / "manifest.json")

    def test_verify_manifest_rechecks_live_tool_and_payloads(self):
        self._acquire()
        with mock.patch.object(acquire_source, "observe_hf_tool", return_value=self.tool), mock.patch.object(
            acquire_source, "observe_hf_runtime", return_value=self.runtime
        ):
            acquire_source.verify_manifest(self.output / "manifest.json")
            (self.output / "snapshot" / acquire_source.FILES[0]).write_text("changed")
            with self.assertRaisesRegex(acquire_source.AcquisitionError, "differs"):
                acquire_source.verify_manifest(self.output / "manifest.json")

    def test_verify_manifest_rejects_live_tool_drift(self):
        self._acquire()
        drifted = dict(self.tool, version="9.9.9")
        with mock.patch.object(acquire_source, "observe_hf_tool", return_value=drifted), mock.patch.object(
            acquire_source, "observe_hf_runtime", return_value=self.runtime
        ):
            with self.assertRaisesRegex(acquire_source.AcquisitionError, "live hf tool"):
                acquire_source.verify_manifest(self.output / "manifest.json")

    def test_reference_verifier_rejects_forged_branch_fields(self):
        source_root = self.root / "t2-source-metadata" / "snapshot"
        source_root.mkdir(parents=True)
        evidence = source_root.parent / "reference-import.json"
        live = {
            "config_transformers_version": "4.42.0",
            "acquisition_manifest_sha256": "a" * 64,
            "acquisition_payloads": [],
            "reference_lock": {},
            "reference_venv": "/venv",
            "command": [],
            "child_env": {},
            "result": "ok",
            "traceback": None,
            "modules": [],
            "installed": {},
        }
        recorded = dict(live, schema_version="dicow-reference-import-v2", selected_branch="one_allowed_relock", fallback_relock_used=True)
        evidence.write_text(json.dumps(recorded))
        with mock.patch.object(acquire_source, "_reference_probe", return_value=live):
            with self.assertRaisesRegex(acquire_source.AcquisitionError, "branch evidence"):
                acquire_source.verify_reference(source_root, Path("/venv"), Path("/lock"), evidence)


class AlignerEnvironmentTests(unittest.TestCase):
    def test_korean_force_aligner_tokenization_path(self):
        venv = os.environ.get("DICOW_ALIGNER_VENV")
        if not venv:
            self.skipTest("run this smoke through the sealed aligner profile")
        self.assertEqual(Path(venv).resolve(), Path(sys.prefix).resolve())
        from mlx_audio.stt.models.qwen3_asr.qwen3_forced_aligner import ForceAlignProcessor
        from soynlp.tokenizer import LTokenizer

        processor = ForceAlignProcessor()
        words, encoded = processor.encode_timestamp("안녕하세요 세계", "Korean")
        self.assertIsInstance(processor.ko_tokenizer, LTokenizer)
        self.assertTrue(words)
        self.assertIn("<|audio_start|><|audio_pad|><|audio_end|>", encoded)
        self.assertTrue(encoded.endswith("<timestamp><timestamp>"))


if __name__ == "__main__":
    unittest.main()
