from __future__ import annotations

import contextlib
import base64
import csv
import hashlib
import io
import json
import os
import shutil
import struct
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from benchmarks.scripts.dicow.common import preflight
from benchmarks.scripts.dicow.reference import inspect


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True), encoding="utf-8")


def write_safetensors(path: Path, entries, payload: bytes) -> None:
    header = json.dumps(entries, separators=(",", ":")).encode("utf-8")
    path.write_bytes(struct.pack("<Q", len(header)) + header + payload)


class TemporaryTree(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()

    def tearDown(self) -> None:
        self.temporary.cleanup()


class SourceMetadataTests(TemporaryTree):
    def make_source(self) -> Path:
        root = self.root / "source"
        snapshot = root / "snapshot"
        snapshot.mkdir(parents=True)
        payloads = []
        for index, name in enumerate(inspect.SOURCE_FILES):
            path = snapshot / name
            data = ("{}:{}\n".format(index, name)).encode()
            path.write_bytes(data)
            path.chmod(0o644)
            payloads.append({
                "bytes": len(data),
                "mode": "0644",
                "path": "snapshot/{}".format(name),
                "sha256": hashlib.sha256(data).hexdigest(),
            })
        write_json(root / "manifest.json", {
            "schema_version": "dicow-source-acquisition-v1",
            "model_id": inspect.MODEL_PINS["dicow"]["model_id"],
            "revision": inspect.MODEL_PINS["dicow"]["revision"],
            "payloads": payloads,
        })
        return root

    def test_exact_nine_file_source_boundary(self) -> None:
        root = self.make_source()
        result = inspect.verify_source_metadata(root)
        self.assertEqual(set(result["payloads"]), set(inspect.SOURCE_FILES))

    def test_extra_source_file_is_rejected(self) -> None:
        root = self.make_source()
        (root / "snapshot" / "extra.py").write_text("pass\n")
        with self.assertRaisesRegex(inspect.InspectionError, "not exactly"):
            inspect.verify_source_metadata(root)

    def test_payload_mutation_is_rejected(self) -> None:
        root = self.make_source()
        (root / "snapshot" / "config.py").write_text("changed\n")
        with self.assertRaisesRegex(inspect.InspectionError, "differs"):
            inspect.verify_source_metadata(root)

    def test_symlinked_source_component_is_rejected(self) -> None:
        root = self.make_source()
        alias = self.root / "alias"
        alias.symlink_to(root, target_is_directory=True)
        with self.assertRaisesRegex(inspect.InspectionError, "symlink"):
            inspect.verify_source_metadata(alias)

    def test_duplicate_manifest_path_is_rejected(self) -> None:
        root = self.make_source()
        manifest = json.loads((root / "manifest.json").read_text())
        manifest["payloads"][-1] = dict(manifest["payloads"][0])
        write_json(root / "manifest.json", manifest)
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect.verify_source_metadata(root)
        self.assertIn(caught.exception.code, {"source_duplicate", "source_allowlist"})


class ConfigurationAndSourceTests(TemporaryTree):
    def make_snapshot(self) -> Path:
        root = self.root / "snapshot"
        root.mkdir()
        write_json(root / "config.json", {
            "d_model": 1280,
            "encoder_layers": 32,
            "decoder_layers": 4,
            "num_mel_bins": 128,
            "max_source_positions": 1500,
            "max_target_positions": 448,
            "vocab_size": 51866,
            "use_fddt": True,
            "use_initial_fddt": True,
            "fddt_is_diagonal": True,
            "fddt_bias_only": False,
            "fddt_use_silence": True,
            "fddt_use_target": True,
            "fddt_use_non_target": True,
            "fddt_use_overlap": True,
            "apply_fddt_to_n_layers": -1,
            "ctc_weight": 0.3,
        })
        write_json(root / "generation_config.json", {"num_beams": 1, "ctc_weight": 0})
        write_json(root / "preprocessor_config.json", {"feature_size": 128})
        (root / "encoder.py").write_text(
            "class FDDT:\n"
            " def __init__(self):\n"
            "  if self.ctc_weight > 0.0:\n"
            "   self.lm_head = nn.Linear(1, 2)\n"
            " def forward(self, inputs_embeds, embed_pos, stno_mask):\n"
            "  a = stno_mask[:, 0, ...] * self.silence_linear\n"
            "  b = stno_mask[:, 1, ...] * self.target_linear\n"
            "  c = stno_mask[:, 2, ...] * self.non_target_linear\n"
            "  d = stno_mask[:, 3, ...] * self.overlap_linear\n"
            "  inputs_embeds = self.initial_fddt(inputs_embeds, stno_mask)\n"
            "  hidden_states = inputs_embeds + embed_pos\n"
            "  for idx, encoder_layer in enumerate(self.layers):\n"
            "   hidden_states = self.fddts[idx](hidden_states, stno_mask)\n"
            "   layer_outputs = encoder_layer(hidden_states)\n"
            "  inter_output = hidden_states\n"
            "  if self.ctc_weight > 0.0:\n"
            "   logits = self.lm_head(inter_output)\n",
            encoding="utf-8",
        )
        (root / "generation.py").write_text(
            "class G:\n"
            " def f(self, generation_config):\n"
            "  if generation_config.ctc_weight > 0:\n"
            "   x = CTCRescorerLogitsProcessor()\n"
            "   processors.append(self.ctc_rescorer)\n",
            encoding="utf-8",
        )
        (root / "modeling_dicow.py").write_text(
            "def f(encoder_outputs):\n"
            " decoder_outputs = self.decoder(encoder_hidden_states=encoder_outputs.hidden_states[-1])\n"
            " return Result(value=decoder_outputs, encoder_logits=encoder_outputs.logits)\n",
            encoding="utf-8",
        )
        return root

    def test_configuration_and_static_source_pass(self) -> None:
        root = self.make_snapshot()
        self.assertEqual(inspect.verify_configuration(root)["graph"]["d_model"], 1280)
        self.assertTrue(inspect.inspect_static_sources(root)["soft_mask_arithmetic"])

    def test_configuration_drift_fails_closed(self) -> None:
        root = self.make_snapshot()
        value = json.loads((root / "config.json").read_text())
        value["vocab_size"] = 51865
        write_json(root / "config.json", value)
        with self.assertRaisesRegex(inspect.InspectionError, "vocab_size"):
            inspect.verify_configuration(root)

    def test_beam_search_is_rejected(self) -> None:
        root = self.make_snapshot()
        write_json(root / "generation_config.json", {"num_beams": 2, "ctc_weight": 0})
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect.verify_configuration(root)
        self.assertEqual(caught.exception.code, "beam_search")

    def test_channel_reordering_is_rejected(self) -> None:
        root = self.make_snapshot()
        path = root / "encoder.py"
        source = path.read_text().replace("b = stno_mask[:, 1, ...]", "b = stno_mask[:, 3, ...]").replace(
            "d = stno_mask[:, 3, ...]", "d = stno_mask[:, 1, ...]"
        )
        path.write_text(source)
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect.inspect_static_sources(root)
        self.assertEqual(caught.exception.code, "stno_channel_order")

    def test_custom_feature_function_is_rejected(self) -> None:
        root = self.make_snapshot()
        with (root / "encoder.py").open("a") as stream:
            stream.write("\ndef log_mel_spectrogram(x):\n return x\n")
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect.inspect_static_sources(root)
        self.assertEqual(caught.exception.code, "custom_features")

    def test_ctc_static_evidence_is_honest_blocker(self) -> None:
        root = self.make_snapshot()
        result = inspect.inspect_ctc_source(root)
        self.assertEqual(result["model_config_ctc_weight"], 0.3)
        self.assertEqual(result["generation_config_ctc_weight"], 0)
        self.assertTrue(result["auxiliary_branch_and_lm_head_execute"])
        self.assertFalse(result["generation_processor_present_at_weight_zero"])
        self.assertFalse(result["decoder_dataflow_consumes_encoder_logits"])
        self.assertFalse(result["zero_forward_calls_proven"])
        self.assertFalse(result["perturbation_bypass_proven"])
        self.assertFalse(result["frozen_rule"]["satisfied"])
        self.assertEqual(
            result["amendment_ready_evidence"]["decoder_logits_perturbation_invariance"],
            "unproven_until_T9",
        )
        self.assertFalse(result["amendment_ready_evidence"]["omission_authorized"])
        self.assertEqual(result["evidence_outcome"], "evidence_blocker")
        self.assertEqual(result["branch_verdict"], "revise")

    def test_ctc_source_does_not_invent_missing_proof(self) -> None:
        root = self.make_snapshot()
        (root / "generation.py").write_text("class G: pass\n")
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect.inspect_ctc_source(root)
        self.assertEqual(caught.exception.code, "ctc_static_source")

    def test_ctc_decoder_direct_logits_dataflow_is_rejected(self) -> None:
        root = self.make_snapshot()
        (root / "modeling_dicow.py").write_text(
            "def f(encoder_outputs):\n"
            " return self.decoder(encoder_hidden_states=encoder_outputs.hidden_states[-1], "
            "encoder_logits=encoder_outputs.logits)\n",
            encoding="utf-8",
        )
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect.inspect_ctc_source(root)
        self.assertEqual(caught.exception.code, "ctc_decoder_dataflow")

    def test_ctc_decoder_aliased_logits_dataflow_is_rejected(self) -> None:
        root = self.make_snapshot()
        (root / "modeling_dicow.py").write_text(
            "def f(encoder_outputs):\n"
            " ctc_alias = encoder_outputs.logits\n"
            " return self.decoder(encoder_hidden_states=encoder_outputs.hidden_states[-1], cache=ctc_alias)\n",
            encoding="utf-8",
        )
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect.inspect_ctc_source(root)
        self.assertEqual(caught.exception.code, "ctc_decoder_dataflow")


class MlxSymbolTests(TemporaryTree):
    SOURCE = (
        "class ModelDimensions:\n x = 1\n\n"
        "class MultiHeadAttention:\n x = 2\n\n"
        "class ResidualAttentionBlock:\n x = 3\n\n"
        "class TextDecoder:\n x = 4\n\n"
        "class Model:\n pass\n\n"
        "def decode():\n pass\n"
    )

    def make_pair(self):
        base = self.root / "base"
        conditional = self.root / "conditional"
        base.mkdir()
        conditional.mkdir()
        (base / "model.py").write_text(self.SOURCE)
        (conditional / "nested.py").write_text(self.SOURCE)
        return base, conditional

    def test_four_definitions_are_byte_identical(self) -> None:
        base, conditional = self.make_pair()
        result = inspect.compare_mlx_symbols(base, conditional)
        self.assertEqual(set(result["permitted_symbols"]), set(inspect.REUSED_MLX_SYMBOLS))
        self.assertIn("Model", result["forbidden_definitions_present_but_not_reused"])

    def test_single_byte_definition_mutation_is_rejected(self) -> None:
        base, conditional = self.make_pair()
        path = conditional / "nested.py"
        path.write_text(path.read_text().replace("x = 4", "x = 5"))
        comparison = inspect.compare_mlx_symbols(base, conditional)
        self.assertFalse(comparison["conditional_source_eligible"])
        self.assertEqual(comparison["mismatched_symbols"], ["TextDecoder"])
        self.assertEqual(
            inspect.validate_mlx_source_selection("mlx-audio-0.4.6", comparison),
            "mlx-audio-0.4.6",
        )
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect.validate_mlx_source_selection(
                "conditional-9cef816508e4fbdc35b4011bbfe1fc512b889701", comparison
            )
        self.assertEqual(caught.exception.code, "mlx_symbol_mutation")

    def test_duplicate_definition_is_rejected(self) -> None:
        base, conditional = self.make_pair()
        with (conditional / "nested.py").open("a") as stream:
            stream.write("\nclass TextDecoder:\n x = 4\n")
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect.compare_mlx_symbols(base, conditional)
        self.assertEqual(caught.exception.code, "mlx_symbol_cardinality")

    def test_missing_definition_is_rejected(self) -> None:
        base, conditional = self.make_pair()
        path = conditional / "nested.py"
        path.write_text(path.read_text().replace("class ModelDimensions:\n x = 1\n\n", ""))
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect.compare_mlx_symbols(base, conditional)
        self.assertEqual(caught.exception.code, "mlx_source_file_cardinality")

    def test_forbidden_reuse_declaration_is_rejected(self) -> None:
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect.validate_reuse_declaration((*inspect.REUSED_MLX_SYMBOLS, "decode"))
        self.assertEqual(caught.exception.code, "mlx_reuse_allowlist")

    def test_duplicate_reuse_declaration_is_rejected(self) -> None:
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect.validate_reuse_declaration((*inspect.REUSED_MLX_SYMBOLS, "TextDecoder"))
        self.assertEqual(caught.exception.code, "mlx_reuse_duplicate")

    def make_installed_mlx(self) -> Path:
        site = self.root / "site-packages"
        package = site / "mlx_audio"
        distribution = site / "mlx_audio-0.4.6.dist-info"
        package.mkdir(parents=True)
        distribution.mkdir()
        payload = b"VALUE = 1\n"
        (package / "model.py").write_bytes(payload)
        (distribution / "METADATA").write_text("Name: mlx-audio\nVersion: 0.4.6\n")
        digest = base64.urlsafe_b64encode(hashlib.sha256(payload).digest()).decode().rstrip("=")
        with (distribution / "RECORD").open("w", newline="") as stream:
            csv.writer(stream).writerows([
                ["mlx_audio/model.py", "sha256=" + digest, str(len(payload))],
                ["mlx_audio-0.4.6.dist-info/METADATA", "", ""],
                ["mlx_audio-0.4.6.dist-info/RECORD", "", ""],
            ])
        return package

    def test_installed_mlx_source_is_bound_to_wheel_record(self) -> None:
        package = self.make_installed_mlx()
        result = inspect.verify_mlx_base_install(package)
        self.assertEqual(result["record_bound_source_file_count"], 1)

    def test_installed_mlx_source_mutation_is_rejected(self) -> None:
        package = self.make_installed_mlx()
        (package / "model.py").write_text("VALUE = 2\n")
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect.verify_mlx_base_install(package)
        self.assertEqual(caught.exception.code, "mlx_base_record")


class SafetensorsTests(TemporaryTree):
    def test_valid_header_counts_parameters_and_offsets(self) -> None:
        path = self.root / "model.safetensors"
        entries = {
            "a": {"dtype": "F32", "shape": [2], "data_offsets": [0, 8]},
            "b": {"dtype": "I16", "shape": [2, 2], "data_offsets": [8, 16]},
        }
        write_safetensors(path, entries, b"\0" * 16)
        result = inspect.read_safetensors_header(path)
        self.assertEqual(result["tensor_count"], 2)
        self.assertEqual(result["parameter_count"], 6)

    def test_gap_is_rejected(self) -> None:
        path = self.root / "model.safetensors"
        entries = {"a": {"dtype": "F32", "shape": [1], "data_offsets": [4, 8]}}
        write_safetensors(path, entries, b"\0" * 8)
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect.read_safetensors_header(path)
        self.assertEqual(caught.exception.code, "tensor_layout")

    def test_dtype_size_mismatch_is_rejected(self) -> None:
        path = self.root / "model.safetensors"
        entries = {"a": {"dtype": "F32", "shape": [2], "data_offsets": [0, 4]}}
        write_safetensors(path, entries, b"\0" * 4)
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect.read_safetensors_header(path)
        self.assertEqual(caught.exception.code, "tensor_payload")

    def test_trailing_payload_is_rejected(self) -> None:
        path = self.root / "model.safetensors"
        entries = {"a": {"dtype": "F32", "shape": [1], "data_offsets": [0, 4]}}
        write_safetensors(path, entries, b"\0" * 8)
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect.read_safetensors_header(path)
        self.assertEqual(caught.exception.code, "tensor_layout")

    def test_duplicate_header_key_is_rejected(self) -> None:
        path = self.root / "model.safetensors"
        header = b'{"a":{"dtype":"F32","shape":[1],"data_offsets":[0,4]},"a":{"dtype":"F32","shape":[1],"data_offsets":[0,4]}}'
        path.write_bytes(struct.pack("<Q", len(header)) + header + b"\0" * 4)
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect.read_safetensors_header(path)
        self.assertEqual(caught.exception.code, "safetensors_header")


class ArchiveTests(TemporaryTree):
    def make_archive(self, members) -> Path:
        path = self.root / "speech.tar.gz"
        with tarfile.open(path, "w:gz") as archive:
            for name, kind, mode in members:
                info = tarfile.TarInfo(name)
                info.mode = mode
                if kind == "file":
                    payload = b"binary"
                    info.size = len(payload)
                    archive.addfile(info, io.BytesIO(payload))
                elif kind == "symlink":
                    info.type = tarfile.SYMTYPE
                    info.linkname = "target"
                    archive.addfile(info)
                else:
                    info.type = tarfile.DIRTYPE
                    archive.addfile(info)
        return path

    def test_safe_archive_has_one_executable(self) -> None:
        path = self.make_archive([("bundle", "dir", 0o755), ("bundle/speech", "file", 0o755)])
        result = inspect.safe_tar_inventory(path)
        self.assertEqual(result[-1]["path"], "bundle/speech")

    def test_traversal_is_rejected(self) -> None:
        path = self.make_archive([("../speech", "file", 0o755)])
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect.safe_tar_inventory(path)
        self.assertEqual(caught.exception.code, "unsafe_archive_path")

    def test_symlink_is_rejected(self) -> None:
        path = self.make_archive([("speech", "file", 0o755), ("alias", "symlink", 0o777)])
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect.safe_tar_inventory(path)
        self.assertEqual(caught.exception.code, "unsafe_archive_type")

    def test_non_executable_speech_is_rejected(self) -> None:
        path = self.make_archive([("speech", "file", 0o644)])
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect.safe_tar_inventory(path)
        self.assertEqual(caught.exception.code, "archive_executable")


class ResourceInventoryTests(TemporaryTree):
    def test_community_exact_allowlist_and_hash(self) -> None:
        root = self.root / "community"
        root.mkdir()
        files = {"LICENSE": (b"license", hashlib.sha256(b"license").hexdigest())}
        (root / "LICENSE").write_bytes(b"license")
        with mock.patch.object(inspect, "COMMUNITY_FILES", {"LICENSE": (7, files["LICENSE"][1])}):
            result = inspect.verify_community_inventory(root)
        self.assertEqual(result["files"]["LICENSE"]["bytes"], 7)

    def test_community_extra_file_is_rejected(self) -> None:
        root = self.root / "community"
        root.mkdir()
        (root / "LICENSE").write_bytes(b"license")
        (root / "extra").write_bytes(b"x")
        digest = hashlib.sha256(b"license").hexdigest()
        with mock.patch.object(inspect, "COMMUNITY_FILES", {"LICENSE": (7, digest)}):
            with self.assertRaises(inspect.InspectionError) as caught:
                inspect.verify_community_inventory(root)
        self.assertEqual(caught.exception.code, "community_allowlist")

    def test_fleurs_exact_paths_and_sizes(self) -> None:
        root = self.root / "fleurs"
        path = root / "parquet-data/en_us/test.parquet"
        path.parent.mkdir(parents=True)
        path.write_bytes(b"123")
        with mock.patch.object(inspect, "FLEURS_FILES", {"parquet-data/en_us/test.parquet": 3}):
            result = inspect.verify_fleurs_inventory(root)
        self.assertEqual(result["file_count"], 3)

    def test_fleurs_wrong_size_is_rejected(self) -> None:
        root = self.root / "fleurs"
        path = root / "parquet-data/en_us/test.parquet"
        path.parent.mkdir(parents=True)
        path.write_bytes(b"123")
        with mock.patch.object(inspect, "FLEURS_FILES", {"parquet-data/en_us/test.parquet": 4}):
            with self.assertRaises(inspect.InspectionError) as caught:
                inspect.verify_fleurs_inventory(root)
        self.assertEqual(caught.exception.code, "fleurs_size")


class LicenseTests(TemporaryTree):
    def make_run(self) -> Path:
        run = self.root / "license"
        run.mkdir()
        evidence_root = run / "evidence"
        evidence_root.mkdir()
        evidence = []
        for index, role in enumerate(inspect.LICENSE_EVIDENCE_ROLES):
            payload = ("{}:{}".format(index, role)).encode()
            relative = "evidence/{:02d}-{}.txt".format(index, role)
            (run / relative).write_bytes(payload)
            evidence.append({
                "bytes": len(payload),
                "path": relative,
                "role": role,
                "sha256": hashlib.sha256(payload).hexdigest(),
                "source": "pinned-{}".format(role),
            })
        write_json(run / "canonical.json", {
            "schema_version": "dicow-license-audit-v1",
            "model_id": inspect.MODEL_PINS["dicow"]["model_id"],
            "revision": inspect.MODEL_PINS["dicow"]["revision"],
            "license_field_conflict": "cc_by_4_0_vs_apache_2_0",
            "repository_license_file": "absent",
            "local_derivative_allowed": "allowed",
            "redistribution_or_bundling_allowed": "ambiguous",
            "training_list_findings": {"mlc_slm": "unknown", "in1009": "excluded", "hike": "unknown"},
            "fixture_demotions": [],
            "author_question": {"drafted": True, "sent": False},
            "evidence": evidence,
        })
        return run

    def test_verify_license_is_read_only(self) -> None:
        run = self.make_run()
        before = {path: (path.stat().st_mtime_ns, path.read_bytes()) for path in run.rglob("*") if path.is_file()}
        result = inspect.verify_license(run)
        after = {path: (path.stat().st_mtime_ns, path.read_bytes()) for path in run.rglob("*") if path.is_file()}
        self.assertEqual(before, after)
        self.assertEqual(result["training_list_findings"]["in1009"], "excluded")
        self.assertEqual(result["redistribution_or_bundling_allowed"], "ambiguous")

    def test_forged_license_evidence_is_rejected(self) -> None:
        run = self.make_run()
        first = sorted((run / "evidence").iterdir())[0]
        first.write_bytes(b"other")
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect.verify_license(run)
        self.assertEqual(caught.exception.code, "license_hash")

    def test_missing_license_evidence_role_is_rejected(self) -> None:
        run = self.make_run()
        manifest = json.loads((run / "canonical.json").read_text())
        manifest["evidence"].pop()
        write_json(run / "canonical.json", manifest)
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect.verify_license(run)
        self.assertEqual(caught.exception.code, "license_evidence")

    def test_sent_author_question_is_rejected(self) -> None:
        run = self.make_run()
        manifest = json.loads((run / "canonical.json").read_text())
        manifest["author_question"]["sent"] = True
        write_json(run / "canonical.json", manifest)
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect.verify_license(run)
        self.assertEqual(caught.exception.code, "author_question")

    def test_combined_license_decision_is_rejected(self) -> None:
        run = self.make_run()
        manifest = json.loads((run / "canonical.json").read_text())
        manifest["local_derivative_work"] = manifest.pop("local_derivative_allowed")
        write_json(run / "canonical.json", manifest)
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect.verify_license(run)
        self.assertEqual(caught.exception.code, "license_schema")


class WorkingSetTests(TemporaryTree):
    def ledger(self, mlx_entry):
        return {
            "schema_version": "dicow-e0-future-resource-ledger-v2",
            "components": [
                mlx_entry,
                {
                    "name": "control_named_goldens",
                    "category": "named_golden",
                    "final_path": str(self.root / "control"),
                    "expected_record": None,
                    "staging_group": None,
                    "record_kind": "immutable_artifact",
                    "provenance": {},
                    "derivation": {},
                },
                {
                    "name": "dicow_named_goldens",
                    "category": "named_golden",
                    "final_path": str(self.root / "dicow"),
                    "expected_record": None,
                    "staging_group": None,
                    "record_kind": "immutable_artifact",
                    "provenance": {},
                    "derivation": {},
                },
            ],
        }

    def replay(self, preflight, entry):
        ledger_path = self.root / "e0-resource-ledger.json"
        write_json(ledger_path, self.ledger(entry))
        ledger_path.chmod(0o444)
        return inspect._future_resource_components(
            preflight,
            ledger_path,
            preflight.file_record(ledger_path, immutable=True),
            expected_run_id="test-run",
            run_root=self.root,
        )

    def test_absent_mlx_expected_record_is_a_distinct_blocker(self) -> None:
        from benchmarks.scripts.dicow.common import preflight
        entry = {
            "name": "mlx_environment",
            "category": "environment",
            "final_path": str(self.root / "mlx"),
            "staging_group": None,
            "record_kind": "sealed_venv",
            "provenance": {},
            "derivation": {},
        }
        with self.assertRaises(inspect.InspectionError) as caught:
            self.replay(preflight, entry)
        self.assertEqual(caught.exception.code, "working_set_unresolved")

    def test_self_asserted_working_set_value_is_not_accepted_from_ledger(self) -> None:
        from benchmarks.scripts.dicow.common import preflight
        entry = {
            "name": "mlx_environment",
            "category": "environment",
            "final_path": str(self.root / "mlx"),
            "expected_record": {"kind": "tree"},
            "staging_group": None,
            "record_kind": "sealed_venv",
            "provenance": {},
            "derivation": {},
            "max_recommended_working_set_size": 123,
        }
        with self.assertRaises(inspect.InspectionError) as caught:
            self.replay(preflight, entry)
        self.assertEqual(caught.exception.code, "resource_formula_unresolved")

    def test_absent_mlx_environment_cannot_claim_a_working_set(self) -> None:
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect._probe_working_set(self.root / "missing")
        self.assertEqual(caught.exception.code, "working_set_unresolved")

    def test_stale_replayed_working_set_is_rejected(self) -> None:
        expected = {"mlx_device_info": {"max_recommended_working_set_size": 100}, "other": 1}
        actual = {"mlx_device_info": {"max_recommended_working_set_size": 101}, "other": 1}
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect._verify_host_replay(expected, actual)
        self.assertEqual(caught.exception.code, "working_set_stale")

    def test_working_set_is_recomputed_from_pinned_environment(self) -> None:
        environment = self.root / "mlx"
        python = environment / "bin" / "python"
        python.parent.mkdir(parents=True)
        python.write_text("#!/bin/sh\nexit 1\n")
        python.chmod(0o555)
        device = {
            "architecture": "applegpu_test",
            "device_name": "Apple Test",
            "max_buffer_length": 10,
            "max_recommended_working_set_size": 20,
            "memory_size": 30,
            "resource_limit": 40,
        }
        completed = mock.Mock(returncode=0, stdout=json.dumps(device).encode(), stderr=b"")
        with mock.patch.object(inspect.subprocess, "run", return_value=completed) as run:
            self.assertEqual(inspect._probe_working_set(environment), device)
        self.assertEqual(run.call_args.args[0][0], str(python))
        self.assertIn("-B", run.call_args.args[0])
        self.assertIn("mx.device_info()", run.call_args.args[0][-1])
        args = run.call_args.args[0]
        self.assertEqual(args[args.index("-X") + 1], "pycache_prefix=/private/var/empty/maccheroni-pycache")
        self.assertNotIn("PYTHONPYCACHEPREFIX", run.call_args.kwargs["env"])


class RuntimeBindingTests(TemporaryTree):
    def make_runtime(self):
        from benchmarks.scripts.dicow.common import preflight
        aligner = self.root / "aligner"
        community = self.root / "community"
        runtime = self.root / "runtime"
        for directory, name in ((aligner, "model.bin"), (community, "weights.bin")):
            directory.mkdir()
            (directory / name).write_bytes(name.encode())
            (directory / name).chmod(0o444)
            directory.chmod(0o555)
        runtime.mkdir()
        binary = runtime / "speech"
        binary.write_bytes(b"binary")
        binary.chmod(0o555)
        runtime.chmod(0o555)
        sandbox = self.root / "deny-network.sb"
        sandbox.write_bytes(b"(version 1)\n")
        fragment = self.root / "T9-diarizer.env"
        fragment.write_text(
            "DICOW_SPEECH_BIN={}\nDICOW_SPEECH_BIN_RELATIVE_PATH=speech\n".format(binary)
        )
        fragment.chmod(0o444)
        aligner_record = preflight.artifact_record(aligner, immutable=True)
        community_record = preflight.artifact_record(community, immutable=True)
        bindings = {
            "aligner": {
                "model_id": inspect.MODEL_PINS["reference_aligner"]["model_id"],
                "model_revision": inspect.MODEL_PINS["reference_aligner"]["revision"],
                "snapshot": {"path": str(aligner), "record": aligner_record},
            },
            "community1": {
                "model_id": inspect.MODEL_PINS["diarizer"]["model_id"],
                "model_revision": inspect.MODEL_PINS["diarizer"]["revision"],
                "binary": {
                    "path": str(binary),
                    "record": preflight.artifact_record(binary, immutable=True),
                },
                "model_tree": {"path": str(community), "record": community_record},
                "sandbox_profile": {
                    "path": str(sandbox),
                    "record": preflight.artifact_record(sandbox),
                },
            },
        }
        policy = preflight.ResourcePolicy(
            (
                preflight.ResourceComponent("aligner_snapshot", "source", 1, aligner, aligner_record),
                preflight.ResourceComponent("community_snapshot", "source", 1, community, community_record),
            ),
            ("aligner_snapshot", "community_snapshot"),
        )
        promotions = {"speech-runtime": str(runtime), "T9-diarizer.env": str(fragment)}
        return preflight, bindings, policy, promotions

    def test_runtime_bindings_replay_exact_t9_objects(self) -> None:
        preflight, bindings, policy, promotions = self.make_runtime()
        result = inspect._verify_runtime_bindings(preflight, bindings, policy, promotions)
        self.assertEqual(result["community1"]["binary"]["path"], str(self.root / "runtime" / "speech"))

    def test_runtime_binding_cannot_move_binary_outside_promoted_runtime(self) -> None:
        preflight, bindings, policy, promotions = self.make_runtime()
        outside = self.root / "outside"
        outside.write_bytes(b"binary")
        outside.chmod(0o555)
        bindings["community1"]["binary"] = {
            "path": str(outside),
            "record": preflight.artifact_record(outside, immutable=True),
        }
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect._verify_runtime_bindings(preflight, bindings, policy, promotions)
        self.assertEqual(caught.exception.code, "runtime_path")


class ResourceLedgerReplayTests(TemporaryTree):
    def make_replay(self):
        from benchmarks.scripts.dicow.common import preflight
        run = self.root / "run"
        output = run / "e0-preflight"
        output.mkdir(parents=True)
        ledger = run / "e0-resource-ledger.json"
        ledger.write_text("{}\n")
        ledger.chmod(0o444)
        component = preflight.ResourceComponent(
            "mlx_environment",
            "environment",
            10,
            self.root / "mlx",
            expected_record={"path": str(self.root / "mlx"), "sha256": "0" * 64, "bytes": 10, "mode": "0755"},
            record_kind="sealed_venv",
        )
        policy = preflight.ResourcePolicy((component,), (component.name,))
        canonical = {
            "future_resource_ledger": {
                "path": str(ledger),
                "record": preflight.file_record(ledger, immutable=True),
            },
        }
        return preflight, output, canonical, component, policy

    def test_verify_rederives_future_components_from_immutable_t8r_ledger(self) -> None:
        preflight, output, canonical, component, policy = self.make_replay()
        with mock.patch.object(inspect, "_future_resource_components", return_value=(component,)) as replay:
            result = inspect._verify_future_resource_replay(preflight, output, canonical, policy, "test-run")
        self.assertEqual(result["components"][0]["declared_bytes"], 10)
        self.assertEqual(replay.call_args.kwargs["expected_run_id"], "test-run")
        self.assertEqual(replay.call_args.kwargs["run_root"], output.parent)

    def test_canonical_declared_bytes_cannot_self_replay_over_t8r_derivation(self) -> None:
        preflight, output, canonical, component, _policy = self.make_replay()
        forged = preflight.ResourceComponent(
            component.name,
            component.category,
            9,
            component.final_path,
            expected_record=component.expected_record,
            record_kind=component.record_kind,
        )
        policy = preflight.ResourcePolicy((forged,), (forged.name,))
        with mock.patch.object(inspect, "_future_resource_components", return_value=(component,)):
            with self.assertRaises(inspect.InspectionError) as caught:
                inspect._verify_future_resource_replay(preflight, output, canonical, policy, "test-run")
        self.assertEqual(caught.exception.code, "resource_ledger_replay")


class PreparedManifestTests(TemporaryTree):
    def canonical(self, output: Path):
        fingerprint = "a" * 64
        return {
            "schema_version": "dicow-e0-preflight-v1",
            "run_id": "test-run",
            "run_root": str(output.parent),
            "attempt_fingerprint": fingerprint,
            "attempt_root": str(output / "attempts" / (fingerprint + "-0001")),
            "paths": {},
            "mlx_reused_symbols": list(inspect.REUSED_MLX_SYMBOLS),
            "mlx_implementation_source": "mlx-audio-0.4.6",
            "inspection_sha256": "b" * 64,
            "inspection_outcome": "evidence_blocker",
            "inspection_verdict": "revise",
            "inspection_blocker": "ctc_zero_call_rule_unsatisfied",
            "runtime_bindings": {},
            "resource": {},
            "resource_policy": {},
            "future_resource_ledger": {},
            "host": {},
            "acquisitions": {},
            "promotion_records": {},
            "promotion_final_paths": {},
            "promotion_staged_paths": {},
        }

    def test_canonical_requires_every_exact_field(self) -> None:
        output = self.root / "e0-preflight"
        canonical = self.canonical(output)
        del canonical["inspection_sha256"]
        write_json(output / "canonical.json", canonical)
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect._prepared_manifest(output)
        self.assertEqual(caught.exception.code, "e0_schema")

    def test_canonical_cannot_demote_the_frozen_ctc_blocker(self) -> None:
        output = self.root / "e0-preflight"
        canonical = self.canonical(output)
        canonical["inspection_outcome"] = "pass"
        write_json(output / "canonical.json", canonical)
        with self.assertRaises(inspect.InspectionError) as caught:
            inspect._prepared_manifest(output)
        self.assertEqual(caught.exception.code, "e0_schema")


class LauncherBindingTests(TemporaryTree):
    def fixture(self):
        run_root = self.root / "run"
        output = run_root / "e0-preflight"
        output.mkdir(parents=True)
        hf_home = self.root / "hf-home"
        speech_cache = self.root / "speech-cache"
        speech_runtime = self.root / "speech-runtime"
        fingerprint_payload = {"source": "current"}
        fingerprint = inspect._attempt_fingerprint(fingerprint_payload)
        attempt = output / "attempts" / (fingerprint + "-0001")
        roots = {
            "run_root": run_root,
            "hf_home": hf_home,
            "speech_cache": speech_cache,
            "speech_runtime": speech_runtime,
            "cache_root": self.root,
            "t9_fragment": run_root / "env.d" / "T9-diarizer.env",
        }
        canonical = {
            "run_root": str(run_root),
            "attempt_root": str(attempt),
            "attempt_fingerprint": fingerprint,
            "promotion_final_paths": {
                "hf-home": str(hf_home),
                "speech-cache": str(speech_cache),
                "speech-runtime": str(speech_runtime),
                "T9-diarizer.env": str(roots["t9_fragment"]),
            },
            "promotion_staged_paths": {
                name: str(attempt / "promotions" / name)
                for name in ("hf-home", "speech-cache", "speech-runtime", "T9-diarizer.env")
            },
            "paths": {
                "dicow_snapshot": str(inspect._hf_snapshot_path(
                    hf_home, inspect.MODEL_PINS["dicow"]["model_id"], inspect.MODEL_PINS["dicow"]["revision"]
                )),
                "t2_source_metadata": str(run_root / "t2-source-metadata"),
                "mlx_base_source": str(self.root / "mlx-base"),
                "mlx_conditional_source": str(attempt / "sources" / "mlx-audio-conditional"),
                "community_snapshot": str(speech_cache / "qwen3-speech" / "models" / "aufklarer" / "Pyannote-Community-1-CoreML"),
                "fleurs_snapshot": str(inspect._hf_snapshot_path(
                    hf_home, inspect.MODEL_PINS["fleurs"]["model_id"], inspect.MODEL_PINS["fleurs"]["revision"], "dataset"
                )),
                "speech_archive": str(attempt / "evidence" / inspect.MODEL_PINS["diarizer"]["archive"]["name"]),
            },
        }
        environment = {
            "DICOW_RUN_ROOT": str(run_root),
            "HF_HOME": str(hf_home),
            "DICOW_SPEECH_CACHE": str(speech_cache),
            "DICOW_SPEECH_RUNTIME_ROOT": str(speech_runtime),
            "DICOW_CACHE_ROOT": str(self.root),
        }
        return output, canonical, environment, fingerprint_payload

    def test_selector_cannot_redirect_a_launcher_fixed_final_root(self) -> None:
        from benchmarks.scripts.dicow.common import preflight
        output, canonical, environment, _ = self.fixture()
        canonical["promotion_final_paths"]["hf-home"] = str(self.root / "other-hf")
        with mock.patch.dict(os.environ, environment, clear=True):
            with self.assertRaises(inspect.InspectionError) as caught:
                inspect._verify_launcher_bindings(preflight, output, canonical)
        self.assertEqual(caught.exception.code, "run_binding")

    def test_stale_source_fingerprint_is_rejected(self) -> None:
        from benchmarks.scripts.dicow.common import preflight
        output, canonical, environment, _ = self.fixture()
        with mock.patch.dict(os.environ, environment, clear=True), \
             mock.patch.object(inspect, "_find_mlx_base_source", return_value=self.root / "mlx-base"), \
             mock.patch.object(inspect, "_attempt_fingerprint_payload", return_value={"source": "changed"}):
            with self.assertRaises(inspect.InspectionError) as caught:
                inspect._verify_launcher_bindings(preflight, output, canonical)
        self.assertEqual(caught.exception.code, "attempt_fingerprint")

    def test_fingerprint_payload_rehashes_both_current_implementations(self) -> None:
        from benchmarks.scripts.dicow.common import preflight
        output, _, _, _ = self.fixture()
        roots = {
            "run_root": output.parent,
            "hf_home": self.root / "hf-home",
            "speech_cache": self.root / "speech-cache",
            "speech_runtime": self.root / "speech-runtime",
            "cache_root": self.root,
            "t9_fragment": output.parent / "env.d" / "T9-diarizer.env",
        }
        with mock.patch.object(inspect, "_sha256", return_value="c" * 64) as digest:
            payload = inspect._attempt_fingerprint_payload(preflight, output.parent, roots)
        labels = [call.args[1] for call in digest.call_args_list]
        self.assertIn("inspect source", labels)
        self.assertIn("preflight source", labels)
        self.assertEqual(payload["runtime_roots"]["hf_home"], str(roots["hf_home"]))


class VerifyOrchestrationTests(TemporaryTree):
    def test_verify_builds_policy_before_independent_resource_replays(self) -> None:
        from benchmarks.scripts.dicow.common import preflight
        output = self.root / "run" / "e0-preflight"
        output.mkdir(parents=True)
        run_root = output.parent
        hf_home = self.root / "hf-home"
        speech_cache = self.root / "speech-cache"
        speech_runtime = self.root / "speech-runtime"
        fingerprint = hashlib.sha256(b"{}").hexdigest()
        attempt_root = output / "attempts" / (fingerprint + "-0001")
        names = ("hf-home", "speech-cache", "speech-runtime", "T9-diarizer.env")
        paths = {
            "dicow_snapshot": str(inspect._hf_snapshot_path(
                hf_home, inspect.MODEL_PINS["dicow"]["model_id"], inspect.MODEL_PINS["dicow"]["revision"]
            )),
            "t2_source_metadata": str(run_root / "t2-source-metadata"),
            "mlx_base_source": str(self.root / "mlx-base"),
            "mlx_conditional_source": str(attempt_root / "sources" / "mlx-audio-conditional"),
            "community_snapshot": str(speech_cache / "qwen3-speech" / "models" / "aufklarer" / "Pyannote-Community-1-CoreML"),
            "fleurs_snapshot": str(inspect._hf_snapshot_path(
                hf_home, inspect.MODEL_PINS["fleurs"]["model_id"], inspect.MODEL_PINS["fleurs"]["revision"], "dataset"
            )),
            "speech_archive": str(attempt_root / "evidence" / inspect.MODEL_PINS["diarizer"]["archive"]["name"]),
        }
        canonical = {
            "run_id": "test-run",
            "run_root": str(output.parent),
            "promotion_records": {name: {} for name in names},
            "promotion_final_paths": {
                "hf-home": str(hf_home),
                "speech-cache": str(speech_cache),
                "speech-runtime": str(speech_runtime),
                "T9-diarizer.env": str(run_root / "env.d" / "T9-diarizer.env"),
            },
            "promotion_staged_paths": {
                name: str(attempt_root / "promotions" / name) for name in names
            },
            "attempt_root": str(attempt_root),
            "attempt_fingerprint": fingerprint,
            "resource_policy": {},
            "paths": paths,
            "mlx_reused_symbols": list(inspect.REUSED_MLX_SYMBOLS),
            "mlx_implementation_source": "mlx-audio-0.4.6",
            "inspection_sha256": hashlib.sha256(b"{}").hexdigest(),
            "host": {},
            "runtime_bindings": {},
        }
        mlx_component = preflight.ResourceComponent(
            "mlx_environment", "environment", 1, self.root / "mlx-env",
            expected_record={"path": str(self.root / "mlx-env"), "sha256": "0" * 64, "bytes": 1, "mode": "0755"},
            record_kind="sealed_venv",
        )
        policy = preflight.ResourcePolicy((mlx_component,), (mlx_component.name,))
        environment = {
            "DICOW_RUN_ID": "test-run",
            "DICOW_RUN_ROOT": str(run_root),
            "DICOW_CACHE_ROOT": str(self.root),
            "HF_HOME": str(hf_home),
            "DICOW_SPEECH_CACHE": str(speech_cache),
            "DICOW_SPEECH_RUNTIME_ROOT": str(speech_runtime),
        }
        with mock.patch.dict(os.environ, environment, clear=False), \
             mock.patch.object(inspect, "_prepared_manifest", return_value=canonical), \
             mock.patch.object(inspect, "_find_mlx_base_source", return_value=self.root / "mlx-base"), \
             mock.patch.object(inspect, "_attempt_fingerprint_payload", return_value={}), \
             mock.patch.object(preflight, "verify_promotion"), \
             mock.patch.object(inspect, "_resource_policy_from_spec", return_value=policy) as build_policy, \
             mock.patch.object(inspect, "_verify_future_resource_replay", return_value={}) as future_replay, \
             mock.patch.object(inspect, "_verify_known_resource_replay", return_value={}), \
             mock.patch.object(preflight, "calculate_required_free_bytes", return_value={}), \
             mock.patch.object(inspect, "_host_facts", return_value={}), \
             mock.patch.object(inspect, "_verify_host_replay"), \
             mock.patch.object(inspect, "_reject_symlink_components"), \
             mock.patch.object(inspect, "_verify_runtime_bindings", return_value={}), \
             mock.patch.object(inspect, "_inspection_from_paths", return_value={}):
            inspect.verify(output)
        self.assertTrue(build_policy.called)
        self.assertIs(future_replay.call_args.args[3], policy)


class CliTests(TemporaryTree):
    def write_task_states(self, run: Path, cache: Path) -> None:
        from benchmarks.scripts.dicow.run_with_env import sealed_path_record
        records = {}
        for name in ("scoring", "aligner", "reference"):
            environment = cache / (name + "-venv")
            (environment / "bin").mkdir(parents=True)
            (environment / "bin" / "python").write_bytes(name.encode())
            records[name] = sealed_path_record(environment, "venv")
        write_json(run / "task-state" / "T1.json", {
            "schema_version": "dicow-task-state-v1",
            "task": "T1",
            "state": "done",
            "branch_disposition": "executed",
            "run_id": "test-run",
            "sealed_paths": {"DICOW_SCORING_VENV": records["scoring"]},
        })
        write_json(run / "task-state" / "T2.json", {
            "schema_version": "dicow-task-state-v1",
            "task": "T2",
            "state": "done",
            "branch_disposition": "executed",
            "run_id": "test-run",
            "sealed_paths": {
                "DICOW_ALIGNER_VENV": records["aligner"],
                "DICOW_REFERENCE_VENV": records["reference"],
            },
        })
        (run / "task-state" / "T1.json").chmod(0o444)
        (run / "task-state" / "T2.json").chmod(0o444)

    def test_verify_missing_output_emits_typed_json(self) -> None:
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            code = inspect.main(["verify", "--output", str(self.root / "missing")])
        payload = json.loads(stdout.getvalue())
        self.assertEqual(code, 2)
        self.assertFalse(payload["ok"])
        self.assertEqual(payload["error"]["evidence_outcome"], "evidence_blocker")
        self.assertEqual(payload["error"]["branch_verdict"], "revise")

    def test_prepare_refuses_preexisting_output_without_network_or_mutation(self) -> None:
        run = self.root / "run"
        output = run / "e0-preflight"
        (run / "env.d").mkdir(parents=True)
        output.mkdir()
        marker = output / "marker"
        marker.write_bytes(b"owned")
        environment = {
            "DICOW_RUN_ROOT": str(run),
            "DICOW_RUN_ID": "test-run",
            "DICOW_CACHE_ROOT": str(self.root / "cache"),
            "HF_HOME": str(self.root / "hf-home"),
            "DICOW_SPEECH_CACHE": str(self.root / "speech-cache"),
            "DICOW_SPEECH_RUNTIME_ROOT": str(self.root / "speech-runtime"),
        }
        with mock.patch.dict(os.environ, environment, clear=False):
            with self.assertRaises(inspect.InspectionError) as caught:
                inspect.prepare_e0(output)
        self.assertEqual(caught.exception.code, "unresolved_partial_materialization")
        self.assertEqual(marker.read_bytes(), b"owned")

    def test_prepare_records_missing_future_resource_components_before_download(self) -> None:
        run = self.root / "run"
        (run / "env.d").mkdir(parents=True)
        (run / "task-state").mkdir()
        (run / "t2-source-metadata").mkdir()
        write_json(run / "t2-source-metadata" / "manifest.json", {"sealed": True})
        cache = self.root / "cache"
        cache.mkdir()
        self.write_task_states(run, cache)
        environment = {
            "DICOW_RUN_ROOT": str(run),
            "DICOW_RUN_ID": "test-run",
            "DICOW_CACHE_ROOT": str(cache),
            "HF_HOME": str(cache / "hf-home"),
            "DICOW_SPEECH_CACHE": str(cache / "speech-cache"),
            "DICOW_SPEECH_RUNTIME_ROOT": str(cache / "speech-runtime"),
        }
        fake_api = mock.MagicMock()
        fake_module = mock.MagicMock(HfApi=mock.MagicMock(return_value=fake_api))
        with mock.patch.dict(os.environ, environment, clear=False), mock.patch.dict(
            "sys.modules", {"huggingface_hub": fake_module}
        ), mock.patch.object(inspect, "_source_size", return_value=1):
            with self.assertRaises(inspect.InspectionError) as caught:
                inspect.prepare_e0(run / "e0-preflight")
        self.assertEqual(caught.exception.code, "resource_formula_unresolved")
        attempts = list((run / "e0-preflight" / "attempts").iterdir())
        self.assertEqual(len(attempts), 1)
        evidence = json.loads((attempts[0] / "resource-incomplete.json").read_text())
        self.assertEqual(
            evidence["missing_components"],
            [
                "mlx_environment",
                "control_named_goldens",
                "dicow_named_goldens",
                "speech_runtime_extracted_payload",
            ],
        )

    def test_pre_final_failure_can_retry_in_a_new_fingerprinted_attempt(self) -> None:
        run = self.root / "run"
        (run / "env.d").mkdir(parents=True)
        (run / "task-state").mkdir()
        (run / "t2-source-metadata").mkdir()
        write_json(run / "t2-source-metadata" / "manifest.json", {"sealed": True})
        cache = self.root / "cache"
        cache.mkdir()
        self.write_task_states(run, cache)
        environment = {
            "DICOW_RUN_ROOT": str(run),
            "DICOW_RUN_ID": "test-run",
            "DICOW_CACHE_ROOT": str(cache),
            "HF_HOME": str(cache / "hf-home"),
            "DICOW_SPEECH_CACHE": str(cache / "speech-cache"),
            "DICOW_SPEECH_RUNTIME_ROOT": str(cache / "speech-runtime"),
        }
        fake_api = mock.MagicMock()
        fake_module = mock.MagicMock(HfApi=mock.MagicMock(return_value=fake_api))
        with mock.patch.dict(os.environ, environment, clear=False), mock.patch.dict(
            "sys.modules", {"huggingface_hub": fake_module}
        ), mock.patch.object(inspect, "_source_size", return_value=1):
            for _ in range(2):
                with self.assertRaises(inspect.InspectionError) as caught:
                    inspect.prepare_e0(run / "e0-preflight")
                self.assertEqual(caught.exception.code, "resource_formula_unresolved")
        attempts = sorted((run / "e0-preflight" / "attempts").iterdir())
        self.assertEqual(len(attempts), 2)
        self.assertNotEqual(attempts[0].name, attempts[1].name)


class R2InspectionContractTests(unittest.TestCase):
    def external_authority(self, name):
        base = os.environ.get("MACCHERONI_R2_AUTHORITY_ROOT")
        root = Path(base) if base else Path("/private/tmp/maccheroni-r2-authorities")
        return root / name

    def record(self):
        return {"bytes": 10, "sha256": "a" * 64}

    def evidence_record(self, path="captures/common.txt"):
        return {"path": path, "bytes": 10, "sha256": "a" * 64}

    def rights_record(self):
        return self.evidence_record("frontier/rights-matrix.json")

    def fleurs_join(self):
        root = self.external_authority("r3-fleurs-timestamp.staging")
        return {
            "schema_version": "dicow-r2-fleurs-timestamp-join-v1",
            "dataset_id": "google/fleurs",
            "revision": inspect.R2_FLEURS_REVISION,
            "license": "CC-BY-4.0",
            "sample_rate_hz": 16_000,
            "sample_width_bytes": 2,
            "channels": 1,
            "annotation_resolution_samples": 1,
            "gap_samples": 8_000,
            "frame_count": inspect.R2_FLEURS_JOIN_SAMPLES,
            "pcm_sha256": inspect.R2_FLEURS_JOIN_PCM_SHA256,
            "coverage_locales": ["ko", "en", "it"],
            "utterances": [dict(inspect.R2_FLEURS_PARQUETS[key]) for key in ("ko", "en", "it")],
            "source_authority": {
                "root_path": str(root),
                "authority_record": dict(inspect.R2_FLEURS_AUTHORITY_RECORD),
            },
        }

    def hike_term_contract(self):
        root = self.external_authority("r3-hike-terms-v2.staging")
        return {
            "schema_version": "dicow-r2-term-contract-v2",
            "normalized_transcript_edit_tolerance": 0,
            "hike_term_metric": "official_loanword_recall",
            "hike_term_source": "public_hike_official_row_loanwords",
            "hike_term_claim_ceiling": "official_loanword_term_recall_on_pinned_hike_rows",
            "dataset_id": "thetaone-ai/HiKE",
            "revision": inspect.R2_HIKE_REVISION,
            "selected_sample_ids": list(inspect.R2_HIKE_SELECTED_SAMPLE_IDS),
            "extractor_id": inspect.R2_HIKE_TERM_EXTRACTOR,
            "filter_contract": inspect.R2_HIKE_TERM_FILTER,
            "derived_term_count": 18,
            "derived_terms_sha256": inspect.R2_HIKE_TERMS_SHA256,
            "source_authority": {
                "root_path": str(root),
                **json.loads(json.dumps(inspect.R2_HIKE_AUTHORITY_RECORDS)),
            },
            "fleurs_it": "term_metric_not_applicable",
            "fleurs_en": "term_metric_not_applicable",
        }

    def identities(self):
        rows = []
        for candidate, expected in inspect.R2_EXACT_MODEL_IDENTITIES.items():
            size = expected.get("model_file_bytes", 100)
            rows.append({
                "candidate": candidate,
                "model_id": expected["model_id"],
                "revision": expected["revision"],
                "model_file_bytes": size,
                "model_file_lfs_sha256": expected["model_file_lfs_sha256"],
                "content_range_total_bytes": size,
                "header_capture": "headers/{}.safetensors.header".format(candidate),
                "header_record": self.record(),
                "header_inspection": {
                    "header_length": 9,
                    "header_end": 17,
                    "tensor_count": 1,
                    "data_bytes": size - 17,
                    "tensor_signature_sha256": "b" * 64,
                },
                "lfs_capture": "lfs/{}.tree.json".format(candidate),
                "lfs_record": self.record(),
            })
        return {"schema_version": "dicow-r2-model-identities-v1", "models": rows}

    def graph_contracts(self):
        return {
            "schema_version": "dicow-r2-graph-states-v3",
            "ast_derivation": json.loads(json.dumps(inspect.R2_GRAPH_AST_DERIVATION)),
            "candidates": [
                {
                    "candidate": "dicow_mlc",
                    "state": "graph_equivalence_unestablished",
                    "source_files": [self.evidence_record("captures/modeling_dicow.py")],
                    "source_ast_sha256": "1" * 64,
                    "established_semantics": {},
                    "unestablished_semantics": sorted(inspect.R2_EXTERNAL_GRAPH_CONTRACT),
                    "follow_up": "run the separately authorized cheap upstream-only oracle-segment probe",
                },
                {
                    "candidate": "dicow_v3_3",
                    "state": "graph_equivalence_unestablished",
                    "source_files": [
                        self.evidence_record("captures/modeling_dicow.py"),
                        self.evidence_record("captures/FDDT.py"),
                        self.evidence_record("captures/layers.py"),
                    ],
                    "source_ast_sha256": "2" * 64,
                    "established_semantics": {},
                    "unestablished_semantics": sorted(inspect.R2_EXTERNAL_GRAPH_CONTRACT),
                    "follow_up": "establish v3.3 graph semantics before any comparable run",
                },
            ],
        }

    def aligner_inventory(self):
        return json.loads(json.dumps(inspect.R2_ALIGNER_SEMANTIC_STATUS))

    def leakage(self, included_candidate=None):
        rows = []
        for candidate in ("dicow_mlc", "dicow_v3_3"):
            for corpus in ("hike", "fleurs_ko"):
                canonical = "thetaone-ai/HiKE" if corpus == "hike" else "google/fleurs:ko_kr"
                status = "included" if candidate == included_candidate and corpus == "hike" else "unknown"
                disclosed = [canonical] if status == "included" else ["ami", "notsofar"]
                rows.append({
                    "candidate": candidate,
                    "corpus": corpus,
                    "canonical_dataset_id": canonical,
                    "frozen_aliases": ["hike-alias"] if corpus == "hike" else ["fleurs-ko-alias"],
                    "derived_mixtures": ["hike-mixture"] if corpus == "hike" else ["fleurs-ko-mixture"],
                    "universe_kind": "generic_or_incomplete",
                    "disclosed_items": disclosed,
                    "generic_entries": [],
                    "status": status,
                    "reason": "pinned model card does not establish a complete post-base training universe",
                    "base_claim_limitation": "Whisper base pretraining cannot be excluded for either corpus",
                    "training_evidence": [self.evidence_record("captures/training-{}.json".format(candidate))],
                    "training_json_pointer": ["response", "cardData", "datasets"],
                    "extractor_id": "hf_pinned_card_datasets_incomplete_v1",
                })
        return {
            "schema_version": "dicow-r2-leakage-decisions-v2",
            "shared_base_claim_limitation": "Whisper base pretraining cannot be excluded for either corpus",
            "rows": rows,
            "korean_utility_basis": "unavailable",
            "claim_ceiling": "no_korean_utility_claim",
        }

    def request(self, candidate):
        expected = inspect.R2_EXACT_MODEL_IDENTITIES[candidate]
        return {
            "candidate_tuple": {
                "candidate": candidate,
                "model_id": expected["model_id"],
                "revision": expected["revision"],
            },
            "ctc_weight": 0,
            "num_beams": 1,
            "timestamp_mode": "whisper_timestamp_tokens",
            "max_new_tokens": 128,
            "language_field": "language",
            "prompt_field": "prompt_ids",
            "tokenizer_record": self.evidence_record("captures/tokenizer.json"),
            "generation_config_record": self.evidence_record("captures/generation-config.json"),
        }

    def header_for_size(self, size):
        data_bytes = size
        while True:
            entries = {"weight": {"dtype": "I8", "shape": [data_bytes], "data_offsets": [0, data_bytes]}}
            header = json.dumps(entries, separators=(",", ":")).encode()
            updated = size - 8 - len(header)
            if updated == data_bytes:
                return struct.pack("<Q", len(header)) + header
            data_bytes = updated

    def execution_row(self, producer_task="R7"):
        return {
            "duration_seconds": 30,
            "requested_output_tokens": 128,
            "effective_output_tokens": 128,
            "context_tokens": {"state": "unavailable", "reason": "not published"},
            "prompt_tokens": 10,
            "timeout_seconds": 120,
            "maximum_attempts": 2,
            "peak_resident_bytes": {"state": "unavailable", "reason": "deferred until execution"},
            "cancellation_contract": "terminate sole process and retain failed attempt",
            "concurrent_model_processes": {"state": "planned_limit", "maximum": 1},
            "plan_state": "planned_unverified",
            "receipt": {
                "state": "deferred",
                "producer_task": producer_task,
                "schema_version": "dicow-r2-execution-receipt-v1",
            },
        }

    def resource_ledger(self, identities=None):
        identities = identities or self.identities()
        identity_rows = {row["candidate"]: row for row in identities["models"]}
        writers = []
        for writer in preflight.R2_REQUIRED_RESOURCE_WRITERS:
            sources = []
            for candidate in inspect.R2_WRITER_SOURCE_CANDIDATES[writer]:
                identity = identity_rows[candidate]
                sources.append({
                    "candidate": identity["candidate"],
                    "model_id": identity["model_id"],
                    "revision": identity["revision"],
                    "model_file_bytes": identity["model_file_bytes"],
                    "model_file_lfs_sha256": identity["model_file_lfs_sha256"],
                    "header_record": identity["header_record"],
                    "lfs_record": identity["lfs_record"],
                })
            model_bytes = sum(source["model_file_bytes"] for source in sources)
            header_bytes = sum(source["header_record"]["bytes"] for source in sources)
            model = {
                "state": "source_derived", "bytes": model_bytes,
                "bound_kind": "upper_bound", "extractor_id": "sum_model_file_bytes_upper_bound_v1",
            }
            header = {
                "state": "source_derived", "bytes": header_bytes,
                "bound_kind": "exact", "extractor_id": "sum_safetensors_header_bytes_exact_v1",
            }
            zero = {
                "state": "source_derived", "bytes": 0,
                "bound_kind": "exact", "extractor_id": "zero_by_phase_contract_v1",
            }
            phases = [{
                "name": "only",
                "final_bytes": model,
                "staging_bytes": model,
                "retained_failure_bytes": model,
                "retry_bytes": zero,
                "serializer_bytes": header,
                "simultaneously_retained_prior_outputs": zero,
            }]
            writers.append({
                "writer": writer,
                "destination_path": "/private/tmp/maccheroni-r2-test/" + writer,
                "sources": sources,
                "phases": phases,
                "execution": self.execution_row(writer),
                "planning_state": "source_bounds_frozen_receipt_deferred",
            })
        return {"schema_version": "dicow-r2-writer-resource-plan-v2", "writers": writers}

    def audit_documents(self, identities):
        rights_evidence = [self.rights_record()]
        rights = [
            {"subject": subject, "action": action, "state": "allowed", "evidence": rights_evidence}
            for subject in inspect.R2_EXACT_MODEL_IDENTITIES
            for action in inspect.R2_RIGHTS_ACTIONS
        ]
        rights.extend(
            {"subject": subject, "action": action, "state": "allowed", "evidence": rights_evidence}
            for subject in inspect.R2_FIXTURE_RIGHTS_SUBJECTS
            for action in inspect.R2_FIXTURE_RIGHTS_ACTIONS
        )
        constraints = []
        for path in preflight.R2_REQUIRED_CONSTRAINT_PATHS:
            maximum_samples = 30 * 16_000
            constraint = {
                "constraint_id": path + "-duration",
                "variable": "wall audio duration",
                "unit": "samples",
                "scope": path,
                "kind": "operator_choice",
                "source": "R3 unverified execution plan",
                "formula": "floor(planned_seconds*16000)",
                "headroom": "none in the planned cap; actual receipt remains deferred",
                "observed_range": "not_observed_at_R3",
                "planned_maximum_samples": maximum_samples,
                "failure_mode": "preflight reject or split",
                "telemetry": "planned audio seconds",
                "review_trigger": "model revision changes",
            }
            constraints.append({
                "path": path,
                "execution": self.execution_row(path),
                "unit_contract": {
                    "unit": "utterance" if path == "qwen_aligner" else "audio_file",
                    "batch_size": {"state": "planned_limit", "maximum": 1},
                    "sample_rate_hz": 16_000,
                },
                "constraints": [constraint],
                "supported_range": {
                    "state": "planned_unverified",
                    "maximum_samples": maximum_samples,
                    "limiting_constraints": [path + "-duration"],
                    "reason": "boundary receipt deferred to producing task",
                },
                "boundary_probe_plans": [{
                    "constraint_id": path + "-duration",
                    "sample_rate_hz": 16_000,
                    "epsilon_unit": "one_sample",
                    "below_samples": maximum_samples - 1,
                    "at_samples": maximum_samples,
                    "above_samples": maximum_samples + 1,
                    "receipt_state": "deferred",
                    "producer_task": path,
                    "receipt_schema_version": "dicow-r2-boundary-receipt-v1",
                }],
            })
        resources = self.resource_ledger(identities)
        volume = preflight.calculate_r2_writer_resource_ledger(resources)
        return {
            "model-identities.json": identities,
            "graph-contracts.json": self.graph_contracts(),
            "leakage-decisions.json": self.leakage(),
            "rights-bindings.json": {"schema_version": "dicow-r2-rights-bindings-v1", "rows": rights},
            "generation-request-universe.json": {
                "schema_version": "dicow-r2-generation-request-universe-v1",
                "requests": [],
            },
            "qwen-timestamp-contract.json": {
                "status": "timestamp_truth_unavailable",
                "reason": "public FLEURS authority is implemented but no R3 runtime capture was authorized",
                "forced_aligner_self_truth_forbidden": True,
            },
            "qwen-term-contract.json": self.hike_term_contract(),
            "mlx-audio-aligner-inventory.json": self.aligner_inventory(),
            "constraint-ledger.json": {
                "schema_version": "dicow-r2-candidate-constraint-plan-v2",
                "paths": constraints,
            },
            "writer-resource-ledger.json": resources,
            "volume-preflight.json": volume,
            "overlap-prior.json": dict(inspect.R2_OVERLAP_PRIOR),
            "deviations.json": {
                "schema_version": "dicow-r2-deviations-v1",
                "ctc_control_envelope": dict(inspect.R2_CTC_DEVIATION),
            },
            "decision.json": {
                "schema_version": "dicow-r2-pre-model-decision-v1",
                "dicow_scope": "evidence_blocker",
                "qwen_asr_scope": "implementation_ready",
                "qwen_aligner_scope": "implementation_ready",
                "resource_scope": "source_bounds_sufficient_receipts_deferred",
            },
        }

    def test_exact_model_identity_rejects_revision_lfs_and_content_range_drift(self) -> None:
        payload = self.identities()
        self.assertEqual(4, len(inspect.validate_r2_model_identities(payload)["models"]))
        for field, replacement in (
            ("revision", "0" * 40),
            ("model_file_lfs_sha256", "0" * 64),
            ("content_range_total_bytes", 99),
        ):
            mutated = json.loads(json.dumps(payload))
            mutated["models"][0][field] = replacement
            with self.assertRaises(inspect.InspectionError) as raised:
                inspect.validate_r2_model_identities(mutated)
            self.assertEqual("r2_identity_drift", raised.exception.code)

    def test_safetensors_header_rejects_overlap_gap_and_shape_mismatch(self) -> None:
        entries = {
            "a": {"dtype": "F32", "shape": [1], "data_offsets": [0, 4]},
            "b": {"dtype": "I8", "shape": [2], "data_offsets": [4, 6]},
        }
        header = json.dumps(entries, separators=(",", ":")).encode()
        raw = struct.pack("<Q", len(header)) + header
        result = inspect.inspect_r2_safetensors_header(raw, total_file_bytes=len(raw) + 6)
        self.assertEqual(2, result["tensor_count"])

        for offsets in ([3, 5], [5, 7]):
            mutated = json.loads(json.dumps(entries))
            mutated["b"]["data_offsets"] = offsets
            header = json.dumps(mutated, separators=(",", ":")).encode()
            with self.assertRaises(inspect.InspectionError) as raised:
                inspect.inspect_r2_safetensors_header(
                    struct.pack("<Q", len(header)) + header,
                    total_file_bytes=8 + len(header) + max(offsets[1], 6),
                )
            self.assertEqual("r2_safetensors_header", raised.exception.code)

        with self.assertRaises(inspect.InspectionError) as raised:
            inspect.inspect_r2_safetensors_header(raw + b"checkpoint-fragment", total_file_bytes=len(raw) + 100)
        self.assertEqual("r2_safetensors_header", raised.exception.code)

    def test_graphs_seal_sources_but_remain_unestablished(self) -> None:
        result = inspect.validate_r2_graph_contracts(self.graph_contracts())
        self.assertEqual("graph_equivalence_unestablished", result["candidates"]["dicow_v3_3"]["state"])
        mutated = self.graph_contracts()
        mutated["candidates"][1]["source_files"] = [
            row for row in mutated["candidates"][1]["source_files"]
            if not row["path"].endswith("FDDT.py")
        ]
        with self.assertRaises(inspect.InspectionError) as raised:
            inspect.validate_r2_graph_contracts(mutated)
        self.assertEqual("r2_graph_source_missing", raised.exception.code)

    def test_marker_only_graph_cannot_claim_comparable(self) -> None:
        marker = {
            "schema_version": "dicow-r2-graph-contracts-v1",
            "candidates": self.graph_contracts()["candidates"],
        }
        with self.assertRaises(inspect.InspectionError) as raised:
            inspect.validate_r2_graph_contracts(marker)
        self.assertEqual("r2_graph_semantics", raised.exception.code)
        promoted = self.graph_contracts()
        promoted["candidates"][0]["state"] = "comparable"
        with self.assertRaises(inspect.InspectionError):
            inspect.validate_r2_graph_contracts(promoted)

    def test_graph_ast_derivation_rejects_runtime_tuple_drift(self) -> None:
        for role, field, value in (
            ("ast_module_record", "bytes", 64_542),
            ("ast_module_record", "sha256", "0" * 64),
            ("executable_record", "bytes", 18_073_887),
        ):
            mutated = self.graph_contracts()
            mutated["ast_derivation"][role][field] = value
            with self.assertRaises(inspect.InspectionError) as raised:
                inspect.validate_r2_graph_contracts(mutated)
            self.assertEqual("r2_graph_runtime", raised.exception.code)

    def test_graph_runtime_fails_before_ast_parse(self) -> None:
        with (
            mock.patch.object(inspect.sys, "version_info", (3, 11, 0)),
            mock.patch.object(inspect.ast, "parse", side_effect=AssertionError("AST parse must not run")),
            self.assertRaises(inspect.InspectionError) as raised,
        ):
            inspect._verify_r2_graph_runtime(self.graph_contracts()["ast_derivation"])
        self.assertEqual("r2_graph_runtime", raised.exception.code)

    def test_aligner_semantic_status_keeps_no_active_bundle(self) -> None:
        inventory = self.aligner_inventory()
        validated = inspect.validate_r2_aligner_inventory(inventory)
        self.assertEqual("semantic_authority_rejected", validated["status"])
        self.assertEqual("unestablished", validated["verdict"])
        self.assertIsNone(validated["active_bundle"])

    def test_aligner_rejected_diagnostic_cannot_self_promote(self) -> None:
        promoted = self.aligner_inventory()
        promoted["verdict"] = "exact_weights_only_supported"
        promoted["active_bundle"] = {"version": "semantic-v4"}
        with self.assertRaises(inspect.InspectionError):
            inspect.validate_r2_aligner_inventory(promoted)
        legacy = {
            "schema_version": "dicow-r2-mlx-audio-aligner-inventory-v2",
            "verdict": "new_model_code_required",
            "axes": [],
        }
        with self.assertRaises(inspect.InspectionError):
            inspect.validate_r2_aligner_inventory(legacy)

    def test_rejected_aligner_diagnostic_is_never_executed(self) -> None:
        with mock.patch.object(
            inspect.subprocess,
            "run",
            side_effect=AssertionError("rejected semantic verifier must not run"),
        ):
            inspect._verify_r2_aligner_evidence(
                self.aligner_inventory(), Path("/not-used")
            )

    def test_leakage_incomplete_disclosures_remain_unknown(self) -> None:
        self.assertEqual(
            "unavailable",
            inspect.validate_r2_leakage_decisions(self.leakage())["korean_utility_basis"],
        )
        false_exclusion = self.leakage()
        false_exclusion["rows"][0]["status"] = "excluded"
        with self.assertRaises(inspect.InspectionError) as raised:
            inspect.validate_r2_leakage_decisions(false_exclusion)
        self.assertEqual("r2_leakage_claim", raised.exception.code)

        asymmetric = self.leakage()
        asymmetric["rows"][0]["base_claim_limitation"] = "different base rule"
        with self.assertRaises(inspect.InspectionError) as raised:
            inspect.validate_r2_leakage_decisions(asymmetric)
        self.assertEqual("r2_leakage_asymmetry", raised.exception.code)

    def test_wrapper_declared_completeness_cannot_upgrade_leakage(self) -> None:
        row = self.leakage()["rows"][0]
        normalized = json.dumps({"datasets": ["ami"], "training_disclosure_complete": True}).encode()
        with self.assertRaises(inspect.InspectionError) as raised:
            inspect._extract_r2_training_disclosure(normalized, row)
        self.assertEqual("r2_leakage_evidence", raised.exception.code)
        identity = inspect.R2_EXACT_MODEL_IDENTITIES[row["candidate"]]
        raw = json.dumps({
            "request_url": "https://huggingface.co/api/models/{}/revision/{}".format(
                identity["model_id"], identity["revision"]
            ),
            "model_id": identity["model_id"],
            "revision": identity["revision"],
            "response": {"cardData": {
                "datasets": ["ami"],
                "training_disclosure": {"scope": "complete_post_base_adaptation_and_finetuning_universe"},
            }},
        }).encode()
        self.assertEqual(
            (["ami"], [], "generic_or_incomplete"),
            inspect._extract_r2_training_disclosure(raw, row),
        )

    def test_free_resource_integers_and_fake_boundary_observations_are_rejected(self) -> None:
        legacy = {"schema_version": "dicow-r2-writer-resource-ledger-v1", "writers": []}
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.calculate_r2_writer_resource_ledger(legacy, required_writers=())
        self.assertEqual("r2_resource_formula_mismatch", raised.exception.code)
        plan = self.resource_ledger()
        plan["writers"][0]["phases"][0]["final_bytes"] = 123
        with self.assertRaises(preflight.PreflightError) as raised:
            preflight.calculate_r2_writer_resource_ledger(plan)
        self.assertEqual("r2_resource_formula_mismatch", raised.exception.code)

        documents = self.audit_documents(self.identities())
        documents["writer-resource-ledger.json"]["writers"][0]["sources"][0]["model_id"] = "invented/model"
        with self.assertRaises(inspect.InspectionError) as raised:
            inspect.validate_r2_audit_documents(documents, require_current_volume_snapshot=False)
        self.assertEqual("r2_resource_formula_mismatch", raised.exception.code)

    def test_constant_pcm_cannot_replace_public_fleurs_authority(self) -> None:
        join = self.fleurs_join()
        mutated = json.loads(json.dumps(join))
        mutated["utterances"][0]["pcm_value"] = 100
        with self.assertRaises(inspect.InspectionError) as raised:
            inspect._generate_r2_timestamp_pcm(mutated)
        self.assertEqual("r2_timestamp_contract", raised.exception.code)

    def test_public_fleurs_replay_uses_sealed_external_authority(self) -> None:
        try:
            import pyarrow  # noqa: F401
        except ImportError:
            self.skipTest("pyarrow is required for the external FLEURS replay")
        join = self.fleurs_join()
        if not Path(join["source_authority"]["root_path"]).is_dir():
            self.skipTest("set MACCHERONI_R2_AUTHORITY_ROOT for the external FLEURS replay")
        pcm = inspect._generate_r2_timestamp_pcm(join)
        self.assertEqual(inspect.R2_FLEURS_JOIN_SAMPLES * 2, len(pcm))
        self.assertEqual(inspect.R2_FLEURS_JOIN_PCM_SHA256, hashlib.sha256(pcm).hexdigest())
        substituted = json.loads(json.dumps(join))
        substituted["source_authority"]["root_path"] = str(Path(__file__).resolve().parents[4])
        with self.assertRaises((inspect.InspectionError, preflight.PreflightError)):
            inspect._generate_r2_timestamp_pcm(substituted)

    def test_generation_universe_requires_all_kwargs_and_identical_candidate_semantics(self) -> None:
        payload = {
            "schema_version": "dicow-r2-generation-request-universe-v1",
            "requests": [self.request("dicow_mlc"), self.request("dicow_v3_3")],
        }
        self.assertEqual(
            {"dicow_mlc", "dicow_v3_3"},
            set(inspect.validate_r2_generation_request_universe(payload)["requests"]),
        )
        missing = json.loads(json.dumps(payload))
        del missing["requests"][0]["timestamp_mode"]
        with self.assertRaises(inspect.InspectionError) as raised:
            inspect.validate_r2_generation_request_universe(missing)
        self.assertEqual("r2_generation_shape", raised.exception.code)
        drift = json.loads(json.dumps(payload))
        drift["requests"][1]["num_beams"] = 2
        with self.assertRaises(inspect.InspectionError):
            inspect.validate_r2_generation_request_universe(drift)

    def test_r3_deviations_are_exact_and_cannot_fabricate_values(self) -> None:
        deviations = {
            "schema_version": "dicow-r2-deviations-v1",
            "ctc_control_envelope": dict(inspect.R2_CTC_DEVIATION),
        }
        inspect.validate_r2_deviations(deviations)
        mutated = json.loads(json.dumps(deviations))
        mutated["ctc_control_envelope"]["numeric_envelope"] = 0.00001
        with self.assertRaises(inspect.InspectionError) as raised:
            inspect.validate_r2_deviations(mutated)
        self.assertEqual("r2_deviation_drift", raised.exception.code)

        inspect.validate_r2_overlap_prior(dict(inspect.R2_OVERLAP_PRIOR))
        overlap = dict(inspect.R2_OVERLAP_PRIOR)
        overlap["prevalence"] = 0.3
        with self.assertRaises(inspect.InspectionError) as raised:
            inspect.validate_r2_overlap_prior(overlap)
        self.assertEqual("r2_overlap_prior_drift", raised.exception.code)

    def test_rights_bind_every_action_and_terms_require_official_row_authority(self) -> None:
        evidence = [self.rights_record()]
        rows = [
            {"subject": subject, "action": action, "state": "allowed", "evidence": evidence}
            for subject in inspect.R2_EXACT_MODEL_IDENTITIES
            for action in inspect.R2_RIGHTS_ACTIONS
        ]
        rows.extend(
            {"subject": subject, "action": action, "state": "allowed", "evidence": evidence}
            for subject in inspect.R2_FIXTURE_RIGHTS_SUBJECTS
            for action in inspect.R2_FIXTURE_RIGHTS_ACTIONS
        )
        rights = {"schema_version": "dicow-r2-rights-bindings-v1", "rows": rows}
        self.assertEqual(29, len(inspect.validate_r2_rights_bindings(rights)["rows"]))
        rights["rows"].pop()
        with self.assertRaises(inspect.InspectionError) as raised:
            inspect.validate_r2_rights_bindings(rights)
        self.assertEqual("r2_rights_binding", raised.exception.code)

        terms = self.hike_term_contract()
        inspect.validate_r2_term_contract(terms)
        terms["derived_terms_sha256"] = "0" * 64
        with self.assertRaises(inspect.InspectionError) as raised:
            inspect.validate_r2_term_contract(terms)
        self.assertEqual("r2_term_contract", raised.exception.code)

        for record_name in ("terms_record", "selected_rows_record", "selection_record", "card_record"):
            mutated = self.hike_term_contract()
            mutated["source_authority"][record_name]["sha256"] = "0" * 64
            with self.assertRaises(inspect.InspectionError) as raised:
                inspect.validate_r2_term_contract(mutated)
            self.assertEqual("r2_term_contract", raised.exception.code)

        invented = {
            "schema_version": "dicow-r2-term-contract-v1",
            "normalized_transcript_edit_tolerance": 0,
            "hike_term_set_difference_tolerance": 0,
            "hike_term_source": "public_hike_official_term_list",
            "hike_term_source_record": self.evidence_record("captures/hike-terms.json"),
            "fleurs_it": "term_metric_not_applicable",
            "fleurs_en": "term_metric_not_applicable",
        }
        with self.assertRaises(inspect.InspectionError):
            inspect.validate_r2_term_contract(invented)

    def test_hike_authority_rejects_forged_terms_and_selected_rows_bytes(self) -> None:
        authority = Path(self.hike_term_contract()["source_authority"]["root_path"])
        if not authority.is_dir():
            self.skipTest("set MACCHERONI_R2_AUTHORITY_ROOT for the external HiKE replay")
        for forged_relative, forged_bytes in (
            ("terms.txt", b"invented\n"),
            ("selected-rows.jsonl", b'{"sample_id":"invented"}\n'),
        ):
            with self.subTest(forged_relative=forged_relative):
                with tempfile.TemporaryDirectory(dir="/private/tmp") as temporary:
                    forged_root = Path(temporary) / "authority"
                    for relative in (
                        "manifest.json", "captures/README.upstream.md", "selected-sample-ids.txt",
                        "selected-rows.jsonl", "terms.txt",
                    ):
                        destination = forged_root / relative
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        destination.write_bytes((authority / relative).read_bytes())
                        destination.chmod(0o444)
                    forged = forged_root / forged_relative
                    forged.chmod(0o644)
                    forged.write_bytes(forged_bytes)
                    forged.chmod(0o444)
                    for directory in sorted(
                        (path for path in forged_root.rglob("*") if path.is_dir()),
                        key=lambda path: len(path.parts),
                        reverse=True,
                    ):
                        directory.chmod(0o555)
                    forged_root.chmod(0o555)
                    contract = self.hike_term_contract()
                    contract["source_authority"]["root_path"] = str(forged_root)
                    with self.assertRaises(inspect.InspectionError) as raised:
                        inspect._replay_r2_hike_terms(contract)
                    self.assertEqual("r2_term_contract", raised.exception.code)
                    for directory in [forged_root / "captures", forged_root]:
                        directory.chmod(0o755)

    def test_hike_terms_replay_official_selected_row_labels(self) -> None:
        try:
            import pyarrow  # noqa: F401
        except ImportError:
            self.skipTest("pyarrow is required for the external HiKE replay")
        authority = Path(self.hike_term_contract()["source_authority"]["root_path"])
        if not authority.is_dir():
            self.skipTest("set MACCHERONI_R2_AUTHORITY_ROOT for the external HiKE replay")
        terms = inspect._replay_r2_hike_terms(self.hike_term_contract())
        self.assertEqual(18, len(terms.decode("utf-8").splitlines()))
        self.assertEqual(inspect.R2_HIKE_TERMS_SHA256, hashlib.sha256(terms).hexdigest())

    def test_rights_block_component_readiness_instead_of_becoming_metadata_only(self) -> None:
        identities = self.identities()
        documents = self.audit_documents(identities)
        for row in documents["rights-bindings.json"]["rows"]:
            if row["subject"] == "qwen_asr" and row["action"] == "private_local_derivative":
                row["state"] = "forbidden"
        with self.assertRaises(inspect.InspectionError) as raised:
            inspect.validate_r2_audit_documents(documents, require_current_volume_snapshot=False)
        self.assertEqual("r2_decision_semantics", raised.exception.code)

        documents = self.audit_documents(self.identities())
        for row in documents["rights-bindings.json"]["rows"]:
            if row["subject"] == "dicow_v3_3" and row["action"] == "private_reference_evaluation":
                row["state"] = "forbidden"
        result = inspect.validate_r2_audit_documents(documents, require_current_volume_snapshot=False)
        self.assertEqual("evidence_blocker", result["decision"]["dicow_scope"])

    def test_prepare_and_offline_verify_r2_audit_are_create_only_and_header_bound(self) -> None:
        try:
            import pyarrow  # noqa: F401
        except ImportError:
            self.skipTest("pyarrow is required for the full external-authority audit replay")
        required_authorities = (
            self.external_authority("r3-fleurs-timestamp.staging"),
            self.external_authority("r3-hike-terms-v2.staging"),
        )
        if not all(path.is_dir() for path in required_authorities):
            self.skipTest("set MACCHERONI_R2_AUTHORITY_ROOT for the full audit replay")
        temporary = tempfile.TemporaryDirectory(dir="/private/tmp")
        root = Path(temporary.name)
        try:
            frontier = root / "frontier"
            frontier.mkdir()
            (frontier / "evidence.json").write_text("{}\n")
            (frontier / "evidence.json").chmod(0o444)
            rights_matrix = {
                "schema_version": "action-specific-rights-matrix-v1",
                "rows": [{
                    "entity": entity,
                    "actions": {
                        "private_reference_evaluation": "eligible",
                        "private_derivative_conversion": "eligible",
                        "public_converter_code": "eligible",
                        "public_weight_redistribution": "eligible",
                        "generated_audio": "eligible",
                        "tracked_metadata_or_scripts": "eligible",
                    },
                } for entity in inspect.R2_RIGHTS_ENTITIES.values() if entity != "BUT-FIT/DiCoW_v3_3"] + [{
                    "entity": "BUT-FIT/DiCoW_v3_3_large",
                    "actions": {
                        "private_reference_evaluation": "eligible",
                        "private_derivative_conversion": "eligible",
                        "public_converter_code": "eligible",
                        "public_weight_redistribution": "eligible",
                        "generated_audio": "eligible",
                        "tracked_metadata_or_scripts": "eligible",
                    },
                }],
            }
            write_json(frontier / "rights-matrix.json", rights_matrix)
            rights_raw = (frontier / "rights-matrix.json").read_bytes()
            rights_record = {
                "path": "frontier/rights-matrix.json",
                "bytes": len(rights_raw),
                "sha256": hashlib.sha256(rights_raw).hexdigest(),
            }
            (frontier / "rights-matrix.json").chmod(0o444)
            frontier.chmod(0o555)
            frontier_record = preflight.artifact_record(frontier, immutable=True)

            capture_root = root / "captures"
            capture_root.mkdir()
            identities = self.identities()
            identity_rows = {row["candidate"]: row for row in identities["models"]}
            captures = []
            for candidate, identity in identity_rows.items():
                raw = self.header_for_size(identity["model_file_bytes"])
                path = capture_root / (candidate + ".header")
                path.write_bytes(raw)
                path.chmod(0o444)
                record = {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}
                inspection = inspect.inspect_r2_safetensors_header(
                    raw, total_file_bytes=identity["model_file_bytes"]
                )
                identity["header_record"] = record
                identity["header_inspection"] = inspection
                captures.append({
                    "name": identity["header_capture"],
                    "kind": "safetensors_header",
                    "source_path": str(path),
                    "record": record,
                    "total_file_bytes": identity["model_file_bytes"],
                })
                lfs_value = {
                    "request_url": "https://huggingface.co/api/models/{}/tree/{}".format(identity["model_id"], identity["revision"]),
                    "model_id": identity["model_id"],
                    "revision": identity["revision"],
                    "response": [{
                        "path": "model.safetensors",
                        "lfs": {"oid": "sha256:" + identity["model_file_lfs_sha256"], "size": identity["model_file_bytes"]},
                    }],
                }
                lfs_path = capture_root / (candidate + ".lfs.json")
                write_json(lfs_path, lfs_value)
                lfs_raw = lfs_path.read_bytes()
                lfs_record = {"bytes": len(lfs_raw), "sha256": hashlib.sha256(lfs_raw).hexdigest()}
                lfs_path.chmod(0o444)
                identity["lfs_record"] = lfs_record
                captures.append({
                    "name": identity["lfs_capture"],
                    "kind": "hf_lfs_metadata",
                    "source_path": str(lfs_path),
                    "record": lfs_record,
                    "total_file_bytes": None,
                })

            documents = self.audit_documents(identities)
            for row in documents["rights-bindings.json"]["rows"]:
                if row["subject"] == "dicow_v3_3":
                    row["state"] = "unresolved"
            join = self.fleurs_join()
            timestamp_pcm = inspect._generate_r2_timestamp_pcm(join)
            join_raw = (json.dumps(join, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()
            utterances = [
                {key: row[key] for key in ("utterance_id", "start_sample", "end_sample")}
                for row in join["utterances"]
            ]
            words = [
                {
                    "word_id": "word-{}".format(index),
                    "start_sample": row["start_sample"] + 100,
                    "end_sample": row["start_sample"] + 200,
                }
                for index, row in enumerate(join["utterances"])
            ]
            documents["qwen-timestamp-contract.json"] = {
                **preflight.R2_TIMESTAMP_CONTRACT,
                "status": "available",
                "truth_fixture_record": self.evidence_record("captures/timestamp-fixture.pcm"),
                "join_manifest_record": self.evidence_record("captures/timestamp-join.json"),
                "coverage_locales": ["ko", "en", "it"],
                "attribution_replay": {
                    "utterances": utterances,
                    "words": words,
                    "expected": preflight.attribute_r2_words_to_utterances(utterances, words),
                },
            }
            evidence_payloads = {
                **{
                    "training-{}.json".format(candidate): json.dumps({
                        "request_url": "https://huggingface.co/api/models/{}/revision/{}".format(
                            inspect.R2_EXACT_MODEL_IDENTITIES[candidate]["model_id"],
                            inspect.R2_EXACT_MODEL_IDENTITIES[candidate]["revision"],
                        ),
                        "model_id": inspect.R2_EXACT_MODEL_IDENTITIES[candidate]["model_id"],
                        "revision": inspect.R2_EXACT_MODEL_IDENTITIES[candidate]["revision"],
                        "response": {"cardData": {"datasets": ["ami", "notsofar"]}},
                    }, sort_keys=True).encode() + b"\n"
                    for candidate in ("dicow_mlc", "dicow_v3_3")
                },
                "timestamp-fixture.pcm": timestamp_pcm,
                "timestamp-join.json": join_raw,
                "modeling_dicow.py": b"class Model:\n    pass\n",
                "FDDT.py": b"class FDDT:\n    pass\n",
                "layers.py": b"class Layer:\n    pass\n",
            }
            evidence_records = {}
            evidence_records[rights_record["path"]] = rights_record
            for name, raw in evidence_payloads.items():
                path = capture_root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(raw)
                path.chmod(0o444)
                record = {"path": "captures/" + name, "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()}
                evidence_records[record["path"]] = record
                captures.append({
                    "name": name,
                    "kind": "evidence",
                    "source_path": str(path),
                    "record": {"bytes": record["bytes"], "sha256": record["sha256"]},
                    "total_file_bytes": None,
                })
            # Replace placeholder tuples without losing the path during mutation.
            def bind_records(value):
                if isinstance(value, dict):
                    if set(value) == {"path", "bytes", "sha256"}:
                        actual = evidence_records.get(value["path"])
                        if actual is not None:
                            value.update(actual)
                    else:
                        for item in value.values():
                            bind_records(item)
                elif isinstance(value, list):
                    for item in value:
                        bind_records(item)
            bind_records(documents)
            for graph in documents["graph-contracts.json"]["candidates"]:
                ast_rows = []
                for source in graph["source_files"]:
                    if Path(source["path"]).suffix != ".py":
                        continue
                    raw = evidence_payloads[Path(source["path"]).name]
                    ast_rows.append({
                        "path": source["path"],
                        "ast": inspect.ast.dump(
                            inspect.ast.parse(raw.decode(), feature_version=(3, 12)),
                            annotate_fields=True,
                            include_attributes=False,
                        ),
                    })
                graph["source_ast_sha256"] = hashlib.sha256(
                    json.dumps(sorted(ast_rows, key=lambda row: row["path"]), sort_keys=True, separators=(",", ":")).encode()
                ).hexdigest()
            spec = {
                "schema_version": inspect.R2_AUDIT_SCHEMA_VERSION,
                "run_id": "r2-test",
                "frontier_record": frontier_record,
                "captures": captures,
                "documents": documents,
            }
            spec_path = root / "spec.json"
            write_json(spec_path, spec)
            output = root / "pre-model-audit"
            result = inspect.prepare_r2_audit(output, frontier, spec_path)
            self.assertEqual("verified", result["status"])
            self.assertEqual("verified", inspect.verify_r2_audit(output)["status"])
            with self.assertRaises(inspect.InspectionError) as raised:
                inspect.prepare_r2_audit(output, frontier, spec_path)
            self.assertEqual("r2_create_only", raised.exception.code)

            header = next((output / "attempts").glob("*/source-captures/headers/dicow_mlc.safetensors.header"))
            header.chmod(0o644)
            header.write_bytes(header.read_bytes() + b"x")
            header.chmod(0o444)
            with self.assertRaises((inspect.InspectionError, preflight.PreflightError)):
                inspect.verify_r2_audit(output)
        finally:
            for parent, directories, files in os.walk(str(root), topdown=False):
                for name in files:
                    try:
                        (Path(parent) / name).chmod(0o600)
                    except FileNotFoundError:
                        pass
                for name in directories:
                    try:
                        (Path(parent) / name).chmod(0o700)
                    except FileNotFoundError:
                        pass
            if root.exists():
                root.chmod(0o700)
            temporary.cleanup()


if __name__ == "__main__":
    unittest.main()
